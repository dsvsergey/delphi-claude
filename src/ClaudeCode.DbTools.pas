unit ClaudeCode.DbTools;

{ Database tools for Claude: the FireDAC connections of the project's forms and data modules,
  the schema behind them and read-only queries. The component on the form is never touched:
  a private connection with the same parameters is opened in a background thread. FireDAC is
  used through RTTI (its classes are registered by the IDE's FireDAC design packages), so this
  package does not depend on FireDAC at compile time. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ClaudeCode.Mcp, ClaudeCode.DbInfo;

type
  TDbConnectionSpec = record
    Title: string;      // Form.Component, for messages
    Params: TArray<string>;
    ConnectionDefName: string;
    DriverName: string;
  end;

function ToolListConnections(Args: TJSONObject): TToolResult;
{ Resolves "connection" (Form.Component or Component; default the only/first one) on the main thread. }
function ResolveConnection(Args: TJSONObject; out Spec: TDbConnectionSpec; out Err: string): Boolean;
{ Background thread work. }
function DatabaseSchemaText(const Spec: TDbConnectionSpec; const Table: string): string;
function RunReadOnlyQuery(const Spec: TDbConnectionSpec; const Sql: string; MaxRows: Integer): string;

implementation

uses
  System.TypInfo, System.Rtti, System.IOUtils, System.Generics.Collections, System.Math, System.StrUtils, Data.DB,
  ToolsAPI, ClaudeCode.Utils, ClaudeCode.IdeBackend;

type
  TFoundConnection = record
    Conn: TDfmConnection;
    ProjectDir: string;
    DfmFile: string;
  end;

function ProjectConnections: TArray<TFoundConnection>;
var
  G: IOTAProjectGroup;
  P: IOTAProject;
  MI: IOTAModuleInfo;
  I, J: Integer;
  Dfm, Text: string;
  C: TDfmConnection;
  F: TFoundConnection;
  Seen: TDictionary<string, Boolean>;
begin
  Result := nil;
  G := (BorlandIDEServices as IOTAModuleServices).MainProjectGroup;
  if G = nil then
    Exit;
  Seen := TDictionary<string, Boolean>.Create;
  try
    for I := 0 to G.ProjectCount - 1 do
    begin
      P := G.Projects[I];
      for J := 0 to P.GetModuleCount - 1 do
      begin
        MI := P.GetModule(J);
        if (MI = nil) or (MI.FormName = '') then
          Continue;
        Dfm := ChangeFileExt(MI.FileName, '.dfm');
        if not FileExists(Dfm) then
          Dfm := ChangeFileExt(MI.FileName, '.fmx');
        if Seen.ContainsKey(AnsiLowerCase(Dfm)) or not ReadSourceText(Dfm, Text) then
          Continue;
        Seen.Add(AnsiLowerCase(Dfm), True);
        for C in FindDfmConnections(Text) do
        begin
          F.Conn := C;
          F.ProjectDir := ExtractFilePath(P.FileName);
          F.DfmFile := Dfm;
          Result := Result + [F];
        end;
      end;
    end;
  finally
    Seen.Free;
  end;
end;

function ToolListConnections(Args: TJSONObject): TToolResult;
var
  Arr: TJSONArray;
  F: TFoundConnection;
  O: TJSONObject;
  S: string;
  Params: TJSONArray;
begin
  Arr := TJSONArray.Create;
  for F in ProjectConnections do
  begin
    O := TJSONObject.Create;
    O.AddPair('connection', F.Conn.Form + '.' + F.Conn.Name);
    O.AddPair('class', F.Conn.ClassName);
    O.AddPair('file', F.DfmFile);
    if F.Conn.ConnectionDefName <> '' then
      O.AddPair('connectionDefName', F.Conn.ConnectionDefName);
    if F.Conn.DriverName <> '' then
      O.AddPair('driverName', F.Conn.DriverName);
    Params := TJSONArray.Create;
    for S in F.Conn.SafeParams do
      Params.Add(S);
    O.AddPair('params', Params);
    Arr.Add(O);
  end;
  if Arr.Count = 0 then
  begin
    Arr.Free;
    Exit(TToolResult.Ok(['No FireDAC connections (TFDConnection) on the forms and data modules of the project ' +
      'group. getDatabaseSchema and runQuery can also take "params" (FireDAC connection parameters) directly.']));
  end;
  Result := TToolResult.Json(TJSONObject.Create.AddPair('connections', Arr));
end;

{ A file database given relative to the project (Database=orders.db) is found from the IDE too. }
function AbsoluteDatabase(const Params: TArray<string>; const ProjectDir: string): TArray<string>;
var
  I, P: Integer;
  Value, Full: string;
begin
  Result := Copy(Params);
  for I := 0 to High(Result) do
  begin
    P := Pos('=', Result[I]);
    if (P = 0) or not SameText(Trim(Copy(Result[I], 1, P - 1)), 'Database') then
      Continue;
    Value := Copy(Result[I], P + 1, MaxInt);
    if (Value = '') or TPath.IsPathRooted(Value) or Value.Contains(':') and (Pos(':', Value) > 2) then
      Continue;
    Full := TPath.GetFullPath(TPath.Combine(ProjectDir, Value));
    if FileExists(Full) then
      Result[I] := Copy(Result[I], 1, P) + Full;
  end;
end;

function ResolveConnection(Args: TJSONObject; out Spec: TDbConnectionSpec; out Err: string): Boolean;
var
  Want: string;
  All: TArray<TFoundConnection>;
  F: TFoundConnection;
  V, Item: TJSONValue;
begin
  Spec := Default(TDbConnectionSpec);
  Err := '';
  // Explicit parameters win.
  V := Args.GetValue('params');
  if V is TJSONArray then
  begin
    for Item in TJSONArray(V) do
      Spec.Params := Spec.Params + [Item.Value];
    Spec.ConnectionDefName := JsonStr(Args, 'connectionDefName');
    Spec.Title := 'parameters';
    Exit(True);
  end;
  if JsonStr(Args, 'connectionDefName') <> '' then
  begin
    Spec.ConnectionDefName := JsonStr(Args, 'connectionDefName');
    Spec.Title := Spec.ConnectionDefName;
    Exit(True);
  end;
  All := ProjectConnections;
  if Length(All) = 0 then
  begin
    Err := 'No FireDAC connection on the project''s forms; pass "params" or "connectionDefName"';
    Exit(False);
  end;
  Want := JsonStr(Args, 'connection');
  for F in All do
    if (Want = '') or SameText(Want, F.Conn.Name) or SameText(Want, F.Conn.Form + '.' + F.Conn.Name) then
    begin
      Spec.Title := F.Conn.Form + '.' + F.Conn.Name;
      Spec.Params := AbsoluteDatabase(F.Conn.Params, F.ProjectDir);
      Spec.ConnectionDefName := F.Conn.ConnectionDefName;
      Spec.DriverName := F.Conn.DriverName;
      Exit(True);
    end;
  Err := 'No connection named ' + Want + ' (see listConnections)';
  Result := False;
end;

{ FireDAC through RTTI }

function NewComponent(const ClassName: string): TComponent;
var
  C: TPersistentClass;
begin
  C := GetClass(ClassName);
  if (C = nil) or not C.InheritsFrom(TComponent) then
    raise Exception.Create(ClassName + ' is not available: FireDAC is not installed in this IDE');
  Result := TComponentClass(C).Create(nil);
end;

procedure CallMethod(Obj: TObject; const Name: string);
var
  Ctx: TRttiContext;
  M: TRttiMethod;
begin
  M := Ctx.GetType(Obj.ClassType).GetMethod(Name);
  if M = nil then
    raise Exception.Create('No method ' + Name);
  M.Invoke(Obj, []);
end;

function OpenConnection(const Spec: TDbConnectionSpec): TCustomConnection;
var
  C: TComponent;
  Opts: TObject;
begin
  C := NewComponent('TFDConnection');
  try
    if Spec.ConnectionDefName <> '' then
      SetStrProp(C, 'ConnectionDefName', Spec.ConnectionDefName);
    if Spec.DriverName <> '' then
      SetStrProp(C, 'DriverName', Spec.DriverName);
    if Length(Spec.Params) > 0 then
      (GetObjectProp(C, 'Params') as TStrings).Text := string.Join(sLineBreak, Spec.Params);
    SetOrdProp(C, 'LoginPrompt', 0);
    // No wait cursor or dialogs from a background thread.
    Opts := GetObjectProp(C, 'ResourceOptions');
    if Opts <> nil then
      SetOrdProp(Opts, 'SilentMode', 1);
    (C as TCustomConnection).Connected := True;
    Result := C as TCustomConnection;
  except
    C.Free;
    raise;
  end;
end;

function MetaQuery(Conn: TCustomConnection; const Kind, ObjectName, BaseObjectName: string): TDataSet;
var
  Q: TComponent;
begin
  Q := NewComponent('TFDMetaInfoQuery');
  try
    SetObjectProp(Q, 'Connection', Conn);
    SetEnumProp(Q, 'MetaInfoKind', Kind);
    if ObjectName <> '' then
      SetStrProp(Q, 'ObjectName', ObjectName);
    if BaseObjectName <> '' then
      SetStrProp(Q, 'BaseObjectName', BaseObjectName);
    (Q as TDataSet).Open;
    Result := Q as TDataSet;
  except
    Q.Free;
    raise;
  end;
end;

function FieldText(DS: TDataSet; const Name: string): string;
var
  F: TField;
begin
  F := DS.FindField(Name);
  if (F = nil) or F.IsNull then
    Result := ''
  else
    Result := F.AsString;
end;

function ColumnsText(Conn: TCustomConnection; const Table: string): string;
const
  ATTR_ALLOW_NULL = 1 shl 1; // TFDDataAttribute: caSearchable, caAllowNull, caFixedLen, caBlobData,
  ATTR_AUTO_INC = 1 shl 5;   // caReadOnly, caAutoInc, caROWID, caDefault, ...
  ATTR_DEFAULT = 1 shl 7;
var
  DS: TDataSet;
  Parts, Keys: TArray<string>;
  S, Typ: string;
  Attrs, Len, Attempt: Integer;
begin
  Keys := nil;
  // The table goes into BaseObjectName for key fields; some drivers take it as ObjectName.
  for Attempt in [0, 1] do
  begin
    try
      if Attempt = 0 then
        DS := MetaQuery(Conn, 'mkPrimaryKeyFields', '', Table)
      else
        DS := MetaQuery(Conn, 'mkPrimaryKeyFields', Table, '');
      try
        while not DS.Eof do
        begin
          Keys := Keys + [LowerCase(FieldText(DS, 'COLUMN_NAME'))];
          DS.Next;
        end;
      finally
        DS.Free;
      end;
    except
      // Not every driver reports keys.
    end;
    if Keys <> nil then
      Break;
  end;
  Parts := nil;
  DS := MetaQuery(Conn, 'mkTableFields', Table, '');
  try
    while not DS.Eof do
    begin
      S := FieldText(DS, 'COLUMN_NAME');
      Typ := FieldText(DS, 'COLUMN_TYPENAME');
      Len := StrToIntDef(FieldText(DS, 'COLUMN_LENGTH'), 0);
      if (Len > 0) and (Len < 100000) and (Pos('(', Typ) = 0) and
         (Typ.ToLower.Contains('char') or Typ.ToLower.Contains('binary')) then
        Typ := Format('%s(%d)', [Typ, Len]);
      S := S + ' ' + Typ;
      if MatchStr(LowerCase(FieldText(DS, 'COLUMN_NAME')), Keys) then
        S := S + ' PK';
      Attrs := StrToIntDef(FieldText(DS, 'COLUMN_ATTRIBUTES'), 0);
      if Attrs and ATTR_AUTO_INC <> 0 then
        S := S + ' autoinc';
      if Attrs and ATTR_ALLOW_NULL = 0 then
        S := S + ' not null';
      if Attrs and ATTR_DEFAULT <> 0 then
        S := S + ' default';
      Parts := Parts + [S];
      DS.Next;
    end;
  finally
    DS.Free;
  end;
  Result := string.Join(', ', Parts);
end;

function ForeignKeysText(Conn: TCustomConnection; const Table: string): string;
var
  DS, F: TDataSet;
  Name, Ref, Cols, RefCols: string;
  Parts: TArray<string>;
begin
  Parts := nil;
  try
    DS := MetaQuery(Conn, 'mkForeignKeys', Table, '');
    try
      while not DS.Eof do
      begin
        Name := FieldText(DS, 'FKEY_NAME');
        Ref := FieldText(DS, 'PKEY_TABLE_NAME');
        Cols := '';
        RefCols := '';
        try
          F := MetaQuery(Conn, 'mkForeignKeyFields', Name, Table);
          try
            while not F.Eof do
            begin
              Cols := Cols + IfThen(Cols <> '', ',', '') + FieldText(F, 'COLUMN_NAME');
              RefCols := RefCols + IfThen(RefCols <> '', ',', '') + FieldText(F, 'PKEY_COLUMN_NAME');
              F.Next;
            end;
          finally
            F.Free;
          end;
        except
        end;
        Parts := Parts + [Format('%s -> %s(%s)', [Cols, Ref, RefCols])];
        DS.Next;
      end;
    finally
      DS.Free;
    end;
  except
  end;
  Result := string.Join('; ', Parts);
end;

function DatabaseSchemaText(const Spec: TDbConnectionSpec; const Table: string): string;
const
  MAX_DETAILED = 60;
var
  Conn: TCustomConnection;
  DS: TDataSet;
  Tables: TArray<string>;
  T, FK: string;
  SB: TStringBuilder;
  I: Integer;
begin
  Conn := OpenConnection(Spec);
  SB := TStringBuilder.Create;
  try
    SB.AppendFormat('Connection %s, driver %s', [Spec.Title, GetStrProp(Conn, 'DriverName')]).AppendLine;
    if Table <> '' then
      Tables := [Table]
    else
    begin
      DS := MetaQuery(Conn, 'mkTables', '', '');
      try
        while not DS.Eof do
        begin
          Tables := Tables + [FieldText(DS, 'TABLE_NAME')];
          DS.Next;
        end;
      finally
        DS.Free;
      end;
    end;
    SB.AppendFormat('%d table(s)', [Length(Tables)]).AppendLine;
    for I := 0 to High(Tables) do
    begin
      T := Tables[I];
      if I >= MAX_DETAILED then
      begin
        SB.AppendLine.Append('Other tables (pass "table" for their columns): ')
          .Append(string.Join(', ', Copy(Tables, I, MaxInt))).AppendLine;
        Break;
      end;
      SB.AppendLine.Append(T).Append(': ').Append(ColumnsText(Conn, T)).AppendLine;
      FK := ForeignKeysText(Conn, T);
      if FK <> '' then
        SB.Append('  foreign keys: ').Append(FK).AppendLine;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
    Conn.Free;
  end;
end;

function Cell(F: TField): string;
begin
  if F.IsNull then
    Exit('NULL');
  if F.IsBlob and not (F.DataType in [ftMemo, ftWideMemo, ftFmtMemo]) then
    Exit(Format('<blob %d bytes>', [F.DataSize]));
  Result := StringReplace(StringReplace(F.AsString, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, '|', '\|', [rfReplaceAll]);
  if Length(Result) > 120 then
    Result := Copy(Result, 1, 120) + '...';
end;

function RunReadOnlyQuery(const Spec: TDbConnectionSpec; const Sql: string; MaxRows: Integer): string;
var
  Conn: TCustomConnection;
  Q: TComponent;
  DS: TDataSet;
  SB: TStringBuilder;
  I, Rows: Integer;
  Opts: TObject;
  More: Boolean;
begin
  Conn := OpenConnection(Spec);
  SB := TStringBuilder.Create;
  Q := nil;
  try
    // Belt and braces: the statement was checked to be a read, and it runs in a transaction
    // that is rolled back.
    CallMethod(Conn, 'StartTransaction');
    try
      Q := NewComponent('TFDQuery');
      SetObjectProp(Q, 'Connection', Conn);
      Opts := GetObjectProp(Q, 'UpdateOptions');
      if Opts <> nil then
        SetOrdProp(Opts, 'ReadOnly', 1);
      (GetObjectProp(Q, 'SQL') as TStrings).Text := Sql;
      DS := Q as TDataSet;
      DS.Open;
      SB.Append('|');
      for I := 0 to DS.FieldCount - 1 do
        SB.Append(' ').Append(DS.Fields[I].FieldName).Append(' |');
      SB.AppendLine.Append('|');
      for I := 0 to DS.FieldCount - 1 do
        SB.Append(' --- |');
      SB.AppendLine;
      Rows := 0;
      while not DS.Eof and (Rows < MaxRows) do
      begin
        SB.Append('|');
        for I := 0 to DS.FieldCount - 1 do
          SB.Append(' ').Append(Cell(DS.Fields[I])).Append(' |');
        SB.AppendLine;
        Inc(Rows);
        DS.Next;
      end;
      More := not DS.Eof;
      DS.Close;
      SB.AppendLine.AppendFormat('%d row(s)%s', [Rows, IfThen(More, Format(' shown; more rows exist (maxRows=%d)',
        [MaxRows]), '')]);
    finally
      CallMethod(Conn, 'Rollback');
    end;
    Result := SB.ToString;
  finally
    Q.Free;
    SB.Free;
    Conn.Free;
  end;
end;

end.
