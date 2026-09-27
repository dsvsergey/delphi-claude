unit ClaudeCode.IdeBackend;

{ Implements the Claude Code IDE tools on top of the Delphi Open Tools API.
  Everything here runs in the IDE main thread. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ToolsAPI, ClaudeCode.Mcp, ClaudeCode.Build,
  ClaudeCode.EditorSync;

type
  TSelectionInfo = record
    Valid: Boolean;
    FilePath: string;
    Text: string;
    StartLine, StartChar, EndLine, EndChar: Integer; // 0-based, like LSP
    function IsEmpty: Boolean;
    function SamePosition(const O: TSelectionInfo): Boolean;
    function SelectionJson: TJSONObject;
    function NotificationParams: TJSONObject;
    function ToolJson: TJSONObject;
  end;

  TDelphiIdeBackend = class(TInterfacedObject, IIdeBackend)
  private
    FLatest: TSelectionInfo;
    FBuild: TBuildRunner;
    FSync: TEditorSync;
    function ToolOpenFile(Args: TJSONObject): TToolResult;
    procedure ToolOpenDiff(Args: TJSONObject; const Done: TToolDone);
    function ToolGetOpenEditors: TToolResult;
    function ToolGetWorkspaceFolders: TToolResult;
    function ToolGetDiagnostics(Args: TJSONObject): TToolResult;
    function ToolCheckDocumentDirty(Args: TJSONObject): TToolResult;
    function ToolSaveDocument(Args: TJSONObject): TToolResult;
    function ToolCloseTab(Args: TJSONObject): TToolResult;
    procedure ToolBuildProject(Args: TJSONObject; const Done: TToolDone);
    function ToolGetProjectInfo(Args: TJSONObject): TToolResult;
  public
    constructor Create;
    destructor Destroy; override;
    { Stops a running build without answering it; call before the MCP server goes away. }
    procedure Shutdown;
    { IIdeBackend }
    procedure ExecuteTool(const Name: string; Args: TJSONObject; const Done: TToolDone);
    function WorkspaceFolders: TArray<string>;
    function IdeName: string;

    function CurrentSelection(WithText: Boolean): TSelectionInfo;
    function ActiveProjectDir: string;
    property Latest: TSelectionInfo read FLatest write FLatest;
    property Sync: TEditorSync read FSync;
  end;

function EditorServices: IOTAEditorServices;
function ModuleServices: IOTAModuleServices;
function FindEditBuffer(const FileName: string): IOTAEditBuffer;
function ReadBufferBytes(const Buffer: IOTAEditBuffer; StartPos, MaxCount: Integer): TBytes;
{ A project of the current group by file path, file name or name without extension;
  the active project when Name is empty. }
function FindProject(const Name: string): IOTAProject;

implementation

uses
  System.Generics.Collections, System.Generics.Defaults, System.Math, Vcl.Forms,
  ClaudeCode.Utils, ClaudeCode.DiffForm, ClaudeCode.TextSync, ClaudeCode.FormTools, ClaudeCode.DebugTools,
  ClaudeCode.FileHistory;

const
  MAX_SELECTION_BYTES = 2 * 1024 * 1024;

function EditorServices: IOTAEditorServices;
begin
  Result := BorlandIDEServices as IOTAEditorServices;
end;

function ModuleServices: IOTAModuleServices;
begin
  Result := BorlandIDEServices as IOTAModuleServices;
end;

function FindEditBuffer(const FileName: string): IOTAEditBuffer;
var
  It: IOTAEditBufferIterator;
  I: Integer;
begin
  Result := nil;
  if (FileName <> '') and EditorServices.GetEditBufferIterator(It) then
    for I := 0 to It.Count - 1 do
      if SameFileName(It.EditBuffers[I].FileName, FileName) then
        Exit(It.EditBuffers[I]);
end;

function ReadBufferBytes(const Buffer: IOTAEditBuffer; StartPos, MaxCount: Integer): TBytes;
const
  CHUNK = 64 * 1024;
var
  Reader: IOTAEditReader;
  Total, Want, Got: Integer;
begin
  Reader := Buffer.CreateReader;
  Total := 0;
  SetLength(Result, 0);
  repeat
    Want := Min(CHUNK, MaxCount - Total);
    if Want <= 0 then
      Break;
    SetLength(Result, Total + Want);
    Got := Reader.GetText(StartPos + Total, PAnsiChar(@Result[Total]), Want);
    if Got < 0 then
      Got := 0;
    Inc(Total, Got);
  until Got < Want;
  SetLength(Result, Total);
end;

function ReadBufferText(const Buffer: IOTAEditBuffer): string;
begin
  Result := Utf8BytesToString(ReadBufferBytes(Buffer, 0, MaxInt));
end;

{ The LSP "character" of an editor position: the UTF-16 index within the line. The editor
  counts in its own units (UTF-8 bytes in the buffer), so the line prefix is read and measured. }
function LspCharacter(const View: IOTAEditView; const CP: TOTACharPos): Integer;
const
  MAX_LINE_BYTES = 64 * 1024;
var
  LineStart: TOTACharPos;
  P0, P1: Integer;
begin
  Result := CP.CharIndex;
  if (View = nil) or (View.Buffer = nil) or (CP.CharIndex <= 0) then
    Exit;
  LineStart.Line := CP.Line;
  LineStart.CharIndex := 0;
  P0 := View.CharPosToPos(LineStart);
  P1 := View.CharPosToPos(CP);
  if (P0 >= 0) and (P1 > P0) and (P1 - P0 <= MAX_LINE_BYTES) then
    Result := Length(Utf8BytesToString(ReadBufferBytes(View.Buffer, P0, P1 - P0)));
end;

{ Selects the buffer range between two UTF-8 byte offsets. }
procedure SelectRange(const View: IOTAEditView; Offset1, Offset2: Integer);
var
  CP: TOTACharPos;
  EP1, EP2: TOTAEditPos;
begin
  CP := View.PosToCharPos(Offset1);
  View.ConvertPos(False, EP1, CP);
  CP := View.PosToCharPos(Offset2);
  View.ConvertPos(False, EP2, CP);
  View.Block.Style := btNonInclusive;
  View.Position.Move(EP1.Line, EP1.Col);
  View.Block.BeginBlock;
  View.Position.Move(EP2.Line, EP2.Col);
  View.Block.EndBlock;
  View.Block.Visible := True;
  View.MoveViewToCursor;
  View.Paint;
end;

function ProjectGroup: IOTAProjectGroup;
begin
  Result := ModuleServices.MainProjectGroup;
end;

function FindProject(const Name: string): IOTAProject;
var
  G: IOTAProjectGroup;
  P: IOTAProject;
  I: Integer;
  Path: string;
begin
  if Trim(Name) = '' then
    Exit(GetActiveProject);
  Result := nil;
  G := ProjectGroup;
  if G = nil then
    Exit;
  if Name.Contains('\') or Name.Contains('/') then
    Path := PathFromUri(Name)
  else
    Path := '';
  for I := 0 to G.ProjectCount - 1 do
  begin
    P := G.Projects[I];
    if ((Path <> '') and SameFileName(P.FileName, Path)) or
       SameText(ExtractFileName(P.FileName), Name) or
       SameText(ChangeFileExt(ExtractFileName(P.FileName), ''), Name) then
      Exit(P);
  end;
end;

function IdeRootDir: string;
begin
  Result := IncludeTrailingPathDelimiter((BorlandIDEServices as IOTAServices).GetRootDirectory);
end;

{ TSelectionInfo }

function TSelectionInfo.IsEmpty: Boolean;
begin
  Result := (StartLine = EndLine) and (StartChar = EndChar);
end;

function TSelectionInfo.SamePosition(const O: TSelectionInfo): Boolean;
begin
  Result := (Valid = O.Valid) and SameFileName(FilePath, O.FilePath) and
    (StartLine = O.StartLine) and (StartChar = O.StartChar) and
    (EndLine = O.EndLine) and (EndChar = O.EndChar);
end;

function PosJson(Line, Ch: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('line', TJSONNumber.Create(Line));
  Result.AddPair('character', TJSONNumber.Create(Ch));
end;

function TSelectionInfo.SelectionJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('start', PosJson(StartLine, StartChar));
  Result.AddPair('end', PosJson(EndLine, EndChar));
  Result.AddPair('isEmpty', TJSONBool.Create(IsEmpty));
end;

function TSelectionInfo.NotificationParams: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('text', Text);
  Result.AddPair('filePath', FilePath);
  Result.AddPair('fileUrl', PathToUri(FilePath));
  Result.AddPair('selection', SelectionJson);
end;

function TSelectionInfo.ToolJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  if not Valid then
  begin
    Result.AddPair('success', TJSONBool.Create(False));
    Result.AddPair('message', 'No active editor found');
    Exit;
  end;
  Result.AddPair('success', TJSONBool.Create(True));
  Result.AddPair('text', Text);
  Result.AddPair('filePath', FilePath);
  Result.AddPair('fileUrl', PathToUri(FilePath));
  Result.AddPair('selection', SelectionJson);
end;

{ TDelphiIdeBackend }

constructor TDelphiIdeBackend.Create;
begin
  inherited Create;
  FBuild := TBuildRunner.Create;
  FSync := TEditorSync.Create;
end;

destructor TDelphiIdeBackend.Destroy;
begin
  FSync.Free;
  FBuild.Free;
  inherited;
end;

procedure TDelphiIdeBackend.Shutdown;
begin
  FBuild.Cancel;
  FSync.Enabled := False;
  CancelDebugWaits;
end;

function TDelphiIdeBackend.IdeName: string;
begin
  Result := 'Delphi';
end;

function TDelphiIdeBackend.CurrentSelection(WithText: Boolean): TSelectionInfo;
var
  View: IOTAEditView;
  Block: IOTAEditBlock;
  EP: TOTAEditPos;
  CP1, CP2: TOTACharPos;
  Off1, Off2: Integer;
  Swap: TOTACharPos;
begin
  Result := Default(TSelectionInfo);
  View := EditorServices.TopView;
  if (View = nil) or (View.Buffer = nil) then
    Exit;
  Result.FilePath := View.Buffer.FileName;
  Result.Valid := Result.FilePath <> '';
  if not Result.Valid then
    Exit;
  Block := View.Block;
  if (Block <> nil) and Block.IsValid and Block.Visible and
     ((Block.StartingRow <> Block.EndingRow) or (Block.StartingColumn <> Block.EndingColumn)) then
  begin
    EP.Line := Block.StartingRow;
    EP.Col := Block.StartingColumn;
    View.ConvertPos(True, EP, CP1);
    EP.Line := Block.EndingRow;
    EP.Col := Block.EndingColumn;
    View.ConvertPos(True, EP, CP2);
    if (CP2.Line < CP1.Line) or ((CP2.Line = CP1.Line) and (CP2.CharIndex < CP1.CharIndex)) then
    begin
      Swap := CP1;
      CP1 := CP2;
      CP2 := Swap;
    end;
    case Block.Style of
      btInclusive:
        Inc(CP2.CharIndex);
      btLine:
        begin
          CP1.CharIndex := 0;
          Inc(CP2.Line);
          CP2.CharIndex := 0;
        end;
    end;
    if WithText then
    begin
      if Block.Style <> btColumn then
      begin
        Off1 := View.CharPosToPos(CP1);
        Off2 := View.CharPosToPos(CP2);
        if Off2 > Off1 then
          Result.Text := Utf8BytesToString(
            ReadBufferBytes(View.Buffer, Off1, Min(Off2 - Off1, MAX_SELECTION_BYTES)));
      end
      else
        Result.Text := Block.Text;
    end;
  end
  else
  begin
    EP := View.CursorPos;
    View.ConvertPos(True, EP, CP1);
    CP2 := CP1;
  end;
  Result.StartLine := CP1.Line - 1;
  Result.StartChar := LspCharacter(View, CP1);
  Result.EndLine := CP2.Line - 1;
  Result.EndChar := LspCharacter(View, CP2);
end;

function TDelphiIdeBackend.ActiveProjectDir: string;
var
  P: IOTAProject;
begin
  Result := '';
  P := GetActiveProject;
  if (P <> nil) and (ExtractFilePath(P.FileName) <> '') then
    Result := ExcludeTrailingPathDelimiter(ExtractFilePath(P.FileName));
end;

function TDelphiIdeBackend.WorkspaceFolders: TArray<string>;
var
  L: TList<string>;
  G: IOTAProjectGroup;
  It: IOTAEditBufferIterator;
  I: Integer;

  procedure AddDirOf(const FileName: string);
  var
    D: string;
    X: string;
  begin
    D := ExtractFilePath(FileName);
    if (D = '') or not DirectoryExists(D) then
      Exit;
    D := ExcludeTrailingPathDelimiter(D);
    for X in L do
      if SameFileName(X, D) then
        Exit;
    L.Add(D);
  end;

begin
  L := TList<string>.Create;
  try
    G := ProjectGroup;
    if G <> nil then
    begin
      AddDirOf(G.FileName);
      for I := 0 to G.ProjectCount - 1 do
        AddDirOf(G.Projects[I].FileName);
    end;
    if (L.Count = 0) and EditorServices.GetEditBufferIterator(It) then
      for I := 0 to It.Count - 1 do
        AddDirOf(It.EditBuffers[I].FileName);
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

procedure TDelphiIdeBackend.ExecuteTool(const Name: string; Args: TJSONObject; const Done: TToolDone);
begin
  if Name = 'openFile' then
    Done(ToolOpenFile(Args))
  else if Name = 'openDiff' then
    ToolOpenDiff(Args, Done)
  else if Name = 'getCurrentSelection' then
    Done(TToolResult.Json(CurrentSelection(True).ToolJson))
  else if Name = 'getLatestSelection' then
  begin
    if FLatest.Valid then
      Done(TToolResult.Json(FLatest.ToolJson))
    else
      Done(TToolResult.Json(CurrentSelection(True).ToolJson));
  end
  else if Name = 'getOpenEditors' then
    Done(ToolGetOpenEditors)
  else if Name = 'getWorkspaceFolders' then
    Done(ToolGetWorkspaceFolders)
  else if Name = 'getDiagnostics' then
    Done(ToolGetDiagnostics(Args))
  else if Name = 'checkDocumentDirty' then
    Done(ToolCheckDocumentDirty(Args))
  else if Name = 'saveDocument' then
    Done(ToolSaveDocument(Args))
  else if Name = 'close_tab' then
    Done(ToolCloseTab(Args))
  else if Name = 'closeAllDiffTabs' then
    Done(TToolResult.Ok([Format('CLOSED_%d_DIFF_TABS', [CloseAllDiffForms])]))
  else if Name = 'buildProject' then
    ToolBuildProject(Args, Done)
  else if Name = 'getProjectInfo' then
    Done(ToolGetProjectInfo(Args))
  else if Name = 'getFormComponents' then
    Done(ToolGetFormComponents(Args))
  else if Name = 'getSelectedComponents' then
    Done(ToolGetSelectedComponents(Args))
  else if Name = 'setComponentProperties' then
    Done(ToolSetComponentProperties(Args))
  else if Name = 'createComponent' then
    Done(ToolCreateComponent(Args))
  else if Name = 'deleteComponent' then
    Done(ToolDeleteComponent(Args))
  else if Name = 'captureForm' then
    Done(ToolCaptureForm(Args))
  else if Name = 'getDebugState' then
    Done(ToolGetDebugState(Args))
  else if Name = 'evaluateExpression' then
    Done(ToolEvaluateExpression(Args))
  else if Name = 'setBreakpoint' then
    Done(ToolSetBreakpoint(Args))
  else if Name = 'listBreakpoints' then
    Done(ToolListBreakpoints(Args))
  else if Name = 'removeBreakpoint' then
    Done(ToolRemoveBreakpoint(Args))
  else if Name = 'getFileHistory' then
    Done(ToolGetFileHistory(Args))
  else if Name = 'debugControl' then
    ToolDebugControl(Args, Done)
  else
    Done(TToolResult.Error('Unknown tool: ' + Name));
end;

function TDelphiIdeBackend.ToolOpenFile(Args: TJSONObject): TToolResult;
var
  Path, StartText, EndText, Text: string;
  Buffer: IOTAEditBuffer;
  View: IOTAEditView;
  P, Q, EndOff: Integer;
  Obj: TJSONObject;
begin
  Path := PathFromUri(JsonStr(Args, 'filePath'));
  if Path = '' then
    Exit(TToolResult.Error('filePath is required'));
  if (FindEditBuffer(Path) = nil) and not FileExists(Path) then
    Exit(TToolResult.Error('File not found: ' + Path));

  (BorlandIDEServices as IOTAActionServices).OpenFile(Path);
  Buffer := FindEditBuffer(Path);
  if Buffer = nil then
    Exit(TToolResult.Error('Could not open file in editor: ' + Path));
  Buffer.Show;
  View := Buffer.TopView;

  StartText := JsonStr(Args, 'startText');
  EndText := JsonStr(Args, 'endText');
  if (View <> nil) and (StartText <> '') then
  begin
    Text := ReadBufferText(Buffer);
    P := Pos(StartText, Text);
    if P > 0 then
    begin
      EndOff := P - 1 + Length(StartText);
      if EndText <> '' then
      begin
        Q := Pos(EndText, Text, EndOff + 1);
        if Q > 0 then
          EndOff := Q - 1 + Length(EndText);
      end;
      if JsonBool(Args, 'selectToEndOfLine', False) then
        while (EndOff < Length(Text)) and not CharInSet(Text[EndOff + 1], [#13, #10]) do
          Inc(EndOff);
      // Text came from the UTF-8 buffer, so its UTF-8 length up to a point is a buffer offset.
      SelectRange(View, TEncoding.UTF8.GetByteCount(Copy(Text, 1, P - 1)),
        TEncoding.UTF8.GetByteCount(Copy(Text, 1, EndOff)));
    end;
  end;

  if JsonBool(Args, 'makeFrontmost', True) then
    Result := TToolResult.Ok(['Opened file: ' + Path])
  else
  begin
    Obj := TJSONObject.Create;
    Obj.AddPair('success', TJSONBool.Create(True));
    Obj.AddPair('filePath', Path);
    Obj.AddPair('languageId', LanguageIdForFile(Path));
    Obj.AddPair('lineCount', TJSONNumber.Create(Buffer.GetLinesInBuffer));
    Result := TToolResult.Json(Obj);
  end;
end;

procedure TDelphiIdeBackend.ToolOpenDiff(Args: TJSONObject; const Done: TToolDone);
var
  OldPath, NewPath, NewText, OldText, TabName, Note: string;
  Existing, Form: TClaudeDiffForm;
  Theming: IOTAIDEThemingServices;
  OldEncoding: TEncodingInfo;
  Restored, Unresolved: Integer;
  Sync: TEditorSync;
begin
  OldPath := PathFromUri(JsonStr(Args, 'old_file_path'));
  NewPath := PathFromUri(JsonStr(Args, 'new_file_path'));
  if NewPath = '' then
    NewPath := OldPath;
  NewText := JsonStr(Args, 'new_file_contents');
  TabName := JsonStr(Args, 'tab_name', ExtractFileName(NewPath));

  Existing := FindDiffForm(TabName);
  if Existing <> nil then
    Existing.Reject;

  if not ReadTextFileAutoEnc(OldPath, OldText) then
    OldText := '';

  // Claude reads files as UTF-8: in an ANSI file every non-ASCII character arrives as U+FFFD.
  Note := '';
  OldEncoding := DetectFileEncoding(OldPath);
  if OldEncoding.IsAnsi then
  begin
    Note := OldEncoding.Name + ' file, the encoding is kept';
    NewText := RestoreLostChars(OldText, NewText, Restored, Unresolved);
    if Restored > 0 then
      Note := Note + Format('; restored %d line(s) Claude could not read', [Restored]);
    if Unresolved > 0 then
      Note := Note + Format('; %d changed line(s) contain U+FFFD, check them', [Unresolved]);
  end;

  Sync := FSync;
  Form := TClaudeDiffForm.CreateDiff(TabName, NewPath, OldText, NewText,
    procedure(Decision: TDiffDecision; const FinalContents: string)
    begin
      if Decision = ddAccepted then
      begin
        Sync.ExpectWrite(NewPath, OldEncoding);
        Done(TToolResult.Ok(['FILE_SAVED', FinalContents]));
      end
      else
        Done(TToolResult.Ok(['DIFF_REJECTED', TabName]));
    end);
  if Note <> '' then
    Form.Note := Note;
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, Theming) and Theming.IDEThemingEnabled then
  begin
    Theming.RegisterFormClass(TClaudeDiffForm);
    Theming.ApplyTheme(Form);
  end;
  Form.ShowAndActivate;
end;

function TDelphiIdeBackend.ToolGetOpenEditors: TToolResult;
var
  It: IOTAEditBufferIterator;
  Top: IOTAEditBuffer;
  Tabs: TJSONArray;
  Tab: TJSONObject;
  I: Integer;
  F, ActiveFile: string;
begin
  Tabs := TJSONArray.Create;
  Top := EditorServices.TopBuffer;
  if Top <> nil then
    ActiveFile := Top.FileName;
  if EditorServices.GetEditBufferIterator(It) then
    for I := 0 to It.Count - 1 do
    begin
      F := It.EditBuffers[I].FileName;
      if F = '' then
        Continue;
      Tab := TJSONObject.Create;
      Tab.AddPair('uri', PathToUri(F));
      Tab.AddPair('isActive', TJSONBool.Create(SameFileName(F, ActiveFile)));
      Tab.AddPair('label', ExtractFileName(F));
      Tab.AddPair('languageId', LanguageIdForFile(F));
      Tab.AddPair('isDirty', TJSONBool.Create(It.EditBuffers[I].IsModified));
      Tab.AddPair('fileName', F);
      Tabs.Add(Tab);
    end;
  Result := TToolResult.Json(TJSONObject.Create.AddPair('tabs', Tabs));
end;

function TDelphiIdeBackend.ToolGetWorkspaceFolders: TToolResult;
var
  Folders: TArray<string>;
  Arr: TJSONArray;
  Obj: TJSONObject;
  F: string;
begin
  Folders := WorkspaceFolders;
  Arr := TJSONArray.Create;
  for F in Folders do
    Arr.Add(TJSONObject.Create
      .AddPair('name', ExtractFileName(F))
      .AddPair('uri', PathToUri(F))
      .AddPair('path', F));
  Obj := TJSONObject.Create;
  Obj.AddPair('success', TJSONBool.Create(True));
  Obj.AddPair('folders', Arr);
  if Length(Folders) > 0 then
    Obj.AddPair('rootPath', Folders[0])
  else
    Obj.AddPair('rootPath', TJSONNull.Create);
  Result := TToolResult.Json(Obj);
end;

function TDelphiIdeBackend.ToolGetDiagnostics(Args: TJSONObject): TToolResult;
const
  SeverityName: array[0..3] of string = ('Error', 'Error', 'Warning', 'Information');
var
  Files: TList<string>;
  It: IOTAEditBufferIterator;
  I: Integer;
  Uri, F: string;
  Module: IOTAModule;
  ModErrors: IOTAModuleErrors;
  Errs: TOTAErrors;
  E: TOTAError;
  Res: TJSONArray;
  Entry, Diag, Range: TJSONObject;
  Diags: TJSONArray;
  Explicit: Boolean;
  Buffer: IOTAEditBuffer;
  View: IOTAEditView;
begin
  Res := TJSONArray.Create;
  Files := TList<string>.Create;
  try
    Uri := JsonStr(Args, 'uri');
    Explicit := Uri <> '';
    if Explicit then
      Files.Add(PathFromUri(Uri))
    else if EditorServices.GetEditBufferIterator(It) then
      for I := 0 to It.Count - 1 do
        if It.EditBuffers[I].FileName <> '' then
          Files.Add(It.EditBuffers[I].FileName);

    for F in Files do
    begin
      Diags := TJSONArray.Create;
      Module := ModuleServices.FindModule(F);
      if (Module <> nil) and Supports(Module, IOTAModuleErrors, ModErrors) then
      begin
        Errs := ModErrors.GetErrors(F);
        Buffer := FindEditBuffer(F);
        View := nil;
        if Buffer <> nil then
          View := Buffer.TopView;
        for E in Errs do
        begin
          Range := TJSONObject.Create;
          Range.AddPair('start', PosJson(E.Start.Line - 1, LspCharacter(View, E.Start)));
          Range.AddPair('end', PosJson(E.Stop.Line - 1, LspCharacter(View, E.Stop)));
          Diag := TJSONObject.Create;
          Diag.AddPair('message', E.Text);
          Diag.AddPair('severity', SeverityName[EnsureRange(E.Severity, 0, 3)]);
          Diag.AddPair('range', Range);
          Diag.AddPair('source', 'Delphi Error Insight');
          Diags.Add(Diag);
        end;
      end;
      if Explicit or (Diags.Count > 0) then
      begin
        Entry := TJSONObject.Create;
        Entry.AddPair('uri', PathToUri(F));
        Entry.AddPair('diagnostics', Diags);
        Res.Add(Entry);
      end
      else
        Diags.Free;
    end;
  finally
    Files.Free;
  end;
  Result := TToolResult.Json(Res);
end;

function TDelphiIdeBackend.ToolCheckDocumentDirty(Args: TJSONObject): TToolResult;
var
  Path: string;
  Buffer: IOTAEditBuffer;
  Obj: TJSONObject;
begin
  Path := PathFromUri(JsonStr(Args, 'filePath'));
  Buffer := FindEditBuffer(Path);
  Obj := TJSONObject.Create;
  if Buffer = nil then
  begin
    Obj.AddPair('success', TJSONBool.Create(False));
    Obj.AddPair('message', 'Document not open: ' + Path);
  end
  else
  begin
    Obj.AddPair('success', TJSONBool.Create(True));
    Obj.AddPair('filePath', Path);
    Obj.AddPair('isDirty', TJSONBool.Create(Buffer.IsModified));
    Obj.AddPair('isUntitled', TJSONBool.Create(not FileExists(Path)));
  end;
  Result := TToolResult.Json(Obj);
end;

function TDelphiIdeBackend.ToolSaveDocument(Args: TJSONObject): TToolResult;
var
  Path: string;
  Module: IOTAModule;
  Obj: TJSONObject;
  Saved: Boolean;
begin
  Path := PathFromUri(JsonStr(Args, 'filePath'));
  Module := ModuleServices.FindModule(Path);
  Obj := TJSONObject.Create;
  if (Module = nil) or (FindEditBuffer(Path) = nil) then
  begin
    Obj.AddPair('success', TJSONBool.Create(False));
    Obj.AddPair('message', 'Document not open: ' + Path);
  end
  else
  begin
    Saved := Module.Save(False, True);
    Obj.AddPair('success', TJSONBool.Create(Saved));
    Obj.AddPair('filePath', Path);
    Obj.AddPair('saved', TJSONBool.Create(Saved));
    if Saved then
      Obj.AddPair('message', 'Document saved successfully')
    else
      Obj.AddPair('message', 'Document could not be saved');
  end;
  Result := TToolResult.Json(Obj);
end;

function TDelphiIdeBackend.ToolCloseTab(Args: TJSONObject): TToolResult;
var
  TabName: string;
  Diff: TClaudeDiffForm;
  It: IOTAEditBufferIterator;
  I: Integer;
  F: string;
  Module: IOTAModule;
begin
  TabName := JsonStr(Args, 'tab_name');
  Diff := FindDiffForm(TabName);
  if Diff <> nil then
  begin
    Diff.Reject;
    Exit(TToolResult.Ok(['TAB_CLOSED']));
  end;
  // Otherwise close an unmodified editor tab with that name (never discard edits).
  if EditorServices.GetEditBufferIterator(It) then
    for I := 0 to It.Count - 1 do
    begin
      F := It.EditBuffers[I].FileName;
      if (F <> '') and (SameText(ExtractFileName(F), TabName) or SameFileName(F, PathFromUri(TabName))) then
      begin
        if not It.EditBuffers[I].IsModified then
        begin
          Module := ModuleServices.FindModule(F);
          if Module <> nil then
            Module.CloseModule(True);
        end;
        Break;
      end;
    end;
  Result := TToolResult.Ok(['TAB_CLOSED']);
end;

{ Build }

const
  BUILD_MESSAGE_GROUP = 'Claude Build';
  MAX_BUILD_MESSAGES = 200;
  OUTPUT_TAIL_LINES = 40;

function BuildSummary(const Req: TBuildRequest; const R: TBuildResult): string;
var
  State: string;
begin
  if R.Error <> '' then
    State := 'could not run'
  else if R.TimedOut then
    State := 'timed out'
  else if R.Success then
    State := 'succeeded'
  else
    State := 'FAILED';
  Result := Format('%s %s (%s, %s) %s: %d error(s), %d warning(s), %d hint(s), %.1f s',
    [Req.Target, ExtractFileName(Req.ProjectFile), Req.Config, Req.Platform, State,
     R.Count(bsError) + R.Count(bsFatal), R.Count(bsWarning), R.Count(bsHint), R.ElapsedMs / 1000]);
end;

procedure ShowBuildInMessages(const Req: TBuildRequest; const R: TBuildResult);
const
  Prefix: array[TBuildSeverity] of string = ('Hint', 'Warning', 'Error', 'Fatal');
var
  MS: IOTAMessageServices;
  G: IOTAMessageGroup;
  M: TBuildMessage;
  LineRef: Pointer;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, MS) then
    Exit;
  try
    G := MS.GetGroup(BUILD_MESSAGE_GROUP);
    if G = nil then
      G := MS.AddMessageGroup(BUILD_MESSAGE_GROUP);
    MS.ClearMessageGroup(G);
    MS.AddTitleMessage(BuildSummary(Req, R), G);
    if R.Error <> '' then
      MS.AddTitleMessage(R.Error, G);
    for M in R.Messages do
      MS.AddToolMessage(M.FileName, M.Text, Trim(Prefix[M.Severity] + ' ' + M.Code),
        M.Line, M.Column, nil, LineRef, G);
  except
    on E: Exception do
      Log('Messages view update failed: ' + E.Message);
  end;
end;

function OutputTail(const Output: string; Count: Integer): string;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Text := Output;
    Result := '';
    for I := Max(0, L.Count - Count) to L.Count - 1 do
      Result := Result + L[I] + sLineBreak;
  finally
    L.Free;
  end;
end;

function StringsJson(const Items: TArray<string>): TJSONArray;
var
  S: string;
begin
  Result := TJSONArray.Create;
  for S in Items do
    Result.Add(S);
end;

procedure TDelphiIdeBackend.ToolBuildProject(Args: TJSONObject; const Done: TToolDone);
var
  Project: IOTAProject;
  Req: TBuildRequest;
  TargetArg, F: string;
  IncludeHints, SaveModified: Boolean;
  It: IOTAEditBufferIterator;
  Module: IOTAModule;
  I: Integer;
  Unsaved, Saved: TList<string>;
  UnsavedArr, SavedArr: TArray<string>;
  Err: string;
begin
  Project := FindProject(JsonStr(Args, 'project'));
  TargetArg := LowerCase(JsonStr(Args, 'target', 'make'));
  if FBuild.Busy then
    Err := 'A build is already running'
  else if Project = nil then
    Err := 'Project not found: ' + JsonStr(Args, 'project', '(no active project)')
  else if not SameText(ExtractFileExt(Project.FileName), '.dproj') then
    Err := 'Only Delphi .dproj projects can be built: ' + Project.FileName
  else if TargetArg = 'make' then
    Req.Target := 'Make'
  else if TargetArg = 'build' then
    Req.Target := 'Build'
  else if TargetArg = 'clean' then
    Req.Target := 'Clean'
  else
    Err := 'target must be "make", "build" or "clean"';
  if Err <> '' then
  begin
    Done(TToolResult.Error(Err));
    Exit;
  end;
  Req.ProjectFile := Project.FileName;
  Req.Config := JsonStr(Args, 'config', Project.CurrentConfiguration);
  Req.Platform := JsonStr(Args, 'platform', Project.CurrentPlatform);
  Req.TimeoutSec := Trunc(StrToFloatDef(JsonStr(Args, 'timeoutSec'), 600, TFormatSettings.Invariant));
  Req.RsVars := IdeRootDir + 'bin\rsvars.bat';
  IncludeHints := JsonBool(Args, 'includeHints', True);
  SaveModified := JsonBool(Args, 'saveModified', False);

  // MSBuild reads files from disk, so unsaved editor changes are not part of the build.
  Unsaved := TList<string>.Create;
  Saved := TList<string>.Create;
  try
    if EditorServices.GetEditBufferIterator(It) then
      for I := 0 to It.Count - 1 do
      begin
        F := It.EditBuffers[I].FileName;
        if (F = '') or not It.EditBuffers[I].IsModified then
          Continue;
        Module := ModuleServices.FindModule(F);
        if SaveModified and (Module <> nil) and Module.Save(False, True) then
          Saved.Add(F)
        else
          Unsaved.Add(F);
      end;
    UnsavedArr := Unsaved.ToArray;
    SavedArr := Saved.ToArray;
  finally
    Saved.Free;
    Unsaved.Free;
  end;

  Log(Format('Build started: %s %s (%s, %s)', [Req.Target, Req.ProjectFile, Req.Config, Req.Platform]));
  FBuild.Start(Req,
    procedure(const R: TBuildResult)
    var
      Obj: TJSONObject;
      Msgs: TJSONArray;
      M: TBuildMessage;
      Omitted: Integer;
    begin
      Log(BuildSummary(Req, R));
      ShowBuildInMessages(Req, R);
      Obj := TJSONObject.Create;
      Obj.AddPair('success', TJSONBool.Create(R.Success));
      Obj.AddPair('summary', BuildSummary(Req, R));
      Obj.AddPair('project', Req.ProjectFile);
      Obj.AddPair('target', Req.Target);
      Obj.AddPair('config', Req.Config);
      Obj.AddPair('platform', Req.Platform);
      Obj.AddPair('exitCode', TJSONNumber.Create(R.ExitCode));
      if R.TimedOut then
        Obj.AddPair('timedOut', TJSONBool.Create(True));
      if R.Error <> '' then
        Obj.AddPair('error', R.Error);
      Obj.AddPair('errorCount', TJSONNumber.Create(R.Count(bsError) + R.Count(bsFatal)));
      Obj.AddPair('warningCount', TJSONNumber.Create(R.Count(bsWarning)));
      Obj.AddPair('hintCount', TJSONNumber.Create(R.Count(bsHint)));
      Msgs := TJSONArray.Create;
      Omitted := 0;
      for M in R.Messages do
        if (M.Severity = bsHint) and not IncludeHints then
          Continue
        else if Msgs.Count >= MAX_BUILD_MESSAGES then
          Inc(Omitted)
        else
          Msgs.Add(M.ToJson);
      Obj.AddPair('messages', Msgs);
      if Omitted > 0 then
        Obj.AddPair('omittedMessages', TJSONNumber.Create(Omitted));
      if Length(UnsavedArr) > 0 then
        Obj.AddPair('unsavedFiles', StringsJson(UnsavedArr));
      if Length(SavedArr) > 0 then
        Obj.AddPair('savedFiles', StringsJson(SavedArr));
      // Without parsed errors the raw output is the only clue why the build failed.
      if not R.Success and (R.Count(bsError) + R.Count(bsFatal) = 0) and (R.Output <> '') then
        Obj.AddPair('outputTail', OutputTail(R.Output, OUTPUT_TAIL_LINES));
      Done(TToolResult.Json(Obj));
    end);
end;

{ Project info }

function SplitList(const S: string): TJSONArray;
var
  Part: string;
begin
  Result := TJSONArray.Create;
  for Part in S.Split([';']) do
    if Trim(Part) <> '' then
      Result.Add(Trim(Part));
end;

function ModuleTypeName(T: TOTAModuleType): string;
begin
  case T of
    omtForm: Result := 'form';
    omtDataModule: Result := 'dataModule';
    omtProjUnit: Result := 'projectUnit';
    omtUnit: Result := 'unit';
    omtRc: Result := 'rc';
    omtAsm: Result := 'asm';
    omtDef: Result := 'def';
    omtObj: Result := 'obj';
    omtRes: Result := 'res';
    omtLib: Result := 'lib';
    omtTypeLib: Result := 'typeLib';
    omtPackageImport: Result := 'packageImport';
    omtFormResource: Result := 'formResource';
    omtCustom: Result := 'custom';
    omtIDL: Result := 'idl';
  else
    Result := IntToStr(T);
  end;
end;

function ProjectJson(const P: IOTAProject; Detailed: Boolean): TJSONObject;
const
  // DCCStrs names; strings keep us independent of that unit.
  ListValues: array[0..5] of string = ('DCC_Define', 'DCC_UnitSearchPath', 'DCC_Namespace',
    'DCC_UsePackage', 'DCC_IncludePath', 'DCC_ResourcePath');
  ScalarValues: array[0..2] of string = ('DCC_ExeOutput', 'DCC_DcuOutput', 'DCC_BplOutput');
var
  Configs: IOTAProjectOptionsConfigurations;
  Active, Cfg: IOTABuildConfiguration;
  Values, Mod_: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  S: string;
  MI: IOTAModuleInfo;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', ChangeFileExt(ExtractFileName(P.FileName), ''));
  Result.AddPair('file', P.FileName);
  Result.AddPair('isActive', TJSONBool.Create(P = GetActiveProject));
  Result.AddPair('personality', P.Personality);
  Result.AddPair('projectType', P.ProjectType);
  Result.AddPair('applicationType', P.ApplicationType);
  Result.AddPair('frameworkType', P.FrameworkType);
  Result.AddPair('config', P.CurrentConfiguration);
  Result.AddPair('platform', P.CurrentPlatform);
  if not Detailed then
    Exit;

  Result.AddPair('supportedPlatforms', StringsJson(P.SupportedPlatforms));
  if P.ProjectOptions <> nil then
    Result.AddPair('targetFile', P.ProjectOptions.TargetName);

  if Supports(P.ProjectOptions, IOTAProjectOptionsConfigurations, Configs) then
  begin
    Arr := TJSONArray.Create;
    for I := 0 to Configs.ConfigurationCount - 1 do
      Arr.Add(Configs.Configurations[I].Name);
    Result.AddPair('configurations', Arr);
    Active := Configs.ActiveConfiguration;
    if Active <> nil then
    begin
      Cfg := Active.PlatformConfiguration[P.CurrentPlatform];
      if Cfg = nil then
        Cfg := Active;
      Values := TJSONObject.Create;
      for S in ListValues do
        Values.AddPair(S, SplitList(Cfg.GetValue(S, True)));
      for S in ScalarValues do
        Values.AddPair(S, Cfg.GetValue(S, True));
      Result.AddPair('options', Values);
    end;
  end;

  Arr := TJSONArray.Create;
  for I := 0 to P.GetModuleCount - 1 do
  begin
    MI := P.GetModule(I);
    if (MI = nil) or (MI.FileName = '') then
      Continue;
    Mod_ := TJSONObject.Create;
    Mod_.AddPair('name', MI.Name);
    Mod_.AddPair('file', MI.FileName);
    Mod_.AddPair('type', ModuleTypeName(MI.ModuleType));
    if MI.FormName <> '' then
    begin
      Mod_.AddPair('formName', MI.FormName);
      Mod_.AddPair('designClass', MI.DesignClass);
    end;
    Arr.Add(Mod_);
  end;
  Result.AddPair('modules', Arr);
end;

function TDelphiIdeBackend.ToolGetProjectInfo(Args: TJSONObject): TToolResult;
var
  Obj, Ide: TJSONObject;
  Arr: TJSONArray;
  G: IOTAProjectGroup;
  P: IOTAProject;
  I: Integer;
begin
  P := FindProject(JsonStr(Args, 'project'));
  if P = nil then
    Exit(TToolResult.Error('Project not found: ' + JsonStr(Args, 'project', '(no active project)')));
  Obj := TJSONObject.Create;
  Ide := TJSONObject.Create;
  Ide.AddPair('product', (BorlandIDEServices as IOTAServices).GetProductIdentifier);
  Ide.AddPair('rootDir', ExcludeTrailingPathDelimiter(IdeRootDir));
  {$IFDEF WIN64}
  Ide.AddPair('bitness', TJSONNumber.Create(64));
  {$ELSE}
  Ide.AddPair('bitness', TJSONNumber.Create(32));
  {$ENDIF}
  Obj.AddPair('ide', Ide);
  G := ProjectGroup;
  if G <> nil then
  begin
    Obj.AddPair('projectGroup', G.FileName);
    Arr := TJSONArray.Create;
    for I := 0 to G.ProjectCount - 1 do
      Arr.Add(ProjectJson(G.Projects[I], False));
    Obj.AddPair('projects', Arr);
  end;
  Obj.AddPair('project', ProjectJson(P, True));
  Result := TToolResult.Json(Obj);
end;

end.
