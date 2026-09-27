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

  TMcpServer = class
  private
    FWs: TWsServer;
    FBackend: IIdeBackend;
    FToken: string;
    FLockFile: string;
    FLockFolders: string;
    FShuttingDown: Boolean;
    FOnClientsChanged: TNotifyEvent;
    procedure WsMessage(const Conn: IWsConnection; const Text: string);
    procedure WsConnect(const Conn: IWsConnection);
    procedure WsDisconnect(const Conn: IWsConnection);
    procedure HandleRequest(const Conn: IWsConnection; const IdJson, Method: string; Params: TJSONObject);
    procedure SendResult(const Conn: IWsConnection; const IdJson: string; Result: TJSONValue);
    procedure SendError(const Conn: IWsConnection; const IdJson: string; Code: Integer; const Msg: string);
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
    property OnClientsChanged: TNotifyEvent read FOnClientsChanged write FOnClientsChanged;
  end;

function ClaudeIdeLockDir: string;
function ToolDefinitions: TJSONArray;

implementation

uses
  System.IOUtils, Winapi.Windows, ClaudeCode.Utils;

const
  SERVER_NAME = 'claude-code-delphi';
  SERVER_VERSION = '0.1.0';
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
  try
    FWs.Start;
  except
    FreeAndNil(FWs);
    raise;
  end;
  FLockFolders := #0; // force write
  RefreshLockFile;
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

procedure TMcpServer.SendResult(const Conn: IWsConnection; const IdJson: string; Result: TJSONValue);
begin
  try
    Conn.Send('{"jsonrpc":"2.0","id":' + IdJson + ',"result":' + Result.ToJSON + '}');
  finally
    Result.Free;
  end;
end;

procedure TMcpServer.SendError(const Conn: IWsConnection; const IdJson: string; Code: Integer; const Msg: string);
var
  Err: TJSONObject;
begin
  Err := TJSONObject.Create;
  try
    Err.AddPair('code', TJSONNumber.Create(Code));
    Err.AddPair('message', Msg);
    Conn.Send('{"jsonrpc":"2.0","id":' + IdJson + ',"error":' + Err.ToJSON + '}');
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
    HandleRequest(Conn, IdVal.ToJSON, Method, TJSONObject(ParamsVal));
  finally
    V.Free;
  end;
end;

procedure TMcpServer.HandleRequest(const Conn: IWsConnection; const IdJson, Method: string; Params: TJSONObject);
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
    Caps.AddPair('logging', TJSONObject.Create);
    R.AddPair('capabilities', Caps);
    Info := TJSONObject.Create;
    Info.AddPair('name', SERVER_NAME);
    Info.AddPair('version', SERVER_VERSION);
    R.AddPair('serverInfo', Info);
    SendResult(Conn, IdJson, R);
  end
  else if Method = 'ping' then
    SendResult(Conn, IdJson, TJSONObject.Create)
  else if Method = 'tools/list' then
    SendResult(Conn, IdJson, TJSONObject.Create.AddPair('tools', ToolDefinitions))
  else if Method = 'prompts/list' then
    SendResult(Conn, IdJson, TJSONObject.Create.AddPair('prompts', TJSONArray.Create))
  else if Method = 'resources/list' then
    SendResult(Conn, IdJson, TJSONObject.Create.AddPair('resources', TJSONArray.Create))
  else if Method = 'tools/call' then
  begin
    ToolName := JsonStr(Params, 'name');
    Log('tools/call ' + ToolName);
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
                SendResult(Conn, IdJson, ToolResultJson(Res));
              end);
          except
            on E: Exception do
              SendResult(Conn, IdJson, ToolResultJson(TToolResult.Error(E.ClassName + ': ' + E.Message)));
          end;
        finally
          Args.Free;
        end;
      end);
  end
  else
    SendError(Conn, IdJson, -32601, 'Method not found: ' + Method);
end;

end.
