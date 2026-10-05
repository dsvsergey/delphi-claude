unit ClaudeCode.DiffForm;

{ Non-modal window showing Claude's proposed change as a coloured diff, unified or side by
  side, with the changed part of each line highlighted. Each change (hunk) can be skipped
  (Space / double-click), and the proposed text can be edited before accepting. The decision
  callback is invoked exactly once (accept, reject, or window closed). }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, ClaudeCode.Diff;

type
  TDiffDecision = (ddAccepted, ddRejected);
  TDiffDecisionProc = reference to procedure(Decision: TDiffDecision; const FinalContents: string);

  { A row of the side-by-side view: indexes into the diff (-1 = empty side). }
  TSideRow = record
    Left, Right: Integer;
  end;

  TClaudeDiffForm = class(TForm)
  private
    FTabName: string;
    FFilePath: string;
    FOldText: string;
    FNewText: string;
    FDiff: TDiffLines;
    FHunks: TArray<THunk>;
    FAccepted: TArray<Boolean>;
    FHunkOf: TArray<Integer>;  // hunk index of each diff line, -1 for equal lines
    FPair: TArray<Integer>;    // counterpart of a changed line within its hunk, or -1
    FSideRows: TArray<TSideRow>;
    FSideBySide: Boolean;
    FDecided: Boolean;
    FOnDecision: TDiffDecisionProc;
    FMemoEdited: Boolean;
    FDiffStale: Boolean;
    FNote: string;
    FInfo: TLabel;
    FPages: TPageControl;
    FList: TListBox;
    FMemo: TMemo;
    FSideBox: TCheckBox;
    procedure BuildUI;
    procedure RebuildDiff;
    procedure UpdateInfo;
    procedure ListDrawItem(Control: TWinControl; Index: Integer; Rect: TRect; State: TOwnerDrawState);
    procedure DrawLine(C: TCanvas; const R: TRect; DiffIndex: Integer; ShowNumbers: Boolean; Selected: Boolean);
    procedure ListDblClick(Sender: TObject);
    procedure ListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SideBoxClick(Sender: TObject);
    procedure AcceptClick(Sender: TObject);
    procedure RejectClick(Sender: TObject);
    procedure FormCloseEvent(Sender: TObject; var Action: TCloseAction);
    procedure FormKeyDownEvent(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PagesChange(Sender: TObject);
    procedure MemoChange(Sender: TObject);
    function ProposedText: string;
    function FinalText: string;
    function AcceptedCount: Integer;
    function RowDiffIndex(Row: Integer): Integer;
    function RowHunk(Row: Integer): Integer;
    procedure ToggleHunk(Hunk: Integer);
    procedure GotoHunk(Delta: Integer);
    procedure Decide(D: TDiffDecision);
    procedure SetNote(const Value: string);
  public
    constructor CreateDiff(const ATabName, AFilePath, AOldText, ANewText: string;
      const OnDecision: TDiffDecisionProc);
    destructor Destroy; override;
    procedure ShowAndActivate;
    procedure Reject;
    property TabName: string read FTabName;
    property Decided: Boolean read FDecided;
    { Extra information shown next to the file name (e.g. encoding repairs). }
    property Note: string read FNote write SetNote;
  end;

function FindDiffForm(const TabName: string): TClaudeDiffForm;
function CloseAllDiffForms: Integer;
procedure DestroyAllDiffForms;

implementation

uses
  System.Math, Vcl.Themes, ClaudeCode.CompatIde;

var
  GForms: TList<TClaudeDiffForm>;
  // Remembered between windows.
  GSideBySide: Boolean;

function FindDiffForm(const TabName: string): TClaudeDiffForm;
var
  F: TClaudeDiffForm;
begin
  for F in GForms do
    if not F.Decided and (F.TabName = TabName) then
      Exit(F);
  Result := nil;
end;

function CloseAllDiffForms: Integer;
var
  F: TClaudeDiffForm;
begin
  Result := 0;
  for F in GForms.ToArray do
    if not F.Decided then
    begin
      F.Reject;
      Inc(Result);
    end;
end;

procedure DestroyAllDiffForms;
var
  F: TClaudeDiffForm;
begin
  // Used when the package unloads: free synchronously, never answer.
  for F in GForms.ToArray do
  begin
    F.FOnDecision := nil;
    F.FDecided := True;
    F.Free;
  end;
end;

function IsDarkColor(C: TColor): Boolean;
var
  RGB: Longint;
begin
  RGB := ColorToRGB(C);
  Result := (GetRValue(RGB) * 299 + GetGValue(RGB) * 587 + GetBValue(RGB) * 114) div 1000 < 128;
end;

function ExpandTabs(const S: string): string;
begin
  Result := StringReplace(S, #9, '  ', [rfReplaceAll]);
end;

{ TClaudeDiffForm }

constructor TClaudeDiffForm.CreateDiff(const ATabName, AFilePath, AOldText, ANewText: string;
  const OnDecision: TDiffDecisionProc);
begin
  inherited CreateNew(nil);
  FTabName := ATabName;
  FFilePath := AFilePath;
  FOldText := AOldText;
  FNewText := ANewText;
  FOnDecision := OnDecision;
  FSideBySide := GSideBySide;
  GForms.Add(Self);
  BuildUI;
  RebuildDiff;
end;

destructor TClaudeDiffForm.Destroy;
begin
  GForms.Remove(Self);
  Decide(ddRejected);
  inherited;
end;

procedure TClaudeDiffForm.BuildUI;
var
  Top, Bottom: TPanel;
  TabDiff, TabEdit: TTabSheet;
  BtnAccept, BtnReject: TButton;
  Hint: TLabel;
begin
  Caption := 'Claude Code - ' + FTabName;
  Width := 1200;
  Height := 780;
  Position := poMainFormCenter;
  BorderIcons := [biSystemMenu, biMaximize];
  KeyPreview := True;
  PopupMode := pmAuto;
  OnClose := FormCloseEvent;
  OnKeyDown := FormKeyDownEvent;

  Top := TPanel.Create(Self);
  Top.Parent := Self;
  Top.Align := alTop;
  Top.Height := 30;
  Top.BevelOuter := bvNone;
  FSideBox := TCheckBox.Create(Self);
  FSideBox.Parent := Top;
  FSideBox.Caption := 'Side by side';
  FSideBox.Width := 110;
  FSideBox.AlignWithMargins := True;
  FSideBox.Margins.SetBounds(8, 6, 8, 4);
  FSideBox.Align := alRight;
  FSideBox.Checked := FSideBySide;
  FSideBox.OnClick := SideBoxClick;
  FInfo := TLabel.Create(Self);
  FInfo.Parent := Top;
  FInfo.AlignWithMargins := True;
  FInfo.Margins.SetBounds(8, 8, 8, 4);
  FInfo.Align := alClient;
  FInfo.EllipsisPosition := epPathEllipsis;

  Bottom := TPanel.Create(Self);
  Bottom.Parent := Self;
  Bottom.Align := alBottom;
  Bottom.Height := 44;
  Bottom.BevelOuter := bvNone;

  BtnReject := TButton.Create(Self);
  BtnReject.Parent := Bottom;
  BtnReject.Caption := 'Reject (Esc)';
  BtnReject.Width := 130;
  BtnReject.AlignWithMargins := True;
  BtnReject.Margins.SetBounds(4, 8, 8, 8);
  BtnReject.Align := alRight;
  BtnReject.OnClick := RejectClick;

  BtnAccept := TButton.Create(Self);
  BtnAccept.Parent := Bottom;
  BtnAccept.Caption := 'Accept (Ctrl+Enter)';
  BtnAccept.Width := 160;
  BtnAccept.AlignWithMargins := True;
  BtnAccept.Margins.SetBounds(4, 8, 4, 8);
  BtnAccept.Align := alRight;
  BtnAccept.OnClick := AcceptClick;
  BtnAccept.Left := BtnReject.Left - 1;

  Hint := TLabel.Create(Self);
  Hint.Parent := Bottom;
  Hint.AlignWithMargins := True;
  Hint.Margins.SetBounds(8, 14, 8, 8);
  Hint.Align := alClient;
  Hint.Caption := 'Space or double-click: take or skip a change.  N / P: next / previous change.  ' +
    'Edits on the "Proposed" tab are kept on Accept. You can also answer in the Claude terminal.';

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.OnChange := PagesChange;

  TabDiff := TTabSheet.Create(Self);
  TabDiff.PageControl := FPages;
  TabDiff.Caption := 'Diff';
  TabEdit := TTabSheet.Create(Self);
  TabEdit.PageControl := FPages;
  TabEdit.Caption := 'Proposed (editable)';

  FList := TListBox.Create(Self);
  FList.Parent := TabDiff;
  FList.Align := alClient;
  FList.Style := lbVirtualOwnerDraw;
  FList.Font.Name := 'Consolas';
  FList.Font.Size := 10;
  FList.OnDrawItem := ListDrawItem;
  FList.OnDblClick := ListDblClick;
  FList.OnKeyDown := ListKeyDown;
  FList.Canvas.Font.Assign(FList.Font);
  FList.ItemHeight := FList.Canvas.TextHeight('Wg') + 2;

  FMemo := TMemo.Create(Self);
  FMemo.Parent := TabEdit;
  FMemo.Align := alClient;
  FMemo.ScrollBars := ssBoth;
  FMemo.WordWrap := False;
  FMemo.WantTabs := True;
  FMemo.Font.Name := 'Consolas';
  FMemo.Font.Size := 10;
  FMemo.MaxLength := 0;
  FMemo.Lines.Text := FNewText;
  FMemo.OnChange := MemoChange;

  FPages.ActivePage := TabDiff;
end;

procedure TClaudeDiffForm.RebuildDiff;
var
  I, H, MaxLen, D, K: Integer;
  Dels, Ins: TList<Integer>;
  Rows: TList<TSideRow>;
  Row: TSideRow;
begin
  FDiff := ComputeLineDiff(SplitLines(FOldText), SplitLines(ProposedText));
  FHunks := FindHunks(FDiff);
  SetLength(FAccepted, Length(FHunks));
  for H := 0 to High(FAccepted) do
    FAccepted[H] := True;
  FPair := PairLines(FDiff, FHunks);
  SetLength(FHunkOf, Length(FDiff));
  for I := 0 to High(FHunkOf) do
    FHunkOf[I] := -1;
  for H := 0 to High(FHunks) do
    for I := FHunks[H].First to FHunks[H].Last do
      FHunkOf[I] := H;

  // Side-by-side rows: equal lines on both sides; in a hunk, deletes left and inserts right.
  Rows := TList<TSideRow>.Create;
  Dels := TList<Integer>.Create;
  Ins := TList<Integer>.Create;
  try
    I := 0;
    while I <= High(FDiff) do
    begin
      if FDiff[I].Kind = dkEqual then
      begin
        Row.Left := I;
        Row.Right := I;
        Rows.Add(Row);
        Inc(I);
        Continue;
      end;
      H := FHunkOf[I];
      Dels.Clear;
      Ins.Clear;
      for D := FHunks[H].First to FHunks[H].Last do
        if FDiff[D].Kind = dkDelete then
          Dels.Add(D)
        else
          Ins.Add(D);
      for K := 0 to Max(Dels.Count, Ins.Count) - 1 do
      begin
        if K < Dels.Count then Row.Left := Dels[K] else Row.Left := -1;
        if K < Ins.Count then Row.Right := Ins[K] else Row.Right := -1;
        Rows.Add(Row);
      end;
      I := FHunks[H].Last + 1;
    end;
    FSideRows := Rows.ToArray;
  finally
    Ins.Free;
    Dels.Free;
    Rows.Free;
  end;

  MaxLen := 0;
  for I := 0 to High(FDiff) do
    MaxLen := Max(MaxLen, Length(ExpandTabs(FDiff[I].Text)));
  if FSideBySide then
  begin
    FList.Count := Length(FSideRows);
    FList.ScrollWidth := 0;
  end
  else
  begin
    FList.Count := Length(FDiff);
    FList.ScrollWidth := (MaxLen + 20) * FList.Canvas.TextWidth('W');
  end;
  UpdateInfo;
  GotoHunk(0);
  FList.Invalidate;
  FDiffStale := False;
end;

procedure TClaudeDiffForm.UpdateInfo;
var
  Added, Removed: Integer;
  S: string;
begin
  CountChanges(FDiff, Added, Removed);
  if FOldText = '' then
    S := Format('%s   (new file)   +%d lines', [FFilePath, Added])
  else
    S := Format('%s   +%d / -%d lines', [FFilePath, Added, Removed]);
  if Length(FHunks) > 1 then
    S := S + Format('   changes taken: %d of %d', [AcceptedCount, Length(FHunks)]);
  if FNote <> '' then
    S := S + '   (' + FNote + ')';
  FInfo.Caption := S;
end;

procedure TClaudeDiffForm.SetNote(const Value: string);
begin
  FNote := Value;
  UpdateInfo;
end;

function TClaudeDiffForm.AcceptedCount: Integer;
var
  B: Boolean;
begin
  Result := 0;
  for B in FAccepted do
    if B then
      Inc(Result);
end;

function TClaudeDiffForm.RowDiffIndex(Row: Integer): Integer;
begin
  Result := -1;
  if FSideBySide then
  begin
    if (Row >= 0) and (Row <= High(FSideRows)) then
      Result := Max(FSideRows[Row].Left, FSideRows[Row].Right);
  end
  else if (Row >= 0) and (Row <= High(FDiff)) then
    Result := Row;
end;

function TClaudeDiffForm.RowHunk(Row: Integer): Integer;
var
  D: Integer;
begin
  D := RowDiffIndex(Row);
  if D >= 0 then
    Result := FHunkOf[D]
  else
    Result := -1;
end;

procedure TClaudeDiffForm.ToggleHunk(Hunk: Integer);
begin
  if (Hunk < 0) or (Hunk > High(FAccepted)) then
    Exit;
  FAccepted[Hunk] := not FAccepted[Hunk];
  UpdateInfo;
  FList.Invalidate;
end;

{ Moves the selection to the next (Delta > 0), previous (Delta < 0) or first (0) change. }
procedure TClaudeDiffForm.GotoHunk(Delta: Integer);
var
  Row, Start, Current: Integer;
begin
  if FList.Count = 0 then
    Exit;
  Current := RowHunk(FList.ItemIndex);
  if Delta = 0 then
    Start := 0
  else
    Start := FList.ItemIndex + Delta;
  Row := Start;
  while (Row >= 0) and (Row < FList.Count) do
  begin
    if (RowHunk(Row) >= 0) and ((Delta = 0) or (RowHunk(Row) <> Current)) then
    begin
      // Land on the first row of that hunk.
      while (Row > 0) and (RowHunk(Row - 1) = RowHunk(Row)) do
        Dec(Row);
      FList.ItemIndex := Row;
      FList.TopIndex := Max(0, Row - 3);
      Exit;
    end;
    if Delta < 0 then
      Dec(Row)
    else
      Inc(Row);
  end;
end;

procedure TClaudeDiffForm.DrawLine(C: TCanvas; const R: TRect; DiffIndex: Integer; ShowNumbers: Boolean;
  Selected: Boolean);
const
  Prefix: array[TDiffKind] of Char = (' ', '-', '+');
var
  L: TDiffLine;
  Bg, Fg, Strong: TColor;
  Dark, Skipped: Boolean;
  Text, Head, Mark: string;
  X, Hunk: Integer;
  InA, InB, Mine: TInlineRange;
begin
  Bg := StyleServices(FList).GetSystemColor(clWindow);
  Fg := StyleServices(FList).GetSystemColor(clWindowText);
  Dark := IsDarkColor(Bg);
  C.Brush.Color := Bg;
  C.FillRect(R);
  if DiffIndex < 0 then
    Exit; // empty side of a side-by-side row
  L := FDiff[DiffIndex];
  Hunk := FHunkOf[DiffIndex];
  Skipped := (Hunk >= 0) and not FAccepted[Hunk];
  Strong := Bg;
  case L.Kind of
    dkDelete:
      if Dark then begin Bg := $002A2A5A; Strong := $00303088; end
      else begin Bg := $00DCDCFF; Strong := $00AAAAFF; end;
    dkInsert:
      if Dark then begin Bg := $00284A28; Strong := $00307A30; end
      else begin Bg := $00D8F5D8; Strong := $0090E090; end;
  end;
  if Skipped then
  begin
    Bg := StyleServices(FList).GetSystemColor(clBtnFace);
    Strong := Bg;
    Fg := StyleServices(FList).GetSystemColor(clGrayText);
  end;
  if Selected then
  begin
    Bg := StyleServices(FList).GetSystemColor(clHighlight);
    Strong := Bg;
    Fg := StyleServices(FList).GetSystemColor(clHighlightText);
  end;
  C.Brush.Color := Bg;
  C.FillRect(R);
  C.Font.Color := Fg;
  if (L.Kind = dkInsert) and Skipped then
    C.Font.Style := [fsStrikeOut]
  else
    C.Font.Style := [];

  // Gutter: line numbers, the take/skip mark on the first line of a change, and +/-.
  Mark := ' ';
  if (Hunk >= 0) and (DiffIndex = FHunks[Hunk].First) then
    if Skipped then Mark := 'x' else Mark := '>';
  if ShowNumbers then
  begin
    Head := '';
    if L.OldLine > 0 then Head := IntToStr(L.OldLine);
    Head := Format('%5s ', [Head]);
    if L.NewLine > 0 then Head := Head + Format('%5d ', [L.NewLine]) else Head := Head + '      ';
  end
  else if L.Kind = dkInsert then
    Head := Format('%5d ', [L.NewLine])
  else
    Head := Format('%5d ', [L.OldLine]);
  Head := Head + Mark + Prefix[L.Kind] + ' ';
  X := R.Left + 2;
  C.TextOut(X, R.Top + 1, Head);
  Inc(X, C.TextWidth(Head));

  Text := ExpandTabs(L.Text);
  if (L.Kind <> dkEqual) and (FPair[DiffIndex] >= 0) and not Skipped and not Selected then
  begin
    // Highlight the part of the line that differs from its counterpart.
    if L.Kind = dkDelete then
      InlineChange(Text, ExpandTabs(FDiff[FPair[DiffIndex]].Text), InA, InB)
    else
      InlineChange(ExpandTabs(FDiff[FPair[DiffIndex]].Text), Text, InB, InA);
    Mine := InA;
    C.TextOut(X, R.Top + 1, Copy(Text, 1, Mine.Start - 1));
    Inc(X, C.TextWidth(Copy(Text, 1, Mine.Start - 1)));
    C.Brush.Color := Strong;
    C.TextOut(X, R.Top + 1, Copy(Text, Mine.Start, Mine.Len));
    Inc(X, C.TextWidth(Copy(Text, Mine.Start, Mine.Len)));
    C.Brush.Color := Bg;
    C.TextOut(X, R.Top + 1, Copy(Text, Mine.Start + Mine.Len, MaxInt));
  end
  else
    C.TextOut(X, R.Top + 1, Text);
  C.Font.Style := [];
end;

procedure TClaudeDiffForm.ListDrawItem(Control: TWinControl; Index: Integer; Rect: TRect;
  State: TOwnerDrawState);
var
  C: TCanvas;
  Half: TRect;
  Mid: Integer;
  Clip: HRGN;
begin
  C := FList.Canvas;
  if not FSideBySide then
  begin
    if (Index >= 0) and (Index <= High(FDiff)) then
      DrawLine(C, Rect, Index, True, odSelected in State);
    Exit;
  end;
  if (Index < 0) or (Index > High(FSideRows)) then
    Exit;
  Mid := (Rect.Left + Rect.Right) div 2;
  Half := Rect;
  Half.Right := Mid - 1;
  Clip := CreateRectRgn(Half.Left, Half.Top, Half.Right, Half.Bottom);
  try
    SelectClipRgn(C.Handle, Clip);
    DrawLine(C, Half, FSideRows[Index].Left, False, odSelected in State);
  finally
    SelectClipRgn(C.Handle, 0);
    DeleteObject(Clip);
  end;
  Half := Rect;
  Half.Left := Mid + 1;
  Clip := CreateRectRgn(Half.Left, Half.Top, Half.Right, Half.Bottom);
  try
    SelectClipRgn(C.Handle, Clip);
    DrawLine(C, Half, FSideRows[Index].Right, False, odSelected in State);
  finally
    SelectClipRgn(C.Handle, 0);
    DeleteObject(Clip);
  end;
  C.Pen.Color := StyleServices(FList).GetSystemColor(clBtnShadow);
  C.MoveTo(Mid, Rect.Top);
  C.LineTo(Mid, Rect.Bottom);
end;

procedure TClaudeDiffForm.ListDblClick(Sender: TObject);
begin
  ToggleHunk(RowHunk(FList.ItemIndex));
end;

procedure TClaudeDiffForm.ListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Shift <> [] then
    Exit;
  case Key of
    VK_SPACE:
      begin
        ToggleHunk(RowHunk(FList.ItemIndex));
        Key := 0;
      end;
    Ord('N'):
      begin
        GotoHunk(1);
        Key := 0;
      end;
    Ord('P'):
      begin
        GotoHunk(-1);
        Key := 0;
      end;
  end;
end;

procedure TClaudeDiffForm.SideBoxClick(Sender: TObject);
var
  D: Integer;
  Row: Integer;
begin
  if FSideBySide = FSideBox.Checked then
    Exit;
  D := RowDiffIndex(FList.ItemIndex);
  FSideBySide := FSideBox.Checked;
  GSideBySide := FSideBySide;
  if FSideBySide then
  begin
    FList.Count := Length(FSideRows);
    FList.ScrollWidth := 0;
  end
  else
    FList.Count := Length(FDiff);
  // Keep the selected line in view.
  if D >= 0 then
    for Row := 0 to FList.Count - 1 do
      if RowDiffIndex(Row) = D then
      begin
        FList.ItemIndex := Row;
        FList.TopIndex := Max(0, Row - 3);
        Break;
      end;
  FList.Invalidate;
end;

function TClaudeDiffForm.ProposedText: string;
var
  LineBreak: string;
begin
  if not FMemoEdited then
    Exit(FNewText);
  if Pos(#13#10, FNewText) > 0 then
    LineBreak := #13#10
  else
    LineBreak := #10;
  Result := StringReplace(FMemo.Lines.Text, #13#10, LineBreak, [rfReplaceAll]);
  // TStrings.Text always ends with a line break; keep the original convention.
  if (FNewText <> '') and not CharInSet(FNewText[Length(FNewText)], [#10, #13]) and
     Result.EndsWith(LineBreak) then
    SetLength(Result, Length(Result) - Length(LineBreak));
end;

function TClaudeDiffForm.FinalText: string;
var
  Proposed, LineBreak: string;
begin
  Proposed := ProposedText;
  if AcceptedCount = Length(FHunks) then
    Exit(Proposed); // exactly what was proposed (and edited)
  if Pos(#13#10, Proposed) > 0 then
    LineBreak := #13#10
  else if (Proposed = '') and (Pos(#13#10, FOldText) > 0) then
    LineBreak := #13#10
  else
    LineBreak := #10;
  Result := ApplyHunks(FDiff, FHunks, FAccepted, LineBreak,
    (Proposed <> '') and CharInSet(Proposed[Length(Proposed)], [#10, #13]));
end;

procedure TClaudeDiffForm.MemoChange(Sender: TObject);
begin
  FMemoEdited := True;
  FDiffStale := True;
end;

procedure TClaudeDiffForm.PagesChange(Sender: TObject);
begin
  if FPages.ActivePageIndex = 1 then
  begin
    // Show what Accept would write: skipped changes are not in the editable text.
    if AcceptedCount < Length(FHunks) then
    begin
      FMemo.OnChange := nil;
      try
        FMemo.Lines.Text := FinalText;
      finally
        FMemo.OnChange := MemoChange;
      end;
      FMemoEdited := True;
      FDiffStale := True;
    end;
  end
  else if FDiffStale then
    RebuildDiff;
end;

procedure TClaudeDiffForm.Decide(D: TDiffDecision);
var
  Proc: TDiffDecisionProc;
  Text: string;
begin
  if FDecided then
    Exit;
  FDecided := True;
  Proc := FOnDecision;
  FOnDecision := nil;
  if Assigned(Proc) then
  begin
    if D = ddAccepted then
      Text := FinalText;
    Proc(D, Text);
  end;
end;

procedure TClaudeDiffForm.AcceptClick(Sender: TObject);
begin
  if FDiffStale then
    RebuildDiff;
  // Taking none of the changes is a rejection.
  if (Length(FHunks) > 0) and (AcceptedCount = 0) then
    Decide(ddRejected)
  else
    Decide(ddAccepted);
  Close;
end;

procedure TClaudeDiffForm.RejectClick(Sender: TObject);
begin
  Reject;
end;

procedure TClaudeDiffForm.Reject;
begin
  Decide(ddRejected);
  Close;
end;

procedure TClaudeDiffForm.FormCloseEvent(Sender: TObject; var Action: TCloseAction);
begin
  Decide(ddRejected);
  Action := caFree;
end;

procedure TClaudeDiffForm.FormKeyDownEvent(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_RETURN) and (ssCtrl in Shift) then
  begin
    Key := 0;
    AcceptClick(nil);
  end
  else if (Key = VK_ESCAPE) and (Shift = []) then
  begin
    Key := 0;
    Reject;
  end;
end;

procedure TClaudeDiffForm.ShowAndActivate;
var
  Info: TFlashWInfo;
begin
  Show;
  if WindowState = wsMinimized then
    WindowState := wsNormal;
  BringToFront;
  if not SetForegroundWindow(Handle) then
  begin
    Info.cbSize := SizeOf(Info);
    Info.hwnd := Handle;
    Info.dwFlags := FLASHW_ALL or FLASHW_TIMERNOFG;
    Info.uCount := 5;
    Info.dwTimeout := 0;
    FlashWindowEx(Info);
  end;
  FList.SetFocus;
end;

initialization
  GForms := TList<TClaudeDiffForm>.Create;

finalization
  DestroyAllDiffForms;
  FreeAndNil(GForms);

end.
