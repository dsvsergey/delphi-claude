unit ClaudeCode.InlineDiff;

{ Claude's proposed change reviewed in the code editor itself instead of the diff window.
  The proposal goes into the editor buffer as one undoable edit. Lines it adds or changes get a
  green background, places where it removed lines a red marker; what is highlighted is always
  diff(original, current buffer), so the user can edit the proposal freely while reviewing.
  A bar above the editor steps through the changes, undoes one change, accepts or rejects all:
    Ctrl+Alt+PgDn / PgUp  next / previous change      Ctrl+Alt+Z  undo the current change
    Ctrl+Alt+Enter        accept all                   Ctrl+Alt+Backspace  reject all
  Accept saves the file and answers Claude with the final text (Claude then writes the same text);
  Reject puts the original text back. }

interface

uses
  System.SysUtils, System.Classes, ToolsAPI;

type
  TInlineDecision = reference to procedure(Accepted: Boolean; const FinalContents: string);

{ Starts reviewing NewText for FileName in the editor. False (nothing done) when the file cannot be
  reviewed there: not a plain source file, not on disk, or open with unsaved changes. }
function StartInlineReview(const TabName, FileName, NewText: string; const OnDecision: TInlineDecision): Boolean;
{ Rejects the review of that tab; False when there is none. }
function RejectInlineReview(const TabName: string): Boolean;
function RejectAllInlineReviews: Integer;
{ Package unload: ends reviews without answering and removes the editor hooks. }
procedure ShutdownInlineReviews;

implementation

{$IF CompilerVersion >= 35.0} // the code editor API (ToolsAPI.Editor) is Delphi 11 and later

uses
  Winapi.Windows, System.Types, System.Math, System.Generics.Collections, System.UITypes, Vcl.Graphics,
  Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.Forms, ToolsAPI.Editor,
  ClaudeCode.Utils, ClaudeCode.Diff, ClaudeCode.TextSync, ClaudeCode.IdeBackend;

type
  THunkInfo = record
    NewFirst, NewLast: Integer; // 1-based buffer lines of the added/changed lines; NewLast < NewFirst: none
    Anchor: Integer;            // buffer line before which removed lines are marked
    Removed: TArray<string>;
    Added: Integer;
  end;

  TInlineReview = class
  private
    FTabName: string;
    FFileName: string;
    FOriginal: string;
    FOnDecision: TInlineDecision;
    FTimer: TTimer;
    FLastText: string;
    FHunks: TArray<THunkInfo>;
    FAddedLines: TDictionary<Integer, Integer>; // line -> hunk
    FMarkers: TDictionary<Integer, Integer>;    // anchor line -> hunk with removed lines
    FCurrent: Integer;
    FBar: TPanel;
    FBarInfo: TLabel;
    FBarRemoved: TLabel;
    FDone: Boolean;
    procedure Tick(Sender: TObject);
    procedure Recompute(const Text: string);
    procedure BuildBar;
    procedure UpdateBar;
    procedure Invalidate;
    procedure GotoHunk(Index: Integer);
    procedure Finish(Accepted: Boolean);
    function Buffer: IOTAEditBuffer;
    procedure PrevClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure UndoClick(Sender: TObject);
    procedure AcceptClick(Sender: TObject);
    procedure RejectClick(Sender: TObject);
  public
    constructor Create(const ATabName, AFileName, AOriginal: string; const AOnDecision: TInlineDecision);
    destructor Destroy; override;
    procedure Start;
    procedure Accept;
    procedure Reject;
    procedure UndoCurrentHunk;
    procedure Step(Delta: Integer);
    function HunkAtLine(Line: Integer): Integer;
    property FileName: string read FFileName;
    property TabName: string read FTabName;
  end;

  TInlinePainter = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
    function AllowedLineStages: TPaintLineStages; override;
  public
    constructor Create;
    procedure DoPaintLine(const Rect: TRect; const Stage: TPaintLineStage; const BeforeEvent: Boolean;
      var AllowDefaultPainting: Boolean; const Context: INTACodeEditorPaintContext);
    procedure DoKeyDown(const Editor: TWinControl; Key: Word; Shift: TShiftState; var Handled: Boolean);
  end;

var
  Reviews: TObjectList<TInlineReview>;
  PainterIndex: Integer = -1;

function EditorServices2: INTACodeEditorServices;
begin
  if not Supports(BorlandIDEServices, INTACodeEditorServices, Result) then
    Result := nil;
end;

function ReviewFor(const FileName: string): TInlineReview;
var
  R: TInlineReview;
begin
  if Reviews <> nil then
    for R in Reviews do
      if SameFileName(R.FileName, FileName) then
        Exit(R);
  Result := nil;
end;

procedure EnsurePainter;
var
  S: INTACodeEditorServices;
begin
  S := EditorServices2;
  if (PainterIndex < 0) and (S <> nil) then
    PainterIndex := S.AddEditorEventsNotifier(TInlinePainter.Create);
end;

procedure RemovePainterIfIdle;
var
  S: INTACodeEditorServices;
begin
  if (PainterIndex >= 0) and ((Reviews = nil) or (Reviews.Count = 0)) then
  begin
    S := EditorServices2;
    if S <> nil then
      S.RemoveEditorEventsNotifier(PainterIndex);
    PainterIndex := -1;
  end;
end;

function Blend(Base, Tint: TColor; Percent: Integer): TColor;
var
  B, T: Integer;
begin
  B := ColorToRGB(Base);
  T := ColorToRGB(Tint);
  Result := RGB(
    (GetRValue(B) * (100 - Percent) + GetRValue(T) * Percent) div 100,
    (GetGValue(B) * (100 - Percent) + GetGValue(T) * Percent) div 100,
    (GetBValue(B) * (100 - Percent) + GetBValue(T) * Percent) div 100);
end;

function EditorBackground: TColor;
var
  S: INTACodeEditorServices;
begin
  Result := clWindow;
  S := EditorServices2;
  if (S <> nil) and (S.Options <> nil) then
    Result := S.Options.BackgroundColor[atWhiteSpace];
end;

const
  ADDED_TINT = $4EA02E;   // green (BGR of #2EA04E)
  REMOVED_TINT = $4951F8; // red (BGR of #F85149)
  CURRENT_TINT = $C8640A; // blue (BGR of #0A64C8)

{ TInlinePainter }

constructor TInlinePainter.Create;
begin
  inherited Create;
  OnEditorPaintLine := DoPaintLine;
  OnEditorKeyDown := DoKeyDown;
end;

function TInlinePainter.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevPaintLineEvents, cevKeyboardEvents];
end;

function TInlinePainter.AllowedLineStages: TPaintLineStages;
begin
  Result := [plsBackground, plsEndPaint];
end;

procedure TInlinePainter.DoPaintLine(const Rect: TRect; const Stage: TPaintLineStage; const BeforeEvent: Boolean;
  var AllowDefaultPainting: Boolean; const Context: INTACodeEditorPaintContext);
var
  R: TInlineReview;
  Line, Hunk: Integer;
  C: TCanvas;
  Bg: TColor;
  M: TRect;
begin
  R := ReviewFor(Context.FileName);
  if R = nil then
    Exit;
  Line := Context.LogicalLineNum;
  C := Context.Canvas;
  if (Stage = plsBackground) and BeforeEvent then
  begin
    Hunk := -1;
    if R.FAddedLines.TryGetValue(Line, Hunk) then
    begin
      Bg := EditorBackground;
      if Hunk = R.FCurrent then
        C.Brush.Color := Blend(Bg, ADDED_TINT, 30)
      else
        C.Brush.Color := Blend(Bg, ADDED_TINT, 17);
      C.FillRect(Rect);
      AllowDefaultPainting := False;
    end;
  end
  else if (Stage = plsEndPaint) and not BeforeEvent then
  begin
    // Removed lines: a red line where they were, and a mark at the left edge of the code.
    if R.FMarkers.TryGetValue(Line, Hunk) then
    begin
      C.Pen.Color := REMOVED_TINT;
      C.Brush.Color := REMOVED_TINT;
      M := System.Types.Rect(Rect.Left, Rect.Top, Rect.Right, Rect.Top + 2);
      C.FillRect(M);
      C.Polygon([Point(Rect.Left, Rect.Top - 4), Point(Rect.Left + 6, Rect.Top + 1), Point(Rect.Left, Rect.Top + 6)]);
    end;
    // The current change: a bar at the left edge.
    if R.FAddedLines.TryGetValue(Line, Hunk) and (Hunk = R.FCurrent) then
    begin
      C.Brush.Color := CURRENT_TINT;
      C.FillRect(System.Types.Rect(Rect.Left, Rect.Top, Rect.Left + 3, Rect.Bottom));
    end;
  end;
end;

procedure TInlinePainter.DoKeyDown(const Editor: TWinControl; Key: Word; Shift: TShiftState; var Handled: Boolean);
var
  S: INTACodeEditorServices;
  View: IOTAEditView;
  R: TInlineReview;
begin
  if Shift * [ssCtrl, ssAlt, ssShift] <> [ssCtrl, ssAlt] then
    Exit;
  S := EditorServices2;
  if S = nil then
    Exit;
  View := S.GetViewForEditor(Editor);
  if (View = nil) or (View.Buffer = nil) then
    Exit;
  R := ReviewFor(View.Buffer.FileName);
  if R = nil then
    Exit;
  Handled := True;
  case Key of
    VK_NEXT: R.Step(1);
    VK_PRIOR: R.Step(-1);
    Ord('Z'): R.UndoCurrentHunk;
    VK_RETURN: TThread.ForceQueue(nil, procedure begin R.Accept; end);
    VK_BACK: TThread.ForceQueue(nil, procedure begin R.Reject; end);
  else
    Handled := False;
  end;
end;

{ TInlineReview }

constructor TInlineReview.Create(const ATabName, AFileName, AOriginal: string; const AOnDecision: TInlineDecision);
begin
  inherited Create;
  FTabName := ATabName;
  FFileName := AFileName;
  FOriginal := AOriginal;
  FOnDecision := AOnDecision;
  FAddedLines := TDictionary<Integer, Integer>.Create;
  FMarkers := TDictionary<Integer, Integer>.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := 300;
  FTimer.OnTimer := Tick;
end;

destructor TInlineReview.Destroy;
begin
  FTimer.Free;
  FBar.Free;
  FMarkers.Free;
  FAddedLines.Free;
  inherited;
end;

function TInlineReview.Buffer: IOTAEditBuffer;
begin
  Result := FindEditBuffer(FFileName);
end;

procedure TInlineReview.Start;
begin
  BuildBar;
  Recompute(ReadBufferText(Buffer));
  if Length(FHunks) > 0 then
    GotoHunk(0);
  FTimer.Enabled := True;
end;

procedure TInlineReview.Recompute(const Text: string);
var
  Diff: TDiffLines;
  Hunks: TArray<THunk>;
  I, K: Integer;
  H: THunkInfo;
begin
  FLastText := Text;
  Diff := ComputeLineDiff(SplitLines(FOriginal), SplitLines(Text));
  Hunks := FindHunks(Diff);
  FAddedLines.Clear;
  FMarkers.Clear;
  SetLength(FHunks, Length(Hunks));
  for I := 0 to High(Hunks) do
  begin
    H := Default(THunkInfo);
    H.NewFirst := MaxInt;
    H.NewLast := -1;
    H.Anchor := -1;
    for K := Hunks[I].First to Hunks[I].Last do
      if Diff[K].Kind = dkInsert then
      begin
        H.NewFirst := Min(H.NewFirst, Diff[K].NewLine);
        H.NewLast := Max(H.NewLast, Diff[K].NewLine);
        Inc(H.Added);
        FAddedLines.AddOrSetValue(Diff[K].NewLine, I);
      end
      else if Diff[K].Kind = dkDelete then
        H.Removed := H.Removed + [Diff[K].Text];
    if Length(H.Removed) > 0 then
    begin
      // Removed lines are marked at the first line after the hunk's old position.
      if H.NewLast >= 0 then
        H.Anchor := H.NewFirst
      else if Hunks[I].Last + 1 <= High(Diff) then
        H.Anchor := Diff[Hunks[I].Last + 1].NewLine
      else if Hunks[I].First > 0 then
        H.Anchor := Diff[Hunks[I].First - 1].NewLine + 1;
      if H.Anchor > 0 then
        FMarkers.AddOrSetValue(H.Anchor, I);
    end;
    if H.NewLast < 0 then
    begin
      H.NewFirst := Max(H.Anchor, 1);
      H.NewLast := H.NewFirst - 1;
    end;
    FHunks[I] := H;
  end;
  if FCurrent > High(FHunks) then
    FCurrent := High(FHunks);
  if FCurrent < 0 then
    FCurrent := 0;
  UpdateBar;
  Invalidate;
end;

procedure TInlineReview.Tick(Sender: TObject);
var
  B: IOTAEditBuffer;
  Text: string;
begin
  if FDone then
    Exit;
  B := Buffer;
  if B = nil then
  begin
    // The user closed the file: that is a rejection of what was not saved.
    FTimer.Enabled := False;
    Log('Inline review: ' + ExtractFileName(FFileName) + ' was closed; rejected');
    TThread.ForceQueue(nil, procedure begin Finish(False); end);
    Exit;
  end;
  Text := ReadBufferText(B);
  if Text <> FLastText then
    Recompute(Text);
end;

procedure TInlineReview.Invalidate;
var
  S: INTACodeEditorServices;
  B: IOTAEditBuffer;
  Ed: TWinControl;
begin
  S := EditorServices2;
  B := Buffer;
  if (S = nil) or (B = nil) or (B.TopView = nil) then
    Exit;
  Ed := S.GetEditorForView(B.TopView);
  if Ed <> nil then
    S.InvalidateEditor(Ed);
end;

procedure TInlineReview.BuildBar;
var
  S: INTACodeEditorServices;
  B: IOTAEditBuffer;
  Ed: TWinControl;
  Buttons: TPanel;
  Bg: TColor;

  procedure Btn(const ACaption, AHint: string; AWidth: Integer; OnClick: TNotifyEvent);
  var
    X: TButton;
  begin
    X := TButton.Create(FBar);
    X.Parent := Buttons;
    X.Caption := ACaption;
    X.Hint := AHint;
    X.ShowHint := True;
    X.Width := AWidth;
    X.Align := alRight;
    X.AlignWithMargins := True;
    X.Margins.SetBounds(2, 3, 2, 3);
    X.OnClick := OnClick;
  end;

begin
  S := EditorServices2;
  B := Buffer;
  if (S = nil) or (B = nil) or (B.TopView = nil) then
    Exit;
  Ed := S.GetEditorForView(B.TopView);
  if (Ed = nil) or (Ed.Parent = nil) then
    Exit;
  Bg := EditorBackground;
  FBar := TPanel.Create(nil);
  FBar.Parent := Ed.Parent;
  FBar.Align := alTop;
  FBar.Top := Ed.Top - 1;
  FBar.Height := 58;
  FBar.BevelOuter := bvNone;
  FBar.ParentBackground := False;
  FBar.Color := Blend(Bg, CURRENT_TINT, 18);
  Buttons := TPanel.Create(FBar);
  Buttons.Parent := FBar;
  Buttons.Align := alRight;
  Buttons.Width := 560;
  Buttons.BevelOuter := bvNone;
  Buttons.ParentBackground := False;
  Buttons.ParentColor := True;
  Btn('Reject all', 'Ctrl+Alt+Backspace: put the original text back and tell Claude', 80, RejectClick);
  Btn('Accept all', 'Ctrl+Alt+Enter: save the file as it is now and tell Claude', 80, AcceptClick);
  Btn('Undo this change', 'Ctrl+Alt+Z: put the current change back as it was', 120, UndoClick);
  Btn('Next', 'Ctrl+Alt+PgDn', 60, NextClick);
  Btn('Previous', 'Ctrl+Alt+PgUp', 70, PrevClick);
  FBarInfo := TLabel.Create(FBar);
  FBarInfo.Parent := FBar;
  FBarInfo.Align := alTop;
  FBarInfo.AlignWithMargins := True;
  FBarInfo.Margins.SetBounds(8, 6, 4, 0);
  FBarInfo.Font.Style := [fsBold];
  FBarRemoved := TLabel.Create(FBar);
  FBarRemoved.Parent := FBar;
  FBarRemoved.Align := alClient;
  FBarRemoved.AlignWithMargins := True;
  FBarRemoved.Margins.SetBounds(8, 2, 4, 2);
  FBarRemoved.Font.Name := 'Consolas';
  FBarRemoved.EllipsisPosition := epEndEllipsis;
  FBarRemoved.ShowAccelChar := False;
end;

procedure TInlineReview.UpdateBar;
var
  H: THunkInfo;
  Added, Removed, I: Integer;
  S: string;
begin
  if FBar = nil then
    Exit;
  Added := 0;
  Removed := 0;
  for H in FHunks do
  begin
    Inc(Added, H.Added);
    Inc(Removed, Length(H.Removed));
  end;
  if Length(FHunks) = 0 then
  begin
    FBarInfo.Caption := Format('Claude''s proposal for %s: no differences left. Accept to save, Reject to ' +
      'restore the original.', [ExtractFileName(FFileName)]);
    FBarRemoved.Caption := '';
    Exit;
  end;
  FBarInfo.Caption := Format('Claude proposes %d change(s) to %s (+%d -%d). Change %d of %d. You can edit the ' +
    'text while reviewing.', [Length(FHunks), ExtractFileName(FFileName), Added, Removed, FCurrent + 1,
    Length(FHunks)]);
  H := FHunks[FCurrent];
  if Length(H.Removed) = 0 then
    S := 'This change only adds lines.'
  else
  begin
    S := 'Removed here: ';
    for I := 0 to Min(High(H.Removed), 2) do
      S := S + Trim(H.Removed[I]) + '  |  ';
    S := Copy(S, 1, Length(S) - 5);
    if Length(H.Removed) > 3 then
      S := S + Format('  (+%d more)', [Length(H.Removed) - 3]);
  end;
  FBarRemoved.Caption := S;
end;

procedure TInlineReview.GotoHunk(Index: Integer);
var
  B: IOTAEditBuffer;
  Line: Integer;
begin
  if Length(FHunks) = 0 then
    Exit;
  FCurrent := EnsureRange(Index, 0, High(FHunks));
  B := Buffer;
  if (B <> nil) and (B.TopView <> nil) then
  begin
    Line := Max(1, FHunks[FCurrent].NewFirst);
    B.TopView.Position.Move(Line, 1);
    B.TopView.Center(Line, 1);
    B.TopView.Paint;
  end;
  UpdateBar;
  Invalidate;
end;

procedure TInlineReview.Step(Delta: Integer);
begin
  if Length(FHunks) > 0 then
    GotoHunk((FCurrent + Delta + Length(FHunks)) mod Length(FHunks));
end;

function TInlineReview.HunkAtLine(Line: Integer): Integer;
begin
  if not FAddedLines.TryGetValue(Line, Result) then
    Result := -1;
end;

procedure TInlineReview.UndoCurrentHunk;
var
  Diff: TDiffLines;
  Hunks: TArray<THunk>;
  Accepted: TArray<Boolean>;
  B: IOTAEditBuffer;
  I: Integer;
  Text: string;
begin
  B := Buffer;
  if (B = nil) or (Length(FHunks) = 0) then
    Exit;
  Text := ReadBufferText(B);
  Diff := ComputeLineDiff(SplitLines(FOriginal), SplitLines(Text));
  Hunks := FindHunks(Diff);
  if FCurrent > High(Hunks) then
    Exit;
  SetLength(Accepted, Length(Hunks));
  for I := 0 to High(Accepted) do
    Accepted[I] := I <> FCurrent;
  if Pos(#13#10, Text) > 0 then
    Text := ApplyHunks(Diff, Hunks, Accepted, #13#10, Text.EndsWith(#10))
  else
    Text := ApplyHunks(Diff, Hunks, Accepted, #10, Text.EndsWith(#10));
  ReplaceBufferText(B, Text);
  Recompute(ReadBufferText(B));
  if Length(FHunks) > 0 then
    GotoHunk(FCurrent);
end;

procedure TInlineReview.Accept;
var
  B: IOTAEditBuffer;
  Module: IOTAModule;
  Final: string;
begin
  if FDone then
    Exit;
  B := Buffer;
  if B = nil then
  begin
    Finish(False);
    Exit;
  end;
  Final := ReadBufferText(B);
  // Saved by the IDE in the file's own encoding; Claude then writes the same text.
  Module := (BorlandIDEServices as IOTAModuleServices).FindModule(FFileName);
  if Module <> nil then
    Module.Save(False, True);
  FDone := True;
  FTimer.Enabled := False;
  if Assigned(FOnDecision) then
    FOnDecision(True, Final);
  FOnDecision := nil;
  Reviews.Remove(Self); // frees Self
  RemovePainterIfIdle;
end;

procedure TInlineReview.Reject;
begin
  Finish(False);
end;

procedure TInlineReview.Finish(Accepted: Boolean);
var
  B: IOTAEditBuffer;
  Module: IOTAModule;
begin
  if FDone then
    Exit;
  if Accepted then
  begin
    Accept;
    Exit;
  end;
  FDone := True;
  FTimer.Enabled := False;
  B := Buffer;
  if B <> nil then
  begin
    // Back to the text on disk (one more undoable edit), saved so the tab is not left modified.
    if ReplaceBufferText(B, FOriginal) then
    begin
      Module := (BorlandIDEServices as IOTAModuleServices).FindModule(FFileName);
      if Module <> nil then
        Module.Save(False, True);
    end;
  end;
  if Assigned(FOnDecision) then
    FOnDecision(False, '');
  FOnDecision := nil;
  Invalidate;
  Reviews.Remove(Self);
  RemovePainterIfIdle;
end;

procedure TInlineReview.PrevClick(Sender: TObject);
begin
  Step(-1);
end;

procedure TInlineReview.NextClick(Sender: TObject);
begin
  Step(1);
end;

procedure TInlineReview.UndoClick(Sender: TObject);
begin
  UndoCurrentHunk;
end;

procedure TInlineReview.AcceptClick(Sender: TObject);
var
  R: TInlineReview;
begin
  // The bar belongs to the review: end it after this click handler has returned.
  R := Self;
  TThread.ForceQueue(nil, procedure begin R.Accept; end);
end;

procedure TInlineReview.RejectClick(Sender: TObject);
var
  R: TInlineReview;
begin
  R := Self;
  TThread.ForceQueue(nil, procedure begin R.Reject; end);
end;

{ Public }

function ReviewableFile(const FileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  // Forms and project files belong to the designer/IDE; binary files cannot be shown.
  Result := (Ext <> '.dfm') and (Ext <> '.fmx') and (Ext <> '.lfm') and (Ext <> '.dproj') and
    (Ext <> '.groupproj') and (Ext <> '.res') and (Ext <> '.ico') and (Ext <> '.png') and (Ext <> '.bmp');
end;

function StartInlineReview(const TabName, FileName, NewText: string; const OnDecision: TInlineDecision): Boolean;
var
  B: IOTAEditBuffer;
  R: TInlineReview;
  Original, Proposed: string;
begin
  Result := False;
  if (EditorServices2 = nil) or not ReviewableFile(FileName) or not FileExists(FileName) or
     (ReviewFor(FileName) <> nil) then
    Exit;
  B := FindEditBuffer(FileName);
  if B = nil then
  begin
    (BorlandIDEServices as IOTAActionServices).OpenFile(FileName);
    B := FindEditBuffer(FileName);
  end;
  if (B = nil) or B.IsModified or B.IsReadOnly then
    Exit; // unsaved user edits: the diff window keeps them apart
  Original := ReadBufferText(B);
  // Keep the file's line breaks (an LF file stays LF).
  if Pos(#13#10, Original) > 0 then
    Proposed := NormalizeToCrLf(NewText)
  else
    Proposed := StringReplace(NormalizeToCrLf(NewText), #13#10, #10, [rfReplaceAll]);
  if Reviews = nil then
    Reviews := TObjectList<TInlineReview>.Create(True);
  B.Show;
  if not ReplaceBufferText(B, Proposed) then
    Exit; // nothing would change: let the diff window report it
  R := TInlineReview.Create(TabName, FileName, Original, OnDecision);
  Reviews.Add(R);
  EnsurePainter;
  R.Start;
  Log(Format('Inline review of %s: %d change(s)', [ExtractFileName(FileName), Length(R.FHunks)]));
  Result := True;
end;

function RejectInlineReview(const TabName: string): Boolean;
var
  R: TInlineReview;
begin
  Result := False;
  if Reviews = nil then
    Exit;
  for R in Reviews do
    if R.TabName = TabName then
    begin
      R.Reject;
      Exit(True);
    end;
end;

function RejectAllInlineReviews: Integer;
begin
  Result := 0;
  while (Reviews <> nil) and (Reviews.Count > 0) do
  begin
    Reviews.Last.Reject;
    Inc(Result);
  end;
end;

procedure ShutdownInlineReviews;
var
  R: TInlineReview;
begin
  if Reviews <> nil then
  begin
    for R in Reviews do
    begin
      R.FDone := True;
      R.FOnDecision := nil;
    end;
    Reviews.Clear;
  end;
  RemovePainterIfIdle;
  FreeAndNil(Reviews);
end;

{$ELSE}

// No code editor API: proposals always go to the diff window.

function StartInlineReview(const TabName, FileName, NewText: string; const OnDecision: TInlineDecision): Boolean;
begin
  Result := False;
end;

function RejectInlineReview(const TabName: string): Boolean;
begin
  Result := False;
end;

function RejectAllInlineReviews: Integer;
begin
  Result := 0;
end;

procedure ShutdownInlineReviews;
begin
end;

{$IFEND}

end.
