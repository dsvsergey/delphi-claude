unit ClaudeCode.TimelineForm;

{ Tools > Claude Code > Claude Timeline: Claude's turns with the files each one changed,
  their diffs, and rewinding the files to before a turn. Open editors are changed in place
  (one undoable edit, then saved), closed files get their exact old bytes back. }

interface

uses
  System.SysUtils, System.Classes, Vcl.Forms, ClaudeCode.Timeline;

procedure ShowTimeline(Timeline: TTimeline; HooksOn: Boolean; const BeforeShow: TProc<TForm>);
procedure DestroyTimelineWindow;
{ Writes the restore plan; returns a line per file. }
function ApplyRestorePlan(const Plan: TArray<TRestore>): string;

implementation

uses
  Winapi.Windows, System.IOUtils, System.UITypes, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.Dialogs, ToolsAPI, ClaudeCode.Utils, ClaudeCode.TextSync, ClaudeCode.IdeBackend, ClaudeCode.DiffForm;

type
  TTimelineForm = class(TForm)
  private
    FTimeline: TTimeline;
    FTurns: TListView;
    FFiles: TListView;
    FInfo: TLabel;
    FDiff, FRewind, FClear: TButton;
    procedure BuildUI;
    procedure Refresh;
    procedure ShowFiles;
    procedure TimelineChanged(Sender: TObject);
    procedure TurnsSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure DiffClick(Sender: TObject);
    procedure RewindClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    function SelectedTurn: Integer;
  public
    constructor CreateFor(ATimeline: TTimeline);
    destructor Destroy; override;
    procedure SetHooksInfo(HooksOn: Boolean);
  end;

var
  Instance: TTimelineForm;

procedure ShowTimeline(Timeline: TTimeline; HooksOn: Boolean; const BeforeShow: TProc<TForm>);
begin
  if Instance = nil then
  begin
    Instance := TTimelineForm.CreateFor(Timeline);
    if Assigned(BeforeShow) then
      BeforeShow(Instance);
  end;
  Instance.SetHooksInfo(HooksOn);
  Instance.Refresh;
  Instance.Show;
  Instance.BringToFront;
end;

procedure DestroyTimelineWindow;
begin
  FreeAndNil(Instance);
end;

function ApplyRestorePlan(const Plan: TArray<TRestore>): string;
var
  R: TRestore;
  Buffer: IOTAEditBuffer;
  Module: IOTAModule;
  Line: string;
begin
  Result := '';
  for R in Plan do
  begin
    try
      Buffer := FindEditBuffer(R.FileName);
      if R.Delete then
      begin
        if Buffer <> nil then
          Line := 'left open in the editor (it did not exist before; close and delete it if you want)'
        else if FileExists(R.FileName) then
        begin
          System.SysUtils.DeleteFile(R.FileName);
          Line := 'deleted (it did not exist before)';
        end
        else
          Line := 'already gone';
      end
      else if (Buffer <> nil) and not Buffer.IsReadOnly then
      begin
        // In the editor: one undoable change, saved in the file's own encoding.
        ReplaceBufferText(Buffer, NormalizeToCrLf(DecodeFileBytes(R.Bytes)));
        Module := (BorlandIDEServices as IOTAModuleServices).FindModule(R.FileName);
        if (Module <> nil) and Module.Save(False, True) then
          Line := 'restored in the editor and saved (Ctrl+Z undoes it)'
        else
          Line := 'restored in the editor (not saved)';
      end
      else
      begin
        ForceDirectories(ExtractFilePath(R.FileName));
        TFile.WriteAllBytes(R.FileName, R.Bytes);
        Line := 'restored';
      end;
    except
      on E: Exception do
        Line := 'FAILED: ' + E.Message;
    end;
    Result := Result + ExtractFileName(R.FileName) + ': ' + Line + sLineBreak;
  end;
end;

{ TTimelineForm }

constructor TTimelineForm.CreateFor(ATimeline: TTimeline);
begin
  CreateNew(Application);
  FTimeline := ATimeline;
  FTimeline.OnChanged := TimelineChanged;
  Caption := 'Claude Timeline';
  Width := 900;
  Height := 560;
  Position := poMainFormCenter;
  OnClose := FormClose;
  BuildUI;
end;

destructor TTimelineForm.Destroy;
begin
  if FTimeline <> nil then
    FTimeline.OnChanged := nil;
  inherited;
end;

procedure TTimelineForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caHide;
end;

procedure TTimelineForm.BuildUI;
var
  Bottom, Buttons: TPanel;
  Split: TSplitter;

  procedure Col(LV: TListView; const ACaption: string; AWidth: Integer);
  var
    C: TListColumn;
  begin
    C := LV.Columns.Add;
    C.Caption := ACaption;
    C.Width := AWidth;
  end;

  function Btn(const ACaption: string; AWidth: Integer; OnClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Buttons;
    Result.Caption := ACaption;
    Result.Width := AWidth;
    Result.Align := alLeft;
    Result.AlignWithMargins := True;
    Result.OnClick := OnClick;
  end;

begin
  FInfo := TLabel.Create(Self);
  FInfo.Parent := Self;
  FInfo.AutoSize := False; // a word-wrapped auto-sized label can take the whole form
  FInfo.Align := alTop;
  FInfo.Height := 36;
  FInfo.AlignWithMargins := True;
  FInfo.WordWrap := True;

  Buttons := TPanel.Create(Self);
  Buttons.Parent := Self;
  Buttons.Align := alBottom;
  Buttons.Top := 10000; // bottom-aligned controls are stacked by Top: the buttons go lowest
  Buttons.Height := 38;
  Buttons.BevelOuter := bvNone;
  FDiff := Btn('Show Diff', 100, DiffClick);
  FRewind := Btn('Rewind to Before This Turn...', 210, RewindClick);
  FClear := Btn('Clear', 80, ClearClick);

  Bottom := TPanel.Create(Self);
  Bottom.Parent := Self;
  Bottom.Align := alBottom;
  Bottom.Top := 5000;
  Bottom.Height := 180;
  Bottom.BevelOuter := bvNone;
  FFiles := TListView.Create(Self);
  FFiles.Parent := Bottom;
  FFiles.Align := alClient;
  FFiles.ViewStyle := vsReport;
  FFiles.ReadOnly := True;
  FFiles.RowSelect := True;
  FFiles.OnDblClick := DiffClick;
  Col(FFiles, 'File', 520);
  Col(FFiles, 'Change', 200);

  Split := TSplitter.Create(Self);
  Split.Parent := Self;
  Split.Align := alBottom;
  Split.Top := 4000;

  FTurns := TListView.Create(Self);
  FTurns.Parent := Self;
  FTurns.Align := alClient;
  FTurns.ViewStyle := vsReport;
  FTurns.ReadOnly := True;
  FTurns.RowSelect := True;
  FTurns.HideSelection := False;
  FTurns.OnSelectItem := TurnsSelect;
  Col(FTurns, '#', 40);
  Col(FTurns, 'Time', 80);
  Col(FTurns, 'Request', 560);
  Col(FTurns, 'Files', 60);
  Col(FTurns, 'Lines', 100);
end;

procedure TTimelineForm.SetHooksInfo(HooksOn: Boolean);
begin
  if HooksOn then
    FInfo.Caption := 'Each turn of Claude (a request and its work) with the files it changed. Select a turn to ' +
      'see its files; "Rewind" puts every file changed in that turn or later back as it was before it. ' +
      'Sessions started before the timeline was switched on are not recorded (start a new one).'
  else
    FInfo.Caption := 'The timeline is off: switch on "Record Claude''s turns" in Tools > Claude Code > Settings ' +
      'and start a new Claude session.';
end;

function TTimelineForm.SelectedTurn: Integer;
begin
  if FTurns.Selected = nil then
    Result := -1
  else
    Result := Integer(FTurns.Selected.Data);
end;

procedure TTimelineForm.TimelineChanged(Sender: TObject);
begin
  if Visible then
    Refresh;
end;

procedure TTimelineForm.Refresh;
var
  I, K, Added, Removed, A, R, Keep: Integer;
  T: TTurn;
  Item: TListItem;
  Prompt: string;
  F: TTurnFile;
  After: TBytes;
begin
  Keep := SelectedTurn;
  FTurns.Items.BeginUpdate;
  try
    FTurns.Items.Clear;
    for I := FTimeline.Count - 1 downto 0 do
    begin
      T := FTimeline.Turn(I);
      Item := FTurns.Items.Add;
      Item.Data := Pointer(I);
      Item.Caption := IntToStr(T.Id);
      Item.SubItems.Add(FormatDateTime('hh:nn:ss', T.Started));
      Prompt := StringReplace(StringReplace(T.Prompt, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]);
      if Prompt = '' then
        Prompt := '(request not recorded)';
      if T.Running then
        Prompt := '[working] ' + Prompt;
      Item.SubItems.Add(Prompt);
      Item.SubItems.Add(IntToStr(T.Files.Count));
      Added := 0;
      Removed := 0;
      for K := 0 to T.Files.Count - 1 do
      begin
        F := T.Files[K];
        if F.HasAfter then
          After := F.After
        else if not ReadFileBytes(F.FileName, After) then
          After := nil;
        LineChanges(F.Before, After, A, R);
        Inc(Added, A);
        Inc(Removed, R);
      end;
      Item.SubItems.Add(Format('+%d -%d', [Added, Removed]));
      if I = Keep then
        Item.Selected := True;
    end;
  finally
    FTurns.Items.EndUpdate;
  end;
  ShowFiles;
end;

procedure TTimelineForm.TurnsSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  ShowFiles;
end;

procedure TTimelineForm.ShowFiles;
var
  I, A, R: Integer;
  T: TTurn;
  F: TTurnFile;
  Item: TListItem;
  After: TBytes;
begin
  FFiles.Items.BeginUpdate;
  try
    FFiles.Items.Clear;
    if SelectedTurn < 0 then
      Exit;
    T := FTimeline.Turn(SelectedTurn);
    for I := 0 to T.Files.Count - 1 do
    begin
      F := T.Files[I];
      Item := FFiles.Items.Add;
      Item.Data := Pointer(I);
      Item.Caption := F.FileName;
      if F.HasAfter and not F.ExistsAfter then
        Item.SubItems.Add('deleted')
      else
      begin
        if F.HasAfter then
          After := F.After
        else if not ReadFileBytes(F.FileName, After) then
          After := nil;
        LineChanges(F.Before, After, A, R);
        if F.Existed then
          Item.SubItems.Add(Format('+%d -%d', [A, R]))
        else
          Item.SubItems.Add(Format('new, %d lines', [A]));
      end;
    end;
  finally
    FFiles.Items.EndUpdate;
  end;
  FRewind.Enabled := SelectedTurn >= 0;
  FDiff.Enabled := SelectedTurn >= 0;
end;

procedure TTimelineForm.DiffClick(Sender: TObject);
var
  T: TTurn;
  F: TTurnFile;
  After: TBytes;
  Form: TClaudeDiffForm;
begin
  if (SelectedTurn < 0) or (FFiles.Selected = nil) then
  begin
    if FFiles.Items.Count > 0 then
      FFiles.Items[0].Selected := True
    else
      Exit;
  end;
  T := FTimeline.Turn(SelectedTurn);
  F := T.Files[Integer(FFiles.Selected.Data)];
  if F.HasAfter then
    After := F.After
  else if not ReadFileBytes(F.FileName, After) then
    After := nil;
  // Review only: both buttons just close the window.
  Form := TClaudeDiffForm.CreateDiff(Format('turn %d: %s', [T.Id, ExtractFileName(F.FileName)]), F.FileName,
    DecodeFileBytes(F.Before), DecodeFileBytes(After),
    procedure(Decision: TDiffDecision; const FinalContents: string)
    begin
    end);
  Form.Note := Format('what turn %d changed (review only)', [T.Id]);
  Form.ShowAndActivate;
end;

procedure TTimelineForm.RewindClick(Sender: TObject);
var
  Index: Integer;
  Plan: TArray<TRestore>;
  R: TRestore;
  List, Report: string;
begin
  Index := SelectedTurn;
  if Index < 0 then
    Exit;
  Plan := FTimeline.RewindPlan(Index);
  if Length(Plan) = 0 then
  begin
    ShowMessage('This turn and the later ones did not change any files.');
    Exit;
  end;
  List := '';
  for R in Plan do
    List := List + '  ' + R.FileName + sLineBreak;
  if MessageDlg(Format('Put these %d file(s) back as they were before turn %d? Turns %d and later are removed ' +
    'from the timeline.' + sLineBreak + sLineBreak + '%s' + sLineBreak +
    'Claude''s conversation is not changed: tell it what you rewound (or use /rewind in Claude Code).',
    [Length(Plan), FTimeline.Turn(Index).Id, FTimeline.Turn(Index).Id, List]), mtConfirmation, [mbOK, mbCancel], 0) <> mrOk then
    Exit;
  Report := ApplyRestorePlan(Plan);
  FTimeline.DropFrom(Index);
  Log('Timeline rewind:' + sLineBreak + Report);
  ShowMessage(Report);
end;

procedure TTimelineForm.ClearClick(Sender: TObject);
begin
  FTimeline.Clear;
end;

end.
