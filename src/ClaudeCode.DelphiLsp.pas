unit ClaudeCode.DelphiLsp;

{ A small client of DelphiLSP.exe, the compiler-based language server of RAD Studio, run as our own
  process (the IDE's instance is not reachable). It is used to tell which declaration a name in the
  code refers to: DelphiLSP answers textDocument/definition (not references or rename), so the
  occurrences found by name are checked one by one. Calls block; use them from a background thread.
  No ToolsAPI here. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections, System.JSON;

type
  TLspLocation = record
    FileName: string; // a full path, or a bare unit file name for units without source (System.SysUtils.pas)
    Line: Integer;    // 1-based; 0 = no definition
  end;

  TDelphiLsp = class
  private
    FExe: string;
    FProcess: THandle;
    FStdinWrite: THandle;
    FStdoutRead: THandle;
    FReader: TThread;
    FLock: TCriticalSection;
    FWriteLock: TCriticalSection;
    FNextId: Integer;
    FWaiting: TDictionary<Integer, TEvent>;
    FAnswers: TDictionary<Integer, string>;
    FVersions: TDictionary<string, Integer>; // open documents: path -> version
    FTexts: TDictionary<string, Integer>;    // open documents: path -> hash of the text sent
    FConfigKey: string;
    procedure Send(const Json: string);
    procedure Received(const Json: string);
    function Request(const Method: string; Params: TJSONValue; TimeoutMs: Cardinal; out Answer: TJSONObject): Boolean;
    procedure Notify(const Method: string; Params: TJSONValue);
  public
    constructor Create(const ExePath: string);
    destructor Destroy; override;
    { Starts the server for RootDir and configures it (Settings: the "settings" object of DelphiLSP:
      project, dllname, dccOptions, projectFiles...). ConfigKey identifies that configuration. }
    function Start(const RootDir: string; Settings: TJSONObject; const ConfigKey: string; out Err: string): Boolean;
    procedure Stop;
    function Running: Boolean;
    { Sends the text of a file (didOpen, or didChange when it differs from what was sent before). }
    procedure OpenText(const FileName, Text: string);
    { Where the symbol at Line:Col (1-based, UTF-16 columns) of FileName is declared. }
    function Definition(const FileName: string; Line, Col: Integer; TimeoutMs: Cardinal = 15000): TLspLocation;
    property ConfigKey: string read FConfigKey;
  end;

{ The location for a definition answer (the result of textDocument/definition). }
function LspLocationOf(Value: TJSONValue): TLspLocation;
{ file:///D:/x.pas from D:\x.pas and back; units without a path stay bare names. }
function LspUri(const FileName: string): string;
function LspPath(const Uri: string): string;

implementation

uses
  ClaudeCode.Utils;

type
  TLspReader = class(TThread)
  private
    FOwner: TDelphiLsp;
    FPipe: THandle;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TDelphiLsp; APipe: THandle);
  end;

function LspUri(const FileName: string): string;
begin
  Result := PathToUri(FileName);
end;

function LspPath(const Uri: string): string;
var
  P: string;
begin
  P := Uri;
  if P.StartsWith('file:///', True) then
    P := Copy(P, 9, MaxInt);
  P := PercentDecode(P);
  // A unit without source is answered as file:///System.SysUtils.pas: no drive, keep the name.
  if (Length(P) >= 2) and (P[2] = ':') then
    Result := PathFromUri(Uri)
  else
    Result := P.Replace('/', '\');
end;

function LspLocationOf(Value: TJSONValue): TLspLocation;
var
  O: TJSONObject;
begin
  Result := Default(TLspLocation);
  // A Location, an array of them, or null.
  if (Value is TJSONArray) and (TJSONArray(Value).Count > 0) then
    Value := TJSONArray(Value).Items[0];
  if not (Value is TJSONObject) then
    Exit;
  O := TJSONObject(Value);
  // LocationLink has targetUri/targetRange.
  if O.GetValue('uri') <> nil then
  begin
    Result.FileName := LspPath(O.GetValue<string>('uri', ''));
    Result.Line := O.GetValue<Integer>('range.start.line', -1) + 1;
  end
  else if O.GetValue('targetUri') <> nil then
  begin
    Result.FileName := LspPath(O.GetValue<string>('targetUri', ''));
    Result.Line := O.GetValue<Integer>('targetSelectionRange.start.line', -1) + 1;
  end;
end;

{ TLspReader }

constructor TLspReader.Create(AOwner: TDelphiLsp; APipe: THandle);
begin
  FOwner := AOwner;
  FPipe := APipe;
  inherited Create(False);
end;

procedure TLspReader.Execute;
var
  Buf: TBytes;
  Data: TBytes;
  Read: DWORD;
  Head, Len, I: Integer;
  Header, Line: string;
begin
  SetLength(Buf, 65536);
  Data := nil;
  while not Terminated do
  begin
    if not ReadFile(FPipe, Buf[0], Length(Buf), Read, nil) or (Read = 0) then
      Break; // the server ended
    Data := Data + Copy(Buf, 0, Read);
    // Frames: "Content-Length: N\r\n\r\n" then N bytes of JSON.
    while True do
    begin
      Head := -1;
      for I := 0 to Length(Data) - 4 do
        if (Data[I] = 13) and (Data[I + 1] = 10) and (Data[I + 2] = 13) and (Data[I + 3] = 10) then
        begin
          Head := I;
          Break;
        end;
      if Head < 0 then
        Break;
      Header := TEncoding.ASCII.GetString(Data, 0, Head);
      Len := -1;
      for Line in Header.Split([#13#10]) do
        if Line.StartsWith('Content-Length:', True) then
          Len := StrToIntDef(Trim(Copy(Line, 16, MaxInt)), -1);
      if Len < 0 then
      begin
        Data := Copy(Data, Head + 4, MaxInt); // not a frame we know: skip the header
        Continue;
      end;
      if Length(Data) < Head + 4 + Len then
        Break;
      FOwner.Received(TEncoding.UTF8.GetString(Data, Head + 4, Len));
      Data := Copy(Data, Head + 4 + Len, MaxInt);
    end;
  end;
end;

{ TDelphiLsp }

constructor TDelphiLsp.Create(const ExePath: string);
begin
  inherited Create;
  FExe := ExePath;
  FLock := TCriticalSection.Create;
  FWriteLock := TCriticalSection.Create;
  FWaiting := TDictionary<Integer, TEvent>.Create;
  FAnswers := TDictionary<Integer, string>.Create;
  FVersions := TDictionary<string, Integer>.Create;
  FTexts := TDictionary<string, Integer>.Create;
end;

destructor TDelphiLsp.Destroy;
begin
  Stop;
  FTexts.Free;
  FVersions.Free;
  FAnswers.Free;
  FWaiting.Free;
  FWriteLock.Free;
  FLock.Free;
  inherited;
end;

function TDelphiLsp.Running: Boolean;
begin
  Result := (FProcess <> 0) and (WaitForSingleObject(FProcess, 0) = WAIT_TIMEOUT);
end;

procedure TDelphiLsp.Send(const Json: string);
var
  Body, Head: TBytes;
  Written: DWORD;
begin
  Body := TEncoding.UTF8.GetBytes(Json);
  Head := TEncoding.ASCII.GetBytes(Format('Content-Length: %d'#13#10#13#10, [Length(Body)]));
  FWriteLock.Enter;
  try
    WriteFile(FStdinWrite, Head[0], Length(Head), Written, nil);
    if Length(Body) > 0 then
      WriteFile(FStdinWrite, Body[0], Length(Body), Written, nil);
  finally
    FWriteLock.Leave;
  end;
end;

procedure TDelphiLsp.Received(const Json: string);
var
  V: TJSONValue;
  O: TJSONObject;
  Id: Integer;
  E: TEvent;
begin
  // Reader thread.
  V := TJSONObject.ParseJSONValue(Json);
  try
    if not (V is TJSONObject) then
      Exit;
    O := TJSONObject(V);
    if O.GetValue('id') = nil then
      Exit; // a notification (diagnostics, log messages)
    if O.GetValue('method') <> nil then
    begin
      // A request of the server (configuration, progress, registrations): answer it with null.
      Send('{"jsonrpc":"2.0","id":' + O.GetValue('id').ToJSON + ',"result":null}');
      Exit;
    end;
    Id := StrToIntDef(O.GetValue('id').Value, -1);
    FLock.Enter;
    try
      if FWaiting.TryGetValue(Id, E) then
      begin
        FAnswers.AddOrSetValue(Id, Json);
        E.SetEvent;
      end;
    finally
      FLock.Leave;
    end;
  finally
    V.Free;
  end;
end;

function TDelphiLsp.Request(const Method: string; Params: TJSONValue; TimeoutMs: Cardinal;
  out Answer: TJSONObject): Boolean;
var
  Id: Integer;
  E: TEvent;
  Msg: TJSONObject;
  Json: string;
  V: TJSONValue;
begin
  Answer := nil;
  Result := False;
  E := TEvent.Create(nil, True, False, '');
  FLock.Enter;
  try
    Inc(FNextId);
    Id := FNextId;
    FWaiting.Add(Id, E);
  finally
    FLock.Leave;
  end;
  try
    Msg := TJSONObject.Create;
    try
      Msg.AddPair('jsonrpc', '2.0');
      Msg.AddPair('id', TJSONNumber.Create(Id));
      Msg.AddPair('method', Method);
      if Params <> nil then
        Msg.AddPair('params', Params)
      else
        Msg.AddPair('params', TJSONNull.Create);
      Send(Msg.ToJSON);
    finally
      Msg.Free; // also frees Params
    end;
    if E.WaitFor(TimeoutMs) <> wrSignaled then
      Exit;
    FLock.Enter;
    try
      FAnswers.TryGetValue(Id, Json);
      FAnswers.Remove(Id);
    finally
      FLock.Leave;
    end;
    V := TJSONObject.ParseJSONValue(Json);
    if V is TJSONObject then
    begin
      Answer := TJSONObject(V);
      Result := Answer.GetValue('error') = nil;
    end
    else
      V.Free;
  finally
    FLock.Enter;
    try
      FWaiting.Remove(Id);
    finally
      FLock.Leave;
    end;
    E.Free;
  end;
end;

procedure TDelphiLsp.Notify(const Method: string; Params: TJSONValue);
var
  Msg: TJSONObject;
begin
  Msg := TJSONObject.Create;
  try
    Msg.AddPair('jsonrpc', '2.0');
    Msg.AddPair('method', Method);
    Msg.AddPair('params', Params);
    Send(Msg.ToJSON);
  finally
    Msg.Free;
  end;
end;

function TDelphiLsp.Start(const RootDir: string; Settings: TJSONObject; const ConfigKey: string;
  out Err: string): Boolean;
var
  SA: TSecurityAttributes;
  InRead, OutWrite: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Params: TJSONObject;
  Answer: TJSONObject;
begin
  Stop;
  Err := '';
  Result := False;
  SA := Default(TSecurityAttributes);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  if not CreatePipe(InRead, FStdinWrite, @SA, 0) then
  begin
    Err := SysErrorMessage(GetLastError);
    Exit;
  end;
  if not CreatePipe(FStdoutRead, OutWrite, @SA, 0) then
  begin
    Err := SysErrorMessage(GetLastError);
    CloseHandle(InRead);
    CloseHandle(FStdinWrite);
    FStdinWrite := 0;
    Exit;
  end;
  // Our ends must not be inherited.
  SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0);
  SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput := InRead;
  SI.hStdOutput := OutWrite;
  SI.hStdError := GetStdHandle(STD_ERROR_HANDLE);
  Cmd := '"' + FExe + '"';
  UniqueString(Cmd);
  if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(RootDir), SI, PI) then
  begin
    Err := 'DelphiLSP could not be started: ' + SysErrorMessage(GetLastError);
    CloseHandle(InRead);
    CloseHandle(OutWrite);
    Stop;
    Exit;
  end;
  CloseHandle(InRead);
  CloseHandle(OutWrite);
  CloseHandle(PI.hThread);
  FProcess := PI.hProcess;
  FReader := TLspReader.Create(Self, FStdoutRead);

  Params := TJSONObject.Create;
  Params.AddPair('processId', TJSONNumber.Create(GetCurrentProcessId));
  Params.AddPair('rootUri', LspUri(ExcludeTrailingPathDelimiter(RootDir)));
  Params.AddPair('clientInfo', TJSONObject.Create.AddPair('name', 'Claude Code for Delphi'));
  Params.AddPair('initializationOptions', TJSONObject.Create.AddPair('serverType', 'controller')
    .AddPair('agentCount', TJSONNumber.Create(1)));
  Params.AddPair('capabilities', TJSONObject.Create);
  if not Request('initialize', Params, 30000, Answer) then
  begin
    Answer.Free;
    Err := 'DelphiLSP did not answer initialize';
    Stop;
    Exit;
  end;
  Answer.Free;
  Notify('initialized', TJSONObject.Create);
  Notify('workspace/didChangeConfiguration', TJSONObject.Create.AddPair('settings', Settings.Clone as TJSONObject));
  FConfigKey := ConfigKey;
  Result := True;
end;

procedure TDelphiLsp.Stop;
var
  Answer: TJSONObject;
begin
  if Running then
  begin
    if Request('shutdown', nil, 3000, Answer) then
      Notify('exit', TJSONNull.Create);
    Answer.Free;
    if WaitForSingleObject(FProcess, 2000) <> WAIT_OBJECT_0 then
      TerminateProcess(FProcess, 1);
  end
  else if FProcess <> 0 then
    TerminateProcess(FProcess, 1);
  if FStdinWrite <> 0 then
    CloseHandle(FStdinWrite);
  FStdinWrite := 0;
  if FReader <> nil then
  begin
    FReader.Terminate;
    // The pipe breaks when the process is gone, which ends ReadFile.
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  if FStdoutRead <> 0 then
    CloseHandle(FStdoutRead);
  FStdoutRead := 0;
  if FProcess <> 0 then
    CloseHandle(FProcess);
  FProcess := 0;
  FVersions.Clear;
  FTexts.Clear;
  FConfigKey := '';
end;

procedure TDelphiLsp.OpenText(const FileName, Text: string);
var
  K: string;
  Version, Hash: Integer;
begin
  K := AnsiLowerCase(FileName);
  Hash := Text.GetHashCode;
  if FVersions.TryGetValue(K, Version) then
  begin
    if FTexts[K] = Hash then
      Exit;
    Inc(Version);
    FVersions[K] := Version;
    FTexts[K] := Hash;
    Notify('textDocument/didChange', TJSONObject.Create
      .AddPair('textDocument', TJSONObject.Create.AddPair('uri', LspUri(FileName))
        .AddPair('version', TJSONNumber.Create(Version)))
      .AddPair('contentChanges', TJSONArray.Create.Add(TJSONObject.Create.AddPair('text', Text))));
    Exit;
  end;
  FVersions.Add(K, 1);
  FTexts.Add(K, Hash);
  Notify('textDocument/didOpen', TJSONObject.Create.AddPair('textDocument', TJSONObject.Create
    .AddPair('uri', LspUri(FileName)).AddPair('languageId', 'pascal').AddPair('version', TJSONNumber.Create(1))
    .AddPair('text', Text)));
end;

function TDelphiLsp.Definition(const FileName: string; Line, Col: Integer; TimeoutMs: Cardinal): TLspLocation;
var
  Answer: TJSONObject;
begin
  Result := Default(TLspLocation);
  if not Running then
    Exit;
  if Request('textDocument/definition', TJSONObject.Create
    .AddPair('textDocument', TJSONObject.Create.AddPair('uri', LspUri(FileName)))
    .AddPair('position', TJSONObject.Create.AddPair('line', TJSONNumber.Create(Line - 1))
      .AddPair('character', TJSONNumber.Create(Col - 1))), TimeoutMs, Answer) then
    Result := LspLocationOf(Answer.GetValue('result'));
  Answer.Free;
end;

end.
