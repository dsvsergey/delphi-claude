unit ClaudeCode.EditorSync;

{ Keeps the IDE in step with files Claude writes on disk.
  - An open, unmodified editor buffer whose file changed on disk gets the change applied as one
    undoable edit (Ctrl+Z restores the previous text) and is saved by the IDE, so the IDE never asks
    "file changed on disk, reload?" and keeps the file's original encoding.
  - Characters Claude lost reading an ANSI file as UTF-8 (U+FFFD) are restored from the buffer.
  - Delphi sources written after an accepted diff get an encoding the compiler reads correctly:
    back to ANSI when the file was ANSI, UTF-8 with a BOM otherwise.
  - A buffer with unsaved edits is never touched; a warning goes to the Messages window. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Vcl.ExtCtrls, ClaudeCode.TextSync;

type
  TFileStamp = record
    WriteTime: Int64;
    Size: Int64;
    class function Read(const FileName: string; out Stamp: TFileStamp): Boolean; static;
    class operator Equal(const A, B: TFileStamp): Boolean;
    class operator NotEqual(const A, B: TFileStamp): Boolean;
  end;

  TWatchedBuffer = record
    Stamp: TFileStamp;    // what the buffer currently matches
    Pending: TFileStamp;  // a change seen once; applied when it is stable on the next tick
    HasPending: Boolean;
  end;

  TExpectedWrite = record
    FileName: string;
    Previous: TEncodingInfo;
    Stamp: TFileStamp;
    HasStamp: Boolean;
    Deadline: TDateTime;
  end;

  TEditorSync = class
  private
    FTimer: TTimer;
    FBuffers: TDictionary<string, TWatchedBuffer>;
    FExpected: TDictionary<string, TExpectedWrite>;
    FEnabled: Boolean;
    FBusy: Boolean;
    procedure Tick(Sender: TObject);
    procedure SyncBuffers;
    procedure FixExpectedWrites;
    procedure ApplyDiskChange(const FileName: string);
    procedure SetEnabled(Value: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    { Called when a diff is accepted: Claude is about to write FileName, which had encoding Previous. }
    procedure ExpectWrite(const FileName: string; const Previous: TEncodingInfo);
    property Enabled: Boolean read FEnabled write SetEnabled;
  end;

implementation

uses
  Winapi.Windows, System.DateUtils, ToolsAPI, ClaudeCode.Utils, ClaudeCode.IdeBackend;

const
  TICK_MS = 500;
  EXPECT_WRITE_SECONDS = 30;
  SYNC_MESSAGE_GROUP = 'Claude Code';

function Key(const FileName: string): string;
begin
  Result := AnsiLowerCase(ExpandFileName(FileName));
end;

{ Files the IDE owns in other ways (forms in the designer, project files) are left to the IDE. }
function Syncable(const FileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  Result := (FileName <> '') and (Ext <> '.dfm') and (Ext <> '.fmx') and (Ext <> '.lfm') and
    (Ext <> '.dproj') and (Ext <> '.groupproj') and (Ext <> '.cbproj') and (Ext <> '.res');
end;

procedure SyncMessage(const Text: string);
var
  MS: IOTAMessageServices;
  G: IOTAMessageGroup;
begin
  Log(Text);
  if not Supports(BorlandIDEServices, IOTAMessageServices, MS) then
    Exit;
  try
    G := MS.GetGroup(SYNC_MESSAGE_GROUP);
    if G = nil then
      G := MS.AddMessageGroup(SYNC_MESSAGE_GROUP);
    MS.AddTitleMessage(FormatDateTime('hh:nn:ss', Now) + '  ' + Text, G);
  except
    // The Messages view is optional here.
  end;
end;

function ModuleModified(const Module: IOTAModule): Boolean;
var
  I: Integer;
  Editor: IOTAEditor;
begin
  Result := False;
  for I := 0 to Module.ModuleFileCount - 1 do
  begin
    Editor := Module.ModuleFileEditors[I];
    if (Editor <> nil) and Editor.Modified then
      Exit(True);
  end;
end;

{ TFileStamp }

class function TFileStamp.Read(const FileName: string; out Stamp: TFileStamp): Boolean;
var
  Data: TWin32FileAttributeData;
begin
  Stamp := Default(TFileStamp);
  Result := GetFileAttributesEx(PChar(FileName), GetFileExInfoStandard, @Data);
  if Result then
  begin
    Stamp.WriteTime := Int64(Data.ftLastWriteTime.dwHighDateTime) shl 32 or Data.ftLastWriteTime.dwLowDateTime;
    Stamp.Size := Int64(Data.nFileSizeHigh) shl 32 or Data.nFileSizeLow;
  end;
end;

class operator TFileStamp.Equal(const A, B: TFileStamp): Boolean;
begin
  Result := (A.WriteTime = B.WriteTime) and (A.Size = B.Size);
end;

class operator TFileStamp.NotEqual(const A, B: TFileStamp): Boolean;
begin
  Result := not (A = B);
end;

{ TEditorSync }

constructor TEditorSync.Create;
begin
  inherited Create;
  FBuffers := TDictionary<string, TWatchedBuffer>.Create;
  FExpected := TDictionary<string, TExpectedWrite>.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := TICK_MS;
  FTimer.OnTimer := Tick;
  FEnabled := True;
end;

destructor TEditorSync.Destroy;
begin
  FTimer.Free;
  FExpected.Free;
  FBuffers.Free;
  inherited;
end;

procedure TEditorSync.SetEnabled(Value: Boolean);
begin
  FEnabled := Value;
  FTimer.Enabled := Value;
  FBuffers.Clear;
  FExpected.Clear;
end;

procedure TEditorSync.ExpectWrite(const FileName: string; const Previous: TEncodingInfo);
var
  E: TExpectedWrite;
begin
  if not FEnabled or (FileName = '') then
    Exit;
  E.FileName := FileName;
  E.Previous := Previous;
  E.HasStamp := TFileStamp.Read(FileName, E.Stamp);
  E.Deadline := IncSecond(Now, EXPECT_WRITE_SECONDS);
  FExpected.AddOrSetValue(Key(FileName), E);
end;

procedure TEditorSync.Tick(Sender: TObject);
begin
  if FBusy then
    Exit; // Module.Save can pump messages
  FBusy := True;
  try
    try
      SyncBuffers;
      FixExpectedWrites;
    except
      on E: Exception do
        Log('Editor sync: ' + E.Message);
    end;
  finally
    FBusy := False;
  end;
end;

procedure TEditorSync.SyncBuffers;
var
  It: IOTAEditBufferIterator;
  Seen: TList<string>;
  I: Integer;
  F, K: string;
  Stamp: TFileStamp;
  W: TWatchedBuffer;
  Keys: TArray<string>;
begin
  Seen := TList<string>.Create;
  try
    if (BorlandIDEServices as IOTAEditorServices).GetEditBufferIterator(It) then
      for I := 0 to It.Count - 1 do
      begin
        F := It.EditBuffers[I].FileName;
        if not Syncable(F) or not TFileStamp.Read(F, Stamp) then
          Continue;
        K := Key(F);
        Seen.Add(K);
        if not FBuffers.TryGetValue(K, W) then
        begin
          W := Default(TWatchedBuffer);
          W.Stamp := Stamp;
          FBuffers.Add(K, W);
          Continue;
        end;
        if Stamp = W.Stamp then
        begin
          W.HasPending := False;
          FBuffers[K] := W;
          Continue;
        end;
        // Wait until the file stops changing: Claude may still be writing it.
        if not W.HasPending or (W.Pending <> Stamp) then
        begin
          W.Pending := Stamp;
          W.HasPending := True;
          FBuffers[K] := W;
          Continue;
        end;
        ApplyDiskChange(F);
        FExpected.Remove(K); // the IDE saves the buffer in the file's own encoding
        W.HasPending := False;
        if not TFileStamp.Read(F, W.Stamp) then
          W.Stamp := Stamp;
        FBuffers[K] := W;
      end;
    // Forget closed buffers.
    Keys := FBuffers.Keys.ToArray;
    for K in Keys do
      if not Seen.Contains(K) then
        FBuffers.Remove(K);
  finally
    Seen.Free;
  end;
end;

procedure TEditorSync.ApplyDiskChange(const FileName: string);
var
  Buffer: IOTAEditBuffer;
  Module: IOTAModule;
  DiskBytes, OldBytes: TBytes;
  OldText, NewText: string;
  Restored, Unresolved: Integer;
begin
  Buffer := FindEditBuffer(FileName);
  Module := (BorlandIDEServices as IOTAModuleServices).FindModule(FileName);
  if (Buffer = nil) or (Module = nil) or Buffer.IsReadOnly then
    Exit;
  if Buffer.IsModified or ModuleModified(Module) then
  begin
    SyncMessage(Format('%s changed on disk but has unsaved changes in the editor; it was not reloaded. ' +
      'Save or revert it, then use File > Reopen if needed.', [ExtractFileName(FileName)]));
    Exit;
  end;
  if not ReadFileBytes(FileName, DiskBytes) then
    Exit;

  OldBytes := ReadBufferBytes(Buffer, 0, MaxInt);
  OldText := Utf8BytesToString(OldBytes);
  NewText := RestoreLostChars(OldText, DecodeFileBytes(DiskBytes), Restored, Unresolved);
  // In the buffer's own line breaks: the IDE saving an LF file is not a change.
  NewText := NormalizeToCrLf(NewText);
  if (Pos(#13#10, OldText) = 0) and (Pos(#10, OldText) > 0) then
    NewText := StringReplace(NewText, #13#10, #10, [rfReplaceAll]);
  // Nothing changed: e.g. the IDE saved the file itself; reloading would only drop the undo history.
  if not ReplaceBufferText(Buffer, NewText) then
    Exit;
  Module.Save(False, True);

  if Restored > 0 then
    SyncMessage(Format('%s: restored %d line(s) whose non-ASCII characters were lost by Claude ' +
      '(the file is not UTF-8)', [ExtractFileName(FileName), Restored]));
  if Unresolved > 0 then
    SyncMessage(Format('%s: %d changed line(s) contain U+FFFD characters that could not be restored; ' +
      'check them or convert the file to UTF-8', [ExtractFileName(FileName), Unresolved]));
  Log(Format('Applied disk change to %s (Ctrl+Z in the editor undoes it)', [FileName]));
end;

procedure TEditorSync.FixExpectedWrites;
var
  Pair: TPair<string, TExpectedWrite>;
  Done: TList<string>;
  Stamp: TFileStamp;
  Bytes, Fixed: TBytes;
  K: string;
  Stream: TFileStream;
begin
  if FExpected.Count = 0 then
    Exit;
  Done := TList<string>.Create;
  try
    for Pair in FExpected do
    begin
      if Now > Pair.Value.Deadline then
      begin
        Done.Add(Pair.Key);
        Continue;
      end;
      if FBuffers.ContainsKey(Pair.Key) then
        Continue; // open in the editor: handled by SyncBuffers
      if not TFileStamp.Read(Pair.Value.FileName, Stamp) or (Pair.Value.HasStamp and (Stamp = Pair.Value.Stamp)) then
        Continue; // not written yet
      Done.Add(Pair.Key);
      if not IsDelphiSourceFile(Pair.Value.FileName) or not ReadFileBytes(Pair.Value.FileName, Bytes) then
        Continue;
      if FixDelphiSourceEncoding(DecodeFileBytes(Bytes), DetectEncoding(Bytes), Pair.Value.Previous, Fixed) then
      begin
        try
          Stream := TFileStream.Create(Pair.Value.FileName, fmCreate);
          try
            if Length(Fixed) > 0 then
              Stream.WriteBuffer(Fixed[0], Length(Fixed));
          finally
            Stream.Free;
          end;
          SyncMessage(Format('%s: saved as %s so the Delphi compiler reads its non-ASCII characters correctly',
            [ExtractFileName(Pair.Value.FileName), DetectEncoding(Fixed).Name]));
        except
          on E: Exception do
            SyncMessage(Format('%s: could not fix the encoding: %s', [ExtractFileName(Pair.Value.FileName), E.Message]));
        end;
      end;
    end;
    for K in Done do
      FExpected.Remove(K);
  finally
    Done.Free;
  end;
end;

end.
