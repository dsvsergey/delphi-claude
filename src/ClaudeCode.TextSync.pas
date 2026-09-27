unit ClaudeCode.TextSync;

{ Text helpers for keeping the editor and files on disk in sync with Claude's edits:
  - file encoding detection (ANSI vs UTF-8, BOM);
  - restoring characters Claude lost when it read an ANSI (e.g. cp1251) file as UTF-8;
  - the smallest changed span between two texts, so the editor buffer is patched, not replaced.
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils;

type
  TTextEncodingKind = (tekEmpty, tekAscii, tekUtf8, tekUtf8Bom, tekUtf16, tekAnsi);

  TEncodingInfo = record
    Kind: TTextEncodingKind;
    function IsAnsi: Boolean;
    function Name: string;
  end;

  TSpan = record
    Start: Integer;  // 0-based offset of the first differing unit
    OldLen: Integer; // units to delete from the old text
    NewLen: Integer; // units to insert from the new text
    function IsEmpty: Boolean;
  end;

const
  REPLACEMENT_CHAR = #$FFFD;

function DetectEncoding(const Bytes: TBytes): TEncodingInfo;
function DetectFileEncoding(const FileName: string): TEncodingInfo;
{ Reads a file that another process may still have open. }
function ReadFileBytes(const FileName: string; out Bytes: TBytes): Boolean;
{ Decodes file bytes the way the IDE does: BOM, then strict UTF-8, then the ANSI code page. }
function DecodeFileBytes(const Bytes: TBytes): string;

{ For every line of NewText that contains U+FFFD, looks for a line of OldText that is the same
  once its non-ASCII characters are masked as U+FFFD and puts the original line back.
  Restored counts repaired lines, Unresolved counts lines that still contain U+FFFD. }
function RestoreLostChars(const OldText, NewText: string; out Restored, Unresolved: Integer): string;

{ Common prefix/suffix of two byte strings; never splits a UTF-8 sequence. }
function ChangedSpanUtf8(const OldBytes, NewBytes: TBytes): TSpan;

function NormalizeToCrLf(const S: string): string;

{ UTF-8 without a BOM is read as ANSI by the Delphi compiler. Encodes Text for a Delphi source
  file whose previous encoding was Previous: ANSI stays ANSI when every character fits the code
  page, anything else non-ASCII gets a UTF-8 BOM. Returns False when the bytes on disk can stay. }
function FixDelphiSourceEncoding(const Text: string; const OnDisk, Previous: TEncodingInfo;
  out Bytes: TBytes): Boolean;
function IsDelphiSourceFile(const FileName: string): Boolean;

implementation

uses
  Winapi.Windows, System.Classes, System.Generics.Collections;

{ TEncodingInfo }

function TEncodingInfo.IsAnsi: Boolean;
begin
  Result := Kind = tekAnsi;
end;

function TEncodingInfo.Name: string;
const
  Names: array[TTextEncodingKind] of string = ('empty', 'ASCII', 'UTF-8', 'UTF-8 with BOM', 'UTF-16', 'ANSI');
begin
  Result := Names[Kind];
  if Kind = tekAnsi then
    Result := Format('ANSI (code page %d)', [GetACP]);
end;

{ TSpan }

function TSpan.IsEmpty: Boolean;
begin
  Result := (OldLen = 0) and (NewLen = 0);
end;

function IsValidUtf8(const Bytes: TBytes; Start: Integer): Boolean;
begin
  if Length(Bytes) <= Start then
    Exit(True);
  Result := MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, PAnsiChar(@Bytes[Start]),
    Length(Bytes) - Start, nil, 0) > 0;
end;

function DetectEncoding(const Bytes: TBytes): TEncodingInfo;
var
  N, I: Integer;
  HighBit: Boolean;
begin
  N := Length(Bytes);
  if N = 0 then
    Result.Kind := tekEmpty
  else if (N >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
    Result.Kind := tekUtf8Bom
  else if (N >= 2) and (((Bytes[0] = $FF) and (Bytes[1] = $FE)) or ((Bytes[0] = $FE) and (Bytes[1] = $FF))) then
    Result.Kind := tekUtf16
  else
  begin
    HighBit := False;
    for I := 0 to N - 1 do
      if Bytes[I] >= $80 then
      begin
        HighBit := True;
        Break;
      end;
    if not HighBit then
      Result.Kind := tekAscii
    else if IsValidUtf8(Bytes, 0) then
      Result.Kind := tekUtf8
    else
      Result.Kind := tekAnsi;
  end;
end;

function ReadFileBytes(const FileName: string; out Bytes: TBytes): Boolean;
var
  Stream: TFileStream;
begin
  SetLength(Bytes, 0);
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Bytes, Stream.Size);
      if Length(Bytes) > 0 then
        Stream.ReadBuffer(Bytes[0], Length(Bytes));
    finally
      Stream.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

function DetectFileEncoding(const FileName: string): TEncodingInfo;
var
  Bytes: TBytes;
begin
  Result.Kind := tekEmpty;
  if (FileName = '') or not FileExists(FileName) then
    Exit;
  if ReadFileBytes(FileName, Bytes) then
    Result := DetectEncoding(Bytes);
end;

function DecodeFileBytes(const Bytes: TBytes): string;
var
  N: Integer;
begin
  N := Length(Bytes);
  case DetectEncoding(Bytes).Kind of
    tekEmpty:
      Result := '';
    tekUtf8Bom:
      Result := TEncoding.UTF8.GetString(Bytes, 3, N - 3);
    tekUtf16:
      if Bytes[0] = $FF then
        Result := TEncoding.Unicode.GetString(Bytes, 2, N - 2)
      else
        Result := TEncoding.BigEndianUnicode.GetString(Bytes, 2, N - 2);
    tekAnsi:
      Result := TEncoding.ANSI.GetString(Bytes);
  else
    Result := TEncoding.UTF8.GetString(Bytes);
  end;
end;

{ Lines with their terminators, so the text can be put back together unchanged. }
function SplitKeepingBreaks(const S: string): TArray<string>;
var
  L: TList<string>;
  I, Start: Integer;
begin
  L := TList<string>.Create;
  try
    Start := 1;
    I := 1;
    while I <= Length(S) do
    begin
      if S[I] = #10 then
      begin
        L.Add(Copy(S, Start, I - Start + 1));
        Start := I + 1;
      end;
      Inc(I);
    end;
    if Start <= Length(S) then
      L.Add(Copy(S, Start, MaxInt));
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function StripBreak(const Line: string): string;
var
  N: Integer;
begin
  N := Length(Line);
  while (N > 0) and CharInSet(Line[N], [#10, #13]) do
    Dec(N);
  Result := Copy(Line, 1, N);
end;

{ How a line reads after a single-byte code page was decoded as UTF-8: every non-ASCII
  character became U+FFFD. }
function MaskNonAscii(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Ord(Result[I]) >= $80 then
      Result[I] := REPLACEMENT_CHAR;
end;

{ For a line Claude changed: each run of U+FFFD is looked up in the old text by the characters
  around it (the same run length, same neighbours); when every match agrees, the original
  characters are put back. Returns True when no U+FFFD is left. }
function RestoreRuns(var Body: string; const OldText, MaskedOld: string): Boolean;
const
  CONTEXT = 6;
  MIN_CONTEXT = 3;
var
  I, RunStart, RunLen, L, R, P, Found, Ctx: Integer;
  Left, Right, Pattern, Candidate, Chosen: string;
  Ambiguous, BoundedLeft, BoundedRight: Boolean;
begin
  I := 1;
  while I <= Length(Body) do
  begin
    if Body[I] <> REPLACEMENT_CHAR then
    begin
      Inc(I);
      Continue;
    end;
    RunStart := I;
    while (I <= Length(Body)) and (Body[I] = REPLACEMENT_CHAR) do
      Inc(I);
    RunLen := I - RunStart;
    // Widest context first; a shorter one helps when Claude edited right next to the run.
    for Ctx := CONTEXT downto 1 do
    begin
      L := RunStart;
      while (L > 1) and (RunStart - L < Ctx) and (Body[L - 1] <> REPLACEMENT_CHAR) do
        Dec(L);
      R := I;
      while (R <= Length(Body)) and (R - I < Ctx) and (Body[R] <> REPLACEMENT_CHAR) do
        Inc(R);
      Left := Copy(Body, L, RunStart - L);
      Right := Copy(Body, I, R - I);
      if Length(Left) + Length(Right) < MIN_CONTEXT then
        Break;
      Pattern := Left + StringOfChar(REPLACEMENT_CHAR, RunLen) + Right;
      Found := 0;
      Ambiguous := False;
      Chosen := '';
      P := Pos(Pattern, MaskedOld);
      while P > 0 do
      begin
        // Without context on a side, the old run must end there too.
        BoundedLeft := (Left <> '') or (P = 1) or (MaskedOld[P - 1] <> REPLACEMENT_CHAR);
        BoundedRight := (Right <> '') or (P + Length(Pattern) > Length(MaskedOld)) or
          (MaskedOld[P + Length(Pattern)] <> REPLACEMENT_CHAR);
        if BoundedLeft and BoundedRight then
        begin
          Candidate := Copy(OldText, P + Length(Left), RunLen);
          if Found = 0 then
            Chosen := Candidate
          else if Candidate <> Chosen then
            Ambiguous := True;
          Inc(Found);
        end;
        P := Pos(Pattern, MaskedOld, P + 1);
      end;
      if Ambiguous then
        Break; // a shorter context only matches more places
      if Found > 0 then
      begin
        Body := Copy(Body, 1, RunStart - 1) + Chosen + Copy(Body, I, MaxInt);
        Break;
      end;
    end;
  end;
  Result := Pos(REPLACEMENT_CHAR, Body) = 0;
end;

function RestoreLostChars(const OldText, NewText: string; out Restored, Unresolved: Integer): string;
var
  OldByMask: TDictionary<string, string>;
  Line, Body, Key, Original, MaskedOld: string;
  NewLines: TArray<string>;
  SB: TStringBuilder;
begin
  Restored := 0;
  Unresolved := 0;
  if Pos(REPLACEMENT_CHAR, NewText) = 0 then
    Exit(NewText);
  OldByMask := TDictionary<string, string>.Create;
  SB := TStringBuilder.Create(Length(NewText));
  try
    for Line in SplitKeepingBreaks(OldText) do
    begin
      Body := StripBreak(Line);
      Key := MaskNonAscii(Body);
      if Key = Body then
        Continue; // pure ASCII lines are never damaged
      if not OldByMask.ContainsKey(Key) then
        OldByMask.Add(Key, Body)
      else if OldByMask[Key] <> Body then
        OldByMask[Key] := #0; // two different originals: ambiguous
    end;
    NewLines := SplitKeepingBreaks(NewText);
    for Line in NewLines do
    begin
      if Pos(REPLACEMENT_CHAR, Line) = 0 then
      begin
        SB.Append(Line);
        Continue;
      end;
      Body := StripBreak(Line);
      if OldByMask.TryGetValue(MaskNonAscii(Body), Original) and (Original <> #0) then
      begin
        SB.Append(Original).Append(Copy(Line, Length(Body) + 1, MaxInt));
        Inc(Restored);
      end
      else
      begin
        // A line Claude changed: repair what can be matched by context.
        if MaskedOld = '' then
          MaskedOld := MaskNonAscii(OldText);
        if RestoreRuns(Body, OldText, MaskedOld) then
          Inc(Restored)
        else
          Inc(Unresolved);
        SB.Append(Body).Append(Copy(Line, Length(StripBreak(Line)) + 1, MaxInt));
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
    OldByMask.Free;
  end;
end;

function ChangedSpanUtf8(const OldBytes, NewBytes: TBytes): TSpan;
var
  OldN, NewN, Prefix, Suffix: Integer;
begin
  OldN := Length(OldBytes);
  NewN := Length(NewBytes);
  Prefix := 0;
  while (Prefix < OldN) and (Prefix < NewN) and (OldBytes[Prefix] = NewBytes[Prefix]) do
    Inc(Prefix);
  // Step back to the start of a UTF-8 sequence (continuation bytes are 10xxxxxx).
  while (Prefix > 0) and (Prefix < OldN) and ((OldBytes[Prefix] and $C0) = $80) do
    Dec(Prefix);
  Suffix := 0;
  while (Suffix < OldN - Prefix) and (Suffix < NewN - Prefix) and
        (OldBytes[OldN - 1 - Suffix] = NewBytes[NewN - 1 - Suffix]) do
    Inc(Suffix);
  // The suffix must also start on a sequence boundary.
  while (Suffix > 0) and ((OldBytes[OldN - Suffix] and $C0) = $80) do
    Dec(Suffix);
  Result.Start := Prefix;
  Result.OldLen := OldN - Prefix - Suffix;
  Result.NewLen := NewN - Prefix - Suffix;
end;

function NormalizeToCrLf(const S: string): string;
begin
  Result := AdjustLineBreaks(S, tlbsCRLF);
end;

function IsDelphiSourceFile(const FileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  Result := (Ext = '.pas') or (Ext = '.dpr') or (Ext = '.dpk') or (Ext = '.inc');
end;

function FitsAnsi(const Text: string; out Bytes: TBytes): Boolean;
var
  Len: Integer;
  UsedDefault: BOOL;
begin
  SetLength(Bytes, 0);
  if Text = '' then
    Exit(True);
  UsedDefault := False;
  Len := WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, PChar(Text), Length(Text), nil, 0, nil, @UsedDefault);
  if (Len = 0) or UsedDefault then
    Exit(False);
  SetLength(Bytes, Len);
  WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, PChar(Text), Length(Text), PAnsiChar(@Bytes[0]), Len, nil, @UsedDefault);
  Result := not UsedDefault;
end;

function FixDelphiSourceEncoding(const Text: string; const OnDisk, Previous: TEncodingInfo;
  out Bytes: TBytes): Boolean;
begin
  SetLength(Bytes, 0);
  // Only BOM-less UTF-8 with non-ASCII characters is misread by the compiler.
  if OnDisk.Kind <> tekUtf8 then
    Exit(False);
  if Previous.IsAnsi and FitsAnsi(Text, Bytes) then
    Exit(True);
  if Previous.Kind = tekUtf8 then
    Exit(False); // the file was already BOM-less UTF-8: keep the project's convention
  Bytes := TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes(Text);
  Result := True;
end;

end.
