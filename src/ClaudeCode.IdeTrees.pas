unit ClaudeCode.IdeTrees;

{ What is being dragged from the IDE's own trees (Project Manager, Structure view). The trees are
  VirtualTrees inside the IDE packages, not part of the Open Tools API, so they are read through
  RTTI: the tree that is in an OLE drag, its selected nodes and their paths ("Orders|OrdersApp.exe|
  MainForm.pas"). Their drags carry no file names, so the Claude panel asks here. }

interface

uses
  System.SysUtils;

{ References for the selected nodes of the IDE tree that is being dragged right now: files and
  folders from the Project Manager, "file#L10-20" for the Structure view (a method body, a type...).
  Empty when no IDE tree is dragging. }
function IdeTreeDragItems: TArray<string>;

{ The Structure view does not start drags of its own; this makes it start an OLE drag (as the
  Project Manager does) so that its items can be dropped into the Claude panel. }
procedure EnableIdeTreeDrag;

implementation

uses
  System.Classes, System.Rtti, System.StrUtils, System.TypInfo, Vcl.Forms, ToolsAPI, ClaudeCode.Utils, ClaudeCode.PascalIndex,
  ClaudeCode.CodeTools, ClaudeCode.IdeBackend;

const
  PROJECT_TREE = 'ProjectTree2';        // ProjectManagerForm
  STRUCTURE_TREE = 'VirtualStringTree1'; // StructureViewForm

function FindTree(const FormName, TreeName: string): TComponent;
var
  I: Integer;
  F: TComponent;
begin
  for I := 0 to Screen.FormCount - 1 do
    if SameText(Screen.Forms[I].Name, FormName) then
    begin
      F := Screen.Forms[I].FindComponent(TreeName);
      if F <> nil then
        Exit(F);
    end;
  Result := nil;
end;

function IsOleDragging(Tree: TComponent): Boolean;
var
  Ctx: TRttiContext;
  P: TRttiProperty;
begin
  P := Ctx.GetType(Tree.ClassType).GetProperty('TreeStates');
  Result := (P <> nil) and ContainsText(P.GetValue(Tree).ToString, 'tsOLEDragging');
end;

{ The paths of the selected nodes, each split into the captions from the root down. }
function SelectedPaths(Tree: TComponent): TArray<TArray<string>>;
var
  Ctx: TRttiContext;
  T: TRttiType;
  First, Next, Path: TRttiMethod;
  Params: TArray<TRttiParameter>;
  Node: TValue;
  S: string;
  Count: Integer;
begin
  Result := nil;
  T := Ctx.GetType(Tree.ClassType);
  First := T.GetMethod('GetFirstSelected');
  Next := T.GetMethod('GetNextSelected');
  Path := T.GetMethod('Path');
  if (First = nil) or (Next = nil) or (Path = nil) then
    Exit;
  Params := Path.GetParameters;
  if Length(Params) <> 4 then
    Exit; // Path(Node, Column, TextType, Delimiter) of the IDE's VirtualTrees
  if Length(First.GetParameters) = 0 then
    Node := First.Invoke(Tree, [])
  else
    Node := First.Invoke(Tree, [False]);
  Count := 0;
  while (Node.AsType<Pointer> <> nil) and (Count < 100) do
  begin
    S := Path.Invoke(Tree, [Node, TValue.From<Integer>(0), TValue.FromOrdinal(Params[2].ParamType.Handle, 0),
      TValue.From<Char>('|')]).AsString;
    Result := Result + [S.TrimRight(['|']).Split(['|'])];
    if Length(Next.GetParameters) = 1 then
      Node := Next.Invoke(Tree, [Node])
    else
      Node := Next.Invoke(Tree, [Node, False]);
    Inc(Count);
  end;
end;

{ A Project Manager node: group | project output (OrdersApp.exe) | [folders |] file [| form file]. }
function ProjectNodeFile(const Parts: TArray<string>): string;
var
  Group: IOTAProjectGroup;
  Project: IOTAProject;
  I: Integer;
  Name, F: string;
begin
  Result := '';
  if Length(Parts) = 0 then
    Exit;
  Group := (BorlandIDEServices as IOTAModuleServices).MainProjectGroup;
  if Length(Parts) = 1 then
  begin
    if Group <> nil then
      Result := ExtractFilePath(Group.FileName);
    Exit;
  end;
  Project := FindProject(ChangeFileExt(Parts[1], ''));
  if Project = nil then
    Exit;
  if Length(Parts) = 2 then
    Exit(ExtractFilePath(Project.FileName)); // a project stands for its folder
  Name := Parts[High(Parts)];
  for I := 0 to Project.GetModuleCount - 1 do
  begin
    F := Project.GetModule(I).FileName;
    if SameText(ExtractFileName(F), Name) then
      Exit(F);
    // A form file shown under its unit (MainForm.pas | MainForm.dfm).
    if SameText(ChangeFileExt(ExtractFileName(F), ExtractFileExt(Name)), Name) and
       FileExists(ChangeFileExt(F, ExtractFileExt(Name))) then
      Exit(ChangeFileExt(F, ExtractFileExt(Name)));
  end;
  // Build configurations, target platforms and the like are not files.
end;

function Ref(const FileName: string; Line1, Line2: Integer): string;
begin
  Result := FileName;
  if Line1 > 0 then
    if Line2 > Line1 then
      Result := Format('%s#L%d-%d', [FileName, Line1, Line2])
    else
      Result := Format('%s#L%d', [FileName, Line1]);
end;

{ A Structure view node: Structure | interface/implementation | [type |] member, of the active file. }
function StructureNodeRef(const Parts: TArray<string>; const FileName: string; const Info: TPasUnitInfo): string;
var
  D: TPasDecl;
begin
  // uses entries: the unit's file, when it is one of ours.
  if (Length(Parts) >= 4) and SameText(Parts[2], 'uses') then
    Exit(ResolveUnitFile(StructureCaptionName(Parts[High(Parts)])));
  if FindStructureItem(Info, Parts, D) then
    Result := Ref(FileName, D.Line, D.EndLine)
  else
    Result := FileName;
end;

function ActiveSourceFile: string;
var
  Module: IOTAModule;
begin
  Module := (BorlandIDEServices as IOTAModuleServices).CurrentModule;
  if Module <> nil then
    Result := Module.CurrentEditor.FileName
  else
    Result := '';
end;

function IdeTreeDragItems: TArray<string>;
var
  Tree: TComponent;
  Parts: TArray<string>;
  FileName, Src, S: string;
  Info: TPasUnitInfo;
begin
  Result := nil;
  try
    Tree := FindTree('ProjectManagerForm', PROJECT_TREE);
    if (Tree <> nil) and IsOleDragging(Tree) then
    begin
      for Parts in SelectedPaths(Tree) do
      begin
        S := ProjectNodeFile(Parts);
        if (S <> '') and (IndexText(S, Result) < 0) then
          Result := Result + [S];
      end;
      Exit;
    end;
    Tree := FindTree('StructureViewForm', STRUCTURE_TREE);
    if (Tree <> nil) and IsOleDragging(Tree) then
    begin
      FileName := ActiveSourceFile;
      if (FileName = '') or not ReadSourceText(FileName, Src) then
        Exit;
      Info := ParsePascalUnit(Src);
      for Parts in SelectedPaths(Tree) do
      begin
        S := StructureNodeRef(Parts, FileName, Info);
        if (S <> '') and (IndexText(S, Result) < 0) then
          Result := Result + [S];
      end;
    end;
  except
    on E: Exception do
      Log('Reading the dragged IDE tree failed: ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure EnableIdeTreeDrag;

  procedure SetEnum(P: TRttiProperty; Tree: TComponent; const Name: string);
  var
    V: Integer;
  begin
    V := GetEnumValue(P.PropertyType.Handle, Name);
    if V >= 0 then
      P.SetValue(Tree, TValue.FromOrdinal(P.PropertyType.Handle, V));
  end;

var
  Tree: TComponent;
  Ctx: TRttiContext;
  T: TRttiType;
  Mode, Kind: TRttiProperty;
begin
  try
    Tree := FindTree('StructureViewForm', STRUCTURE_TREE);
    if Tree = nil then
      Exit;
    T := Ctx.GetType(Tree.ClassType);
    Mode := T.GetProperty('DragMode');
    Kind := T.GetProperty('DragType');
    if (Mode = nil) or (Kind = nil) or (Mode.GetValue(Tree).ToString = 'dmAutomatic') then
      Exit;
    // It comes with dmManual and starts no drag; dropped elsewhere in the IDE, an item at most opens its unit.
    SetEnum(Mode, Tree, 'dmAutomatic');
    SetEnum(Kind, Tree, 'dtOLE');
  except
    on E: Exception do
      Log('Structure view drag: ' + E.ClassName + ': ' + E.Message);
  end;
end;

end.
