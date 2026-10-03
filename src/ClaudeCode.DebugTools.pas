unit ClaudeCode.DebugTools;

{ Debugger tools: the state of the debugged process (threads, call stack, source around
  the current line, exception), evaluating expressions, source breakpoints and stepping.
  The Open Tools API has no list of local variables: Claude reads the code around the
  current line and evaluates what it needs. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ToolsAPI, ClaudeCode.Mcp;

function ToolGetDebugState(Args: TJSONObject): TToolResult;
function ToolEvaluateExpression(Args: TJSONObject): TToolResult;
function ToolSetBreakpoint(Args: TJSONObject): TToolResult;
function ToolListBreakpoints(Args: TJSONObject): TToolResult;
function ToolRemoveBreakpoint(Args: TJSONObject): TToolResult;
{ Runs or steps the process; Done is called when it stops again (or the wait ends). }
procedure ToolDebugControl(Args: TJSONObject; const Done: TToolDone);

{ Logpoints: breakpoints that record expression values and let the program run on. }
function ToolSetLogpoint(Args: TJSONObject): TToolResult;
function ToolGetLogpointHits(Args: TJSONObject): TToolResult;
function ToolRemoveLogpoint(Args: TJSONObject): TToolResult;
{ Runs Project under the debugger with the IDE's Run command (F9); waits for the first stop when
  WaitSec > 0. Params, when given, become the project's run parameters. }
procedure StartDebugging(const Project: IOTAProject; const Params: string; WaitSec: Integer; const Done: TToolDone);

{ A request for Claude describing why the debugged process is stopped, or '' when it is not. }
function DebugStopPrompt: string;
{ Drops a pending debugControl wait without answering it. }
procedure CancelDebugWaits;
{ Removes the logpoints (their breakpoints would stop the program without us) and timers. }
procedure ShutdownDebugTools;

implementation

uses
  Winapi.Windows, System.Math, System.DateUtils, System.Generics.Collections, Vcl.ExtCtrls, Vcl.ActnList,
  Vcl.Menus, ClaudeCode.Utils, ClaudeCode.IdeBackend, ClaudeCode.PascalIndex, ClaudeCode.CodeTools;

const
  STOPPED_STATES = [psStopped, psException, psFault, psResFault];
  STOP_SETTLE_TICKS = 6; // x 100 ms after a stop before the call stack is read
  EXCEPTION_STATES = [psException, psFault, psResFault];
  EVAL_TIMEOUT_MS = 5000;
  EVAL_BUFFER_CHARS = 64 * 1024;

function Debugger: IOTADebuggerServices;
begin
  Result := BorlandIDEServices as IOTADebuggerServices;
end;

function CurrentProcess: IOTAProcess;
begin
  Result := Debugger.CurrentProcess;
end;

function ProcessStateName(S: TOTAProcessState): string;
const
  Names: array[TOTAProcessState] of string = ('nothing', 'running', 'stopping', 'stopped', 'fault',
    'resourceFault', 'terminated', 'exception', 'noProcess');
begin
  Result := Names[S];
end;

function ThreadStateName(S: TOTAThreadState): string;
const
  Names: array[TOTAThreadState] of string = ('stopped', 'runnable', 'blocked', 'none', 'other');
begin
  Result := Names[S];
end;

function IsStopped(const P: IOTAProcess): Boolean;
begin
  Result := (P <> nil) and (P.ProcessState in STOPPED_STATES);
end;

{ Evaluation }

type
  TEvalWaiter = class(TNotifierObject, IOTAThreadNotifier, IOTAThreadNotifier160)
  public
    Completed: Boolean;
    ResultText: string;
    ReturnCode: Integer;
    procedure ThreadNotify(Reason: TOTANotifyReason);
    procedure EvaluateComplete(const ExprStr, ResultStr: string; CanModify: Boolean;
      ResultAddress, ResultSize: LongWord; ReturnCode: Integer); overload;
    procedure EvaluateComplete(const ExprStr, ResultStr: string; CanModify: Boolean;
      ResultAddress: TOTAAddress; ResultSize: LongWord; ReturnCode: Integer); overload;
    procedure ModifyComplete(const ExprStr, ResultStr: string; ReturnCode: Integer);
  end;

procedure TEvalWaiter.ThreadNotify(Reason: TOTANotifyReason);
begin
end;

procedure TEvalWaiter.EvaluateComplete(const ExprStr, ResultStr: string; CanModify: Boolean;
  ResultAddress, ResultSize: LongWord; ReturnCode: Integer);
begin
  ResultText := ResultStr;
  Self.ReturnCode := ReturnCode;
  Completed := True;
end;

procedure TEvalWaiter.EvaluateComplete(const ExprStr, ResultStr: string; CanModify: Boolean;
  ResultAddress: TOTAAddress; ResultSize: LongWord; ReturnCode: Integer);
begin
  ResultText := ResultStr;
  Self.ReturnCode := ReturnCode;
  Completed := True;
end;

procedure TEvalWaiter.ModifyComplete(const ExprStr, ResultStr: string; ReturnCode: Integer);
begin
end;

{ Evaluates Expr in the context of Thread. False with the reason in Value on failure. }
function EvaluateSync(const Thread: IOTAThread; const Expr: string; SideEffects: Boolean;
  out Value: string; out CanModify: Boolean): Boolean;
var
  Buf: array of Char;
  Addr: TOTAAddress;
  Size, Val: LongWord;
  R: TOTAEvaluateResult;
  Waiter: TEvalWaiter;
  Notifier: IOTAThreadNotifier;
  Index: Integer;
  Deadline: TDateTime;
begin
  Value := '';
  CanModify := False;
  SetLength(Buf, EVAL_BUFFER_CHARS);
  Buf[0] := #0;
  R := Thread.Evaluate(Expr, PChar(Buf), Length(Buf), CanModify, SideEffects, nil, Addr, Size, Val);
  case R of
    erOK:
      begin
        Value := PChar(Buf);
        Result := True;
      end;
    erError:
      begin
        Value := PChar(Buf);
        if Value = '' then
          Value := 'Cannot evaluate ' + Expr;
        Result := False;
      end;
    erBusy:
      begin
        Value := 'The debugger is busy';
        Result := False;
      end;
  else
    // erDeferred: the result arrives through the thread notifier.
    Waiter := TEvalWaiter.Create;
    Notifier := Waiter;
    Index := Thread.AddNotifier(Notifier);
    try
      Deadline := IncMilliSecond(Now, EVAL_TIMEOUT_MS);
      while not Waiter.Completed and (Now < Deadline) do
      begin
        Debugger.ProcessDebugEvents;
        Sleep(5);
      end;
    finally
      Thread.RemoveNotifier(Index);
    end;
    if not Waiter.Completed then
    begin
      Value := 'Evaluation timed out';
      Result := False;
    end
    else
    begin
      Value := Waiter.ResultText;
      Result := Waiter.ReturnCode = 0;
    end;
  end;
end;

{ Source around a line, numbered, the line itself marked with ">". }
function SourceSnippet(const FileName: string; Line, Context: Integer): string;
var
  Text: string;
  Buffer: IOTAEditBuffer;
  Lines: TStringList;
  I: Integer;
begin
  Result := '';
  if (FileName = '') or (Line <= 0) or (Context < 0) then
    Exit;
  Buffer := FindEditBuffer(FileName);
  if Buffer <> nil then
    Text := Utf8BytesToString(ReadBufferBytes(Buffer, 0, MaxInt))
  else if not ReadTextFileAutoEnc(FileName, Text) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for I := Max(1, Line - Context) to Min(Lines.Count, Line + Context) do
      if I = Line then
        Result := Result + Format('>%5d: %s', [I, Lines[I - 1]]) + #10
      else
        Result := Result + Format(' %5d: %s', [I, Lines[I - 1]]) + #10;
  finally
    Lines.Free;
  end;
end;

{ The routine around a source line, from the code (ClaudeCode.PascalIndex): "TOrder.CalcTotal". }
function RoutineAt(const FileName: string; Line: Integer): string;
var
  Info: TPasUnitInfo;
  D: TPasDecl;
begin
  Result := '';
  if (FileName = '') or not UnitInfoOf(FileName, Info) then
    Exit;
  for D in Info.Decls do
    if (D.Kind in [pdMethodImpl, pdRoutine]) and (D.Line <= Line) and (D.EndLine >= Line) and (D.EndLine > D.Line) then
      Result := D.QualifiedName; // the last (innermost) match wins
end;

function CallStackJson(const Thread: IOTAThread; MaxFrames: Integer): TJSONArray;
var
  State: TOTACallStackState;
  Deadline: TDateTime;
  I, Line: Integer;
  FileName, Routine: string;
  Frame: TJSONObject;
begin
  Result := TJSONArray.Create;
  State := Thread.StartCallStackAccess;
  try
    Deadline := IncMilliSecond(Now, 2000);
    while (State = csWait) and (Now < Deadline) do
    begin
      Debugger.ProcessDebugEvents;
      Sleep(10);
      Thread.EndCallStackAccess;
      State := Thread.StartCallStackAccess;
    end;
    if State <> csAccessible then
      Exit;
    for I := 0 to Min(Thread.CallCount, MaxFrames) - 1 do
    begin
      Frame := TJSONObject.Create;
      Frame.AddPair('index', TJSONNumber.Create(I));
      // Not Thread.CallHeaders: formatting the headers (with parameter values) makes the Delphi 13
      // debugger kernel assert ("item.src" in DBKIMPL.CPP). The routine comes from the source.
      Thread.GetCallPos(I, FileName, Line);
      if FileName <> '' then
      begin
        Routine := RoutineAt(FileName, Line);
        if Routine = '' then
          Routine := ChangeFileExt(ExtractFileName(FileName), '');
        Frame.AddPair('call', Routine);
        Frame.AddPair('file', FileName);
        Frame.AddPair('line', TJSONNumber.Create(Line));
      end
      else
        Frame.AddPair('call', '(no source)');
      Result.Add(Frame);
    end;
  finally
    Thread.EndCallStackAccess;
  end;
end;

function ExceptionJson(const Thread: IOTAThread): TJSONObject;
var
  Value: string;
  CanModify: Boolean;
begin
  // Best effort: at an exception notification the RTL usually has the object in ExceptObject.
  Result := TJSONObject.Create;
  if EvaluateSync(Thread, 'ExceptObject.ClassName', True, Value, CanModify) then
    Result.AddPair('class', Value);
  if EvaluateSync(Thread, 'Exception(ExceptObject).Message', True, Value, CanModify) then
    Result.AddPair('message', Value);
end;

function DebugStateJson(MaxFrames, Context: Integer): TJSONObject;
var
  P: IOTAProcess;
  T: IOTAThread;
  Threads: TJSONArray;
  Th, Ex: TJSONObject;
  I: Integer;
begin
  Result := TJSONObject.Create;
  P := CurrentProcess;
  if P = nil then
  begin
    Result.AddPair('state', 'noProcess');
    Result.AddPair('hint', 'Nothing is being debugged. The user starts debugging with Run (F9).');
    Exit;
  end;
  Result.AddPair('state', ProcessStateName(P.ProcessState));
  Result.AddPair('exe', P.ExeName);
  Result.AddPair('processId', TJSONNumber.Create(P.OSProcessId));
  Result.AddPair('status', P.Status);
  Result.AddPair('location', P.Location);
  if not IsStopped(P) then
    Exit;

  T := P.CurrentThread;
  if T <> nil then
  begin
    Th := TJSONObject.Create;
    Th.AddPair('id', TJSONNumber.Create(T.OSThreadID));
    Th.AddPair('name', T.ThreadName);
    Th.AddPair('state', ThreadStateName(T.State));
    Th.AddPair('status', T.Status);
    Th.AddPair('location', T.Location);
    if T.CurrentFile <> '' then
    begin
      Th.AddPair('file', T.CurrentFile);
      Th.AddPair('line', TJSONNumber.Create(T.CurrentLine));
      Th.AddPair('source', SourceSnippet(T.CurrentFile, T.CurrentLine, Context));
    end;
    Th.AddPair('callStack', CallStackJson(T, MaxFrames));
    Result.AddPair('currentThread', Th);
    if P.ProcessState in EXCEPTION_STATES then
    begin
      Ex := ExceptionJson(T);
      if Ex.Count > 0 then
        Result.AddPair('exception', Ex)
      else
        Ex.Free;
    end;
  end;

  Threads := TJSONArray.Create;
  for I := 0 to P.ThreadCount - 1 do
  begin
    T := P.Threads[I];
    Th := TJSONObject.Create;
    Th.AddPair('id', TJSONNumber.Create(T.OSThreadID));
    Th.AddPair('name', T.ThreadName);
    Th.AddPair('state', ThreadStateName(T.State));
    Th.AddPair('location', T.Location);
    Threads.Add(Th);
  end;
  Result.AddPair('threads', Threads);
end;

function IntArg(Args: TJSONObject; const Name: string; Default: Integer): Integer;
begin
  Result := Trunc(StrToFloatDef(JsonStr(Args, Name), Default, TFormatSettings.Invariant));
end;

{ Tools }

function ToolGetDebugState(Args: TJSONObject): TToolResult;
begin
  Result := TToolResult.Json(DebugStateJson(IntArg(Args, 'maxFrames', 30), IntArg(Args, 'contextLines', 6)));
end;

function ToolEvaluateExpression(Args: TJSONObject): TToolResult;
var
  P: IOTAProcess;
  Expr, Value: string;
  CanModify: Boolean;
  Obj: TJSONObject;
begin
  Expr := Trim(JsonStr(Args, 'expression'));
  if Expr = '' then
    Exit(TToolResult.Error('"expression" is required'));
  P := CurrentProcess;
  if not IsStopped(P) or (P.CurrentThread = nil) then
    Exit(TToolResult.Error('The debugged process must be stopped (breakpoint, exception or pause) to evaluate'));
  if not EvaluateSync(P.CurrentThread, Expr, JsonBool(Args, 'allowSideEffects', False), Value, CanModify) then
    Exit(TToolResult.Error(Value));
  Obj := TJSONObject.Create;
  Obj.AddPair('expression', Expr);
  Obj.AddPair('value', Value);
  Result := TToolResult.Json(Obj);
end;

function FindSourceBreakpoint(const FileName: string; Line: Integer): IOTABreakpoint;
var
  I: Integer;
  B: IOTASourceBreakpoint;
begin
  Result := nil;
  for I := 0 to Debugger.SourceBkptCount - 1 do
  begin
    B := Debugger.SourceBkpts[I];
    if SameFileName(B.FileName, FileName) and (B.LineNumber = Line) then
      Exit(B);
  end;
end;

function IsLogpointStop(const P: IOTAProcess): Boolean; forward;
function LogpointIdOf(const B: IOTABreakpoint): Integer; forward;

function BreakpointJson(const B: IOTABreakpoint): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('file', B.FileName);
  Result.AddPair('line', TJSONNumber.Create(B.LineNumber));
  Result.AddPair('enabled', TJSONBool.Create(B.Enabled));
  if B.Expression <> '' then
    Result.AddPair('condition', B.Expression);
  if B.PassCount > 0 then
    Result.AddPair('passCount', TJSONNumber.Create(B.PassCount));
  if LogpointIdOf(B) > 0 then
    Result.AddPair('logpoint', TJSONNumber.Create(LogpointIdOf(B)));
end;

function ToolSetBreakpoint(Args: TJSONObject): TToolResult;
var
  FileName: string;
  Line: Integer;
  B: IOTABreakpoint;
  Existed: Boolean;
  Obj: TJSONObject;
begin
  FileName := PathFromUri(JsonStr(Args, 'file'));
  Line := IntArg(Args, 'line', 0);
  if (FileName = '') or (Line <= 0) then
    Exit(TToolResult.Error('"file" and "line" (1-based) are required'));
  B := FindSourceBreakpoint(FileName, Line);
  Existed := B <> nil;
  if B = nil then
    B := Debugger.NewSourceBreakpoint(FileName, Line, nil);
  if B = nil then
    Exit(TToolResult.Error('The IDE did not create the breakpoint'));
  if Args.GetValue('condition') <> nil then
    B.Expression := JsonStr(Args, 'condition');
  if Args.GetValue('passCount') <> nil then
    B.PassCount := IntArg(Args, 'passCount', 0);
  B.Enabled := JsonBool(Args, 'enabled', True);
  Obj := BreakpointJson(B);
  Obj.AddPair('updatedExisting', TJSONBool.Create(Existed));
  Result := TToolResult.Json(Obj);
end;

function ToolListBreakpoints(Args: TJSONObject): TToolResult;
var
  Arr: TJSONArray;
  I: Integer;
begin
  Arr := TJSONArray.Create;
  for I := 0 to Debugger.SourceBkptCount - 1 do
    Arr.Add(BreakpointJson(Debugger.SourceBkpts[I]));
  Result := TToolResult.Json(TJSONObject.Create.AddPair('breakpoints', Arr));
end;

function ToolRemoveBreakpoint(Args: TJSONObject): TToolResult;
var
  FileName: string;
  Line: Integer;
  B: IOTABreakpoint;
begin
  FileName := PathFromUri(JsonStr(Args, 'file'));
  Line := IntArg(Args, 'line', 0);
  B := FindSourceBreakpoint(FileName, Line);
  if B = nil then
    Exit(TToolResult.Error(Format('No breakpoint at %s:%d', [FileName, Line])));
  Debugger.RemoveBreakpoint(B);
  Result := TToolResult.Ok([Format('Removed the breakpoint at %s:%d', [ExtractFileName(FileName), Line])]);
end;

{ debugControl: run/step and wait for the next stop }

type
  TStopWait = class
  private
    FTimer: TTimer;
    FDone: TToolDone;
    FDeadline: TDateTime;
    FStartedAt: TDateTime;
    FSawRunning: Boolean;
    FSawProcess: Boolean;
    FUntilRunning: Boolean; // start without waitSec: done once the program runs
    FStoppedTicks: Integer; // consecutive ticks in the stopped state
    FAction: string;
    procedure Tick(Sender: TObject);
    procedure DoTick;
    procedure Finish(const Note: string);
  public
    constructor Create(const Action: string; WaitSec: Integer; const Done: TToolDone);
    destructor Destroy; override;
  end;

var
  PendingWait: TStopWait;

constructor TStopWait.Create(const Action: string; WaitSec: Integer; const Done: TToolDone);
begin
  inherited Create;
  FAction := Action;
  FDone := Done;
  FStartedAt := Now;
  FDeadline := IncSecond(Now, WaitSec);
  FTimer := TTimer.Create(nil);
  FTimer.Interval := 100;
  FTimer.OnTimer := Tick;
end;

destructor TStopWait.Destroy;
begin
  FTimer.Free;
  inherited;
end;

procedure TStopWait.Finish(const Note: string);
var
  Done: TToolDone;
  Obj: TJSONObject;
begin
  FTimer.Enabled := False;
  Done := FDone;
  FDone := nil;
  if PendingWait = Self then
    PendingWait := nil;
  Obj := DebugStateJson(30, 6);
  Obj.AddPair('action', FAction);
  if Note <> '' then
    Obj.AddPair('note', Note);
  // Free after the callback: this object's timer is on the call stack.
  TThread.ForceQueue(nil,
    procedure
    begin
      Free;
    end);
  if Assigned(Done) then
    Done(TToolResult.Json(Obj));
end;

procedure TStopWait.Tick(Sender: TObject);
begin
  try
    DoTick;
  except
    on E: Exception do
      Finish('Waiting failed: ' + E.Message);
  end;
end;

procedure TStopWait.DoTick;
var
  P: IOTAProcess;
begin
  P := CurrentProcess;
  if (P = nil) or (P.ProcessState in [psTerminated, psNoProcess, psNothing]) then
  begin
    // A process being started appears after the IDE has compiled it.
    if FSawProcess then
    begin
      Finish('The process ended');
      Exit;
    end;
    if Now >= FDeadline then
      Finish('The program did not start. If it does not compile, the errors are in the IDE Messages ' +
        'window (buildProject returns them).');
    Exit;
  end;
  FSawProcess := True;
  if FUntilRunning and (P.ProcessState = psRunning) then
  begin
    Finish('The program is running. Logpoints record while it runs; getDebugState or debugControl ' +
      '"pause" shows where it is.');
    Exit;
  end;
  // A program being started reads "stopped" while the debugger kernel loads it; asking it for
  // threads or call stacks then breaks the kernel ("Invalid debugger request"). Wait until it runs.
  if (FAction = 'start') and not FSawRunning and (P.ProcessState <> psRunning) then
  begin
    if Now >= FDeadline then
      Finish('The program did not start running');
    Exit;
  end;
  if P.ProcessState = psRunning then
    FSawRunning := True
  // A logpoint stop is not a stop for Claude: the logpoint lets the program run on.
  else if IsStopped(P) and IsLogpointStop(P) then
  begin
    FSawRunning := True;
    FStoppedTicks := 0;
  end
  // Right after Run the state may still read "stopped" for a moment. And right after a stop the
  // IDE is still updating its debug views; reading the call stack then makes the debugger kernel
  // assert ("item.src"), so the state is read once the stop has settled.
  else if IsStopped(P) and (FSawRunning or (MilliSecondsBetween(Now, FStartedAt) > 600)) then
  begin
    Inc(FStoppedTicks);
    if FStoppedTicks >= STOP_SETTLE_TICKS then
    begin
      Finish('');
      Exit;
    end;
  end;
  if not IsStopped(P) then
    FStoppedTicks := 0;
  if Now >= FDeadline then
    Finish('Still running when the wait ended; call getDebugState later or debugControl with "pause"');
end;

procedure CancelDebugWaits;
begin
  if PendingWait <> nil then
  begin
    PendingWait.FDone := nil;
    PendingWait.FTimer.Enabled := False;
    FreeAndNil(PendingWait);
  end;
end;

procedure ToolDebugControl(Args: TJSONObject; const Done: TToolDone);
var
  P: IOTAProcess;
  Action: string;
  Mode: TOTARunMode;
  WaitSec: Integer;
begin
  P := CurrentProcess;
  Action := JsonStr(Args, 'action');
  if P = nil then
  begin
    Done(TToolResult.Error('Nothing is being debugged. The user starts debugging with Run (F9).'));
    Exit;
  end;
  if PendingWait <> nil then
  begin
    Done(TToolResult.Error('Another debugControl call is still waiting'));
    Exit;
  end;
  if Action = 'pause' then
  begin
    P.Pause;
    WaitSec := IntArg(Args, 'waitSec', 5);
  end
  else if Action = 'terminate' then
  begin
    P.Terminate;
    Done(TToolResult.Ok(['Terminated the debugged process']));
    Exit;
  end
  else
  begin
    if Action = 'run' then
      Mode := ormRun
    else if Action = 'stepOver' then
      Mode := ormStmtStepOver
    else if Action = 'stepInto' then
      Mode := ormStmtStepInto
    else if Action = 'runUntilReturn' then
      Mode := ormRunUntilReturn
    else if Action = 'runToCursor' then
      Mode := ormRunToCursor
    else
    begin
      Done(TToolResult.Error('action must be run, stepOver, stepInto, runUntilReturn, runToCursor, pause or terminate'));
      Exit;
    end;
    if not IsStopped(P) then
    begin
      Done(TToolResult.Error('The process is running; use "pause" first'));
      Exit;
    end;
    if Mode = ormRun then
      WaitSec := IntArg(Args, 'waitSec', 0)
    else
      WaitSec := IntArg(Args, 'waitSec', 10);
    P.Run(Mode);
  end;
  if WaitSec <= 0 then
  begin
    Done(TToolResult.Ok([Format('%s: the process is running', [Action])]));
    Exit;
  end;
  PendingWait := TStopWait.Create(Action, WaitSec, Done);
end;

{ Logpoints }

type
  TLogHit = record
    Index: Integer;
    Time: TDateTime;
    ThreadId: Cardinal;
    Values: TArray<string>;
    Stack: TArray<string>;
  end;

  TLogpoint = class
  public
    Id: Integer;
    FileName: string;
    Line: Integer;
    Expressions: TArray<string>;
    Condition: string;
    MaxHits: Integer;
    StackFrames: Integer;
    HitCount: Integer;
    Breakpoint: IOTABreakpoint;
    Hits: TList<TLogHit>;
    Created: TDateTime;
    constructor Create;
    destructor Destroy; override;
    function Exhausted: Boolean;
  end;

  { Owns the logpoints. A logpoint is an ordinary breakpoint; when the program has stopped on its
    line (and the IDE has finished handling the stop), a timer records the values and runs it on.
    Breakpoint notifiers are not used: evaluating from their Trigger breaks the debugger kernel. }
  TLogpoints = class
  private
    FItems: TObjectList<TLogpoint>;
    FTimer: TTimer;
    FNextId: Integer;
    FStopTicks: Integer; // consecutive ticks the process has been stopped
    FRunningPid: Cardinal; // the process seen running; a new one is not touched until it runs
    FBusy: Boolean;
    // A hit whose call stack is still being read: the stack becomes accessible only after the
    // IDE has been back in its message loop, so it is read on later ticks.
    FStackOf: TLogpoint;
    FStackHit: TLogHit;
    FStackTicks: Integer;
    procedure Tick(Sender: TObject);
    function AtStop(const P: IOTAProcess): TLogpoint;
    function RecordValues(LP: TLogpoint; const P: IOTAProcess): TLogHit;
    procedure FinishHit(LP: TLogpoint; const H: TLogHit; const P: IOTAProcess);
    function TryReadStack(LP: TLogpoint; const P: IOTAProcess; var H: TLogHit): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(const FileName: string; Line: Integer; const Exprs: TArray<string>; const Condition: string;
      MaxHits, StackFrames: Integer; out Err: string): TLogpoint;
    function Find(Id: Integer): TLogpoint;
    function FindByBreakpoint(const B: IOTABreakpoint): TLogpoint;
    procedure Remove(LP: TLogpoint);
    property Items: TObjectList<TLogpoint> read FItems;
  end;

var
  Logpoints: TLogpoints;

function LP: TLogpoints;
begin
  if Logpoints = nil then
    Logpoints := TLogpoints.Create;
  Result := Logpoints;
end;

constructor TLogpoint.Create;
begin
  inherited Create;
  Hits := TList<TLogHit>.Create;
  Created := Now;
end;

destructor TLogpoint.Destroy;
begin
  Hits.Free;
  inherited;
end;

function TLogpoint.Exhausted: Boolean;
begin
  Result := (MaxHits > 0) and (HitCount >= MaxHits);
end;

constructor TLogpoints.Create;
begin
  inherited Create;
  FItems := TObjectList<TLogpoint>.Create(True);
  FTimer := TTimer.Create(nil);
  FTimer.Interval := 100;
  FTimer.OnTimer := Tick;
end;

destructor TLogpoints.Destroy;
begin
  FTimer.Free;
  while FItems.Count > 0 do
    Remove(FItems.Last);
  FItems.Free;
  inherited;
end;

function TLogpoints.Add(const FileName: string; Line: Integer; const Exprs: TArray<string>; const Condition: string;
  MaxHits, StackFrames: Integer; out Err: string): TLogpoint;
var
  B: IOTABreakpoint;
  B50: IOTABreakpoint50;
begin
  Result := nil;
  Err := '';
  B := FindSourceBreakpoint(FileName, Line);
  if (B <> nil) and (FindByBreakpoint(B) = nil) then
  begin
    Err := Format('There is already a breakpoint at %s:%d; remove it first (removeBreakpoint)',
      [ExtractFileName(FileName), Line]);
    Exit;
  end;
  if B <> nil then
    Remove(FindByBreakpoint(B));
  B := Debugger.NewSourceBreakpoint(FileName, Line, nil);
  if B = nil then
  begin
    Err := 'The IDE did not create the breakpoint';
    Exit;
  end;
  Result := TLogpoint.Create;
  Inc(FNextId);
  Result.Id := FNextId;
  Result.FileName := FileName;
  Result.Line := Line;
  Result.Expressions := Exprs;
  Result.Condition := Condition;
  Result.MaxHits := MaxHits;
  Result.StackFrames := StackFrames;
  Result.Breakpoint := B;
  B.Expression := Condition;
  B.Enabled := True;
  if Supports(B, IOTABreakpoint50, B50) then
    B50.GroupName := 'Claude logpoints';
  FItems.Add(Result);
  FTimer.Enabled := True;
end;

function TLogpoints.Find(Id: Integer): TLogpoint;
var
  X: TLogpoint;
begin
  for X in FItems do
    if X.Id = Id then
      Exit(X);
  Result := nil;
end;

function TLogpoints.FindByBreakpoint(const B: IOTABreakpoint): TLogpoint;
var
  X: TLogpoint;
begin
  for X in FItems do
    if X.Breakpoint = B then
      Exit(X);
  Result := nil;
end;

procedure TLogpoints.Remove(LP: TLogpoint);
begin
  if LP = nil then
    Exit;
  try
    if LP.Breakpoint <> nil then
      Debugger.RemoveBreakpoint(LP.Breakpoint);
  except
    // The IDE may have removed it already (the user deleted it).
  end;
  LP.Breakpoint := nil;
  FItems.Remove(LP);
end;

function TLogpoints.AtStop(const P: IOTAProcess): TLogpoint;
var
  T: IOTAThread;
  X: TLogpoint;
begin
  Result := nil;
  if not IsStopped(P) or (P.ProcessState in EXCEPTION_STATES) then
    Exit;
  // A stop on the line of an active logpoint.
  T := P.CurrentThread;
  if (T = nil) or (T.CurrentFile = '') then
    Exit;
  for X in FItems do
    if not X.Exhausted and (X.Line = Integer(T.CurrentLine)) and SameFileName(X.FileName, T.CurrentFile) then
      Exit(X);
end;

function TLogpoints.RecordValues(LP: TLogpoint; const P: IOTAProcess): TLogHit;
var
  T: IOTAThread;
  Expr, Value: string;
  CanModify: Boolean;
begin
  T := P.CurrentThread;
  Inc(LP.HitCount);
  Result.Index := LP.HitCount;
  Result.Time := Now;
  Result.ThreadId := 0;
  Result.Values := nil;
  Result.Stack := nil;
  if T = nil then
    Exit;
  Result.ThreadId := T.OSThreadID;
  for Expr in LP.Expressions do
  begin
    if not EvaluateSync(T, Expr, False, Value, CanModify) then
      Value := '<' + Value + '>';
    Result.Values := Result.Values + [Value];
  end;
end;

function TLogpoints.TryReadStack(LP: TLogpoint; const P: IOTAProcess; var H: TLogHit): Boolean;
var
  T: IOTAThread;
  State: TOTACallStackState;
  I, Line: Integer;
  FileName, S: string;
begin
  // One non-blocking attempt; True when done (read, or no thread to read).
  T := P.CurrentThread;
  if T = nil then
    Exit(True);
  State := T.StartCallStackAccess;
  try
    Result := State = csAccessible;
    if not Result then
      Exit;
    for I := 0 to System.Math.Min(T.CallCount, LP.StackFrames) - 1 do
    begin
      // Not CallHeaders (see CallStackJson).
      T.GetCallPos(I, FileName, Line);
      if FileName <> '' then
        S := Format('%s (%s:%d)', [RoutineAt(FileName, Line), ExtractFileName(FileName), Line])
      else
        S := '(no source)';
      H.Stack := H.Stack + [S];
    end;
  finally
    T.EndCallStackAccess;
  end;
end;

procedure TLogpoints.FinishHit(LP: TLogpoint; const H: TLogHit; const P: IOTAProcess);
begin
  LP.Hits.Add(H);
  // Keep the log bounded; the counter still counts every hit.
  if LP.Hits.Count > 2000 then
    LP.Hits.Delete(0);
  if LP.Exhausted and (LP.Breakpoint <> nil) then
    LP.Breakpoint.Enabled := False;
  P.Run(ormRun);
end;

procedure TLogpoints.Tick(Sender: TObject);
var
  P: IOTAProcess;
  X: TLogpoint;
begin
  if FBusy then
    Exit;
  FBusy := True;
  try
    try
      P := CurrentProcess;
      if P = nil then
      begin
        FStopTicks := 0;
        FRunningPid := 0;
        FStackOf := nil;
        Exit;
      end;
      // Finishing a hit that waits for its call stack.
      if FStackOf <> nil then
      begin
        if not IsStopped(P) then
        begin
          FStackOf := nil;
          Exit;
        end;
        Inc(FStackTicks);
        // See STOP_SETTLE_TICKS: not while the IDE is still updating its views for this stop.
        if (FStackTicks >= STOP_SETTLE_TICKS) and (TryReadStack(FStackOf, P, FStackHit) or (FStackTicks > 30)) then
        begin
          X := FStackOf;
          FStackOf := nil;
          FinishHit(X, FStackHit, P);
        end;
        Exit;
      end;
      if P.ProcessState = psRunning then
        FRunningPid := P.OSProcessId;
      // Not before the program has run: while the kernel loads it, it only looks stopped.
      if not IsStopped(P) or (FRunningPid <> P.OSProcessId) then
      begin
        FStopTicks := 0;
        Exit;
      end;
      // Give the IDE a moment to finish its own handling of the stop before evaluating.
      Inc(FStopTicks);
      if FStopTicks < 3 then
        Exit;
      X := AtStop(P);
      if X = nil then
        Exit;
      FStopTicks := 0;
      FStackHit := RecordValues(X, P);
      if X.StackFrames > 0 then
      begin
        FStackOf := X;
        FStackTicks := 0;
      end
      else
        FinishHit(X, FStackHit, P);
    except
      on E: Exception do
        Log('Logpoint: ' + E.Message);
    end;
  finally
    FBusy := False;
  end;
end;

function IsLogpointStop(const P: IOTAProcess): Boolean;
begin
  Result := (Logpoints <> nil) and ((Logpoints.FStackOf <> nil) or (Logpoints.AtStop(P) <> nil));
end;

function LogpointIdOf(const B: IOTABreakpoint): Integer;
var
  X: TLogpoint;
begin
  Result := 0;
  if Logpoints <> nil then
  begin
    X := Logpoints.FindByBreakpoint(B);
    if X <> nil then
      Result := X.Id;
  end;
end;

function StringsArg(Args: TJSONObject; const ArrayName, SingleName: string): TArray<string>;
var
  V: TJSONValue;
  Item: TJSONValue;
begin
  Result := nil;
  V := Args.GetValue(ArrayName);
  if V is TJSONArray then
  begin
    for Item in TJSONArray(V) do
      if Trim(Item.Value) <> '' then
        Result := Result + [Trim(Item.Value)];
  end
  else if (V is TJSONString) and (Trim(V.Value) <> '') then
    Result := [Trim(V.Value)];
  if (Result = nil) and (Trim(JsonStr(Args, SingleName)) <> '') then
    Result := [Trim(JsonStr(Args, SingleName))];
end;

function ToolSetLogpoint(Args: TJSONObject): TToolResult;
var
  FileName, Err: string;
  Line: Integer;
  Exprs: TArray<string>;
  X: TLogpoint;
  Obj: TJSONObject;
begin
  FileName := PathFromUri(JsonStr(Args, 'file'));
  Line := IntArg(Args, 'line', 0);
  if (FileName = '') or (Line <= 0) then
    Exit(TToolResult.Error('"file" and "line" (1-based) are required'));
  Exprs := StringsArg(Args, 'expressions', 'expression');
  if Length(Exprs) = 0 then
    Exit(TToolResult.Error('"expressions" is required: the Delphi expressions to record on each hit'));
  X := LP.Add(FileName, Line, Exprs, JsonStr(Args, 'condition'), IntArg(Args, 'maxHits', 100),
    IntArg(Args, 'stackFrames', 0), Err);
  if X = nil then
    Exit(TToolResult.Error(Err));
  Obj := TJSONObject.Create;
  Obj.AddPair('logpoint', TJSONNumber.Create(X.Id));
  Obj.AddPair('file', FileName);
  Obj.AddPair('line', TJSONNumber.Create(Line));
  Obj.AddPair('maxHits', TJSONNumber.Create(X.MaxHits));
  Obj.AddPair('hint', 'Run the program (debugControl "start" or "run"); each time the line is reached the ' +
    'expressions are recorded and the program continues. Read them with getLogpointHits.');
  Result := TToolResult.Json(Obj);
end;

function ToolGetLogpointHits(Args: TJSONObject): TToolResult;
var
  Id, Max, Shown, I, K: Integer;
  X: TLogpoint;
  H: TLogHit;
  SB: TStringBuilder;
  Clear: Boolean;
begin
  if (Logpoints = nil) or (Logpoints.Items.Count = 0) then
    Exit(TToolResult.Ok(['No logpoints. Set one with setLogpoint.']));
  Id := IntArg(Args, 'logpoint', 0);
  Max := IntArg(Args, 'maxHits', 200);
  Clear := JsonBool(Args, 'clear', False);
  SB := TStringBuilder.Create;
  try
    for X in Logpoints.Items do
    begin
      if (Id > 0) and (X.Id <> Id) then
        Continue;
      SB.AppendFormat('logpoint %d at %s:%d - %d hit(s)', [X.Id, ExtractFileName(X.FileName), X.Line, X.HitCount]);
      if X.Condition <> '' then
        SB.Append(' when ').Append(X.Condition);
      if X.Exhausted then
        SB.AppendFormat(' (stopped recording after %d hits)', [X.MaxHits]);
      SB.AppendLine;
      SB.Append('  #  ms     thread  ').Append(string.Join(' | ', X.Expressions)).AppendLine;
      Shown := 0;
      for I := System.Math.Max(0, X.Hits.Count - Max) to X.Hits.Count - 1 do
      begin
        H := X.Hits[I];
        SB.AppendFormat('  %d  %d  %d  ', [H.Index, MilliSecondsBetween(H.Time, X.Created), H.ThreadId]);
        SB.Append(string.Join(' | ', H.Values)).AppendLine;
        for K := 0 to High(H.Stack) do
          SB.Append('      ').Append(H.Stack[K]).AppendLine;
        Inc(Shown);
      end;
      if X.Hits.Count > Shown then
        SB.AppendFormat('  (%d earlier hit(s) not shown)', [X.Hits.Count - Shown]).AppendLine;
      if Clear then
        X.Hits.Clear;
    end;
    Result := TToolResult.Ok([SB.ToString]);
  finally
    SB.Free;
  end;
end;

function ToolRemoveLogpoint(Args: TJSONObject): TToolResult;
var
  Id, N: Integer;
  X: TLogpoint;
begin
  if Logpoints = nil then
    Exit(TToolResult.Ok(['No logpoints']));
  Id := IntArg(Args, 'logpoint', 0);
  if Id = 0 then
  begin
    N := Logpoints.Items.Count;
    while Logpoints.Items.Count > 0 do
      Logpoints.Remove(Logpoints.Items.Last);
    Exit(TToolResult.Ok([Format('Removed %d logpoint(s)', [N])]));
  end;
  X := Logpoints.Find(Id);
  if X = nil then
    Exit(TToolResult.Error(Format('No logpoint %d', [Id])));
  Logpoints.Remove(X);
  Result := TToolResult.Ok([Format('Removed logpoint %d', [Id])]);
end;

{ The IDE's Run (F9) action. IOTADebuggerServices.CreateProcess fails inside the debugger
  (access violation in dbkdebugide), so debugging is started the way the user does. }
function RunAction: TCustomAction;
var
  List: TCustomActionList;
  I: Integer;
  A: TCustomAction;
begin
  Result := nil;
  List := (BorlandIDEServices as INTAServices).ActionList;
  for I := 0 to List.ActionCount - 1 do
    if (List.Actions[I] is TCustomAction) and SameText(List.Actions[I].Name, 'RunRunCommand') then
      Exit(TCustomAction(List.Actions[I]));
  // Fallback: the action bound to plain F9.
  for I := 0 to List.ActionCount - 1 do
    if List.Actions[I] is TCustomAction then
    begin
      A := TCustomAction(List.Actions[I]);
      if A.ShortCut = ShortCut(VK_F9, []) then
        Exit(A);
    end;
end;

procedure StartDebugging(const Project: IOTAProject; const Params: string; WaitSec: Integer; const Done: TToolDone);
var
  P: IOTAProcess;
  Action: TCustomAction;
  Group: IOTAProjectGroup;
begin
  P := CurrentProcess;
  if (P <> nil) and not (P.ProcessState in [psTerminated, psNoProcess, psNothing]) then
  begin
    Done(TToolResult.Error('A program is already being debugged; terminate it first (debugControl "terminate")'));
    Exit;
  end;
  if PendingWait <> nil then
  begin
    Done(TToolResult.Error('Another debugControl call is still waiting'));
    Exit;
  end;
  Action := RunAction;
  if Action = nil then
  begin
    Done(TToolResult.Error('The IDE''s Run command was not found'));
    Exit;
  end;
  Group := (BorlandIDEServices as IOTAModuleServices).MainProjectGroup;
  if (Group <> nil) and (Group.ActiveProject <> Project) then
    Group.ActiveProject := Project;
  if (Params <> '') and (Project.ProjectOptions <> nil) then
    try
      Project.ProjectOptions.Values['RunParams'] := Params;
    except
      on E: Exception do
        Log('Could not set the run parameters: ' + E.Message);
    end;
  Log(Format('Starting %s with %s', [ExtractFileName(Project.FileName), Action.Name]));
  Action.Update;
  if not Action.Enabled then
  begin
    Done(TToolResult.Error('The IDE''s Run command is disabled right now (a build or another session running?)'));
    Exit;
  end;
  Action.Execute;
  // The IDE compiles first, so the process appears only after a while.
  PendingWait := TStopWait.Create('start', System.Math.Max(WaitSec, 300), Done);
  PendingWait.FUntilRunning := WaitSec <= 0;
end;

procedure ShutdownDebugTools;
begin
  CancelDebugWaits;
  FreeAndNil(Logpoints);
end;

{ Explain Debugger Stop }

function DebugStopPrompt: string;
var
  State, Th, Ex, Frame: TJSONObject;
  Stack: TJSONArray;
  I: Integer;
  Loc: string;
begin
  Result := '';
  if not IsStopped(CurrentProcess) then
    Exit;
  State := DebugStateJson(15, 8);
  try
    Result := Format('The debugged program %s is stopped (%s).', [ExtractFileName(JsonStr(State, 'exe')),
      JsonStr(State, 'state')]) + #10;
    if JsonStr(State, 'status') <> '' then
      Result := Result + 'Debugger status: ' + JsonStr(State, 'status') + #10;
    if State.GetValue('exception') is TJSONObject then
    begin
      Ex := TJSONObject(State.GetValue('exception'));
      Result := Result + Format('Exception: %s: %s', [JsonStr(Ex, 'class'), JsonStr(Ex, 'message')]) + #10;
    end;
    if State.GetValue('currentThread') is TJSONObject then
    begin
      Th := TJSONObject(State.GetValue('currentThread'));
      if JsonStr(Th, 'file') <> '' then
        Result := Result + Format('Current line: %s:%s', [JsonStr(Th, 'file'), JsonStr(Th, 'line')]) + #10 +
          '```pascal' + #10 + JsonStr(Th, 'source') + '```' + #10;
      if Th.GetValue('callStack') is TJSONArray then
      begin
        Stack := TJSONArray(Th.GetValue('callStack'));
        Result := Result + 'Call stack:' + #10;
        for I := 0 to Stack.Count - 1 do
        begin
          Frame := Stack.Items[I] as TJSONObject;
          Loc := '';
          if JsonStr(Frame, 'file') <> '' then
            Loc := Format(' (%s:%s)', [ExtractFileName(JsonStr(Frame, 'file')), JsonStr(Frame, 'line')]);
          Result := Result + '  ' + JsonStr(Frame, 'call') + Loc + #10;
        end;
      end;
    end;
    Result := Result + 'Explain why it stopped here and what the likely cause is. You can inspect values with ' +
      'mcp__delphi__evaluateExpression and step with mcp__delphi__debugControl.';
  finally
    State.Free;
  end;
end;

end.
