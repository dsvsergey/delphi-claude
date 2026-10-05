unit ClaudeCode.FileHistory;

{ The IDE's local history: on every save the previous version of Unit1.pas is kept as
  __history\Unit1.pas.~N~ next to the file. No ToolsAPI here, so it can be exercised
  outside the IDE. }

interface

uses
  System.SysUtils, System.JSON, ClaudeCode.Mcp, ClaudeCode.Compat;

type
  THistoryEntry = record
    Version: Integer;   // the N of .~N~
    FileName: string;
    Modified: TDateTime;
    Size: Int64;
    function ToJson: TJSONObject;
  end;

function HistoryDir(const FileName: string): string;
{ Backups of FileName, newest first. }
function ListHistory(const FileName: string): TArray<THistoryEntry>;
{ The backup with that version number; False when there is none. }
function FindHistory(const FileName: string; Version: Integer; out Entry: THistoryEntry): Boolean;
{ MCP tool: the list of backups, or the text of one version. }
function ToolGetFileHistory(Args: TJSONObject): TToolResult;

implementation

uses
  System.Classes, System.IOUtils, System.DateUtils, System.Generics.Collections,
  System.Generics.Defaults, ClaudeCode.Utils;

function THistoryEntry.ToJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('version', TJSONNumber.Create(Version));
  Result.AddPair('modified', DateToISO8601(Modified, False));
  Result.AddPair('size', TJSONNumber.Create(Size));
  Result.AddPair('file', FileName);
end;

function HistoryDir(const FileName: string): string;
begin
  Result := TPath.Combine(ExtractFilePath(ExpandFileName(FileName)), '__history');
end;

function ListHistory(const FileName: string): TArray<THistoryEntry>;
var
  L: TList<THistoryEntry>;
  Dir, Prefix, Name, Num: string;
  F: string;
  E: THistoryEntry;
begin
  L := TList<THistoryEntry>.Create;
  try
    Dir := HistoryDir(FileName);
    if TDirectory.Exists(Dir) then
    begin
      Prefix := ExtractFileName(FileName) + '.~';
      for F in TDirectory.GetFiles(Dir, ExtractFileName(FileName) + '.~*~') do
      begin
        Name := ExtractFileName(F);
        if not (Name.StartsWith(Prefix, True) and Name.EndsWith('~')) then
          Continue;
        Num := Copy(Name, Length(Prefix) + 1, Length(Name) - Length(Prefix) - 1);
        E.Version := StrToIntDef(Num, -1);
        if E.Version < 0 then
          Continue;
        E.FileName := F;
        E.Modified := TFile.GetLastWriteTime(F);
        E.Size := TFile.GetSize(F);
        L.Add(E);
      end;
    end;
    L.Sort(TComparer<THistoryEntry>.Construct(
      function(const A, B: THistoryEntry): Integer
      begin
        Result := CompareDateTime(B.Modified, A.Modified);
        if Result = 0 then
          Result := B.Version - A.Version;
      end));
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function FindHistory(const FileName: string; Version: Integer; out Entry: THistoryEntry): Boolean;
var
  E: THistoryEntry;
begin
  for E in ListHistory(FileName) do
    if E.Version = Version then
    begin
      Entry := E;
      Exit(True);
    end;
  Entry := Default(THistoryEntry);
  Result := False;
end;

function ToolGetFileHistory(Args: TJSONObject): TToolResult;
const
  MAX_CHARS = 512 * 1024;
var
  FileName, Text: string;
  Version: Integer;
  E: THistoryEntry;
  Obj: TJSONObject;
  Arr: TJSONArray;
begin
  FileName := PathFromUri(JsonStr(Args, 'file'));
  if FileName = '' then
    Exit(TToolResult.Error('"file" is required'));
  Version := StrToIntDef(JsonStr(Args, 'version'), 0);
  if Version <= 0 then
  begin
    Obj := TJSONObject.Create;
    Obj.AddPair('file', FileName);
    Obj.AddPair('historyDir', HistoryDir(FileName));
    Arr := TJSONArray.Create;
    for E in ListHistory(FileName) do
      Arr.Add(E.ToJson);
    Obj.AddPair('versions', Arr);
    if Arr.Count = 0 then
      Obj.AddPair('note', 'No local history: the IDE keeps backups in __history when a file is saved in the IDE');
    Exit(TToolResult.Json(Obj));
  end;
  if not FindHistory(FileName, Version, E) then
    Exit(TToolResult.Error(Format('No version %d of %s in %s', [Version, ExtractFileName(FileName),
      HistoryDir(FileName)])));
  if not ReadTextFileAutoEnc(E.FileName, Text) then
    Exit(TToolResult.Error('Cannot read ' + E.FileName));
  Obj := E.ToJson;
  if Length(Text) > MAX_CHARS then
  begin
    Obj.AddPair('truncated', TJSONBool.Create(True));
    Text := Copy(Text, 1, MAX_CHARS);
  end;
  Obj.AddPair('text', Text);
  Result := TToolResult.Json(Obj);
end;

end.
