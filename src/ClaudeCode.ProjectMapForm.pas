unit ClaudeCode.ProjectMapForm;

{ Tools > Claude Code > Project Map: the unit dependency graph in a WebView2 page
  (src/terminal/projectmap.html). Double-click opens a unit, "Ask Claude" sends a request
  about it to the Claude panel. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, Vcl.Forms, Vcl.Controls, Vcl.Graphics,
  ClaudeCode.WebViewHost, ClaudeCode.ProjectMap;

type
  TProjectMapForm = class(TForm)
  private
    FWeb: TWebViewHost;
    FOnOpen: TProc<string>;
    FOnAsk: TProc<string, string>;
    procedure WebMessage(Sender: TObject; const Msg: string);
    procedure WebError(Sender: TObject; const Error: string);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
  public
    constructor CreateMap(AOwner: TComponent);
    procedure ShowMap(const Map: TProjectMap; const Title: string; Dark: Boolean);
    property OnOpen: TProc<string> read FOnOpen write FOnOpen;
    property OnAsk: TProc<string, string> read FOnAsk write FOnAsk;
  end;

var
  { Set by the wizard: sends a request about a unit to the Claude panel. }
  ProjectMapAsk: TProc<string, string>;

{ Builds the map of the project group and shows it; False when no project is open. }
function OpenProjectMap(Dark: Boolean): Boolean;
procedure DestroyProjectMapWindow;

implementation

uses
  System.Types, ToolsAPI, ClaudeCode.Utils, ClaudeCode.CodeTools;

{$R 'terminal\pages.res'}

var
  Instance: TProjectMapForm;

function OpenProjectMap(Dark: Boolean): Boolean;
var
  Map: TProjectMap;
  G: IOTAProjectGroup;
  Title: string;
  Theming: IOTAIDEThemingServices;
begin
  Map := BuildProjectMap(ProjectMapSources(''));
  if Length(Map.Units) = 0 then
    Exit(False);
  G := (BorlandIDEServices as IOTAModuleServices).MainProjectGroup;
  Title := 'project';
  if G <> nil then
    Title := ExtractFileName(G.FileName);
  if Instance = nil then
  begin
    // Registered before the window exists: the theme's title bar is set up when it is created.
    if Supports(BorlandIDEServices, IOTAIDEThemingServices, Theming) and Theming.IDEThemingEnabled then
      Theming.RegisterFormClass(TProjectMapForm);
    Instance := TProjectMapForm.CreateMap(Application);
    Instance.OnOpen :=
      procedure(FileName: string)
      begin
        (BorlandIDEServices as IOTAActionServices).OpenFile(FileName);
      end;
    Instance.OnAsk :=
      procedure(UnitName, FileName: string)
      begin
        if Assigned(ProjectMapAsk) then
          ProjectMapAsk(UnitName, FileName);
      end;
    if (Theming <> nil) and Theming.IDEThemingEnabled then
      Theming.ApplyTheme(Instance);
  end;
  Instance.ShowMap(Map, Title, Dark);
  Result := True;
end;

procedure DestroyProjectMapWindow;
begin
  ProjectMapAsk := nil;
  FreeAndNil(Instance);
end;

function LoadTextResource(const Name: string): string;
var
  Res: TResourceStream;
  Bytes: TBytes;
begin
  Res := TResourceStream.Create(HInstance, Name, RT_RCDATA);
  try
    SetLength(Bytes, Res.Size);
    if Length(Bytes) > 0 then
      Res.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Res.Free;
  end;
  Result := TEncoding.UTF8.GetString(Bytes);
end;

constructor TProjectMapForm.CreateMap(AOwner: TComponent);
begin
  CreateNew(AOwner);
  Caption := 'Project Map';
  Width := 1200;
  Height := 760;
  Position := poMainFormCenter;
  OnClose := FormClose;
  FWeb := TWebViewHost.Create(Self);
  FWeb.Parent := Self;
  FWeb.Align := alClient;
  FWeb.OnMessage := WebMessage;
  FWeb.OnError := WebError;
end;

procedure TProjectMapForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caHide;
end;

procedure TProjectMapForm.ShowMap(const Map: TProjectMap; const Title: string; Dark: Boolean);
var
  Html: string;
  Json: TJSONObject;
begin
  Caption := 'Project Map - ' + Title;
  Json := Map.ToJson;
  try
    // "</" inside the JSON must not end the script element.
    Html := StringReplace(LoadTextResource('CC_PROJECTMAP_HTML'), '/*DATA*/null',
      StringReplace(Json.ToJSON, '</', '<\/', [rfReplaceAll]), []);
  finally
    Json.Free;
  end;
  if Dark then
    Html := StringReplace(Html, '/*DARK*/false', 'true', []);
  Show;
  FWeb.NavigateToString(Html);
end;

procedure TProjectMapForm.WebMessage(Sender: TObject; const Msg: string);
var
  V: TJSONValue;
  O: TJSONObject;
begin
  V := TJSONObject.ParseJSONValue(Msg);
  try
    if not (V is TJSONObject) then
      Exit;
    O := TJSONObject(V);
    if (JsonStr(O, 'open') <> '') and Assigned(FOnOpen) then
      FOnOpen(JsonStr(O, 'open'))
    else if (JsonStr(O, 'ask') <> '') and Assigned(FOnAsk) then
      FOnAsk(JsonStr(O, 'ask'), JsonStr(O, 'file'));
  finally
    V.Free;
  end;
end;

procedure TProjectMapForm.WebError(Sender: TObject; const Error: string);
begin
  Log('Project map: ' + Error);
end;

end.
