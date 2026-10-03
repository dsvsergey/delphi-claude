unit ClaudeCode.Prompts;

{ MCP prompts of the "delphi" server: Claude Code shows them as slash commands
  (/mcp__delphi__make-tests-pass ...). Each one is a ready workflow over the Delphi tools.
  The IDE's menu commands use the same texts. No ToolsAPI here. }

interface

uses
  System.SysUtils, System.JSON;

type
  TPromptArg = record
    Name, Description: string;
    Required: Boolean;
  end;

  TPromptDef = record
    Name, Description: string;
    Args: TArray<TPromptArg>;
  end;

function PromptDefinitions: TArray<TPromptDef>;
function PromptListJson: TJSONArray;
{ The prompt text with the arguments filled in; False for an unknown prompt. }
function RenderPrompt(const Name: string; Args: TJSONObject; out Text: string): Boolean;
{ Convenience for the IDE: one string argument. }
function PromptText(const Name, ArgName, ArgValue: string): string;
{ prompts/get result. }
function PromptGetJson(const Name: string; Args: TJSONObject): TJSONObject;

implementation

uses
  ClaudeCode.Utils;

function Arg(const Name, Description: string; Required: Boolean = False): TPromptArg;
begin
  Result.Name := Name;
  Result.Description := Description;
  Result.Required := Required;
end;

function Def(const Name, Description: string; const Args: array of TPromptArg): TPromptDef;
var
  I: Integer;
begin
  Result.Name := Name;
  Result.Description := Description;
  SetLength(Result.Args, Length(Args));
  for I := 0 to High(Args) do
    Result.Args[I] := Args[I];
end;

function PromptDefinitions: TArray<TPromptDef>;
begin
  Result := [
    Def('make-tests-pass', 'Run the DUnitX tests and fix the code until they all pass',
      [Arg('project', 'Test project; default: the first DUnitX project of the group')]),
    Def('hunt-bug', 'Reproduce a bug in the running program and find its cause with logpoints',
      [Arg('description', 'What goes wrong and how to make it happen', True)]),
    Def('screenshot-to-form', 'Build a VCL form (or a part of one) in the designer from a picture or description',
      [Arg('image', 'Path of a screenshot, mockup or sketch'), Arg('form', 'The form to build on; default: the current one'),
       Arg('description', 'What the form should contain, if there is no picture')]),
    Def('crud-form', 'Create a data module and a form to browse and edit a database table',
      [Arg('table', 'The table', True), Arg('connection', 'Form.Component of the FireDAC connection; default: the first')]),
    Def('modernize', 'Modernize the project: win64, unicode, bde (to FireDAC), warnings or leaks',
      [Arg('scenario', 'win64, unicode, bde, warnings or leaks', True)]),
    Def('explain-architecture', 'Explain how the project is structured, from its unit dependencies', [])];
end;

function PromptListJson: TJSONArray;
var
  D: TPromptDef;
  A: TPromptArg;
  O, AO: TJSONObject;
  Args: TJSONArray;
begin
  Result := TJSONArray.Create;
  for D in PromptDefinitions do
  begin
    O := TJSONObject.Create;
    O.AddPair('name', D.Name);
    O.AddPair('description', D.Description);
    Args := TJSONArray.Create;
    for A in D.Args do
    begin
      AO := TJSONObject.Create;
      AO.AddPair('name', A.Name);
      AO.AddPair('description', A.Description);
      AO.AddPair('required', TJSONBool.Create(A.Required));
      Args.Add(AO);
    end;
    O.AddPair('arguments', Args);
    Result.Add(O);
  end;
end;

function ModernizeText(const Scenario: string): string;
const
  COMMON = ' Work in small batches (a unit or a few related units at a time). After each batch build ' +
    '(mcp__delphi__buildProject) and fix what the compiler reports; if the project group has a test project, run ' +
    'mcp__delphi__runTests too. Do not change behavior. At the end, summarize what changed and what is left.';
var
  S: string;
begin
  S := LowerCase(Trim(Scenario));
  if S = 'win64' then
    Result := 'Make this project ready for 64-bit Windows. Start with mcp__delphi__analyzeModernization ' +
      '(scenario "win64"). Change pointer, object and handle casts to 32-bit integers into NativeInt/NativeUInt ' +
      'or the proper handle types, GetWindowLong/SetWindowLong into the ...Ptr versions, and replace inline ' +
      'assembler with Pascal. Build for Win64 (buildProject with platform "Win64") as well as Win32.' + COMMON
  else if S = 'unicode' then
    Result := 'Fix the ANSI/Unicode string issues of this project. Start with mcp__delphi__analyzeModernization ' +
      '(scenario "unicode") and also look at the W1057/W1058 warnings (scenario "warnings"). Use string/Char ' +
      'unless bytes or a specific encoding are really meant (then TBytes or TEncoding), compute byte counts with ' +
      'SizeOf(Char)/ByteLength, use CharInSet.' + COMMON
  else if S = 'bde' then
    Result := 'Move the database access of this project from BDE/dbExpress/ADO to FireDAC. Start with ' +
      'mcp__delphi__analyzeModernization (scenario "bde") and mcp__delphi__listConnections. Replace components ' +
      'on forms and data modules through the designer (mcp__delphi__getFormComponents, pasteDfm, ' +
      'setComponentProperties, deleteComponent) so the .dfm and the class stay in step; keep component names ' +
      'where code refers to them; replace units in uses clauses. Check SQL against the real schema ' +
      '(getDatabaseSchema).' + COMMON
  else if S = 'warnings' then
    Result := 'Clear the compiler warnings of this project. Start with mcp__delphi__analyzeModernization ' +
      '(scenario "warnings"), which builds and groups them by code; fix the most frequent kinds first. Fix the ' +
      'cause, do not silence warnings with {$WARN} unless the code is right as it is.' + COMMON
  else if S = 'leaks' then
    Result := 'Find and fix the memory leaks of this program. Read the FastMM report with ' +
      'mcp__delphi__getMemoryLeaks (it explains how to enable it if there is none yet). For each leaked class find ' +
      'where the objects are created and who should own them (findSymbol, findReferences), and free them ' +
      '(try/finally, destructors, owned lists). Then run the program again and check the report.' + COMMON
  else
    Result := 'Modernize this project (' + Scenario + '). Start with mcp__delphi__analyzeModernization.' + COMMON;
end;

function RenderPrompt(const Name: string; Args: TJSONObject; out Text: string): Boolean;
var
  V: string;
begin
  Result := True;
  if Name = 'make-tests-pass' then
  begin
    Text := 'Run the tests with mcp__delphi__runTests';
    V := JsonStr(Args, 'project');
    if V <> '' then
      Text := Text + ' (project "' + V + '")';
    Text := Text + '. For each failing test read the test and the code under test (getUnitOutline, findSymbol), ' +
      'find the cause and fix the code - change a test only when the test itself is wrong. Run the tests again ' +
      'after each fix, until all of them pass. If needed, use logpoints (setLogpoint, debugControl "start", ' +
      'getLogpointHits) to see what the code really does. Finish with a short summary of the causes.';
  end
  else if Name = 'hunt-bug' then
    Text := 'Find the cause of this bug: ' + JsonStr(Args, 'description') + #10 +
      'Reproduce it in the running program: start it with mcp__delphi__debugControl "start", look at it with ' +
      'captureApp and getAppUI and do what the user would do with appAction. Before that, put logpoints ' +
      '(setLogpoint) on the code paths involved to record the values that matter, and read them with ' +
      'getLogpointHits; use findSymbol/findReferences to find the code. Use breakpoints and evaluateExpression ' +
      'only when you need to stop. Explain the cause with the evidence, propose the fix, and once it is applied ' +
      'reproduce again to confirm. Terminate the program at the end.'
  else if Name = 'screenshot-to-form' then
  begin
    Text := 'Build this user interface on the Delphi form';
    V := JsonStr(Args, 'form');
    if V <> '' then
      Text := Text + ' ' + V
    else
      Text := Text + ' that is open in the designer';
    Text := Text + '.';
    V := JsonStr(Args, 'image');
    if V <> '' then
      Text := Text + ' The picture is ' + V + ': read it first.';
    V := JsonStr(Args, 'description');
    if V <> '' then
      Text := Text + ' ' + V;
    Text := Text + #10 + 'Look at the form first (getFormComponents, captureForm). Write the controls as DFM text ' +
      'and create them with mcp__delphi__pasteDfm: standard VCL controls, sensible names (EditCustomer, not ' +
      'Edit1), panels with Align and Anchors so the layout survives resizing, tab order, captions, hints. Then ' +
      'take captureForm and compare it with the picture; adjust with setComponentProperties until it matches. ' +
      'Add event handlers only where the behavior is obvious. Do not save the form; tell the user what was built.';
  end
  else if Name = 'crud-form' then
  begin
    Text := 'Create a form to browse and edit the table ' + JsonStr(Args, 'table');
    V := JsonStr(Args, 'connection');
    if V <> '' then
      Text := Text + ' (connection ' + V + ')';
    Text := Text + '.' + #10 + 'Read the table with mcp__delphi__getDatabaseSchema and a few rows with runQuery. ' +
      'Use the project''s connection: put a TFDQuery (and a TDataSource) for the table on the data module that ' +
      'holds the connection, with persistent fields of the right types. Then build the form in the designer with ' +
      'pasteDfm: a TDBGrid with sensible columns and a TDBNavigator, or labelled data-aware edits for the ' +
      'columns, filters for the obvious search fields, and the not-null columns validated before posting. Look ' +
      'at it with captureForm, build the project, and explain how to open the form.';
  end
  else if Name = 'modernize' then
    Text := ModernizeText(JsonStr(Args, 'scenario'))
  else if Name = 'explain-architecture' then
    Text := 'Explain how this Delphi project is structured. Use mcp__delphi__getProjectInfo and ' +
      'getUnitDependencies (summary first, then the most important units) and getUnitOutline for the central ' +
      'units; read code only where needed. Describe the layers and responsibilities, the main flows, the forms ' +
      'and data modules, and the problems you see (cycles, units that do too much, UI code mixed with logic). ' +
      'Offer to open the interactive map (showProjectMap).'
  else
    Result := False;
end;

function PromptText(const Name, ArgName, ArgValue: string): string;
var
  A: TJSONObject;
begin
  A := TJSONObject.Create;
  try
    if ArgName <> '' then
      A.AddPair(ArgName, ArgValue);
    if not RenderPrompt(Name, A, Result) then
      Result := '';
  finally
    A.Free;
  end;
end;

function PromptGetJson(const Name: string; Args: TJSONObject): TJSONObject;
var
  Text: string;
  D: TPromptDef;
  Msg: TJSONObject;
begin
  if not RenderPrompt(Name, Args, Text) then
    Exit(nil);
  Result := TJSONObject.Create;
  for D in PromptDefinitions do
    if D.Name = Name then
      Result.AddPair('description', D.Description);
  Msg := TJSONObject.Create;
  Msg.AddPair('role', 'user');
  Msg.AddPair('content', TJSONObject.Create.AddPair('type', 'text').AddPair('text', Text));
  Result.AddPair('messages', TJSONArray.Create.Add(Msg));
end;

end.
