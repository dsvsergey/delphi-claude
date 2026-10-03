unit ClaudeCode.SettingsForm;

{ Tools > Claude Code > Settings: how Claude is started and how the IDE follows it. }

interface

uses
  System.SysUtils, System.Classes, Vcl.Forms;

type
  TClaudeSettings = record
    PanelCommand: string;     // e.g. claude
    ConsoleCommand: string;   // e.g. cmd.exe /k claude
    Model: string;            // --model; empty = Claude's default
    PermissionMode: string;   // --permission-mode; empty = default
    ExtraArgs: string;        // anything else for the command line
    DelphiTools: Boolean;     // pass --mcp-config with the "delphi" server
    SyncEditor: Boolean;      // apply Claude's file changes to open editors
    SubmitRequests: Boolean;  // context menu requests are sent right away
    Timeline: Boolean;        // record Claude's turns through hooks (--settings)
    InlineDiff: Boolean;      // show proposed changes in the code editor instead of the diff window
    { Arguments added to the claude command line (without --mcp-config). }
    function CommandArgs: string;
  end;

{ Shows the dialog; BeforeShow can theme the form. True when the user pressed OK. }
function EditClaudeSettings(var Settings: TClaudeSettings; const BeforeShow: TProc<TForm>): Boolean;

implementation

uses
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls;

function Quote(const S: string): string;
begin
  if S.Contains(' ') then
    Result := '"' + S + '"'
  else
    Result := S;
end;

function TClaudeSettings.CommandArgs: string;
begin
  Result := '';
  if Trim(Model) <> '' then
    Result := Result + ' --model ' + Quote(Trim(Model));
  if Trim(PermissionMode) <> '' then
    Result := Result + ' --permission-mode ' + Trim(PermissionMode);
  if Trim(ExtraArgs) <> '' then
    Result := Result + ' ' + Trim(ExtraArgs);
  Result := Trim(Result);
end;

function EditClaudeSettings(var Settings: TClaudeSettings; const BeforeShow: TProc<TForm>): Boolean;
const
  W = 520;
var
  F: TForm;
  Y: Integer;
  PanelCmd, ConsoleCmd, Extra: TEdit;
  Model, Mode: TComboBox;
  Tools, Sync, Submit, Timeline, InlineDiff: TCheckBox;
  Ok, Cancel: TButton;

  procedure Caption(const Text: string);
  var
    L: TLabel;
  begin
    L := TLabel.Create(F);
    L.Parent := F;
    L.Caption := Text;
    L.SetBounds(12, Y, W - 24, 16);
    Inc(Y, 18);
  end;

  function Edit(const Text: string): TEdit;
  begin
    Result := TEdit.Create(F);
    Result.Parent := F;
    Result.Text := Text;
    Result.SetBounds(12, Y, W - 24, 23);
    Inc(Y, 32);
  end;

  function Combo(const Text: string; const Items: array of string): TComboBox;
  var
    S: string;
  begin
    Result := TComboBox.Create(F);
    Result.Parent := F;
    Result.Style := csDropDown;
    for S in Items do
      Result.Items.Add(S);
    Result.Text := Text;
    Result.SetBounds(12, Y, 240, 23);
    Inc(Y, 32);
  end;

  function Check(const Text: string; Value: Boolean): TCheckBox;
  begin
    Result := TCheckBox.Create(F);
    Result.Parent := F;
    Result.Caption := Text;
    Result.Checked := Value;
    Result.SetBounds(12, Y, W - 24, 20);
    Inc(Y, 24);
  end;

begin
  F := TForm.CreateNew(nil);
  try
    F.Caption := 'Claude Code Settings';
    F.BorderStyle := bsDialog;
    F.Position := poMainFormCenter;
    F.ClientWidth := W;
    Y := 12;
    Caption('Command run in the Claude Code panel:');
    PanelCmd := Edit(Settings.PanelCommand);
    Caption('Command for "Open in External Console":');
    ConsoleCmd := Edit(Settings.ConsoleCommand);
    Caption('Model (--model; empty = Claude''s default):');
    Model := Combo(Settings.Model, ['', 'opus', 'sonnet', 'haiku']);
    Caption('Permission mode (--permission-mode; empty = default):');
    Mode := Combo(Settings.PermissionMode, ['', 'default', 'acceptEdits', 'plan']);
    Caption('Other command line arguments:');
    Extra := Edit(Settings.ExtraArgs);
    Inc(Y, 4);
    Tools := Check('Give Claude the Delphi tools (build, project, form designer, debugger)', Settings.DelphiTools);
    Sync := Check('Apply Claude''s file changes to open editors (undo with Ctrl+Z)', Settings.SyncEditor);
    Submit := Check('Send editor context-menu requests right away (otherwise only paste them)', Settings.SubmitRequests);
    InlineDiff := Check('Show Claude''s proposed changes in the code editor (otherwise in a diff window)',
      Settings.InlineDiff);
    Timeline := Check('Record Claude''s turns for the timeline and rewinding (Claude Code hooks)', Settings.Timeline);
    Inc(Y, 8);

    Cancel := TButton.Create(F);
    Cancel.Parent := F;
    Cancel.Caption := 'Cancel';
    Cancel.ModalResult := mrCancel;
    Cancel.Cancel := True;
    Cancel.SetBounds(W - 12 - 90, Y, 90, 27);
    Ok := TButton.Create(F);
    Ok.Parent := F;
    Ok.Caption := 'OK';
    Ok.ModalResult := mrOk;
    Ok.Default := True;
    Ok.SetBounds(W - 12 - 90 - 8 - 90, Y, 90, 27);
    F.ClientHeight := Y + 27 + 12;

    if Assigned(BeforeShow) then
      BeforeShow(F);
    Result := F.ShowModal = mrOk;
    if Result then
    begin
      Settings.PanelCommand := Trim(PanelCmd.Text);
      Settings.ConsoleCommand := Trim(ConsoleCmd.Text);
      Settings.Model := Trim(Model.Text);
      Settings.PermissionMode := Trim(Mode.Text);
      Settings.ExtraArgs := Trim(Extra.Text);
      Settings.DelphiTools := Tools.Checked;
      Settings.SyncEditor := Sync.Checked;
      Settings.SubmitRequests := Submit.Checked;
      Settings.InlineDiff := InlineDiff.Checked;
      Settings.Timeline := Timeline.Checked;
    end;
  finally
    F.Free;
  end;
end;

end.
