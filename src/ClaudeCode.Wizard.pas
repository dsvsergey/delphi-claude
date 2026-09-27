unit ClaudeCode.Wizard;

{ IDE wizard: owns the MCP server, the "Claude Code" panel, the
  "Tools > Claude Code" menu and the selection tracker. }

interface

procedure Register;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Win.Registry,
  System.Generics.Collections, System.JSON, Vcl.Menus, Vcl.ActnList, Vcl.ExtCtrls,
  Vcl.Dialogs, Vcl.Forms, Vcl.Graphics, Vcl.ComCtrls, ToolsAPI,
  ClaudeCode.Utils, ClaudeCode.Mcp, ClaudeCode.IdeBackend, ClaudeCode.DiffForm,
  ClaudeCode.Launcher, ClaudeCode.TerminalFrame, ClaudeCode.TerminalPanel, ClaudeCode.FormTools,
  ClaudeCode.DebugTools, ClaudeCode.ContextMenus, ClaudeCode.SettingsForm, ClaudeCode.ClaudeMd,
  System.IOUtils;

const
  DEFAULT_PANEL_COMMAND = 'claude';
  DEFAULT_CONSOLE_COMMAND = 'cmd.exe /k claude';
  SETTINGS_SUBKEY = '\ClaudeCode';
  MAX_LOG_LINES = 200;

type
  TClaudeCodeWizard = class(TNotifierObject, IOTAWizard)
  private
    FBackend: TDelphiIdeBackend;
    FBackendIntf: IIdeBackend;
    FMcp: TMcpServer;
    FSelTimer: TTimer;
    FWorkspaceTimer: TTimer;
    FMenu: TMenuItem;
    FActions: TList<TAction>;
    FOpenAction: TAction;
    FSendSelAction: TAction;
    FLastSent: TSelectionInfo;
    FLog: TStringList;
    FContextMenus: TClaudeContextMenus;
    procedure AddLog(const Msg: string);
    procedure StartServer;
    procedure CreateMenu;
    procedure RemoveMenu;
    function NewAction(const AName, ACaption, AShortCut: string; OnExec: TNotifyEvent): TAction;
    function SettingsKey: string;
    function ReadSetting(const Name, Default: string): string;
    procedure WriteSetting(const Name, Value: string);
    function WorkDir: string;
    function ClaudeExtraArgs: string;
    procedure FocusEditor;
    function TerminalHostInfo: TTerminalHostInfo;
    function TerminalHostKey(Key: Word; Shift: TShiftState; Execute: Boolean): Boolean;
    procedure SelTimerTick(Sender: TObject);
    procedure WorkspaceTimerTick(Sender: TObject);
    procedure ClientsChanged(Sender: TObject);
    procedure UpdateStatusIndicator(Show: Boolean);
    procedure OpenClaudeExecute(Sender: TObject);
    procedure OpenConsoleExecute(Sender: TObject);
    procedure SendSelectionExecute(Sender: TObject);
    procedure RestartExecute(Sender: TObject);
    procedure StatusExecute(Sender: TObject);
    procedure SettingsExecute(Sender: TObject);
    function LoadSettings: TClaudeSettings;
    procedure SaveSettings(const S: TClaudeSettings);
    procedure BuildFixExecute(Sender: TObject);
    procedure BuildFixDone(const R: TToolResult);
    procedure ExplainStopExecute(Sender: TObject);
    procedure ClaudeMdExecute(Sender: TObject);
    function SessionFrame: TClaudeTerminalFrame;
    procedure SendToClaude(const Text: string; Submit: Boolean);
    function FileRef(const Path: string; Line1, Line2: Integer): string;
    function PromptTemplate(const Command: string): string;
    procedure EditorCommand(const Command: string);
    procedure AddToContext(const Files: TArray<string>);
  public
    constructor Create;
    destructor Destroy; override;
    { IOTAWizard }
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
    procedure Execute;
  end;

procedure Register;
begin
  RegisterPackageWizard(TClaudeCodeWizard.Create);
end;

{ TClaudeCodeWizard }

constructor TClaudeCodeWizard.Create;
begin
  inherited Create;
  FLog := TStringList.Create;
  FActions := TList<TAction>.Create;
  LogProc := AddLog;

  FBackend := TDelphiIdeBackend.Create;
  FBackendIntf := FBackend;
  FMcp := TMcpServer.Create(FBackendIntf);
  FMcp.OnClientsChanged := ClientsChanged;
  StartServer;

  FSelTimer := TTimer.Create(nil);
  FSelTimer.Interval := 300;
  FSelTimer.OnTimer := SelTimerTick;
  FWorkspaceTimer := TTimer.Create(nil);
  FWorkspaceTimer.Interval := 2000;
  FWorkspaceTimer.OnTimer := WorkspaceTimerTick;

  CreateMenu;
  FBackend.Sync.Enabled := LoadSettings.SyncEditor;
  FContextMenus := TClaudeContextMenus.Create(
    function: Boolean
    begin
      Result := FBackend.CurrentSelection(False).Valid;
    end);
  FContextMenus.OnEditorCommand := EditorCommand;
  FContextMenus.OnAddToContext := AddToContext;
  FContextMenus.OnFixBuildErrors := BuildFixExecute;

  TClaudeTerminalFrame.HostInfo := TerminalHostInfo;
  TClaudeTerminalFrame.HostKey := TerminalHostKey;
  RegisterClaudePanel;
end;

destructor TClaudeCodeWizard.Destroy;
begin
  FreeAndNil(FContextMenus);
  UpdateStatusIndicator(False);
  FreeAndNil(FSelTimer);
  FreeAndNil(FWorkspaceTimer);
  UnregisterClaudePanel; // stops the terminal session
  TClaudeTerminalFrame.HostInfo := nil;
  TClaudeTerminalFrame.HostKey := nil;
  DestroyAllDiffForms;
  FBackend.Shutdown; // a running build must not answer through a freed server
  if FMcp <> nil then
  begin
    FMcp.OnClientsChanged := nil;
    FMcp.Stop;
    FreeAndNil(FMcp);
  end;
  RemoveMenu;
  LogProc := nil;
  FBackendIntf := nil;
  FBackend := nil;
  FActions.Free;
  FLog.Free;
  inherited;
end;

function TClaudeCodeWizard.GetIDString: string;
begin
  Result := 'ClaudeCode.DelphiIDE';
end;

function TClaudeCodeWizard.GetName: string;
begin
  Result := 'Claude Code IDE Integration';
end;

function TClaudeCodeWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

procedure TClaudeCodeWizard.Execute;
begin
end;

procedure TClaudeCodeWizard.AddLog(const Msg: string);
begin
  FLog.Add(Msg);
  while FLog.Count > MAX_LOG_LINES do
    FLog.Delete(0);
end;

procedure TClaudeCodeWizard.StartServer;
begin
  try
    FMcp.Start;
  except
    on E: Exception do
      AddLog('Failed to start server: ' + E.Message);
  end;
end;

{ Settings }

function TClaudeCodeWizard.SettingsKey: string;
begin
  Result := (BorlandIDEServices as IOTAServices).GetBaseRegistryKey + SETTINGS_SUBKEY;
end;

function TClaudeCodeWizard.ReadSetting(const Name, Default: string): string;
var
  R: TRegistry;
begin
  Result := Default;
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly(SettingsKey) and R.ValueExists(Name) then
      Result := R.ReadString(Name);
  finally
    R.Free;
  end;
  if Trim(Result) = '' then
    Result := Default;
end;

procedure TClaudeCodeWizard.WriteSetting(const Name, Value: string);
var
  R: TRegistry;
begin
  R := TRegistry.Create;
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKey(SettingsKey, True) then
      R.WriteString(Name, Value);
  finally
    R.Free;
  end;
end;

function TClaudeCodeWizard.WorkDir: string;
var
  Folders: TArray<string>;
begin
  Result := FBackend.ActiveProjectDir;
  if Result = '' then
  begin
    Folders := FBackend.WorkspaceFolders;
    if Length(Folders) > 0 then
      Result := Folders[0];
  end;
end;

function TClaudeCodeWizard.ClaudeExtraArgs: string;
var
  S: TClaudeSettings;
begin
  S := LoadSettings;
  Result := S.CommandArgs;
  // Registers the "delphi" MCP server (build, project, designer and debugger tools) for this session.
  // Last, because --mcp-config takes every following value that is not an option.
  if S.DelphiTools and FMcp.Running and (FMcp.McpConfigFile <> '') then
    Result := Trim(Result + ' --mcp-config "' + FMcp.McpConfigFile + '"');
end;

{ Terminal panel callbacks }

function TClaudeCodeWizard.TerminalHostInfo: TTerminalHostInfo;
var
  Theming: IOTAIDEThemingServices;
  Editor: IOTAEditorServices;
begin
  if not FMcp.Running then
    StartServer;
  FMcp.RefreshLockFile;
  Result.Port := FMcp.Port;
  Result.WorkDir := WorkDir;
  Result.Command := ReadSetting('PanelCommand', DEFAULT_PANEL_COMMAND);
  Result.ExtraArgs := ClaudeExtraArgs;
  Result.Background := clWindow;
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, Theming) and Theming.IDEThemingEnabled then
    Result.Background := Theming.StyleServices.GetSystemColor(clWindow);
  // Match the code editor font.
  Result.FontName := '';
  Result.FontSize := 0;
  try
    if Supports(BorlandIDEServices, IOTAEditorServices, Editor) and (Editor.EditOptions <> nil) then
    begin
      Result.FontName := Editor.EditOptions.FontName;
      Result.FontSize := Editor.EditOptions.FontSize;
    end;
  except
  end;
end;

function TClaudeCodeWizard.TerminalHostKey(Key: Word; Shift: TShiftState; Execute: Boolean): Boolean;
var
  SC: TShortCut;
  List: TCustomActionList;
  I: Integer;
  A: TCustomAction;
begin
  SC := ShortCut(Key, Shift);
  // Our "Open Claude Code" shortcut toggles back to the code editor, like Ctrl+Esc in VS Code.
  if SC = FOpenAction.ShortCut then
  begin
    if Execute then
      FocusEditor;
    Exit(True);
  end;
  if SC = FSendSelAction.ShortCut then
  begin
    if Execute then
      FSendSelAction.Execute;
    Exit(True);
  end;
  // Function keys run IDE commands (F9, F7, F12...) when the IDE has one bound; everything
  // else, including Esc and Ctrl+letters, belongs to Claude.
  if (Key < VK_F1) or (Key > VK_F24) then
    Exit(False);
  List := (BorlandIDEServices as INTAServices).ActionList;
  for I := 0 to List.ActionCount - 1 do
    if List.Actions[I] is TCustomAction then
    begin
      A := TCustomAction(List.Actions[I]);
      if (A.ShortCut = SC) or (A.SecondaryShortCuts.IndexOfShortCut(SC) >= 0) then
      begin
        if Execute then
        begin
          A.Update;
          if A.Enabled then
            A.Execute;
        end;
        Exit(True);
      end;
    end;
  Result := False;
end;

procedure TClaudeCodeWizard.FocusEditor;
var
  Services: IOTAEditorServices;
  Window: INTAEditWindow;
begin
  Services := BorlandIDEServices as IOTAEditorServices;
  if Services.TopBuffer <> nil then
    Services.TopBuffer.Show;
  if Services.TopView <> nil then
  begin
    Window := Services.TopView.GetEditWindow;
    if (Window <> nil) and (Window.Form <> nil) and Window.Form.CanFocus then
      Window.Form.SetFocus;
  end;
end;

{ Menu }

function TClaudeCodeWizard.NewAction(const AName, ACaption, AShortCut: string;
  OnExec: TNotifyEvent): TAction;
begin
  Result := TAction.Create(nil);
  Result.Name := AName;
  Result.Caption := ACaption;
  Result.Category := 'Claude Code';
  if AShortCut <> '' then
    Result.ShortCut := TextToShortCut(AShortCut);
  Result.OnExecute := OnExec;
  Result.ActionList := (BorlandIDEServices as INTAServices).ActionList;
  FActions.Add(Result);
end;

procedure TClaudeCodeWizard.CreateMenu;
var
  MainMenu: TMainMenu;
  Parent: TMenuItem;
  I: Integer;

  procedure AddItem(Action: TAction);
  var
    Item: TMenuItem;
  begin
    Item := TMenuItem.Create(FMenu);
    Item.Action := Action;
    FMenu.Add(Item);
  end;

  procedure AddSeparator;
  begin
    FMenu.Add(NewLine);
  end;

begin
  MainMenu := (BorlandIDEServices as INTAServices).MainMenu;
  Parent := nil;
  for I := 0 to MainMenu.Items.Count - 1 do
    if SameText(MainMenu.Items[I].Name, 'ToolsMenu') then
    begin
      Parent := MainMenu.Items[I];
      Break;
    end;

  FMenu := TMenuItem.Create(nil);
  FMenu.Name := 'ClaudeCodeMenu';
  FMenu.Caption := 'Claude Code';

  FOpenAction := NewAction('ClaudeCodeOpenAction', 'Open Claude Code', 'Ctrl+Shift+Alt+C', OpenClaudeExecute);
  FSendSelAction := NewAction('ClaudeCodeSendSelAction', 'Send Selection to Claude (@-mention)',
    'Ctrl+Alt+K', SendSelectionExecute);
  AddItem(FOpenAction);
  AddItem(FSendSelAction);
  AddItem(NewAction('ClaudeCodeConsoleAction', 'Open in External Console', '', OpenConsoleExecute));
  AddSeparator;
  AddItem(NewAction('ClaudeCodeBuildFixAction', 'Build and Fix Errors with Claude', '', BuildFixExecute));
  AddItem(NewAction('ClaudeCodeExplainStopAction', 'Explain Debugger Stop with Claude', '', ExplainStopExecute));
  AddItem(NewAction('ClaudeCodeClaudeMdAction', 'Create CLAUDE.md for Project...', '', ClaudeMdExecute));
  AddSeparator;
  AddItem(NewAction('ClaudeCodeStatusAction', 'Status and Log...', '', StatusExecute));
  AddItem(NewAction('ClaudeCodeRestartAction', 'Restart Server', '', RestartExecute));
  AddItem(NewAction('ClaudeCodeSettingsAction', 'Settings...', '', SettingsExecute));

  if Parent <> nil then
    Parent.Insert(0, FMenu)
  else
    MainMenu.Items.Add(FMenu);
end;

procedure TClaudeCodeWizard.RemoveMenu;
var
  A: TAction;
begin
  FreeAndNil(FMenu);
  for A in FActions do
    A.Free;
  FActions.Clear;
  FOpenAction := nil;
  FSendSelAction := nil;
end;

{ Timers }

procedure TClaudeCodeWizard.SelTimerTick(Sender: TObject);
var
  Sel: TSelectionInfo;
begin
  try
    Sel := FBackend.CurrentSelection(False);
    if not Sel.Valid or Sel.SamePosition(FLastSent) then
      Exit;
    Sel := FBackend.CurrentSelection(True);
    FBackend.Latest := Sel;
    FLastSent := Sel;
    if (FMcp <> nil) and (FMcp.ClientCount > 0) then
      FMcp.Notify('selection_changed', Sel.NotificationParams);
  except
    // The editor can be in transient states (closing, reloading); try again next tick.
  end;
end;

procedure TClaudeCodeWizard.WorkspaceTimerTick(Sender: TObject);
begin
  try
    if FMcp <> nil then
      FMcp.RefreshLockFile;
  except
    on E: Exception do
      AddLog('Lock file update failed: ' + E.Message);
  end;
  UpdateStatusIndicator(True);
end;

procedure TClaudeCodeWizard.ClientsChanged(Sender: TObject);
begin
  // Resend the current selection to newly connected clients.
  FLastSent.Valid := False;
  UpdateStatusIndicator(True);
end;

{ A panel in the status bar of each code editor window: whether Claude is connected,
  working or waiting for the user. Show=False removes it (package unload). }
procedure TClaudeCodeWizard.UpdateStatusIndicator(Show: Boolean);
const
  PREFIX = 'Claude: ';
var
  Editors: INTAEditorServices;
  Bar: TStatusBar;
  Panel: TStatusPanel;
  Frame: TClaudeTerminalFrame;
  I, J: Integer;
  State: string;
  Busy, Waiting: Boolean;
begin
  if not Supports(BorlandIDEServices, INTAEditorServices, Editors) then
    Exit;
  Busy := False;
  Waiting := False;
  Frame := ClaudePanelFrame;
  if Frame <> nil then
    for I := 0 to Frame.ViewCount - 1 do
      if Frame.Views[I].SessionRunning then
      begin
        Busy := Busy or Frame.Views[I].Busy;
        Waiting := Waiting or Frame.Views[I].Attention;
      end;
  if Waiting then
    State := 'waiting for you'
  else if Busy then
    State := 'working'
  else if (FMcp <> nil) and (FMcp.ClientCount > 0) then
    State := Format('connected (%d)', [FMcp.ClientCount])
  else
    State := 'off';
  try
    for I := 0 to Editors.EditWindowCount - 1 do
    begin
      Bar := Editors.EditWindow[I].StatusBar;
      if Bar = nil then
        Continue;
      Panel := nil;
      for J := Bar.Panels.Count - 1 downto 0 do
        if Bar.Panels[J].Text.StartsWith(PREFIX) then
        begin
          if Show then
            Panel := Bar.Panels[J]
          else
            Bar.Panels.Delete(J);
          Break;
        end;
      if not Show then
        Continue;
      if Panel = nil then
      begin
        Panel := Bar.Panels.Add;
        Panel.Width := 170;
      end;
      if Panel.Text <> PREFIX + State then
        Panel.Text := PREFIX + State;
    end;
  except
    // The editor status bar belongs to the IDE; never let it break anything.
  end;
end;

{ Commands }

procedure TClaudeCodeWizard.OpenClaudeExecute(Sender: TObject);
var
  Frame: TClaudeTerminalFrame;
  View: TClaudeSessionView;
begin
  Frame := ShowClaudePanel;
  if Frame = nil then
  begin
    ShowMessage('The Claude Code panel could not be created. ' +
      'Use Tools > Claude Code > Open in External Console.');
    Exit;
  end;
  // One tab per project folder: switch to it, or take an unused tab, or open a new one.
  View := Frame.ViewFor(WorkDir);
  if not View.SessionRunning then
    View.StartSession
  else
    View.FocusTerminal;
end;

procedure TClaudeCodeWizard.OpenConsoleExecute(Sender: TObject);
var
  Dir, Cmd: string;
begin
  if not FMcp.Running then
    StartServer;
  if not FMcp.Running then
  begin
    ShowMessage('Claude Code server is not running. See Tools > Claude Code > Status and Log.');
    Exit;
  end;
  FMcp.RefreshLockFile;
  Dir := WorkDir;
  Cmd := ReadSetting('LaunchCommand', DEFAULT_CONSOLE_COMMAND);
  try
    LaunchClaude(Dir, Trim(Cmd + ' ' + ClaudeExtraArgs), FMcp.Port);
    AddLog('Launched "' + Cmd + '" in ' + Dir);
  except
    on E: Exception do
      ShowMessage('Could not start Claude Code: ' + E.Message);
  end;
end;

procedure TClaudeCodeWizard.SendSelectionExecute(Sender: TObject);
var
  Sel: TSelectionInfo;
  Params: TJSONObject;
  LastLine: Integer;
  Prompt: string;
  Frame: TClaudeTerminalFrame;
begin
  // In the form designer: hand Claude the selected components as DFM text.
  if DesignerIsActive then
  begin
    Prompt := SelectedComponentsPrompt;
    Frame := ClaudePanelFrame;
    if Prompt = '' then
      ShowMessage('Select components in the form designer first.')
    else if (Frame = nil) or not Frame.SessionRunning then
      ShowMessage('Start Claude Code first: Tools > Claude Code > Open Claude Code.')
    else
    begin
      ShowClaudePanel;
      Frame.PasteInput(Prompt);
      Frame.FocusTerminal;
    end;
    Exit;
  end;
  Sel := FBackend.CurrentSelection(False);
  if not Sel.Valid then
  begin
    ShowMessage('No active editor.');
    Exit;
  end;
  // With sessions in the panel, only the active tab gets the reference (at_mentioned would go
  // to every connected session).
  Frame := ClaudePanelFrame;
  if (Frame <> nil) and Frame.SessionRunning then
  begin
    LastLine := Sel.EndLine + 1;
    if (Sel.EndChar = 0) and (LastLine > Sel.StartLine + 1) then
      Dec(LastLine);
    if Sel.IsEmpty then
      Prompt := FileRef(Sel.FilePath, 0, 0)
    else
      Prompt := FileRef(Sel.FilePath, Sel.StartLine + 1, LastLine);
    SendToClaude(Prompt + ' ', False);
    Exit;
  end;
  if FMcp.ClientCount = 0 then
  begin
    ShowMessage('Claude Code is not connected. Use Tools > Claude Code > Open Claude Code, ' +
      'or run /ide inside an existing Claude Code session.');
    Exit;
  end;
  Params := TJSONObject.Create;
  Params.AddPair('filePath', Sel.FilePath);
  if not Sel.IsEmpty then
  begin
    LastLine := Sel.EndLine;
    // A selection ending at column 0 does not include that line.
    if (Sel.EndChar = 0) and (LastLine > Sel.StartLine) then
      Dec(LastLine);
    Params.AddPair('lineStart', TJSONNumber.Create(Sel.StartLine));
    Params.AddPair('lineEnd', TJSONNumber.Create(LastLine));
  end;
  FMcp.Notify('at_mentioned', Params);
  if (ClaudePanelFrame <> nil) and ClaudePanelFrame.SessionRunning then
    ShowClaudePanel;
end;

procedure TClaudeCodeWizard.BuildFixExecute(Sender: TObject);
var
  Frame: TClaudeTerminalFrame;
  Args: TJSONObject;
begin
  Frame := ClaudePanelFrame;
  if (Frame = nil) or not Frame.SessionRunning then
  begin
    ShowMessage('Start Claude Code first: Tools > Claude Code > Open Claude Code.');
    Exit;
  end;
  // Like an IDE compile, build what is in the editor.
  Args := TJSONObject.Create;
  try
    Args.AddPair('saveModified', TJSONBool.Create(True));
    Args.AddPair('includeHints', TJSONBool.Create(False));
    FBackend.ExecuteTool('buildProject', Args, BuildFixDone);
  finally
    Args.Free;
  end;
end;

procedure TClaudeCodeWizard.BuildFixDone(const R: TToolResult);
const
  MAX_LISTED = 20;
var
  V: TJSONValue;
  Obj, M: TJSONObject;
  Msgs: TJSONArray;
  Prompt, Loc, Severity: string;
  I, Listed: Integer;
  Frame: TClaudeTerminalFrame;
begin
  if R.IsError or (Length(R.Texts) = 0) then
  begin
    if Length(R.Texts) > 0 then
      ShowMessage('Build could not be started: ' + R.Texts[0]);
    Exit;
  end;
  V := TJSONObject.ParseJSONValue(R.Texts[0]);
  try
    if not (V is TJSONObject) then
      Exit;
    Obj := TJSONObject(V);
    if JsonBool(Obj, 'success', False) then
    begin
      ShowMessage(JsonStr(Obj, 'summary'));
      Exit;
    end;
    Prompt := 'The build failed: ' + JsonStr(Obj, 'summary') + #10;
    Listed := 0;
    if Obj.GetValue('messages') is TJSONArray then
    begin
      Msgs := TJSONArray(Obj.GetValue('messages'));
      for I := 0 to Msgs.Count - 1 do
      begin
        if not (Msgs.Items[I] is TJSONObject) then
          Continue;
        M := TJSONObject(Msgs.Items[I]);
        Severity := JsonStr(M, 'severity');
        if (Severity <> 'error') and (Severity <> 'fatal') then
          Continue;
        if Listed = MAX_LISTED then
        begin
          Prompt := Prompt + '...' + #10;
          Break;
        end;
        Loc := JsonStr(M, 'file');
        if JsonStr(M, 'line') <> '' then
          Loc := Loc + '(' + JsonStr(M, 'line') + ')';
        Prompt := Prompt + Trim(Loc + ': ' + JsonStr(M, 'code') + ' ' + JsonStr(M, 'message')) + #10;
        Inc(Listed);
      end;
    end;
    if (Listed = 0) and (JsonStr(Obj, 'outputTail') <> '') then
      Prompt := Prompt + 'Build output:' + #10 + JsonStr(Obj, 'outputTail') + #10;
    Prompt := Prompt + 'Fix these errors, then build the project again (buildProject tool of the delphi MCP server) to verify.';
  finally
    V.Free;
  end;
  Frame := ShowClaudePanel;
  if (Frame <> nil) and Frame.SessionRunning then
  begin
    // Pasted, not submitted: the user can edit the request and press Enter.
    Frame.PasteInput(Prompt);
    Frame.FocusTerminal;
  end;
end;

{ Requests from the context menus }

function TClaudeCodeWizard.SessionFrame: TClaudeTerminalFrame;
begin
  Result := ClaudePanelFrame;
  if (Result = nil) or not Result.SessionRunning then
  begin
    ShowMessage('Start Claude Code first: Tools > Claude Code > Open Claude Code.');
    Result := nil;
  end;
end;

procedure TClaudeCodeWizard.SendToClaude(const Text: string; Submit: Boolean);
var
  Frame: TClaudeTerminalFrame;
begin
  Frame := SessionFrame;
  if Frame = nil then
    Exit;
  ShowClaudePanel;
  Frame.PasteInput(Text, Submit);
  Frame.FocusTerminal;
end;

{ "@path#L10-20" as Claude Code reads it: relative to the session folder when inside it. }
function TClaudeCodeWizard.FileRef(const Path: string; Line1, Line2: Integer): string;
var
  Base, P: string;
begin
  P := Path;
  Base := '';
  if ClaudePanelFrame <> nil then
    Base := ClaudePanelFrame.SessionDir;
  if Base <> '' then
  begin
    Base := IncludeTrailingPathDelimiter(Base);
    if SameText(Copy(P, 1, Length(Base)), Base) then
      P := Copy(P, Length(Base) + 1, MaxInt);
  end;
  P := StringReplace(P, '\', '/', [rfReplaceAll]);
  if Line1 > 0 then
  begin
    P := P + '#L' + IntToStr(Line1);
    if Line2 > Line1 then
      P := P + '-' + IntToStr(Line2);
  end;
  if P.Contains(' ') then
    Result := '@"' + P + '"'
  else
    Result := '@' + P;
end;

// Request templates; "{ref}" is replaced by the @-reference. Each can be overridden in
// ~/.claude/delphi-prompts.json, e.g. "explain": "Поясни цей код: {ref}".
function TClaudeCodeWizard.PromptTemplate(const Command: string): string;
var
  FileName, Text: string;
  V: TJSONValue;
begin
  if Command = ecExplain then
    Result := 'Explain what this code does, how it fits into the unit, and anything non-obvious: {ref}'
  else if Command = ecRefactor then
    Result := 'Refactor this code for readability and maintainability without changing its behavior: {ref}'
  else if Command = ecReview then
    Result := 'Review this code for bugs: wrong logic, resource leaks, missing try/finally, exception safety, ' +
      'threading and off-by-one errors. List concrete problems with line numbers and how to fix them: {ref}'
  else if Command = ecTest then
    Result := 'Write DUnitX unit tests for this code. Follow the test conventions already used in the project; ' +
      'create a test unit if there is none: {ref}'
  else if Command = ecDoc then
    Result := 'Add XML documentation comments (/// <summary>, <param>, <returns>) to the declarations in this code: {ref}'
  else
    Result := '{ref} ';
  FileName := TPath.Combine(ExtractFileDir(ClaudeIdeLockDir), 'delphi-prompts.json');
  if FileExists(FileName) and ReadTextFileAutoEnc(FileName, Text) then
  begin
    V := TJSONObject.ParseJSONValue(Text);
    try
      if (V is TJSONObject) and (JsonStr(TJSONObject(V), Command) <> '') then
        Result := JsonStr(TJSONObject(V), Command);
    finally
      V.Free;
    end;
  end;
end;

procedure TClaudeCodeWizard.EditorCommand(const Command: string);
var
  Sel: TSelectionInfo;
  Line1, Line2: Integer;
begin
  Sel := FBackend.CurrentSelection(False);
  if not Sel.Valid then
    Exit;
  Line1 := Sel.StartLine + 1;
  Line2 := Sel.EndLine + 1;
  // A selection ending at column 0 does not include that line.
  if (Sel.EndChar = 0) and (Line2 > Line1) then
    Dec(Line2);
  SendToClaude(StringReplace(PromptTemplate(Command), '{ref}', FileRef(Sel.FilePath, Line1, Line2),
    [rfReplaceAll]), (Command <> ecAsk) and LoadSettings.SubmitRequests);
end;

procedure TClaudeCodeWizard.AddToContext(const Files: TArray<string>);
var
  Refs, F: string;
begin
  Refs := '';
  for F in Files do
    if DirectoryExists(F) then
      Refs := Refs + FileRef(IncludeTrailingPathDelimiter(F), 0, 0) + ' '
    else
      Refs := Refs + FileRef(F, 0, 0) + ' ';
  if Refs <> '' then
    SendToClaude(Refs, False);
end;

procedure TClaudeCodeWizard.ClaudeMdExecute(Sender: TObject);
var
  Project: IOTAProject;
  FileName, OldText, NewText, Section: string;
  Form: TClaudeDiffForm;
  Theming: IOTAIDEThemingServices;
begin
  Project := GetActiveProject;
  if Project = nil then
  begin
    ShowMessage('Open a project first.');
    Exit;
  end;
  FileName := TPath.Combine(ExtractFilePath(Project.FileName), 'CLAUDE.md');
  if not ReadTextFileAutoEnc(FileName, OldText) then
    OldText := '';
  Section := DelphiSection(Project);
  if Pos(#13#10, OldText) > 0 then
    Section := AdjustLineBreaks(Section, tlbsCRLF);
  NewText := MergeSection(OldText, Section);
  if NewText = OldText then
  begin
    ShowMessage(FileName + ' is up to date.');
    Exit;
  end;
  // Reviewed like one of Claude's edits: single changes can be skipped.
  Form := TClaudeDiffForm.CreateDiff('CLAUDE.md', FileName, OldText, NewText,
    procedure(Decision: TDiffDecision; const FinalContents: string)
    begin
      if Decision = ddAccepted then
      begin
        TFile.WriteAllBytes(FileName, TEncoding.UTF8.GetBytes(FinalContents)); // UTF-8, no BOM
        AddLog('Wrote ' + FileName);
      end;
    end);
  if FileExists(FileName) then
    Form.Note := 'only the section between <!-- delphi:begin --> and <!-- delphi:end --> is generated'
  else
    Form.Note := 'new file';
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, Theming) and Theming.IDEThemingEnabled then
  begin
    Theming.RegisterFormClass(TClaudeDiffForm);
    Theming.ApplyTheme(Form);
  end;
  Form.ShowAndActivate;
end;

procedure TClaudeCodeWizard.ExplainStopExecute(Sender: TObject);
var
  Frame: TClaudeTerminalFrame;
  Prompt: string;
begin
  Frame := ClaudePanelFrame;
  if (Frame = nil) or not Frame.SessionRunning then
  begin
    ShowMessage('Start Claude Code first: Tools > Claude Code > Open Claude Code.');
    Exit;
  end;
  Prompt := DebugStopPrompt;
  if Prompt = '' then
  begin
    ShowMessage('The debugged program is not stopped (no breakpoint, exception or pause).');
    Exit;
  end;
  // Pasted, not submitted: the user can add what they expected and press Enter.
  ShowClaudePanel;
  Frame.PasteInput(Prompt);
  Frame.FocusTerminal;
end;

procedure TClaudeCodeWizard.RestartExecute(Sender: TObject);
begin
  FMcp.Stop;
  StartServer;
  ShowMessage(Format('Claude Code server restarted on port %d. ' +
    'Running Claude sessions need /ide to reconnect (or New Session in the panel).', [FMcp.Port]));
end;

procedure TClaudeCodeWizard.StatusExecute(Sender: TObject);
var
  S: string;
  I, First: Integer;
begin
  if FMcp.Running then
    S := Format('Server: ws://127.0.0.1:%d'#13#10'Connected clients: %d'#13#10'Lock file: %s',
      [FMcp.Port, FMcp.ClientCount, FMcp.LockFile])
  else
    S := 'Server: not running';
  if FMcp.McpConfigFile <> '' then
    S := S + #13#10'Delphi tools (--mcp-config): ' + FMcp.McpConfigFile;
  S := S + #13#10'Workspace folders: ' + string.Join('; ', FBackend.WorkspaceFolders) +
    #13#10'Panel command: ' + ReadSetting('PanelCommand', DEFAULT_PANEL_COMMAND) +
    #13#10'External console command: ' + ReadSetting('LaunchCommand', DEFAULT_CONSOLE_COMMAND) +
    #13#10'Claude arguments: ' + ClaudeExtraArgs +
    #13#10#13#10'Recent log:'#13#10;
  First := FLog.Count - 20;
  if First < 0 then
    First := 0;
  for I := First to FLog.Count - 1 do
    S := S + FLog[I] + #13#10;
  ShowMessage(S);
end;

function TClaudeCodeWizard.LoadSettings: TClaudeSettings;
begin
  Result.PanelCommand := ReadSetting('PanelCommand', DEFAULT_PANEL_COMMAND);
  Result.ConsoleCommand := ReadSetting('LaunchCommand', DEFAULT_CONSOLE_COMMAND);
  Result.Model := ReadSetting('Model', '');
  Result.PermissionMode := ReadSetting('PermissionMode', '');
  Result.ExtraArgs := ReadSetting('ExtraArgs', '');
  Result.DelphiTools := ReadSetting('DelphiTools', '1') <> '0';
  Result.SyncEditor := ReadSetting('SyncEditor', '1') <> '0';
  Result.SubmitRequests := ReadSetting('SubmitRequests', '1') <> '0';
end;

procedure TClaudeCodeWizard.SaveSettings(const S: TClaudeSettings);
const
  Flag: array[Boolean] of string = ('0', '1');
begin
  WriteSetting('PanelCommand', S.PanelCommand);
  WriteSetting('LaunchCommand', S.ConsoleCommand);
  WriteSetting('Model', S.Model);
  WriteSetting('PermissionMode', S.PermissionMode);
  WriteSetting('ExtraArgs', S.ExtraArgs);
  WriteSetting('DelphiTools', Flag[S.DelphiTools]);
  WriteSetting('SyncEditor', Flag[S.SyncEditor]);
  WriteSetting('SubmitRequests', Flag[S.SubmitRequests]);
end;

procedure TClaudeCodeWizard.SettingsExecute(Sender: TObject);
var
  S: TClaudeSettings;
begin
  S := LoadSettings;
  if EditClaudeSettings(S,
    procedure(F: TForm)
    var
      Theming: IOTAIDEThemingServices;
    begin
      if Supports(BorlandIDEServices, IOTAIDEThemingServices, Theming) and Theming.IDEThemingEnabled then
        Theming.ApplyTheme(F);
    end) then
  begin
    SaveSettings(S);
    FBackend.Sync.Enabled := S.SyncEditor;
  end;
end;

end.
