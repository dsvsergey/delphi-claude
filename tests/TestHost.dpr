program TestHost;

{ Runs the MCP/WebSocket server outside the IDE with a fake backend so the
  protocol layer can be exercised by tests/protocol-test.mjs. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.JSON,
  ClaudeCode.Utils, ClaudeCode.WebSocket, ClaudeCode.Diff, ClaudeCode.Mcp, FakeBackend;


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
