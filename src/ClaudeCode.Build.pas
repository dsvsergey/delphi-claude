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
    OutputFile: string; // what the build produced (.exe/.bpl), when MSBuild reported it
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
{ The file MSBuild reported as the project's output ("X.dproj -> C:\...\X.exe"), or ''. }
function ParseOutputFile(const Output: string): string;

implementation

uses
  System.RegularExpressions, System.Generics.Collections, ClaudeCode.Process, ClaudeCode.Utils;

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
  // Project1.dproj -> C:\p\Win32\Debug\Project1.exe
  ReOutputFile: TRegEx;

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
  ReOutputFile := TRegEx.Create('^\s*\S.*?\.(?:dproj|cbproj)\s+->\s+(?<file>.+?\.(?:exe|dll|bpl))\s*$',
    [roIgnoreCase, roMultiLine]);
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

function ParseOutputFile(const Output: string): string;
var
  M: TMatch;
begin
  Result := '';
  for M in ReOutputFile.Matches(Output) do
    Result := Trim(M.Groups['file'].Value);
end;

function RunBuild(const Req: TBuildRequest; const Cancelled: TFunc<Boolean>): TBuildResult;
var
  P: TProcessResult;
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
  P := RunProcess(Req.CommandLine, ExtractFilePath(Req.ProjectFile), Req.TimeoutSec, Cancelled);
  Result.Error := P.Error;
  Result.ExitCode := P.ExitCode;
  Result.TimedOut := P.TimedOut;
  Result.ElapsedMs := P.ElapsedMs;
  Result.Output := P.Output;
  if Result.Error <> '' then
    Exit;
  Result.Messages := ParseBuildOutput(Result.Output, ExtractFilePath(Req.ProjectFile));
  Result.OutputFile := ParseOutputFile(Result.Output);
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
  // Queued against this thread so Cancel/Destroy can drop it; the callback itself then runs from
  // the message loop (RunInMainLoop), where IDE services can wait for the IDE's own work.
  Queue(
    procedure
    var
      Done: TBuildDone;
    begin
      Done := FOnDone;
      FOnDone := nil;
      FRunner.FFinished := FRunner.FThread;
      FRunner.FThread := nil;
      RunInMainLoop(
        procedure
        begin
          Done(R);
        end);
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
