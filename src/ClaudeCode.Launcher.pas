unit ClaudeCode.Launcher;

{ Starts the Claude Code CLI in a new console window with the environment
  variables that make it connect to this IDE automatically. }

interface

uses
  System.Classes;

procedure LaunchClaude(const WorkDir, CommandLine: string; Port: Integer);
{ Current environment with Overrides (Name=Value) applied, as a CreateProcess block.
  An override with an empty value (Name=) removes the variable. }
function BuildEnvironmentBlock(const Overrides: TStrings): string;
{ Environment for a Claude process that should connect to this IDE. }
function ClaudeEnvironmentBlock(Port: Integer): string;
{ Turns a user command such as 'claude --continue' into something CreateProcess can run:
  a bare .exe found on PATH is used directly, anything else (e.g. npm's claude.cmd) goes through cmd.exe. }
function ResolveCommandLine(const Command: string): string;

implementation

uses
  Winapi.Windows, System.SysUtils;

function BuildEnvironmentBlock(const Overrides: TStrings): string;
var
  Block, P: PChar;
  Line, Name: string;
  Eq, I: Integer;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    Block := GetEnvironmentStrings;
    try
      P := Block;
      while P^ <> #0 do
      begin
        Line := P;
        Inc(P, Length(Line) + 1);
        // Entries like "=C:=C:\x" start with '=', so search from the 2nd char.
        Eq := Pos('=', Line, 2);
        if Eq = 0 then
          Continue;
        Name := Copy(Line, 1, Eq - 1);
        if Overrides.IndexOfName(Name) < 0 then
          L.Add(Line);
      end;
    finally
      FreeEnvironmentStrings(Block);
    end;
    for I := 0 to Overrides.Count - 1 do
      if Overrides.ValueFromIndex[I] <> '' then
        L.Add(Overrides[I]);
    Result := '';
    for I := 0 to L.Count - 1 do
      Result := Result + L[I] + #0;
    Result := Result + #0;
  finally
    L.Free;
  end;
end;

function ClaudeEnvironmentBlock(Port: Integer): string;
var
  Overrides: TStringList;
begin
  Overrides := TStringList.Create;
  try
    Overrides.Add('CLAUDE_CODE_SSE_PORT=' + IntToStr(Port));
    Overrides.Add('ENABLE_IDE_INTEGRATION=true');
    Overrides.Add('COLORTERM=truecolor');
    // Markers of a parent Claude session (when the IDE itself was started from one)
    // would make the new session behave as a child session.
    Overrides.Add('CLAUDECODE=');
    Overrides.Add('CLAUDE_CODE_ENTRYPOINT=');
    Overrides.Add('CLAUDE_CODE_CHILD_SESSION=');
    Overrides.Add('CLAUDE_CODE_SESSION_ID=');
    Overrides.Add('CLAUDE_CODE_SESSION_ATTENDED=');
    Overrides.Add('CLAUDE_CODE_EXECPATH=');
    Overrides.Add('CLAUDE_CODE_MESSAGING_SOCKET=');
    Overrides.Add('CLAUDE_CODE_MESSAGING_TOKEN=');
    Overrides.Add('CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=');
    Overrides.Add('CLAUDE_AGENT_SDK_VERSION=');
    Overrides.Add('CLAUDE_PID=');
    Overrides.Add('CLAUDE_EFFORT=');
    Result := BuildEnvironmentBlock(Overrides);
  finally
    Overrides.Free;
  end;
end;

function ResolveCommandLine(const Command: string): string;
var
  S, Prog, Rest: string;
  P: Integer;
  Found: array[0..MAX_PATH] of Char;
  FilePart: PChar;
begin
  S := Trim(Command);
  if S = '' then
    Exit('');
  if S[1] = '"' then
  begin
    P := Pos('"', S, 2);
    if P = 0 then
      P := Length(S) + 1;
    Prog := Copy(S, 2, P - 2);
    Rest := Copy(S, P + 1, MaxInt);
  end
  else
  begin
    P := Pos(' ', S);
    if P = 0 then
      P := Length(S) + 1;
    Prog := Copy(S, 1, P - 1);
    Rest := Copy(S, P, MaxInt);
  end;
  if (ExtractFileExt(Prog) = '') or SameText(ExtractFileExt(Prog), '.exe') then
    if SearchPath(nil, PChar(Prog), '.exe', Length(Found), Found, FilePart) > 0 then
      Exit('"' + string(Found) + '"' + Rest);
  Result := 'cmd.exe /d /s /c "' + S + '"';
end;

procedure LaunchClaude(const WorkDir, CommandLine: string; Port: Integer);
var
  Env, Cmd, Dir: string;
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  Env := ClaudeEnvironmentBlock(Port);

  Cmd := CommandLine;
  UniqueString(Cmd);
  Dir := WorkDir;
  if (Dir = '') or not DirectoryExists(Dir) then
    Dir := GetEnvironmentVariable('USERPROFILE');

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.lpTitle := 'Claude Code';
  FillChar(PI, SizeOf(PI), 0);
  if not CreateProcess(nil, PChar(Cmd), nil, nil, False,
    CREATE_NEW_CONSOLE or CREATE_UNICODE_ENVIRONMENT, PChar(Env), PChar(Dir), SI, PI) then
    RaiseLastOSError(GetLastError, '. Command: ' + CommandLine);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
end;

end.
