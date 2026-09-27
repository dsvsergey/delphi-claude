unit ClaudeCode.Build;

{ Builds a Delphi project with MSBuild (rsvars.bat + msbuild) in a background thread
  and parses the compiler output into structured messages.
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, System.JSON;

type
  TBuildSeverity = (bsHint, bsWarning, bsError, bsFatal);

  TBuildMessage = record
    FileName: string;
    Line, Column: Integer; // 1-based; 0 when unknown
    Severity: TBuildSeverity;
    Code: string;
    Text: string;
    function ToJson: TJSONObject;
  end;

  TBuildRequest = record
    RsVars: string;      // full path to rsvars.bat
    ProjectFile: string; // .dproj
    Target: string;      // Make, Build or Clean
    Config: string;
    Platform: string;
    TimeoutSec: Integer;
    function CommandLine: string;
  end;

  TBuildResult = record
    Success: Boolean;
    TimedOut: Boolean;
    ExitCode: Cardinal;
    ElapsedMs: Int64;
    Error: string;  // the build could not be run at all
    Output: string;
    Messages: TArray<TBuildMessage>;
    function Count(Severity: TBuildSeverity): Integer;
  end;

  TBuildDone = reference to procedure(const R: TBuildResult);

  { Runs one build at a time. OnDone is called in the main thread unless the build is cancelled. }
  TBuildRunner = class
  private
    FThread: TThread;
    FFinished: TThread;
    procedure FreeFinished;
  public
    destructor Destroy; override;
    procedure Start(const Req: TBuildRequest; const OnDone: TBuildDone);
    function Busy: Boolean;
    { Kills a running build and waits for it; its OnDone is never called. }
    procedure Cancel;
  end;

const
  SeverityNames: array[TBuildSeverity] of string = ('hint', 'warning', 'error', 'fatal');

function ParseBuildLine(const Line, BaseDir: string; out Msg: TBuildMessage): Boolean;
function ParseBuildOutput(const Output, BaseDir: string): TArray<TBuildMessage>;
{ Runs the build in the calling thread. Cancelled is polled while it runs. }
function RunBuild(const Req: TBuildRequest; const Cancelled: TFunc<Boolean>): TBuildResult;

implementation

uses
  Winapi.Windows, System.Diagnostics, System.RegularExpressions, System.Math,
  System.Generics.Collections, ClaudeCode.ConPty;

{ TBuildMessage }

function TBuildMessage.ToJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('severity', SeverityNames[Severity]);
  if Code <> '' then
    Result.AddPair('code', Code);
  Result.AddPair('message', Text);
  if FileName <> '' then
    Result.AddPair('file', FileName);
  if Line > 0 then
    Result.AddPair('line', TJSONNumber.Create(Line));
  if Column > 0 then
    Result.AddPair('column', TJSONNumber.Create(Column));
end;

{ TBuildRequest }

function TBuildRequest.CommandLine: string;
var
  MsBuild: string;
begin
  MsBuild := Format('msbuild "%s" /nologo /nr:false /v:minimal /clp:NoSummary /t:%s',
    [ProjectFile, Target]);
  if Config <> '' then
    MsBuild := MsBuild + Format(' "/p:Config=%s"', [Config]);
  if Platform <> '' then
    MsBuild := MsBuild + Format(' "/p:Platform=%s"', [Platform]);
  // chcp 65001 makes msbuild write UTF-8 into the pipe.
  Result := Format('cmd.exe /s /c "chcp 65001 >nul & call "%s" >nul && %s"', [RsVars, MsBuild]);
end;

{ TBuildResult }

function TBuildResult.Count(Severity: TBuildSeverity): Integer;
var
  M: TBuildMessage;
begin
  Result := 0;
  for M in Messages do
    if M.Severity = Severity then
      Inc(Result);
end;

{ Parsing }

var
  // file(line[,col]): error E2003: text [project]   (MSBuild)
  ReLocated: TRegEx;
  // file(line[,col]) Error: E2003 text               (plain dcc32)
  ReDcc: TRegEx;
  // MSBUILD : error MSB1009: text [project]
  ReUnlocated: TRegEx;

procedure InitRegexes;
const
  Tail = '\s*(?:\[[^\[\]]*\])?\s*$';
begin
  ReLocated := TRegEx.Create(
    '^\s*(?<file>[^\s(][^(]*?)\((?<line>\d+)(?:,(?<col>\d+))?\)\s*:\s*' +
    '(?<kind>fatal error|error|hint warning|warning|hint)\s+(?<code>[A-Za-z]+\d+)\s*:\s*(?<text>.*?)' + Tail,
    [roIgnoreCase]);
  ReDcc := TRegEx.Create(
    '^\s*(?<file>[^\s(][^(]*?)\((?<line>\d+)(?:,(?<col>\d+))?\)\s+' +
    '(?<kind>Fatal|Error|Warning|Hint):\s*(?<code>[A-Z]\d+)\s+(?<text>.*?)\s*$',
    [roIgnoreCase]);
  ReUnlocated := TRegEx.Create(
    '^\s*(?<file>[^:]*?)\s*:\s*(?<kind>fatal error|error|warning)\s+(?<code>[A-Za-z]+\d+)\s*:\s*(?<text>.*?)' + Tail,
    [roIgnoreCase]);
end;

function KindToSeverity(const Kind: string): TBuildSeverity;
var
  K: string;
begin
  K := LowerCase(Kind);
  if K.StartsWith('fatal') then
    Result := bsFatal
  else if K = 'error' then
    Result := bsError
  else if K.StartsWith('hint') then
    Result := bsHint
  else
    Result := bsWarning;
end;

function ResolveFile(const F, BaseDir: string): string;
begin
  Result := Trim(F);
  if (Result = '') or SameText(Result, 'MSBUILD') then
    Exit('');
  if (BaseDir <> '') and not ((Length(Result) > 1) and (Result[2] = ':')) and
     not Result.StartsWith('\\') then
    Result := ExpandFileName(IncludeTrailingPathDelimiter(BaseDir) + Result);
end;

function ParseBuildLine(const Line, BaseDir: string; out Msg: TBuildMessage): Boolean;
var
  M: TMatch;
begin
  Msg := Default(TBuildMessage);
  M := ReLocated.Match(Line);
  if not M.Success then
    M := ReDcc.Match(Line);
  if M.Success then
  begin
    Msg.FileName := ResolveFile(M.Groups['file'].Value, BaseDir);
    Msg.Line := StrToIntDef(M.Groups['line'].Value, 0);
    try
      Msg.Column := StrToIntDef(M.Groups['col'].Value, 0);
    except
      Msg.Column := 0; // the optional group did not take part in the match
    end;
  end
  else
  begin
    M := ReUnlocated.Match(Line);
    if not M.Success then
      Exit(False);
    Msg.FileName := ResolveFile(M.Groups['file'].Value, BaseDir);
    if (Msg.FileName <> '') and not FileExists(Msg.FileName) then
      Msg.FileName := '';
  end;
  Msg.Severity := KindToSeverity(M.Groups['kind'].Value);
  Msg.Code := UpperCase(M.Groups['code'].Value);
  Msg.Text := M.Groups['text'].Value;
  // MSBuild reports Delphi fatal errors (Fxxxx) as plain "error".
  if (Msg.Severity = bsError) and (Length(Msg.Code) = 5) and (Msg.Code[1] = 'F') then
    Msg.Severity := bsFatal;
  Result := True;
end;

function ParseBuildOutput(const Output, BaseDir: string): TArray<TBuildMessage>;
var
  Lines: TStringList;
  Seen: TDictionary<string, Boolean>;
  L: TList<TBuildMessage>;
  S, Key: string;
  Msg: TBuildMessage;
begin
  Lines := TStringList.Create;
  Seen := TDictionary<string, Boolean>.Create;
  L := TList<TBuildMessage>.Create;
  try
    Lines.Text := Output;
    for S in Lines do
      if ParseBuildLine(S, BaseDir, Msg) then
      begin
        Key := Format('%s|%d|%d|%s|%s', [LowerCase(Msg.FileName), Msg.Line, Msg.Column, Msg.Code, Msg.Text]);
        if Seen.ContainsKey(Key) then
          Continue;
        Seen.Add(Key, True);
        L.Add(Msg);
      end;
    // Errors, then warnings, then hints, each in compiler order: the first error is
    // usually the cause and later ones (e.g. F2063 "could not compile used unit") follow from it.
    Result := nil;
    for Msg in L do
      if Msg.Severity >= bsError then
        Result := Result + [Msg];
    for Msg in L do
      if Msg.Severity = bsWarning then
        Result := Result + [Msg];
    for Msg in L do
      if Msg.Severity = bsHint then
        Result := Result + [Msg];
  finally
    L.Free;
    Seen.Free;
    Lines.Free;
  end;
end;

{ Running }

function DecodeOutput(const Bytes: TBytes): string;
var
  Len: Integer;
begin
  if Length(Bytes) = 0 then
    Exit('');
  Len := MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, PAnsiChar(@Bytes[0]), Length(Bytes), nil, 0);
  if Len > 0 then
  begin
    SetLength(Result, Len);
    MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(@Bytes[0]), Length(Bytes), PChar(Result), Len);
  end
  else
    Result := TEncoding.GetEncoding(GetOEMCP).GetString(Bytes);
end;

function RunBuild(const Req: TBuildRequest; const Cancelled: TFunc<Boolean>): TBuildResult;
var
  SA: TSecurityAttributes;
  ReadPipe, WritePipe, NulIn, Job: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Watch: TStopwatch;
  Buf: array[0..65535] of Byte;
  Avail, Got, Code: DWORD;
  Bytes: TBytes;
  Exited: Boolean;

  procedure Drain;
  begin
    while PeekNamedPipe(ReadPipe, nil, 0, nil, @Avail, nil) and (Avail > 0) do
    begin
      if not ReadFile(ReadPipe, Buf, Min(Avail, DWORD(SizeOf(Buf))), Got, nil) or (Got = 0) then
        Break;
      SetLength(Bytes, Length(Bytes) + Integer(Got));
      Move(Buf[0], Bytes[Length(Bytes) - Integer(Got)], Got);
    end;
  end;

begin
  Result := Default(TBuildResult);
  if not FileExists(Req.RsVars) then
  begin
    Result.Error := 'rsvars.bat not found: ' + Req.RsVars;
    Exit;
  end;
  if not FileExists(Req.ProjectFile) then
  begin
    Result.Error := 'Project file not found: ' + Req.ProjectFile;
    Exit;
  end;

  SA.nLength := SizeOf(SA);
  SA.lpSecurityDescriptor := nil;
  SA.bInheritHandle := True;
  if not CreatePipe(ReadPipe, WritePipe, @SA, 0) then
  begin
    Result.Error := 'CreatePipe failed: ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0);
  NulIn := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @SA, OPEN_EXISTING, 0, 0);
  Job := 0;
  try
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    SI.wShowWindow := SW_HIDE;
    SI.hStdInput := NulIn;
    SI.hStdOutput := WritePipe;
    SI.hStdError := WritePipe;
    Cmd := Req.CommandLine;
    UniqueString(Cmd);
    FillChar(PI, SizeOf(PI), 0);
    Watch := TStopwatch.StartNew;
    if not CreateProcess(nil, PChar(Cmd), nil, nil, True,
      CREATE_NO_WINDOW or CREATE_SUSPENDED or CREATE_UNICODE_ENVIRONMENT, nil,
      PChar(ExtractFilePath(Req.ProjectFile)), SI, PI) then
    begin
      Result.Error := 'Could not start MSBuild: ' + SysErrorMessage(GetLastError);
      Exit;
    end;
    // The write end now lives in the child only, so the pipe breaks when the build ends.
    CloseHandle(WritePipe);
    WritePipe := 0;
    Job := CreateKillOnCloseJob;
    if Job <> 0 then
      AssignProcessToJobObject(Job, PI.hProcess);
    ResumeThread(PI.hThread);
    CloseHandle(PI.hThread);
    try
      Exited := False;
      repeat
        Drain;
        if WaitForSingleObject(PI.hProcess, 50) = WAIT_OBJECT_0 then
          Exited := True
        else if (Assigned(Cancelled) and Cancelled()) or
                ((Req.TimeoutSec > 0) and (Watch.ElapsedMilliseconds > Int64(Req.TimeoutSec) * 1000)) then
        begin
          Result.TimedOut := not (Assigned(Cancelled) and Cancelled());
          if Job <> 0 then
            TerminateJobObject(Job, 1)
          else
            TerminateProcess(PI.hProcess, 1);
          WaitForSingleObject(PI.hProcess, 5000);
          Exited := True;
        end;
      until Exited;
      Drain;
      GetExitCodeProcess(PI.hProcess, Code);
      Result.ExitCode := Code;
    finally
      CloseHandle(PI.hProcess);
    end;
    Result.ElapsedMs := Watch.ElapsedMilliseconds;
  finally
    if WritePipe <> 0 then
      CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
    if NulIn <> INVALID_HANDLE_VALUE then
      CloseHandle(NulIn);
    if Job <> 0 then
      CloseHandle(Job); // kills anything the build left running (msbuild nodes)
  end;
  Result.Output := DecodeOutput(Bytes);
  Result.Messages := ParseBuildOutput(Result.Output, ExtractFilePath(Req.ProjectFile));
  Result.Success := (Result.ExitCode = 0) and not Result.TimedOut and
    (Result.Count(bsError) = 0) and (Result.Count(bsFatal) = 0);
end;

{ TBuildRunner }

type
  TBuildThread = class(TThread)
  private
    FReq: TBuildRequest;
    FOnDone: TBuildDone;
    FRunner: TBuildRunner;
  protected
    procedure Execute; override;
  public
    constructor Create(Runner: TBuildRunner; const Req: TBuildRequest; const OnDone: TBuildDone);
  end;

constructor TBuildThread.Create(Runner: TBuildRunner; const Req: TBuildRequest; const OnDone: TBuildDone);
begin
  FRunner := Runner;
  FReq := Req;
  FOnDone := OnDone;
  inherited Create(False);
end;

procedure TBuildThread.Execute;
var
  R: TBuildResult;
begin
  try
    R := RunBuild(FReq,
      function: Boolean
      begin
        Result := Terminated;
      end);
  except
    on E: Exception do
    begin
      R := Default(TBuildResult);
      R.Error := E.ClassName + ': ' + E.Message;
    end;
  end;
  if Terminated then
    Exit;
  // Queued against this thread so Cancel/Destroy can drop it.
  Queue(
    procedure
    var
      Done: TBuildDone;
    begin
      Done := FOnDone;
      FOnDone := nil;
      FRunner.FFinished := FRunner.FThread;
      FRunner.FThread := nil;
      Done(R);
    end);
end;

destructor TBuildRunner.Destroy;
begin
  Cancel;
  FreeFinished;
  inherited;
end;

procedure TBuildRunner.FreeFinished;
begin
  if FFinished <> nil then
  begin
    FFinished.WaitFor;
    FreeAndNil(FFinished);
  end;
end;

function TBuildRunner.Busy: Boolean;
begin
  Result := FThread <> nil;
end;

procedure TBuildRunner.Start(const Req: TBuildRequest; const OnDone: TBuildDone);
begin
  if Busy then
    raise Exception.Create('A build is already running');
  FreeFinished;
  FThread := TBuildThread.Create(Self, Req, OnDone);
end;

procedure TBuildRunner.Cancel;
begin
  if FThread = nil then
    Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread); // also removes its queued completion
end;

initialization
  InitRegexes;
end.
