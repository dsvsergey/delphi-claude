unit ClaudeCode.ComponentProps;

{ Component <-> text helpers for the form designer tools:
  - DFM text of a component / form resource, and the block of one object in it;
  - setting published properties from JSON through RTTI: nested paths ("Font.Size", or a
    nested JSON object for Font), enums/sets by name, integer identifiers (clRed, crHandPoint),
    component references by name, TStrings as text or an array of lines, events by method name.
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, System.TypInfo, System.JSON;

type
  { Returns the method for an event handler name (the designer creates it when missing). }
  TMethodResolver = reference to function(const Name: string; TypeData: PTypeData): TMethod;
  TMethodNamer = reference to function(const Method: TMethod): string;

  TPropChange = record
    Path: string;
    OldValue: string;
    NewValue: string;
    function ToJson: TJSONObject;
  end;

function ComponentToDfm(C: TComponent): string;
{ A form resource as written by the IDE (with or without the resource header). }
function ResourceToDfm(Stream: TStream): string;
{ The "object/inherited/inline Name: TClass ... end" block of one component, or ''. }
function ExtractDfmObject(const Dfm, Name: string): string;

{ Sets Props on Target. Every property is tried; problems are returned as messages. }
function SetComponentProperties(Root, Target: TComponent; Props: TJSONObject;
  const ResolveMethod: TMethodResolver; const MethodName: TMethodNamer;
  out Changes: TArray<TPropChange>): TArray<string>;

function PropValueText(Instance: TPersistent; PropInfo: PPropInfo; const MethodName: TMethodNamer): string;

implementation

uses
  System.Variants, System.Generics.Collections;

{ TPropChange }

function TPropChange.ToJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('property', Path);
  Result.AddPair('old', OldValue);
  Result.AddPair('new', NewValue);
end;

{ DFM text }

{ UTF-8 text output keeps non-ASCII strings readable instead of #1055#1088 escapes. }
function StreamText(Stream: TMemoryStream): string;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, Stream.Size);
  if Length(Bytes) > 0 then
    Move(Stream.Memory^, Bytes[0], Length(Bytes));
  Result := TEncoding.UTF8.GetString(Bytes);
  if Result.StartsWith(#$FEFF) then
    Delete(Result, 1, 1);
end;

function ComponentToDfm(C: TComponent): string;
var
  Bin, Txt: TMemoryStream;
  Format: TStreamOriginalFormat;
begin
  Bin := TMemoryStream.Create;
  Txt := TMemoryStream.Create;
  try
    Bin.WriteComponent(C);
    Bin.Position := 0;
    Format := sofUTF8Text;
    ObjectBinaryToText(Bin, Txt, Format);
    Result := StreamText(Txt);
  finally
    Txt.Free;
    Bin.Free;
  end;
end;

function ResourceToDfm(Stream: TStream): string;
var
  Txt: TMemoryStream;
  Sig: array[0..3] of Byte;
  Format: TStreamOriginalFormat;
begin
  Txt := TMemoryStream.Create;
  try
    Stream.Position := 0;
    FillChar(Sig, SizeOf(Sig), 0);
    Stream.Read(Sig, SizeOf(Sig));
    Stream.Position := 0;
    Format := sofUTF8Text;
    if (Sig[0] = Ord('T')) and (Sig[1] = Ord('P')) and (Sig[2] = Ord('F')) then
      ObjectBinaryToText(Stream, Txt, Format) // plain binary form data
    else
      ObjectResourceToText(Stream, Txt, Format); // with the RCDATA resource header
    Result := StreamText(Txt);
  finally
    Txt.Free;
  end;
end;

function ExtractDfmObject(const Dfm, Name: string): string;
var
  Lines: TStringList;
  I, J, Indent: Integer;
  S, Head: string;

  function LeadingSpaces(const L: string): Integer;
  begin
    Result := 0;
    while (Result < Length(L)) and (L[Result + 1] = ' ') do
      Inc(Result);
  end;

begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Dfm;
    for I := 0 to Lines.Count - 1 do
    begin
      S := TrimLeft(Lines[I]);
      for Head in ['object ', 'inherited ', 'inline '] do
        if S.StartsWith(Head + Name + ':', True) or SameText(S, Head + Name) then
        begin
          Indent := LeadingSpaces(Lines[I]);
          Result := Lines[I] + sLineBreak;
          for J := I + 1 to Lines.Count - 1 do
          begin
            Result := Result + Lines[J] + sLineBreak;
            if (LeadingSpaces(Lines[J]) = Indent) and SameText(Trim(Lines[J]), 'end') then
              Exit;
          end;
          Exit;
        end;
    end;
  finally
    Lines.Free;
  end;
end;

{ Property values }

function JsonText(V: TJSONValue): string;
begin
  if V is TJSONString then
    Result := TJSONString(V).Value
  else if (V = nil) or (V is TJSONNull) then
    Result := ''
  else
    Result := V.ToJSON;
end;

function PropValueText(Instance: TPersistent; PropInfo: PPropInfo; const MethodName: TMethodNamer): string;
var
  Obj: TObject;
  M: TMethod;
  Ident: string;
  IntToIdentFn: TIntToIdent;
begin
  case PropInfo.PropType^.Kind of
    tkClass:
      begin
        Obj := GetObjectProp(Instance, PropInfo);
        if Obj = nil then
          Result := '(nil)'
        else if Obj is TComponent then
          Result := TComponent(Obj).Name
        else if Obj is TStrings then
          Result := TStrings(Obj).Text
        else
          Result := '(' + Obj.ClassName + ')';
      end;
    tkMethod:
      begin
        M := GetMethodProp(Instance, PropInfo);
        if (M.Code = nil) and (M.Data = nil) then
          Result := ''
        else if Assigned(MethodName) then
          Result := MethodName(M)
        else
          Result := '(handler)';
      end;
    tkInteger:
      begin
        IntToIdentFn := FindIntToIdent(PropInfo.PropType^);
        if Assigned(IntToIdentFn) and IntToIdentFn(GetOrdProp(Instance, PropInfo), Ident) then
          Result := Ident
        else
          Result := IntToStr(GetOrdProp(Instance, PropInfo));
      end;
  else
    try
      Result := VarToStrDef(GetPropValue(Instance, PropInfo, True), '');
    except
      Result := '?';
    end;
  end;
end;

function SetComponentPropertiesOf(Root: TComponent; Target: TPersistent; Props: TJSONObject;
  const ResolveMethod: TMethodResolver; const Prefix: string; var Errors: TList<string>): Boolean; forward;

function SetOne(Root: TComponent; Instance: TPersistent; PropInfo: PPropInfo; Value: TJSONValue;
  const ResolveMethod: TMethodResolver; const Path: string; var Errors: TList<string>): Boolean;
var
  Kind: TTypeKind;
  S: string;
  N: Int64;
  IdentToIntFn: TIdentToInt;
  Ident: Integer;
  Obj: TObject;
  Ref: TComponent;
  Arr: TJSONArray;
  I: Integer;
  F: Double;
  TD: PTypeData;

  function Fail(const Msg: string): Boolean;
  begin
    Errors.Add(Path + ': ' + Msg);
    Result := False;
  end;

begin
  Result := True;
  Kind := PropInfo.PropType^.Kind;
  if (PropInfo.SetProc = nil) and (Kind <> tkClass) then
    Exit(Fail('read-only property'));
  S := JsonText(Value);
  case Kind of
    tkInteger, tkInt64:
      begin
        if Value is TJSONNumber then
          N := TJSONNumber(Value).AsInt64
        else
        begin
          IdentToIntFn := FindIdentToInt(PropInfo.PropType^);
          if Assigned(IdentToIntFn) and IdentToIntFn(S, Ident) then
            N := Ident
          else if not TryStrToInt64(S, N) then
            Exit(Fail('not an integer or a known identifier: ' + S));
        end;
        if Kind = tkInt64 then
          SetInt64Prop(Instance, PropInfo, N)
        else
          SetOrdProp(Instance, PropInfo, Integer(N));
      end;
    tkChar, tkWChar:
      if S = '' then
        SetOrdProp(Instance, PropInfo, 0)
      else
        SetOrdProp(Instance, PropInfo, Ord(S[1]));
    tkEnumeration:
      begin
        if Value is TJSONBool then
          S := BoolToStr(TJSONBool(Value).AsBoolean, True);
        I := GetEnumValue(PropInfo.PropType^, S);
        if I < 0 then
          Exit(Fail('unknown value ' + S));
        SetOrdProp(Instance, PropInfo, I);
      end;
    tkSet:
      begin
        if Value is TJSONArray then
        begin
          S := '';
          for I := 0 to TJSONArray(Value).Count - 1 do
          begin
            if S <> '' then
              S := S + ',';
            S := S + JsonText(TJSONArray(Value).Items[I]);
          end;
        end;
        S := Trim(S);
        if not S.StartsWith('[') then
          S := '[' + S + ']';
        try
          SetSetProp(Instance, PropInfo, S);
        except
          on E: Exception do
            Exit(Fail(E.Message));
        end;
      end;
    tkFloat:
      begin
        if Value is TJSONNumber then
          F := TJSONNumber(Value).AsDouble
        else if not TryStrToFloat(S, F, TFormatSettings.Invariant) then
          Exit(Fail('not a number: ' + S));
        SetFloatProp(Instance, PropInfo, F);
      end;
    tkString, tkLString, tkUString, tkWString:
      SetStrProp(Instance, PropInfo, S);
    tkVariant:
      SetVariantProp(Instance, PropInfo, S);
    tkMethod:
      begin
        if S = '' then
          SetMethodProp(Instance, PropInfo, Default(TMethod))
        else if not Assigned(ResolveMethod) then
          Exit(Fail('events cannot be set here'))
        else
          SetMethodProp(Instance, PropInfo, ResolveMethod(S, GetTypeData(PropInfo.PropType^)));
      end;
    tkClass:
      begin
        Obj := GetObjectProp(Instance, PropInfo);
        TD := GetTypeData(PropInfo.PropType^);
        if (Obj is TStrings) and not (Value is TJSONObject) then
        begin
          // Items, Lines, SQL...: text or an array of lines.
          if Value is TJSONArray then
          begin
            Arr := TJSONArray(Value);
            TStrings(Obj).BeginUpdate;
            try
              TStrings(Obj).Clear;
              for I := 0 to Arr.Count - 1 do
                TStrings(Obj).Add(JsonText(Arr.Items[I]));
            finally
              TStrings(Obj).EndUpdate;
            end;
          end
          else
            TStrings(Obj).Text := S;
        end
        else if Value is TJSONObject then
        begin
          // A nested persistent such as Font or Constraints, or a subcomponent (EditLabel).
          if not (Obj is TPersistent) then
            Exit(Fail('the object is empty'));
          if (Obj is TComponent) and not (csSubComponent in TComponent(Obj).ComponentStyle) then
            Exit(Fail(Format('refers to %s; change that component itself, or pass a name to point elsewhere',
              [TComponent(Obj).Name])));
          Result := SetComponentPropertiesOf(Root, TPersistent(Obj), TJSONObject(Value), ResolveMethod, Path, Errors);
        end
        else if TD.ClassType.InheritsFrom(TComponent) then
        begin
          if S = '' then
            Ref := nil
          else
          begin
            Ref := Root.FindComponent(S);
            if (Ref = nil) and SameText(Root.Name, S) then
              Ref := Root;
            if Ref = nil then
              Exit(Fail('no component named ' + S));
            if not Ref.InheritsFrom(TD.ClassType) then
              Exit(Fail(Format('%s is a %s, expected %s', [S, Ref.ClassName, TD.ClassType.ClassName])));
          end;
          SetObjectProp(Instance, PropInfo, Ref);
        end
        else
          Exit(Fail('set the fields of this object with a JSON object'));
      end;
  else
    Exit(Fail('unsupported property type'));
  end;
end;


function SetPath(Root: TComponent; Target: TPersistent; const Path: string; Value: TJSONValue;
  const ResolveMethod: TMethodResolver; const Prefix: string; var Errors: TList<string>): Boolean;
var
  Parts: TArray<string>;
  Instance: TPersistent;
  PropInfo: PPropInfo;
  Obj: TObject;
  I: Integer;
  Full: string;
begin
  Full := Prefix + Path;
  Parts := Path.Split(['.']);
  Instance := Target;
  for I := 0 to High(Parts) - 1 do
  begin
    PropInfo := GetPropInfo(Instance, Parts[I]);
    if (PropInfo = nil) or (PropInfo.PropType^.Kind <> tkClass) then
    begin
      Errors.Add(Full + ': ' + Parts[I] + ' is not an object property of ' + Instance.ClassName);
      Exit(False);
    end;
    Obj := GetObjectProp(Instance, PropInfo);
    if not (Obj is TPersistent) then
    begin
      Errors.Add(Full + ': ' + Parts[I] + ' is empty');
      Exit(False);
    end;
    Instance := TPersistent(Obj);
  end;
  PropInfo := GetPropInfo(Instance, Parts[High(Parts)]);
  if PropInfo = nil then
  begin
    Errors.Add(Full + ': ' + Instance.ClassName + ' has no published property ' + Parts[High(Parts)]);
    Exit(False);
  end;
  try
    Result := SetOne(Root, Instance, PropInfo, Value, ResolveMethod, Full, Errors);
  except
    on E: Exception do
    begin
      Errors.Add(Full + ': ' + E.Message);
      Result := False;
    end;
  end;
end;

function SetComponentPropertiesOf(Root: TComponent; Target: TPersistent; Props: TJSONObject;
  const ResolveMethod: TMethodResolver; const Prefix: string; var Errors: TList<string>): Boolean;
var
  Pair: TJSONPair;
begin
  Result := True;
  for Pair in Props do
    if not SetPath(Root, Target, Pair.JsonString.Value, Pair.JsonValue, ResolveMethod, Prefix, Errors) then
      Result := False;
end;

{ The value text of Path on Target, for reporting; '' when it cannot be read. }
function PathValueText(Target: TPersistent; const Path: string; const MethodName: TMethodNamer): string;
var
  Parts: TArray<string>;
  Instance: TPersistent;
  PropInfo: PPropInfo;
  Obj: TObject;
  I: Integer;
begin
  Result := '';
  Parts := Path.Split(['.']);
  Instance := Target;
  for I := 0 to High(Parts) - 1 do
  begin
    PropInfo := GetPropInfo(Instance, Parts[I]);
    if (PropInfo = nil) or (PropInfo.PropType^.Kind <> tkClass) then
      Exit;
    Obj := GetObjectProp(Instance, PropInfo);
    if not (Obj is TPersistent) then
      Exit;
    Instance := TPersistent(Obj);
  end;
  PropInfo := GetPropInfo(Instance, Parts[High(Parts)]);
  if PropInfo <> nil then
    Result := PropValueText(Instance, PropInfo, MethodName);
end;

{ Leaf paths of a props object: a nested "Font" object with "Size" gives Font.Size. }
procedure CollectPaths(Props: TJSONObject; const Prefix: string; Paths: TList<string>);
var
  Pair: TJSONPair;
begin
  for Pair in Props do
    if Pair.JsonValue is TJSONObject then
      CollectPaths(TJSONObject(Pair.JsonValue), Prefix + Pair.JsonString.Value + '.', Paths)
    else
      Paths.Add(Prefix + Pair.JsonString.Value);
end;

function SetComponentProperties(Root, Target: TComponent; Props: TJSONObject;
  const ResolveMethod: TMethodResolver; const MethodName: TMethodNamer;
  out Changes: TArray<TPropChange>): TArray<string>;
var
  Errors: TList<string>;
  Paths: TList<string>;
  Olds: TArray<string>;
  I: Integer;
  C: TPropChange;
  List: TList<TPropChange>;
begin
  Errors := TList<string>.Create;
  Paths := TList<string>.Create;
  List := TList<TPropChange>.Create;
  try
    CollectPaths(Props, '', Paths);
    SetLength(Olds, Paths.Count);
    for I := 0 to Paths.Count - 1 do
      Olds[I] := PathValueText(Target, Paths[I], MethodName);
    SetComponentPropertiesOf(Root, Target, Props, ResolveMethod, '', Errors);
    for I := 0 to Paths.Count - 1 do
    begin
      C.Path := Paths[I];
      C.OldValue := Olds[I];
      C.NewValue := PathValueText(Target, Paths[I], MethodName);
      if C.NewValue <> C.OldValue then
        List.Add(C);
    end;
    Changes := List.ToArray;
    Result := Errors.ToArray;
  finally
    List.Free;
    Paths.Free;
    Errors.Free;
  end;
end;

end.
