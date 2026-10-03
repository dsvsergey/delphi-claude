unit ClaudeCode.ClaudeMd;

{ Tools > Claude Code > Create CLAUDE.md for Project: facts about the active Delphi project
  (type, framework, platforms, build command, source encoding, forms, tests) written as a
  section of the project's CLAUDE.md between <!-- delphi:begin --> and <!-- delphi:end -->.
  An existing CLAUDE.md keeps everything outside that section. }

interface

uses
  System.SysUtils, ToolsAPI;

{ The generated section for Project (with the markers). }
function DelphiSection(const Project: IOTAProject): string;
{ OldText with the section replaced, or the section appended when there is none yet. }
function MergeSection(const OldText, Section: string): string;

const
  SECTION_BEGIN = '<!-- delphi:begin -->';
  SECTION_END = '<!-- delphi:end -->';

implementation

uses
  Winapi.Windows, System.Classes, System.IOUtils, System.Generics.Collections, System.StrUtils,
  ClaudeCode.Utils, ClaudeCode.TextSync;

const
  MAX_LISTED_FORMS = 40;
  MAX_SCANNED_UNITS = 300;

function ProjectKind(const P: IOTAProject): string;
var
  Ext: string;
begin
  Result := P.ApplicationType;
  if Result = '' then
  begin
    Ext := LowerCase(ExtractFileExt(P.FileName));
    if Ext = '.dproj' then
      Result := 'Application';
  end;
end;

function Join(const Items: TArray<string>): string;
begin
  Result := string.Join(', ', Items);
end;

function ConfigValue(const P: IOTAProject; const Name: string): string;
var
  Configs: IOTAProjectOptionsConfigurations;
  Cfg: IOTABuildConfiguration;
begin
  Result := '';
  if Supports(P.ProjectOptions, IOTAProjectOptionsConfigurations, Configs) and
     (Configs.ActiveConfiguration <> nil) then
  begin
    Cfg := Configs.ActiveConfiguration.PlatformConfiguration[P.CurrentPlatform];
    if Cfg = nil then
      Cfg := Configs.ActiveConfiguration;
    Result := Cfg.GetValue(Name, True);
  end;
end;

function Configurations(const P: IOTAProject): TArray<string>;
var
  Configs: IOTAProjectOptionsConfigurations;
  I: Integer;
begin
  Result := nil;
  if Supports(P.ProjectOptions, IOTAProjectOptionsConfigurations, Configs) then
    for I := 0 to Configs.ConfigurationCount - 1 do
      if not SameText(Configs.Configurations[I].Name, 'Base') then
        Result := Result + [Configs.Configurations[I].Name];
end;

{ What most units of the project are saved as. }
function EncodingSummary(const P: IOTAProject): string;
var
  Counts: array[TTextEncodingKind] of Integer;
  I, Scanned: Integer;
  F: string;
  K, Best: TTextEncodingKind;
begin
  FillChar(Counts, SizeOf(Counts), 0);
  Scanned := 0;
  for I := 0 to P.GetModuleCount - 1 do
  begin
    F := P.GetModule(I).FileName;
    if not IsDelphiSourceFile(F) or not FileExists(F) then
      Continue;
    Inc(Counts[DetectFileEncoding(F).Kind]);
    Inc(Scanned);
    if Scanned >= MAX_SCANNED_UNITS then
      Break;
  end;
  if Counts[tekAnsi] + Counts[tekUtf8] + Counts[tekUtf8Bom] + Counts[tekUtf16] = 0 then
    Exit('Units are plain ASCII. Non-ASCII text in new code: save the unit as UTF-8 with a BOM ' +
      '(the Delphi compiler reads BOM-less files as ANSI).');
  Best := tekAnsi;
  for K in [tekUtf8, tekUtf8Bom, tekUtf16] do
    if Counts[K] > Counts[Best] then
      Best := K;
  case Best of
    tekAnsi:
      Result := Format('Units with non-ASCII text are ANSI (code page %d), not UTF-8 (%d of %d scanned). ' +
        'Keep that encoding; the compiler reads them as ANSI.', [GetACP, Counts[tekAnsi], Scanned]);
    tekUtf8Bom:
      Result := Format('Units with non-ASCII text are UTF-8 with a BOM (%d of %d scanned). Keep the BOM: ' +
        'without it the compiler reads the file as ANSI.', [Counts[tekUtf8Bom], Scanned]);
    tekUtf8:
      Result := Format('Units with non-ASCII text are UTF-8 without a BOM (%d of %d scanned); check that the ' +
        'project compiles them as UTF-8 ({$CODEPAGE UTF8} or -codepage), otherwise add a BOM.',
        [Counts[tekUtf8], Scanned]);
  else
    Result := Format('Units are UTF-16 (%d of %d scanned).', [Counts[tekUtf16], Scanned]);
  end;
end;

function UsesDUnitX(const P: IOTAProject): Boolean;
var
  Text: string;
  Source: string;
begin
  Source := ChangeFileExt(P.FileName, '.dpr');
  Result := FileExists(Source) and ReadTextFileAutoEnc(Source, Text) and
    (ContainsText(Text, 'DUnitX') or ContainsText(Text, 'TestFramework'));
end;

function DelphiSection(const Project: IOTAProject): string;
var
  SB: TStringBuilder;
  Group: IOTAProjectGroup;
  I, Forms: Integer;
  Info: IOTAModuleInfo;
  Dir, BdsRoot, S: string;
  Tests: TList<string>;

  procedure Line(const Text: string = '');
  begin
    SB.Append(Text).Append(#10);
  end;

  function Rel(const Path: string): string;
  begin
    Result := Path;
    if (Dir <> '') and StartsText(Dir, Path) then
      Result := Copy(Path, Length(Dir) + 1, MaxInt);
    Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  end;

begin
  Dir := IncludeTrailingPathDelimiter(ExtractFilePath(Project.FileName));
  BdsRoot := ExcludeTrailingPathDelimiter((BorlandIDEServices as IOTAServices).GetRootDirectory);
  SB := TStringBuilder.Create;
  Tests := TList<string>.Create;
  try
    Line(SECTION_BEGIN);
    Line('## Delphi project');
    Line;
    Line('_Generated by Claude Code for Delphi (Tools > Claude Code > Create CLAUDE.md for Project); ' +
      'this section is replaced when it is generated again._');
    Line;
    Line(Format('- Project: `%s` (%s, %s), Delphi: %s', [Rel(Project.FileName), ProjectKind(Project),
      IfThen(Project.FrameworkType <> '', Project.FrameworkType, 'no framework'),
      (BorlandIDEServices as IOTAServices).GetProductIdentifier]));
    Line(Format('- Platforms: %s; configurations: %s (active: %s / %s)', [Join(Project.SupportedPlatforms),
      Join(Configurations(Project)), Project.CurrentConfiguration, Project.CurrentPlatform]));
    if Project.ProjectOptions <> nil then
      Line(Format('- Output: `%s`', [Project.ProjectOptions.TargetName]));
    S := ConfigValue(Project, 'DCC_Define');
    if S <> '' then
      Line(Format('- Defines (active configuration): `%s`', [S]));
    S := ConfigValue(Project, 'DCC_UnitSearchPath');
    if S <> '' then
      Line(Format('- Unit search path: `%s`', [S]));

    Group := (BorlandIDEServices as IOTAModuleServices).MainProjectGroup;
    if (Group <> nil) and (Group.ProjectCount > 1) then
    begin
      Line(Format('- Project group `%s`:', [Rel(Group.FileName)]));
      for I := 0 to Group.ProjectCount - 1 do
      begin
        Line(Format('  - `%s`', [Rel(Group.Projects[I].FileName)]));
        if UsesDUnitX(Group.Projects[I]) then
          Tests.Add(Group.Projects[I].FileName);
      end;
    end
    else if UsesDUnitX(Project) then
      Tests.Add(Project.FileName);

    Line;
    Line('### Build');
    Line;
    Line('- Inside the Delphi IDE session use the `mcp__delphi__buildProject` tool: it builds with the ' +
      'IDE''s configuration and returns the compiler errors (also shown in the Messages window).');
    Line('- From a command prompt:');
    Line;
    Line('  ```bat');
    Line(Format('  call "%s\bin\rsvars.bat" && msbuild "%s" /t:Build /p:Config=%s /p:Platform=%s',
      [BdsRoot, Rel(Project.FileName), Project.CurrentConfiguration, Project.CurrentPlatform]));
    Line('  ```');
    if Tests.Count > 0 then
    begin
      Line;
      Line('### Tests');
      Line;
      for S in Tests do
        Line(Format('- DUnitX/DUnit test project: `%s` (build it like the project above and run the exe).',
          [Rel(S)]));
      Line('- Inside the IDE session `mcp__delphi__runTests` builds and runs the tests and returns each failure ' +
        'with the file and line of the test.');
    end;

    Line;
    Line('### Navigating the code');
    Line;
    Line('- `mcp__delphi__getUnitOutline` shows a unit''s structure with line ranges (cheaper than reading it); ' +
      '`findSymbol` and `findReferences` find declarations and uses without matches in comments and strings; ' +
      '`renameSymbol` renames across units and forms (dry run first). `getUnitDependencies` shows how units ' +
      'depend on each other.');

    Line;
    Line('### Source files');
    Line;
    Line('- ' + EncodingSummary(Project));
    Forms := 0;
    for I := 0 to Project.GetModuleCount - 1 do
    begin
      Info := Project.GetModule(I);
      if (Info <> nil) and (Info.FormName <> '') then
      begin
        if Forms = 0 then
          Line('- Forms (unit: form, class):');
        Inc(Forms);
        if Forms <= MAX_LISTED_FORMS then
          Line(Format('  - `%s`: %s, %s', [Rel(Info.FileName), Info.FormName, Info.DesignClass]));
      end;
    end;
    if Forms > MAX_LISTED_FORMS then
      Line(Format('  - ... %d more', [Forms - MAX_LISTED_FORMS]));
    if Forms > 0 then
      Line('- While a form is open in the IDE, change it with `mcp__delphi__setComponentProperties`, ' +
        '`createComponent`, `pasteDfm` (whole blocks of DFM text) and `deleteComponent` (read it with ' +
        '`getFormComponents`, look at it with `captureForm`) instead of editing its .dfm/.fmx file: the ' +
        'designer keeps the file and the class declaration in sync.');

    Line;
    Line('### Debugging');
    Line;
    Line('- When the user is debugging in the IDE, `mcp__delphi__getDebugState` shows where the program ' +
      'stopped (call stack, source, exception); `evaluateExpression` reads values; `debugControl` steps ' +
      '(and "start" runs the program under the debugger).');
    Line('- `setLogpoint`/`getLogpointHits` record values on a line without stopping; `captureApp`, ' +
      '`getAppUI` and `appAction` look at and operate the running program, to reproduce a bug end to end.');
    Line('- `listConnections`, `getDatabaseSchema` and `runQuery` (read-only) show the database behind the ' +
      'project''s FireDAC connections.');
    Line(SECTION_END);
    Result := SB.ToString;
  finally
    Tests.Free;
    SB.Free;
  end;
end;

function MergeSection(const OldText, Section: string): string;
var
  B, E: Integer;
begin
  B := Pos(SECTION_BEGIN, OldText);
  E := Pos(SECTION_END, OldText);
  if (B > 0) and (E > B) then
    Exit(Copy(OldText, 1, B - 1) + TrimRight(Section) +
      Copy(OldText, E + Length(SECTION_END), MaxInt));
  if Trim(OldText) = '' then
    Exit(Section);
  Result := TrimRight(OldText) + #10#10 + Section;
end;

end.
