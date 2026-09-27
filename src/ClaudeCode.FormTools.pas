unit ClaudeCode.FormTools;

{ Form designer tools: read the live designer state (DFM text, components, selection),
  change it through the designer (properties, new and deleted components) and take a
  picture of a VCL form. Changes go through the designer so the .dfm, the class
  declaration and the Object Inspector stay in step; nothing is saved automatically. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ToolsAPI, DesignIntf, ClaudeCode.Mcp;

function ToolGetFormComponents(Args: TJSONObject): TToolResult;
function ToolGetSelectedComponents(Args: TJSONObject): TToolResult;
function ToolSetComponentProperties(Args: TJSONObject): TToolResult;
function ToolCreateComponent(Args: TJSONObject): TToolResult;
function ToolDeleteComponent(Args: TJSONObject): TToolResult;
function ToolCaptureForm(Args: TJSONObject): TToolResult;

{ True when the form designer is the active IDE view. }
function DesignerIsActive: Boolean;
{ A request describing the components selected in the active designer, or '' when none. }
function SelectedComponentsPrompt: string;

implementation

uses
  Winapi.Windows, System.IOUtils, System.TypInfo, System.Generics.Collections,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Imaging.pngimage,
  ClaudeCode.Utils, ClaudeCode.ComponentProps;

const
  MAX_DFM_CHARS = 200 * 1024;

type
  TFormContext = record
    Module: IOTAModule;
    Editor: IOTAFormEditor;
    Root: TComponent;
    Designer: IDesigner;
    FileName: string;
    function Dfm: string;
    function Find(const Name: string): TComponent;
    function Framework: string;
    procedure Modified;
    function ResolveMethod: TMethodResolver;
    function MethodNamer: TMethodNamer;
  end;

function ModuleServices: IOTAModuleServices;
begin
  Result := BorlandIDEServices as IOTAModuleServices;
end;

function FormEditorOf(const Module: IOTAModule): IOTAFormEditor;
var
  I: Integer;
begin
  Result := nil;
  if Module = nil then
    Exit;
  for I := 0 to Module.ModuleFileCount - 1 do
    if Supports(Module.ModuleFileEditors[I], IOTAFormEditor, Result) then
      Exit;
  Result := nil;
end;

function RootOf(const Editor: IOTAFormEditor): TComponent;
var
  C: INTAComponent;
begin
  Result := nil;
  if (Editor <> nil) and Supports(Editor.GetRootComponent, INTAComponent, C) then
    Result := C.GetComponent;
end;

function ComponentOf(const C: IOTAComponent): TComponent;
var
  N: INTAComponent;
begin
  Result := nil;
  if Supports(C, INTAComponent, N) then
    Result := N.GetComponent;
end;

function MakeContext(const Module: IOTAModule; out Ctx: TFormContext): Boolean;
var
  NF: INTAFormEditor;
begin
  Ctx := Default(TFormContext);
  Ctx.Editor := FormEditorOf(Module);
  Ctx.Root := RootOf(Ctx.Editor);
  Result := Ctx.Root <> nil;
  if not Result then
    Exit;
  Ctx.Module := Module;
  Ctx.FileName := Module.FileName;
  if Supports(Ctx.Editor, INTAFormEditor, NF) then
    Ctx.Designer := NF.FormDesigner;
end;

{ The form of the current module, a file (.pas/.dfm/.fmx), a unit name or a form name. }
function FindForm(const Spec: string; out Ctx: TFormContext; out Err: string): Boolean;
var
  Path, Ext: string;
  Module: IOTAModule;
  Project: IOTAProject;
  Info: IOTAModuleInfo;
  I: Integer;
begin
  Result := False;
  Err := '';
  if Trim(Spec) = '' then
  begin
    if MakeContext(ModuleServices.CurrentModule, Ctx) then
      Exit(True);
    Err := 'The current editor has no form. Pass "form" (a unit/.dfm path, unit name or form name).';
    Exit;
  end;

  // A path, or a file name; dotted unit names such as Main.Form are names.
  Ext := LowerCase(ExtractFileExt(Spec));
  if Spec.Contains('\') or Spec.Contains('/') or (Ext = '.pas') or (Ext = '.dfm') or (Ext = '.fmx') then
  begin
    Path := PathFromUri(Spec);
    Ext := LowerCase(ExtractFileExt(Path));
    if (Ext = '.dfm') or (Ext = '.fmx') or (Ext = '.lfm') then
      Path := ChangeFileExt(Path, '.pas');
    Module := ModuleServices.FindModule(Path);
    if (Module = nil) and FileExists(Path) then
    begin
      (BorlandIDEServices as IOTAActionServices).OpenFile(Path);
      Module := ModuleServices.FindModule(Path);
    end;
    if MakeContext(Module, Ctx) then
      Exit(True);
    Err := 'No form found for ' + Path;
    Exit;
  end;

  // Open modules: form name or unit name.
  for I := 0 to ModuleServices.ModuleCount - 1 do
  begin
    Module := ModuleServices.Modules[I];
    if MakeContext(Module, Ctx) and
       (SameText(Ctx.Root.Name, Spec) or SameText(ChangeFileExt(ExtractFileName(Module.FileName), ''), Spec)) then
      Exit(True);
  end;
  // Modules of the active project that are not open yet.
  Project := GetActiveProject;
  if Project <> nil then
    for I := 0 to Project.GetModuleCount - 1 do
    begin
      Info := Project.GetModule(I);
      if (Info <> nil) and (Info.FormName <> '') and (SameText(Info.FormName, Spec) or SameText(Info.Name, Spec)) then
        if MakeContext(Info.OpenModule, Ctx) then
          Exit(True);
    end;
  Err := 'No form named ' + Spec;
end;

{ TFormContext }

function TFormContext.Dfm: string;
var
  NF: INTAFormEditor;
  Stream: TMemoryStream;
begin
  Result := '';
  if Supports(Editor, INTAFormEditor, NF) then
  begin
    Stream := TMemoryStream.Create;
    try
      try
        NF.GetFormResource(Stream);
        if Stream.Size > 0 then
          Result := ResourceToDfm(Stream);
      except
        Result := '';
      end;
    finally
      Stream.Free;
    end;
  end;
  if Result = '' then
    Result := ComponentToDfm(Root);
end;

function TFormContext.Find(const Name: string): TComponent;
begin
  if (Name = '') or SameText(Name, Root.Name) then
    Result := Root
  else
    Result := Root.FindComponent(Name);
end;

function TFormContext.Framework: string;
var
  C: TClass;
begin
  if Root is TCustomForm then
    Exit('VCL');
  if Root is TDataModule then
    Exit('DataModule');
  C := Root.ClassType;
  while C <> nil do
  begin
    if string(C.UnitName).StartsWith('FMX.') then
      Exit('FMX');
    C := C.ClassParent;
  end;
  Result := 'Other';
end;

procedure TFormContext.Modified;
begin
  if Designer <> nil then
    Designer.Modified
  else if Editor <> nil then
    Editor.MarkModified;
end;

function TFormContext.ResolveMethod: TMethodResolver;
var
  D: IDesigner;
begin
  D := Designer;
  Result :=
    function(const Name: string; TypeData: PTypeData): TMethod
    begin
      if D = nil then
        raise Exception.Create('No designer to create the event handler in');
      // Creates the handler in the unit when it does not exist yet.
      Result := D.CreateMethod(Name, TypeData);
    end;
end;

function TFormContext.MethodNamer: TMethodNamer;
var
  D: IDesigner;
begin
  D := Designer;
  Result :=
    function(const M: TMethod): string
    begin
      if D <> nil then
        Result := D.GetMethodName(M)
      else
        Result := '(handler)';
    end;
end;

{ Helpers }

function ParentName(C: TComponent): string;
begin
  Result := '';
  if (C is TControl) and (TControl(C).Parent <> nil) then
    Result := TControl(C).Parent.Name;
end;

function ComponentJson(C: TComponent): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', C.Name);
  Result.AddPair('class', C.ClassName);
  if ParentName(C) <> '' then
    Result.AddPair('parent', ParentName(C));
end;

function Capped(const S: string; out Truncated: Boolean): string;
begin
  Truncated := Length(S) > MAX_DFM_CHARS;
  if Truncated then
    Result := Copy(S, 1, MAX_DFM_CHARS)
  else
    Result := S;
end;

function FormHeaderJson(const Ctx: TFormContext): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('form', Ctx.Root.Name);
  Result.AddPair('class', Ctx.Root.ClassName);
  Result.AddPair('file', Ctx.FileName);
  Result.AddPair('framework', Ctx.Framework);
end;

function Fail(const Err: string): TToolResult;
begin
  Result := TToolResult.Error(Err);
end;

{ Tools }

function ToolGetFormComponents(Args: TJSONObject): TToolResult;
var
  Ctx: TFormContext;
  Err, Name, Dfm, Block: string;
  Obj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Truncated: Boolean;
begin
  if not FindForm(JsonStr(Args, 'form'), Ctx, Err) then
    Exit(Fail(Err));
  Obj := FormHeaderJson(Ctx);
  Name := JsonStr(Args, 'component');
  Dfm := Ctx.Dfm;
  if Name <> '' then
  begin
    if Ctx.Find(Name) = nil then
    begin
      Obj.Free;
      Exit(Fail('No component named ' + Name + ' on ' + Ctx.Root.Name));
    end;
    Block := ExtractDfmObject(Dfm, Ctx.Find(Name).Name);
    Obj.AddPair('dfm', Capped(Block, Truncated));
  end
  else
  begin
    Arr := TJSONArray.Create;
    for I := 0 to Ctx.Root.ComponentCount - 1 do
      Arr.Add(ComponentJson(Ctx.Root.Components[I]));
    Obj.AddPair('components', Arr);
    if JsonBool(Args, 'includeDfm', True) then
      Obj.AddPair('dfm', Capped(Dfm, Truncated))
    else
      Truncated := False;
  end;
  if Truncated then
    Obj.AddPair('dfmTruncated', TJSONBool.Create(True));
  Result := TToolResult.Json(Obj);
end;

function SelectedComponents(const Ctx: TFormContext): TArray<TComponent>;
var
  L: TList<TComponent>;
  I: Integer;
  C: TComponent;
begin
  L := TList<TComponent>.Create;
  try
    for I := 0 to Ctx.Editor.GetSelCount - 1 do
    begin
      C := ComponentOf(Ctx.Editor.GetSelComponent(I));
      if C <> nil then
        L.Add(C);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function ToolGetSelectedComponents(Args: TJSONObject): TToolResult;
var
  Ctx: TFormContext;
  Err, Dfm: string;
  Obj, Item: TJSONObject;
  Arr: TJSONArray;
  C: TComponent;
begin
  if not FindForm(JsonStr(Args, 'form'), Ctx, Err) then
    Exit(Fail(Err));
  Obj := FormHeaderJson(Ctx);
  Dfm := Ctx.Dfm;
  Arr := TJSONArray.Create;
  for C in SelectedComponents(Ctx) do
  begin
    Item := ComponentJson(C);
    if C <> Ctx.Root then
      Item.AddPair('dfm', ExtractDfmObject(Dfm, C.Name));
    Arr.Add(Item);
  end;
  Obj.AddPair('selected', Arr);
  Result := TToolResult.Json(Obj);
end;

function ChangesJson(const Changes: TArray<TPropChange>; const Errors: TArray<string>): TJSONObject;
var
  Arr: TJSONArray;
  C: TPropChange;
  E: string;
begin
  Result := TJSONObject.Create;
  Arr := TJSONArray.Create;
  for C in Changes do
    Arr.Add(C.ToJson);
  Result.AddPair('changed', Arr);
  if Length(Errors) > 0 then
  begin
    Arr := TJSONArray.Create;
    for E in Errors do
      Arr.Add(E);
    Result.AddPair('errors', Arr);
  end;
end;

function ToolSetComponentProperties(Args: TJSONObject): TToolResult;
var
  Ctx: TFormContext;
  Err, Name: string;
  Target: TComponent;
  Props: TJSONObject;
  Changes: TArray<TPropChange>;
  Errors: TArray<string>;
  Obj: TJSONObject;
begin
  if not FindForm(JsonStr(Args, 'form'), Ctx, Err) then
    Exit(Fail(Err));
  Name := JsonStr(Args, 'component');
  Target := Ctx.Find(Name);
  if Target = nil then
    Exit(Fail('No component named ' + Name + ' on ' + Ctx.Root.Name));
  if not (Args.GetValue('properties') is TJSONObject) then
    Exit(Fail('"properties" must be an object, e.g. {"Caption": "OK", "Font.Size": 10}'));
  Props := TJSONObject(Args.GetValue('properties'));
  Errors := SetComponentProperties(Ctx.Root, Target, Props, Ctx.ResolveMethod(), Ctx.MethodNamer(), Changes);
  if Length(Changes) > 0 then
    Ctx.Modified;
  Obj := ChangesJson(Changes, Errors);
  Obj.AddPair('component', Target.Name);
  Obj.AddPair('form', Ctx.Root.Name);
  Result := TToolResult.Json(Obj);
  Result.IsError := (Length(Changes) = 0) and (Length(Errors) > 0);
end;

function IntArg(Args: TJSONObject; const Name: string; Default: Integer): Integer;
begin
  Result := Trunc(StrToFloatDef(JsonStr(Args, Name), Default, TFormatSettings.Invariant));
end;

function ToolCreateComponent(Args: TJSONObject): TToolResult;
var
  Ctx: TFormContext;
  Err, ClassName, NewName, ParentArg: string;
  Container, Created: IOTAComponent;
  C: TComponent;
  Changes: TArray<TPropChange>;
  Errors, More: TArray<string>;
  NameProps, Obj: TJSONObject;
begin
  if not FindForm(JsonStr(Args, 'form'), Ctx, Err) then
    Exit(Fail(Err));
  ClassName := JsonStr(Args, 'className');
  if ClassName = '' then
    Exit(Fail('"className" is required, e.g. TButton'));
  NewName := JsonStr(Args, 'name');
  if (NewName <> '') and (Ctx.Root.FindComponent(NewName) <> nil) then
    Exit(Fail('A component named ' + NewName + ' already exists'));
  ParentArg := JsonStr(Args, 'parent');
  if (ParentArg = '') or SameText(ParentArg, Ctx.Root.Name) then
    Container := Ctx.Editor.GetRootComponent
  else
  begin
    Container := Ctx.Editor.FindComponent(ParentArg);
    if Container = nil then
      Exit(Fail('No parent component named ' + ParentArg));
  end;

  Created := Ctx.Editor.CreateComponent(Container, ClassName,
    IntArg(Args, 'left', -1), IntArg(Args, 'top', -1), IntArg(Args, 'width', -1), IntArg(Args, 'height', -1));
  C := ComponentOf(Created);
  if C = nil then
    Exit(Fail('Could not create ' + ClassName + '. The class must be registered in the IDE (its design-time ' +
      'package installed) and allowed on this form/parent.'));

  Errors := nil;
  if NewName <> '' then
  begin
    NameProps := TJSONObject.Create.AddPair('Name', NewName);
    try
      Errors := SetComponentProperties(Ctx.Root, C, NameProps, nil, nil, Changes);
    finally
      NameProps.Free;
    end;
  end;
  if Args.GetValue('properties') is TJSONObject then
  begin
    More := SetComponentProperties(Ctx.Root, C, TJSONObject(Args.GetValue('properties')),
      Ctx.ResolveMethod(), Ctx.MethodNamer(), Changes);
    Errors := Errors + More;
  end
  else
    Changes := nil;
  Ctx.Modified;
  Obj := ChangesJson(Changes, Errors);
  Obj.AddPair('created', ComponentJson(C));
  Obj.AddPair('dfm', ExtractDfmObject(Ctx.Dfm, C.Name));
  Result := TToolResult.Json(Obj);
end;

function ToolDeleteComponent(Args: TJSONObject): TToolResult;
var
  Ctx: TFormContext;
  Err, Name: string;
  Target: IOTAComponent;
begin
  if not FindForm(JsonStr(Args, 'form'), Ctx, Err) then
    Exit(Fail(Err));
  Name := JsonStr(Args, 'component');
  if (Name = '') or SameText(Name, Ctx.Root.Name) then
    Exit(Fail('Pass the name of a component on the form (the form itself cannot be deleted)'));
  Target := Ctx.Editor.FindComponent(Name);
  if Target = nil then
    Exit(Fail('No component named ' + Name + ' on ' + Ctx.Root.Name));
  if not Target.Delete then
    Exit(Fail('The designer did not delete ' + Name + ' (it may be inherited from an ancestor form)'));
  Ctx.Modified;
  Result := TToolResult.Ok([Format('Deleted %s from %s. Its event handlers stay in the unit; ' +
    'the IDE removes empty ones when the file is saved.', [Name, Ctx.Root.Name])]);
end;

function ToolCaptureForm(Args: TJSONObject): TToolResult;
var
  Ctx: TFormContext;
  Err, Name, Dir, FileName: string;
  Target: TComponent;
  Control: TWinControl;
  Bmp: TBitmap;
  Png: TPngImage;
  Obj: TJSONObject;
begin
  if not FindForm(JsonStr(Args, 'form'), Ctx, Err) then
    Exit(Fail(Err));
  Name := JsonStr(Args, 'component');
  Target := Ctx.Find(Name);
  if Target = nil then
    Exit(Fail('No component named ' + Name + ' on ' + Ctx.Root.Name));
  if not (Target is TWinControl) then
    Exit(Fail('Only VCL forms and windowed controls can be captured (this is ' + Ctx.Framework + ' / ' +
      Target.ClassName + ')'));
  Control := TWinControl(Target);
  if not Control.HandleAllocated or (Control.Width <= 0) or (Control.Height <= 0) then
    Exit(Fail(Target.Name + ' is not visible in the designer; open the form first'));

  Dir := TPath.Combine(TPath.GetTempPath, 'claude-delphi');
  ForceDirectories(Dir);
  FileName := TPath.Combine(Dir, Format('%s-%s.png', [Target.Name, FormatDateTime('hhnnsszzz', Now)]));
  Bmp := TBitmap.Create;
  Png := TPngImage.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(Control.ClientWidth, Control.ClientHeight);
    Bmp.Canvas.Brush.Color := clBtnFace;
    Bmp.Canvas.FillRect(Rect(0, 0, Bmp.Width, Bmp.Height));
    Control.PaintTo(Bmp.Canvas, 0, 0);
    Png.Assign(Bmp);
    Png.SaveToFile(FileName);
  finally
    Png.Free;
    Bmp.Free;
  end;
  Obj := TJSONObject.Create;
  Obj.AddPair('file', FileName);
  Obj.AddPair('width', TJSONNumber.Create(Control.ClientWidth));
  Obj.AddPair('height', TJSONNumber.Create(Control.ClientHeight));
  Obj.AddPair('hint', 'Open the PNG with the Read tool to see the form (client area, as in the designer).');
  Result := TToolResult.Json(Obj);
end;

{ Designer selection for "Send Selection to Claude" }

function DesignerIsActive: Boolean;
var
  Module: IOTAModule;
  FE: IOTAFormEditor;
begin
  Module := ModuleServices.CurrentModule;
  Result := (Module <> nil) and (Module.CurrentEditor <> nil) and
    Supports(Module.CurrentEditor, IOTAFormEditor, FE);
end;

function SelectedComponentsPrompt: string;
var
  Ctx: TFormContext;
  Err, Dfm, Blocks: string;
  C: TComponent;
  Names: TList<string>;
begin
  Result := '';
  if not FindForm('', Ctx, Err) then
    Exit;
  Dfm := Ctx.Dfm;
  Blocks := '';
  Names := TList<string>.Create;
  try
    for C in SelectedComponents(Ctx) do
    begin
      Names.Add(C.Name);
      if C = Ctx.Root then
        Blocks := Blocks + Dfm
      else
        Blocks := Blocks + ExtractDfmObject(Dfm, C.Name);
    end;
    if Names.Count = 0 then
      Exit;
    Result := Format('Components %s on form %s (%s), as they are in the designer now:',
      [string.Join(', ', Names.ToArray), Ctx.Root.Name, ExtractFileName(Ctx.FileName)]) + #10 +
      '```dfm' + #10 + AdjustLineBreaks(TrimRight(Blocks), tlbsLF) + #10 + '```' + #10;
  finally
    Names.Free;
  end;
end;

end.
