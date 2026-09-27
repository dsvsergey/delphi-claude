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

{ A request for Claude describing why the debugged process is stopped, or '' when it is not. }
function DebugStopPrompt: string;
{ Drops a pending debugControl wait without answering it. }
procedure CancelDebugWaits;

implementation

uses
  Winapi.Windows, System.Math, System.DateUtils, Vcl.ExtCtrls,
  ClaudeCode.Utils, ClaudeCode.IdeBackend;

const
  STOPPED_STATES = [psStopped, psException, psFault, psResFault];
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

function CallStackJson(const Thread: IOTAThread; MaxFrames: Integer): TJSONArray;
var
  State: TOTACallStackState;
  Deadline: TDateTime;
  I, Line: Integer;
  FileName: string;
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
      Frame.AddPair('call', Thread.CallHeaders[I]);
      Thread.GetCallPos(I, FileName, Line);
      if FileName <> '' then
      begin
        Frame.AddPair('file', FileName);
        Frame.AddPair('line', TJSONNumber.Create(Line));
      end;
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
    FAction: string;
    procedure Tick(Sender: TObject);
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
var
  P: IOTAProcess;
begin
  P := CurrentProcess;
  if (P = nil) or (P.ProcessState in [psTerminated, psNoProcess, psNothing]) then
  begin
    Finish('The process ended');
    Exit;
  end;
  if P.ProcessState = psRunning then
    FSawRunning := True
  // Right after Run the state may still read "stopped" for a moment.
  else if IsStopped(P) and (FSawRunning or (MilliSecondsBetween(Now, FStartedAt) > 600)) then
  begin
    Finish('');
    Exit;
  end;
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
