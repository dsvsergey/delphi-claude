unit ClaudeCode.DiffForm;

{ Non-modal window showing Claude's proposed change as a coloured line diff.
  The proposed text can be edited before accepting. The decision callback is
  invoked exactly once (accept, reject, or window closed). }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, ClaudeCode.Diff;

type
  TDiffDecision = (ddAccepted, ddRejected);
  TDiffDecisionProc = reference to procedure(Decision: TDiffDecision; const FinalContents: string);

  TClaudeDiffForm = class(TForm)
  private
    FTabName: string;
    FFilePath: string;
    FOldText: string;
    FNewText: string;
    FDiff: TDiffLines;
    FDecided: Boolean;
    FOnDecision: TDiffDecisionProc;
    FMemoEdited: Boolean;
    FDiffStale: Boolean;
    FInfo: TLabel;
    FPages: TPageControl;
    FList: TListBox;
    FMemo: TMemo;
    procedure BuildUI;
    procedure RebuildDiff;
    procedure ListDrawItem(Control: TWinControl; Index: Integer; Rect: TRect; State: TOwnerDrawState);
    procedure AcceptClick(Sender: TObject);
    procedure RejectClick(Sender: TObject);
    procedure FormCloseEvent(Sender: TObject; var Action: TCloseAction);
    procedure FormKeyDownEvent(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PagesChange(Sender: TObject);
    procedure MemoChange(Sender: TObject);
    function CurrentNewText: string;
    procedure Decide(D: TDiffDecision);
  public
    constructor CreateDiff(const ATabName, AFilePath, AOldText, ANewText: string;
      const OnDecision: TDiffDecisionProc);
    destructor Destroy; override;
    procedure ShowAndActivate;
    procedure Reject;
    property TabName: string read FTabName;
    property Decided: Boolean read FDecided;
  end;

function FindDiffForm(const TabName: string): TClaudeDiffForm;
function CloseAllDiffForms: Integer;
procedure DestroyAllDiffForms;

implementation

uses
  Vcl.Themes;

var
  GForms: TList<TClaudeDiffForm>;

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
  Width := 1100;
  Height := 750;
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
  FInfo := TLabel.Create(Self);
  FInfo.Parent := Top;
  FInfo.AlignWithMargins := True;
  FInfo.Margins.SetBounds(8, 8, 8, 4);
  FInfo.Align := alClient;

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
  Hint.Caption := 'You can also answer in the Claude Code terminal. Edits made on the "Proposed" tab are kept on Accept.';

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
  Added, Removed, I, MaxLen: Integer;
begin
  FDiff := ComputeLineDiff(SplitLines(FOldText), SplitLines(CurrentNewText));
  CountChanges(FDiff, Added, Removed);
  if FOldText = '' then
    FInfo.Caption := Format('%s   (new file)   +%d lines', [FFilePath, Added])
  else
    FInfo.Caption := Format('%s   +%d / -%d lines', [FFilePath, Added, Removed]);
  MaxLen := 0;
  for I := 0 to High(FDiff) do
    if Length(FDiff[I].Text) > MaxLen then
      MaxLen := Length(FDiff[I].Text);
  FList.Count := Length(FDiff);
  FList.ScrollWidth := (MaxLen + 20) * FList.Canvas.TextWidth('W');
  // Jump to the first change.
  for I := 0 to High(FDiff) do
    if FDiff[I].Kind <> dkEqual then
    begin
      FList.TopIndex := I - 3;
      Break;
    end;
  FList.Invalidate;
  FDiffStale := False;
end;

procedure TClaudeDiffForm.ListDrawItem(Control: TWinControl; Index: Integer; Rect: TRect;
  State: TOwnerDrawState);
const
  Prefix: array[TDiffKind] of Char = (' ', '-', '+');
var
  C: TCanvas;
  L: TDiffLine;
  Bg, Fg: TColor;
  Dark: Boolean;
  S, OldNo, NewNo: string;
begin
  if (Index < 0) or (Index > High(FDiff)) then
    Exit;
  C := FList.Canvas;
  L := FDiff[Index];
  Bg := StyleServices(FList).GetSystemColor(clWindow);
  Fg := StyleServices(FList).GetSystemColor(clWindowText);
  Dark := IsDarkColor(Bg);
  case L.Kind of
    dkDelete:
      if Dark then Bg := $002A2A5A else Bg := $00DCDCFF;
    dkInsert:
      if Dark then Bg := $00284A28 else Bg := $00D8F5D8;
  end;
  if odSelected in State then
  begin
    Bg := StyleServices(FList).GetSystemColor(clHighlight);
    Fg := StyleServices(FList).GetSystemColor(clHighlightText);
  end;
  C.Brush.Color := Bg;
  C.Font.Color := Fg;
  C.FillRect(Rect);
  if L.OldLine > 0 then OldNo := IntToStr(L.OldLine) else OldNo := '';
  if L.NewLine > 0 then NewNo := IntToStr(L.NewLine) else NewNo := '';
  S := Format('%5s %5s %s ', [OldNo, NewNo, Prefix[L.Kind]]) +
    StringReplace(L.Text, #9, '  ', [rfReplaceAll]);
  C.TextOut(Rect.Left + 2, Rect.Top + 1, S);
end;

function TClaudeDiffForm.CurrentNewText: string;
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

procedure TClaudeDiffForm.MemoChange(Sender: TObject);
begin
  FMemoEdited := True;
  FDiffStale := True;
end;

procedure TClaudeDiffForm.PagesChange(Sender: TObject);
begin
  if FDiffStale and (FPages.ActivePageIndex = 0) then
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
      Text := CurrentNewText;
    Proc(D, Text);
  end;
end;

procedure TClaudeDiffForm.AcceptClick(Sender: TObject);
begin
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
