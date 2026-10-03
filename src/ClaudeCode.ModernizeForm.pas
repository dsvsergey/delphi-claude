unit ClaudeCode.ModernizeForm;

{ Tools > Claude Code > Modernize Project with Claude: choosing what to modernize. }

interface

uses
  System.SysUtils, System.Classes, Vcl.Forms;

{ Shows the dialog; True with Scenario set (win64, unicode, bde, warnings, leaks) on OK. }
function ChooseModernization(out Scenario: string; const BeforeShow: TProc<TForm>): Boolean;

implementation

uses
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls;

type
  { Its own class: the IDE themes registered form classes only (registering TForm would theme every plain form). }
  TModernizeDialog = class(TForm);

const
  Scenarios: array[0..4] of string = ('win64', 'unicode', 'bde', 'warnings', 'leaks');
  Captions: array[0..4] of string = (
    'Win64: make the project 64-bit ready (pointer casts, GetWindowLong, asm)',
    'Unicode: fix ANSI/Unicode string issues (AnsiString, byte counts, Char sets)',
    'Database: move BDE / dbExpress / ADO to FireDAC',
    'Compiler warnings: clear them, most frequent first',
    'Memory leaks: fix what FastMM reports');

function ChooseModernization(out Scenario: string; const BeforeShow: TProc<TForm>): Boolean;
var
  F: TForm;
  Group: TRadioGroup;
  Info: TLabel;
  Ok, Cancel: TButton;
  I: Integer;
begin
  Scenario := '';
  F := TModernizeDialog.CreateNew(nil);
  try
    F.Caption := 'Modernize Project with Claude';
    F.BorderStyle := bsDialog;
    F.Position := poMainFormCenter;
    F.ClientWidth := 520;
    F.ClientHeight := 260;
    Info := TLabel.Create(F);
    Info.Parent := F;
    Info.SetBounds(12, 10, 496, 32);
    Info.AutoSize := False;
    Info.WordWrap := True;
    Info.Caption := 'Claude analyzes the project with the Delphi tools, then fixes it in small batches with a ' +
      'build (and the tests) after each one. You review the changes as usual.';
    Group := TRadioGroup.Create(F);
    Group.Parent := F;
    Group.SetBounds(12, 48, 496, 160);
    Group.Caption := 'What to modernize';
    for I := 0 to High(Captions) do
      Group.Items.Add(Captions[I]);
    Group.ItemIndex := 0;
    Ok := TButton.Create(F);
    Ok.Parent := F;
    Ok.SetBounds(F.ClientWidth - 180, 220, 80, 26);
    Ok.Caption := 'OK';
    Ok.Default := True;
    Ok.ModalResult := mrOk;
    Cancel := TButton.Create(F);
    Cancel.Parent := F;
    Cancel.SetBounds(F.ClientWidth - 92, 220, 80, 26);
    Cancel.Caption := 'Cancel';
    Cancel.Cancel := True;
    Cancel.ModalResult := mrCancel;
    if Assigned(BeforeShow) then
      BeforeShow(F);
    Result := (F.ShowModal = mrOk) and (Group.ItemIndex >= 0);
    if Result then
      Scenario := Scenarios[Group.ItemIndex];
  finally
    F.Free;
  end;
end;

end.
