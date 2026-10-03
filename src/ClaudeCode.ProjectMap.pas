unit ClaudeCode.ProjectMap;

{ The unit dependency graph of a project: which units use which (interface/implementation),
  sizes, fan-in/fan-out and cycles (strongly connected components over all uses: units that
  depend on each other through implementation uses - legal, but they can only be understood,
  tested and changed together). No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections, ClaudeCode.PascalIndex;

type
  TMapSource = record
    FileName: string;
    Text: string;
    FormKind: string; // form, dataModule, frame or ''
  end;

  TMapUnit = record
    Name: string;
    FileName: string;
    Kind: string;      // unit, program, library, package
    FormKind: string;
    Lines: Integer;
    Types: Integer;
    Routines: Integer;
    IntfUses: TArray<string>; // only units of the map
    ImplUses: TArray<string>;
    ExternalUses: Integer;    // RTL/VCL/library units used
    UsedBy: TArray<string>;
    Cycle: Integer;           // index into TProjectMap.Cycles, -1 when in none
  end;

  TProjectMap = record
    Units: TArray<TMapUnit>;
    Cycles: TArray<TArray<string>>;
    function IndexOf(const Name: string): Integer;
    function ToJson: TJSONObject;
    { Summary for Claude: biggest units, most used, most dependent, cycles. }
    function SummaryText(Top: Integer): string;
    function UnitText(const Name: string): string;
  end;

function BuildProjectMap(const Sources: TArray<TMapSource>): TProjectMap;

implementation

uses
  System.Math, System.Generics.Defaults;

function TProjectMap.IndexOf(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Units) do
    if SameText(Units[I].Name, Name) then
      Exit(I);
  Result := -1;
end;

function StrArray(const A: TArray<string>): TJSONArray;
var
  S: string;
begin
  Result := TJSONArray.Create;
  for S in A do
    Result.Add(S);
end;

function TProjectMap.ToJson: TJSONObject;
var
  Arr, C: TJSONArray;
  U: TMapUnit;
  O: TJSONObject;
  Cyc: TArray<string>;
begin
  Result := TJSONObject.Create;
  Arr := TJSONArray.Create;
  for U in Units do
  begin
    O := TJSONObject.Create;
    O.AddPair('name', U.Name);
    O.AddPair('file', U.FileName);
    O.AddPair('kind', U.Kind);
    if U.FormKind <> '' then
      O.AddPair('form', U.FormKind);
    O.AddPair('lines', TJSONNumber.Create(U.Lines));
    O.AddPair('types', TJSONNumber.Create(U.Types));
    O.AddPair('routines', TJSONNumber.Create(U.Routines));
    O.AddPair('intf', StrArray(U.IntfUses));
    O.AddPair('impl', StrArray(U.ImplUses));
    O.AddPair('usedBy', StrArray(U.UsedBy));
    O.AddPair('external', TJSONNumber.Create(U.ExternalUses));
    O.AddPair('cycle', TJSONNumber.Create(U.Cycle));
    Arr.Add(O);
  end;
  Result.AddPair('units', Arr);
  C := TJSONArray.Create;
  for Cyc in Cycles do
    C.Add(StrArray(Cyc));
  Result.AddPair('cycles', C);
end;

function TProjectMap.SummaryText(Top: Integer): string;
var
  SB: TStringBuilder;
  Order: TList<Integer>;
  I, TotalLines: Integer;
  Cyc: TArray<string>;
  LU: TArray<TMapUnit>; // record methods cannot capture Self in anonymous methods

  procedure Ranked(const Caption: string; const Value: TFunc<Integer, Integer>);
  var
    K, N: Integer;
  begin
    Order.Clear;
    for K := 0 to High(Units) do
      Order.Add(K);
    Order.Sort(TComparer<Integer>.Construct(
      function(const A, B: Integer): Integer
      begin
        Result := Value(B) - Value(A);
      end));
    SB.AppendLine.Append(Caption).AppendLine;
    N := 0;
    for K in Order do
    begin
      if (N >= Top) or (Value(K) <= 0) then
        Break;
      SB.AppendFormat('  %-40s %d', [Units[K].Name, Value(K)]).AppendLine;
      Inc(N);
    end;
  end;

begin
  LU := Units;
  SB := TStringBuilder.Create;
  Order := TList<Integer>.Create;
  try
    TotalLines := 0;
    for I := 0 to High(Units) do
      Inc(TotalLines, Units[I].Lines);
    SB.AppendFormat('%d units, %d lines, %d cycle(s) of mutually dependent units', [Length(Units), TotalLines,
      Length(Cycles)]).AppendLine;
    Ranked('Largest units (lines):',
      function(K: Integer): Integer begin Result := LU[K].Lines; end);
    Ranked('Most used (used by N project units):',
      function(K: Integer): Integer begin Result := Length(LU[K].UsedBy); end);
    Ranked('Most dependent (uses N project units):',
      function(K: Integer): Integer begin Result := Length(LU[K].IntfUses) + Length(LU[K].ImplUses); end);
    if Length(Cycles) > 0 then
    begin
      SB.AppendLine.Append('Cycles (each group can only be built, tested and changed together):').AppendLine;
      for Cyc in Cycles do
        SB.Append('  ').Append(string.Join(' <-> ', Cyc)).AppendLine;
    end;
    Result := SB.ToString;
  finally
    Order.Free;
    SB.Free;
  end;
end;

function TProjectMap.UnitText(const Name: string): string;
var
  I: Integer;
  U: TMapUnit;
begin
  I := IndexOf(Name);
  if I < 0 then
    Exit('Unit ' + Name + ' is not part of the project map');
  U := Units[I];
  Result := Format('%s %s (%s): %d lines, %d types, %d routines', [U.Kind, U.Name, U.FileName, U.Lines, U.Types,
    U.Routines]) + #10;
  if U.FormKind <> '' then
    Result := Result + 'Designer: ' + U.FormKind + #10;
  Result := Result + 'Uses in interface: ' + string.Join(', ', U.IntfUses) + #10 +
    'Uses in implementation: ' + string.Join(', ', U.ImplUses) + #10 +
    Format('Library/RTL units used: %d', [U.ExternalUses]) + #10 +
    'Used by: ' + string.Join(', ', U.UsedBy) + #10;
  if U.Cycle >= 0 then
    Result := Result + 'In a cycle with: ' + string.Join(', ', Cycles[U.Cycle]) + #10;
end;

{ Tarjan's strongly connected components; Adj holds indexes. }
function StronglyConnected(const Adj: TArray<TArray<Integer>>): TArray<TArray<Integer>>;
var
  Index, Low: TArray<Integer>;
  OnStack: TArray<Boolean>;
  Stack: TList<Integer>;
  Counter: Integer;
  L: TList<TArray<Integer>>;

  procedure Visit(V: Integer);
  var
    W: Integer;
    Comp: TArray<Integer>;
  begin
    Index[V] := Counter;
    Low[V] := Counter;
    Inc(Counter);
    Stack.Add(V);
    OnStack[V] := True;
    for W in Adj[V] do
      if Index[W] < 0 then
      begin
        Visit(W);
        Low[V] := Min(Low[V], Low[W]);
      end
      else if OnStack[W] then
        Low[V] := Min(Low[V], Index[W]);
    if Low[V] = Index[V] then
    begin
      Comp := nil;
      repeat
        W := Stack.Last;
        Stack.Delete(Stack.Count - 1);
        OnStack[W] := False;
        Comp := Comp + [W];
      until W = V;
      if Length(Comp) > 1 then
        L.Add(Comp);
    end;
  end;

var
  I: Integer;
begin
  SetLength(Index, Length(Adj));
  SetLength(Low, Length(Adj));
  SetLength(OnStack, Length(Adj));
  for I := 0 to High(Index) do
    Index[I] := -1;
  Counter := 0;
  Stack := TList<Integer>.Create;
  L := TList<TArray<Integer>>.Create;
  try
    for I := 0 to High(Adj) do
      if Index[I] < 0 then
        Visit(I);
    Result := L.ToArray;
  finally
    L.Free;
    Stack.Free;
  end;
end;

function BuildProjectMap(const Sources: TArray<TMapSource>): TProjectMap;
var
  I, K, J: Integer;
  Infos: TArray<TPasUnitInfo>;
  Names: TDictionary<string, Integer>;
  U: TMapUnit;
  D: TPasDecl;
  E: TUsesEntry;
  Adj: TArray<TArray<Integer>>;
  Comps: TArray<TArray<Integer>>;
  Cyc: TArray<string>;
  UsedBy: TArray<TList<string>>;
begin
  Result := Default(TProjectMap);
  SetLength(Infos, Length(Sources));
  Names := TDictionary<string, Integer>.Create;
  try
    // One node per unit name (a unit listed twice is read once).
    for I := 0 to High(Sources) do
    begin
      Infos[I] := ParsePascalUnit(Sources[I].Text);
      if Infos[I].UnitName = '' then
        Infos[I].UnitName := ChangeFileExt(ExtractFileName(Sources[I].FileName), '');
      if Names.ContainsKey(LowerCase(Infos[I].UnitName)) then
        Continue;
      U := Default(TMapUnit);
      U.Name := Infos[I].UnitName;
      U.FileName := Sources[I].FileName;
      U.Kind := Infos[I].UnitKind;
      if U.Kind = '' then
        U.Kind := 'unit';
      U.FormKind := Sources[I].FormKind;
      U.Lines := Infos[I].LineCount;
      U.Cycle := -1;
      for D in Infos[I].Decls do
        case D.Kind of
          pdClass, pdRecord, pdInterface, pdEnum, pdType:
            if D.Parent = '' then
              Inc(U.Types);
          pdRoutine, pdMethodImpl:
            if D.Section <> 'interface' then
              Inc(U.Routines);
        end;
      Names.Add(LowerCase(U.Name), Length(Result.Units));
      Result.Units := Result.Units + [U];
      Infos[Length(Result.Units) - 1] := Infos[I];
    end;
    SetLength(Infos, Length(Result.Units));

    SetLength(UsedBy, Length(Result.Units));
    for I := 0 to High(UsedBy) do
      UsedBy[I] := TList<string>.Create;
    try
      SetLength(Adj, Length(Result.Units));
      for I := 0 to High(Result.Units) do
      begin
        for E in Infos[I].IntfUses do
          if not Names.TryGetValue(LowerCase(E.Name), K) then
            Inc(Result.Units[I].ExternalUses)
          else if K <> I then
          begin
            Result.Units[I].IntfUses := Result.Units[I].IntfUses + [Result.Units[K].Name];
            Adj[I] := Adj[I] + [K];
            UsedBy[K].Add(Result.Units[I].Name);
          end;
        for E in Infos[I].ImplUses do
          if not Names.TryGetValue(LowerCase(E.Name), K) then
            Inc(Result.Units[I].ExternalUses)
          else if K <> I then
          begin
            Result.Units[I].ImplUses := Result.Units[I].ImplUses + [Result.Units[K].Name];
            Adj[I] := Adj[I] + [K];
            UsedBy[K].Add(Result.Units[I].Name);
          end;
      end;
      for I := 0 to High(UsedBy) do
        Result.Units[I].UsedBy := UsedBy[I].ToArray;
    finally
      for I := 0 to High(UsedBy) do
        UsedBy[I].Free;
    end;

    // Programs and packages use every unit: leave them out of cycles.
    for I := 0 to High(Result.Units) do
      if Result.Units[I].Kind <> 'unit' then
        Adj[I] := nil;
    Comps := StronglyConnected(Adj);
    for J := 0 to High(Comps) do
    begin
      Cyc := nil;
      for K in Comps[J] do
      begin
        Cyc := Cyc + [Result.Units[K].Name];
        Result.Units[K].Cycle := J;
      end;
      TArray.Sort<string>(Cyc);
      Result.Cycles := Result.Cycles + [Cyc];
    end;
  finally
    Names.Free;
  end;
end;

end.
