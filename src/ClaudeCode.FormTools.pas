unit ClaudeCode.FormTools;

{ Form designer tools: read the live designer state (DFM text, components, selection),
  change it through the designer (properties, new and deleted components) and take a
  picture of a VCL form. Changes go through the designer so the .dfm, the class
  declaration and the Object Inspector stay in step; nothing is saved automatically. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ToolsAPI, DesignIntf, ClaudeCode.Mcp, ClaudeCode.Compat;

function ToolGetFormComponents(Args: TJSONObject): TToolResult;
function ToolGetSelectedComponents(Args: TJSONObject): TToolResult;
function ToolSetComponentProperties(Args: TJSONObject): TToolResult;
function ToolCreateComponent(Args: TJSONObject): TToolResult;
function ToolDeleteComponent(Args: TJSONObject): TToolResult;
function ToolCaptureForm(Args: TJSONObject): TToolResult;
procedure ToolPasteDfm(Args: TJSONObject; const Done: TToolDone);

{ True when the form designer is the active IDE view. }
function DesignerIsActive: Boolean;
{ The form of the current module (its name and unit); False when the current module has none. }
function CurrentFormInfo(out FormName, FileName: string): Boolean;
{ A request describing the components selected in the active designer, or '' when none. }
function SelectedComponentsPrompt: string;

implementation

uses
  Winapi.Windows, System.IOUtils, System.TypInfo, System.Generics.Collections,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Imaging.pngimage, Vcl.Clipbrd, Vcl.ExtCtrls,
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
  Group: IOTAProjectGroup;
  Info: IOTAModuleInfo;
  I: Integer;

  function InProject(const Project: IOTAProject): Boolean;
  var
    M: Integer;
  begin
    Result := False;
    if Project <> nil then
      for M := 0 to Project.GetModuleCount - 1 do
      begin
        Info := Project.GetModule(M);
        if (Info <> nil) and (Info.FormName <> '') and (SameText(Info.FormName, Spec) or SameText(Info.Name, Spec)) then
          if MakeContext(Info.OpenModule, Ctx) then
            Exit(True);
      end;
  end;

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
  // Modules that are not open yet: of the active project first, then of the rest of the group.
  if InProject(GetActiveProject) then
    Exit(True);
  Group := ModuleServices.MainProjectGroup;
  if Group <> nil then
    for I := 0 to Group.ProjectCount - 1 do
      if (Group.Projects[I] <> GetActiveProject) and InProject(Group.Projects[I]) then
        Exit(True);
  Err := 'No form named ' + Spec;
end;

function CurrentFormInfo(out FormName, FileName: string): Boolean;
var
  Ctx: TFormContext;
begin
  FormName := '';
  FileName := '';
  Result := MakeContext(ModuleServices.CurrentModule, Ctx);
  if Result then
  begin
    FormName := Ctx.Root.Name;
    FileName := Ctx.FileName;
  end;
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

{ pasteDfm }

type
  TOneShot = class(TComponent)
  public
    Proc: TProc;
    procedure Fire(Sender: TObject);
  end;

procedure TOneShot.Fire(Sender: TObject);
var
  P: TProc;
begin
  (Sender as TTimer).Enabled := False;
  P := Proc;
  Proc := nil;
  // Free this owner (and its timer) after the event handler returns.
  TThread.ForceQueue(nil,
    procedure
    begin
      Free;
    end);
  if Assigned(P) then
    P();
end;


type
  { The clipboard's memory-based formats (text, CF_DIB images, files...), put back after we used it. }
  TClipboardBackup = class
  private
    FFormats: TList<Cardinal>;
    FData: TList<TBytes>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Save;
    procedure Restore;
  end;

constructor TClipboardBackup.Create;
begin
  inherited Create;
  FFormats := TList<Cardinal>.Create;
  FData := TList<TBytes>.Create;
end;

destructor TClipboardBackup.Destroy;
begin
  FData.Free;
  FFormats.Free;
  inherited;
end;

procedure TClipboardBackup.Save;
var
  Fmt: Cardinal;
  H: THandle;
  P: Pointer;
  Size: NativeUInt;
  B: TBytes;
begin
  if not OpenClipboard(0) then
    Exit;
  try
    Fmt := EnumClipboardFormats(0);
    while Fmt <> 0 do
    begin
      // GDI handles (CF_BITMAP, CF_ENHMETAFILE...) are not memory; Windows synthesizes them from CF_DIB etc.
      if not (Fmt in [CF_BITMAP, CF_METAFILEPICT, CF_PALETTE, CF_ENHMETAFILE, CF_OWNERDISPLAY,
         CF_DSPBITMAP, CF_DSPMETAFILEPICT, CF_DSPENHMETAFILE]) then
      begin
        H := GetClipboardData(Fmt);
        if H <> 0 then
        begin
          Size := GlobalSize(H);
          P := GlobalLock(H);
          if P <> nil then
          try
            SetLength(B, Size);
            if Size > 0 then
              Move(P^, B[0], Size);
            FFormats.Add(Fmt);
            FData.Add(B);
          finally
            GlobalUnlock(H);
          end;
        end;
      end;
      Fmt := EnumClipboardFormats(Fmt);
    end;
  finally
    CloseClipboard;
  end;
end;

procedure TClipboardBackup.Restore;
var
  I: Integer;
  H: HGLOBAL;
  P: Pointer;
begin
  if not OpenClipboard(0) then
    Exit;
  try
    EmptyClipboard;
    for I := 0 to FFormats.Count - 1 do
    begin
      H := GlobalAlloc(GMEM_MOVEABLE, NativeUInt(Length(FData[I])) + 1);
      if H = 0 then
        Continue;
      P := GlobalLock(H);
      if Length(FData[I]) > 0 then
        Move(FData[I][0], P^, Length(FData[I]));
      GlobalUnlock(H);
      if SetClipboardData(FFormats[I], H) = 0 then
        GlobalFree(H);
    end;
  finally
    CloseClipboard;
  end;
end;

{ Syntax check of DFM text with one or more top-level objects: wrapped in a dummy root and
  converted to binary, which reports the line of the first error. }
function CheckDfmSyntax(const Dfm: string; out Err: string): Boolean;
var
  Src: TStringStream;
  Dst: TMemoryStream;
begin
  Err := '';
  Src := TStringStream.Create('object ClaudeCheckRoot: TComponent'#13#10 + Dfm + #13#10'end'#13#10, TEncoding.UTF8);
  Dst := TMemoryStream.Create;
  try
    try
      ObjectTextToBinary(Src, Dst);
      Result := True;
    except
      on E: Exception do
      begin
        // Line numbers count the wrapper line.
        Err := E.Message + ' (line numbers include one added line at the top)';
        Result := False;
      end;
    end;
  finally
    Dst.Free;
    Src.Free;
  end;
end;

function TopLevelObjectCount(const Dfm: string): Integer;
var
  L: TStringList;
  S: string;
  Depth: Integer;
  T: string;
begin
  Result := 0;
  Depth := 0;
  L := TStringList.Create;
  try
    L.Text := Dfm;
    for S in L do
    begin
      T := LowerCase(Trim(S));
      if T.StartsWith('object ') or T.StartsWith('inherited ') or T.StartsWith('inline ') then
      begin
        if Depth = 0 then
          Inc(Result);
        Inc(Depth);
      end
      else if (T = 'end') and (Depth > 0) then
        Dec(Depth);
    end;
  finally
    L.Free;
  end;
end;

{ Runs Proc once after Ms milliseconds, from the main message loop. }
procedure RunLater(Ms: Cardinal; const Proc: TProc);
var
  Shot: TOneShot;
  Timer: TTimer;
begin
  Shot := TOneShot.Create(nil);
  Shot.Proc := Proc;
  Timer := TTimer.Create(Shot);
  Timer.Interval := Ms;
  Timer.OnTimer := Shot.Fire;
  Timer.Enabled := True;
end;

procedure PasteNow(const FormSpec, ParentArg, Dfm: string; TopLevel, Attempt: Integer; const Done: TToolDone);
var
  Ctx: TFormContext;
  Err, AllDfm, Blocks, Step: string;
  ParentComp, C: TComponent;
  Before: TDictionary<TComponent, Boolean>;
  Created: TJSONArray;
  Backup: TClipboardBackup;
  EditHandler: IEditHandler;
  I: Integer;
  Obj: TJSONObject;
begin
  // The form may have been closed meanwhile: look it up again.
  if not FindForm(FormSpec, Ctx, Err) or (Ctx.Designer = nil) then
  begin
    Done(Fail('The form is no longer open in the designer: ' + Err));
    Exit;
  end;
  ParentComp := Ctx.Find(ParentArg);
  if ParentComp = nil then
  begin
    Done(Fail('No parent component named ' + ParentArg + ' on ' + Ctx.Root.Name));
    Exit;
  end;
  Before := TDictionary<TComponent, Boolean>.Create;
  Backup := TClipboardBackup.Create;
  try
    for I := 0 to Ctx.Root.ComponentCount - 1 do
      Before.Add(Ctx.Root.Components[I], True);
    Step := 'select';
    try
      // Showing an already loaded form makes its designer the active one (what Edit > Paste works on).
      Ctx.Module.Show;
      Ctx.Editor.Show;
      Ctx.Designer.SelectComponent(ParentComp);
      Backup.Save;
      try
        Step := 'clipboard';
        Clipboard.AsText := Dfm;
        Step := 'canPaste';
        if not Ctx.Designer.CanPaste then
        begin
          Done(Fail('The designer cannot paste into ' + ParentComp.Name + ' (not a container?)'));
          Exit;
        end;
        Step := 'paste';
        // The path of Edit > Paste in the IDE.
        if Supports(Ctx.Designer, IEditHandler, EditHandler) then
          EditHandler.EditAction(eaPaste)
        else
          Ctx.Designer.PasteSelection;
      finally
        Backup.Restore;
      end;
    except
      on E: Exception do
      begin
        // The first paste into a freshly opened designer fails inside designide; the IDE is ready
        // after it has been back in its message loop once, so try again from there.
        if (Step = 'paste') and (Attempt < 4) and (Ctx.Root.ComponentCount = Before.Count) then
        begin
          Log(Format('pasteDfm: attempt %d failed (%s), retrying', [Attempt, E.Message]));
          RunLater(400,
            procedure
            begin
              PasteNow(FormSpec, ParentArg, Dfm, TopLevel, Attempt + 1, Done);
            end);
          Exit;
        end;
        Done(Fail(Format('Pasting failed (%s): %s: %s', [Step, E.ClassName, E.Message])));
        Exit;
      end;
    end;

    Created := TJSONArray.Create;
    Blocks := '';
    AllDfm := Ctx.Dfm;
    for I := 0 to Ctx.Root.ComponentCount - 1 do
    begin
      C := Ctx.Root.Components[I];
      if Before.ContainsKey(C) then
        Continue;
      Created.Add(ComponentJson(C));
      // DFM of the pasted top-level components (their children are inside).
      if not (C is TControl) or (TControl(C).Parent = nil) or Before.ContainsKey(TControl(C).Parent) or
         (TControl(C).Parent = Ctx.Root) then
        Blocks := Blocks + ExtractDfmObject(AllDfm, C.Name);
    end;
    if Created.Count = 0 then
    begin
      Created.Free;
      Done(Fail('The designer did not create any component. Check that the classes are registered in the IDE ' +
        '(their design-time packages installed) and fit this parent.'));
      Exit;
    end;
    Ctx.Modified;
    Obj := TJSONObject.Create;
    Obj.AddPair('form', Ctx.Root.Name);
    Obj.AddPair('parent', ParentComp.Name);
    Obj.AddPair('created', Created);
    Obj.AddPair('topLevelObjectsInDfm', TJSONNumber.Create(TopLevel));
    Obj.AddPair('dfm', Blocks);
    Obj.AddPair('hint', 'Names that already existed were changed by the designer, and event handlers that do ' +
      'not exist in the unit are dropped (set them with setComponentProperties); see "created" and "dfm". ' +
      'Check the layout with captureForm. The form is not saved.');
    Done(TToolResult.Json(Obj));
  finally
    Backup.Free;
    Before.Free;
  end;
end;

procedure ToolPasteDfm(Args: TJSONObject; const Done: TToolDone);
var
  Ctx: TFormContext;
  Err, Dfm, ParentArg, FormSpec: string;
  TopLevel: Integer;
begin
  FormSpec := JsonStr(Args, 'form');
  if not FindForm(FormSpec, Ctx, Err) then
  begin
    Done(Fail(Err));
    Exit;
  end;
  if Ctx.Designer = nil then
  begin
    Done(Fail('The form has no designer; open it in the IDE first'));
    Exit;
  end;
  Dfm := Trim(JsonStr(Args, 'dfm'));
  if Dfm = '' then
  begin
    Done(Fail('"dfm" is required: one or more "object Name: TClass ... end" blocks'));
    Exit;
  end;
  if not CheckDfmSyntax(Dfm, Err) then
  begin
    Done(Fail('The DFM text is not valid: ' + Err));
    Exit;
  end;
  TopLevel := TopLevelObjectCount(Dfm);
  ParentArg := JsonStr(Args, 'parent');
  if Ctx.Find(ParentArg) = nil then
  begin
    Done(Fail('No parent component named ' + ParentArg + ' on ' + Ctx.Root.Name));
    Exit;
  end;
  // The designer pastes into the active form. It becomes the active one only after the IDE has
  // processed its messages and idle updates, so the paste runs a moment later (pasting right
  // after opening a form fails inside the designer).
  FormSpec := Ctx.Root.Name;
  if Ctx.FileName <> '' then
    FormSpec := Ctx.FileName;
  Ctx.Module.Show;
  Ctx.Editor.Show;
  RunLater(250,
    procedure
    begin
      PasteNow(FormSpec, ParentArg, Dfm, TopLevel, 1, Done);
    end);
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
