unit FakeBackend;

{ IIdeBackend stand-in for running the server outside the IDE. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ClaudeCode.Mcp;

type
  TFakeBackend = class(TInterfacedObject, IIdeBackend)
  private
    FFolder: string;
    FPending: TToolDone;
  public
    constructor Create(const Folder: string);
    procedure ExecuteTool(const Name: string; Args: TJSONObject; const Done: TToolDone);
    function WorkspaceFolders: TArray<string>;
    function IdeName: string;
  end;

implementation

uses
  ClaudeCode.Utils, ClaudeCode.FileHistory;

constructor TFakeBackend.Create(const Folder: string);
begin
  inherited Create;
  FFolder := Folder;
end;

procedure TFakeBackend.ExecuteTool(const Name: string; Args: TJSONObject; const Done: TToolDone);
begin
  Log('tools/call ' + Name + ' ' + Args.ToJSON);
  if Name = 'openDiff' then
  begin
    // Answer later, like a user clicking Accept.
    FPending := Done;
    TThread.CreateAnonymousThread(
      procedure
      begin
        Sleep(300);
        TThread.Queue(nil,
          procedure
          begin
            FPending(TToolResult.Ok(['FILE_SAVED', 'accepted']));
            FPending := nil;
          end);
      end).Start;
  end
  else if Name = 'echo' then
    Done(TToolResult.Ok([Args.ToJSON]))
  else if Name = 'getProjectInfo' then
    Done(TToolResult.Ok(['{"project":{"name":"Fake"}}']))
  else if Name = 'getFileHistory' then
    Done(ToolGetFileHistory(Args))
  else if Name = 'closeAllDiffTabs' then
    Done(TToolResult.Ok(['CLOSED_0_DIFF_TABS']))
  else
    Done(TToolResult.Error('Unknown tool: ' + Name));
end;

function TFakeBackend.WorkspaceFolders: TArray<string>;
begin
  Result := [FFolder];
end;

function TFakeBackend.IdeName: string;
begin
  Result := 'DelphiTest';
end;

end.
