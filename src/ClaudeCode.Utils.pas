unit ClaudeCode.Utils;

{ Shared helpers: logging, path <-> URI conversion, file reading, JSON access. }

interface

uses
  System.SysUtils, System.Classes, System.JSON;

type
  TLogProc = reference to procedure(const Msg: string);

var
  // Assigned by the wizard; always invoked in the main thread.
  LogProc: TLogProc;

procedure Log(const Msg: string);

function PathFromUri(const S: string): string;
function PathToUri(const Path: string): string;
function LanguageIdForFile(const FileName: string): string;
function ReadTextFileAutoEnc(const FileName: string; out Text: string): Boolean;
function NewAuthToken: string;
function JsonStr(Obj: TJSONObject; const Name: string; const Default: string = ''): string;
function JsonBool(Obj: TJSONObject; const Name: string; Default: Boolean): Boolean;
function Utf8BytesToString(const Bytes: TBytes): string;

implementation

uses
  Winapi.Windows;

procedure Log(const Msg: string);
var
  Stamped: string;
begin
  Stamped := FormatDateTime('hh:nn:ss', Now) + '  ' + Msg;
  if TThread.CurrentThread.ThreadID = MainThreadID then
  begin
    if Assigned(LogProc) then
      LogProc(Stamped);
  end
  else
    TThread.Queue(nil,
      procedure
      begin
        if Assigned(LogProc) then
          LogProc(Stamped);
      end);
end;

function PercentDecode(const S: string): string;
var
  Bytes: TBytes;
  I, N: Integer;
  Hex: string;
  Chunk: TBytes;
begin
  if Pos('%', S) = 0 then
    Exit(S);
  SetLength(Bytes, 0);
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    if (S[I] = '%') and (I + 2 <= N) then
    begin
      Hex := Copy(S, I + 1, 2);
      Bytes := Bytes + [Byte(StrToIntDef('$' + Hex, Ord('?')))];
      Inc(I, 3);
    end
    else
    begin
      Chunk := TEncoding.UTF8.GetBytes(S[I]);
      Bytes := Bytes + Chunk;
      Inc(I);
    end;
  end;
  Result := TEncoding.UTF8.GetString(Bytes);
end;

function PathFromUri(const S: string): string;
var
  P: string;
begin
  P := Trim(S);
  if P = '' then
    Exit('');
  if P.StartsWith('file://', True) then
  begin
    P := PercentDecode(Copy(P, 8, MaxInt));
    // file:///C:/x -> /C:/x -> C:/x
    if (Length(P) >= 3) and (P[1] = '/') and (P[3] = ':') then
      Delete(P, 1, 1);
  end;
  P := StringReplace(P, '/', '\', [rfReplaceAll]);
  Result := ExpandFileName(P);
end;

function PathToUri(const Path: string): string;
begin
  Result := 'file:///' + StringReplace(StringReplace(Path, '\', '/', [rfReplaceAll]),
    ' ', '%20', [rfReplaceAll]);
end;

function LanguageIdForFile(const FileName: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if (Ext = '.pas') or (Ext = '.dpr') or (Ext = '.dpk') or (Ext = '.inc') or (Ext = '.pp') then
    Result := 'pascal'
  else if (Ext = '.dfm') or (Ext = '.fmx') or (Ext = '.lfm') then
    Result := 'delphi-form'
  else if (Ext = '.cpp') or (Ext = '.hpp') or (Ext = '.h') or (Ext = '.c') or (Ext = '.cc') then
    Result := 'cpp'
  else if (Ext = '.dproj') or (Ext = '.groupproj') or (Ext = '.xml') or (Ext = '.cbproj') then
    Result := 'xml'
  else if Ext = '.json' then
    Result := 'json'
  else if Ext = '.sql' then
    Result := 'sql'
  else if Ext = '.md' then
    Result := 'markdown'
  else if (Ext = '.js') or (Ext = '.ts') then
    Result := 'javascript'
  else if (Ext = '.htm') or (Ext = '.html') then
    Result := 'html'
  else
    Result := 'plaintext';
end;

function Utf8BytesToString(const Bytes: TBytes): string;
begin
  if Length(Bytes) = 0 then
    Exit('');
  Result := TEncoding.UTF8.GetString(Bytes);
end;

function DecodeStrictUtf8(const Bytes: TBytes; Start, Count: Integer; out Text: string): Boolean;
var
  Len: Integer;
begin
  Text := '';
  if Count = 0 then
    Exit(True);
  Len := MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, PAnsiChar(@Bytes[Start]), Count, nil, 0);
  if Len = 0 then
    Exit(False);
  SetLength(Text, Len);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, PAnsiChar(@Bytes[Start]), Count, PChar(Text), Len);
  Result := True;
end;

function ReadTextFileAutoEnc(const FileName: string; out Text: string): Boolean;
var
  Stream: TFileStream;
  Bytes: TBytes;
  N: Integer;
begin
  Text := '';
  if (FileName = '') or not FileExists(FileName) then
    Exit(False);
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Bytes, Stream.Size);
      if Length(Bytes) > 0 then
        Stream.ReadBuffer(Bytes[0], Length(Bytes));
    finally
      Stream.Free;
    end;
  except
    Exit(False);
  end;
  N := Length(Bytes);
  if (N >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
    Text := TEncoding.UTF8.GetString(Bytes, 3, N - 3)
  else if (N >= 2) and (Bytes[0] = $FF) and (Bytes[1] = $FE) then
    Text := TEncoding.Unicode.GetString(Bytes, 2, N - 2)
  else if (N >= 2) and (Bytes[0] = $FE) and (Bytes[1] = $FF) then
    Text := TEncoding.BigEndianUnicode.GetString(Bytes, 2, N - 2)
  else if not DecodeStrictUtf8(Bytes, 0, N, Text) then
    Text := TEncoding.ANSI.GetString(Bytes);
  Result := True;
end;

function RtlGenRandom(RandomBuffer: Pointer; RandomBufferLength: ULONG): BOOLEAN; stdcall;
  external advapi32 name 'SystemFunction036';

function NewAuthToken: string;
var
  Buf: array[0..15] of Byte;
  I: Integer;
  G: TGUID;
begin
  // 128 bits from the OS CSPRNG as lowercase hex.
  if not RtlGenRandom(@Buf[0], SizeOf(Buf)) then
  begin
    CreateGUID(G);
    Move(G, Buf[0], SizeOf(Buf));
  end;
  Result := '';
  for I := 0 to High(Buf) do
    Result := Result + LowerCase(IntToHex(Buf[I], 2));
end;

function JsonStr(Obj: TJSONObject; const Name: string; const Default: string): string;
var
  V: TJSONValue;
begin
  Result := Default;
  if Obj = nil then
    Exit;
  V := Obj.GetValue(Name);
  if (V = nil) or (V is TJSONNull) then
    Exit;
  if V is TJSONString then
    Result := TJSONString(V).Value
  else
    Result := V.ToJSON;
end;

function JsonBool(Obj: TJSONObject; const Name: string; Default: Boolean): Boolean;
var
  V: TJSONValue;
begin
  Result := Default;
  if Obj = nil then
    Exit;
  V := Obj.GetValue(Name);
  if V is TJSONBool then
    Result := TJSONBool(V).AsBoolean;
end;

end.
