unit ClaudeCode.ConPty;

{ Runs a console program inside a Windows pseudo console (ConPTY, Windows 10 1809+).
  Output arrives through OnOutput in the main thread; input is written as UTF-8. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs;

type
  TConPtyOutputEvent = procedure(const Data: TBytes) of object;
  TConPtyExitEvent = procedure(ExitCode: Cardinal) of object;

  TConPtySession = class
  private
    FPseudoConsole: THandle;
    FInputWrite: THandle;
    FOutputRead: THandle;
    FProcess: THandle;
    FJob: THandle;
    FReader: TThread;
    FWatcher: TThread;
    FPendingLock: TCriticalSection;
    FPending: TBytes;
    FFlushQueued: Boolean;
    FClosing: Boolean;
    FExited: Boolean;
    FOnOutput: TConPtyOutputEvent;
    FOnExit: TConPtyExitEvent;
    function AppendOutput(const Buf; Count: Integer): Boolean;
    procedure FlushOutput;
    procedure ProcessExited(Code: Cardinal);
    procedure ClosePty;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(const CommandLine, WorkDir, EnvBlock: string; Cols, Rows: Integer);
    procedure Write(const Data: TBytes);
    procedure WriteText(const S: string);
    procedure Resize(Cols, Rows: Integer);
    procedure Close;
    function Running: Boolean;
    property OnOutput: TConPtyOutputEvent read FOnOutput write FOnOutput;
    property OnExit: TConPtyExitEvent read FOnExit write FOnExit;
  end;

function ConPtyAvailable: Boolean;
{ A job object that kills its processes when the handle is closed; 0 on failure. }
function CreateKillOnCloseJob: THandle;

implementation

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = $00020016;
  EXTENDED_STARTUPINFO_PRESENT_ = $00080000;

type
  TStartupInfoExW_ = record
    StartupInfo: TStartupInfoW;
    lpAttributeList: Pointer;
  end;

  TCreatePseudoConsole = function(Size: DWORD; hInput, hOutput: THandle; dwFlags: DWORD;
    out phPC: THandle): HRESULT; stdcall;
  TResizePseudoConsole = function(hPC: THandle; Size: DWORD): HRESULT; stdcall;
  TClosePseudoConsole = procedure(hPC: THandle); stdcall;

function InitializeProcThreadAttributeList_(lpAttributeList: Pointer; dwAttributeCount, dwFlags: DWORD;
  var lpSize: SIZE_T): BOOL; stdcall; external kernel32 name 'InitializeProcThreadAttributeList';
function UpdateProcThreadAttribute_(lpAttributeList: Pointer; dwFlags: DWORD; Attribute: DWORD_PTR;
  lpValue: Pointer; cbSize: SIZE_T; lpPreviousValue: Pointer; lpReturnSize: Pointer): BOOL; stdcall;
  external kernel32 name 'UpdateProcThreadAttribute';
procedure DeleteProcThreadAttributeList_(lpAttributeList: Pointer); stdcall;
  external kernel32 name 'DeleteProcThreadAttributeList';

var
  _CreatePseudoConsole: TCreatePseudoConsole;
  _ResizePseudoConsole: TResizePseudoConsole;
  _ClosePseudoConsole: TClosePseudoConsole;

type
  TJobObjectBasicLimitInformation_ = record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: SIZE_T;
    MaximumWorkingSetSize: SIZE_T;
    ActiveProcessLimit: DWORD;
    Affinity: ULONG_PTR;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;

  TIoCounters_ = record
    ReadOperationCount, WriteOperationCount, OtherOperationCount: UInt64;
    ReadTransferCount, WriteTransferCount, OtherTransferCount: UInt64;
  end;

  TJobObjectExtendedLimitInformation_ = record
    BasicLimitInformation: TJobObjectBasicLimitInformation_;
    IoInfo: TIoCounters_;
    ProcessMemoryLimit: SIZE_T;
    JobMemoryLimit: SIZE_T;
    PeakProcessMemoryUsed: SIZE_T;
    PeakJobMemoryUsed: SIZE_T;
  end;

const
  JobObjectExtendedLimitInformation_ = 9;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE_ = $2000;

function CreateJobObjectW_(lpJobAttributes: Pointer; lpName: PWideChar): THandle; stdcall;
  external kernel32 name 'CreateJobObjectW';
function SetInformationJobObject_(hJob: THandle; JobObjectInformationClass: Integer;
  lpJobObjectInformation: Pointer; cbJobObjectInformationLength: DWORD): BOOL; stdcall;
  external kernel32 name 'SetInformationJobObject';
function AssignProcessToJobObject(hJob, hProcess: THandle): BOOL; stdcall;
  external kernel32 name 'AssignProcessToJobObject';

function CreateKillOnCloseJob: THandle;
var
  Info: TJobObjectExtendedLimitInformation_;
begin
  Result := CreateJobObjectW_(nil, nil);
  if Result = 0 then
    Exit;
  FillChar(Info, SizeOf(Info), 0);
  Info.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE_;
  if not SetInformationJobObject_(Result, JobObjectExtendedLimitInformation_, @Info, SizeOf(Info)) then
  begin
    CloseHandle(Result);
    Result := 0;
  end;
end;

function ConPtyAvailable: Boolean;
var
  K: HMODULE;
begin
  if not Assigned(_CreatePseudoConsole) then
  begin
    K := GetModuleHandle(kernel32);
    @_CreatePseudoConsole := GetProcAddress(K, 'CreatePseudoConsole');
    @_ResizePseudoConsole := GetProcAddress(K, 'ResizePseudoConsole');
    @_ClosePseudoConsole := GetProcAddress(K, 'ClosePseudoConsole');
  end;
  Result := Assigned(_CreatePseudoConsole) and Assigned(_ResizePseudoConsole) and
    Assigned(_ClosePseudoConsole);
end;

// COORD passed by value: X (columns) in the low word, Y (rows) in the high word.
function PackSize(Cols, Rows: Integer): DWORD;
begin
  if Cols < 2 then Cols := 2;
  if Rows < 1 then Rows := 1;
  Result := DWORD(Word(Cols)) or (DWORD(Word(Rows)) shl 16);
end;

type
  TReaderThread = class(TThread)
  private
    FOwner: TConPtySession;
    FHandle: THandle;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TConPtySession; AHandle: THandle);
  end;

  TWatcherThread = class(TThread)
  private
    FOwner: TConPtySession;
    FProcess: THandle;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TConPtySession; AProcess: THandle);
  end;

{ TReaderThread }

constructor TReaderThread.Create(AOwner: TConPtySession; AHandle: THandle);
begin
  FOwner := AOwner;
  FHandle := AHandle;
  inherited Create(False);
end;

procedure TReaderThread.Execute;
var
  Buf: array[0..65535] of Byte;
  N: DWORD;
begin
  while not Terminated do
  begin
    if not ReadFile(FHandle, Buf[0], SizeOf(Buf), N, nil) or (N = 0) then
      Break;
    if FOwner.AppendOutput(Buf, N) then
      Queue(
        procedure
        begin
          FOwner.FlushOutput;
        end);
  end;
end;

{ TWatcherThread }

constructor TWatcherThread.Create(AOwner: TConPtySession; AProcess: THandle);
begin
  FOwner := AOwner;
  FProcess := AProcess;
  inherited Create(False);
end;

procedure TWatcherThread.Execute;
var
  Code: DWORD;
begin
  WaitForSingleObject(FProcess, INFINITE);
  if not GetExitCodeProcess(FProcess, Code) then
    Code := DWORD(-1);
  Queue(
    procedure
    begin
      FOwner.ProcessExited(Code);
    end);
end;

{ TConPtySession }

constructor TConPtySession.Create;
begin
  inherited Create;
  FPendingLock := TCriticalSection.Create;
end;

destructor TConPtySession.Destroy;
begin
  Close;
  FPendingLock.Free;
  inherited;
end;

function TConPtySession.Running: Boolean;
begin
  Result := (FProcess <> 0) and not FExited;
end;

procedure TConPtySession.Start(const CommandLine, WorkDir, EnvBlock: string; Cols, Rows: Integer);
var
  InRead, OutWrite: THandle;
  SI: TStartupInfoExW_;
  PI: TProcessInformation;
  AttrSize: SIZE_T;
  Cmd: string;
  Hr: HRESULT;
  Env: Pointer;
begin
  if not ConPtyAvailable then
    raise Exception.Create('ConPTY requires Windows 10 version 1809 or later');
  Close;
  FClosing := False;
  FExited := False;

  InRead := 0;
  OutWrite := 0;
  if not CreatePipe(InRead, FInputWrite, nil, 0) then
    RaiseLastOSError;
  if not CreatePipe(FOutputRead, OutWrite, nil, 0) then
    RaiseLastOSError;
  try
    Hr := _CreatePseudoConsole(PackSize(Cols, Rows), InRead, OutWrite, 0, FPseudoConsole);
    if Failed(Hr) then
      raise Exception.CreateFmt('CreatePseudoConsole failed (0x%.8x)', [Hr]);
  finally
    // The pseudo console holds its own duplicates.
    CloseHandle(InRead);
    CloseHandle(OutWrite);
  end;

  FillChar(SI, SizeOf(SI), 0);
  SI.StartupInfo.cb := SizeOf(SI);
  // Without this the child inherits the host's redirected stdio (if any) instead of the
  // pseudo console and e.g. Claude falls back to non-interactive --print mode.
  SI.StartupInfo.dwFlags := STARTF_USESTDHANDLES;
  AttrSize := 0;
  InitializeProcThreadAttributeList_(nil, 1, 0, AttrSize);
  GetMem(SI.lpAttributeList, AttrSize);
  try
    if not InitializeProcThreadAttributeList_(SI.lpAttributeList, 1, 0, AttrSize) then
      RaiseLastOSError;
    try
      // The value is the HPCON itself, not a pointer to it.
      if not UpdateProcThreadAttribute_(SI.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        Pointer(FPseudoConsole), SizeOf(THandle), nil, nil) then
        RaiseLastOSError;
      Cmd := CommandLine;
      UniqueString(Cmd);
      if EnvBlock <> '' then
        Env := PChar(EnvBlock)
      else
        Env := nil;
      FillChar(PI, SizeOf(PI), 0);
      // Start suspended so the process is in the job before it can spawn children.
      if not CreateProcessW(nil, PChar(Cmd), nil, nil, False,
        EXTENDED_STARTUPINFO_PRESENT_ or CREATE_UNICODE_ENVIRONMENT or CREATE_SUSPENDED, Env,
        PChar(WorkDir), SI.StartupInfo, PI) then
        RaiseLastOSError(GetLastError, '. Command: ' + CommandLine);
    finally
      DeleteProcThreadAttributeList_(SI.lpAttributeList);
    end;
  finally
    FreeMem(SI.lpAttributeList);
  end;
  FProcess := PI.hProcess;
  FJob := CreateKillOnCloseJob;
  if FJob <> 0 then
    AssignProcessToJobObject(FJob, FProcess);
  ResumeThread(PI.hThread);
  CloseHandle(PI.hThread);
  FReader := TReaderThread.Create(Self, FOutputRead);
  FWatcher := TWatcherThread.Create(Self, FProcess);
end;

function TConPtySession.AppendOutput(const Buf; Count: Integer): Boolean;
var
  L: Integer;
begin
  // Reader thread: coalesce output; True when the main thread must be told to flush.
  FPendingLock.Enter;
  try
    L := Length(FPending);
    SetLength(FPending, L + Count);
    Move(Buf, FPending[L], Count);
    Result := not FFlushQueued;
    FFlushQueued := True;
  finally
    FPendingLock.Leave;
  end;
end;

procedure TConPtySession.FlushOutput;
var
  Data: TBytes;
begin
  FPendingLock.Enter;
  try
    Data := FPending;
    FPending := nil;
    FFlushQueued := False;
  finally
    FPendingLock.Leave;
  end;
  if not FClosing and (Length(Data) > 0) and Assigned(FOnOutput) then
    FOnOutput(Data);
end;

procedure TConPtySession.ProcessExited(Code: Cardinal);
begin
  if FClosing or FExited then
    Exit;
  FExited := True;
  // Closing the pseudo console flushes the remaining output and ends the reader.
  ClosePty;
  if FReader <> nil then
    FReader.WaitFor;
  FlushOutput;
  if Assigned(FOnExit) then
    FOnExit(Code);
end;

procedure TConPtySession.ClosePty;
begin
  if FPseudoConsole <> 0 then
  begin
    _ClosePseudoConsole(FPseudoConsole);
    FPseudoConsole := 0;
  end;
  if FInputWrite <> 0 then
  begin
    CloseHandle(FInputWrite);
    FInputWrite := 0;
  end;
end;

procedure TConPtySession.Close;
begin
  FClosing := True;
  // Closing the pseudo console sends CTRL_CLOSE_EVENT to everything attached to it.
  ClosePty;
  if (FProcess <> 0) and (WaitForSingleObject(FProcess, 1500) = WAIT_TIMEOUT) then
    TerminateProcess(FProcess, 1);
  if FJob <> 0 then
  begin
    // Kills whatever the session left behind (shells, MCP servers, ...).
    CloseHandle(FJob);
    FJob := 0;
  end;
  if FReader <> nil then
  begin
    FReader.Terminate;
    FReader.WaitFor;
    FreeAndNil(FReader); // also drops its queued callbacks
  end;
  if FWatcher <> nil then
  begin
    FWatcher.WaitFor;
    FreeAndNil(FWatcher);
  end;
  if FOutputRead <> 0 then
  begin
    CloseHandle(FOutputRead);
    FOutputRead := 0;
  end;
  if FProcess <> 0 then
  begin
    CloseHandle(FProcess);
    FProcess := 0;
  end;
  FPending := nil;
  FFlushQueued := False;
end;

procedure TConPtySession.Write(const Data: TBytes);
var
  Written: DWORD;
  Off: Integer;
begin
  if (FInputWrite = 0) or (Length(Data) = 0) then
    Exit;
  Off := 0;
  while Off < Length(Data) do
  begin
    if not WriteFile(FInputWrite, Data[Off], Length(Data) - Off, Written, nil) or (Written = 0) then
      Exit;
    Inc(Off, Written);
  end;
end;

procedure TConPtySession.WriteText(const S: string);
begin
  Write(TEncoding.UTF8.GetBytes(S));
end;

procedure TConPtySession.Resize(Cols, Rows: Integer);
begin
  if FPseudoConsole <> 0 then
    _ResizePseudoConsole(FPseudoConsole, PackSize(Cols, Rows));
end;

end.
