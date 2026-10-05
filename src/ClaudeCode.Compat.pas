unit ClaudeCode.Compat;

{ Declarations that newer Delphi versions have in the RTL and older ones (down to Delphi 10
  Seattle) lack. Everything here is conditional, so with a current Delphi this unit is empty. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.IOUtils;

{$IF not Declared(AssignProcessToJobObject)}
  {$DEFINE COMPAT_JOBOBJECT}
function AssignProcessToJobObject(hJob, hProcess: THandle): BOOL; stdcall;
function TerminateJobObject(hJob: THandle; uExitCode: UINT): BOOL; stdcall;
{$IFEND}
{$IF not Declared(GetTickCount64)}
  {$DEFINE COMPAT_GETTICKCOUNT64}
function GetTickCount64: UInt64; stdcall;
{$IFEND}

{$IF CompilerVersion < 32.0}
type
  { TThread.ForceQueue (Delphi 10.2): runs Proc in the main thread later, even when called
    from the main thread. }
  TThreadCompatHelper = class helper for TThread
  public
    class procedure ForceQueue(const AThread: TThread; const AThreadProc: TThreadProcedure); static;
    { TThread.GetTickCount64 (Delphi 10.2). }
    class function GetTickCount64: UInt64; static;
  end;
{$IFEND}

{$IF CompilerVersion < 33.0}
type
  { TJSONAncestor.Format (Delphi 10.3): the JSON text indented by Indentation spaces per level. }
  TJSONAncestorCompatHelper = class helper for TJSONAncestor
  public
    function Format(Indentation: Integer = 4): string;
  end;
{$IFEND}

{$IF CompilerVersion < 31.0}
type
  { TFile.GetSize (Delphi 10.1). }
  TFileCompatHelper = record helper for TFile
  public
    class function GetSize(const Path: string): Int64; static;
  end;
{$IFEND}

implementation

{$IFDEF COMPAT_JOBOBJECT}
function AssignProcessToJobObject; external kernel32 name 'AssignProcessToJobObject';
function TerminateJobObject; external kernel32 name 'TerminateJobObject';
{$ENDIF}
{$IFDEF COMPAT_GETTICKCOUNT64}
function GetTickCount64; external kernel32 name 'GetTickCount64';
{$ENDIF}

{$IF CompilerVersion < 32.0}
type
  TForceQueueThread = class(TThread)
  private
    FProc: TThreadProcedure;
  protected
    procedure Execute; override;
  end;

procedure TForceQueueThread.Execute;
begin
  // Queued from another thread, the call is never run synchronously.
  TThread.Queue(nil, FProc);
end;

class function TThreadCompatHelper.GetTickCount64: UInt64;
begin
  Result := ClaudeCode.Compat.GetTickCount64;
end;

class procedure TThreadCompatHelper.ForceQueue(const AThread: TThread;
  const AThreadProc: TThreadProcedure);
var
  T: TForceQueueThread;
begin
  if TThread.CurrentThread.ThreadID <> MainThreadID then
  begin
    TThread.Queue(AThread, AThreadProc);
    Exit;
  end;
  T := TForceQueueThread.Create(True);
  T.FProc := AThreadProc;
  T.FreeOnTerminate := True;
  T.Start;
end;
{$IFEND}

{$IF CompilerVersion < 31.0}
class function TFileCompatHelper.GetSize(const Path: string): Int64;
var
  Data: TWin32FileAttributeData;
begin
  if not GetFileAttributesEx(PChar(Path), GetFileExInfoStandard, @Data) then
    RaiseLastOSError;
  Result := Int64(Data.nFileSizeHigh) shl 32 or Data.nFileSizeLow;
end;
{$IFEND}

{$IF CompilerVersion < 33.0}
procedure FormatJson(Value: TJSONAncestor; Indentation, Level: Integer; B: TStringBuilder);
var
  I: Integer;
  Obj: TJSONObject;
  Arr: TJSONArray;
begin
  if Value is TJSONObject then
  begin
    Obj := TJSONObject(Value);
    if Obj.Count = 0 then
    begin
      B.Append('{}');
      Exit;
    end;
    B.Append('{').Append(sLineBreak);
    for I := 0 to Obj.Count - 1 do
    begin
      B.Append(StringOfChar(' ', (Level + 1) * Indentation));
      B.Append(Obj.Pairs[I].JsonString.ToJSON).Append(': ');
      FormatJson(Obj.Pairs[I].JsonValue, Indentation, Level + 1, B);
      if I < Obj.Count - 1 then
        B.Append(',');
      B.Append(sLineBreak);
    end;
    B.Append(StringOfChar(' ', Level * Indentation)).Append('}');
  end
  else if Value is TJSONArray then
  begin
    Arr := TJSONArray(Value);
    if Arr.Count = 0 then
    begin
      B.Append('[]');
      Exit;
    end;
    B.Append('[').Append(sLineBreak);
    for I := 0 to Arr.Count - 1 do
    begin
      B.Append(StringOfChar(' ', (Level + 1) * Indentation));
      FormatJson(Arr.Items[I], Indentation, Level + 1, B);
      if I < Arr.Count - 1 then
        B.Append(',');
      B.Append(sLineBreak);
    end;
    B.Append(StringOfChar(' ', Level * Indentation)).Append(']');
  end
  else
    B.Append(Value.ToJSON);
end;

function TJSONAncestorCompatHelper.Format(Indentation: Integer): string;
var
  B: TStringBuilder;
begin
  B := TStringBuilder.Create;
  try
    FormatJson(Self, Indentation, 0, B);
    Result := B.ToString;
  finally
    B.Free;
  end;
end;
{$IFEND}

end.
