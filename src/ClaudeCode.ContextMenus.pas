unit ClaudeCode.ContextMenus;

{ Context menu entries that send work to Claude:
  - code editor: "Claude Code" submenu (Explain, Refactor, Review, DUnitX test, XML doc, Ask...);
  - Project Manager: "Add to Claude Context" for the selected files/projects;
  - Messages view: "Fix Build Errors with Claude".
  The menus only collect what was clicked; the wizard turns it into a request. }

interface

uses
  System.SysUtils, System.Classes, Vcl.ActnList, Vcl.Menus, ToolsAPI;

type
  TEditorCommandEvent = procedure(const Command: string) of object;
  TFilesEvent = procedure(const Files: TArray<string>) of object;

  TClaudeContextMenus = class
  private
    FEditorActions: TActionList;
    FCommands: TStringList; // editor command of each action, by Tag
    FEditorMenuRegistered: Boolean;
    FProjectNotifier: Integer;
    FMessageNotifier: Integer;
    FMessageItems: TComponent; // owns the items added to the Messages popup
    FOnEditorCommand: TEditorCommandEvent;
    FOnAddToContext: TFilesEvent;
    FOnFixBuildErrors: TNotifyEvent;
    FHasEditorFile: TFunc<Boolean>;
    procedure CreateEditorMenu;
    procedure EditorActionExecute(Sender: TObject);
    procedure EditorActionUpdate(Sender: TObject);
    procedure FixBuildErrorsClick(Sender: TObject);
  public
    constructor Create(const HasEditorFile: TFunc<Boolean>);
    destructor Destroy; override;
    property OnEditorCommand: TEditorCommandEvent read FOnEditorCommand write FOnEditorCommand;
    property OnAddToContext: TFilesEvent read FOnAddToContext write FOnAddToContext;
    property OnFixBuildErrors: TNotifyEvent read FOnFixBuildErrors write FOnFixBuildErrors;
  end;

const
  // Editor commands; the wizard maps them to request templates.
  ecExplain = 'explain';
  ecRefactor = 'refactor';
  ecReview = 'review';
  ecTest = 'test';
  ecDoc = 'doc';
  ecAsk = 'ask';

implementation

uses
  ClaudeCode.Utils;

const
  EDITOR_MENU_CATEGORY = 'ClaudeCode';
  FIX_ITEM_NAME = 'ClaudeCodeFixBuildErrorsItem';

type
  { Project Manager: one "Add to Claude Context" item for the clicked nodes. }
  TAddToContextMenu = class(TNotifierObject, IOTALocalMenu, IOTAProjectManagerMenu)
  private
    FOwner: TClaudeContextMenus;
    FFiles: TArray<string>;
  public
    constructor Create(AOwner: TClaudeContextMenus; const Files: TArray<string>);
    { IOTALocalMenu }
    function GetCaption: string;
    function GetChecked: Boolean;
    function GetEnabled: Boolean;
    function GetHelpContext: Integer;
    function GetName: string;
    function GetParent: string;
    function GetPosition: Integer;
    function GetVerb: string;
    procedure SetCaption(const Value: string);
    procedure SetChecked(Value: Boolean);
    procedure SetEnabled(Value: Boolean);
    procedure SetHelpContext(Value: Integer);
    procedure SetName(const Value: string);
    procedure SetParent(const Value: string);
    procedure SetPosition(Value: Integer);
    procedure SetVerb(const Value: string);
    { IOTAProjectManagerMenu }
    function GetIsMultiSelectable: Boolean;
    procedure SetIsMultiSelectable(Value: Boolean);
    procedure Execute(const MenuContextList: IInterfaceList); overload;
    function PreExecute(const MenuContextList: IInterfaceList): Boolean;
    function PostExecute(const MenuContextList: IInterfaceList): Boolean;
  end;

  TProjectMenuCreator = class(TNotifierObject, IOTAProjectMenuItemCreatorNotifier)
  private
    FOwner: TClaudeContextMenus;
  public
    constructor Create(AOwner: TClaudeContextMenus);
    procedure AddMenu(const Project: IOTAProject; const IdentList: TStrings;
      const ProjectManagerMenuList: IInterfaceList; IsMultiSelect: Boolean);
  end;

  TMessageMenuNotifier = class(TNotifierObject, IOTAMessageNotifier, INTAMessageNotifier)
  private
    FOwner: TClaudeContextMenus;
  public
    constructor Create(AOwner: TClaudeContextMenus);
    procedure MessageGroupAdded(const Group: IOTAMessageGroup);
    procedure MessageGroupDeleted(const Group: IOTAMessageGroup);
    procedure MessageViewMenuShown(Menu: TPopupMenu; const MessageGroup: IOTAMessageGroup; LineRef: Pointer);
  end;

{ TAddToContextMenu }

constructor TAddToContextMenu.Create(AOwner: TClaudeContextMenus; const Files: TArray<string>);
begin
  inherited Create;
  FOwner := AOwner;
  FFiles := Files;
end;

function TAddToContextMenu.GetCaption: string;
begin
  Result := 'Add to Claude Context';
end;

function TAddToContextMenu.GetChecked: Boolean;
begin
  Result := False;
end;

function TAddToContextMenu.GetEnabled: Boolean;
begin
  Result := Length(FFiles) > 0;
end;

function TAddToContextMenu.GetHelpContext: Integer;
begin
  Result := 0;
end;

function TAddToContextMenu.GetName: string;
begin
  Result := 'ClaudeCodeAddToContext';
end;

function TAddToContextMenu.GetParent: string;
begin
  Result := '';
end;

function TAddToContextMenu.GetPosition: Integer;
begin
  Result := pmmpOpenSection + 900; // next to Open / Show in Explorer
end;

function TAddToContextMenu.GetVerb: string;
begin
  Result := 'ClaudeCodeAddToContext';
end;

procedure TAddToContextMenu.SetCaption(const Value: string);
begin
end;

procedure TAddToContextMenu.SetChecked(Value: Boolean);
begin
end;

procedure TAddToContextMenu.SetEnabled(Value: Boolean);
begin
end;

procedure TAddToContextMenu.SetHelpContext(Value: Integer);
begin
end;

procedure TAddToContextMenu.SetName(const Value: string);
begin
end;

procedure TAddToContextMenu.SetParent(const Value: string);
begin
end;

procedure TAddToContextMenu.SetPosition(Value: Integer);
begin
end;

procedure TAddToContextMenu.SetVerb(const Value: string);
begin
end;

function TAddToContextMenu.GetIsMultiSelectable: Boolean;
begin
  Result := True;
end;

procedure TAddToContextMenu.SetIsMultiSelectable(Value: Boolean);
begin
end;

procedure TAddToContextMenu.Execute(const MenuContextList: IInterfaceList);
begin
  if Assigned(FOwner.FOnAddToContext) then
    FOwner.FOnAddToContext(FFiles);
end;

function TAddToContextMenu.PreExecute(const MenuContextList: IInterfaceList): Boolean;
begin
  Result := True;
end;

function TAddToContextMenu.PostExecute(const MenuContextList: IInterfaceList): Boolean;
begin
  Result := True;
end;

{ TProjectMenuCreator }

constructor TProjectMenuCreator.Create(AOwner: TClaudeContextMenus);
begin
  inherited Create;
  FOwner := AOwner;
end;

procedure TProjectMenuCreator.AddMenu(const Project: IOTAProject; const IdentList: TStrings;
  const ProjectManagerMenuList: IInterfaceList; IsMultiSelect: Boolean);
var
  Paths: TArray<string>;
  S: string;
begin
  // IdentList holds the file names of the clicked nodes, plus container markers.
  Paths := nil;
  for S in IdentList do
    if (S <> '') and (FileExists(S) or DirectoryExists(S)) then
    begin
      // A project node stands for its folder.
      if SameText(ExtractFileExt(S), '.dproj') or SameText(ExtractFileExt(S), '.groupproj') then
        Paths := Paths + [ExtractFilePath(S)]
      else
        Paths := Paths + [S];
    end;
  if (Length(Paths) = 0) and (Project <> nil) and
     ((IdentList.IndexOf(sProjectContainer) >= 0) or (IdentList.IndexOf(sProjectGroupContainer) >= 0)) then
    Paths := [ExtractFilePath(Project.FileName)];
  if Length(Paths) > 0 then
    ProjectManagerMenuList.Add(TAddToContextMenu.Create(FOwner, Paths));
end;

{ TMessageMenuNotifier }

constructor TMessageMenuNotifier.Create(AOwner: TClaudeContextMenus);
begin
  inherited Create;
  FOwner := AOwner;
end;

procedure TMessageMenuNotifier.MessageGroupAdded(const Group: IOTAMessageGroup);
begin
end;

procedure TMessageMenuNotifier.MessageGroupDeleted(const Group: IOTAMessageGroup);
begin
end;

procedure TMessageMenuNotifier.MessageViewMenuShown(Menu: TPopupMenu; const MessageGroup: IOTAMessageGroup;
  LineRef: Pointer);
var
  Item: TMenuItem;
  I: Integer;
begin
  // The popup is reused: add our item once; it is owned (and freed) by FMessageItems.
  for I := 0 to Menu.Items.Count - 1 do
    if Menu.Items[I].Name = FIX_ITEM_NAME then
      Exit;
  Item := TMenuItem.Create(FOwner.FMessageItems);
  Item.Name := FIX_ITEM_NAME;
  Item.Caption := 'Fix Build Errors with Claude';
  Item.OnClick := FOwner.FixBuildErrorsClick;
  Menu.Items.Insert(0, Item);
end;

{ TClaudeContextMenus }

constructor TClaudeContextMenus.Create(const HasEditorFile: TFunc<Boolean>);
var
  PM: IOTAProjectManager;
  MS: IOTAMessageServices;
begin
  inherited Create;
  FHasEditorFile := HasEditorFile;
  FProjectNotifier := -1;
  FMessageNotifier := -1;
  FMessageItems := TComponent.Create(nil);
  try
    CreateEditorMenu;
  except
    on E: Exception do
      Log('Editor menu not available: ' + E.Message);
  end;
  if Supports(BorlandIDEServices, IOTAProjectManager, PM) then
    FProjectNotifier := PM.AddMenuItemCreatorNotifier(TProjectMenuCreator.Create(Self));
  if Supports(BorlandIDEServices, IOTAMessageServices, MS) then
    FMessageNotifier := MS.AddNotifier(TMessageMenuNotifier.Create(Self));
end;

destructor TClaudeContextMenus.Destroy;
var
  PM: IOTAProjectManager;
  MS: IOTAMessageServices;
begin
  if FEditorMenuRegistered then
    (BorlandIDEServices as IOTAEditorServices).GetEditorLocalMenu.UnregisterActionList(EDITOR_MENU_CATEGORY);
  if (FProjectNotifier >= 0) and Supports(BorlandIDEServices, IOTAProjectManager, PM) then
    PM.RemoveMenuItemCreatorNotifier(FProjectNotifier);
  if (FMessageNotifier >= 0) and Supports(BorlandIDEServices, IOTAMessageServices, MS) then
    MS.RemoveNotifier(FMessageNotifier);
  FMessageItems.Free; // removes our items from the Messages popup
  FEditorActions.Free;
  FCommands.Free;
  inherited;
end;

procedure TClaudeContextMenus.CreateEditorMenu;

  procedure Add(const Caption, Command, Category: string);
  var
    A: TAction;
  begin
    A := TAction.Create(FEditorActions);
    A.Caption := Caption;
    A.Category := Category;
    A.Tag := FCommands.Add(Command);
    A.OnExecute := EditorActionExecute;
    A.OnUpdate := EditorActionUpdate;
    A.DisableIfNoHandler := False;
    A.ActionList := FEditorActions;
  end;

const
  Sub = EDITOR_MENU_CATEGORY + '.Commands';
begin
  FEditorActions := TActionList.Create(nil);
  FCommands := TStringList.Create;
  // The parent item first, then its submenu items (see INTAEditorLocalMenu).
  Add('Claude Code', '', EDITOR_MENU_CATEGORY);
  Add('Explain', ecExplain, Sub);
  Add('Refactor', ecRefactor, Sub);
  Add('Find Bugs', ecReview, Sub);
  Add('Write DUnitX Test', ecTest, Sub);
  Add('Add XML Documentation', ecDoc, Sub);
  Add('Ask Claude About This...', ecAsk, Sub);
  (BorlandIDEServices as IOTAEditorServices).GetEditorLocalMenu.RegisterActionList(FEditorActions,
    EDITOR_MENU_CATEGORY, cEdMenuCatClipboard);
  FEditorMenuRegistered := True;
end;

procedure TClaudeContextMenus.EditorActionExecute(Sender: TObject);
var
  Command: string;
begin
  Command := FCommands[(Sender as TAction).Tag];
  if (Command <> '') and Assigned(FOnEditorCommand) then
    FOnEditorCommand(Command);
end;

procedure TClaudeContextMenus.EditorActionUpdate(Sender: TObject);
begin
  (Sender as TAction).Enabled := not Assigned(FHasEditorFile) or FHasEditorFile();
end;

procedure TClaudeContextMenus.FixBuildErrorsClick(Sender: TObject);
begin
  if Assigned(FOnFixBuildErrors) then
    FOnFixBuildErrors(Self);
end;

end.
