unit ClaudeCode.CompatIde;

{ ToolsAPI and VCL declarations that newer Delphi versions have and older ones (down to Delphi 10
  Seattle) lack. Everything here is conditional, so with a current Delphi this unit is empty. }

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms, Vcl.Themes, ToolsAPI;

{$IF not Declared(IOTAIDEThemingServices)}
type
  { IDE themes (Delphi 10.2). The IDE does not implement this GUID, so Supports(BorlandIDEServices,
    IOTAIDEThemingServices, ...) is False and the forms keep the regular VCL look. }
  IOTAIDEThemingServices = interface
    ['{5B0D7E9C-3A51-4C7E-9F0B-6C8E2D1A4F30}']
    function GetIDEThemingEnabled: Boolean;
    function GetStyleServices: TCustomStyleServices;
    procedure ApplyTheme(Component: TComponent);
    procedure RegisterFormClass(AFormClass: TCustomFormClass);
    property IDEThemingEnabled: Boolean read GetIDEThemingEnabled;
    property StyleServices: TCustomStyleServices read GetStyleServices;
  end;
{$IFEND}

{$IF CompilerVersion < 34.0}
{ StyleServices(Control) (Delphi 10.4, per-control styles): the application style. }
function StyleServices(AControl: TControl = nil): TCustomStyleServices;
{$IFEND}

implementation

{$IF CompilerVersion < 34.0}
function StyleServices(AControl: TControl): TCustomStyleServices;
begin
  Result := Vcl.Themes.StyleServices;
end;
{$IFEND}

end.
