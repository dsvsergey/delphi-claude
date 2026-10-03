unit ClaudeCode.BackgroundTasks;

{ Claude tasks that run in the background (claude -p) while the user goes on working: writing tests,
  documentation, clearing warnings. Each one is a separate process; its file edits are applied
  directly (acceptEdits) and show up in the Claude Timeline like any turn, so they can be reviewed
  and rewound there. No ToolsAPI here. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Vcl.Forms, ClaudeCode.Process;

type
  TBackgroundTaskState = (btRunning, btDone, btFailed, btCancelled);

  TBackgroundTask = class
  private
    FRunner: TJobRunner;
  public
    Id: Integer;
    Title: string;      // shown in the list
    Prompt: string;
    WorkDir: string;
    Started: TDateTime;
    State: TBackgroundTaskState;
    ElapsedMs: Int64;
    ResultText: string; // Claude's final message, or what went wrong
    Cost: Double;       // USD, as Claude Code reports it
    SessionId: string;  // to continue the conversation in the panel
    destructor Destroy; override;
    function StateText: string;
  end;

  TBackgroundTasks = class
  private
    FTasks: TObjectList<TBackgroundTask>;
    FNextId: Integer;
    FOnChanged: TNotifyEvent;
    FOnFinished: TProc<TBackgroundTask>;
    procedure Changed;
    procedure Finished(Task: TBackgroundTask; const R: TProcessResult);
  public
    constructor Create;
    destructor Destroy; override;
    { Runs CommandLine (a claude -p ... --output-format json command) in WorkDir. }
    function Start(const Title, Prompt, CommandLine, WorkDir: string): TBackgroundTask;
    procedure Cancel(Task: TBackgroundTask);
    procedure ClearFinished;
    function Count: Integer;
    function Task(Index: Integer): TBackgroundTask;
    function RunningCount: Integer;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
    { Main thread, when a task ends by itself (not when cancelled). }
    property OnFinished: TProc<TBackgroundTask> read FOnFinished write FOnFinished;
  end;

  TTaskTemplate = record
    Title, Prompt: string;
  end;

{ The ready-made tasks for the dialog; UnitFile is the unit open in the editor ('' when none). }
function TaskTemplates(const UnitFile: string): TArray<TTaskTemplate>;
{ Asks what to run; False when cancelled. }
function ChooseBackgroundTask(const Templates: TArray<TTaskTemplate>; out Title, Prompt: string;
  const BeforeShow: TProc<TForm>): Boolean;
{ Claude's answer of claude -p --output-format json: result text, cost and session; False when the
  output holds no result object. }
function ParseClaudeResult(const Output: string; out Text: string; out Cost: Double; out SessionId: string;
  out IsError: Boolean): Boolean;
{ The window that lists the tasks. OnContinue opens a session id in the panel, OnTimeline the timeline. }
procedure ShowBackgroundTasks(Tasks: TBackgroundTasks; const OnContinue: TProc<TBackgroundTask>;
  const OnTimeline: TProc; const BeforeShow: TProc<TForm>);
procedure DestroyBackgroundTasksWindow;

implementation

uses
  System.JSON, System.Math, System.DateUtils, System.UITypes, Winapi.Windows, Vcl.Controls, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Dialogs, ClaudeCode.Utils;

const
  UNATTENDED = ' You are running in the background while the user works on something else: do not ask ' +
    'questions, make reasonable choices and list them in the final summary. Keep the summary short.';

function TaskTemplates(const UnitFile: string): TArray<TTaskTemplate>;

  procedure Add(const Title, Prompt: string);
  var
    T: TTaskTemplate;
  begin
    T.Title := Title;
    T.Prompt := Prompt + UNATTENDED;
    Result := Result + [T];
  end;

var
  U: string;
begin
  Result := nil;
  if UnitFile <> '' then
  begin
    U := ExtractFileName(UnitFile);
    Add('Write DUnitX tests for ' + U,
      'Write DUnitX tests for the unit ' + UnitFile + '. Cover its public routines and methods, including edge ' +
      'cases. Put them into the test project of the project group (mcp__delphi__getProjectInfo; create a DUnitX ' +
      'test unit there if needed) and run them with mcp__delphi__runTests until they pass. Do not change the code ' +
      'under test: if a test shows a real bug, keep the test, mark it clearly and report the bug.');
    Add('Add XML documentation to ' + U,
      'Add XML documentation comments (/// <summary> ...) to the public and published declarations of ' + UnitFile +
      ' that have none: what each one does, its parameters and result, in the style of the comments already ' +
      'there. Do not change code. Build the project afterwards (mcp__delphi__buildProject).');
  end;
  Add('Clear the compiler warnings',
    'Clear the compiler warnings of the active project. Start with mcp__delphi__analyzeModernization (scenario ' +
    '"warnings"), fix the causes (do not silence them with {$WARN}), most frequent kinds first, and build after ' +
    'each batch. Do not change behavior.');
end;

{ TBackgroundTask }

destructor TBackgroundTask.Destroy;
begin
  FRunner.Free; // cancels a running job
  inherited;
end;

function TBackgroundTask.StateText: string;
begin
  case State of
    btRunning:
      Result := Format('running %ds', [SecondsBetween(Now, Started)]);
    btDone:
      Result := Format('done in %ds', [ElapsedMs div 1000]);
    btFailed:
      Result := 'failed';
  else
    Result := 'cancelled';
  end;
end;

{ TBackgroundTasks }

constructor TBackgroundTasks.Create;
begin
  inherited Create;
  FTasks := TObjectList<TBackgroundTask>.Create(True);
end;

destructor TBackgroundTasks.Destroy;
begin
  FOnChanged := nil;
  FOnFinished := nil;
  FTasks.Free; // cancels what still runs
  inherited;
end;

procedure TBackgroundTasks.Changed;
begin
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TBackgroundTasks.Start(const Title, Prompt, CommandLine, WorkDir: string): TBackgroundTask;
var
  T: TBackgroundTask;
  R: TProcessResult;
begin
  T := TBackgroundTask.Create;
  Inc(FNextId);
  T.Id := FNextId;
  T.Title := Title;
  T.Prompt := Prompt;
  T.WorkDir := WorkDir;
  T.Started := Now;
  T.State := btRunning;
  T.FRunner := TJobRunner.Create;
  FTasks.Add(T);
  Log(Format('Background task %d: %s', [T.Id, CommandLine]));
  T.FRunner.Start(
    procedure(const Cancelled: TFunc<Boolean>)
    begin
      R := RunProcess(CommandLine, WorkDir, 0, Cancelled);
    end,
    procedure
    begin
      Finished(T, R);
    end);
  Changed;
  Result := T;
end;

procedure TBackgroundTasks.Finished(Task: TBackgroundTask; const R: TProcessResult);
var
  Text, Session: string;
  Cost: Double;
  IsError: Boolean;
begin
  if FTasks.IndexOf(Task) < 0 then
    Exit;
  Task.ElapsedMs := R.ElapsedMs;
  if R.Error <> '' then
  begin
    Task.State := btFailed;
    Task.ResultText := 'Claude Code could not be started: ' + R.Error;
  end
  else if ParseClaudeResult(R.Output, Text, Cost, Session, IsError) then
  begin
    Task.ResultText := Text;
    Task.Cost := Cost;
    Task.SessionId := Session;
    if IsError then
      Task.State := btFailed
    else
      Task.State := btDone;
  end
  else
  begin
    Task.State := btFailed;
    Task.ResultText := Format('Claude Code ended with exit code %d:', [R.ExitCode]) + sLineBreak + Trim(R.Output);
  end;
  Log(Format('Background task %d %s (%d s)', [Task.Id, Task.StateText, R.ElapsedMs div 1000]));
  Changed;
  if Assigned(FOnFinished) then
    FOnFinished(Task);
end;

procedure TBackgroundTasks.Cancel(Task: TBackgroundTask);
begin
  if (Task = nil) or (Task.State <> btRunning) then
    Exit;
  Task.FRunner.Cancel; // ends the process tree; Done is not called
  Task.State := btCancelled;
  Task.ElapsedMs := MilliSecondsBetween(Now, Task.Started);
  Changed;
end;

procedure TBackgroundTasks.ClearFinished;
var
  I: Integer;
begin
  for I := FTasks.Count - 1 downto 0 do
    if FTasks[I].State <> btRunning then
      FTasks.Delete(I);
  Changed;
end;

function TBackgroundTasks.Count: Integer;
begin
  Result := FTasks.Count;
end;

function TBackgroundTasks.Task(Index: Integer): TBackgroundTask;
begin
  Result := FTasks[Index];
end;

function TBackgroundTasks.RunningCount: Integer;
var
  T: TBackgroundTask;
begin
  Result := 0;
  for T in FTasks do
    if T.State = btRunning then
      Inc(Result);
end;

function ParseClaudeResult(const Output: string; out Text: string; out Cost: Double; out SessionId: string;
  out IsError: Boolean): Boolean;
var
  P, Q: Integer;
  V: TJSONValue;
  O: TJSONObject;
begin
  Text := '';
  Cost := 0;
  SessionId := '';
  IsError := False;
  // stderr may come first (warnings); the result is the last JSON object of the output.
  P := Output.LastIndexOf('{"type":"result"');
  if P < 0 then
    P := Output.IndexOf('{');
  Q := Output.LastIndexOf('}');
  Result := False;
  if (P < 0) or (Q < P) then
    Exit;
  V := TJSONObject.ParseJSONValue(Copy(Output, P + 1, Q - P + 1));
  try
    if not (V is TJSONObject) then
      Exit;
    O := TJSONObject(V);
    Text := O.GetValue<string>('result', '');
    Cost := O.GetValue<Double>('total_cost_usd', 0);
    SessionId := O.GetValue<string>('session_id', '');
    IsError := O.GetValue<Boolean>('is_error', False);
    Result := True;
  finally
    V.Free;
  end;
end;

{ The dialog }

type
  { Own classes: the IDE themes registered form classes only. }
  TBackgroundTaskDialog = class(TForm)
  private
    FTemplates: TArray<TTaskTemplate>;
    FKind: TComboBox;
    FMemo: TMemo;
    procedure KindChange(Sender: TObject);
  public
    constructor CreateFor(const Templates: TArray<TTaskTemplate>);
  end;

constructor TBackgroundTaskDialog.CreateFor(const Templates: TArray<TTaskTemplate>);
var
  Info: TLabel;
  Ok, Cancel: TButton;
  T: TTaskTemplate;
begin
  inherited CreateNew(nil);
  FTemplates := Templates;
  Caption := 'Background Task with Claude';
  BorderStyle := bsDialog;
  Position := poMainFormCenter;
  ClientWidth := 620;
  ClientHeight := 330;
  Info := TLabel.Create(Self);
  Info.Parent := Self;
  Info.SetBounds(12, 10, 596, 34);
  Info.AutoSize := False;
  Info.WordWrap := True;
  Info.Caption := 'Claude works on this in a separate process while you go on. Its file changes are applied ' +
    'right away and recorded in the Claude Timeline, where you can review and rewind them.';
  FKind := TComboBox.Create(Self);
  FKind.Parent := Self;
  FKind.Style := csDropDownList;
  FKind.SetBounds(12, 50, 596, 24);
  for T in Templates do
    FKind.Items.Add(T.Title);
  FKind.Items.Add('Your own request');
  FKind.OnChange := KindChange;
  FMemo := TMemo.Create(Self);
  FMemo.Parent := Self;
  FMemo.SetBounds(12, 82, 596, 200);
  FMemo.ScrollBars := ssVertical;
  FMemo.WordWrap := True;
  Ok := TButton.Create(Self);
  Ok.Parent := Self;
  Ok.SetBounds(ClientWidth - 180, 292, 80, 26);
  Ok.Caption := 'Start';
  Ok.ModalResult := mrOk; // not Default: Enter makes new lines in the request
  Cancel := TButton.Create(Self);
  Cancel.Parent := Self;
  Cancel.SetBounds(ClientWidth - 92, 292, 80, 26);
  Cancel.Caption := 'Cancel';
  Cancel.Cancel := True;
  Cancel.ModalResult := mrCancel;
  FKind.ItemIndex := 0;
  KindChange(nil);
end;

procedure TBackgroundTaskDialog.KindChange(Sender: TObject);
begin
  // The template text can be edited before starting; the last item is a request of your own.
  if (FKind.ItemIndex >= 0) and (FKind.ItemIndex < Length(FTemplates)) then
    FMemo.Text := FTemplates[FKind.ItemIndex].Prompt
  else
    FMemo.Text := '';
end;

function ChooseBackgroundTask(const Templates: TArray<TTaskTemplate>; out Title, Prompt: string;
  const BeforeShow: TProc<TForm>): Boolean;
var
  F: TBackgroundTaskDialog;
begin
  Title := '';
  Prompt := '';
  F := TBackgroundTaskDialog.CreateFor(Templates);
  try
    if Assigned(BeforeShow) then
      BeforeShow(F);
    Result := (F.ShowModal = mrOk) and (Trim(F.FMemo.Text) <> '');
    if Result then
    begin
      Prompt := Trim(F.FMemo.Text);
      if F.FKind.ItemIndex < Length(Templates) then
        Title := Templates[F.FKind.ItemIndex].Title
      else
      begin
        // A request of one's own still runs unattended.
        Title := Copy(Prompt.Replace(sLineBreak, ' '), 1, 80);
        Prompt := Prompt + UNATTENDED;
      end;
    end;
  finally
    F.Free;
  end;
end;

{ The window }

type
  TBackgroundTasksForm = class(TForm)
  private
    FTasks: TBackgroundTasks;
    FList: TListView;
    FResult: TMemo;
    FCancel, FContinue, FTimelineBtn, FClear: TButton;
    FTimer: TTimer;
    FOnContinue: TProc<TBackgroundTask>;
    FOnTimeline: TProc;
    procedure BuildUI;
    procedure Refresh;
    procedure TasksChanged(Sender: TObject);
    function Selected: TBackgroundTask;
    procedure ListSelect(Sender: TObject; Item: TListItem; IsSelected: Boolean);
    procedure UpdateButtons;
    procedure CancelClick(Sender: TObject);
    procedure ContinueClick(Sender: TObject);
    procedure TimelineClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
  public
    constructor CreateFor(ATasks: TBackgroundTasks);
    destructor Destroy; override;
  end;

var
  Instance: TBackgroundTasksForm;

constructor TBackgroundTasksForm.CreateFor(ATasks: TBackgroundTasks);
begin
  inherited CreateNew(Application);
  FTasks := ATasks;
  BuildUI;
  FTasks.OnChanged := TasksChanged;
  Refresh;
end;

destructor TBackgroundTasksForm.Destroy;
begin
  if FTasks <> nil then
    FTasks.OnChanged := nil;
  if Instance = Self then
    Instance := nil;
  inherited;
end;

procedure TBackgroundTasksForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caHide;
end;

procedure TBackgroundTasksForm.BuildUI;

  function Btn(const ACaption: string; ALeft: Integer; AOnClick: TNotifyEvent; Bar: TPanel): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Bar;
    Result.Caption := ACaption;
    Result.SetBounds(ALeft, 8, 150, 26);
    Result.OnClick := AOnClick;
  end;

  procedure AddColumn(const ACaption: string; AWidth: Integer);
  var
    Col: TListColumn;
  begin
    Col := FList.Columns.Add;
    Col.Caption := ACaption;
    Col.Width := AWidth;
  end;

var
  Bar: TPanel;
  Split: TSplitter;
begin
  Caption := 'Claude Background Tasks';
  Width := 860;
  Height := 520;
  Position := poMainFormCenter;
  OnClose := FormClose;
  Bar := TPanel.Create(Self);
  Bar.Parent := Self;
  Bar.Align := alBottom;
  Bar.Height := 42;
  Bar.BevelOuter := bvNone;
  FCancel := Btn('Cancel Task', 8, CancelClick, Bar);
  FContinue := Btn('Continue in Panel', 166, ContinueClick, Bar);
  FTimelineBtn := Btn('Claude Timeline...', 324, TimelineClick, Bar);
  FClear := Btn('Clear Finished', 482, ClearClick, Bar);
  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alTop;
  FList.Height := 200;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.HideSelection := False;
  FList.OnSelectItem := ListSelect;
  AddColumn('Task', 470);
  AddColumn('State', 130);
  AddColumn('Started', 80);
  AddColumn('Cost', 70);
  Split := TSplitter.Create(Self);
  Split.Parent := Self;
  Split.Align := alTop;
  Split.Top := FList.Top + FList.Height;
  FResult := TMemo.Create(Self);
  FResult.Parent := Self;
  FResult.Align := alClient;
  FResult.ReadOnly := True;
  FResult.ScrollBars := ssVertical;
  FResult.WordWrap := True;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 1000;
  FTimer.OnTimer := TimerTick;
end;

function TBackgroundTasksForm.Selected: TBackgroundTask;
var
  I: Integer;
begin
  Result := nil;
  if FList.Selected = nil then
    Exit;
  for I := 0 to FTasks.Count - 1 do
    if FTasks.Task(I).Id = NativeInt(FList.Selected.Data) then
      Exit(FTasks.Task(I));
end;

procedure TBackgroundTasksForm.Refresh;
var
  I: Integer;
  SelId: NativeInt;
  T: TBackgroundTask;
  Item: TListItem;
begin
  SelId := -1;
  if FList.Selected <> nil then
    SelId := NativeInt(FList.Selected.Data);
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    // Newest first.
    for I := FTasks.Count - 1 downto 0 do
    begin
      T := FTasks.Task(I);
      Item := FList.Items.Add;
      Item.Caption := T.Title;
      Item.Data := Pointer(NativeInt(T.Id));
      Item.SubItems.Add(T.StateText);
      Item.SubItems.Add(FormatDateTime('hh:nn:ss', T.Started));
      if T.Cost > 0 then
        Item.SubItems.Add(Format('$%.2f', [T.Cost], TFormatSettings.Invariant))
      else
        Item.SubItems.Add('');
      if T.Id = SelId then
        Item.Selected := True;
    end;
    if (FList.Selected = nil) and (FList.Items.Count > 0) then
      FList.Items[0].Selected := True;
  finally
    FList.Items.EndUpdate;
  end;
  UpdateButtons;
end;

procedure TBackgroundTasksForm.UpdateButtons;
var
  T: TBackgroundTask;
begin
  T := Selected;
  FCancel.Enabled := (T <> nil) and (T.State = btRunning);
  FContinue.Enabled := (T <> nil) and (T.SessionId <> '');
  if T = nil then
    FResult.Text := ''
  else if T.State = btRunning then
    FResult.Text := 'Working on it...' + sLineBreak + sLineBreak + AdjustLineBreaks(T.Prompt, tlbsCRLF)
  else
    FResult.Text := AdjustLineBreaks(T.ResultText, tlbsCRLF);
end;

procedure TBackgroundTasksForm.ListSelect(Sender: TObject; Item: TListItem; IsSelected: Boolean);
begin
  if IsSelected then
    UpdateButtons;
end;

procedure TBackgroundTasksForm.TasksChanged(Sender: TObject);
begin
  Refresh;
end;

procedure TBackgroundTasksForm.TimerTick(Sender: TObject);
var
  I, Row: Integer;
  T: TBackgroundTask;
begin
  // The running time of the tasks that still run (rows are newest first).
  if not Visible then
    Exit;
  for I := 0 to FTasks.Count - 1 do
  begin
    T := FTasks.Task(I);
    Row := FTasks.Count - 1 - I;
    if (T.State = btRunning) and (Row < FList.Items.Count) then
      FList.Items[Row].SubItems[0] := T.StateText;
  end;
end;

procedure TBackgroundTasksForm.CancelClick(Sender: TObject);
var
  T: TBackgroundTask;
begin
  T := Selected;
  if (T <> nil) and (MessageDlg('Stop this task? Changes it already made stay (see the Claude Timeline).',
    mtConfirmation, [mbOK, mbCancel], 0) = mrOk) then
    FTasks.Cancel(T);
end;

procedure TBackgroundTasksForm.ContinueClick(Sender: TObject);
var
  T: TBackgroundTask;
begin
  T := Selected;
  if (T <> nil) and Assigned(FOnContinue) then
    FOnContinue(T);
end;

procedure TBackgroundTasksForm.TimelineClick(Sender: TObject);
begin
  if Assigned(FOnTimeline) then
    FOnTimeline();
end;

procedure TBackgroundTasksForm.ClearClick(Sender: TObject);
begin
  FTasks.ClearFinished;
end;

procedure ShowBackgroundTasks(Tasks: TBackgroundTasks; const OnContinue: TProc<TBackgroundTask>;
  const OnTimeline: TProc; const BeforeShow: TProc<TForm>);
begin
  if Instance = nil then
  begin
    Instance := TBackgroundTasksForm.CreateFor(Tasks);
    if Assigned(BeforeShow) then
      BeforeShow(Instance);
  end;
  Instance.FOnContinue := OnContinue;
  Instance.FOnTimeline := OnTimeline;
  Instance.Refresh;
  Instance.Show;
  Instance.BringToFront;
end;

procedure DestroyBackgroundTasksWindow;
begin
  FreeAndNil(Instance);
end;

end.
