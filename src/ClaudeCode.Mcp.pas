unit ClaudeCode.Mcp;

{ MCP (JSON-RPC 2.0) server over WebSocket, speaking the Claude Code IDE protocol:
  - advertises itself through ~/.claude/ide/<port>.lock
  - answers initialize / tools/list / tools/call
  - pushes selection_changed / at_mentioned notifications.
  Tool calls are forwarded to IIdeBackend in the main thread. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ClaudeCode.WebSocket;

type
  TToolResult = record
    Texts: TArray<string>;
    IsError: Boolean;
    class function Ok(const ATexts: array of string): TToolResult; static;
    class function Json(Obj: TJSONValue): TToolResult; static; // frees Obj
    class function Error(const Msg: string): TToolResult; static;
  end;

  TToolDone = reference to procedure(const R: TToolResult);

  IIdeBackend = interface
    ['{B7C1B0A4-3E0F-4F47-8B0B-0F5F6C8C9A21}']
    { Called in the main thread. Done may be invoked immediately or later
      (e.g. openDiff waits for the user), always from the main thread.
      Args is owned by the caller and only valid during the call. }
    procedure ExecuteTool(const Name: string; Args: TJSONObject; const Done: TToolDone);
    function WorkspaceFolders: TArray<string>;
    function IdeName: string;
  end;

  { mcIde: the Claude Code IDE protocol over WebSocket (~/.claude/ide/<port>.lock).
    mcTools: the "delphi" MCP server over Streamable HTTP (POST /mcp) with the Delphi tools,
    which Claude Code does not show to the model when they come from the IDE connection. }
  TMcpChannel = (mcIde, mcTools);
  TReplyProc = reference to procedure(const Json: string);

  TMcpServer = class
  private
    FWs: TWsServer;
    FBackend: IIdeBackend;
    FToken: string;
    FLockFile: string;
    FMcpConfigFile: string;
    FHookSettingsFile: string;
    FOnHook: TProc<string>;
    FOnStatusLine: TFunc<string, string>;
    FSettingsHooks: Boolean;
    FSettingsStatusLine: Boolean;
    FLockFolders: string;
    FShuttingDown: Boolean;
    FOnClientsChanged: TNotifyEvent;
    procedure WsMessage(const Conn: IWsConnection; const Text: string);
    procedure WsConnect(const Conn: IWsConnection);
    procedure WsDisconnect(const Conn: IWsConnection);
    function HttpRequest(const Path, Body: string; out Status: Integer): string;
    procedure HandleRequest(const Reply: TReplyProc; Channel: TMcpChannel; const IdJson, Method: string;
      Params: TJSONObject);
    procedure SendResult(const Reply: TReplyProc; const IdJson: string; Result: TJSONValue);
    procedure SendError(const Reply: TReplyProc; const IdJson: string; Code: Integer; const Msg: string);
    procedure WriteMcpConfig;
    procedure WriteHookSettings;
    procedure WriteLockFile(const Folders: TArray<string>);
    procedure ClientsChanged;
  public
    constructor Create(const Backend: IIdeBackend);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function Running: Boolean;
    procedure RefreshLockFile;
    procedure Notify(const Method: string; Params: TJSONObject);
    { What the --settings file gives Claude Code: the hooks (timeline) and/or the status line. }
    procedure SetClaudeSettings(Hooks, StatusLine: Boolean);
    function ClientCount: Integer;
    function Port: Integer;
    property LockFile: string read FLockFile;
    { --mcp-config file that registers the "delphi" server for this IDE instance. }
    property McpConfigFile: string read FMcpConfigFile;
    { --settings file with Claude Code hooks that report turns and file edits to POST /hook. }
    property HookSettingsFile: string read FHookSettingsFile;
    { Called in the main thread with the JSON of each hook event. }
    property OnHook: TProc<string> read FOnHook write FOnHook;
    { Called in the main thread with the status line JSON of a session; returns the line Claude Code shows. }
    property OnStatusLine: TFunc<string, string> read FOnStatusLine write FOnStatusLine;
    property OnClientsChanged: TNotifyEvent read FOnClientsChanged write FOnClientsChanged;
  end;

function ClaudeIdeLockDir: string;
function ToolDefinitions: TJSONArray;
function DelphiToolDefinitions: TJSONArray;

implementation

uses
  System.IOUtils, System.SyncObjs, Winapi.Windows, ClaudeCode.Utils, ClaudeCode.Prompts;

const
  SERVER_NAME = 'claude-code-delphi';
  SERVER_VERSION = '0.3.0';
  TOOLS_SERVER_NAME = 'delphi'; // the key in mcpServers, so tools are mcp__delphi__*
  MCP_HTTP_PATH = '/mcp';
  MCP_CONFIG_NAME = 'delphi-mcp.json';
  HOOK_PATH = '/hook';
  STATUSLINE_PATH = '/statusline';
  HOOK_SETTINGS_SUFFIX = '.delphi-settings.json';
  DEFAULT_PROTOCOL = '2025-03-26';

function ClaudeIdeLockDir: string;
begin
  Result := TPath.Combine(ClaudeConfigDir, 'ide');
end;

{ TToolResult }

class function TToolResult.Ok(const ATexts: array of string): TToolResult;
var
  I: Integer;
begin
  SetLength(Result.Texts, Length(ATexts));
  for I := 0 to High(ATexts) do
    Result.Texts[I] := ATexts[I];
  Result.IsError := False;
end;

class function TToolResult.Json(Obj: TJSONValue): TToolResult;
begin
  try
    Result := Ok([Obj.ToJSON]);
  finally
    Obj.Free;
  end;
end;

class function TToolResult.Error(const Msg: string): TToolResult;
begin
  Result := Ok([Msg]);
  Result.IsError := True;
end;

{ Tool schemas }

function Prop(const AType, Desc: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', AType);
  Result.AddPair('description', Desc);
end;

function Schema(const Props: array of TJSONPair; const Required: array of string): TJSONObject;
var
  P: TJSONObject;
  R: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  P := TJSONObject.Create;
  for I := 0 to High(Props) do
    P.AddPair(Props[I]);
  Result.AddPair('properties', P);
  if Length(Required) > 0 then
  begin
    R := TJSONArray.Create;
    for I := 0 to High(Required) do
      R.Add(Required[I]);
    Result.AddPair('required', R);
  end;
  Result.AddPair('additionalProperties', TJSONBool.Create(False));
end;

function ArrayProp(const Desc: string): TJSONObject;
begin
  Result := Prop('array', Desc);
  Result.AddPair('items', TJSONObject.Create.AddPair('type', 'string'));
end;

function Tool(const Name, Desc: string; InputSchema: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('description', Desc);
  Result.AddPair('inputSchema', InputSchema);
end;

procedure AddDelphiTools(Result: TJSONArray); forward;

function ToolDefinitions: TJSONArray;
begin
  Result := TJSONArray.Create;
  Result.Add(Tool('openFile', 'Open a file in the Delphi editor and optionally select a range of text',
    Schema([
      TJSONPair.Create('filePath', Prop('string', 'Path to the file to open')),
      TJSONPair.Create('preview', Prop('boolean', 'Whether to open the file in preview mode')),
      TJSONPair.Create('startText', Prop('string', 'Text pattern to find the start of the selection range')),
      TJSONPair.Create('endText', Prop('string', 'Text pattern to find the end of the selection range')),
      TJSONPair.Create('selectToEndOfLine', Prop('boolean', 'Extend the selection to the end of the line')),
      TJSONPair.Create('makeFrontmost', Prop('boolean', 'Make the file the active editor tab'))],
      ['filePath'])));
  Result.Add(Tool('openDiff', 'Open a diff view comparing a file with proposed new contents and wait for the user to accept or reject it',
    Schema([
      TJSONPair.Create('old_file_path', Prop('string', 'Path to the file being changed')),
      TJSONPair.Create('new_file_path', Prop('string', 'Path the new contents will be written to')),
      TJSONPair.Create('new_file_contents', Prop('string', 'Proposed contents of the file')),
      TJSONPair.Create('tab_name', Prop('string', 'Name of the diff tab'))],
      ['old_file_path', 'new_file_path', 'new_file_contents', 'tab_name'])));
  Result.Add(Tool('getCurrentSelection', 'Get the current text selection in the active editor',
    Schema([], [])));
  Result.Add(Tool('getLatestSelection', 'Get the most recent text selection (even if the editor is no longer focused)',
    Schema([], [])));
  Result.Add(Tool('getOpenEditors', 'Get the list of files currently open in the editor',
    Schema([], [])));
  Result.Add(Tool('getWorkspaceFolders', 'Get the folders of the open project group',
    Schema([], [])));
  Result.Add(Tool('getDiagnostics', 'Get Error Insight diagnostics (errors, warnings, hints) from the IDE',
    Schema([
      TJSONPair.Create('uri', Prop('string', 'Optional file URI; if omitted, diagnostics for all open files are returned'))],
      [])));
  Result.Add(Tool('checkDocumentDirty', 'Check whether a document has unsaved changes',
    Schema([TJSONPair.Create('filePath', Prop('string', 'Path to the file'))], ['filePath'])));
  Result.Add(Tool('saveDocument', 'Save a document with unsaved changes',
    Schema([TJSONPair.Create('filePath', Prop('string', 'Path to the file'))], ['filePath'])));
  Result.Add(Tool('close_tab', 'Close a diff window or an editor tab by name',
    Schema([TJSONPair.Create('tab_name', Prop('string', 'Tab name'))], ['tab_name'])));
  Result.Add(Tool('closeAllDiffTabs', 'Close all diff windows opened by Claude',
    Schema([], [])));
  AddDelphiTools(Result);
end;

{ Delphi-specific tools. Claude Code hides every IDE-server tool from the model except
  getDiagnostics/executeCode, so these are also served as the separate "delphi" MCP server
  (Streamable HTTP on the same port) that Claude is started with. }
procedure AddDelphiTools(Result: TJSONArray);
begin
  Result.Add(Tool('buildProject',
    'Compile a Delphi project with MSBuild using its .dproj settings (the active IDE configuration and ' +
    'platform by default) and return the compiler errors, warnings and hints. Files are built from disk: ' +
    'unsaved editor changes are listed in unsavedFiles unless saveModified is true. ' +
    'The messages also appear in the IDE Messages window.',
    Schema([
      TJSONPair.Create('project', Prop('string', 'Project file path or name; defaults to the active project')),
      TJSONPair.Create('target', Prop('string', '"make" (default, incremental), "build" (full rebuild) or "clean"')),
      TJSONPair.Create('config', Prop('string', 'Build configuration, e.g. Debug or Release; defaults to the active one')),
      TJSONPair.Create('platform', Prop('string', 'Target platform, e.g. Win32 or Win64; defaults to the active one')),
      TJSONPair.Create('saveModified', Prop('boolean', 'Save modified editor buffers before building (default false)')),
      TJSONPair.Create('includeHints', Prop('boolean', 'Include compiler hints in the result (default true)')),
      TJSONPair.Create('timeoutSec', Prop('number', 'Build timeout in seconds (default 600)'))],
      [])));
  Result.Add(Tool('runTests',
    'Build a DUnitX test project and run its tests: the results with each failing test''s message and the file ' +
    'and line of the test method. The failures also appear in the IDE Messages window (Claude Tests). Use it ' +
    'after changing code, and in a loop (fix, runTests) until all tests pass.',
    Schema([
      TJSONPair.Create('project', Prop('string', 'Test project path or name; default: the active project if it is a ' +
        'test project, else the first DUnitX project of the group')),
      TJSONPair.Create('filter', Prop('string', 'Only these fixtures/tests (DUnitX --run), e.g. ' +
        'OrderTests.TOrderTests or OrderTests.TOrderTests.TotalAddsAllLines; comma-separated')),
      TJSONPair.Create('saveModified', Prop('boolean', 'Save modified editor buffers before building (default true)')),
      TJSONPair.Create('timeoutSec', Prop('number', 'Timeout of the test run in seconds (default 300)'))],
      [])));
  Result.Add(Tool('getProjectInfo',
    'Get the Delphi project group and project settings: projects, active configuration and platform, ' +
    'framework (VCL/FMX), output file, defines, search paths, namespaces and the units/forms of the project',
    Schema([
      TJSONPair.Create('project', Prop('string', 'Project file path or name; defaults to the active project'))],
      [])));

  // Form designer. "form" is a unit/.dfm path, a unit name or a form name; empty = the current editor.
  Result.Add(Tool('getFormComponents',
    'Read a Delphi form (VCL or FMX) as it is in the IDE designer right now, including unsaved designer ' +
    'changes: the list of components (name, class, parent) and the form''s DFM text. Prefer this over ' +
    'reading the .dfm file while the form is open in the IDE.',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the form of the current editor')),
      TJSONPair.Create('component', Prop('string', 'Only this component: return its DFM block (with its children)')),
      TJSONPair.Create('includeDfm', Prop('boolean', 'Include the full DFM text (default true)'))],
      [])));
  Result.Add(Tool('getSelectedComponents',
    'Get the components the user has selected in the Delphi form designer, with their DFM blocks',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form'))],
      [])));
  Result.Add(Tool('setComponentProperties',
    'Change published properties of a component (or of the form itself) through the Delphi form designer, ' +
    'instead of editing the .dfm file of a form that is open in the IDE. The designer keeps the .dfm, ' +
    'the class declaration and the Object Inspector in sync; the user saves the form. ' +
    'Values: strings, numbers, booleans; enums and sets by name ("alClient", ["akLeft","akTop"]); ' +
    'identifiers such as clRed or crHandPoint; nested properties as "Font.Size" or {"Font": {"Style": "[fsBold]"}}; ' +
    'component references by component name; TStrings (Items, Lines) as text or an array of lines; ' +
    'events by handler method name (created in the unit if missing), "" to clear. ' +
    'Returns old and new values of what changed.',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('component', Prop('string', 'Component name; empty or the form name for the form itself')),
      TJSONPair.Create('properties', Prop('object', 'Property names (or dotted paths) and values'))],
      ['properties'])));
  Result.Add(Tool('createComponent',
    'Drop a new component on a Delphi form through the designer (the class must be registered in the IDE). ' +
    'Optionally name it, place it inside a parent control and set properties like setComponentProperties.',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('className', Prop('string', 'Component class, e.g. TButton, TFDQuery')),
      TJSONPair.Create('name', Prop('string', 'Component name; default: the designer''s next free name')),
      TJSONPair.Create('parent', Prop('string', 'Parent control name (e.g. a TPanel); default: the form')),
      TJSONPair.Create('left', Prop('number', 'Left, relative to the parent')),
      TJSONPair.Create('top', Prop('number', 'Top, relative to the parent')),
      TJSONPair.Create('width', Prop('number', 'Width')),
      TJSONPair.Create('height', Prop('number', 'Height')),
      TJSONPair.Create('properties', Prop('object', 'Properties to set after creation'))],
      ['className'])));
  Result.Add(Tool('pasteDfm',
    'Create components on a Delphi form from DFM text, exactly like pasting DFM text into the form designer: ' +
    'one or more "object Name: TClass ... end" blocks with properties, nested child objects, collections and ' +
    'event handlers (created in the unit). The fastest way to build a whole form or panel, e.g. from a ' +
    'screenshot or a sketch. Left/Top are relative to the parent. Existing names get renamed by the ' +
    'designer; the result lists the real names. Check the result with captureForm.',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('parent', Prop('string', 'Container to paste into (e.g. a TPanel); default: the form')),
      TJSONPair.Create('dfm', Prop('string', 'DFM text: object blocks as in a text .dfm file'))],
      ['dfm'])));
  Result.Add(Tool('deleteComponent',
    'Delete a component (and the controls it contains) from a Delphi form through the designer',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('component', Prop('string', 'Component name'))],
      ['component'])));
  // Debugger.
  Result.Add(Tool('getDebugState',
    'Get the state of the program being debugged in the Delphi IDE: process state, the current thread with ' +
    'its call stack and the source around the current line, the exception (when stopped on one) and all ' +
    'threads. There is no list of local variables: read the code and use evaluateExpression.',
    Schema([
      TJSONPair.Create('maxFrames', Prop('number', 'Call stack frames to return (default 30)')),
      TJSONPair.Create('contextLines', Prop('number', 'Source lines shown before and after the current line (default 6)'))],
      [])));
  Result.Add(Tool('evaluateExpression',
    'Evaluate a Delphi expression in the stopped debugged process (current thread and frame), like the ' +
    'Evaluate/Modify dialog: variables, fields, properties, typecasts, Length(), array elements...',
    Schema([
      TJSONPair.Create('expression', Prop('string', 'Delphi expression, e.g. Customer.Name or Length(Items)')),
      TJSONPair.Create('allowSideEffects', Prop('boolean', 'Allow calling functions/property getters with side effects (default false)'))],
      ['expression'])));
  Result.Add(Tool('setBreakpoint',
    'Add a source breakpoint in the Delphi IDE (or update the one on that line)',
    Schema([
      TJSONPair.Create('file', Prop('string', 'Unit path')),
      TJSONPair.Create('line', Prop('number', '1-based line number')),
      TJSONPair.Create('condition', Prop('string', 'Break only when this Delphi expression is True')),
      TJSONPair.Create('passCount', Prop('number', 'Break on the Nth pass')),
      TJSONPair.Create('enabled', Prop('boolean', 'Default true'))],
      ['file', 'line'])));
  Result.Add(Tool('listBreakpoints', 'List the source breakpoints set in the Delphi IDE',
    Schema([], [])));
  Result.Add(Tool('removeBreakpoint', 'Remove a source breakpoint from the Delphi IDE',
    Schema([
      TJSONPair.Create('file', Prop('string', 'Unit path')),
      TJSONPair.Create('line', Prop('number', '1-based line number'))],
      ['file', 'line'])));
  Result.Add(Tool('debugControl',
    'Control the program being debugged: "start" builds the project and runs it under the debugger (waits for ' +
    'the first stop only if waitSec is given); "stepOver", "stepInto", "runUntilReturn", "runToCursor" and ' +
    '"pause" wait until it stops again and return the new debug state; "run" continues (waits only if waitSec ' +
    'is given, e.g. until the next breakpoint); "terminate" ends the program. Logpoint hits do not count as stops.',
    Schema([
      TJSONPair.Create('action', Prop('string', 'start, run, stepOver, stepInto, runUntilReturn, runToCursor, pause or terminate')),
      TJSONPair.Create('waitSec', Prop('number', 'How long to wait for the next stop (default 10; 0 for run and start)')),
      TJSONPair.Create('project', Prop('string', 'start: project to build and run; default: the active project')),
      TJSONPair.Create('params', Prop('string', 'start: command-line parameters of the program'))],
      ['action'])));
  // Modernization.
  Result.Add(Tool('analyzeModernization',
    'Find what to change to modernize a Delphi project, with file:line and advice per kind: "win64" (pointer ' +
    'and handle casts to 32-bit integers, GetWindowLong, inline asm, Extended), "unicode" (AnsiString/PAnsiChar/' +
    'ShortString, byte counts from string lengths, Char in sets), "bde" (BDE, dbExpress and ADO units and ' +
    'components with their FireDAC replacements, forms included) or "warnings" (a full build, compiler ' +
    'warnings grouped by code - e.g. implicit string casts, deprecated symbols). Comments and strings are ' +
    'ignored. Start a modernization with it, then fix in batches with builds in between.',
    Schema([
      TJSONPair.Create('scenario', Prop('string', 'win64, unicode, bde or warnings')),
      TJSONPair.Create('project', Prop('string', 'Only this project; default: the project group (warnings: the active project)')),
      TJSONPair.Create('maxPerRule', Prop('number', 'Locations listed per kind (default 15)'))],
      ['scenario'])));
  Result.Add(Tool('getMemoryLeaks',
    'Memory leaks of the program from its FastMM4/FastMM5 event log (<program>_MemoryManager_EventLog.txt): ' +
    'leaked classes with counts, sizes and the application frames of the allocation stack. Without a log it ' +
    'explains how to enable one.',
    Schema([
      TJSONPair.Create('file', Prop('string', 'The log file; default: the one next to the project''s program')),
      TJSONPair.Create('project', Prop('string', 'Project whose program is checked; default: the active one'))],
      [])));
  // Databases (FireDAC connections of the project).
  Result.Add(Tool('listConnections',
    'The FireDAC connections (TFDConnection) on the forms and data modules of the project: names to use with ' +
    'getDatabaseSchema and runQuery, drivers and parameters (passwords masked).',
    Schema([], [])));
  Result.Add(Tool('getDatabaseSchema',
    'The schema of a project database: tables with their columns (type, primary key, not null, autoinc) and ' +
    'foreign keys, read through a private FireDAC connection with the parameters of the project''s ' +
    'connection (the component on the form is not touched). Use it before writing SQL, queries, data modules ' +
    'or data-aware forms so names and types are right.',
    Schema([
      TJSONPair.Create('connection', Prop('string', 'Form.Component or Component from listConnections; default: the first')),
      TJSONPair.Create('table', Prop('string', 'Only this table')),
      TJSONPair.Create('params', ArrayProp('Instead of a project connection: FireDAC parameters, e.g. ' +
        '["DriverID=SQLite", "Database=C:\data\app.db"]')),
      TJSONPair.Create('connectionDefName', Prop('string', 'Instead: a FireDAC connection definition name'))],
      [])));
  Result.Add(Tool('runQuery',
    'Run one reading SQL statement (SELECT/WITH/SHOW/EXPLAIN) against a project database and return the rows as ' +
    'a table. Statements that change data or schema are refused, and the query runs in a transaction that is ' +
    'rolled back. Use it to look at real data while debugging or before writing code that uses it.',
    Schema([
      TJSONPair.Create('sql', Prop('string', 'The SELECT statement')),
      TJSONPair.Create('connection', Prop('string', 'Form.Component or Component from listConnections; default: the first')),
      TJSONPair.Create('maxRows', Prop('number', 'Rows to return (default 100)')),
      TJSONPair.Create('params', ArrayProp('Instead of a project connection: FireDAC parameters')),
      TJSONPair.Create('connectionDefName', Prop('string', 'Instead: a FireDAC connection definition name'))],
      ['sql'])));
  // The running program (UI Automation).
  Result.Add(Tool('captureApp',
    'Take pictures of the windows of the running program (by default the one being debugged), as they look ' +
    'now, even when other windows cover them. Returns PNG paths: open them with the Read tool. Use it to see ' +
    'the result of a change or to reproduce what the user describes.',
    Schema([
      TJSONPair.Create('processId', Prop('number', 'Another running program; default: the debugged one')),
      TJSONPair.Create('window', Prop('string', 'Only windows whose title contains this text'))],
      [])));
  Result.Add(Tool('getAppUI',
    'The UI of the running program''s main window (or the window given) as a tree from UI Automation: each ' +
    'control with an id for appAction, its type, caption/name, value, checked/disabled state and position. ' +
    'Works for VCL and (partly) FMX programs.',
    Schema([
      TJSONPair.Create('processId', Prop('number', 'Another running program; default: the debugged one')),
      TJSONPair.Create('window', Prop('string', 'The window whose title contains this text; default: the largest')),
      TJSONPair.Create('depth', Prop('number', 'Tree depth (default 12)')),
      TJSONPair.Create('maxNodes', Prop('number', 'Elements to list (default 400)'))],
      [])));
  Result.Add(Tool('appAction',
    'Act on the running program like a user: "click" (buttons are invoked, check boxes toggled, list items ' +
    'selected), "doubleClick", "rightClick", "setText" (replaces an edit''s text), "sendKeys" (types into the ' +
    'focused or given control; {ENTER} {TAB} {ESC} {BACKSPACE} {DELETE} {UP} {DOWN} {LEFT} {RIGHT} {HOME} ' +
    '{END} {PGUP} {PGDN} {F1}..{F12}) or "focus". Target an element id from getAppUI, or x/y relative to the ' +
    'window picture from captureApp. The user''s foreground window keeps the focus. Combine with logpoints and ' +
    'getDebugState to reproduce and diagnose bugs end to end.',
    Schema([
      TJSONPair.Create('action', Prop('string', 'click, doubleClick, rightClick, setText, sendKeys or focus')),
      TJSONPair.Create('element', Prop('string', 'Element id from getAppUI, e.g. 0.2')),
      TJSONPair.Create('x', Prop('number', 'Instead of element: x relative to the window')),
      TJSONPair.Create('y', Prop('number', 'Instead of element: y relative to the window')),
      TJSONPair.Create('text', Prop('string', 'setText/sendKeys: the text')),
      TJSONPair.Create('expectName', Prop('string', 'The element''s name from getAppUI: the action fails if the UI changed')),
      TJSONPair.Create('processId', Prop('number', 'Another running program; default: the debugged one')),
      TJSONPair.Create('window', Prop('string', 'The window whose title contains this text; default: the largest'))],
      ['action'])));
  Result.Add(Tool('setLogpoint',
    'Set a logpoint: a breakpoint that does not stop the program but records the values of Delphi expressions ' +
    'each time the line is reached (optionally only when a condition holds), then lets it run on. Use it to ' +
    'watch how values change over many iterations or events without stepping: set logpoints, run the program ' +
    '(debugControl "start"), make it do the work, then read getLogpointHits.',
    Schema([
      TJSONPair.Create('file', Prop('string', 'Unit path')),
      TJSONPair.Create('line', Prop('number', '1-based line number (a line with code)')),
      TJSONPair.Create('expressions', ArrayProp('Delphi expressions to record, e.g. ["I", "Total", "Items.Count"]')),
      TJSONPair.Create('condition', Prop('string', 'Record only when this Delphi expression is True')),
      TJSONPair.Create('maxHits', Prop('number', 'Stop recording after this many hits (default 100)')),
      TJSONPair.Create('stackFrames', Prop('number', 'Also record this many call stack frames per hit (default 0)'))],
      ['file', 'line', 'expressions'])));
  Result.Add(Tool('getLogpointHits',
    'The values recorded by logpoints: one row per hit with the hit number, milliseconds since the logpoint ' +
    'was set, thread id and the expression values (and call stacks if requested).',
    Schema([
      TJSONPair.Create('logpoint', Prop('number', 'Only this logpoint id; default: all')),
      TJSONPair.Create('maxHits', Prop('number', 'Last N hits per logpoint (default 200)')),
      TJSONPair.Create('clear', Prop('boolean', 'Forget the shown hits afterwards (default false)'))],
      [])));
  Result.Add(Tool('removeLogpoint', 'Remove a logpoint, or all logpoints when no id is given',
    Schema([TJSONPair.Create('logpoint', Prop('number', 'Logpoint id; default: all'))], [])));

  Result.Add(Tool('getFileHistory',
    'The Delphi IDE''s local history of a file (__history\<name>.~N~ backups made on each save in the IDE): ' +
    'without "version" the list of versions, newest first; with "version" the text of that version. ' +
    'Useful to see or restore what the file looked like before recent changes.',
    Schema([
      TJSONPair.Create('file', Prop('string', 'Path of the file')),
      TJSONPair.Create('version', Prop('number', 'Version number from the list'))],
      ['file'])));

  // Code navigation (ClaudeCode.PascalIndex): parsed from the sources, not the compiler.
  Result.Add(Tool('getUnitOutline',
    'Outline of a Delphi unit read from its code: uses clauses, types with their members, routines and ' +
    'method bodies with line ranges, constants and variables. Much smaller than the file: use it to find where ' +
    'things are, then read only the lines you need. Open editors are read with their unsaved changes.',
    Schema([
      TJSONPair.Create('unit', Prop('string', 'File path or unit name; default: the active editor')),
      TJSONPair.Create('members', Prop('boolean', 'Include fields, methods and properties of types (default true)'))],
      [])));
  Result.Add(Tool('getUnitDependencies',
    'How the units of the project depend on each other (uses clauses read from the code): without "unit" a ' +
    'summary - largest units, most used, most dependent and cycles of mutually dependent units; with "unit" ' +
    'what it uses (interface/implementation), what uses it and the cycle it is in. Use it before refactoring ' +
    'or moving code between units.',
    Schema([
      TJSONPair.Create('unit', Prop('string', 'A unit name or file; default: the summary')),
      TJSONPair.Create('project', Prop('string', 'Only this project; default: the whole project group')),
      TJSONPair.Create('top', Prop('number', 'Entries per list in the summary (default 10)'))],
      [])));
  Result.Add(Tool('showTimeline',
    'Open the Claude Timeline in the IDE for the user: the turns of this session with the files each one ' +
    'changed, their diffs, and rewinding files to before a turn. Use it when the user wants to review or undo ' +
    'what was changed.',
    Schema([], [])));
  Result.Add(Tool('showProjectMap',
    'Open the interactive project map in the IDE for the user: the unit dependency graph with sizes, forms, ' +
    'data modules and cycles. Use it when the user asks to see the architecture.',
    Schema([], [])));
  Result.Add(Tool('findSymbol',
    'Find where a Delphi symbol is declared in the project sources: types, members, method bodies, routines, ' +
    'constants, variables and enum values, with file, line range and the declaration itself. Names: "TOrder", ' +
    '"TOrder.Save" (declaration and body) or "Save". Comments and strings are ignored, unlike grep.',
    Schema([
      TJSONPair.Create('name', Prop('string', 'Symbol name, optionally qualified by its type or unit')),
      TJSONPair.Create('kind', Prop('string', 'Only this kind: class, record, interface, enum, type, method, ' +
        'methodImpl, routine, property, field, const, var, enumValue')),
      TJSONPair.Create('files', ArrayProp('Only these files (paths or unit names); default: the project group')),
      TJSONPair.Create('maxResults', Prop('number', 'Default 50'))],
      ['name'])));
  Result.Add(Tool('findReferences',
    'Find every use of an identifier in the project''s Delphi sources and text forms (.pas, .dpr, .inc, .dfm, ' +
    '.fmx: event handlers and component names too), outside comments and strings, with the line text and the ' +
    'qualifier (Customer.Save). Matching is by name, not by type: same-named members of other classes match too.',
    Schema([
      TJSONPair.Create('name', Prop('string', 'Identifier; for TOrder.Save the name Save is searched')),
      TJSONPair.Create('files', ArrayProp('Only these files (paths or unit names); default: the project group')),
      TJSONPair.Create('maxResults', Prop('number', 'Default 300'))],
      ['name'])));
  Result.Add(Tool('renameSymbol',
    'Rename an identifier in the project''s Delphi sources and text forms (event handler and component names in ' +
    '.dfm/.fmx included), skipping comments and strings. With dryRun (the default) it lists every occurrence ' +
    'with an id (file:line:col); call it again with dryRun=false and "only" set to the ids to change exactly ' +
    'those (all when "only" is omitted). Open files change in the editor (Ctrl+Z undoes) and are saved; closed ' +
    'files keep their encoding. Forms open in the designer are skipped. Build afterwards.',
    Schema([
      TJSONPair.Create('name', Prop('string', 'Current identifier')),
      TJSONPair.Create('newName', Prop('string', 'New identifier')),
      TJSONPair.Create('files', ArrayProp('Only these files (paths or unit names); default: the project group')),
      TJSONPair.Create('dryRun', Prop('boolean', 'Only list the occurrences (default true)')),
      TJSONPair.Create('only', ArrayProp('Occurrence ids from the dry run to change'))],
      ['name', 'newName'])));

  Result.Add(Tool('captureForm',
    'Save a PNG picture of a VCL form (or of one windowed control on it) as it looks in the designer, ' +
    'and return the file path; open it with the Read tool to look at the layout',
    Schema([
      TJSONPair.Create('form', Prop('string', 'Unit or .dfm path, unit name or form name; default: the current form')),
      TJSONPair.Create('component', Prop('string', 'Only this windowed control (e.g. a panel)'))],
      [])));
end;

function DelphiToolDefinitions: TJSONArray;
begin
  Result := TJSONArray.Create;
  AddDelphiTools(Result);
end;

function IsDelphiTool(const Name: string): Boolean;
var
  Defs: TJSONArray;
  V: TJSONValue;
begin
  Result := False;
  Defs := DelphiToolDefinitions;
  try
    for V in Defs do
      if JsonStr(V as TJSONObject, 'name') = Name then
        Exit(True);
  finally
    Defs.Free;
  end;
end;

{ TMcpServer }

constructor TMcpServer.Create(const Backend: IIdeBackend);
begin
  inherited Create;
  FBackend := Backend;
  FSettingsHooks := True;
end;

destructor TMcpServer.Destroy;
begin
  Stop;
  inherited;
end;

function TMcpServer.Running: Boolean;
begin
  Result := (FWs <> nil) and (FWs.Port <> 0);
end;

function TMcpServer.Port: Integer;
begin
  if FWs <> nil then
    Result := FWs.Port
  else
    Result := 0;
end;

function TMcpServer.ClientCount: Integer;
begin
  if FWs <> nil then
    Result := FWs.ConnectionCount
  else
    Result := 0;
end;

procedure TMcpServer.Start;
begin
  if Running then
    Exit;
  FShuttingDown := False;
  FToken := NewAuthToken;
  FWs := TWsServer.Create(FToken);
  FWs.OnMessage := WsMessage;
  FWs.OnConnect := WsConnect;
  FWs.OnDisconnect := WsDisconnect;
  FWs.OnHttp := HttpRequest;
  try
    FWs.Start;
  except
    FreeAndNil(FWs);
    raise;
  end;
  FLockFolders := #0; // force write
  RefreshLockFile;
  WriteMcpConfig;
  WriteHookSettings;
  Log(Format('Server listening on 127.0.0.1:%d', [FWs.Port]));
end;

procedure TMcpServer.Stop;
var
  I: Integer;
begin
  if FWs = nil then
    Exit;
  FShuttingDown := True;
  if FLockFile <> '' then
  begin
    System.SysUtils.DeleteFile(FLockFile);
    FLockFile := '';
  end;
  if FMcpConfigFile <> '' then
  begin
    System.SysUtils.DeleteFile(FMcpConfigFile);
    FMcpConfigFile := '';
  end;
  if FHookSettingsFile <> '' then
  begin
    System.SysUtils.DeleteFile(FHookSettingsFile);
    FHookSettingsFile := '';
  end;
  FWs.Stop;
  FreeAndNil(FWs);
  // Run anything the socket threads queued so no closure outlives this object.
  if TThread.CurrentThread.ThreadID = MainThreadID then
    for I := 1 to 3 do
    begin
      CheckSynchronize(0);
      FlushMainLoop;
    end;
end;

procedure TMcpServer.RefreshLockFile;
var
  Folders: TArray<string>;
  Joined: string;
begin
  if not Running then
    Exit;
  Folders := FBackend.WorkspaceFolders;
  Joined := string.Join(#1, Folders);
  if (Joined <> FLockFolders) or (FLockFile = '') or not FileExists(FLockFile) then
  begin
    WriteLockFile(Folders);
    FLockFolders := Joined;
  end;
end;

procedure TMcpServer.WriteLockFile(const Folders: TArray<string>);
var
  Obj: TJSONObject;
  Arr: TJSONArray;
  F, Dir: string;
begin
  Dir := ClaudeIdeLockDir;
  ForceDirectories(Dir);
  FLockFile := TPath.Combine(Dir, IntToStr(FWs.Port) + '.lock');
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('pid', TJSONNumber.Create(GetCurrentProcessId));
    Arr := TJSONArray.Create;
    for F in Folders do
      Arr.Add(F);
    Obj.AddPair('workspaceFolders', Arr);
    Obj.AddPair('ideName', FBackend.IdeName);
    Obj.AddPair('transport', 'ws');
    Obj.AddPair('authToken', FToken);
    TFile.WriteAllBytes(FLockFile, TEncoding.UTF8.GetBytes(Obj.ToJSON)); // no BOM
  finally
    Obj.Free;
  end;
end;

procedure TMcpServer.WriteMcpConfig;
var
  Root, Servers, Srv: TJSONObject;
  Bytes: TBytes;
  Dir: string;
begin
  Dir := ClaudeIdeLockDir;
  ForceDirectories(Dir);
  Srv := TJSONObject.Create;
  Srv.AddPair('type', 'http');
  Srv.AddPair('url', Format('http://127.0.0.1:%d%s', [FWs.Port, MCP_HTTP_PATH]));
  Srv.AddPair('headers', TJSONObject.Create.AddPair('Authorization', 'Bearer ' + FToken));
  Servers := TJSONObject.Create;
  Servers.AddPair(TOOLS_SERVER_NAME, Srv);
  Root := TJSONObject.Create;
  try
    Root.AddPair('mcpServers', Servers);
    Bytes := TEncoding.UTF8.GetBytes(Root.Format(2));
  finally
    Root.Free;
  end;
  // One file per IDE instance (passed to the panel's claude), plus a fixed name that always
  // points at the most recently started IDE, for claude sessions started outside the IDE.
  FMcpConfigFile := TPath.Combine(Dir, IntToStr(FWs.Port) + '.' + MCP_CONFIG_NAME);
  TFile.WriteAllBytes(FMcpConfigFile, Bytes);
  try
    TFile.WriteAllBytes(TPath.Combine(Dir, MCP_CONFIG_NAME), Bytes);
  except
    // Another IDE instance may be writing it; the per-instance file is what the panel uses.
  end;
end;

procedure TMcpServer.WriteHookSettings;
var
  Cmd, Old: string;
  Root, Hooks: TJSONObject;

  function Entry(const Matcher: string): TJSONArray;
  var
    E: TJSONObject;
  begin
    E := TJSONObject.Create;
    if Matcher <> '' then
      E.AddPair('matcher', Matcher);
    E.AddPair('hooks', TJSONArray.Create.Add(TJSONObject.Create
      .AddPair('type', 'command')
      .AddPair('command', Cmd)
      .AddPair('timeout', TJSONNumber.Create(10))));
    Result := TJSONArray.Create.Add(E);
  end;

begin
  // curl posts the event JSON (stdin) to the IDE. The IDE answers with no body, so nothing is added
  // to Claude's context; "|| exit 0" (cmd and bash alike) keeps Claude going when the IDE is gone.
  Cmd := Format('curl -s -m 5 -X POST -H "Authorization: Bearer %s" -H "Content-Type: application/json" ' +
    '--data-binary @- http://127.0.0.1:%d%s || exit 0', [FToken, FWs.Port, HOOK_PATH]);
  Root := TJSONObject.Create;
  if FSettingsHooks then
  begin
    Hooks := TJSONObject.Create;
    Hooks.AddPair('UserPromptSubmit', Entry(''));
    Hooks.AddPair('PreToolUse', Entry('Edit|Write|MultiEdit|NotebookEdit'));
    Hooks.AddPair('Stop', Entry(''));
    Root.AddPair('hooks', Hooks);
  end;
  // The status line: the session's model, context and cost go to the IDE, which answers the text
  // Claude Code shows in its own status row.
  if FSettingsStatusLine then
    Root.AddPair('statusLine', TJSONObject.Create
      .AddPair('type', 'command')
      .AddPair('command', Format('curl -s -m 2 -X POST -H "Authorization: Bearer %s" -H "Content-Type: application/json" ' +
        '--data-binary @- http://127.0.0.1:%d%s || exit 0', [FToken, FWs.Port, STATUSLINE_PATH])));
  try
    // Settings of IDEs that ended without cleaning up (no lock file for that port any more).
    for Old in TDirectory.GetFiles(ClaudeIdeLockDir, '*' + HOOK_SETTINGS_SUFFIX) do
      if not FileExists(TPath.Combine(ClaudeIdeLockDir,
        Copy(ExtractFileName(Old), 1, Length(ExtractFileName(Old)) - Length(HOOK_SETTINGS_SUFFIX)) + '.lock')) then
        System.SysUtils.DeleteFile(Old);
    FHookSettingsFile := TPath.Combine(ClaudeIdeLockDir, IntToStr(FWs.Port) + HOOK_SETTINGS_SUFFIX);
    TFile.WriteAllBytes(FHookSettingsFile, TEncoding.UTF8.GetBytes(Root.Format(2)));
  finally
    Root.Free;
  end;
end;

procedure TMcpServer.SetClaudeSettings(Hooks, StatusLine: Boolean);
begin
  if (Hooks = FSettingsHooks) and (StatusLine = FSettingsStatusLine) then
    Exit;
  FSettingsHooks := Hooks;
  FSettingsStatusLine := StatusLine;
  if Running then
    WriteHookSettings;
end;

procedure TMcpServer.ClientsChanged;
begin
  // Main thread.
  if FShuttingDown then
    Exit;
  if Assigned(FOnClientsChanged) then
    FOnClientsChanged(Self);
end;

procedure TMcpServer.WsConnect(const Conn: IWsConnection);
var
  Id: Integer;
begin
  Id := Conn.Id;
  Log(Format('Claude Code connected (#%d)', [Id]));
  TThread.Queue(nil,
    procedure
    begin
      ClientsChanged;
    end);
end;

procedure TMcpServer.WsDisconnect(const Conn: IWsConnection);
var
  Id: Integer;
begin
  Id := Conn.Id;
  if not FShuttingDown then
    Log(Format('Claude Code disconnected (#%d)', [Id]));
  TThread.Queue(nil,
    procedure
    begin
      ClientsChanged;
    end);
end;

procedure TMcpServer.Notify(const Method: string; Params: TJSONObject);
var
  Msg: TJSONObject;
begin
  Msg := TJSONObject.Create;
  try
    Msg.AddPair('jsonrpc', '2.0');
    Msg.AddPair('method', Method);
    if Params <> nil then
      Msg.AddPair('params', Params)
    else
      Msg.AddPair('params', TJSONObject.Create);
    if FWs <> nil then
      FWs.Broadcast(Msg.ToJSON);
  finally
    Msg.Free;
  end;
end;

procedure TMcpServer.SendResult(const Reply: TReplyProc; const IdJson: string; Result: TJSONValue);
begin
  try
    Reply('{"jsonrpc":"2.0","id":' + IdJson + ',"result":' + Result.ToJSON + '}');
  finally
    Result.Free;
  end;
end;

procedure TMcpServer.SendError(const Reply: TReplyProc; const IdJson: string; Code: Integer; const Msg: string);
var
  Err: TJSONObject;
begin
  Err := TJSONObject.Create;
  try
    Err.AddPair('code', TJSONNumber.Create(Code));
    Err.AddPair('message', Msg);
    Reply('{"jsonrpc":"2.0","id":' + IdJson + ',"error":' + Err.ToJSON + '}');
  finally
    Err.Free;
  end;
end;

function ToolResultJson(const R: TToolResult): TJSONObject;
var
  Content: TJSONArray;
  Item: TJSONObject;
  S: string;
begin
  Result := TJSONObject.Create;
  Content := TJSONArray.Create;
  for S in R.Texts do
  begin
    Item := TJSONObject.Create;
    Item.AddPair('type', 'text');
    Item.AddPair('text', S);
    Content.Add(Item);
  end;
  Result.AddPair('content', Content);
  Result.AddPair('isError', TJSONBool.Create(R.IsError));
end;

procedure TMcpServer.WsMessage(const Conn: IWsConnection; const Text: string);
var
  V: TJSONValue;
  Obj: TJSONObject;
  IdVal, ParamsVal: TJSONValue;
  Method: string;
begin
  // Socket thread.
  if FShuttingDown then
    Exit;
  V := TJSONObject.ParseJSONValue(Text);
  try
    if not (V is TJSONObject) then
    begin
      Conn.Send('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}');
      Exit;
    end;
    Obj := TJSONObject(V);
    Method := JsonStr(Obj, 'method');
    IdVal := Obj.GetValue('id');
    if Method = '' then
      Exit; // a response to something we sent; nothing to do
    if (IdVal = nil) or (IdVal is TJSONNull) then
      Exit; // notification (notifications/initialized, ide_connected, ...)
    ParamsVal := Obj.GetValue('params');
    if not (ParamsVal is TJSONObject) then
      ParamsVal := nil;
    HandleRequest(
      procedure(const Json: string)
      begin
        Conn.Send(Json);
      end,
      mcIde, IdVal.ToJSON, Method, TJSONObject(ParamsVal));
  finally
    V.Free;
  end;
end;

type
  { One HTTP request waiting for its answer, which may come later from the main thread. }
  IHttpWait = interface
    procedure Answer(const Json: string);
    function Wait(const ShuttingDown: TFunc<Boolean>; out Json: string): Boolean;
  end;

  THttpWait = class(TInterfacedObject, IHttpWait)
  private
    FEvent: TEvent;
    FJson: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Answer(const Json: string);
    function Wait(const ShuttingDown: TFunc<Boolean>; out Json: string): Boolean;
  end;

constructor THttpWait.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor THttpWait.Destroy;
begin
  FEvent.Free;
  inherited;
end;

procedure THttpWait.Answer(const Json: string);
begin
  FJson := Json;
  FEvent.SetEvent;
end;

function THttpWait.Wait(const ShuttingDown: TFunc<Boolean>; out Json: string): Boolean;
begin
  // Poll so that stopping the server never waits for a tool that will not run any more.
  while FEvent.WaitFor(200) <> wrSignaled do
    if ShuttingDown() then
      Exit(False);
  Json := FJson;
  Result := True;
end;

const
  SHUTTING_DOWN_JSON = '{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Server is shutting down"}}';

function TMcpServer.HttpRequest(const Path, Body: string; out Status: Integer): string;
var
  V: TJSONValue;
  Obj, Params: TJSONObject;
  IdVal: TJSONValue;
  Method, UrlPath: string;
  Waiter: IHttpWait;
begin
  // Connection thread; may block until the tool has run in the main thread.
  Status := 200;
  Result := '';
  UrlPath := Path;
  if Pos('?', UrlPath) > 0 then
    UrlPath := Copy(UrlPath, 1, Pos('?', UrlPath) - 1);
  if SameText(UrlPath, HOOK_PATH) then
  begin
    // A Claude Code hook: answered without a body (it would go into Claude's context), but only once
    // the main thread has handled it - PreToolUse must snapshot the file before Claude writes it.
    Status := 202;
    if FShuttingDown then
      Exit;
    Waiter := THttpWait.Create;
    RunInMainLoop(
      procedure
      begin
        try
          if not FShuttingDown and Assigned(FOnHook) then
            FOnHook(Body);
        finally
          Waiter.Answer('');
        end;
      end);
    Waiter.Wait(
      function: Boolean
      begin
        Result := FShuttingDown;
      end, Result);
    Exit;
  end;
  if SameText(UrlPath, STATUSLINE_PATH) then
  begin
    // The status line command of a session: the answer is the text Claude Code shows.
    if FShuttingDown then
      Exit;
    Waiter := THttpWait.Create;
    RunInMainLoop(
      procedure
      var
        Line: string;
      begin
        Line := '';
        try
          if not FShuttingDown and Assigned(FOnStatusLine) then
            Line := FOnStatusLine(Body);
        finally
          Waiter.Answer(Line);
        end;
      end);
    Waiter.Wait(
      function: Boolean
      begin
        Result := FShuttingDown;
      end, Result);
    Exit;
  end;
  if not SameText(UrlPath, MCP_HTTP_PATH) then
  begin
    Status := 404;
    Exit;
  end;
  if FShuttingDown then
    Exit(SHUTTING_DOWN_JSON);
  V := TJSONObject.ParseJSONValue(Body);
  try
    if not (V is TJSONObject) then
      Exit('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}');
    Obj := TJSONObject(V);
    Method := JsonStr(Obj, 'method');
    IdVal := Obj.GetValue('id');
    if (Method = '') or (IdVal = nil) or (IdVal is TJSONNull) then
    begin
      Status := 202; // notification or response: accepted, no body
      Exit;
    end;
    if Obj.GetValue('params') is TJSONObject then
      Params := TJSONObject(Obj.GetValue('params'))
    else
      Params := nil;
    Waiter := THttpWait.Create;
    HandleRequest(
      procedure(const Json: string)
      begin
        Waiter.Answer(Json);
      end,
      mcTools, IdVal.ToJSON, Method, Params);
  finally
    V.Free;
  end;
  if not Waiter.Wait(
    function: Boolean
    begin
      Result := FShuttingDown;
    end, Result) then
    Result := SHUTTING_DOWN_JSON;
end;

procedure TMcpServer.HandleRequest(const Reply: TReplyProc; Channel: TMcpChannel; const IdJson, Method: string;
  Params: TJSONObject);
var
  R, Caps, Info: TJSONObject;
  ToolName: string;
  ArgsJson: string;
  ArgsVal: TJSONValue;
begin
  if Method = 'initialize' then
  begin
    Log('initialize: ' + JsonStr(Params, 'clientInfo'));
    R := TJSONObject.Create;
    R.AddPair('protocolVersion', JsonStr(Params, 'protocolVersion', DEFAULT_PROTOCOL));
    Caps := TJSONObject.Create;
    Caps.AddPair('tools', TJSONObject.Create.AddPair('listChanged', TJSONBool.Create(False)));
    if Channel = mcIde then
      Caps.AddPair('logging', TJSONObject.Create)
    else
      Caps.AddPair('prompts', TJSONObject.Create.AddPair('listChanged', TJSONBool.Create(False)));
    R.AddPair('capabilities', Caps);
    Info := TJSONObject.Create;
    if Channel = mcIde then
      Info.AddPair('name', SERVER_NAME)
    else
      Info.AddPair('name', TOOLS_SERVER_NAME);
    Info.AddPair('version', SERVER_VERSION);
    R.AddPair('serverInfo', Info);
    SendResult(Reply, IdJson, R);
  end
  else if Method = 'ping' then
    SendResult(Reply, IdJson, TJSONObject.Create)
  else if Method = 'tools/list' then
  begin
    if Channel = mcIde then
      SendResult(Reply, IdJson, TJSONObject.Create.AddPair('tools', ToolDefinitions))
    else
      SendResult(Reply, IdJson, TJSONObject.Create.AddPair('tools', DelphiToolDefinitions));
  end
  else if Method = 'prompts/list' then
  begin
    // Workflows over the Delphi tools; Claude Code shows them as /mcp__delphi__<name>.
    if Channel = mcTools then
      SendResult(Reply, IdJson, TJSONObject.Create.AddPair('prompts', PromptListJson))
    else
      SendResult(Reply, IdJson, TJSONObject.Create.AddPair('prompts', TJSONArray.Create));
  end
  else if Method = 'prompts/get' then
  begin
    R := nil;
    if Channel = mcTools then
    begin
      ArgsVal := nil;
      if Params <> nil then
        ArgsVal := Params.GetValue('arguments');
      if ArgsVal is TJSONObject then
        R := PromptGetJson(JsonStr(Params, 'name'), TJSONObject(ArgsVal))
      else
        R := PromptGetJson(JsonStr(Params, 'name'), nil);
    end;
    if R <> nil then
      SendResult(Reply, IdJson, R)
    else
      SendError(Reply, IdJson, -32602, 'Unknown prompt: ' + JsonStr(Params, 'name'));
  end
  else if Method = 'resources/list' then
    SendResult(Reply, IdJson, TJSONObject.Create.AddPair('resources', TJSONArray.Create))
  else if Method = 'tools/call' then
  begin
    ToolName := JsonStr(Params, 'name');
    Log('tools/call ' + ToolName);
    if (Channel = mcTools) and not IsDelphiTool(ToolName) then
    begin
      SendResult(Reply, IdJson, ToolResultJson(TToolResult.Error('Unknown tool: ' + ToolName)));
      Exit;
    end;
    ArgsJson := '{}';
    if Params <> nil then
    begin
      ArgsVal := Params.GetValue('arguments');
      if ArgsVal is TJSONObject then
        ArgsJson := ArgsVal.ToJSON;
    end;
    // IDE services must be used from the main thread, from its message loop (see RunInMainLoop).
    RunInMainLoop(
      procedure
      var
        Args: TJSONObject;
      begin
        if FShuttingDown then
          Exit;
        Args := TJSONObject.ParseJSONValue(ArgsJson) as TJSONObject;
        try
          try
            FBackend.ExecuteTool(ToolName, Args,
              procedure(const Res: TToolResult)
              begin
                SendResult(Reply, IdJson, ToolResultJson(Res));
              end);
          except
            on E: Exception do
              SendResult(Reply, IdJson, ToolResultJson(TToolResult.Error(E.ClassName + ': ' + E.Message)));
          end;
        finally
          Args.Free;
        end;
      end);
  end
  else
    SendError(Reply, IdJson, -32601, 'Method not found: ' + Method);
end;

end.
