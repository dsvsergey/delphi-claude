unit ClaudeCode.Process;

{ Running console programs with captured output (builds, test runners) and one-at-a-time
  background jobs whose completion is reported in the main thread.
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, ClaudeCode.Compat;

type
  TProcessResult = record
    Error: string;       // the process could not be started
    ExitCode: Cardinal;
    TimedOut: Boolean;
    Cancelled: Boolean;
    ElapsedMs: Int64;
    Output: string;      // stdout and stderr together
  end;

  { Runs in the background thread; polls Cancelled while it works. }
  TJobWork = reference to procedure(const Cancelled: TFunc<Boolean>);

  { Runs one job at a time. Done is called in the main thread unless the job is cancelled. }
  TJobRunner = class
  private
    FThread: TThread;
    FFinished: TThread;
    procedure FreeFinished;
  public
    destructor Destroy; override;
    procedure Start(const Work: TJobWork; const Done: TProc);
    function Busy: Boolean;
    { Stops a running job and waits for it; its Done is never called. }
    procedure Cancel;
  end;

{ Runs CommandLine hidden with stdin from NUL in a kill-on-close job (so child processes end
  with it) and returns its output. TimeoutSec <= 0 waits without limit. }
function RunProcess(const CommandLine, WorkDir: string; TimeoutSec: Integer;
  const Cancelled: TFunc<Boolean>): TProcessResult;
{ Console output: UTF-8 when valid, otherwise the OEM code page. }
function DecodeOutput(const Bytes: TBytes): string;
{ Command-line quoting for one argument. }
function QuoteArg(const S: string): string;

implementation

uses
  Winapi.Windows, System.Diagnostics, System.Math, ClaudeCode.ConPty, ClaudeCode.Utils;

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

function QuoteArg(const S: string): string;
begin
  if (S <> '') and (S.IndexOfAny([' ', #9, '"']) < 0) then
    Exit(S);
  Result := '"' + StringReplace(S, '"', '\"', [rfReplaceAll]) + '"';
end;

function RunProcess(const CommandLine, WorkDir: string; TimeoutSec: Integer;
  const Cancelled: TFunc<Boolean>): TProcessResult;
var
  SA: TSecurityAttributes;
  ReadPipe, WritePipe, NulIn, Job: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Dir: PChar;
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
  Result := Default(TProcessResult);
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
    Cmd := CommandLine;
    UniqueString(Cmd);
    FillChar(PI, SizeOf(PI), 0);
    if WorkDir <> '' then
      Dir := PChar(WorkDir)
    else
      Dir := nil;
    Watch := TStopwatch.StartNew;
    if not CreateProcess(nil, PChar(Cmd), nil, nil, True,
      CREATE_NO_WINDOW or CREATE_SUSPENDED or CREATE_UNICODE_ENVIRONMENT, nil, Dir, SI, PI) then
    begin
      Result.Error := 'Could not start ' + CommandLine + ': ' + SysErrorMessage(GetLastError);
      Exit;
    end;
    // The write end now lives in the child only, so the pipe breaks when it ends.
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
                ((TimeoutSec > 0) and (Watch.ElapsedMilliseconds > Int64(TimeoutSec) * 1000)) then
        begin
          Result.Cancelled := Assigned(Cancelled) and Cancelled();
          Result.TimedOut := not Result.Cancelled;
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
      CloseHandle(Job); // kills anything the process left running
  end;
  Result.Output := DecodeOutput(Bytes);
end;

{ TJobRunner }

type
  TJobThread = class(TThread)
  private
    FWork: TJobWork;
    FDone: TProc;
    FRunner: TJobRunner;
  protected
    procedure Execute; override;
  public
    constructor Create(Runner: TJobRunner; const Work: TJobWork; const Done: TProc);
  end;

constructor TJobThread.Create(Runner: TJobRunner; const Work: TJobWork; const Done: TProc);
begin
  FRunner := Runner;
  FWork := Work;
  FDone := Done;
  inherited Create(False);
end;

procedure TJobThread.Execute;
begin
  try
    FWork(
      function: Boolean
      begin
        Result := Terminated;
      end);
  except
    // The work reports its own errors through the variables it captured.
  end;
  if Terminated then
    Exit;
  // Queued against this thread so Cancel/Destroy can drop it.
  Queue(
    procedure
    var
      Done: TProc;
    begin
      Done := FDone;
      FDone := nil;
      FRunner.FFinished := FRunner.FThread;
      FRunner.FThread := nil;
      // From the message loop, where IDE services can wait for the IDE's own queued work.
      if Assigned(Done) then
        RunInMainLoop(Done);
    end);
end;

destructor TJobRunner.Destroy;
begin
  Cancel;
  FreeFinished;
  inherited;
end;

procedure TJobRunner.FreeFinished;
begin
  if FFinished <> nil then
  begin
    FFinished.WaitFor;
    FreeAndNil(FFinished);
  end;
end;

function TJobRunner.Busy: Boolean;
begin
  Result := FThread <> nil;
end;

procedure TJobRunner.Start(const Work: TJobWork; const Done: TProc);
begin
  if Busy then
    raise Exception.Create('A job is already running');
  FreeFinished;
  FThread := TJobThread.Create(Self, Work, Done);
end;

procedure TJobRunner.Cancel;
begin
  if FThread = nil then
    Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread); // also removes its queued completion
end;

end.
