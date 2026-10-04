unit ClaudeCode.Utils;

{ Shared helpers: logging, path <-> URI conversion, file reading, JSON access. }

interface

uses
  System.SysUtils, System.Classes, System.JSON;

type
  TLogProc = reference to procedure(const Msg: string);

var
  // Assigned by the wizard; always invoked in the main thread.
  LogProc: TLogProc;

procedure Log(const Msg: string);
{ Runs Proc in the main thread from the regular message loop (a posted window message), like a
  user action - not from inside TThread.Queue/CheckSynchronize. IDE services that wait for work
  the IDE itself queues (the debugger starting a program, evaluating at a stop, the designer
  pasting) fail or hang when called from inside CheckSynchronize, which is not re-entrant.
  Callable from any thread. }
procedure RunInMainLoop(const Proc: TProc);
{ The same, after Ms milliseconds (a timer of the same window). }
procedure RunInMainLoopAfter(Ms: Cardinal; const Proc: TProc);
{ Runs what RunInMainLoop has queued so far (main thread; used when shutting down). }
procedure FlushMainLoop;

function PathFromUri(const S: string): string;
{ %XX escapes (UTF-8) decoded. }
function PercentDecode(const S: string): string;
function PathToUri(const Path: string): string;
function LanguageIdForFile(const FileName: string): string;
function ReadTextFileAutoEnc(const FileName: string; out Text: string): Boolean;
function NewAuthToken: string;
function JsonStr(Obj: TJSONObject; const Name: string; const Default: string = ''): string;
function JsonBool(Obj: TJSONObject; const Name: string; Default: Boolean): Boolean;
function Utf8BytesToString(const Bytes: TBytes): string;
{ Claude Code's configuration folder (CLAUDE_CONFIG_DIR or %USERPROFILE%\.claude). }
function ClaudeConfigDir: string;
{ True when Claude Code has an interactive conversation recorded for Dir (what --continue continues). }
function HasClaudeConversation(const Dir: string): Boolean;

implementation

uses
  Winapi.Windows, Winapi.Messages, System.SyncObjs, System.Generics.Collections, System.IOUtils, System.Math;

const
  WM_RUN_QUEUED = WM_APP + 77;

type
  TMainLoopDispatcher = class
  private
    FWnd: HWND;
    FLock: TCriticalSection;
    FQueue: TQueue<System.SysUtils.TProc>;
    FTimers: TDictionary<UIntPtr, System.SysUtils.TProc>;
    FNextTimer: UIntPtr;
    procedure WndProc(var Msg: TMessage);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Post(const Proc: System.SysUtils.TProc);
  end;

var
  Dispatcher: TMainLoopDispatcher;

constructor TMainLoopDispatcher.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FQueue := TQueue<System.SysUtils.TProc>.Create;
  FTimers := TDictionary<UIntPtr, System.SysUtils.TProc>.Create;
  FNextTimer := 1;
  FWnd := AllocateHWnd(WndProc);
end;

destructor TMainLoopDispatcher.Destroy;
begin
  DeallocateHWnd(FWnd);
  FTimers.Free;
  FQueue.Free;
  FLock.Free;
  inherited;
end;

procedure TMainLoopDispatcher.Post(const Proc: System.SysUtils.TProc);
begin
  FLock.Enter;
  try
    FQueue.Enqueue(Proc);
  finally
    FLock.Leave;
  end;
  PostMessage(FWnd, WM_RUN_QUEUED, 0, 0);
end;

procedure TMainLoopDispatcher.WndProc(var Msg: TMessage);
var
  Proc: System.SysUtils.TProc;
begin
  if Msg.Msg = WM_TIMER then
  begin
    KillTimer(FWnd, Msg.WParam);
    if FTimers.TryGetValue(Msg.WParam, Proc) then
    begin
      FTimers.Remove(Msg.WParam);
      try
        Proc();
      except
        on E: Exception do
          Log('Main loop task failed: ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    Exit;
  end;
  if Msg.Msg <> WM_RUN_QUEUED then
  begin
    Msg.Result := DefWindowProc(FWnd, Msg.Msg, Msg.WParam, Msg.LParam);
    Exit;
  end;
  // One item per message, so a long-running item never starves the rest of the message loop.
  FLock.Enter;
  try
    if FQueue.Count = 0 then
      Exit;
    Proc := FQueue.Dequeue();
  finally
    FLock.Leave;
  end;
  try
    Proc();
  except
    on E: Exception do
      Log('Main loop task failed: ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure RunInMainLoop(const Proc: TProc);
begin
  Dispatcher.Post(Proc);
end;

procedure RunInMainLoopAfter(Ms: Cardinal; const Proc: TProc);
var
  Id: UIntPtr;
begin
  // Main thread only (the timers belong to the dispatcher's window).
  Id := Dispatcher.FNextTimer;
  Inc(Dispatcher.FNextTimer);
  Dispatcher.FTimers.Add(Id, Proc);
  SetTimer(Dispatcher.FWnd, Id, Ms, nil);
end;

procedure FlushMainLoop;
var
  Msg: TMessage;
  I: Integer;
begin
  if (Dispatcher = nil) or (TThread.CurrentThread.ThreadID <> MainThreadID) then
    Exit;
  Msg := Default(TMessage);
  Msg.Msg := WM_RUN_QUEUED;
  for I := 1 to 1000 do
  begin
    Dispatcher.FLock.Enter;
    try
      if Dispatcher.FQueue.Count = 0 then
        Break;
    finally
      Dispatcher.FLock.Leave;
    end;
    Dispatcher.WndProc(Msg);
  end;
end;

var
  LogFileName: string;

{ With CLAUDE_DELPHI_LOGFILE set, the log also goes to that file (diagnostics). }
procedure LogToFile(const Line: string);
var
  F: TextFile;
begin
  if LogFileName = '' then
    Exit;
  try
    AssignFile(F, LogFileName);
    if FileExists(LogFileName) then
      Append(F)
    else
      Rewrite(F);
    try
      Writeln(F, Line);
    finally
      CloseFile(F);
    end;
  except
    // Logging must never fail the caller.
  end;
end;

procedure Log(const Msg: string);
var
  Stamped: string;
begin
  Stamped := FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + Msg;
  // Main thread only, so lines from several threads never collide in the file.
  if TThread.CurrentThread.ThreadID = MainThreadID then
  begin
    LogToFile(Stamped);
    if Assigned(LogProc) then
      LogProc(Stamped);
  end
  else
    TThread.Queue(nil,
      procedure
      begin
        LogToFile(Stamped);
        if Assigned(LogProc) then
          LogProc(Stamped);
      end);
end;

function PercentDecode(const S: string): string;
var
  Bytes: TBytes;
  I, N: Integer;
  Hex: string;
  Chunk: TBytes;
begin
  if Pos('%', S) = 0 then
    Exit(S);
  SetLength(Bytes, 0);
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    if (S[I] = '%') and (I + 2 <= N) then
    begin
      Hex := Copy(S, I + 1, 2);
      Bytes := Bytes + [Byte(StrToIntDef('$' + Hex, Ord('?')))];
      Inc(I, 3);
    end
    else
    begin
      Chunk := TEncoding.UTF8.GetBytes(S[I]);
      Bytes := Bytes + Chunk;
      Inc(I);
    end;
  end;
  Result := TEncoding.UTF8.GetString(Bytes);
end;

function PathFromUri(const S: string): string;
var
  P: string;
begin
  P := Trim(S);
  if P = '' then
    Exit('');
  if P.StartsWith('file://', True) then
  begin
    P := PercentDecode(Copy(P, 8, MaxInt));
    // file:///C:/x -> /C:/x -> C:/x
    if (Length(P) >= 3) and (P[1] = '/') and (P[3] = ':') then
      Delete(P, 1, 1);
  end;
  P := StringReplace(P, '/', '\', [rfReplaceAll]);
  Result := ExpandFileName(P);
end;

function PathToUri(const Path: string): string;
begin
  Result := 'file:///' + StringReplace(StringReplace(Path, '\', '/', [rfReplaceAll]),
    ' ', '%20', [rfReplaceAll]);
end;

function LanguageIdForFile(const FileName: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if (Ext = '.pas') or (Ext = '.dpr') or (Ext = '.dpk') or (Ext = '.inc') or (Ext = '.pp') then
    Result := 'pascal'
  else if (Ext = '.dfm') or (Ext = '.fmx') or (Ext = '.lfm') then
    Result := 'delphi-form'
  else if (Ext = '.cpp') or (Ext = '.hpp') or (Ext = '.h') or (Ext = '.c') or (Ext = '.cc') then
    Result := 'cpp'
  else if (Ext = '.dproj') or (Ext = '.groupproj') or (Ext = '.xml') or (Ext = '.cbproj') then
    Result := 'xml'
  else if Ext = '.json' then
    Result := 'json'
  else if Ext = '.sql' then
    Result := 'sql'
  else if Ext = '.md' then
    Result := 'markdown'
  else if (Ext = '.js') or (Ext = '.ts') then
    Result := 'javascript'
  else if (Ext = '.htm') or (Ext = '.html') then
    Result := 'html'
  else
    Result := 'plaintext';
end;

function ClaudeConfigDir: string;
begin
  Result := GetEnvironmentVariable('CLAUDE_CONFIG_DIR');
  if Result = '' then
    Result := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.claude');
end;

function HasClaudeConversation(const Dir: string): Boolean;
var
  Key, F: string;
  I: Integer;
  S: TFileStream;
  Head: TBytes;
begin
  // Claude Code keeps the conversations of a folder in projects\<the path with every
  // character other than a letter or digit replaced by '-'>.
  Key := ExcludeTrailingPathDelimiter(Dir);
  for I := 1 to Length(Key) do
    if not CharInSet(Key[I], ['A'..'Z', 'a'..'z', '0'..'9']) then
      Key[I] := '-';
  Key := TPath.Combine(TPath.Combine(ClaudeConfigDir, 'projects'), Key);
  Result := False;
  if not TDirectory.Exists(Key) then
    Exit;
  // Sessions of claude -p and the SDKs are kept there too, but --continue skips them: only an
  // interactive one counts. The marker is in the first records, so the head of the file is enough.
  for F in TDirectory.GetFiles(Key, '*.jsonl') do
    try
      S := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
      try
        SetLength(Head, Min(S.Size, 65536));
        if Length(Head) > 0 then
          S.ReadBuffer(Head[0], Length(Head));
      finally
        S.Free;
      end;
      if Pos('"entrypoint":"cli"', TEncoding.UTF8.GetString(Head)) > 0 then
        Exit(True);
    except
      on EStreamError do ; // being written or locked: try the others
    end;
end;

function Utf8BytesToString(const Bytes: TBytes): string;
begin
  if Length(Bytes) = 0 then
    Exit('');
  Result := TEncoding.UTF8.GetString(Bytes);
end;

function DecodeStrictUtf8(const Bytes: TBytes; Start, Count: Integer; out Text: string): Boolean;
var
  Len: Integer;
begin
  Text := '';
  if Count = 0 then
    Exit(True);
  Len := MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, PAnsiChar(@Bytes[Start]), Count, nil, 0);
  if Len = 0 then
    Exit(False);
  SetLength(Text, Len);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, PAnsiChar(@Bytes[Start]), Count, PChar(Text), Len);
  Result := True;
end;

function ReadTextFileAutoEnc(const FileName: string; out Text: string): Boolean;
var
  Stream: TFileStream;
  Bytes: TBytes;
  N: Integer;
begin
  Text := '';
  if (FileName = '') or not FileExists(FileName) then
    Exit(False);
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Bytes, Stream.Size);
      if Length(Bytes) > 0 then
        Stream.ReadBuffer(Bytes[0], Length(Bytes));
    finally
      Stream.Free;
    end;
  except
    Exit(False);
  end;
  N := Length(Bytes);
  if (N >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
    Text := TEncoding.UTF8.GetString(Bytes, 3, N - 3)
  else if (N >= 2) and (Bytes[0] = $FF) and (Bytes[1] = $FE) then
    Text := TEncoding.Unicode.GetString(Bytes, 2, N - 2)
  else if (N >= 2) and (Bytes[0] = $FE) and (Bytes[1] = $FF) then
    Text := TEncoding.BigEndianUnicode.GetString(Bytes, 2, N - 2)
  else if not DecodeStrictUtf8(Bytes, 0, N, Text) then
    Text := TEncoding.ANSI.GetString(Bytes);
  Result := True;
end;

function RtlGenRandom(RandomBuffer: Pointer; RandomBufferLength: ULONG): BOOLEAN; stdcall;
  external advapi32 name 'SystemFunction036';

function NewAuthToken: string;
var
  Buf: array[0..15] of Byte;
  I: Integer;
  G: TGUID;
begin
  // 128 bits from the OS CSPRNG as lowercase hex.
  if not RtlGenRandom(@Buf[0], SizeOf(Buf)) then
  begin
    CreateGUID(G);
    Move(G, Buf[0], SizeOf(Buf));
  end;
  Result := '';
  for I := 0 to High(Buf) do
    Result := Result + LowerCase(IntToHex(Buf[I], 2));
end;

function JsonStr(Obj: TJSONObject; const Name: string; const Default: string): string;
var
  V: TJSONValue;
begin
  Result := Default;
  if Obj = nil then
    Exit;
  V := Obj.GetValue(Name);
  if (V = nil) or (V is TJSONNull) then
    Exit;
  if V is TJSONString then
    Result := TJSONString(V).Value
  else
    Result := V.ToJSON;
end;

function JsonBool(Obj: TJSONObject; const Name: string; Default: Boolean): Boolean;
var
  V: TJSONValue;
begin
  Result := Default;
  if Obj = nil then
    Exit;
  V := Obj.GetValue(Name);
  if V is TJSONBool then
    Result := TJSONBool(V).AsBoolean;
end;

initialization
  LogFileName := GetEnvironmentVariable('CLAUDE_DELPHI_LOGFILE');
  Dispatcher := TMainLoopDispatcher.Create;
finalization
  FreeAndNil(Dispatcher);
end.
