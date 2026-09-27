unit ClaudeCode.TerminalPanel;

{ Registers the "Claude Code" dockable window with the IDE and shows/hides it. }

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Vcl.ActnList, Vcl.ImgList, Vcl.Menus,
  Vcl.ComCtrls, Vcl.Forms, DesignIntf, ToolsAPI, ClaudeCode.TerminalFrame;

type
  TClaudeDockableForm = class(TInterfacedObject, INTACustomDockableForm)
  public
    { INTACustomDockableForm }
    function GetCaption: string;
    function GetIdentifier: string;
    function GetFrameClass: TCustomFrameClass;
    procedure FrameCreated(AFrame: TCustomFrame);
    function GetMenuActionList: TCustomActionList;
    function GetMenuImageList: TCustomImageList;
    procedure CustomizePopupMenu(PopupMenu: TPopupMenu);
    function GetToolBarActionList: TCustomActionList;
    function GetToolBarImageList: TCustomImageList;
    procedure CustomizeToolBar(ToolBar: TToolBar);
    procedure SaveWindowState(Desktop: TCustomIniFile; const Section: string; IsProject: Boolean);
    procedure LoadWindowState(Desktop: TCustomIniFile; const Section: string);
    function GetEditState: TEditState;
    function EditAction(Action: TEditAction): Boolean;
  end;

procedure RegisterClaudePanel;
procedure UnregisterClaudePanel;
{ Shows the panel (creating it if needed) and focuses the terminal. }
function ShowClaudePanel: TClaudeTerminalFrame;
function ClaudePanelFrame: TClaudeTerminalFrame;

implementation

uses
  Vcl.Controls;

var
  GDockable: INTACustomDockableForm;

{ TClaudeDockableForm }

function TClaudeDockableForm.GetCaption: string;
begin
  Result := 'Claude Code';
end;

function TClaudeDockableForm.GetIdentifier: string;
begin
  Result := 'ClaudeCodeTerminal';
end;

function TClaudeDockableForm.GetFrameClass: TCustomFrameClass;
begin
  Result := TClaudeTerminalFrame;
end;

procedure TClaudeDockableForm.FrameCreated(AFrame: TCustomFrame);
begin
  if AFrame is TClaudeTerminalFrame then
    ActiveTerminalFrame := TClaudeTerminalFrame(AFrame);
end;

function TClaudeDockableForm.GetMenuActionList: TCustomActionList;
begin
  Result := nil;
end;

function TClaudeDockableForm.GetMenuImageList: TCustomImageList;
begin
  Result := nil;
end;

procedure TClaudeDockableForm.CustomizePopupMenu(PopupMenu: TPopupMenu);
begin
end;

function TClaudeDockableForm.GetToolBarActionList: TCustomActionList;
begin
  Result := nil;
end;

function TClaudeDockableForm.GetToolBarImageList: TCustomImageList;
begin
  Result := nil;
end;

procedure TClaudeDockableForm.CustomizeToolBar(ToolBar: TToolBar);
begin
end;

procedure TClaudeDockableForm.SaveWindowState(Desktop: TCustomIniFile; const Section: string;
  IsProject: Boolean);
begin
end;

procedure TClaudeDockableForm.LoadWindowState(Desktop: TCustomIniFile; const Section: string);
begin
end;

function TClaudeDockableForm.GetEditState: TEditState;
begin
  Result := [];
end;

function TClaudeDockableForm.EditAction(Action: TEditAction): Boolean;
begin
  Result := False;
end;

{ Panel management }

function ClaudePanelFrame: TClaudeTerminalFrame;
begin
  Result := ActiveTerminalFrame;
end;

procedure RegisterClaudePanel;
begin
  if GDockable <> nil then
    Exit;
  GDockable := TClaudeDockableForm.Create;
  (BorlandIDEServices as INTAServices).RegisterDockableForm(GDockable);
end;

procedure UnregisterClaudePanel;
var
  Form: TCustomForm;
begin
  if GDockable = nil then
    Exit;
  Form := nil;
  if ActiveTerminalFrame <> nil then
    Form := GetParentForm(ActiveTerminalFrame, False);
  (BorlandIDEServices as INTAServices).UnregisterDockableForm(GDockable);
  // The form's frame class lives in this package, so the form must go with it.
  Form.Free;
  GDockable := nil;
end;

function ShowClaudePanel: TClaudeTerminalFrame;
var
  Form: TCustomForm;
begin
  RegisterClaudePanel;
  if ActiveTerminalFrame <> nil then
    Form := GetParentForm(ActiveTerminalFrame, False)
  else
  begin
    Form := (BorlandIDEServices as INTAServices).CreateDockableForm(GDockable);
  end;
  if Form <> nil then
  begin
    Form.Show;
    Form.BringToFront;
  end;
  Result := ActiveTerminalFrame;
  if Result <> nil then
    Result.FocusTerminal;
end;

end.
