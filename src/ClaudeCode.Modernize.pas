unit ClaudeCode.Modernize;

{ Static checks for modernizing Delphi code, and FastMM memory leak reports.
  Scenarios:
  - win64:   pointer/handle casts to 32-bit integers, GetWindowLong & co, inline assembler, Extended;
  - unicode: AnsiString/PAnsiChar/ShortString use, byte counts taken from string lengths, StrPas & co;
  - bde:     BDE, dbExpress and ADO units and components, with their FireDAC replacements.
  Code is checked with comments and string literals blanked out, so they never match.
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TModernSource = record
    FileName: string;
    Text: string;
  end;

  TFinding = record
    Rule: string;
    FileName: string;
    Line: Integer;
    Code: string; // the source line, trimmed
  end;

  TRuleSummary = record
    Rule: string;
    Advice: string;
    Count: Integer;
  end;

  TLeak = record
    ClassName: string; // or "Unknown" for raw blocks
    Count: Integer;
    TotalBytes: Int64;
    Stack: TArray<string>; // allocation stack of the first block, application frames first
  end;

const
  MODERNIZE_SCENARIOS = 'win64, unicode, bde';

{ Findings of one scenario; Summary has one entry per rule that matched, most frequent first. }
function AnalyzeSources(const Sources: TArray<TModernSource>; const Scenario: string;
  out Summary: TArray<TRuleSummary>): TArray<TFinding>;
function FindingsText(const Summary: TArray<TRuleSummary>; const Findings: TArray<TFinding>;
  MaxPerRule: Integer; const BaseDir: string): string;
function IsKnownScenario(const Scenario: string): Boolean;

{ Leaks in a FastMM4/FastMM5 event log (…_MemoryManager_EventLog.txt), grouped by class. }
function ParseFastMMLog(const Text: string): TArray<TLeak>;
function LeaksText(const Leaks: TArray<TLeak>): string;

implementation

uses
  System.RegularExpressions, System.Math, System.Generics.Defaults, ClaudeCode.PascalIndex;

type
  TRule = record
    Id: string;
    Scenario: string;
    Pattern: string;  // regex on code with comments/strings blanked
    Advice: string;
    FormsToo: Boolean; // also checked in .dfm/.fmx
  end;

var
  Rules: TArray<TRule>;
  Compiled: TArray<TRegEx>;

procedure AddRule(const Id, Scenario, Pattern, Advice: string; FormsToo: Boolean = False);
var
  R: TRule;
begin
  R.Id := Id;
  R.Scenario := Scenario;
  R.Pattern := Pattern;
  R.Advice := Advice;
  R.FormsToo := FormsToo;
  Rules := Rules + [R];
  Compiled := Compiled + [TRegEx.Create(Pattern, [roIgnoreCase])];
end;

procedure InitRules;
begin
  // Win64
  AddRule('pointer-to-int-cast', 'win64',
    '\b(Integer|Cardinal|LongInt|LongWord|DWORD|DWord)\s*\(\s*(Pointer\s*\(|@|Self\b|Sender\b|\w*Handle\b|\w*Wnd\b|\w*Obj\w*\b|\w*\.Data\b|\w+\.Objects\[)',
    'A pointer, object or handle cast to a 32-bit integer loses the upper half on Win64. Use NativeInt/NativeUInt ' +
    '(or THandle/HWND/LPARAM/WPARAM) for values that hold addresses.');
  AddRule('int-to-pointer-cast', 'win64',
    '\b(Pointer|TObject|T\w+)\s*\(\s*(Integer|Cardinal|LongInt|LongWord|DWORD)\s*\(',
    'An integer turned into a pointer/object was probably a truncated pointer before: keep it NativeInt.');
  AddRule('window-long', 'win64', '\b(Get|Set)(Window|Class)Long[AW]?\s*\(',
    'GetWindowLong/SetWindowLong (and ClassLong) cannot store pointers on Win64: use the ...LongPtr functions ' +
    'with GWLP_/GCLP_ indexes and NativeInt values.');
  AddRule('message-param-cast', 'win64', '\b(Integer|Cardinal|LongInt)\s*\(\s*(\w+\.)?(WParam|LParam|lParam|wParam)\b',
    'WPARAM/LPARAM are pointer-sized on Win64; casting them to 32-bit integers truncates pointers passed in messages.');
  AddRule('inline-asm', 'win64', '\basm\b',
    'Win64 supports only routines written entirely in assembler (no asm blocks inside Pascal code), with the ' +
    'x64 calling convention. Replace with Pascal or provide a {$IFDEF CPUX64} version.');
  AddRule('extended', 'win64', '\bExtended\b',
    'Extended is 8 bytes (= Double) on Win64, 10 bytes on Win32: binary files/records with Extended change size ' +
    'and precision differs.');
  AddRule('sizeof-pointer-4', 'win64', '\b(SizeOf\s*\(\s*(Pointer|TObject|NativeInt)\s*\)\s*=\s*4|4\s*=\s*SizeOf\s*\(\s*Pointer)',
    'Code that assumes 4-byte pointers.');
  // Unicode
  AddRule('ansi-types', 'unicode', '\b(AnsiString|AnsiChar|PAnsiChar|RawByteString|UTF8String|WideString)\b',
    'Explicit 8-bit/COM string types: right for byte data, APIs and files with a known encoding; elsewhere use ' +
    'string/Char. Conversions to and from string are implicit and may lose characters (W1057/W1058).');
  AddRule('short-string', 'unicode', '\b(ShortString\b|string\s*\[\s*\d+\s*\])',
    'ShortString holds AnsiChars: non-ASCII text is converted through the ANSI code page.');
  AddRule('byte-count-from-length', 'unicode',
    '\b(Move|CopyMemory|FillChar|ZeroMemory|BlockRead|BlockWrite|Read|Write|ReadBuffer|WriteBuffer)\s*\(.*\bLength\s*\((?!.*SizeOf\s*\(\s*(Char|WideChar)\s*\))',
    'A byte count taken from Length() of a string: since Delphi 2009 a Char is 2 bytes. Use ' +
    'Length(S) * SizeOf(Char) or ByteLength(S).');
  AddRule('str-functions', 'unicode', '\b(StrPas|StrPCopy|StrPLCopy|StrLCopy|StrCopy|StrLen|StrComp|StrIComp)\s*\(',
    'PChar helpers: check that buffers are sized in Chars, not bytes, and that PAnsiChar/PChar are not mixed.');
  // String literals are blanked: in ['a'..'z'] reads as "in [   ..   ]".
  AddRule('char-set-in', 'unicode', '\b\w+(\[\w+\])?\s+in\s*\[\s+(\.\.|,|\])',
    'Char in [...] sets only work for AnsiChar ranges (W1050): use CharInSet or Char helpers (IsLetter, ...).');
  AddRule('ansi-api', 'unicode', '\b\w+A\s*\(\s*PAnsiChar\s*\(',
    'An explicit ANSI Windows API call: use the W/default version with string/PChar.');
  // BDE / dbExpress / ADO -> FireDAC
  AddRule('bde-units', 'bde', '\b(DBTables|Bde\.DBTables|BDE|DbiProcs|DbiTypes|DbiErrs|BdeConst)\b',
    'BDE units: the BDE is deprecated and 32-bit only. Replace with FireDAC (FireDAC.Comp.Client, ' +
    'FireDAC.Stan.*, FireDAC.Phys.<driver>).');
  AddRule('dbx-units', 'bde', '\b(SqlExpr|Data\.SqlExpr|DBXCommon|Data\.DBXCommon|DBXpress|SimpleDS|Data\.DBXInterBase|Data\.DBXMSSQL|Data\.DBXFirebird|Data\.DBXOracle|Data\.DBXMySQL)\b',
    'dbExpress units: replace with FireDAC.');
  AddRule('ado-units', 'bde', '\b(ADODB|Data\.Win\.ADODB)\b',
    'ADO (dbGo) units: FireDAC replaces them with native drivers (MSSQL, ODBC...).');
  AddRule('bde-components', 'bde',
    '\b(TTable|TQuery|TDatabase|TSession|TStoredProc|TUpdateSQL|TBatchMove|TBDEDataSet|TDBDataSet)\b',
    'BDE components -> FireDAC: TDatabase -> TFDConnection, TTable -> TFDTable, TQuery -> TFDQuery, ' +
    'TStoredProc -> TFDStoredProc, TUpdateSQL -> TFDUpdateSQL, TBatchMove -> TFDBatchMove, TSession -> ' +
    'TFDManager. Params use :Name the same way; DatabaseName becomes Connection.', True);
  AddRule('dbx-components', 'bde',
    '\b(TSQLConnection|TSQLQuery|TSQLTable|TSQLDataSet|TSQLStoredProc|TSimpleDataSet)\b',
    'dbExpress components -> FireDAC: TSQLConnection -> TFDConnection, TSQLQuery/TSQLDataSet -> TFDQuery, ' +
    'TSQLTable -> TFDTable, TSQLStoredProc -> TFDStoredProc, TSimpleDataSet -> TFDQuery (cached updates). A ' +
    'TDataSetProvider + TClientDataSet pair over them can often become one TFDQuery.', True);
  AddRule('ado-components', 'bde',
    '\b(TADOConnection|TADOQuery|TADOTable|TADOStoredProc|TADOCommand|TADODataSet)\b',
    'ADO components -> FireDAC: TADOConnection -> TFDConnection, TADOQuery/TADODataSet -> TFDQuery, ' +
    'TADOTable -> TFDTable, TADOStoredProc -> TFDStoredProc, TADOCommand -> TFDCommand.', True);
end;

function IsKnownScenario(const Scenario: string): Boolean;
var
  R: TRule;
begin
  for R in Rules do
    if SameText(R.Scenario, Scenario) then
      Exit(True);
  Result := False;
end;

{ Text with comments, directives and string literals replaced by spaces (line breaks kept). }
function CodeOnly(const Src: string): string;
var
  Toks: TArray<TPasToken>;
  T: TPasToken;
  I: Integer;
begin
  Result := Src;
  UniqueString(Result);
  Toks := TokenizePascal(Src, True);
  for T in Toks do
    if T.Kind in [ptComment, ptDirective, ptString] then
      for I := T.Pos to T.Pos + T.Len - 1 do
        if not CharInSet(Result[I], [#10, #13]) then
          Result[I] := ' ';
end;

{ DFM text: only "object Name: TClass" lines matter. }
function FormObjectLines(const Src: string): string;
var
  L: TStringList;
  I: Integer;
  T: string;
begin
  L := TStringList.Create;
  try
    L.Text := Src;
    for I := 0 to L.Count - 1 do
    begin
      T := TrimLeft(L[I]);
      if not (T.StartsWith('object ', True) or T.StartsWith('inherited ', True) or T.StartsWith('inline ', True)) then
        L[I] := '';
    end;
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function AnalyzeSources(const Sources: TArray<TModernSource>; const Scenario: string;
  out Summary: TArray<TRuleSummary>): TArray<TFinding>;
var
  S: TModernSource;
  Lines, Orig: TStringList;
  IsForm: Boolean;
  I, R, N: Integer;
  F: TFinding;
  L: TList<TFinding>;
  Counts: TDictionary<string, Integer>;
  RS: TRuleSummary;
  SL: TList<TRuleSummary>;
  Ext: string;
begin
  L := TList<TFinding>.Create;
  Counts := TDictionary<string, Integer>.Create;
  Lines := TStringList.Create;
  Orig := TStringList.Create;
  try
    for S in Sources do
    begin
      Ext := LowerCase(ExtractFileExt(S.FileName));
      IsForm := (Ext = '.dfm') or (Ext = '.fmx');
      if IsForm then
        Lines.Text := FormObjectLines(S.Text)
      else
        Lines.Text := CodeOnly(S.Text);
      Orig.Text := S.Text;
      for I := 0 to Lines.Count - 1 do
      begin
        if Trim(Lines[I]) = '' then
          Continue;
        for R := 0 to High(Rules) do
        begin
          if not SameText(Rules[R].Scenario, Scenario) or (IsForm and not Rules[R].FormsToo) then
            Continue;
          if Compiled[R].IsMatch(Lines[I]) then
          begin
            F.Rule := Rules[R].Id;
            F.FileName := S.FileName;
            F.Line := I + 1;
            if I < Orig.Count then
              F.Code := Trim(Orig[I])
            else
              F.Code := Trim(Lines[I]);
            L.Add(F);
            if Counts.TryGetValue(F.Rule, N) then
              Counts[F.Rule] := N + 1
            else
              Counts.Add(F.Rule, 1);
          end;
        end;
      end;
    end;
    SL := TList<TRuleSummary>.Create;
    try
      for R := 0 to High(Rules) do
        if Counts.ContainsKey(Rules[R].Id) then
        begin
          RS.Rule := Rules[R].Id;
          RS.Advice := Rules[R].Advice;
          RS.Count := Counts[Rules[R].Id];
          SL.Add(RS);
        end;
      SL.Sort(TComparer<TRuleSummary>.Construct(
        function(const A, B: TRuleSummary): Integer
        begin
          Result := B.Count - A.Count;
        end));
      Summary := SL.ToArray;
    finally
      SL.Free;
    end;
    Result := L.ToArray;
  finally
    Orig.Free;
    Lines.Free;
    Counts.Free;
    L.Free;
  end;
end;

function FindingsText(const Summary: TArray<TRuleSummary>; const Findings: TArray<TFinding>;
  MaxPerRule: Integer; const BaseDir: string): string;
var
  SB: TStringBuilder;
  RS: TRuleSummary;
  F: TFinding;
  N, Total: Integer;
  Files: TDictionary<string, Boolean>;
  Name: string;
begin
  SB := TStringBuilder.Create;
  Files := TDictionary<string, Boolean>.Create;
  try
    Total := 0;
    for F in Findings do
      Files.AddOrSetValue(LowerCase(F.FileName), True);
    for RS in Summary do
      Inc(Total, RS.Count);
    SB.AppendFormat('%d finding(s) of %d kind(s) in %d file(s)', [Total, Length(Summary), Files.Count]).AppendLine;
    for RS in Summary do
    begin
      SB.AppendLine.AppendFormat('== %s: %d', [RS.Rule, RS.Count]).AppendLine;
      SB.Append(RS.Advice).AppendLine;
      N := 0;
      for F in Findings do
        if F.Rule = RS.Rule then
        begin
          if N >= MaxPerRule then
          begin
            SB.AppendFormat('  ... %d more', [RS.Count - N]).AppendLine;
            Break;
          end;
          Name := F.FileName;
          if (BaseDir <> '') and SameText(Copy(Name, 1, Length(BaseDir)), BaseDir) then
            Name := Copy(Name, Length(BaseDir) + 1, MaxInt);
          SB.AppendFormat('  %s:%d  %s', [Name, F.Line, Copy(F.Code, 1, 160)]).AppendLine;
          Inc(N);
        end;
    end;
    Result := SB.ToString;
  finally
    Files.Free;
    SB.Free;
  end;
end;

{ FastMM }

function IsRuntimeFrame(const Frame: string): Boolean;
var
  L: string;
begin
  L := LowerCase(Frame);
  Result := L.Contains('[system.pas]') or L.Contains('[fastmm') or L.Contains('[system.sysutils') or
    L.Contains('[system.classes') or L.Contains('@getmem') or L.Contains('@newunicodestring') or
    L.Contains('[system.getmemory') or L.Contains('[system][@') or L.Contains('tobject.newinstance') or
    L.Contains('@classcreate') or L.Contains('[kernel') or L.Contains('[ntdll');
end;

function ParseFastMMLog(const Text: string): TArray<TLeak>;
var
  Lines: TStringList;
  I, Size: Integer;
  T, Cls: string;
  Stack, App: TArray<string>;
  InStack: Boolean;
  Map: TDictionary<string, Integer>;
  L: TList<TLeak>;
  Leak: TLeak;
  M: TMatch;

  procedure Flush;
  var
    K: Integer;
    Fr: string;
  begin
    if Size < 0 then
      Exit;
    if Cls = '' then
      Cls := 'Unknown (not an object)';
    if not Map.TryGetValue(Cls, K) then
    begin
      Leak := Default(TLeak);
      Leak.ClassName := Cls;
      App := nil;
      for Fr in Stack do
        if not IsRuntimeFrame(Fr) then
          App := App + [Fr];
      Leak.Stack := Copy(App, 0, 8);
      if Length(Leak.Stack) = 0 then
        Leak.Stack := Copy(Stack, 0, 8);
      K := L.Add(Leak);
      Map.Add(Cls, K);
    end;
    Leak := L[K];
    Inc(Leak.Count);
    Inc(Leak.TotalBytes, Size);
    L[K] := Leak;
    Size := -1;
  end;

begin
  Map := TDictionary<string, Integer>.Create;
  L := TList<TLeak>.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    Size := -1;
    Cls := '';
    Stack := nil;
    InStack := False;
    for I := 0 to Lines.Count - 1 do
    begin
      T := Trim(Lines[I]);
      M := TRegEx.Match(T, 'A memory block has been leaked\. The size is:\s*(\d+)', [roIgnoreCase]);
      if M.Success then
      begin
        Flush;
        Size := StrToIntDef(M.Groups[1].Value, 0);
        Cls := '';
        Stack := nil;
        InStack := False;
        Continue;
      end;
      if Size < 0 then
        Continue;
      if T.StartsWith('This block was allocated by thread', True) then
      begin
        InStack := True;
        Continue;
      end;
      M := TRegEx.Match(T, 'The block is currently used for an object of class:\s*(.+)$', [roIgnoreCase]);
      if M.Success then
      begin
        Cls := Trim(M.Groups[1].Value);
        Continue;
      end;
      if InStack then
      begin
        if (T = '') or T.StartsWith('The ', True) or T.StartsWith('Current memory dump', True) then
          InStack := False
        else
          Stack := Stack + [T];
      end;
    end;
    Flush;
    Result := L.ToArray;
    TArray.Sort<TLeak>(Result, TComparer<TLeak>.Construct(
      function(const A, B: TLeak): Integer
      begin
        Result := B.Count - A.Count;
      end));
  finally
    Lines.Free;
    L.Free;
    Map.Free;
  end;
end;

function LeaksText(const Leaks: TArray<TLeak>): string;
var
  SB: TStringBuilder;
  Lk: TLeak;
  Fr: string;
  Blocks: Integer;
begin
  SB := TStringBuilder.Create;
  try
    Blocks := 0;
    for Lk in Leaks do
      Inc(Blocks, Lk.Count);
    SB.AppendFormat('%d leaked block(s) of %d kind(s)', [Blocks, Length(Leaks)]).AppendLine;
    for Lk in Leaks do
    begin
      SB.AppendLine.AppendFormat('%s x %d (%d bytes)', [Lk.ClassName, Lk.Count, Lk.TotalBytes]).AppendLine;
      if Length(Lk.Stack) > 0 then
      begin
        SB.Append('  allocated at (first block):').AppendLine;
        for Fr in Lk.Stack do
          SB.Append('    ').Append(Fr).AppendLine;
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

initialization
  InitRules;
end.
