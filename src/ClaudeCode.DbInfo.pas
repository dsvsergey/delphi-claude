unit ClaudeCode.DbInfo;

{ Helpers for the database tools that need neither the IDE nor FireDAC:
  - FireDAC connections declared in form/data module DFM text (parameters, secrets masked);
  - a check that SQL only reads (one statement, no data or schema changes).
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils, System.Classes;

type
  TDfmConnection = record
    Form: string;            // the form / data module name
    Name: string;            // component name
    ClassName: string;
    Params: TArray<string>;  // Name=Value lines as in the DFM
    ConnectionDefName: string;
    DriverName: string;
    function Param(const Key: string): string;
    { Params with passwords and other secrets replaced by ***. }
    function SafeParams: TArray<string>;
  end;

{ FireDAC connections (TFDConnection and descendants by name) in a text DFM. }
function FindDfmConnections(const Dfm: string): TArray<TDfmConnection>;
{ True when Sql is a single statement that only reads data; Reason says why not. }
function IsReadOnlySql(const Sql: string; out Reason: string): Boolean;
function IsSecretParam(const Key: string): Boolean;

implementation

uses
  System.RegularExpressions, System.Generics.Collections;

function IsSecretParam(const Key: string): Boolean;
var
  K: string;
begin
  K := LowerCase(Trim(Key));
  Result := K.Contains('password') or K.Contains('pwd') or K.Contains('secret') or K.Contains('token') or
    (K = 'apikey') or (K = 'api_key');
end;

function TDfmConnection.Param(const Key: string): string;
var
  S: string;
  P: Integer;
begin
  Result := '';
  for S in Params do
  begin
    P := Pos('=', S);
    if (P > 0) and SameText(Trim(Copy(S, 1, P - 1)), Key) then
      Exit(Copy(S, P + 1, MaxInt));
  end;
end;

function TDfmConnection.SafeParams: TArray<string>;
var
  S: string;
  P: Integer;
begin
  Result := nil;
  for S in Params do
  begin
    P := Pos('=', S);
    if (P > 0) and IsSecretParam(Copy(S, 1, P - 1)) then
      Result := Result + [Copy(S, 1, P) + '***']
    else
      Result := Result + [S];
  end;
end;

{ A DFM string value: 'abc''d' #39 'x' + 'y' -> abc'd'xy }
function DfmString(const S: string): string;
var
  I, J: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '''' then
    begin
      Inc(I);
      while I <= Length(S) do
      begin
        if S[I] = '''' then
        begin
          if (I < Length(S)) and (S[I + 1] = '''') then
          begin
            Result := Result + '''';
            Inc(I, 2);
            Continue;
          end;
          Inc(I);
          Break;
        end;
        Result := Result + S[I];
        Inc(I);
      end;
    end
    else if S[I] = '#' then
    begin
      J := I + 1;
      while (J <= Length(S)) and CharInSet(S[J], ['0'..'9']) do
        Inc(J);
      Result := Result + Char(StrToIntDef(Copy(S, I + 1, J - I - 1), 32));
      I := J;
    end
    else
      Inc(I);
  end;
end;

function FindDfmConnections(const Dfm: string): TArray<TDfmConnection>;
var
  Lines: TStringList;
  I, Depth, StartDepth: Integer;
  T, FormName: string;
  M: TMatch;
  C: TDfmConnection;
  InConn, InParams: Boolean;
  L: TList<TDfmConnection>;
begin
  L := TList<TDfmConnection>.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Dfm;
    Depth := 0;
    StartDepth := -1;
    InConn := False;
    InParams := False;
    FormName := '';
    for I := 0 to Lines.Count - 1 do
    begin
      T := Trim(Lines[I]);
      M := TRegEx.Match(T, '^(object|inherited|inline)\s+(\w+)\s*:\s*(\w+)', [roIgnoreCase]);
      if M.Success then
      begin
        if Depth = 0 then
          FormName := M.Groups[2].Value;
        Inc(Depth);
        if not InConn and M.Groups[3].Value.StartsWith('TFD', True) and
           M.Groups[3].Value.EndsWith('Connection', True) then
        begin
          C := Default(TDfmConnection);
          C.Form := FormName;
          C.Name := M.Groups[2].Value;
          C.ClassName := M.Groups[3].Value;
          InConn := True;
          StartDepth := Depth;
        end;
        Continue;
      end;
      if SameText(T, 'end') then
      begin
        if InConn and (Depth = StartDepth) then
        begin
          L.Add(C);
          InConn := False;
          InParams := False;
        end;
        Dec(Depth);
        Continue;
      end;
      if not InConn or (Depth <> StartDepth) then
        Continue;
      if InParams then
      begin
        if T.EndsWith(')') then
        begin
          InParams := False;
          T := Copy(T, 1, Length(T) - 1);
        end;
        if Trim(T) <> '' then
          C.Params := C.Params + [DfmString(T)];
        Continue;
      end;
      if T.StartsWith('Params.Strings', True) then
      begin
        InParams := not T.EndsWith(')');
        Continue;
      end;
      if T.StartsWith('ConnectionDefName', True) then
        C.ConnectionDefName := DfmString(Copy(T, Pos('=', T) + 1, MaxInt))
      else if T.StartsWith('DriverName', True) then
        C.DriverName := DfmString(Copy(T, Pos('=', T) + 1, MaxInt));
    end;
    Result := L.ToArray;
  finally
    Lines.Free;
    L.Free;
  end;
end;

{ SQL without comments and string literals (they cannot hide statements then). }
function StripSql(const Sql: string): string;
var
  I: Integer;
  Q: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(Sql) do
  begin
    if (Sql[I] = '-') and (I < Length(Sql)) and (Sql[I + 1] = '-') then
    begin
      while (I <= Length(Sql)) and not CharInSet(Sql[I], [#10, #13]) do
        Inc(I);
      Result := Result + ' ';
    end
    else if (Sql[I] = '/') and (I < Length(Sql)) and (Sql[I + 1] = '*') then
    begin
      Inc(I, 2);
      while (I < Length(Sql)) and not ((Sql[I] = '*') and (Sql[I + 1] = '/')) do
        Inc(I);
      Inc(I, 2);
      Result := Result + ' ';
    end
    else if CharInSet(Sql[I], ['''', '"', '`']) then
    begin
      Q := Sql[I];
      Inc(I);
      while (I <= Length(Sql)) and (Sql[I] <> Q) do
        Inc(I);
      Inc(I);
      Result := Result + ' ''s'' ';
    end
    else
    begin
      Result := Result + Sql[I];
      Inc(I);
    end;
  end;
end;

function IsReadOnlySql(const Sql: string; out Reason: string): Boolean;
const
  ALLOWED: array[0..6] of string = ('select', 'with', 'show', 'explain', 'describe', 'desc', 'values');
  WRITES: array[0..17] of string = ('insert', 'update', 'delete', 'merge', 'drop', 'alter', 'create', 'truncate',
    'grant', 'revoke', 'upsert', 'exec', 'execute', 'call', 'attach', 'detach', 'vacuum', 'lock');
var
  S, First, W: string;
  M: TMatch;
begin
  Reason := '';
  S := Trim(StripSql(Sql));
  while S.EndsWith(';') do
    S := Trim(Copy(S, 1, Length(S) - 1));
  if S = '' then
  begin
    Reason := 'empty statement';
    Exit(False);
  end;
  if S.Contains(';') then
  begin
    Reason := 'only one statement is allowed';
    Exit(False);
  end;
  M := TRegEx.Match(S, '^\s*([A-Za-z]+)');
  First := LowerCase(M.Groups[1].Value);
  Result := False;
  for W in ALLOWED do
    if First = W then
      Result := True;
  if (First = 'pragma') and not S.Contains('=') and not S.Contains('(') then
    Result := True; // reading a SQLite pragma
  if not Result then
  begin
    Reason := 'only SELECT/WITH/SHOW/EXPLAIN/DESCRIBE statements are allowed, not ' + UpperCase(First);
    Exit;
  end;
  // A WITH ... DELETE, SELECT ... INTO, or a writing function call.
  for W in WRITES do
    if TRegEx.IsMatch(S, '\b' + W + '\b', [roIgnoreCase]) then
    begin
      Reason := 'the statement contains ' + UpperCase(W);
      Exit(False);
    end;
  if TRegEx.IsMatch(S, '\binto\b', [roIgnoreCase]) then
  begin
    Reason := 'SELECT ... INTO writes data';
    Exit(False);
  end;
  if TRegEx.IsMatch(S, '\bfor\s+update\b', [roIgnoreCase]) then
  begin
    Reason := 'FOR UPDATE takes locks';
    Exit(False);
  end;
end;

end.
