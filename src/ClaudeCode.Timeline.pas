unit ClaudeCode.Timeline;

{ A timeline of Claude's turns, fed by Claude Code hooks (see TMcpServer's /hook endpoint):
  UserPromptSubmit starts a turn, PreToolUse of a file-editing tool keeps the file's bytes as they
  were before the turn touched it, Stop takes the files as the turn left them. Rewinding to before
  a turn gives back the exact bytes of every file that turn or a later one changed.
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections;

type
  TTurnFile = record
    FileName: string;
    Existed: Boolean;  // the file existed before the turn
    Before: TBytes;
    After: TBytes;
    HasAfter: Boolean;
    ExistsAfter: Boolean;
  end;

  TTurn = class
  public
    Id: Integer;
    SessionId: string;
    Prompt: string;
    Started: TDateTime;
    Ended: TDateTime;   // 0 while running
    Files: TList<TTurnFile>;
    constructor Create;
    destructor Destroy; override;
    function IndexOfFile(const FileName: string): Integer;
    function Running: Boolean;
  end;

  { What rewinding writes: Bytes into FileName, or deletes it when it did not exist. }
  TRestore = record
    FileName: string;
    Delete: Boolean;
    Bytes: TBytes;
  end;

  TTimeline = class
  private
    FTurns: TObjectList<TTurn>;
    FNextId: Integer;
    FOnChanged: TNotifyEvent;
    FMaxTurns: Integer;
    function CurrentTurn(const SessionId: string): TTurn;
    procedure Changed;
    procedure Trim_;
  public
    constructor Create;
    destructor Destroy; override;
    procedure PromptSubmitted(const SessionId, Prompt: string);
    procedure BeforeFileChange(const SessionId, FileName: string);
    procedure TurnEnded(const SessionId: string);
    { One Claude Code hook event (the JSON Claude Code passes to hook commands). }
    procedure HandleHook(const Json: string);
    { Files to restore so that every file changed in turn Index or later is as before turn Index. }
    function RewindPlan(Index: Integer): TArray<TRestore>;
    { Forgets turn Index and the later ones (after rewinding). }
    procedure DropFrom(Index: Integer);
    procedure Clear;
    function Count: Integer;
    function Turn(Index: Integer): TTurn;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
    property MaxTurns: Integer read FMaxTurns write FMaxTurns;
  end;

const
  MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024;

{ Lines added and removed between two versions of a file (text decoded like the IDE does). }
procedure LineChanges(const Before, After: TBytes; out Added, Removed: Integer);

implementation

uses
  System.IOUtils, ClaudeCode.Utils, ClaudeCode.TextSync, ClaudeCode.Diff;

function NormalKey(const FileName: string): string;
begin
  Result := AnsiLowerCase(ExpandFileName(FileName));
end;

procedure LineChanges(const Before, After: TBytes; out Added, Removed: Integer);
begin
  CountChanges(ComputeLineDiff(SplitLines(DecodeFileBytes(Before)), SplitLines(DecodeFileBytes(After))),
    Added, Removed);
end;

{ TTurn }

constructor TTurn.Create;
begin
  inherited Create;
  Files := TList<TTurnFile>.Create;
end;

destructor TTurn.Destroy;
begin
  Files.Free;
  inherited;
end;

function TTurn.IndexOfFile(const FileName: string): Integer;
var
  I: Integer;
  K: string;
begin
  K := NormalKey(FileName);
  for I := 0 to Files.Count - 1 do
    if NormalKey(Files[I].FileName) = K then
      Exit(I);
  Result := -1;
end;

function TTurn.Running: Boolean;
begin
  Result := Ended = 0;
end;

{ TTimeline }

constructor TTimeline.Create;
begin
  inherited Create;
  FTurns := TObjectList<TTurn>.Create(True);
  FMaxTurns := 200;
end;

destructor TTimeline.Destroy;
begin
  FTurns.Free;
  inherited;
end;

procedure TTimeline.Changed;
begin
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TTimeline.Trim_;
begin
  while FTurns.Count > FMaxTurns do
    FTurns.Delete(0);
end;

function TTimeline.CurrentTurn(const SessionId: string): TTurn;
var
  I: Integer;
begin
  for I := FTurns.Count - 1 downto 0 do
    if FTurns[I].SessionId = SessionId then
    begin
      if FTurns[I].Running then
        Exit(FTurns[I]);
      Break;
    end;
  Result := nil;
end;

procedure TTimeline.PromptSubmitted(const SessionId, Prompt: string);
var
  T: TTurn;
begin
  T := CurrentTurn(SessionId);
  if T <> nil then
    TurnEnded(SessionId); // a Stop we did not see (interrupted turn)
  T := TTurn.Create;
  Inc(FNextId);
  T.Id := FNextId;
  T.SessionId := SessionId;
  T.Prompt := Prompt;
  T.Started := Now;
  FTurns.Add(T);
  Trim_;
  Changed;
end;

procedure TTimeline.BeforeFileChange(const SessionId, FileName: string);
var
  T: TTurn;
  F: TTurnFile;
begin
  if FileName = '' then
    Exit;
  T := CurrentTurn(SessionId);
  if T = nil then
  begin
    // Hooks were installed in the middle of a turn: an unnamed one.
    PromptSubmitted(SessionId, '');
    T := CurrentTurn(SessionId);
  end;
  if T.IndexOfFile(FileName) >= 0 then
    Exit; // the first version of the turn is the one to keep
  F := Default(TTurnFile);
  F.FileName := ExpandFileName(FileName);
  F.Existed := FileExists(F.FileName);
  if F.Existed and not ReadFileBytes(F.FileName, F.Before) then
    Exit;
  if Length(F.Before) > MAX_SNAPSHOT_BYTES then
    Exit; // generated or binary data: not kept
  T.Files.Add(F);
  Changed;
end;

procedure TTimeline.TurnEnded(const SessionId: string);
var
  T: TTurn;
  I: Integer;
  F: TTurnFile;
begin
  T := CurrentTurn(SessionId);
  if T = nil then
    Exit;
  T.Ended := Now;
  for I := 0 to T.Files.Count - 1 do
  begin
    F := T.Files[I];
    F.ExistsAfter := FileExists(F.FileName);
    F.HasAfter := not F.ExistsAfter or ReadFileBytes(F.FileName, F.After);
    T.Files[I] := F;
  end;
  Changed;
end;

procedure TTimeline.HandleHook(const Json: string);
var
  V: TJSONValue;
  O, Input: TJSONObject;
  Event, Session, Tool, FileName: string;
begin
  V := TJSONObject.ParseJSONValue(Json);
  try
    if not (V is TJSONObject) then
      Exit;
    O := TJSONObject(V);
    Event := JsonStr(O, 'hook_event_name');
    Session := JsonStr(O, 'session_id');
    if Event = 'UserPromptSubmit' then
      PromptSubmitted(Session, JsonStr(O, 'prompt'))
    else if Event = 'PreToolUse' then
    begin
      Tool := JsonStr(O, 'tool_name');
      if not (O.GetValue('tool_input') is TJSONObject) then
        Exit;
      Input := TJSONObject(O.GetValue('tool_input'));
      FileName := JsonStr(Input, 'file_path');
      if FileName = '' then
        FileName := JsonStr(Input, 'notebook_path');
      if (FileName <> '') and not TPath.IsPathRooted(FileName) and (JsonStr(O, 'cwd') <> '') then
        FileName := TPath.Combine(JsonStr(O, 'cwd'), FileName);
      if (Tool = 'Edit') or (Tool = 'Write') or (Tool = 'MultiEdit') or (Tool = 'NotebookEdit') then
        BeforeFileChange(Session, PathFromUri(FileName));
    end
    else if (Event = 'Stop') or (Event = 'SessionEnd') then
      TurnEnded(Session);
  finally
    V.Free;
  end;
end;

function TTimeline.RewindPlan(Index: Integer): TArray<TRestore>;
var
  Seen: TDictionary<string, Boolean>;
  I: Integer;
  F: TTurnFile;
  R: TRestore;
begin
  Result := nil;
  Seen := TDictionary<string, Boolean>.Create;
  try
    // The earliest snapshot of each file from turn Index on is the state before turn Index.
    for I := Index to FTurns.Count - 1 do
      for F in FTurns[I].Files do
      begin
        if Seen.ContainsKey(NormalKey(F.FileName)) then
          Continue;
        Seen.Add(NormalKey(F.FileName), True);
        R.FileName := F.FileName;
        R.Delete := not F.Existed;
        R.Bytes := F.Before;
        Result := Result + [R];
      end;
  finally
    Seen.Free;
  end;
end;

procedure TTimeline.DropFrom(Index: Integer);
begin
  while FTurns.Count > Index do
    FTurns.Delete(FTurns.Count - 1);
  Changed;
end;

procedure TTimeline.Clear;
begin
  FTurns.Clear;
  Changed;
end;

function TTimeline.Count: Integer;
begin
  Result := FTurns.Count;
end;

function TTimeline.Turn(Index: Integer): TTurn;
begin
  Result := FTurns[Index];
end;

end.
