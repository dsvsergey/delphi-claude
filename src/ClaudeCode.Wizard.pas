unit ClaudeCode.Wizard;

{ IDE wizard: owns the MCP server, the "Claude Code" panel, the
  "Tools > Claude Code" menu and the selection tracker. }

interface

procedure Register;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Win.Registry,
  System.Generics.Collections, System.JSON, Vcl.Menus, Vcl.ActnList, Vcl.ExtCtrls,
  Vcl.Dialogs, Vcl.Forms, Vcl.Graphics, ToolsAPI,
  ClaudeCode.Utils, ClaudeCode.Mcp, ClaudeCode.IdeBackend, ClaudeCode.DiffForm,
  ClaudeCode.Launcher, ClaudeCode.TerminalFrame, ClaudeCode.TerminalPanel;

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
    procedure AddLog(const Msg: string);
    procedure StartServer;
    procedure CreateMenu;
    procedure RemoveMenu;
    function NewAction(const AName, ACaption, AShortCut: string; OnExec: TNotifyEvent): TAction;
    function SettingsKey: string;
    function ReadSetting(const Name, Default: string): string;
    procedure WriteSetting(const Name, Value: string);
    function WorkDir: string;
    procedure FocusEditor;
    function TerminalHostInfo: TTerminalHostInfo;
    function TerminalHostKey(Key: Word; Shift: TShiftState; Execute: Boolean): Boolean;
    procedure SelTimerTick(Sender: TObject);
    procedure WorkspaceTimerTick(Sender: TObject);
    procedure ClientsChanged(Sender: TObject);
    procedure OpenClaudeExecute(Sender: TObject);
    procedure OpenConsoleExecute(Sender: TObject);
    procedure SendSelectionExecute(Sender: TObject);
    procedure RestartExecute(Sender: TObject);
    procedure StatusExecute(Sender: TObject);
    procedure SettingsExecute(Sender: TObject);
    procedure BuildFixExecute(Sender: TObject);
    procedure BuildFixDone(const R: TToolResult);
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
  FWorkspaceTimer.Interval := 3000;
  FWorkspaceTimer.OnTimer := WorkspaceTimerTick;

  CreateMenu;

  TClaudeTerminalFrame.HostInfo := TerminalHostInfo;
  TClaudeTerminalFrame.HostKey := TerminalHostKey;
  RegisterClaudePanel;
end;

destructor TClaudeCodeWizard.Destroy;
begin
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
end;

procedure TClaudeCodeWizard.ClientsChanged(Sender: TObject);
begin
  // Resend the current selection to newly connected clients.
  FLastSent.Valid := False;
end;

{ Commands }

procedure TClaudeCodeWizard.OpenClaudeExecute(Sender: TObject);
var
  Frame: TClaudeTerminalFrame;
begin
  Frame := ShowClaudePanel;
  if Frame = nil then
  begin
    ShowMessage('The Claude Code panel could not be created. ' +
      'Use Tools > Claude Code > Open in External Console.');
    Exit;
  end;
  if not Frame.SessionRunning then
    Frame.StartSession;
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
    LaunchClaude(Dir, Cmd, FMcp.Port);
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
begin
  Sel := FBackend.CurrentSelection(False);
  if not Sel.Valid then
  begin
    ShowMessage('No active editor.');
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
    Prompt := Prompt + 'Fix these errors, then call the buildProject tool to verify the build.';
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
  S := S + #13#10'Workspace folders: ' + string.Join('; ', FBackend.WorkspaceFolders) +
    #13#10'Panel command: ' + ReadSetting('PanelCommand', DEFAULT_PANEL_COMMAND) +
    #13#10'External console command: ' + ReadSetting('LaunchCommand', DEFAULT_CONSOLE_COMMAND) +
    #13#10#13#10'Recent log:'#13#10;
  First := FLog.Count - 20;
  if First < 0 then
    First := 0;
  for I := First to FLog.Count - 1 do
    S := S + FLog[I] + #13#10;
  ShowMessage(S);
end;

procedure TClaudeCodeWizard.SettingsExecute(Sender: TObject);
var
  Values: array[0..1] of string;
begin
  Values[0] := ReadSetting('PanelCommand', DEFAULT_PANEL_COMMAND);
  Values[1] := ReadSetting('LaunchCommand', DEFAULT_CONSOLE_COMMAND);
  if InputQuery('Claude Code Settings',
    ['Command run in the Claude Code panel:', 'Command for "Open in External Console":'], Values) then
  begin
    WriteSetting('PanelCommand', Trim(Values[0]));
    WriteSetting('LaunchCommand', Trim(Values[1]));
  end;
end;

end.
