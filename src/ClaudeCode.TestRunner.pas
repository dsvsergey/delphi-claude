unit ClaudeCode.TestRunner;

{ Runs a DUnitX (or DUnit console) test executable and reads its results: the NUnit XML file
  DUnitX writes with --xmlfile, or the console output when there is no XML.
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, System.JSON;

type
  TTestStatus = (tsPassed, tsFailed, tsError, tsIgnored);

  TTestCaseResult = record
    Namespace: string;  // the unit of the fixture (DUnitX "Namespace" suite)
    Fixture: string;    // the fixture class
    Name: string;       // the test method
    Status: TTestStatus;
    Message: string;
    StackTrace: string;
    TimeSec: Double;
    FileName: string;   // filled in by the caller when it finds the test method
    Line: Integer;
    function FullName: string;
    function ToJson: TJSONObject;
  end;

  TTestRunResult = record
    Error: string;      // the tests could not be run
    Exe: string;
    ExitCode: Cardinal;
    TimedOut: Boolean;
    ElapsedMs: Int64;
    Output: string;
    FromXml: Boolean;   // results come from the NUnit XML file (else the console output)
    Cases: TArray<TTestCaseResult>;
    function Count(Status: TTestStatus): Integer;
    function AllPassed: Boolean;
    function Summary: string;
  end;

const
  TestStatusNames: array[TTestStatus] of string = ('passed', 'failed', 'error', 'ignored');

{ Test cases of a DUnitX NUnit XML report. }
function ParseNUnitXml(const Xml: string): TArray<TTestCaseResult>;
{ Failing tests listed by the DUnitX console logger ("Failing Tests" / "Tests With Errors"). }
function ParseDUnitXConsole(const Output: string): TArray<TTestCaseResult>;
{ True when a project source looks like a test project (DUnitX or DUnit). }
function IsTestProjectSource(const DprText: string): Boolean;
{ Runs the test executable; Filter is passed as --run (fixture or test names, comma-separated). }
function RunTestExe(const Exe, Filter: string; TimeoutSec: Integer; const Cancelled: TFunc<Boolean>): TTestRunResult;

implementation

uses
  System.IOUtils, System.RegularExpressions, System.Generics.Collections, ClaudeCode.Process;

{ TTestCaseResult }

function TTestCaseResult.FullName: string;
begin
  Result := Name;
  if Fixture <> '' then
    Result := Fixture + '.' + Result;
  if Namespace <> '' then
    Result := Namespace + '.' + Result;
end;

function TTestCaseResult.ToJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('test', FullName);
  Result.AddPair('status', TestStatusNames[Status]);
  if Message <> '' then
    Result.AddPair('message', Message);
  if Trim(StackTrace) <> '' then
    Result.AddPair('stackTrace', StackTrace);
  if FileName <> '' then
  begin
    Result.AddPair('file', FileName);
    Result.AddPair('line', TJSONNumber.Create(Line));
  end;
end;

{ TTestRunResult }

function TTestRunResult.Count(Status: TTestStatus): Integer;
var
  C: TTestCaseResult;
begin
  Result := 0;
  for C in Cases do
    if C.Status = Status then
      Inc(Result);
end;

function TTestRunResult.AllPassed: Boolean;
begin
  Result := (Error = '') and not TimedOut and (Count(tsFailed) + Count(tsError) = 0) and
    (FromXml or (ExitCode = 0));
end;

function TTestRunResult.Summary: string;
begin
  if Error <> '' then
    Exit('Tests could not be run: ' + Error);
  Result := Format('%d test(s): %d passed, %d failed, %d error(s), %d ignored, %.1f s',
    [Length(Cases), Count(tsPassed), Count(tsFailed), Count(tsError), Count(tsIgnored), ElapsedMs / 1000]);
  if TimedOut then
    Result := Result + ' - TIMED OUT';
  if not FromXml then
    Result := Result + Format(' (from the console output, exit code %d)', [ExitCode]);
end;

{ NUnit XML }

function XmlDecode(const S: string): string;
begin
  Result := StringReplace(S, '&lt;', '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&apos;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&#13;', #13, [rfReplaceAll]);
  Result := StringReplace(Result, '&#10;', #10, [rfReplaceAll]);
  Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]);
end;

function InnerText(const S: string): string;
var
  A, B: Integer;
begin
  // The content of an element: CDATA as is, otherwise decoded text.
  A := Pos('<![CDATA[', S);
  if A > 0 then
  begin
    B := Pos(']]>', S, A);
    if B = 0 then
      B := Length(S) + 1;
    Result := Trim(Copy(S, A + 9, B - A - 9));
  end
  else
    Result := Trim(XmlDecode(S));
end;

function Attr(const Tag, Name: string): string;
var
  M: TMatch;
begin
  M := TRegEx.Match(Tag, '\b' + Name + '\s*=\s*"([^"]*)"', [roIgnoreCase]);
  if M.Success then
    Result := XmlDecode(M.Groups[1].Value)
  else
    Result := '';
end;

function ElementText(const Body, Element: string): string;
var
  A, B: Integer;
begin
  A := Pos('<' + Element, Body);
  if A = 0 then
    Exit('');
  A := Pos('>', Body, A);
  B := Pos('</' + Element + '>', Body, A);
  if (A = 0) or (B = 0) then
    Exit('');
  Result := InnerText(Copy(Body, A + 1, B - A - 1));
end;

function ParseNUnitXml(const Xml: string): TArray<TTestCaseResult>;
type
  TSuite = record
    Kind, Name: string;
  end;
var
  L: TList<TTestCaseResult>;
  Stack: TList<TSuite>;
  P, TagEnd, CloseAt: Integer;
  Tag, Body, ResultAttr: string;
  Suite: TSuite;
  C: TTestCaseResult;
  SelfClosing: Boolean;
  I: Integer;
begin
  L := TList<TTestCaseResult>.Create;
  Stack := TList<TSuite>.Create;
  try
    P := 1;
    while True do
    begin
      P := Pos('<', Xml, P);
      if P = 0 then
        Break;
      TagEnd := Pos('>', Xml, P);
      if TagEnd = 0 then
        Break;
      Tag := Copy(Xml, P, TagEnd - P + 1);
      SelfClosing := Tag.EndsWith('/>');
      if Tag.StartsWith('<test-suite') then
      begin
        Suite.Kind := Attr(Tag, 'type');
        Suite.Name := Attr(Tag, 'name');
        if not SelfClosing then
          Stack.Add(Suite);
      end
      else if Tag.StartsWith('</test-suite') then
      begin
        if Stack.Count > 0 then
          Stack.Delete(Stack.Count - 1);
      end
      else if Tag.StartsWith('<test-case') then
      begin
        C := Default(TTestCaseResult);
        C.Name := Attr(Tag, 'name');
        for I := Stack.Count - 1 downto 0 do
          if SameText(Stack[I].Kind, 'Fixture') or SameText(Stack[I].Kind, 'TestFixture') then
          begin
            C.Fixture := Stack[I].Name;
            Break;
          end;
        for I := Stack.Count - 1 downto 0 do
          if SameText(Stack[I].Kind, 'Namespace') then
          begin
            C.Namespace := Stack[I].Name;
            Break;
          end;
        // A full name in the case itself (NUnit style "Unit.Fixture.Test") wins.
        if C.Name.Contains('.') then
        begin
          I := C.Name.LastIndexOf('.');
          if C.Fixture = '' then
            C.Fixture := Copy(C.Name, 1, I);
          C.Name := Copy(C.Name, I + 2, MaxInt);
        end;
        C.TimeSec := StrToFloatDef(Attr(Tag, 'time'), 0, TFormatSettings.Invariant);
        ResultAttr := LowerCase(Attr(Tag, 'result'));
        if (ResultAttr = 'success') or (ResultAttr = 'passed') then
          C.Status := tsPassed
        else if (ResultAttr = 'failure') or (ResultAttr = 'failed') then
          C.Status := tsFailed
        else if ResultAttr = 'error' then
          C.Status := tsError
        else if SameText(Attr(Tag, 'executed'), 'false') or (ResultAttr = 'ignored') or
                (ResultAttr = 'skipped') or (ResultAttr = 'notrunnable') then
          C.Status := tsIgnored
        else if SameText(Attr(Tag, 'success'), 'true') then
          C.Status := tsPassed
        else
          C.Status := tsFailed;
        if not SelfClosing then
        begin
          CloseAt := Pos('</test-case>', Xml, TagEnd);
          if CloseAt > 0 then
          begin
            Body := Copy(Xml, TagEnd + 1, CloseAt - TagEnd - 1);
            C.Message := ElementText(Body, 'message');
            C.StackTrace := ElementText(Body, 'stack-trace');
            if (C.Message = '') and (C.Status = tsIgnored) then
              C.Message := ElementText(Body, 'reason');
            TagEnd := CloseAt;
          end;
        end;
        L.Add(C);
      end;
      P := TagEnd + 1;
    end;
    Result := L.ToArray;
  finally
    Stack.Free;
    L.Free;
  end;
end;

{ Console output }

function ParseDUnitXConsole(const Output: string): TArray<TTestCaseResult>;
var
  Lines: TStringList;
  I, Dot: Integer;
  S: string;
  Status: TTestStatus;
  InList: Boolean;
  C: TTestCaseResult;
  L: TList<TTestCaseResult>;
begin
  // Failing Tests
  //
  //   Unit.TFixture.Test
  //   Message: Expected [10] equals actual [6]
  L := TList<TTestCaseResult>.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    InList := False;
    Status := tsFailed;
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      if SameText(S, 'Failing Tests') then
      begin
        InList := True;
        Status := tsFailed;
        Continue;
      end;
      if SameText(S, 'Tests With Errors') then
      begin
        InList := True;
        Status := tsError;
        Continue;
      end;
      if not InList or (S = '') then
        Continue;
      if S.StartsWith('Message:', True) then
      begin
        if L.Count > 0 then
        begin
          C := L.Last;
          C.Message := Trim(Copy(S, 9, MaxInt));
          L[L.Count - 1] := C;
        end;
        Continue;
      end;
      if S.Contains(' ') or not S.Contains('.') then
      begin
        InList := False;
        Continue;
      end;
      C := Default(TTestCaseResult);
      C.Status := Status;
      Dot := S.LastIndexOf('.');
      C.Name := Copy(S, Dot + 2, MaxInt);
      S := Copy(S, 1, Dot);
      Dot := S.LastIndexOf('.');
      C.Fixture := Copy(S, Dot + 2, MaxInt);
      if Dot >= 0 then
        C.Namespace := Copy(S, 1, Dot);
      L.Add(C);
    end;
    Result := L.ToArray;
  finally
    Lines.Free;
    L.Free;
  end;
end;

function IsTestProjectSource(const DprText: string): Boolean;
var
  Low: string;
begin
  Low := LowerCase(DprText);
  Result := Low.Contains('dunitx.testframework') or Low.Contains('testframework') or
    Low.Contains('guitestrunner') or Low.Contains('texttestrunner') or Low.Contains('testinsight');
end;

function RunTestExe(const Exe, Filter: string; TimeoutSec: Integer; const Cancelled: TFunc<Boolean>): TTestRunResult;
var
  XmlFile, Cmd, Xml: string;
  P: TProcessResult;
begin
  Result := Default(TTestRunResult);
  Result.Exe := Exe;
  if not FileExists(Exe) then
  begin
    Result.Error := 'Test executable not found: ' + Exe;
    Exit;
  end;
  XmlFile := TPath.Combine(TPath.Combine(TPath.GetTempPath, 'claude-delphi'),
    Format('tests-%s-%d.xml', [ChangeFileExt(ExtractFileName(Exe), ''), TThread.GetTickCount64 mod 1000000]));
  ForceDirectories(ExtractFilePath(XmlFile));
  System.SysUtils.DeleteFile(XmlFile);
  // DUnitX options; DUnit console runners ignore what they do not know.
  Cmd := QuoteArg(Exe) + ' --exitbehavior:Continue --hidebanner --consolemode:Quiet ' +
    QuoteArg('--xmlfile:' + XmlFile);
  if Filter <> '' then
    Cmd := Cmd + ' ' + QuoteArg('--run:' + Filter);
  P := RunProcess(Cmd, ExtractFilePath(Exe), TimeoutSec, Cancelled);
  Result.Error := P.Error;
  Result.ExitCode := P.ExitCode;
  Result.TimedOut := P.TimedOut;
  Result.ElapsedMs := P.ElapsedMs;
  Result.Output := P.Output;
  if Result.Error <> '' then
    Exit;
  if FileExists(XmlFile) then
  begin
    try
      Xml := TFile.ReadAllText(XmlFile, TEncoding.UTF8);
      Result.Cases := ParseNUnitXml(Xml);
      Result.FromXml := True;
    except
      Result.FromXml := False;
    end;
    System.SysUtils.DeleteFile(XmlFile);
  end;
  if not Result.FromXml then
    Result.Cases := ParseDUnitXConsole(Result.Output);
end;

end.
