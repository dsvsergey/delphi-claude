unit ClaudeCode.PascalIndex;

{ A light, forgiving Object Pascal reader for code navigation:
  - tokens with line/column, comments, strings and compiler directives kept apart;
  - the declarations of a unit (types, members, routines, method bodies, constants, variables)
    with their line ranges and one-line signatures;
  - uses clauses;
  - identifier occurrences outside comments and strings (references, renaming).
  It does not resolve types or overloads: a name means every symbol with that name. Conditional
  compilation is ignored (both branches are read). No ToolsAPI here, so it can be exercised
  outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TPasTokenKind = (ptIdent, ptNumber, ptString, ptSymbol, ptComment, ptDirective);

  TPasToken = record
    Kind: TPasTokenKind;
    Text: string;  // identifiers without a leading '&'
    Pos: Integer;  // 1-based index of the first character in the source (the '&' if any)
    Len: Integer;  // characters in the source
    Line: Integer; // 1-based
    Col: Integer;  // 1-based, UTF-16 units
    AfterDot: Boolean; // follows '.', so never a keyword (TState.Object, Self.Type)
    function Lower: string;
    function Is_(const S: string): Boolean; // case-insensitive text match
  end;

  TPasDeclKind = (pdUnit, pdType, pdClass, pdRecord, pdInterface, pdEnum, pdEnumValue, pdRoutine,
    pdMethod, pdMethodImpl, pdProperty, pdField, pdConst, pdVar, pdResourceString);

  TPasDecl = record
    Name: string;       // simple name
    Kind: TPasDeclKind;
    Parent: string;     // owning type of members and method bodies ('TForm1'), else ''
    Line, Col: Integer;
    EndLine: Integer;   // last line of a type or routine body when known, else Line
    Section: string;    // interface, implementation, program
    Visibility: string; // members: private, strict private, protected, public, published
    Signature: string;  // the declaration on one line
    Ancestor: string;   // classes and interfaces: the text between the parentheses
    function QualifiedName: string;
    function KindName: string;
  end;

  TUsesEntry = record
    Name: string;
    Line: Integer;
    InFile: string; // "Unit in 'path'" of program and package files
  end;

  TPasUnitInfo = record
    UnitName: string;
    UnitKind: string;   // unit, program, library, package
    IntfUses: TArray<TUsesEntry>;
    ImplUses: TArray<TUsesEntry>; // for programs/packages: the uses/contains list
    Decls: TArray<TPasDecl>;
    LineCount: Integer;
  end;

  TPasOccurrence = record
    Line, Col: Integer;
    Pos, Len: Integer;  // in the source, including a leading '&'
    Qualifier: string;  // "Customer" in Customer.Save, else ''
  end;

function TokenizePascal(const Src: string; KeepComments: Boolean = False): TArray<TPasToken>;
function IsPascalKeyword(const LowerName: string): Boolean;
function IsValidIdentifier(const S: string): Boolean;
function ParsePascalUnit(const Src: string): TPasUnitInfo;
{ Identifier occurrences of Name (case-insensitive) outside comments and strings. Works for
  Pascal sources and text DFM/FMX files (property values, component names, event handlers). }
function FindOccurrences(const Src, Name: string): TArray<TPasOccurrence>;
{ Src with the given occurrences replaced by NewName. }
function ReplaceOccurrences(const Src: string; const Occ: TArray<TPasOccurrence>; const NewName: string): string;
{ The text of a 1-based line, without the line break. }
function SourceLine(const Src: string; Line: Integer): string;
{ "unit Unit1 (240 lines)" followed by uses and declarations, one per line with line numbers. }
function UnitOutlineText(const Info: TPasUnitInfo; const FileName: string; WithMembers: Boolean): string;
{ The declared name in a Structure view caption: "TOrder.CalcTotal: Currency" gives TOrder.CalcTotal. }
function StructureCaptionName(const Caption: string): string;
{ The declaration a Structure view node stands for. Parts are the captions from the root down
  ("Structure", "implementation", "TOrder.Save(const Name: string)"); a routine or method gives its
  body, a type, field or property its declaration. }
function FindStructureItem(const Info: TPasUnitInfo; const Parts: TArray<string>; out Decl: TPasDecl): Boolean;

implementation

uses
  System.Character, System.Math;

const
  DeclKindNames: array[TPasDeclKind] of string = ('unit', 'type', 'class', 'record', 'interface', 'enum',
    'enumValue', 'routine', 'method', 'methodImpl', 'property', 'field', 'const', 'var', 'resourcestring');
  MAX_SIGNATURE = 300;

var
  Keywords: TDictionary<string, Boolean>;
  RoutineDirectives: TDictionary<string, Boolean>;

procedure InitWords;
const
  KW: array[0..66] of string = ('and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const',
    'constructor', 'destructor', 'dispinterface', 'div', 'do', 'downto', 'else', 'end', 'except', 'exports',
    'file', 'finalization', 'finally', 'for', 'function', 'goto', 'if', 'implementation', 'in', 'inherited',
    'initialization', 'inline', 'interface', 'is', 'label', 'library', 'mod', 'nil', 'not', 'object', 'of',
    'or', 'packed', 'procedure', 'program', 'property', 'raise', 'record', 'repeat', 'resourcestring', 'set',
    'shl', 'shr', 'string', 'then', 'threadvar', 'to', 'try', 'type', 'unit', 'until', 'uses', 'var',
    'while', 'with', 'xor', 'operator', 'out', 'absolute');
  RD: array[0..34] of string = ('overload', 'virtual', 'override', 'abstract', 'reintroduce', 'static',
    'dynamic', 'message', 'inline', 'cdecl', 'stdcall', 'safecall', 'register', 'pascal', 'final',
    'deprecated', 'platform', 'experimental', 'library', 'external', 'forward', 'assembler', 'export',
    'far', 'near', 'local', 'varargs', 'dispid', 'unsafe', 'winapi', 'noreturn', 'name', 'index',
    'delayed', 'default');
var
  S: string;
begin
  Keywords := TDictionary<string, Boolean>.Create;
  for S in KW do
    Keywords.AddOrSetValue(S, True);
  RoutineDirectives := TDictionary<string, Boolean>.Create;
  for S in RD do
    RoutineDirectives.AddOrSetValue(S, True);
end;

function IsPascalKeyword(const LowerName: string): Boolean;
begin
  Result := Keywords.ContainsKey(LowerName);
end;

function IsIdentStart(C: Char): Boolean; inline;
begin
  Result := (C = '_') or CharInSet(C, ['A'..'Z', 'a'..'z']) or ((Ord(C) > 127) and C.IsLetter);
end;

function IsIdentChar(C: Char): Boolean; inline;
begin
  Result := (C = '_') or CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9']) or ((Ord(C) > 127) and C.IsLetterOrDigit);
end;

function IsValidIdentifier(const S: string): Boolean;
var
  I: Integer;
begin
  Result := (S <> '') and IsIdentStart(S[1]) and not IsPascalKeyword(LowerCase(S));
  if Result then
    for I := 2 to Length(S) do
      if not IsIdentChar(S[I]) then
        Exit(False);
end;

{ TPasToken }

function TPasToken.Lower: string;
begin
  Result := LowerCase(Text);
end;

function TPasToken.Is_(const S: string): Boolean;
begin
  Result := (Kind = ptIdent) and SameText(Text, S);
end;

{ Tokenizer }

function TokenizePascal(const Src: string; KeepComments: Boolean): TArray<TPasToken>;
var
  L: TList<TPasToken>;
  P, N, Line, LineStart, Start, StartLine, StartCol: Integer;

  procedure Add(Kind: TPasTokenKind; TextStart, TextLen: Integer);
  var
    T: TPasToken;
  begin
    if not KeepComments and (Kind in [ptComment, ptDirective]) then
      Exit;
    T.Kind := Kind;
    T.Text := Copy(Src, TextStart, TextLen);
    T.Pos := Start;
    T.Len := P - Start;
    T.Line := StartLine;
    T.Col := StartCol;
    T.AfterDot := (L.Count > 0) and (L.Last.Kind = ptSymbol) and (L.Last.Text = '.');
    L.Add(T);
  end;

  procedure NewLineAt(I: Integer);
  begin
    Inc(Line);
    LineStart := I + 1;
  end;

  { Advances P past the closing text, counting lines. }
  procedure SkipUntil(const Close: string);
  begin
    while P <= N do
    begin
      if (Src[P] = Close[1]) and (Copy(Src, P, Length(Close)) = Close) then
      begin
        Inc(P, Length(Close));
        Exit;
      end;
      if Src[P] = #10 then
        NewLineAt(P);
      Inc(P);
    end;
    P := N + 1; // unterminated: to the end
  end;

begin
  L := TList<TPasToken>.Create;
  try
    N := Length(Src);
    P := 1;
    Line := 1;
    LineStart := 1;
    while P <= N do
    begin
      if Src[P] = #10 then
      begin
        NewLineAt(P);
        Inc(P);
        Continue;
      end;
      if Src[P] <= ' ' then
      begin
        Inc(P);
        Continue;
      end;
      Start := P;
      StartLine := Line;
      StartCol := P - LineStart + 1;
      case Src[P] of
        '/':
          if (P < N) and (Src[P + 1] = '/') then
          begin
            while (P <= N) and (Src[P] <> #10) and (Src[P] <> #13) do
              Inc(P);
            Add(ptComment, Start, P - Start);
          end
          else
          begin
            Inc(P);
            Add(ptSymbol, Start, 1);
          end;
        '{':
          begin
            Inc(P);
            SkipUntil('}');
            if (Start < N) and (Src[Start + 1] = '$') then
              Add(ptDirective, Start, P - Start)
            else
              Add(ptComment, Start, P - Start);
          end;
        '(':
          if (P < N) and (Src[P + 1] = '*') then
          begin
            Inc(P, 2);
            SkipUntil('*)');
            if (Start + 2 <= N) and (Src[Start + 2] = '$') then
              Add(ptDirective, Start, P - Start)
            else
              Add(ptComment, Start, P - Start);
          end
          else
          begin
            Inc(P);
            Add(ptSymbol, Start, 1);
          end;
        '''':
          begin
            // Multi-line string: ''' + line break ... '''
            if (Copy(Src, P, 3) = '''''''') and (P + 3 <= N) and CharInSet(Src[P + 3], [#13, #10]) then
            begin
              Inc(P, 3);
              SkipUntil('''''''');
            end
            else
            begin
              Inc(P);
              while P <= N do
              begin
                if Src[P] = '''' then
                begin
                  if (P < N) and (Src[P + 1] = '''') then
                    Inc(P, 2)
                  else
                  begin
                    Inc(P);
                    Break;
                  end;
                end
                else if CharInSet(Src[P], [#10, #13]) then
                  Break // unterminated on this line
                else
                  Inc(P);
              end;
            end;
            Add(ptString, Start, P - Start);
          end;
        '#':
          begin
            Inc(P);
            if (P <= N) and (Src[P] = '$') then
            begin
              Inc(P);
              while (P <= N) and CharInSet(Src[P], ['0'..'9', 'A'..'F', 'a'..'f']) do
                Inc(P);
            end
            else
              while (P <= N) and CharInSet(Src[P], ['0'..'9']) do
                Inc(P);
            Add(ptString, Start, P - Start);
          end;
        '0'..'9':
          begin
            while (P <= N) and CharInSet(Src[P], ['0'..'9', '_']) do
              Inc(P);
            // Fraction, but not a range "1..5"
            if (P < N) and (Src[P] = '.') and CharInSet(Src[P + 1], ['0'..'9']) then
            begin
              Inc(P);
              while (P <= N) and CharInSet(Src[P], ['0'..'9', '_']) do
                Inc(P);
            end;
            if (P <= N) and CharInSet(Src[P], ['e', 'E']) and (P < N) and
               CharInSet(Src[P + 1], ['0'..'9', '+', '-']) then
            begin
              Inc(P, 2);
              while (P <= N) and CharInSet(Src[P], ['0'..'9']) do
                Inc(P);
            end;
            Add(ptNumber, Start, P - Start);
          end;
        '$':
          begin
            Inc(P);
            while (P <= N) and CharInSet(Src[P], ['0'..'9', 'A'..'F', 'a'..'f', '_']) do
              Inc(P);
            Add(ptNumber, Start, P - Start);
          end;
        '%':
          begin
            Inc(P);
            while (P <= N) and CharInSet(Src[P], ['0', '1', '_']) do
              Inc(P);
            Add(ptNumber, Start, P - Start);
          end;
        '&':
          if (P < N) and IsIdentStart(Src[P + 1]) then
          begin
            Inc(P);
            while (P <= N) and IsIdentChar(Src[P]) do
              Inc(P);
            Add(ptIdent, Start + 1, P - Start - 1);
          end
          else
          begin
            Inc(P);
            Add(ptSymbol, Start, 1);
          end;
      else
        if IsIdentStart(Src[P]) then
        begin
          while (P <= N) and IsIdentChar(Src[P]) do
            Inc(P);
          Add(ptIdent, Start, P - Start);
        end
        else
        begin
          if (P < N) and (((Src[P] = ':') and (Src[P + 1] = '=')) or ((Src[P] = '.') and (Src[P + 1] = '.')) or
             ((Src[P] = '<') and CharInSet(Src[P + 1], ['=', '>'])) or ((Src[P] = '>') and (Src[P + 1] = '='))) then
            Inc(P, 2)
          else
            Inc(P);
          Add(ptSymbol, Start, P - Start);
        end;
      end;
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

{ TPasDecl }

function TPasDecl.QualifiedName: string;
begin
  if Parent <> '' then
    Result := Parent + '.' + Name
  else
    Result := Name;
end;

function TPasDecl.KindName: string;
begin
  Result := DeclKindNames[Kind];
end;

{ Parser }

type
  TPasParser = class
  private
    FSrc: string;
    T: TArray<TPasToken>;
    I: Integer;
    FDecls: TList<TPasDecl>;
    FInfo: TPasUnitInfo;
    FSection: string;
    function Tok(Offset: Integer = 0): TPasToken;
    function AtEnd: Boolean;
    function Sym(const S: string; Offset: Integer = 0): Boolean;
    function KW(const S: string; Offset: Integer = 0): Boolean;
    function IsIdentTok(Offset: Integer = 0): Boolean;
    function KwLower: string;
    function TextBetween(FirstTok, LastTok: Integer): string;
    procedure SkipTo(const S: string);
    procedure SkipBrackets;
    procedure SkipToMatchingEnd;
    procedure SkipTypeExpr;
    procedure SkipGenericParams;
    function AddDecl(const Name: string; Kind: TPasDeclKind; const Parent: string; At: Integer;
      const Visibility: string = ''): Integer;
    procedure SetSignature(Index, FirstTok, LastTok: Integer);
    procedure ParseUses(Implementation_: Boolean);
    procedure ParseTypeDecl(const Parent, Visibility: string);
    procedure ParseStructBody(const TypeName: string; DeclIndex: Integer; IsRecord: Boolean);
    procedure ParseConstDecl(Kind: TPasDeclKind; const Parent, Visibility: string);
    procedure ParseVarDecl(Kind: TPasDeclKind; const Parent, Visibility: string);
    function ParseRoutine(const Parent, Visibility: string; InStruct: Boolean; Record_: Boolean = True): Integer;
    procedure SkipRoutineBody(DeclIndex: Integer);
  public
    constructor Create(const Src: string);
    destructor Destroy; override;
    function Parse: TPasUnitInfo;
  end;

constructor TPasParser.Create(const Src: string);
begin
  inherited Create;
  FSrc := Src;
  T := TokenizePascal(Src, False);
  // Directives are noise for declarations.
  FDecls := TList<TPasDecl>.Create;
end;

destructor TPasParser.Destroy;
begin
  FDecls.Free;
  inherited;
end;

function TPasParser.Tok(Offset: Integer): TPasToken;
begin
  if (I + Offset >= 0) and (I + Offset < Length(T)) then
    Result := T[I + Offset]
  else
  begin
    Result := Default(TPasToken);
    Result.Kind := ptSymbol;
    Result.Text := #0;
    if Length(T) > 0 then
      Result.Line := T[High(T)].Line;
  end;
end;

function TPasParser.AtEnd: Boolean;
begin
  Result := I >= Length(T);
end;

function TPasParser.Sym(const S: string; Offset: Integer): Boolean;
var
  X: TPasToken;
begin
  X := Tok(Offset);
  Result := (X.Kind = ptSymbol) and (X.Text = S);
end;

function TPasParser.KW(const S: string; Offset: Integer): Boolean;
var
  X: TPasToken;
begin
  X := Tok(Offset);
  Result := X.Is_(S) and not X.AfterDot;
end;

function TPasParser.KwLower: string;
begin
  // The current token as a possible keyword; '' after a dot.
  if Tok.AfterDot then
    Result := ''
  else
    Result := Tok.Lower;
end;

function TPasParser.IsIdentTok(Offset: Integer): Boolean;
var
  X: TPasToken;
begin
  X := Tok(Offset);
  Result := (X.Kind = ptIdent) and not IsPascalKeyword(X.Lower);
end;

function TPasParser.TextBetween(FirstTok, LastTok: Integer): string;
var
  A, B, K, N: Integer;
  Space: Boolean;
  C: Char;
begin
  if (FirstTok < 0) or (LastTok >= Length(T)) or (LastTok < FirstTok) then
    Exit('');
  A := T[FirstTok].Pos;
  B := Min(T[LastTok].Pos + T[LastTok].Len, A + 4 * MAX_SIGNATURE);
  // One line, single spaces.
  SetLength(Result, B - A);
  N := 0;
  Space := False;
  for K := A to B - 1 do
  begin
    C := FSrc[K];
    if C <= ' ' then
      Space := True
    else
    begin
      if Space and (N > 0) then
      begin
        Inc(N);
        Result[N] := ' ';
      end;
      Space := False;
      Inc(N);
      Result[N] := C;
    end;
  end;
  SetLength(Result, N);
  if N > MAX_SIGNATURE then
    Result := Copy(Result, 1, MAX_SIGNATURE) + '...';
end;

procedure TPasParser.SkipTo(const S: string);
var
  Depth: Integer;
begin
  // To the token after S at bracket depth 0.
  Depth := 0;
  while not AtEnd do
  begin
    if Sym('(') or Sym('[') then
      Inc(Depth)
    else if Sym(')') or Sym(']') then
      Dec(Depth)
    else if (Depth <= 0) and Sym(S) then
    begin
      Inc(I);
      Exit;
    end;
    Inc(I);
  end;
end;

procedure TPasParser.SkipBrackets;
var
  Depth: Integer;
begin
  // At '(' or '[': past the matching closer.
  Depth := 0;
  repeat
    if Sym('(') or Sym('[') then
      Inc(Depth)
    else if Sym(')') or Sym(']') then
      Dec(Depth);
    Inc(I);
  until AtEnd or (Depth <= 0);
end;

procedure TPasParser.SkipGenericParams;
var
  Depth: Integer;
begin
  if not Sym('<') then
    Exit;
  Depth := 0;
  repeat
    if Sym('<') then
      Inc(Depth)
    else if Sym('>') then
      Dec(Depth)
    else if Sym('>=') then // "TList<T>=" lexed as '>='
    begin
      Dec(Depth);
      if Depth <= 0 then
      begin
        // Leave a '=' for the caller: replace the token in place.
        T[I].Text := '=';
        Exit;
      end;
    end;
    Inc(I);
  until AtEnd or (Depth <= 0);
end;

procedure TPasParser.SkipToMatchingEnd;
var
  Depth: Integer;
  L: string;
begin
  // At the opener of a structured type (record, class, object, interface): past its "end".
  // A variant part ("case ... of") shares the record's "end".
  Depth := 1;
  Inc(I);
  while not AtEnd do
  begin
    if Tok.Kind = ptIdent then
    begin
      L := KwLower;
      if L = 'record' then
        Inc(Depth)
      else if ((L = 'class') or (L = 'object') or (L = 'interface') or (L = 'dispinterface')) and
              (Sym('=', -1) or Sym(':', -1)) and not (KW('of', 1) or Sym(';', 1)) then
        Inc(Depth)
      else if L = 'end' then
      begin
        Dec(Depth);
        if Depth <= 0 then
        begin
          Inc(I);
          Exit;
        end;
      end;
    end;
    Inc(I);
  end;
end;

procedure TPasParser.SkipTypeExpr;
var
  Depth: Integer;
  L: string;
begin
  // A type (and initializer) up to ';' or a closing ')' or 'end' at depth 0; stops on them.
  Depth := 0;
  while not AtEnd do
  begin
    if Sym('(') or Sym('[') then
      Inc(Depth)
    else if Sym(')') or Sym(']') then
    begin
      if Depth = 0 then
        Exit;
      Dec(Depth);
    end
    else if (Depth = 0) and Sym(';') then
      Exit
    else if Tok.Kind = ptIdent then
    begin
      L := KwLower;
      if (Depth = 0) and (L = 'end') then
        Exit;
      if (L = 'record') or ((L = 'class') and not KW('of', 1) and not Sym(';', 1)) or
         ((L = 'object') and not KW('of', -1)) then
      begin
        SkipToMatchingEnd;
        Continue;
      end;
    end;
    Inc(I);
  end;
end;

function TPasParser.AddDecl(const Name: string; Kind: TPasDeclKind; const Parent: string; At: Integer;
  const Visibility: string): Integer;
var
  D: TPasDecl;
begin
  D := Default(TPasDecl);
  D.Name := Name;
  D.Kind := Kind;
  D.Parent := Parent;
  if (At >= 0) and (At < Length(T)) then
  begin
    D.Line := T[At].Line;
    D.Col := T[At].Col;
  end;
  D.EndLine := D.Line;
  D.Section := FSection;
  D.Visibility := Visibility;
  Result := FDecls.Add(D);
end;

procedure TPasParser.SetSignature(Index, FirstTok, LastTok: Integer);
var
  D: TPasDecl;
begin
  D := FDecls[Index];
  D.Signature := TextBetween(FirstTok, LastTok);
  FDecls[Index] := D;
end;

procedure TPasParser.ParseUses(Implementation_: Boolean);
var
  E: TUsesEntry;
  L: TList<TUsesEntry>;
begin
  Inc(I); // uses/contains/requires
  L := TList<TUsesEntry>.Create;
  try
    while not AtEnd and not Sym(';') do
    begin
      if Tok.Kind = ptIdent then
      begin
        E := Default(TUsesEntry);
        E.Line := Tok.Line;
        E.Name := Tok.Text;
        Inc(I);
        while Sym('.') and (Tok(1).Kind = ptIdent) do
        begin
          E.Name := E.Name + '.' + Tok(1).Text;
          Inc(I, 2);
        end;
        if KW('in') and (Tok(1).Kind = ptString) then
        begin
          E.InFile := Tok(1).Text;
          if (Length(E.InFile) >= 2) and (E.InFile[1] = '''') then
            E.InFile := Copy(E.InFile, 2, Length(E.InFile) - 2);
          Inc(I, 2);
        end;
        L.Add(E);
      end
      else
        Inc(I);
    end;
    Inc(I);
    if Implementation_ then
      FInfo.ImplUses := FInfo.ImplUses + L.ToArray
    else
      FInfo.IntfUses := FInfo.IntfUses + L.ToArray;
  finally
    L.Free;
  end;
end;

function TPasParser.ParseRoutine(const Parent, Visibility: string; InStruct: Boolean; Record_: Boolean): Integer;
var
  First, NameTok, Idx: Integer;
  Name, Owner, L: string;
  Kind: TPasDeclKind;
  NoBody: Boolean;
begin
  // At [class] procedure/function/constructor/destructor/operator.
  First := I;
  if KW('class') then
    Inc(I);
  Inc(I); // the routine keyword
  Result := -1;
  NameTok := I;
  Name := '';
  Owner := '';
  if Tok.Kind = ptIdent then
  begin
    Name := Tok.Text;
    Inc(I);
    SkipGenericParams;
    while Sym('.') and (Tok(1).Kind = ptIdent) do
    begin
      if Owner <> '' then
        Owner := Owner + '.' + Name
      else
        Owner := Name;
      Name := Tok(1).Text;
      NameTok := I + 1;
      Inc(I, 2);
      SkipGenericParams;
    end;
  end;
  // Parameters, result type, ';'
  if Sym('(') then
    SkipBrackets;
  // Interface method resolution "procedure IFoo.Bar = Baz;" and the rest of the header
  while not AtEnd and not Sym(';') do
  begin
    if Sym('(') or Sym('[') then
      SkipBrackets
    else if KW('begin') or KW('end') then
      Break
    else
      Inc(I);
  end;
  if Name = '' then
  begin
    if Sym(';') then
      Inc(I);
    Exit;
  end;

  if InStruct then
    Kind := pdMethod
  else if Owner <> '' then
    Kind := pdMethodImpl
  else
    Kind := pdRoutine;
  if Record_ then
  begin
    if InStruct then
      Idx := AddDecl(Name, Kind, Parent, NameTok, Visibility)
    else
      Idx := AddDecl(Name, Kind, Owner, NameTok, Visibility);
    SetSignature(Idx, First, I);
    Result := Idx;
  end
  else
    Idx := -1;
  if Sym(';') then
    Inc(I);

  // Directives: overload; virtual; external 'x.dll' name 'y'; forward; ...
  NoBody := InStruct or (FSection = 'interface');
  while not AtEnd and (Tok.Kind = ptIdent) and RoutineDirectives.ContainsKey(Tok.Lower) do
  begin
    L := KwLower;
    if (L = 'external') or (L = 'forward') then
      NoBody := True;
    // "default" only follows properties; stop so it is not eaten here.
    if L = 'default' then
      Break;
    SkipTo(';');
    if Idx >= 0 then
      SetSignature(Idx, First, I - 1); // with the directives: virtual; override; ...
  end;
  // Without a unit header (include files) a body must follow right away.
  if (FSection = '') and not (KW('begin') or KW('asm') or KW('var') or KW('const') or KW('type') or
     KW('label')) then
    NoBody := True;
  if not NoBody then
    SkipRoutineBody(Idx);
end;

procedure TPasParser.SkipRoutineBody(DeclIndex: Integer);
var
  Depth: Integer;
  L: string;
  D: TPasDecl;
begin
  // Local declarations and nested routines, then begin/asm ... end;
  while not AtEnd do
  begin
    if Tok.Kind <> ptIdent then
    begin
      Inc(I);
      Continue;
    end;
    L := KwLower;
    if (L = 'begin') or (L = 'asm') then
      Break;
    if (L = 'procedure') or (L = 'function') or (L = 'constructor') or (L = 'destructor') or
       ((L = 'class') and (KW('procedure', 1) or KW('function', 1))) then
    begin
      ParseRoutine('', '', False, False); // nested routine, not listed
      Continue;
    end;
    if (L = 'record') or (((L = 'class') or (L = 'object') or (L = 'interface')) and Sym('=', -1)) then
    begin
      if (L = 'class') and (KW('of', 1) or Sym(';', 1)) then
        Inc(I)
      else
        SkipToMatchingEnd;
      Continue;
    end;
    // A unit-level keyword means the body was missing (e.g. a declaration we misread).
    if (L = 'implementation') or (L = 'initialization') or (L = 'finalization') then
      Exit;
    Inc(I);
  end;
  Depth := 0;
  while not AtEnd do
  begin
    if Tok.Kind = ptIdent then
    begin
      L := KwLower;
      if (L = 'begin') or (L = 'try') or (L = 'case') or (L = 'asm') then
        Inc(Depth)
      else if (L = 'record') and Sym('=', -1) then
        Inc(Depth)
      else if L = 'end' then
      begin
        Dec(Depth);
        if Depth <= 0 then
        begin
          if (DeclIndex >= 0) and (DeclIndex < FDecls.Count) then
          begin
            D := FDecls[DeclIndex];
            D.EndLine := Tok.Line;
            FDecls[DeclIndex] := D;
          end;
          Inc(I);
          if Sym(';') then
            Inc(I);
          Exit;
        end;
      end;
    end;
    Inc(I);
  end;
end;

procedure TPasParser.ParseConstDecl(Kind: TPasDeclKind; const Parent, Visibility: string);
var
  First, Idx: Integer;
begin
  // Name [: Type] = Value;
  First := I;
  if not (Sym('=', 1) or Sym(':', 1)) then
  begin
    Inc(I);
    Exit;
  end;
  Idx := AddDecl(Tok.Text, Kind, Parent, I, Visibility);
  Inc(I);
  SkipTypeExpr;
  SetSignature(Idx, First, Max(First, I - 1));
  if Sym(';') then
    Inc(I);
end;

procedure TPasParser.ParseVarDecl(Kind: TPasDeclKind; const Parent, Visibility: string);
var
  Names: TList<Integer>;
  First, Idx, K: Integer;
begin
  // A, B: Type [= Init] [absolute X];
  First := I;
  Names := TList<Integer>.Create;
  try
    while IsIdentTok do
    begin
      Names.Add(I);
      Inc(I);
      if Sym(',') then
        Inc(I)
      else
        Break;
    end;
    if not Sym(':') or (Names.Count = 0) then
    begin
      Inc(I);
      Exit;
    end;
    Inc(I);
    SkipTypeExpr;
    for K in Names do
    begin
      Idx := AddDecl(T[K].Text, Kind, Parent, K, Visibility);
      SetSignature(Idx, First, Max(First, I - 1));
    end;
    if Sym(';') then
      Inc(I);
  finally
    Names.Free;
  end;
end;

procedure TPasParser.ParseTypeDecl(const Parent, Visibility: string);
var
  NameTok, First, Idx, AncStart: Integer;
  Name, L: string;
  D: TPasDecl;
begin
  First := I;
  NameTok := I;
  Name := Tok.Text;
  Inc(I);
  SkipGenericParams;
  if not Sym('=') then
  begin
    SkipTo(';');
    Exit;
  end;
  Inc(I);
  if KW('type') then
    Inc(I);
  if KW('packed') then
    Inc(I);
  L := KwLower;
  if Tok.Kind <> ptIdent then
    L := '';
  if (L = 'class') or (L = 'object') then
  begin
    if Sym(';', 1) then // forward declaration
    begin
      Inc(I, 2);
      Exit;
    end;
    if KW('of', 1) then
    begin
      Idx := AddDecl(Name, pdType, Parent, NameTok, Visibility);
      SkipTo(';');
      SetSignature(Idx, First, I - 2);
      Exit;
    end;
    Idx := AddDecl(Name, pdClass, Parent, NameTok, Visibility);
    Inc(I);
    while KW('abstract') or KW('sealed') or KW('helper') do
    begin
      if KW('helper') then
      begin
        Inc(I);
        if Sym('(') then
          SkipBrackets;
        if KW('for') then
          Inc(I, 2);
        Continue;
      end;
      Inc(I);
    end;
    if Sym('(') then
    begin
      AncStart := I + 1;
      SkipBrackets;
      D := FDecls[Idx];
      D.Ancestor := TextBetween(AncStart, I - 2);
      FDecls[Idx] := D;
    end;
    SetSignature(Idx, First, I - 1);
    if Sym(';') then // TFoo = class(TBar);
    begin
      Inc(I);
      Exit;
    end;
    ParseStructBody(Name, Idx, False);
    Exit;
  end;
  if L = 'record' then
  begin
    Idx := AddDecl(Name, pdRecord, Parent, NameTok, Visibility);
    Inc(I);
    if KW('helper') then
    begin
      Inc(I);
      if KW('for') then
        Inc(I, 2);
    end;
    SetSignature(Idx, First, I - 1);
    ParseStructBody(Name, Idx, True);
    Exit;
  end;
  if (L = 'interface') or (L = 'dispinterface') then
  begin
    if Sym(';', 1) then
    begin
      Inc(I, 2);
      Exit;
    end;
    Idx := AddDecl(Name, pdInterface, Parent, NameTok, Visibility);
    Inc(I);
    if Sym('(') then
    begin
      AncStart := I + 1;
      SkipBrackets;
      D := FDecls[Idx];
      D.Ancestor := TextBetween(AncStart, I - 2);
      FDecls[Idx] := D;
    end;
    SetSignature(Idx, First, I - 1);
    if Sym('[') then // GUID
      SkipBrackets;
    ParseStructBody(Name, Idx, False);
    Exit;
  end;
  if Sym('(') then
  begin
    Idx := AddDecl(Name, pdEnum, Parent, NameTok, Visibility);
    Inc(I);
    while not AtEnd and not Sym(')') do
    begin
      if IsIdentTok then
      begin
        AddDecl(Tok.Text, pdEnumValue, Name, I, Visibility);
        Inc(I);
        if Sym('=') then // explicit ordinal
          while not AtEnd and not Sym(',') and not Sym(')') do
            Inc(I);
      end
      else
        Inc(I);
    end;
    Inc(I);
    SkipTo(';');
    SetSignature(Idx, First, I - 2);
    D := FDecls[Idx];
    D.EndLine := Tok(-1).Line;
    FDecls[Idx] := D;
    Exit;
  end;
  // Alias, set, array, pointer, procedural type...
  Idx := AddDecl(Name, pdType, Parent, NameTok, Visibility);
  SkipTypeExpr;
  SetSignature(Idx, First, Max(First, I - 1));
  if Sym(';') then
    Inc(I);
  // Procedural type directives: "of object; stdcall;"
  while not AtEnd and (Tok.Kind = ptIdent) and RoutineDirectives.ContainsKey(Tok.Lower) and
        not Sym('=', 1) do
    SkipTo(';');
end;

procedure TPasParser.ParseStructBody(const TypeName: string; DeclIndex: Integer; IsRecord: Boolean);
type
  TMemberBlock = (mbFields, mbConst, mbType, mbVar);
var
  Visibility, L: string;
  Block: TMemberBlock;
  IsClassMember: Boolean;
  First, Idx: Integer;
  D: TPasDecl;
begin
  if IsRecord then
    Visibility := 'public'
  else
    Visibility := 'published';
  Block := mbFields;
  while not AtEnd do
  begin
    if Sym('[') then // attributes
    begin
      SkipBrackets;
      Continue;
    end;
    if Tok.Kind <> ptIdent then
    begin
      Inc(I);
      Continue;
    end;
    L := KwLower;
    if L = 'end' then
    begin
      D := FDecls[DeclIndex];
      D.EndLine := Tok.Line;
      FDecls[DeclIndex] := D;
      Inc(I);
      SkipTo(';');
      Exit;
    end;
    if (L = 'strict') and (KW('private', 1) or KW('protected', 1)) then
    begin
      Visibility := 'strict ' + Tok(1).Lower;
      Block := mbFields;
      Inc(I, 2);
      Continue;
    end;
    if (L = 'private') or (L = 'protected') or (L = 'public') or (L = 'published') or (L = 'automated') then
    begin
      Visibility := L;
      Block := mbFields;
      Inc(I);
      Continue;
    end;
    IsClassMember := False;
    if (L = 'class') and (KW('procedure', 1) or KW('function', 1) or KW('constructor', 1) or
       KW('destructor', 1) or KW('operator', 1) or KW('property', 1) or KW('var', 1)) then
    begin
      IsClassMember := True;
      if KW('var', 1) then
      begin
        Block := mbVar;
        Inc(I, 2);
        Continue;
      end;
      if KW('property', 1) then
      begin
        Inc(I);
        L := 'property';
      end;
    end;
    if IsClassMember and (L <> 'property') then
    begin
      ParseRoutine(TypeName, Visibility, True);
      Continue;
    end;
    if (L = 'procedure') or (L = 'function') or (L = 'constructor') or (L = 'destructor') or (L = 'operator') then
    begin
      Block := mbFields;
      ParseRoutine(TypeName, Visibility, True);
      Continue;
    end;
    if L = 'property' then
    begin
      Block := mbFields;
      First := I;
      Inc(I);
      if IsIdentTok or (Tok.Kind = ptIdent) then
      begin
        Idx := AddDecl(Tok.Text, pdProperty, TypeName, I, Visibility);
        SkipTo(';');
        if KW('default') and Sym(';', 1) then
          Inc(I, 2);
        SetSignature(Idx, First, I - 1);
      end
      else
        SkipTo(';');
      Continue;
    end;
    if L = 'const' then
    begin
      Block := mbConst;
      Inc(I);
      Continue;
    end;
    if L = 'type' then
    begin
      Block := mbType;
      Inc(I);
      Continue;
    end;
    if L = 'var' then
    begin
      Block := mbVar;
      Inc(I);
      Continue;
    end;
    if L = 'case' then // variant part of a record: "case [Tag:] Type of"
    begin
      Inc(I);
      if IsIdentTok and Sym(':', 1) then
      begin
        Idx := AddDecl(Tok.Text, pdField, TypeName, I, Visibility);
        SetSignature(Idx, I, I + 2);
      end;
      while not AtEnd and not KW('of') do
        Inc(I);
      Inc(I);
      Continue;
    end;
    if not IsIdentTok then
    begin
      Inc(I);
      Continue;
    end;
    case Block of
      mbConst:
        ParseConstDecl(pdConst, TypeName, Visibility);
      mbType:
        ParseTypeDecl(TypeName, Visibility);
    else
      if Sym(':', 1) or Sym(',', 1) then
        ParseVarDecl(pdField, TypeName, Visibility)
      else
        Inc(I);
    end;
  end;
end;

function TPasParser.Parse: TPasUnitInfo;
type
  TBlock = (bNone, bType, bConst, bVar, bRes);
var
  L: string;
  Block: TBlock;
  Idx: Integer;
begin
  FInfo := Default(TPasUnitInfo);
  FSection := '';
  Block := bNone;
  I := 0;
  while not AtEnd do
  begin
    if Sym('[') then
    begin
      SkipBrackets;
      Continue;
    end;
    if Tok.Kind <> ptIdent then
    begin
      // "end." finishes the unit
      Inc(I);
      Continue;
    end;
    L := KwLower;
    if ((L = 'unit') or (L = 'program') or (L = 'library') or (L = 'package')) and (FInfo.UnitName = '') and
       (Tok(1).Kind = ptIdent) then
    begin
      FInfo.UnitKind := L;
      Inc(I);
      Idx := I;
      FInfo.UnitName := Tok.Text;
      Inc(I);
      while Sym('.') and (Tok(1).Kind = ptIdent) do
      begin
        FInfo.UnitName := FInfo.UnitName + '.' + Tok(1).Text;
        Inc(I, 2);
      end;
      AddDecl(FInfo.UnitName, pdUnit, '', Idx);
      if L <> 'unit' then
        FSection := 'program';
      SkipTo(';');
      Continue;
    end;
    if (L = 'interface') and (FSection = '') then
    begin
      FSection := 'interface';
      Block := bNone;
      Inc(I);
      Continue;
    end;
    if L = 'implementation' then
    begin
      FSection := 'implementation';
      Block := bNone;
      Inc(I);
      Continue;
    end;
    if (L = 'initialization') or (L = 'finalization') or (L = 'begin') then
      Break; // nothing is declared after this
    if (L = 'end') and Sym('.', 1) then
      Break;
    if (L = 'uses') or (L = 'contains') or (L = 'requires') then
    begin
      ParseUses((FSection = 'implementation') or (FSection = 'program'));
      Block := bNone;
      Continue;
    end;
    if L = 'type' then
    begin
      Block := bType;
      Inc(I);
      Continue;
    end;
    if L = 'const' then
    begin
      Block := bConst;
      Inc(I);
      Continue;
    end;
    if L = 'resourcestring' then
    begin
      Block := bRes;
      Inc(I);
      Continue;
    end;
    if (L = 'var') or (L = 'threadvar') then
    begin
      Block := bVar;
      Inc(I);
      Continue;
    end;
    if (L = 'exports') or (L = 'label') then
    begin
      Block := bNone;
      SkipTo(';');
      Continue;
    end;
    if (L = 'procedure') or (L = 'function') or (L = 'constructor') or (L = 'destructor') or (L = 'operator') or
       ((L = 'class') and (KW('procedure', 1) or KW('function', 1) or KW('constructor', 1) or
        KW('destructor', 1) or KW('operator', 1))) then
    begin
      Block := bNone;
      ParseRoutine('', '', False);
      Continue;
    end;
    if not IsIdentTok then
    begin
      Inc(I);
      Continue;
    end;
    case Block of
      bType:
        ParseTypeDecl('', '');
      bConst:
        ParseConstDecl(pdConst, '', '');
      bRes:
        ParseConstDecl(pdResourceString, '', '');
      bVar:
        ParseVarDecl(pdVar, '', '');
    else
      Inc(I);
    end;
  end;
  FInfo.Decls := FDecls.ToArray;
  Result := FInfo;
end;

function CountLines(const Src: string): Integer;
var
  C: Char;
begin
  if Src = '' then
    Exit(0);
  Result := 1;
  for C in Src do
    if C = #10 then
      Inc(Result);
  if Src[Length(Src)] = #10 then
    Dec(Result);
end;

function ParsePascalUnit(const Src: string): TPasUnitInfo;
var
  P: TPasParser;
begin
  P := TPasParser.Create(Src);
  try
    Result := P.Parse;
  finally
    P.Free;
  end;
  Result.LineCount := CountLines(Src);
end;

function FindOccurrences(const Src, Name: string): TArray<TPasOccurrence>;
var
  Toks: TArray<TPasToken>;
  L: TList<TPasOccurrence>;
  K: Integer;
  O: TPasOccurrence;
  Want: string;
begin
  Want := Name;
  if Want.StartsWith('&') then
    Delete(Want, 1, 1);
  // Cheap pre-check: most files do not mention the name at all.
  if Pos(LowerCase(Want), LowerCase(Src)) = 0 then
    Exit(nil);
  Toks := TokenizePascal(Src, False);
  L := TList<TPasOccurrence>.Create;
  try
    for K := 0 to High(Toks) do
      if (Toks[K].Kind = ptIdent) and SameText(Toks[K].Text, Want) then
      begin
        O.Line := Toks[K].Line;
        O.Col := Toks[K].Col;
        O.Pos := Toks[K].Pos;
        O.Len := Toks[K].Len;
        O.Qualifier := '';
        if (K >= 2) and (Toks[K - 1].Kind = ptSymbol) and (Toks[K - 1].Text = '.') and
           (Toks[K - 2].Kind = ptIdent) then
          O.Qualifier := Toks[K - 2].Text;
        L.Add(O);
      end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function ReplaceOccurrences(const Src: string; const Occ: TArray<TPasOccurrence>; const NewName: string): string;
var
  K: Integer;
  Sorted: TArray<TPasOccurrence>;
  Swap: TPasOccurrence;
  A, B: Integer;
begin
  // From the end, so earlier positions stay valid.
  Sorted := Copy(Occ);
  for A := 1 to High(Sorted) do
  begin
    B := A;
    while (B > 0) and (Sorted[B - 1].Pos > Sorted[B].Pos) do
    begin
      Swap := Sorted[B - 1];
      Sorted[B - 1] := Sorted[B];
      Sorted[B] := Swap;
      Dec(B);
    end;
  end;
  Result := Src;
  for K := High(Sorted) downto 0 do
    Result := Copy(Result, 1, Sorted[K].Pos - 1) + NewName + Copy(Result, Sorted[K].Pos + Sorted[K].Len, MaxInt);
end;

function SourceLine(const Src: string; Line: Integer): string;
var
  P, Q, N: Integer;
begin
  Result := '';
  P := 1;
  N := 1;
  while (N < Line) and (P <= Length(Src)) do
  begin
    if Src[P] = #10 then
      Inc(N);
    Inc(P);
  end;
  if N <> Line then
    Exit;
  Q := P;
  while (Q <= Length(Src)) and not CharInSet(Src[Q], [#10, #13]) do
    Inc(Q);
  Result := Copy(Src, P, Q - P);
end;

function StructureCaptionName(const Caption: string): string;
var
  I: Integer;
begin
  Result := Caption;
  for I := 1 to Length(Result) do
    if CharInSet(Result[I], ['(', ':', ' ', '<', '=']) then
      Exit(Copy(Result, 1, I - 1));
end;

function FindStructureItem(const Info: TPasUnitInfo; const Parts: TArray<string>; out Decl: TPasDecl): Boolean;
var
  Section, Name, Owner: string;
  Dot, Found: Integer;

  function Find(const Kinds: array of TPasDeclKind; const ASection: string): Integer;
  var
    I: Integer;
    K: TPasDeclKind;
  begin
    for I := 0 to High(Info.Decls) do
      for K in Kinds do
        if (Info.Decls[I].Kind = K) and SameText(Info.Decls[I].Name, Name) and SameText(Info.Decls[I].Parent, Owner) and
           ((ASection = '') or SameText(Info.Decls[I].Section, ASection)) then
          Exit(I);
    Result := -1;
  end;

begin
  Result := False;
  Decl := Default(TPasDecl);
  if Length(Parts) < 3 then
    Exit;
  Section := LowerCase(Parts[1]);
  Name := StructureCaptionName(Parts[High(Parts)]);
  if Length(Parts) >= 4 then
    Owner := StructureCaptionName(Parts[High(Parts) - 1]) // a member of a type
  else
  begin
    // "TOrder.Save" in the implementation section: the method of TOrder.
    Owner := '';
    Dot := Name.LastIndexOf('.');
    if Dot > 0 then
    begin
      Owner := Copy(Name, 1, Dot);
      Name := Copy(Name, Dot + 2, MaxInt);
    end;
  end;
  if (Section <> 'interface') and (Section <> 'implementation') then
    Section := '';
  // The body of a routine or method first, else the declaration (types span their whole block).
  Found := Find([pdMethodImpl, pdRoutine], 'implementation');
  if (Found < 0) and (Section <> 'implementation') then
    Found := Find([pdType, pdClass, pdRecord, pdInterface, pdEnum, pdRoutine, pdMethod, pdProperty, pdField, pdConst,
      pdVar, pdResourceString], Section);
  if Found < 0 then
    Found := Find([pdType, pdClass, pdRecord, pdInterface, pdEnum, pdRoutine, pdConst, pdVar, pdResourceString], '');
  Result := Found >= 0;
  if Result then
    Decl := Info.Decls[Found];
end;

function UnitOutlineText(const Info: TPasUnitInfo; const FileName: string; WithMembers: Boolean): string;
var
  SB: TStringBuilder;
  D: TPasDecl;
  Names: TStringList;
  Section, Kind: string;

  function Range(const X: TPasDecl): string;
  begin
    if X.EndLine > X.Line then
      Result := Format('[%d-%d]', [X.Line, X.EndLine])
    else
      Result := Format('[%d]', [X.Line]);
  end;

  procedure UsesLine(const Caption: string; const Items: TArray<TUsesEntry>);
  var
    E: TUsesEntry;
  begin
    if Length(Items) = 0 then
      Exit;
    Names.Clear;
    for E in Items do
      if E.InFile <> '' then
        Names.Add(E.Name + ' in ''' + E.InFile + '''')
      else
        Names.Add(E.Name);
    SB.Append(Caption).Append(': ').Append(string.Join(', ', Names.ToStringArray)).AppendLine;
  end;

begin
  SB := TStringBuilder.Create;
  Names := TStringList.Create;
  try
    Kind := Info.UnitKind;
    if Kind = '' then
      Kind := 'unit';
    SB.AppendFormat('%s %s (%s, %d lines)', [Kind, Info.UnitName,
      ExtractFileName(FileName), Info.LineCount]).AppendLine;
    if Info.UnitKind = 'unit' then
    begin
      UsesLine('uses (interface)', Info.IntfUses);
      UsesLine('uses (implementation)', Info.ImplUses);
    end
    else
      UsesLine('uses', Info.IntfUses + Info.ImplUses);
    Section := '';
    for D in Info.Decls do
    begin
      if D.Kind in [pdUnit, pdEnumValue] then
        Continue;
      if (D.Section <> Section) and (D.Section <> '') and (D.Section <> 'program') then
      begin
        Section := D.Section;
        SB.AppendLine.Append(Section).AppendLine;
      end;
      if D.Kind in [pdMethod, pdProperty, pdField] then
      begin
        if not WithMembers then
          Continue;
        SB.AppendFormat('    %s %s', [D.Visibility, D.Signature]);
        SB.Append('  ').Append(Range(D)).AppendLine;
        Continue;
      end;
      if (D.Kind in [pdType, pdClass, pdRecord, pdInterface, pdEnum, pdConst, pdVar, pdResourceString]) and
         (D.Parent <> '') then
      begin
        if WithMembers then
          SB.AppendFormat('    %s %s', [D.KindName, D.Signature]).Append('  ').Append(Range(D)).AppendLine;
        Continue;
      end;
      case D.Kind of
        pdClass, pdRecord, pdInterface, pdEnum, pdType:
          SB.Append('  type ').Append(D.Signature);
        pdConst, pdResourceString:
          SB.Append('  const ').Append(D.Signature);
        pdVar:
          SB.Append('  var ').Append(D.Signature);
      else
        SB.Append('  ').Append(D.Signature);
      end;
      SB.Append('  ').Append(Range(D)).AppendLine;
    end;
    Result := SB.ToString;
  finally
    Names.Free;
    SB.Free;
  end;
end;

initialization
  InitWords;
finalization
  Keywords.Free;
  RoutineDirectives.Free;
end.
