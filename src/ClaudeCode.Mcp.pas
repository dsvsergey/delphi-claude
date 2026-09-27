unit ClaudeCode.Mcp;

{ MCP (JSON-RPC 2.0) server over WebSocket, speaking the Claude Code IDE protocol:
  - advertises itself through ~/.claude/ide/<port>.lock
  - answers initialize / tools/list / tools/call
  - pushes selection_changed / at_mentioned notifications.
  Tool calls are forwarded to IIdeBackend in the main thread. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ClaudeCode.WebSocket;

type
  TToolResult = record
    Texts: TArray<string>;
    IsError: Boolean;
    class function Ok(const ATexts: array of string): TToolResult; static;
    class function Json(Obj: TJSONValue): TToolResult; static; // frees Obj
    class function Error(const Msg: string): TToolResult; static;
  end;

  TToolDone = reference to procedure(const R: TToolResult);

  IIdeBackend = interface
    ['{B7C1B0A4-3E0F-4F47-8B0B-0F5F6C8C9A21}']
    { Called in the main thread. Done may be invoked immediately or later
      (e.g. openDiff waits for the user), always from the main thread.
      Args is owned by the caller and only valid during the call. }
    procedure ExecuteTool(const Name: string; Args: TJSONObject; const Done: TToolDone);
    function WorkspaceFolders: TArray<string>;
    function IdeName: string;
  end;

  { mcIde: the Claude Code IDE protocol over WebSocket (~/.claude/ide/<port>.lock).
    mcTools: the "delphi" MCP server over Streamable HTTP (POST /mcp) with the Delphi tools,
    which Claude Code does not show to the model when they come from the IDE connection. }
  TMcpChannel = (mcIde, mcTools);
  TReplyProc = reference to procedure(const Json: string);

  TMcpServer = class
  private
    FWs: TWsServer;
    FBackend: IIdeBackend;
    FToken: string;
    FLockFile: string;
    FMcpConfigFile: string;
    FLockFolders: string;
    FShuttingDown: Boolean;
    FOnClientsChanged: TNotifyEvent;
    procedure WsMessage(const Conn: IWsConnection; const Text: string);
    procedure WsConnect(const Conn: IWsConnection);
    procedure WsDisconnect(const Conn: IWsConnection);
    function HttpRequest(const Path, Body: string; out Status: Integer): string;
    procedure HandleRequest(const Reply: TReplyProc; Channel: TMcpChannel; const IdJson, Method: string;
      Params: TJSONObject);
    procedure SendResult(const Reply: TReplyProc; const IdJson: string; Result: TJSONValue);
    procedure SendError(const Reply: TReplyProc; const IdJson: string; Code: Integer; const Msg: string);
    procedure WriteMcpConfig;
    procedure WriteLockFile(const Folders: TArray<string>);
    procedure ClientsChanged;
  public
    constructor Create(const Backend: IIdeBackend);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function Running: Boolean;
    procedure RefreshLockFile;
    procedure Notify(const Method: string; Params: TJSONObject);
    function ClientCount: Integer;
    function Port: Integer;
    property LockFile: string read FLockFile;
    { --mcp-config file that registers the "delphi" server for this IDE instance. }
    property McpConfigFile: string read FMcpConfigFile;
    property OnClientsChanged: TNotifyEvent read FOnClientsChanged write FOnClientsChanged;
  end;

function ClaudeIdeLockDir: string;
function ToolDefinitions: TJSONArray;
function DelphiToolDefinitions: TJSONArray;

implementation

uses
  System.IOUtils, System.SyncObjs, Winapi.Windows, ClaudeCode.Utils;

const
  SERVER_NAME = 'claude-code-delphi';
  SERVER_VERSION = '0.3.0';
  TOOLS_SERVER_NAME = 'delphi'; // the key in mcpServers, so tools are mcp__delphi__*
  MCP_HTTP_PATH = '/mcp';
  MCP_CONFIG_NAME = 'delphi-mcp.json';
  DEFAULT_PROTOCOL = '2025-03-26';

function ClaudeIdeLockDir: string;
var
  Base: string;
begin
  Base := GetEnvironmentVariable('CLAUDE_CONFIG_DIR');
  if Base = '' then
    Base := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.claude');
  Result := TPath.Combine(Base, 'ide');
end;

{ TToolResult }

class function TToolResult.Ok(const ATexts: array of string): TToolResult;
var
  I: Integer;
begin
  SetLength(Result.Texts, Length(ATexts));
  for I := 0 to High(ATexts) do
    Result.Texts[I] := ATexts[I];
  Result.IsError := False;
end;

class function TToolResult.Json(Obj: TJSONValue): TToolResult;
begin
  try
    Result := Ok([Obj.ToJSON]);
  finally
    Obj.Free;
  end;
end;

class function TToolResult.Error(const Msg: string): TToolResult;
begin
  Result := Ok([Msg]);
  Result.IsError := True;
end;

{ Tool schemas }

function Prop(const AType, Desc: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', AType);
  Result.AddPair('description', Desc);
end;

function Schema(const Props: array of TJSONPair; const Required: array of string): TJSONObject;
var
  P: TJSONObject;
  R: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  P := TJSONObject.Create;
  for I := 0 to High(Props) do
    P.AddPair(Props[I]);
  Result.AddPair('properties', P);
  if Length(Required) > 0 then
  begin
    R := TJSONArray.Create;
    for I := 0 to High(Required) do
      R.Add(Required[I]);
    Result.AddPair('required', R);
  end;
  Result.AddPair('additionalProperties', TJSONBool.Create(False));
end;

function Tool(const Name, Desc: string; InputSchema: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('description', Desc);
  Result.AddPair('inputSchema', InputSchema);
end;

procedure AddDelphiTools(Result: TJSONArray); forward;

function ToolDefinitions: TJSONArray;
begin
  Result := TJSONArray.Create;
  Result.Add(Tool('openFile', 'Open a file in the Delphi editor and optionally select a range of text',
    Schema([
      TJSONPair.Create('filePath', Prop('string', 'Path to the file to open')),
      TJSONPair.Create('preview', Prop('boolean', 'Whether to open the file in preview mode')),
      TJSONPair.Create('startText', Prop('string', 'Text pattern to find the start of the selection range')),
      TJSONPair.Create('endText', Prop('string', 'Text pattern to find the end of the selection range')),
      TJSONPair.Create('selectToEndOfLine', Prop('boolean', 'Extend the selection to the end of the line')),
      TJSONPair.Create('makeFrontmost', Prop('boolean', 'Make the file the active editor tab'))],
      ['filePath'])));
  Result.Add(Tool('openDiff', 'Open a diff view comparing a file with proposed new contents and wait for the user to accept or reject it',
    Schema([
      TJSONPair.Create('old_file_path', Prop('string', 'Path to the file being changed')),
      TJSONPair.Create('new_file_path', Prop('string', 'Path the new contents will be written to')),
      TJSONPair.Create('new_file_contents', Prop('string', 'Proposed contents of the file')),
      TJSONPair.Create('tab_name', Prop('string', 'Name of the diff tab'))],
      ['old_file_path', 'new_file_path', 'new_file_contents', 'tab_name'])));
  Result.Add(Tool('getCurrentSelection', 'Get the current text selection in the active editor',
    Schema([], [])));
  Result.Add(Tool('getLatestSelection', 'Get the most recent text selection (even if the editor is no longer focused)',
    Schema([], [])));
  Result.Add(Tool('getOpenEditors', 'Get the list of files currently open in the editor',
    Schema([], [])));
  Result.Add(Tool('getWorkspaceFolders', 'Get the folders of the open project group',
    Schema([], [])));
  Result.Add(Tool('getDiagnostics', 'Get Error Insight diagnostics (errors, warnings, hints) from the IDE',
    Schema([
      TJSONPair.Create('uri', Prop('string', 'Optional file URI; if omitted, diagnostics for all open files are returned'))],
      [])));
  Result.Add(Tool('checkDocumentDirty', 'Check whether a document has unsaved changes',
    Schema([TJSONPair.Create('filePath', Prop('string', 'Path to the file'))], ['filePath'])));
  Result.Add(Tool('saveDocument', 'Save a document with unsaved changes',
    Schema([TJSONPair.Create('filePath', Prop('string', 'Path to the file'))], ['filePath'])));
  Result.Add(Tool('close_tab', 'Close a diff window or an editor tab by name',
    Schema([TJSONPair.Create('tab_name', Prop('string', 'Tab name'))], ['tab_name'])));
  Result.Add(Tool('closeAllDiffTabs', 'Close all diff windows opened by Claude',
    Schema([], [])));
  AddDelphiTools(Result);
end;

{ Delphi-specific tools. Claude Code hides every IDE-server tool from the model except
  getDiagnostics/executeCode, so these are also served as the separate "delphi" MCP server
  (Streamable HTTP on the same port) that Claude is started with. }
procedure AddDelphiTools(Result: TJSONArray);
begin
  Result.Add(Tool('buildProject',
    'Compile a Delphi project with MSBuild using its .dproj settings (the active IDE configuration and ' +
    'platform by default) and return the compiler errors, warnings and hints. Files are built from disk: ' +
    'unsaved editor changes are listed in unsavedFiles unless saveModified is true. ' +
    'The messages also appear in the IDE Messages window.',
    Schema([
      TJSONPair.Create('project', Prop('string', 'Project file path or name; defaults to the active project')),
      TJSONPair.Create('target', Prop('string', '"make" (default, incremental), "build" (full rebuild) or "clean"')),
      TJSONPair.Create('config', Prop('string', 'Build configuration, e.g. Debug or Release; defaults to the active one')),
      TJSONPair.Create('platform', Prop('string', 'Target platform, e.g. Win32 or Win64; defaults to the active one')),
      TJSONPair.Create('saveModified', Prop('boolean', 'Save modified editor buffers before building (default false)')),
      TJSONPair.Create('includeHints', Prop('boolean', 'Include compiler hints in the result (default true)')),
      TJSONPair.Create('timeoutSec', Prop('number', 'Build timeout in seconds (default 600)'))],
      [])));
  Result.Add(Tool('getProjectInfo',
    'Get the Delphi project group and project settings: projects, active configuration and platform, ' +
    'framework (VCL/FMX), output file, defines, search paths, namespaces and the units/forms of the project',
    Schema([
      TJSONPair.Create('project', Prop('string', 'Project file path or name; defaults to the active project'))],
      [])));

  // Form designer. "form" is a unit/.dfm path, a unit name or a form name; empty = the current editor.
  Result.Add(Tool('getFormComponents',
    'Read a Delphi form (VCL or FMX) as it is in the IDE designer right now, including unsaved designer ' +
    'changes: the list of components (name, class, parent) and the form''s DFM text. Prefer this over ' +
    'reading the .dfm file while the form is open in the IDE.',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the form of the current editor')),
      TJSONPair.Create('component', Prop('string', 'Only this component: return its DFM block (with its children)')),
      TJSONPair.Create('includeDfm', Prop('boolean', 'Include the full DFM text (default true)'))],
      [])));
  Result.Add(Tool('getSelectedComponents',
    'Get the components the user has selected in the Delphi form designer, with their DFM blocks',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form'))],
      [])));
  Result.Add(Tool('setComponentProperties',
    'Change published properties of a component (or of the form itself) through the Delphi form designer, ' +
    'instead of editing the .dfm file of a form that is open in the IDE. The designer keeps the .dfm, ' +
    'the class declaration and the Object Inspector in sync; the user saves the form. ' +
    'Values: strings, numbers, booleans; enums and sets by name ("alClient", ["akLeft","akTop"]); ' +
    'identifiers such as clRed or crHandPoint; nested properties as "Font.Size" or {"Font": {"Style": "[fsBold]"}}; ' +
    'component references by component name; TStrings (Items, Lines) as text or an array of lines; ' +
    'events by handler method name (created in the unit if missing), "" to clear. ' +
    'Returns old and new values of what changed.',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('component', Prop('string', 'Component name; empty or the form name for the form itself')),
      TJSONPair.Create('properties', Prop('object', 'Property names (or dotted paths) and values'))],
      ['properties'])));
  Result.Add(Tool('createComponent',
    'Drop a new component on a Delphi form through the designer (the class must be registered in the IDE). ' +
    'Optionally name it, place it inside a parent control and set properties like setComponentProperties.',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('className', Prop('string', 'Component class, e.g. TButton, TFDQuery')),
      TJSONPair.Create('name', Prop('string', 'Component name; default: the designer''s next free name')),
      TJSONPair.Create('parent', Prop('string', 'Parent control name (e.g. a TPanel); default: the form')),
      TJSONPair.Create('left', Prop('number', 'Left, relative to the parent')),
      TJSONPair.Create('top', Prop('number', 'Top, relative to the parent')),
      TJSONPair.Create('width', Prop('number', 'Width')),
      TJSONPair.Create('height', Prop('number', 'Height')),
      TJSONPair.Create('properties', Prop('object', 'Properties to set after creation'))],
      ['className'])));
  Result.Add(Tool('deleteComponent',
    'Delete a component (and the controls it contains) from a Delphi form through the designer',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('component', Prop('string', 'Component name'))],
      ['component'])));
  // Debugger.
  Result.Add(Tool('getDebugState',
    'Get the state of the program being debugged in the Delphi IDE: process state, the current thread with ' +
    'its call stack and the source around the current line, the exception (when stopped on one) and all ' +
    'threads. There is no list of local variables: read the code and use evaluateExpression.',
    Schema([
      TJSONPair.Create('maxFrames', Prop('number', 'Call stack frames to return (default 30)')),
      TJSONPair.Create('contextLines', Prop('number', 'Source lines shown before and after the current line (default 6)'))],
      [])));
  Result.Add(Tool('evaluateExpression',
    'Evaluate a Delphi expression in the stopped debugged process (current thread and frame), like the ' +
    'Evaluate/Modify dialog: variables, fields, properties, typecasts, Length(), array elements...',
    Schema([
      TJSONPair.Create('expression', Prop('string', 'Delphi expression, e.g. Customer.Name or Length(Items)')),
      TJSONPair.Create('allowSideEffects', Prop('boolean', 'Allow calling functions/property getters with side effects (default false)'))],
      ['expression'])));
  Result.Add(Tool('setBreakpoint',
    'Add a source breakpoint in the Delphi IDE (or update the one on that line)',
    Schema([
      TJSONPair.Create('file', Prop('string', 'Unit path')),
      TJSONPair.Create('line', Prop('number', '1-based line number')),
      TJSONPair.Create('condition', Prop('string', 'Break only when this Delphi expression is True')),
      TJSONPair.Create('passCount', Prop('number', 'Break on the Nth pass')),
      TJSONPair.Create('enabled', Prop('boolean', 'Default true'))],
      ['file', 'line'])));
  Result.Add(Tool('listBreakpoints', 'List the source breakpoints set in the Delphi IDE',
    Schema([], [])));
  Result.Add(Tool('removeBreakpoint', 'Remove a source breakpoint from the Delphi IDE',
    Schema([
      TJSONPair.Create('file', Prop('string', 'Unit path')),
      TJSONPair.Create('line', Prop('number', '1-based line number'))],
      ['file', 'line'])));
  Result.Add(Tool('debugControl',
    'Control the program being debugged: "stepOver", "stepInto", "runUntilReturn", "runToCursor" and "pause" ' +
    'wait until it stops again and return the new debug state; "run" continues (waits only if waitSec is ' +
    'given, e.g. until the next breakpoint); "terminate" ends the program.',
    Schema([
      TJSONPair.Create('action', Prop('string', 'run, stepOver, stepInto, runUntilReturn, runToCursor, pause or terminate')),
      TJSONPair.Create('waitSec', Prop('number', 'How long to wait for the next stop (default 10; 0 for run)'))],
      ['action'])));

  Result.Add(Tool('getFileHistory',
    'The Delphi IDE''s local history of a file (__history\<name>.~N~ backups made on each save in the IDE): ' +
    'without "version" the list of versions, newest first; with "version" the text of that version. ' +
    'Useful to see or restore what the file looked like before recent changes.',
    Schema([
      TJSONPair.Create('file', Prop('string', 'Path of the file')),
      TJSONPair.Create('version', Prop('number', 'Version number from the list'))],
      ['file'])));

  Result.Add(Tool('captureForm',
    'Save a PNG picture of a VCL form (or of one windowed control on it) as it looks in the designer, ' +
    'and return the file path; open it with the Read tool to look at the layout',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('component', Prop('string', 'Only this windowed control (e.g. a panel)'))],
      [])));
end;

function DelphiToolDefinitions: TJSONArray;
begin
  Result := TJSONArray.Create;
  AddDelphiTools(Result);
end;

function IsDelphiTool(const Name: string): Boolean;
var
  Defs: TJSONArray;
  V: TJSONValue;
begin
  Result := False;
  Defs := DelphiToolDefinitions;
  try
    for V in Defs do
      if JsonStr(V as TJSONObject, 'name') = Name then
        Exit(True);
  finally
    Defs.Free;
  end;
end;

{ TMcpServer }

constructor TMcpServer.Create(const Backend: IIdeBackend);
begin
  inherited Create;
  FBackend := Backend;
end;

destructor TMcpServer.Destroy;
begin
  Stop;
  inherited;
end;

function TMcpServer.Running: Boolean;
begin
  Result := (FWs <> nil) and (FWs.Port <> 0);
end;

function TMcpServer.Port: Integer;
begin
  if FWs <> nil then
    Result := FWs.Port
  else
    Result := 0;
end;

function TMcpServer.ClientCount: Integer;
begin
  if FWs <> nil then
    Result := FWs.ConnectionCount
  else
    Result := 0;
end;

procedure TMcpServer.Start;
begin
  if Running then
    Exit;
  FShuttingDown := False;
  FToken := NewAuthToken;
  FWs := TWsServer.Create(FToken);
  FWs.OnMessage := WsMessage;
  FWs.OnConnect := WsConnect;
  FWs.OnDisconnect := WsDisconnect;
  FWs.OnHttp := HttpRequest;
  try
    FWs.Start;
  except
    FreeAndNil(FWs);
    raise;
  end;
  FLockFolders := #0; // force write
  RefreshLockFile;
  WriteMcpConfig;
  Log(Format('Server listening on 127.0.0.1:%d', [FWs.Port]));
end;

procedure TMcpServer.Stop;
var
  I: Integer;
begin
  if FWs = nil then
    Exit;
  FShuttingDown := True;
  if FLockFile <> '' then
  begin
    System.SysUtils.DeleteFile(FLockFile);
    FLockFile := '';
  end;
  if FMcpConfigFile <> '' then
  begin
    System.SysUtils.DeleteFile(FMcpConfigFile);
    FMcpConfigFile := '';
  end;
  FWs.Stop;
  FreeAndNil(FWs);
  // Run anything the socket threads queued so no closure outlives this object.
  if TThread.CurrentThread.ThreadID = MainThreadID then
    for I := 1 to 3 do
      CheckSynchronize(0);
end;

procedure TMcpServer.RefreshLockFile;
var
  Folders: TArray<string>;
  Joined: string;
begin
  if not Running then
    Exit;
  Folders := FBackend.WorkspaceFolders;
  Joined := string.Join(#1, Folders);
  if (Joined <> FLockFolders) or (FLockFile = '') or not FileExists(FLockFile) then
  begin
    WriteLockFile(Folders);
    FLockFolders := Joined;
  end;
end;

procedure TMcpServer.WriteLockFile(const Folders: TArray<string>);
var
  Obj: TJSONObject;
  Arr: TJSONArray;
  F, Dir: string;
begin
  Dir := ClaudeIdeLockDir;
  ForceDirectories(Dir);
  FLockFile := TPath.Combine(Dir, IntToStr(FWs.Port) + '.lock');
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('pid', TJSONNumber.Create(GetCurrentProcessId));
    Arr := TJSONArray.Create;
    for F in Folders do
      Arr.Add(F);
    Obj.AddPair('workspaceFolders', Arr);
    Obj.AddPair('ideName', FBackend.IdeName);
    Obj.AddPair('transport', 'ws');
    Obj.AddPair('authToken', FToken);
    TFile.WriteAllBytes(FLockFile, TEncoding.UTF8.GetBytes(Obj.ToJSON)); // no BOM
  finally
    Obj.Free;
  end;
end;

procedure TMcpServer.WriteMcpConfig;
var
  Root, Servers, Srv: TJSONObject;
  Bytes: TBytes;
  Dir: string;
begin
  Dir := ClaudeIdeLockDir;
  ForceDirectories(Dir);
  Srv := TJSONObject.Create;
  Srv.AddPair('type', 'http');
  Srv.AddPair('url', Format('http://127.0.0.1:%d%s', [FWs.Port, MCP_HTTP_PATH]));
  Srv.AddPair('headers', TJSONObject.Create.AddPair('Authorization', 'Bearer ' + FToken));
  Servers := TJSONObject.Create;
  Servers.AddPair(TOOLS_SERVER_NAME, Srv);
  Root := TJSONObject.Create;
  try
    Root.AddPair('mcpServers', Servers);
    Bytes := TEncoding.UTF8.GetBytes(Root.Format(2));
  finally
    Root.Free;
  end;
  // One file per IDE instance (passed to the panel's claude), plus a fixed name that always
  // points at the most recently started IDE, for claude sessions started outside the IDE.
  FMcpConfigFile := TPath.Combine(Dir, IntToStr(FWs.Port) + '.' + MCP_CONFIG_NAME);
  TFile.WriteAllBytes(FMcpConfigFile, Bytes);
  try
    TFile.WriteAllBytes(TPath.Combine(Dir, MCP_CONFIG_NAME), Bytes);
  except
    // Another IDE instance may be writing it; the per-instance file is what the panel uses.
  end;
end;

procedure TMcpServer.ClientsChanged;
begin
  // Main thread.
  if FShuttingDown then
    Exit;
  if Assigned(FOnClientsChanged) then
    FOnClientsChanged(Self);
end;

procedure TMcpServer.WsConnect(const Conn: IWsConnection);
var
  Id: Integer;
begin
  Id := Conn.Id;
  Log(Format('Claude Code connected (#%d)', [Id]));
  TThread.Queue(nil,
    procedure
    begin
      ClientsChanged;
    end);
end;

procedure TMcpServer.WsDisconnect(const Conn: IWsConnection);
var
  Id: Integer;
begin
  Id := Conn.Id;
  if not FShuttingDown then
    Log(Format('Claude Code disconnected (#%d)', [Id]));
  TThread.Queue(nil,
    procedure
    begin
      ClientsChanged;
    end);
end;

procedure TMcpServer.Notify(const Method: string; Params: TJSONObject);
var
  Msg: TJSONObject;
begin
  Msg := TJSONObject.Create;
  try
    Msg.AddPair('jsonrpc', '2.0');
    Msg.AddPair('method', Method);
    if Params <> nil then
      Msg.AddPair('params', Params)
    else
      Msg.AddPair('params', TJSONObject.Create);
    if FWs <> nil then
      FWs.Broadcast(Msg.ToJSON);
  finally
    Msg.Free;
  end;
end;

procedure TMcpServer.SendResult(const Reply: TReplyProc; const IdJson: string; Result: TJSONValue);
begin
  try
    Reply('{"jsonrpc":"2.0","id":' + IdJson + ',"result":' + Result.ToJSON + '}');
  finally
    Result.Free;
  end;
end;

procedure TMcpServer.SendError(const Reply: TReplyProc; const IdJson: string; Code: Integer; const Msg: string);
var
  Err: TJSONObject;
begin
  Err := TJSONObject.Create;
  try
    Err.AddPair('code', TJSONNumber.Create(Code));
    Err.AddPair('message', Msg);
    Reply('{"jsonrpc":"2.0","id":' + IdJson + ',"error":' + Err.ToJSON + '}');
  finally
    Err.Free;
  end;
end;

function ToolResultJson(const R: TToolResult): TJSONObject;
var
  Content: TJSONArray;
  Item: TJSONObject;
  S: string;
begin
  Result := TJSONObject.Create;
  Content := TJSONArray.Create;
  for S in R.Texts do
  begin
    Item := TJSONObject.Create;
    Item.AddPair('type', 'text');
    Item.AddPair('text', S);
    Content.Add(Item);
  end;
  Result.AddPair('content', Content);
  Result.AddPair('isError', TJSONBool.Create(R.IsError));
end;

procedure TMcpServer.WsMessage(const Conn: IWsConnection; const Text: string);
var
  V: TJSONValue;
  Obj: TJSONObject;
  IdVal, ParamsVal: TJSONValue;
  Method: string;
begin
  // Socket thread.
  if FShuttingDown then
    Exit;
  V := TJSONObject.ParseJSONValue(Text);
  try
    if not (V is TJSONObject) then
    begin
      Conn.Send('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}');
      Exit;
    end;
    Obj := TJSONObject(V);
    Method := JsonStr(Obj, 'method');
    IdVal := Obj.GetValue('id');
    if Method = '' then
      Exit; // a response to something we sent; nothing to do
    if (IdVal = nil) or (IdVal is TJSONNull) then
      Exit; // notification (notifications/initialized, ide_connected, ...)
    ParamsVal := Obj.GetValue('params');
    if not (ParamsVal is TJSONObject) then
      ParamsVal := nil;
    HandleRequest(
      procedure(const Json: string)
      begin
        Conn.Send(Json);
      end,
      mcIde, IdVal.ToJSON, Method, TJSONObject(ParamsVal));
  finally
    V.Free;
  end;
end;

type
  { One HTTP request waiting for its answer, which may come later from the main thread. }
  IHttpWait = interface
    procedure Answer(const Json: string);
    function Wait(const ShuttingDown: TFunc<Boolean>; out Json: string): Boolean;
  end;

  THttpWait = class(TInterfacedObject, IHttpWait)
  private
    FEvent: TEvent;
    FJson: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Answer(const Json: string);
    function Wait(const ShuttingDown: TFunc<Boolean>; out Json: string): Boolean;
  end;

constructor THttpWait.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor THttpWait.Destroy;
begin
  FEvent.Free;
  inherited;
end;

procedure THttpWait.Answer(const Json: string);
begin
  FJson := Json;
  FEvent.SetEvent;
end;

function THttpWait.Wait(const ShuttingDown: TFunc<Boolean>; out Json: string): Boolean;
begin
  // Poll so that stopping the server never waits for a tool that will not run any more.
  while FEvent.WaitFor(200) <> wrSignaled do
    if ShuttingDown() then
      Exit(False);
  Json := FJson;
  Result := True;
end;

const
  SHUTTING_DOWN_JSON = '{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Server is shutting down"}}';

function TMcpServer.HttpRequest(const Path, Body: string; out Status: Integer): string;
var
  V: TJSONValue;
  Obj, Params: TJSONObject;
  IdVal: TJSONValue;
  Method, UrlPath: string;
  Waiter: IHttpWait;
begin
  // Connection thread; may block until the tool has run in the main thread.
  Status := 200;
  Result := '';
  UrlPath := Path;
  if Pos('?', UrlPath) > 0 then
    UrlPath := Copy(UrlPath, 1, Pos('?', UrlPath) - 1);
  if not SameText(UrlPath, MCP_HTTP_PATH) then
  begin
    Status := 404;
    Exit;
  end;
  if FShuttingDown then
    Exit(SHUTTING_DOWN_JSON);
  V := TJSONObject.ParseJSONValue(Body);
  try
    if not (V is TJSONObject) then
      Exit('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}');
    Obj := TJSONObject(V);
    Method := JsonStr(Obj, 'method');
    IdVal := Obj.GetValue('id');
    if (Method = '') or (IdVal = nil) or (IdVal is TJSONNull) then
    begin
      Status := 202; // notification or response: accepted, no body
      Exit;
    end;
    if Obj.GetValue('params') is TJSONObject then
      Params := TJSONObject(Obj.GetValue('params'))
    else
      Params := nil;
    Waiter := THttpWait.Create;
    HandleRequest(
      procedure(const Json: string)
      begin
        Waiter.Answer(Json);
      end,
      mcTools, IdVal.ToJSON, Method, Params);
  finally
    V.Free;
  end;
  if not Waiter.Wait(
    function: Boolean
    begin
      Result := FShuttingDown;
    end, Result) then
    Result := SHUTTING_DOWN_JSON;
end;

procedure TMcpServer.HandleRequest(const Reply: TReplyProc; Channel: TMcpChannel; const IdJson, Method: string;
  Params: TJSONObject);
var
  R, Caps, Info: TJSONObject;
  ToolName: string;
  ArgsJson: string;
  ArgsVal: TJSONValue;
begin
  if Method = 'initialize' then
  begin
    Log('initialize: ' + JsonStr(Params, 'clientInfo'));
    R := TJSONObject.Create;
    R.AddPair('protocolVersion', JsonStr(Params, 'protocolVersion', DEFAULT_PROTOCOL));
    Caps := TJSONObject.Create;
    Caps.AddPair('tools', TJSONObject.Create.AddPair('listChanged', TJSONBool.Create(False)));
    if Channel = mcIde then
      Caps.AddPair('logging', TJSONObject.Create);
    R.AddPair('capabilities', Caps);
    Info := TJSONObject.Create;
    if Channel = mcIde then
      Info.AddPair('name', SERVER_NAME)
    else
      Info.AddPair('name', TOOLS_SERVER_NAME);
    Info.AddPair('version', SERVER_VERSION);
    R.AddPair('serverInfo', Info);
    SendResult(Reply, IdJson, R);
  end
  else if Method = 'ping' then
    SendResult(Reply, IdJson, TJSONObject.Create)
  else if Method = 'tools/list' then
  begin
    if Channel = mcIde then
      SendResult(Reply, IdJson, TJSONObject.Create.AddPair('tools', ToolDefinitions))
    else
      SendResult(Reply, IdJson, TJSONObject.Create.AddPair('tools', DelphiToolDefinitions));
  end
  else if Method = 'prompts/list' then
    SendResult(Reply, IdJson, TJSONObject.Create.AddPair('prompts', TJSONArray.Create))
  else if Method = 'resources/list' then
    SendResult(Reply, IdJson, TJSONObject.Create.AddPair('resources', TJSONArray.Create))
  else if Method = 'tools/call' then
  begin
    ToolName := JsonStr(Params, 'name');
    Log('tools/call ' + ToolName);
    if (Channel = mcTools) and not IsDelphiTool(ToolName) then
    begin
      SendResult(Reply, IdJson, ToolResultJson(TToolResult.Error('Unknown tool: ' + ToolName)));
      Exit;
    end;
    ArgsJson := '{}';
    if Params <> nil then
    begin
      ArgsVal := Params.GetValue('arguments');
      if ArgsVal is TJSONObject then
        ArgsJson := ArgsVal.ToJSON;
    end;
    // IDE services must be used from the main thread.
    TThread.Queue(nil,
      procedure
      var
        Args: TJSONObject;
      begin
        if FShuttingDown then
          Exit;
        Args := TJSONObject.ParseJSONValue(ArgsJson) as TJSONObject;
        try
          try
            FBackend.ExecuteTool(ToolName, Args,
              procedure(const Res: TToolResult)
              begin
                SendResult(Reply, IdJson, ToolResultJson(Res));
              end);
          except
            on E: Exception do
              SendResult(Reply, IdJson, ToolResultJson(TToolResult.Error(E.ClassName + ': ' + E.Message)));
          end;
        finally
          Args.Free;
        end;
      end);
  end
  else
    SendError(Reply, IdJson, -32601, 'Method not found: ' + Method);
end;

end.
