program TestHost;

{ Runs the MCP/WebSocket server outside the IDE with a fake backend so the
  protocol layer can be exercised by tests/protocol-test.mjs. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.JSON, System.IOUtils,
  ClaudeCode.Utils, ClaudeCode.WebSocket, ClaudeCode.Diff, ClaudeCode.Mcp, ClaudeCode.Build,
  FakeBackend;

procedure Expect(Cond: Boolean; const What: string);
begin
  if not Cond then
    raise Exception.Create('Self-test failed: ' + What);
end;

procedure BuildParserSelfTest;
var
  M: TBuildMessage;
begin
  Expect(ParseBuildLine('C:\p\Unit1.pas(12,5): error E2003: Undeclared identifier: ''x'' [C:\p\P.dproj]', '', M),
    'msbuild error');
  Expect((M.FileName = 'C:\p\Unit1.pas') and (M.Line = 12) and (M.Column = 5) and (M.Severity = bsError) and
    (M.Code = 'E2003') and (M.Text = 'Undeclared identifier: ''x'''), 'msbuild error fields: ' + M.Text);
  Expect(ParseBuildLine('  Unit1.pas(30): warning W1036: Variable ''I'' might not have been initialized [C:\p\P.dproj]',
    'C:\p\', M), 'relative warning');
  Expect((M.FileName = 'C:\p\Unit1.pas') and (M.Line = 30) and (M.Column = 0) and (M.Severity = bsWarning),
    'relative warning fields: ' + M.FileName);
  Expect(ParseBuildLine('C:\p\U.pas(11): hint warning H2164: Variable ''Unused'' is declared but never used [C:\p\P.dproj]',
    '', M) and (M.Severity = bsHint) and (M.Code = 'H2164'), 'hint');
  Expect(ParseBuildLine('C:\p\U.pas(5) Fatal: F2613 Unit ''X'' not found.', '', M) and (M.Severity = bsFatal) and
    (M.Code = 'F2613') and (M.Line = 5), 'plain dcc fatal');
  Expect(ParseBuildLine('MSBUILD : error MSB1009: Project file does not exist.', '', M) and
    (M.FileName = '') and (M.Code = 'MSB1009') and (M.Severity = bsError), 'msbuild error without location');
  Expect(not ParseBuildLine('  BuildSample.dproj -> C:\p\BuildSample.exe', '', M), 'plain output line');
  Writeln('BUILD PARSER OK');
end;

{ Builds tests\buildsample with MSBuild: once as is, once with a compile error. }
procedure BuildRunSelfTest;
var
  Req: TBuildRequest;
  R: TBuildResult;
  Src, Tmp, F, Code: string;
  M: TBuildMessage;
begin
  Src := TPath.Combine(ExtractFilePath(ParamStr(0)), 'buildsample');
  Tmp := TPath.Combine(TPath.GetTempPath, 'claude-build-test');
  if TDirectory.Exists(Tmp) then
    TDirectory.Delete(Tmp, True);
  TDirectory.CreateDirectory(Tmp);
  for F in ['BuildSample.dproj', 'BuildSample.dpr', 'SampleUnit.pas'] do
    TFile.Copy(TPath.Combine(Src, F), TPath.Combine(Tmp, F));

  Req.RsVars := GetEnvironmentVariable('BDS_RSVARS');
  if Req.RsVars = '' then
    Req.RsVars := 'd:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat';
  Req.ProjectFile := TPath.Combine(Tmp, 'BuildSample.dproj');
  Req.Target := 'Build';
  Req.Config := 'Debug';
  Req.Platform := 'Win32';
  Req.TimeoutSec := 300;

  R := RunBuild(Req, nil);
  Writeln('BUILD 1: exit ', R.ExitCode, ', ', Length(R.Messages), ' messages, ', R.ElapsedMs, ' ms');
  for M in R.Messages do
    Writeln('  ', SeverityNames[M.Severity], ' ', M.Code, ' ', ExtractFileName(M.FileName), ':', M.Line, ' ', M.Text);
  Expect(R.Error = '', 'build 1 ran: ' + R.Error);
  Expect(R.Success, 'build 1 succeeded'#13#10 + R.Output);
  Expect(R.Count(bsHint) >= 1, 'build 1 reports the unused variable hint');
  Expect(FileExists(TPath.Combine(Tmp, 'out\Win32\BuildSample.exe')), 'build 1 produced the exe');

  Code := TFile.ReadAllText(TPath.Combine(Tmp, 'SampleUnit.pas'));
  TFile.WriteAllText(TPath.Combine(Tmp, 'SampleUnit.pas'),
    StringReplace(Code, '{$IFDEF BREAK_BUILD}', '{$DEFINE BREAK_BUILD}{$IFDEF BREAK_BUILD}', []));
  Req.Target := 'Make';
  R := RunBuild(Req, nil);
  Writeln('BUILD 2: exit ', R.ExitCode, ', ', Length(R.Messages), ' messages, ', R.ElapsedMs, ' ms');
  for M in R.Messages do
    Writeln('  ', SeverityNames[M.Severity], ' ', M.Code, ' ', ExtractFileName(M.FileName), ':', M.Line, ' ', M.Text);
  Expect(not R.Success and (R.ExitCode <> 0), 'build 2 failed');
  Expect((Length(R.Messages) > 0) and (R.Messages[0].Severity >= bsError), 'build 2 lists the error first');
  Expect(SameText(ExtractFileName(R.Messages[0].FileName), 'SampleUnit.pas') and (R.Messages[0].Line = 14) and
    (R.Messages[0].Code = 'E2003'), 'build 2 error location');
  TDirectory.Delete(Tmp, True);
  Writeln('BUILD RUN OK');
end;


procedure DiffSelfTest;
var
  D: TDiffLines;
  S: string;
  L: TDiffLine;
begin
  D := ComputeLineDiff(SplitLines('a'#13#10'b'#13#10'c'#13#10'd'), SplitLines('a'#10'x'#10'c'#10'd'#10'e'#10));
  S := '';
  for L in D do
    case L.Kind of
      dkEqual: S := S + ' ' + L.Text;
      dkDelete: S := S + '-' + L.Text;
      dkInsert: S := S + '+' + L.Text;
    end;
  if S <> ' a-b+x c d+e' then
    raise Exception.Create('Diff self-test failed: ' + S);
  Writeln('DIFF OK');
end;

var
  Mcp: TMcpServer;
  Deadline: TDateTime;
  Token, LockText: string;
begin
  try
    DiffSelfTest;
    BuildParserSelfTest;
    if SameText(ParamStr(1), 'build') then
    begin
      BuildRunSelfTest;
      Exit;
    end;
    LogProc := procedure(const Msg: string) begin Writeln('LOG ', Msg); end;
    Mcp := TMcpServer.Create(TFakeBackend.Create(GetCurrentDir));
    Mcp.Start;
    ReadTextFileAutoEnc(Mcp.LockFile, LockText);
    Token := (TJSONObject.ParseJSONValue(LockText) as TJSONObject).GetValue<string>('authToken');
    Writeln('PORT ', Mcp.Port);
    Writeln('TOKEN ', Token);
    Writeln('LOCK ', Mcp.LockFile);
    Flush(Output);
    Deadline := Now + StrToIntDef(ParamStr(1), 20) / SecsPerDay;
    while Now < Deadline do
    begin
      CheckSynchronize(50);
      if FileExists(ChangeFileExt(ParamStr(0), '.stop')) then
        Break;
    end;
    // Push a notification to whoever is still connected, then shut down.
    Mcp.Notify('selection_changed', TJSONObject.Create.AddPair('text', 'bye'));
    Mcp.Stop;
    Writeln('LOCK_DELETED ', not FileExists(Mcp.LockFile));
    Mcp.Free;
  except
    on E: Exception do
    begin
      Writeln('ERROR ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
