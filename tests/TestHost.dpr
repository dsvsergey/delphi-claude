program TestHost;

{ Runs the MCP/WebSocket server outside the IDE with a fake backend so the
  protocol layer can be exercised by tests/protocol-test.mjs. }

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.IOUtils,
  ClaudeCode.Utils, ClaudeCode.WebSocket, ClaudeCode.Diff, ClaudeCode.Mcp, ClaudeCode.Build,
  ClaudeCode.TextSync, ClaudeCode.ComponentProps, System.TypInfo, ClaudeCode.PascalIndex, ClaudeCode.TestRunner,
  ClaudeCode.ProjectMap, ClaudeCode.DbInfo, ClaudeCode.Modernize, ClaudeCode.Timeline,
  FakeBackend;

procedure Expect(Cond: Boolean; const What: string);
begin
  if not Cond then
    raise Exception.Create('Self-test failed: ' + What);
end;

procedure BuildParserSelfTest;
var
  M: TBuildMessage;
begin
  Expect(ParseBuildLine('C:\p\Unit1.pas(12,5): error E2003: Undeclared identifier: ''x'' [C:\p\P.dproj]', '', M),
    'msbuild error');
  Expect((M.FileName = 'C:\p\Unit1.pas') and (M.Line = 12) and (M.Column = 5) and (M.Severity = bsError) and
    (M.Code = 'E2003') and (M.Text = 'Undeclared identifier: ''x'''), 'msbuild error fields: ' + M.Text);
  Expect(ParseBuildLine('  Unit1.pas(30): warning W1036: Variable ''I'' might not have been initialized [C:\p\P.dproj]',
    'C:\p\', M), 'relative warning');
  Expect((M.FileName = 'C:\p\Unit1.pas') and (M.Line = 30) and (M.Column = 0) and (M.Severity = bsWarning),
    'relative warning fields: ' + M.FileName);
  Expect(ParseBuildLine('C:\p\U.pas(11): hint warning H2164: Variable ''Unused'' is declared but never used [C:\p\P.dproj]',
    '', M) and (M.Severity = bsHint) and (M.Code = 'H2164'), 'hint');
  Expect(ParseBuildLine('C:\p\U.pas(5) Fatal: F2613 Unit ''X'' not found.', '', M) and (M.Severity = bsFatal) and
    (M.Code = 'F2613') and (M.Line = 5), 'plain dcc fatal');
  Expect(ParseBuildLine('MSBUILD : error MSB1009: Project file does not exist.', '', M) and
    (M.FileName = '') and (M.Code = 'MSB1009') and (M.Severity = bsError), 'msbuild error without location');
  Expect(not ParseBuildLine('  BuildSample.dproj -> C:\p\BuildSample.exe', '', M), 'plain output line');
  Writeln('BUILD PARSER OK');
end;

{ Decodes like Node's Buffer.toString('utf8'): invalid bytes become U+FFFD. }
function LenientUtf8(const B: TBytes): string;
var
  N: Integer;
begin
  N := MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(@B[0]), Length(B), nil, 0);
  SetLength(Result, N);
  MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(@B[0]), Length(B), PChar(Result), N);
end;

procedure TextSyncSelfTest;
var
  Letters, Original, Edited, Seen, Restored: string;
  AnsiBytes, Fixed: TBytes;
  R, U: Integer;
  Span: TSpan;
  Old8, New8: TBytes;
begin
  // Non-ASCII letters of the current ANSI code page (cp1251 here: Cyrillic).
  Letters := TEncoding.ANSI.GetString(TBytes.Create($C0, $C1, $C2, $E0, $E1, $E2));
  Original := 'unit U;'#13#10'const S = ''' + Letters + ''';'#13#10'  X = 1; // ' + Letters + #13#10'end.'#13#10;
  AnsiBytes := TEncoding.ANSI.GetBytes(Original);
  Expect(DetectEncoding(AnsiBytes).IsAnsi, 'ANSI detected');
  Expect(DetectEncoding(TEncoding.UTF8.GetBytes(Original)).Kind = tekUtf8, 'UTF-8 detected');
  Expect(DetectEncoding(TEncoding.ASCII.GetBytes('abc')).Kind = tekAscii, 'ASCII detected');
  Expect(DecodeFileBytes(AnsiBytes) = Original, 'ANSI decoded');

  // What Claude sees (ANSI read as UTF-8) and writes back with one line changed.
  Seen := LenientUtf8(AnsiBytes);
  Expect(Pos(REPLACEMENT_CHAR, Seen) > 0, 'ANSI read as UTF-8 has U+FFFD');
  Edited := StringReplace(Seen, 'X = 1;', 'X = 2;', []);
  Restored := RestoreLostChars(Original, Edited, R, U);
  Expect(Restored = StringReplace(Original, 'X = 1;', 'X = 2;', []),
    Format('lost characters restored (%d restored, %d unresolved)', [R, U]));
  Expect((R = 2) and (U = 0), Format('restore counts %d/%d', [R, U]));
  // A run whose surroundings are not in the old text cannot be restored.
  RestoreLostChars(Original, Edited + 'Q := ''zz' + StringOfChar(REPLACEMENT_CHAR, 3) + 'qq'';'#13#10, R, U);
  Expect((R = 2) and (U = 1), Format('unresolved line counted %d/%d', [R, U]));

  Old8 := TEncoding.UTF8.GetBytes('abc' + Letters + 'xyz');
  New8 := TEncoding.UTF8.GetBytes('abc' + Letters + 'Qxyz');
  Span := ChangedSpanUtf8(Old8, New8);
  Expect((Span.Start = Length(TEncoding.UTF8.GetBytes('abc' + Letters))) and (Span.OldLen = 0) and
    (Span.NewLen = 1), 'insert span');
  // Replacing one multi-byte letter must not split its UTF-8 sequence.
  New8 := TEncoding.UTF8.GetBytes('abc' + Copy(Letters, 1, 2) + 'Z' + Copy(Letters, 4, MaxInt) + 'xyz');
  Span := ChangedSpanUtf8(Old8, New8);
  Expect((Span.Start = Length(TEncoding.UTF8.GetBytes('abc' + Copy(Letters, 1, 2)))) and
    (Span.OldLen = 2) and (Span.NewLen = 1), Format('replace span %d/%d/%d', [Span.Start, Span.OldLen, Span.NewLen]));
  Expect(ChangedSpanUtf8(Old8, Old8).IsEmpty, 'empty span');

  Expect(FixDelphiSourceEncoding(Original, DetectEncoding(TEncoding.UTF8.GetBytes(Original)),
    DetectEncoding(AnsiBytes), Fixed) and (DetectEncoding(Fixed).IsAnsi), 'UTF-8 back to ANSI');
  Expect(FixDelphiSourceEncoding(Original, DetectEncoding(TEncoding.UTF8.GetBytes(Original)),
    DetectEncoding(nil), Fixed) and (DetectEncoding(Fixed).Kind = tekUtf8Bom), 'new file gets a BOM');
  Expect(not FixDelphiSourceEncoding('abc', DetectEncoding(TEncoding.ASCII.GetBytes('abc')),
    DetectEncoding(AnsiBytes), Fixed), 'ASCII left alone');
  Writeln('TEXT SYNC OK');
end;

type
  TTestShade = type Integer; // an integer type with identifiers, like TColor
  TTestAlign = (taNone, taLeft, taClient);
  TTestOption = (toBold, toItalic, toUnderline);
  TTestOptions = set of TTestOption;

  TTestFont = class(TPersistent)
  private
    FSize: Integer;
    FName: string;
  published
    property Size: Integer read FSize write FSize;
    property Name: string read FName write FName;
  end;

  TTestThing = class(TComponent)
  private
    FCaption: string;
    FAlign: TTestAlign;
    FOptions: TTestOptions;
    FRatio: Double;
    FEnabled: Boolean;
    FShade: TTestShade;
    FFont: TTestFont;
    FItems: TStrings;
    FLink: TComponent;
    FOnChange: TNotifyEvent;
    procedure SetFont(Value: TTestFont);
    procedure SetItems(Value: TStrings);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property Caption: string read FCaption write FCaption;
    property Align: TTestAlign read FAlign write FAlign default taNone;
    property Options: TTestOptions read FOptions write FOptions default [];
    property Ratio: Double read FRatio write FRatio;
    property Enabled: Boolean read FEnabled write FEnabled default False;
    property Shade: TTestShade read FShade write FShade default 0;
    property Font: TTestFont read FFont write SetFont;
    property Items: TStrings read FItems write SetItems;
    property Link: TComponent read FLink write FLink;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

constructor TTestThing.Create(AOwner: TComponent);
begin
  inherited;
  FFont := TTestFont.Create;
  FItems := TStringList.Create;
end;

destructor TTestThing.Destroy;
begin
  FItems.Free;
  FFont.Free;
  inherited;
end;

procedure TTestThing.SetFont(Value: TTestFont);
begin
  FFont.Size := Value.Size;
  FFont.Name := Value.Name;
end;

procedure TTestThing.SetItems(Value: TStrings);
begin
  FItems.Assign(Value);
end;

const
  ShadeIdents: array[0..1] of TIdentMapEntry = ((Value: 255; Name: 'shRed'), (Value: 0; Name: 'shBlack'));

function ShadeToIdent(Int: Longint; var Ident: string): Boolean;
begin
  Result := IntToIdent(Int, Ident, ShadeIdents);
end;

function IdentToShade(const Ident: string; var Int: Longint): Boolean;
begin
  Result := IdentToInt(Ident, Int, ShadeIdents);
end;

type
  THandlerHost = class
    procedure Changed(Sender: TObject);
  end;

procedure THandlerHost.Changed(Sender: TObject);
begin
end;

procedure ComponentPropsSelfTest;
var
  Root: TComponent;
  A, B: TTestThing;
  Props: TJSONObject;
  Changes: TArray<TPropChange>;
  Errors: TArray<string>;
  Host: THandlerHost;
  Dfm, Block: string;
begin
  RegisterIntegerConsts(TypeInfo(TTestShade), IdentToShade, ShadeToIdent);
  Host := THandlerHost.Create;
  Root := TComponent.Create(nil);
  try
    Root.Name := 'Form1';
    A := TTestThing.Create(Root);
    A.Name := 'ThingA';
    B := TTestThing.Create(Root);
    B.Name := 'ThingB';
    Props := TJSONObject.ParseJSONValue(
      '{"Caption":"Привіт","Align":"taClient","Options":["toBold","toUnderline"],"Ratio":1.5,' +
      '"Enabled":true,"Shade":"shRed","Font.Size":12,"Font":{"Name":"Consolas"},' +
      '"Items":["one","two"],"Link":"ThingB","OnChange":"ThingAChange"}') as TJSONObject;
    try
      Errors := SetComponentProperties(Root, A, Props,
        function(const Name: string; TypeData: PTypeData): TMethod
        begin
          Expect(Name = 'ThingAChange', 'resolver gets the handler name');
          Result.Code := @THandlerHost.Changed;
          Result.Data := Host;
        end,
        function(const M: TMethod): string
        begin
          Result := 'ThingAChange';
        end, Changes);
    finally
      Props.Free;
    end;
    Expect(Length(Errors) = 0, 'no errors: ' + string.Join('; ', Errors));
    Expect((A.Caption = 'Привіт') and (A.Align = taClient) and (A.Options = [toBold, toUnderline]) and
      (A.Ratio = 1.5) and A.Enabled and (A.Shade = 255) and (A.Font.Size = 12) and (A.Font.Name = 'Consolas') and
      (A.Items.Count = 2) and (A.Items[1] = 'two') and (A.Link = B) and Assigned(A.OnChange), 'values applied');
    Expect(Length(Changes) = 11, Format('%d changes reported', [Length(Changes)]));

    Props := TJSONObject.ParseJSONValue(
      '{"Align":"taNowhere","Link":"Missing","Nope":1,"Font.Size":"big","Shade":"shBlack"}') as TJSONObject;
    try
      Errors := SetComponentProperties(Root, A, Props, nil, nil, Changes);
    finally
      Props.Free;
    end;
    Expect(Length(Errors) = 4, 'bad values reported: ' + string.Join('; ', Errors));
    Expect((A.Shade = 0) and (Length(Changes) = 1) and (Changes[0].OldValue = 'shRed') and
      (Changes[0].NewValue = 'shBlack'), 'valid values still applied, identifiers reported');

    Dfm := 'object Form1: TForm1'#13#10'  Caption = ''x'''#13#10'  object Panel1: TPanel'#13#10 +
      '    object Button1: TButton'#13#10'      Caption = ''OK'''#13#10'    end'#13#10'  end'#13#10'end'#13#10;
    Block := ExtractDfmObject(Dfm, 'Panel1');
    Expect(Block.StartsWith('  object Panel1: TPanel') and Block.Contains('Button1') and
      Block.TrimRight.EndsWith('  end'), 'DFM block extracted');
    Expect(ExtractDfmObject(Dfm, 'Button').IsEmpty, 'no partial name match');
    Expect(ComponentToDfm(B).StartsWith('object ThingB: TTestThing'), 'component streamed to DFM text');
  finally
    Root.Free;
    Host.Free;
  end;
  Writeln('COMPONENT PROPS OK');
end;

{ Builds tests\buildsample with MSBuild: once as is, once with a compile error. }
procedure BuildRunSelfTest;
var
  Req: TBuildRequest;
  R: TBuildResult;
  Src, Tmp, F, Code: string;
  M: TBuildMessage;
begin
  Src := TPath.Combine(ExtractFilePath(ParamStr(0)), 'buildsample');
  Tmp := TPath.Combine(TPath.GetTempPath, 'claude-build-test');
  if TDirectory.Exists(Tmp) then
    TDirectory.Delete(Tmp, True);
  TDirectory.CreateDirectory(Tmp);
  for F in ['BuildSample.dproj', 'BuildSample.dpr', 'SampleUnit.pas'] do
    TFile.Copy(TPath.Combine(Src, F), TPath.Combine(Tmp, F));

  Req.RsVars := GetEnvironmentVariable('BDS_RSVARS');
  if Req.RsVars = '' then
    Req.RsVars := 'd:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat';
  Req.ProjectFile := TPath.Combine(Tmp, 'BuildSample.dproj');
  Req.Target := 'Build';
  Req.Config := 'Debug';
  Req.Platform := 'Win32';
  Req.TimeoutSec := 300;

  R := RunBuild(Req, nil);
  Writeln('BUILD 1: exit ', R.ExitCode, ', ', Length(R.Messages), ' messages, ', R.ElapsedMs, ' ms');
  for M in R.Messages do
    Writeln('  ', SeverityNames[M.Severity], ' ', M.Code, ' ', ExtractFileName(M.FileName), ':', M.Line, ' ', M.Text);
  Expect(R.Error = '', 'build 1 ran: ' + R.Error);
  Expect(R.Success, 'build 1 succeeded'#13#10 + R.Output);
  Expect(R.Count(bsHint) >= 1, 'build 1 reports the unused variable hint');
  Expect(FileExists(TPath.Combine(Tmp, 'out\Win32\BuildSample.exe')), 'build 1 produced the exe');

  Code := TFile.ReadAllText(TPath.Combine(Tmp, 'SampleUnit.pas'));
  TFile.WriteAllText(TPath.Combine(Tmp, 'SampleUnit.pas'),
    StringReplace(Code, '{$IFDEF BREAK_BUILD}', '{$DEFINE BREAK_BUILD}{$IFDEF BREAK_BUILD}', []));
  Req.Target := 'Make';
  R := RunBuild(Req, nil);
  Writeln('BUILD 2: exit ', R.ExitCode, ', ', Length(R.Messages), ' messages, ', R.ElapsedMs, ' ms');
  for M in R.Messages do
    Writeln('  ', SeverityNames[M.Severity], ' ', M.Code, ' ', ExtractFileName(M.FileName), ':', M.Line, ' ', M.Text);
  Expect(not R.Success and (R.ExitCode <> 0), 'build 2 failed');
  Expect((Length(R.Messages) > 0) and (R.Messages[0].Severity >= bsError), 'build 2 lists the error first');
  Expect(SameText(ExtractFileName(R.Messages[0].FileName), 'SampleUnit.pas') and (R.Messages[0].Line = 14) and
    (R.Messages[0].Code = 'E2003'), 'build 2 error location');
  TDirectory.Delete(Tmp, True);
  Writeln('BUILD RUN OK');
end;


procedure DiffSelfTest;
var
  D: TDiffLines;
  S: string;
  L: TDiffLine;
  Hunks: TArray<THunk>;
  Pairs: TArray<Integer>;
  Accepted: TArray<Boolean>;
  InA, InB: TInlineRange;
begin
  D := ComputeLineDiff(SplitLines('a'#13#10'b'#13#10'c'#13#10'd'), SplitLines('a'#10'x'#10'c'#10'd'#10'e'#10));
  S := '';
  for L in D do
    case L.Kind of
      dkEqual: S := S + ' ' + L.Text;
      dkDelete: S := S + '-' + L.Text;
      dkInsert: S := S + '+' + L.Text;
    end;
  if S <> ' a-b+x c d+e' then
    raise Exception.Create('Diff self-test failed: ' + S);

  // Hunks, pairing, partial application and in-line change.
  Hunks := FindHunks(D);
  Expect(Length(Hunks) = 2, 'two hunks');
  Pairs := PairLines(D, Hunks);
  Expect((Pairs[1] = 2) and (Pairs[2] = 1) and (Pairs[5] = -1), 'b/x paired, e alone');
  Accepted := [True, True];
  Expect(ApplyHunks(D, Hunks, Accepted, #10, True) = 'a'#10'x'#10'c'#10'd'#10'e'#10, 'all hunks');
  Accepted := [False, True];
  Expect(ApplyHunks(D, Hunks, Accepted, #13#10, False) = 'a'#13#10'b'#13#10'c'#13#10'd'#13#10'e',
    'first hunk skipped');
  Accepted := [True, False];
  Expect(ApplyHunks(D, Hunks, Accepted, #10, True) = 'a'#10'x'#10'c'#10'd'#10, 'second hunk skipped');
  InlineChange('Result := Foo(1);', 'Result := Bar(1);', InA, InB);
  Expect((InA.Start = 11) and (InA.Len = 3) and (InB.Start = 11) and (InB.Len = 3), 'in-line change');
  InlineChange('abc', 'abXYc', InA, InB);
  Expect((InA.Start = 3) and (InA.Len = 0) and (InB.Start = 3) and (InB.Len = 2), 'in-line insertion');
  // A new routine after "end;": the inserted run is the whole routine, not "end; ... Result".
  D := ComputeLineDiff(['a', 'x', 'b', 'end;', '', 'g;'], ['a', 'y', 'b', 'end;', '', 'h;', 'end;', '', 'g;']);
  S := '';
  for L in D do
    case L.Kind of
      dkEqual: S := S + ' ' + L.Text + IntToStr(L.NewLine);
      dkDelete: S := S + '-' + L.Text + IntToStr(L.OldLine);
      dkInsert: S := S + '+' + L.Text + IntToStr(L.NewLine);
    end;
  Expect(S = ' a1-x2+y2 b3 end;4 5+h;6+end;7+8 g;9', 'inserted run slid to the routine: ' + S);
  Writeln('DIFF OK');
end;

{ RunInMainLoop posts window messages; a console host has to dispatch them. }
procedure PumpMessages;
var
  Msg: TMsg;
begin
  while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
  begin
    TranslateMessage(Msg);
    DispatchMessage(Msg);
  end;
end;

function FindDecl(const Info: TPasUnitInfo; const Qualified: string; Kind: TPasDeclKind; out D: TPasDecl): Boolean;
var
  X: TPasDecl;
begin
  for X in Info.Decls do
    if SameText(X.QualifiedName, Qualified) and (X.Kind = Kind) then
    begin
      D := X;
      Exit(True);
    end;
  Result := False;
end;

procedure PascalIndexSelfTest;
const
  Src =
    'unit Demo.Orders;'#13#10 +                                          // 1
    'interface'#13#10 +                                                  // 2
    'uses System.SysUtils, Vcl.Forms;'#13#10 +                           // 3
    'type'#13#10 +                                                       // 4
    '  TKind = (kNone, kBig = 5);'#13#10 +                               // 5
    '  TOrder = class(TPersistent, IInterface)'#13#10 +                  // 6
    '  private'#13#10 +                                                  // 7
    '    FTotal, FTax: Currency; // a comment with Save'#13#10 +         // 8
    '  public'#13#10 +                                                   // 9
    '    [Weak] FOwner: TObject;'#13#10 +                                // 10
    '    procedure Save(const Name: string = ''Save''); virtual;'#13#10 + // 11
    '    class function Create2: TOrder; static;'#13#10 +                // 12
    '    property Total: Currency read FTotal write FTotal;'#13#10 +     // 13
    '  end;'#13#10 +                                                     // 14
    '  TRec = packed record'#13#10 +                                     // 15
    '    case Tag: Integer of'#13#10 +                                   // 16
    '      0: (A: Integer);'#13#10 +                                     // 17
    '      1: (B: Double);'#13#10 +                                      // 18
    '  end;'#13#10 +                                                     // 19
    '  TList<T> = class end;'#13#10 +                                    // 20
    'const MaxOrders: Integer = 10;'#13#10 +                             // 21
    'function Helper(X: Integer): Integer;'#13#10 +                      // 22
    'implementation'#13#10 +                                             // 23
    'uses Data.DB;'#13#10 +                                              // 24
    'procedure TOrder.Save(const Name: string);'#13#10 +                 // 25
    'var I: Integer;'#13#10 +                                            // 26
    '  procedure Local; begin end;'#13#10 +                              // 27
    'begin'#13#10 +                                                      // 28
    '  case I of 1: begin end; end;'#13#10 +                             // 29
    '  try Self.Save(''x''); finally end;'#13#10 +                       // 30
    'end;'#13#10 +                                                       // 31
    'class function TOrder.Create2: TOrder; begin Result := nil; end;'#13#10 + // 32
    'function Helper(X: Integer): Integer;'#13#10 +                      // 33
    'begin'#13#10 +                                                      // 34
    '  Result := X; { Save } // Save'#13#10 +                            // 35
    'end;'#13#10 +                                                       // 36
    'end.'#13#10;
var
  Info: TPasUnitInfo;
  D: TPasDecl;
  Occ: TArray<TPasOccurrence>;
  Renamed, F, Text, Outline: string;
  Files, Units: Integer;
begin
  Info := ParsePascalUnit(Src);
  Expect((Info.UnitName = 'Demo.Orders') and (Info.UnitKind = 'unit') and (Info.LineCount = 37), 'unit header');
  Expect((Length(Info.IntfUses) = 2) and (Info.IntfUses[1].Name = 'Vcl.Forms') and (Length(Info.ImplUses) = 1),
    'uses clauses');
  Expect(FindDecl(Info, 'TOrder', pdClass, D) and (D.Line = 6) and (D.EndLine = 14) and
    (D.Ancestor = 'TPersistent, IInterface'), 'class range/ancestor: ' + D.Ancestor);
  Expect(FindDecl(Info, 'TOrder.FTax', pdField, D) and (D.Visibility = 'private'), 'field list');
  Expect(FindDecl(Info, 'TOrder.FOwner', pdField, D) and (D.Visibility = 'public'), 'field after attribute');
  Expect(FindDecl(Info, 'TOrder.Save', pdMethod, D) and (D.Line = 11) and
    D.Signature.StartsWith('procedure Save(const Name'), 'method decl: ' + D.Signature);
  Expect(FindDecl(Info, 'TOrder.Create2', pdMethod, D), 'class function decl');
  Expect(FindDecl(Info, 'TOrder.Total', pdProperty, D) and (D.Line = 13), 'property');
  Expect(FindDecl(Info, 'TKind', pdEnum, D) and FindDecl(Info, 'TKind.kBig', pdEnumValue, D), 'enum');
  Expect(FindDecl(Info, 'TRec', pdRecord, D) and (D.EndLine = 19) and FindDecl(Info, 'TRec.B', pdField, D),
    'variant record');
  Expect(FindDecl(Info, 'TList', pdClass, D) and (D.Line = 20), 'generic class');
  Expect(FindDecl(Info, 'MaxOrders', pdConst, D), 'typed const');
  Expect(FindDecl(Info, 'Helper', pdRoutine, D) and (D.Section = 'interface') and (D.Line = 22), 'routine decl');
  Expect(FindDecl(Info, 'TOrder.Save', pdMethodImpl, D) and (D.Line = 25) and (D.EndLine = 31) and
    (D.Section = 'implementation'), Format('method body %d-%d', [D.Line, D.EndLine]));
  Expect(FindDecl(Info, 'TOrder.Create2', pdMethodImpl, D) and (D.EndLine = 32), 'one-line body');
  Expect(not FindDecl(Info, 'Local', pdRoutine, D), 'nested routine not listed');
  Expect(not FindDecl(Info, 'I', pdVar, D), 'local var not listed');

  // Save: decl 11, impl 25, call 30; not in comments (8, 35) or strings (11's default value).
  Occ := FindOccurrences(Src, 'save');
  Expect(Length(Occ) = 3, Format('%d occurrences of Save', [Length(Occ)]));
  Expect((Occ[0].Line = 11) and (Occ[1].Line = 25) and (Occ[1].Qualifier = 'TOrder') and
    (Occ[2].Line = 30) and (Occ[2].Qualifier = 'Self'), 'occurrence lines and qualifiers');
  Renamed := ReplaceOccurrences(Src, Occ, 'Store');
  Expect((Length(FindOccurrences(Renamed, 'Save')) = 0) and (Length(FindOccurrences(Renamed, 'Store')) = 3) and
    Renamed.Contains('{ Save }') and Renamed.Contains('''Save'''), 'rename leaves comments and strings');
  Expect(SourceLine(Src, 25) = 'procedure TOrder.Save(const Name: string);', 'source line');
  Expect(IsValidIdentifier('Store') and not IsValidIdentifier('begin') and not IsValidIdentifier('1x'), 'identifiers');
  Outline := UnitOutlineText(Info, 'Demo.Orders.pas', True);
  Expect(Outline.Contains('procedure TOrder.Save(const Name: string);  [25-31]') and
    Outline.Contains('type TOrder = class(TPersistent, IInterface)  [6-14]'), 'outline:'#13#10 + Outline);

  // Every unit of this project parses into something sensible.
  Files := 0;
  Units := 0;
  for F in TDirectory.GetFiles(TPath.Combine(ExtractFilePath(ParamStr(0)), '..\src'), '*.pas') do
  begin
    Inc(Files);
    Text := TFile.ReadAllText(F);
    Info := ParsePascalUnit(Text);
    Expect(SameText(Info.UnitName + '.pas', ExtractFileName(F)), 'unit name of ' + F);
    for D in Info.Decls do
      Expect(D.EndLine >= D.Line, Format('%s: %s ends before it starts', [ExtractFileName(F), D.QualifiedName]));
    if FindDecl(Info, 'TMcpServer.Start', pdMethodImpl, D) then
      Inc(Units);
    if FindDecl(Info, 'TPasParser.Parse', pdMethodImpl, D) then
      Inc(Units);
  end;
  Expect((Files > 20) and (Units = 2), Format('project sources: %d files, %d probes', [Files, Units]));
  Writeln('PASCAL INDEX OK');
end;

procedure TestRunnerSelfTest;
const
  Xml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>'#13#10 +
    '<test-results name="T.exe" total="4" errors="1" failures="1">'#13#10 +
    '  <test-suite type="Assembly" name="T.exe" executed="true" result="Failure" success="False">'#13#10 +
    '    <results>'#13#10 +
    '      <test-suite type="Namespace" name="OrderTests" executed="true" result="Failure">'#13#10 +
    '        <results>'#13#10 +
    '          <test-suite type="Fixture" name="TOrderTests" executed="True" result="Failure">'#13#10 +
    '            <results>'#13#10 +
    '              <test-case name="EmptyOrderTotalIsZero" executed="True" result="Success" success="True" time="0.001" />'#13#10 +
    '              <test-case name="TotalAddsAllLines" executed="True" result="Failure" success="False" time="0.000">'#13#10 +
    '                <failure>'#13#10 +
    '                  <message><![CDATA[ Expected [10] equals actual [6] two lines ]]></message>'#13#10 +
    '                  <stack-trace><![CDATA[  ]]></stack-trace>'#13#10 +
    '                </failure>'#13#10 +
    '              </test-case>'#13#10 +
    '              <test-case name="Crashes" executed="True" result="Error" success="False">'#13#10 +
    '                <failure><message>EAccessViolation &amp; more &lt;x&gt;</message></failure>'#13#10 +
    '              </test-case>'#13#10 +
    '              <test-case name="Later" executed="False" result="Ignored"><reason><message>todo</message></reason></test-case>'#13#10 +
    '            </results>'#13#10 +
    '          </test-suite>'#13#10 +
    '        </results>'#13#10 +
    '      </test-suite>'#13#10 +
    '    </results>'#13#10 +
    '  </test-suite>'#13#10 +
    '</test-results>';
  Console =
    'DUnitX - [OrdersTests.exe] - Starting Tests.'#13#10#13#10'...F..'#13#10#13#10 +
    'Tests Found   : 3'#13#10'Tests Failed  : 1'#13#10#13#10'Failing Tests'#13#10#13#10 +
    '  OrderTests.TOrderTests.TotalAddsAllLines'#13#10'  Message: Expected [10] equals actual [6] two lines'#13#10#13#10;
var
  C: TArray<TTestCaseResult>;
begin
  C := ParseNUnitXml(Xml);
  Expect(Length(C) = 4, Format('%d test cases', [Length(C)]));
  Expect((C[0].Status = tsPassed) and (C[0].FullName = 'OrderTests.TOrderTests.EmptyOrderTotalIsZero'), 'passed case');
  Expect((C[1].Status = tsFailed) and (C[1].Message = 'Expected [10] equals actual [6] two lines') and
    (Trim(C[1].StackTrace) = ''), 'failed case: ' + C[1].Message);
  Expect((C[2].Status = tsError) and (C[2].Message = 'EAccessViolation & more <x>'), 'error case: ' + C[2].Message);
  Expect(C[3].Status = tsIgnored, 'ignored case');
  C := ParseDUnitXConsole(Console);
  Expect((Length(C) = 1) and (C[0].Fixture = 'TOrderTests') and (C[0].Name = 'TotalAddsAllLines') and
    (C[0].Namespace = 'OrderTests') and (C[0].Message = 'Expected [10] equals actual [6] two lines'), 'console failures');
  Expect(IsTestProjectSource('uses DUnitX.TestFramework, X;') and not IsTestProjectSource('uses Vcl.Forms;'),
    'test project detection');
  Writeln('TEST RUNNER OK');
end;

function Src(const FileName, Text: string): TMapSource;
begin
  Result.FileName := FileName;
  Result.Text := Text;
  Result.FormKind := '';
end;

procedure ProjectMapSelfTest;
var
  Map: TProjectMap;
  I: Integer;
begin
  Map := BuildProjectMap([
    Src('P.dpr', 'program P; uses A in ''A.pas'', B, C; begin end.'),
    Src('A.pas', 'unit A; interface uses System.SysUtils, B; implementation end.'),
    Src('B.pas', 'unit B; interface implementation uses A, C; end.'),
    Src('C.pas', 'unit C; interface type T = class end; implementation end.')]);
  Expect(Length(Map.Units) = 4, 'four units');
  I := Map.IndexOf('A');
  Expect((Length(Map.Units[I].IntfUses) = 1) and (Map.Units[I].ExternalUses = 1), 'A uses B and SysUtils');
  Expect((Length(Map.Cycles) = 1) and (Length(Map.Cycles[0]) = 2) and (Map.Units[I].Cycle = 0), 'A <-> B cycle');
  I := Map.IndexOf('C');
  Expect((Map.Units[I].Cycle = -1) and (Length(Map.Units[I].UsedBy) = 2) and (Map.Units[I].Types = 1),
    'C used by P and B, not in the cycle');
  Expect(Map.SummaryText(5).Contains('A <-> B'), 'summary lists the cycle');
  Writeln('PROJECT MAP OK');
end;

procedure DbInfoSelfTest;
const
  Dfm =
    'object DataOrders: TDataOrders'#13#10 +
    '  object Connection: TFDConnection'#13#10 +
    '    Params.Strings = ('#13#10 +
    '      ''Database=orders.db'''#13#10 +
    '      ''User_Name=sysdba'''#13#10 +
    '      ''Password=mast''''erkey'''#13#10 +
    '      ''DriverID=FB'')'#13#10 +
    '    LoginPrompt = False'#13#10 +
    '  end'#13#10 +
    '  object Query1: TFDQuery'#13#10 +
    '    Connection = Connection'#13#10 +
    '  end'#13#10 +
    'end'#13#10;
var
  C: TArray<TDfmConnection>;
  Why: string;
begin
  C := FindDfmConnections(Dfm);
  Expect((Length(C) = 1) and (C[0].Form = 'DataOrders') and (C[0].Name = 'Connection') and
    (Length(C[0].Params) = 4) and (C[0].Param('Password') = 'mast''erkey') and (C[0].Param('DriverID') = 'FB'),
    'DFM connection');
  Expect(C[0].SafeParams[2] = 'Password=***', 'password masked');
  Expect(IsReadOnlySql('select * from orders where status = ''delete'' -- update', Why), 'select with words in literals');
  Expect(IsReadOnlySql('  WITH t AS (SELECT 1 AS x) SELECT x FROM t;', Why), 'with select');
  Expect(IsReadOnlySql('select created_at, last_update from t order by id desc', Why), 'column names that contain keywords');
  Expect(not IsReadOnlySql('delete from orders', Why), 'delete refused');
  Expect(not IsReadOnlySql('with x as (select 1) delete from orders', Why), 'cte delete refused');
  Expect(not IsReadOnlySql('select 1; drop table orders', Why), 'two statements refused');
  Expect(not IsReadOnlySql('select * into backup from orders', Why), 'select into refused');
  Expect(not IsReadOnlySql('pragma journal_mode = off', Why) and IsReadOnlySql('pragma table_info(x)', Why) = False,
    'writing pragma refused');
  Writeln('DB INFO OK');
end;

procedure ModernizeSelfTest;
const
  Legacy =
    'unit Legacy;'#13#10 +
    'interface'#13#10 +
    'uses Windows, DBTables, SqlExpr;'#13#10 +
    'implementation'#13#10 +
    'procedure P(Wnd: HWND; S: string);'#13#10 +
    'var Buf: array[0..9] of Char; A: AnsiString;'#13#10 +
    'begin'#13#10 +
    '  SetWindowLong(Wnd, GWL_USERDATA, Integer(Pointer(Self)));'#13#10 +
    '  Move(S[1], Buf, Length(S));'#13#10 +
    '  // Integer(Pointer(X)) in a comment does not count'#13#10 +
    '  Writeln(''TTable in a string does not count'');'#13#10 +
    '  if S[1] in [''a''..''z''] then;'#13#10 +
    'end;'#13#10 +
    'end.'#13#10;
  LegacyDfm =
    'object Form1: TForm1'#13#10 +
    '  object Table1: TTable'#13#10 +
    '    TableName = ''TQuery'''#13#10 +
    '  end'#13#10 +
    'end'#13#10;
  Log =
    '--------------------------------2026/10/3 12:00:00--------------------------------'#13#10 +
    'A memory block has been leaked. The size is: 20'#13#10#13#10 +
    'This block was allocated by thread 0x1A2C, and the stack trace (return addresses) at the time was:'#13#10 +
    '406A2B [System.pas][System][@GetMem][4843]'#13#10 +
    '40A1F0 [System.pas][System][TObject.NewInstance][18000]'#13#10 +
    '4C1234 [OrderLogic.pas][OrderLogic][TOrder.Create][38]'#13#10 +
    '4C2234 [MainForm.pas][MainForm][TFormMain.FormCreate][31]'#13#10#13#10 +
    'The block is currently used for an object of class: TOrder'#13#10#13#10 +
    'Current memory dump of 256 bytes starting at pointer address 7FF8A0:'#13#10 +
    '--------------------------------2026/10/3 12:00:00--------------------------------'#13#10 +
    'A memory block has been leaked. The size is: 20'#13#10#13#10 +
    'This block was allocated by thread 0x1A2C, and the stack trace (return addresses) at the time was:'#13#10 +
    '4C1234 [OrderLogic.pas][OrderLogic][TOrder.Create][38]'#13#10#13#10 +
    'The block is currently used for an object of class: TOrder'#13#10 +
    '--------------------------------2026/10/3 12:00:00--------------------------------'#13#10 +
    'A memory block has been leaked. The size is: 36'#13#10#13#10 +
    'The block is currently used for an object of class: UnicodeString'#13#10;
var
  Sources: TArray<TModernSource>;
  S: TModernSource;
  Summary: TArray<TRuleSummary>;
  F: TArray<TFinding>;
  Leaks: TArray<TLeak>;

  function Count(const Rule: string): Integer;
  var
    R: TRuleSummary;
  begin
    Result := 0;
    for R in Summary do
      if R.Rule = Rule then
        Exit(R.Count);
  end;

begin
  S.FileName := 'C:pLegacy.pas';
  S.Text := Legacy;
  Sources := [S];
  S.FileName := 'C:pLegacy.dfm';
  S.Text := LegacyDfm;
  Sources := Sources + [S];
  F := AnalyzeSources(Sources, 'win64', Summary);
  Expect((Count('window-long') = 1) and (Count('pointer-to-int-cast') = 1), 'win64 findings');
  Expect(F[0].Line = 8, 'finding line');
  F := AnalyzeSources(Sources, 'unicode', Summary);
  Expect((Count('ansi-types') = 1) and (Count('byte-count-from-length') = 1) and (Count('char-set-in') = 1),
    'unicode findings');
  F := AnalyzeSources(Sources, 'bde', Summary);
  Expect((Count('bde-units') = 1) and (Count('dbx-units') = 1) and (Count('bde-components') = 1),
    Format('bde findings %d/%d/%d', [Count('bde-units'), Count('dbx-units'), Count('bde-components')]));
  Expect(FindingsText(Summary, F, 5, 'C:p').Contains('Legacy.dfm:2'), 'the form is reported');
  Leaks := ParseFastMMLog(Log);
  Expect((Length(Leaks) = 2) and (Leaks[0].ClassName = 'TOrder') and (Leaks[0].Count = 2) and
    (Leaks[0].TotalBytes = 40) and Leaks[0].Stack[0].Contains('TOrder.Create'), 'FastMM leaks grouped');
  Writeln('MODERNIZE OK');
end;

procedure TimelineSelfTest;
var
  Dir, A, B: string;
  TL: TTimeline;
  Plan: TArray<TRestore>;
  Add, Rem: Integer;

  function Hook(const Event, Extra: string): string;
  begin
    Result := '{"session_id":"s1","cwd":' + TJSONString.Create(Dir).ToJSON + ',"hook_event_name":"' + Event + '"' +
      Extra + '}';
  end;

  function Edit(const FileName: string): string;
  begin
    Result := Hook('PreToolUse', ',"tool_name":"Edit","tool_input":{"file_path":' +
      TJSONString.Create(FileName).ToJSON + '}');
  end;

begin
  Dir := TPath.Combine(TPath.GetTempPath, 'claude-timeline-test');
  TDirectory.CreateDirectory(Dir);
  A := TPath.Combine(Dir, 'A.pas');
  B := TPath.Combine(Dir, 'B.pas');
  System.SysUtils.DeleteFile(B);
  TFile.WriteAllText(A, 'v1'#13#10);
  TL := TTimeline.Create;
  try
    // Turn 1 edits A twice: the snapshot is from before the first edit.
    TL.HandleHook(Hook('UserPromptSubmit', ',"prompt":"rename things"'));
    TL.HandleHook(Edit(A));
    TFile.WriteAllText(A, 'v2'#13#10);
    TL.HandleHook(Edit(A));
    TFile.WriteAllText(A, 'v2'#13#10'more'#13#10);
    TL.HandleHook(Hook('Stop', ''));
    // Turn 2 edits A again and creates B (a relative path, from the session folder).
    TL.HandleHook(Hook('UserPromptSubmit', ',"prompt":"add B"'));
    TL.HandleHook(Edit(A));
    TFile.WriteAllText(A, 'v3'#13#10);
    TL.HandleHook(Hook('PreToolUse', ',"tool_name":"Write","tool_input":{"file_path":"B.pas"}'));
    TFile.WriteAllText(B, 'new'#13#10);
    TL.HandleHook(Hook('Read', ''));
    TL.HandleHook(Hook('Stop', ''));
    Expect((TL.Count = 2) and (TL.Turn(0).Prompt = 'rename things') and (TL.Turn(0).Files.Count = 1) and
      (TL.Turn(1).Files.Count = 2) and not TL.Turn(1).Running, 'turns and files');
    Expect(TEncoding.ANSI.GetString(TL.Turn(0).Files[0].Before) = 'v1'#13#10, 'turn 1 keeps the first version');
    LineChanges(TL.Turn(0).Files[0].Before, TL.Turn(0).Files[0].After, Add, Rem);
    Expect((Add = 2) and (Rem = 1), Format('turn 1 line changes +%d -%d', [Add, Rem]));
    Plan := TL.RewindPlan(1);
    Expect((Length(Plan) = 2) and (TEncoding.ANSI.GetString(Plan[0].Bytes) = 'v2'#13#10'more'#13#10) and
      Plan[1].Delete and SameText(Plan[1].FileName, B), 'rewind to before turn 2');
    Plan := TL.RewindPlan(0);
    Expect((Length(Plan) = 2) and (TEncoding.ANSI.GetString(Plan[0].Bytes) = 'v1'#13#10), 'rewind to before turn 1');
    TL.DropFrom(1);
    Expect(TL.Count = 1, 'later turns dropped');
  finally
    TL.Free;
    TDirectory.Delete(Dir, True);
  end;
  Writeln('TIMELINE OK');
end;

procedure ConversationSelfTest;
var
  Dir, Old: string;
begin
  // --continue only where Claude Code has a conversation for the folder.
  Dir := TPath.Combine(TPath.GetTempPath, 'cc-conv-' + IntToStr(GetTickCount));
  Old := GetEnvironmentVariable('CLAUDE_CONFIG_DIR');
  SetEnvironmentVariable('CLAUDE_CONFIG_DIR', PChar(Dir));
  try
    ForceDirectories(TPath.Combine(Dir, 'projects\D--nprojects-delphi-claude'));
    TFile.WriteAllText(TPath.Combine(Dir, 'projects\D--nprojects-delphi-claude\s.jsonl'),
      '{"type":"user","entrypoint":"cli","cwd":"x"}'#10);
    ForceDirectories(TPath.Combine(Dir, 'projects\D--empty'));
    ForceDirectories(TPath.Combine(Dir, 'projects\D--sdk'));
    TFile.WriteAllText(TPath.Combine(Dir, 'projects\D--sdk\p.jsonl'), '{"type":"user","entrypoint":"sdk-ts"}'#10);
    Expect(HasClaudeConversation('D:\nprojects\delphi-claude'), 'conversation of a folder');
    Expect(HasClaudeConversation('D:\nprojects\delphi-claude\'), 'trailing backslash');
    Expect(not HasClaudeConversation('D:\nprojects\delphi'), 'other folder');
    Expect(not HasClaudeConversation('D:\empty'), 'folder without conversations');
    Expect(not HasClaudeConversation('D:\sdk'), 'claude -p sessions do not count');
  finally
    if Old = '' then
      SetEnvironmentVariable('CLAUDE_CONFIG_DIR', nil)
    else
      SetEnvironmentVariable('CLAUDE_CONFIG_DIR', PChar(Old));
    TDirectory.Delete(Dir, True);
  end;
  Writeln('CONVERSATION OK');
end;

var
  Mcp: TMcpServer;
  Deadline: TDateTime;
  Token, LockText: string;
begin
  try
    DiffSelfTest;
    BuildParserSelfTest;
    TextSyncSelfTest;
    ComponentPropsSelfTest;
    PascalIndexSelfTest;
    TestRunnerSelfTest;
    ProjectMapSelfTest;
    DbInfoSelfTest;
    ModernizeSelfTest;
    TimelineSelfTest;
    ConversationSelfTest;
    if SameText(ParamStr(1), 'build') then
    begin
      BuildRunSelfTest;
      Exit;
    end;
    LogProc := procedure(const Msg: string) begin Writeln('LOG ', Msg); end;
    Mcp := TMcpServer.Create(TFakeBackend.Create(GetCurrentDir));
    Mcp.OnHook := procedure(Json: string) begin Writeln('HOOK ', Json); Flush(Output); end;
    Mcp.Start;
    ReadTextFileAutoEnc(Mcp.LockFile, LockText);
    Token := (TJSONObject.ParseJSONValue(LockText) as TJSONObject).GetValue<string>('authToken');
    Writeln('PORT ', Mcp.Port);
    Writeln('TOKEN ', Token);
    Writeln('LOCK ', Mcp.LockFile);
    Flush(Output);
    Deadline := Now + StrToIntDef(ParamStr(1), 20) / SecsPerDay;
    while Now < Deadline do
    begin
      CheckSynchronize(50);
      PumpMessages;
      if FileExists(ChangeFileExt(ParamStr(0), '.stop')) then
        Break;
    end;
    // Push a notification to whoever is still connected, then shut down.
    Mcp.Notify('selection_changed', TJSONObject.Create.AddPair('text', 'bye'));
    Mcp.Stop;
    Writeln('LOCK_DELETED ', not FileExists(Mcp.LockFile));
    Mcp.Free;
  except
    on E: Exception do
    begin
      Writeln('ERROR ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
