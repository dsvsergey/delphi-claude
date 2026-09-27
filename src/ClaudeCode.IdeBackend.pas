unit ClaudeCode.IdeBackend;

{ Implements the Claude Code IDE tools on top of the Delphi Open Tools API.
  Everything here runs in the IDE main thread. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ToolsAPI, ClaudeCode.Mcp;

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
    function ToolOpenFile(Args: TJSONObject): TToolResult;
    procedure ToolOpenDiff(Args: TJSONObject; const Done: TToolDone);
    function ToolGetOpenEditors: TToolResult;
    function ToolGetWorkspaceFolders: TToolResult;
    function ToolGetDiagnostics(Args: TJSONObject): TToolResult;
    function ToolCheckDocumentDirty(Args: TJSONObject): TToolResult;
    function ToolSaveDocument(Args: TJSONObject): TToolResult;
    function ToolCloseTab(Args: TJSONObject): TToolResult;
  public
    { IIdeBackend }
    procedure ExecuteTool(const Name: string; Args: TJSONObject; const Done: TToolDone);
    function WorkspaceFolders: TArray<string>;
    function IdeName: string;

    function CurrentSelection(WithText: Boolean): TSelectionInfo;
    function ActiveProjectDir: string;
    property Latest: TSelectionInfo read FLatest write FLatest;
  end;

function EditorServices: IOTAEditorServices;
function ModuleServices: IOTAModuleServices;
function FindEditBuffer(const FileName: string): IOTAEditBuffer;

implementation

uses
  System.Generics.Collections, System.Generics.Defaults, System.Math, Vcl.Forms,
  ClaudeCode.Utils, ClaudeCode.DiffForm;

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

{ Converts a 0-based offset in S into a 1-based line and 0-based character index. }
procedure OffsetToLineChar(const S: string; Offset: Integer; out Line, CharIdx: Integer);
var
  I, LineStart: Integer;
begin
  Line := 1;
  LineStart := 0;
  for I := 1 to Min(Offset, Length(S)) do
    if S[I] = #10 then
    begin
      Inc(Line);
      LineStart := I;
    end;
  CharIdx := Offset - LineStart;
end;

procedure SelectRange(const View: IOTAEditView; Line1, Char1, Line2, Char2: Integer);
var
  CP: TOTACharPos;
  EP1, EP2: TOTAEditPos;
begin
  CP.Line := Line1;
  CP.CharIndex := Char1;
  View.ConvertPos(False, EP1, CP);
  CP.Line := Line2;
  CP.CharIndex := Char2;
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
  Result.StartChar := CP1.CharIndex;
  Result.EndLine := CP2.Line - 1;
  Result.EndChar := CP2.CharIndex;
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
  else
    Done(TToolResult.Error('Unknown tool: ' + Name));
end;

function TDelphiIdeBackend.ToolOpenFile(Args: TJSONObject): TToolResult;
var
  Path, StartText, EndText, Text: string;
  Buffer: IOTAEditBuffer;
  View: IOTAEditView;
  P, Q, EndOff, L1, C1, L2, C2: Integer;
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
      OffsetToLineChar(Text, P - 1, L1, C1);
      OffsetToLineChar(Text, EndOff, L2, C2);
      SelectRange(View, L1, C1, L2, C2);
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
  OldPath, NewPath, NewText, OldText, TabName: string;
  Existing, Form: TClaudeDiffForm;
  Theming: IOTAIDEThemingServices;
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

  Form := TClaudeDiffForm.CreateDiff(TabName, NewPath, OldText, NewText,
    procedure(Decision: TDiffDecision; const FinalContents: string)
    begin
      if Decision = ddAccepted then
        Done(TToolResult.Ok(['FILE_SAVED', FinalContents]))
      else
        Done(TToolResult.Ok(['DIFF_REJECTED', TabName]));
    end);
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
        for E in Errs do
        begin
          Range := TJSONObject.Create;
          Range.AddPair('start', PosJson(E.Start.Line - 1, E.Start.CharIndex));
          Range.AddPair('end', PosJson(E.Stop.Line - 1, E.Stop.CharIndex));
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

end.
