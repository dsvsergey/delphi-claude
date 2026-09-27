program PanelHost;

{ Hosts the Claude Code terminal panel in a plain VCL window, with the MCP server
  and a fake IDE backend, and runs a scripted smoke test:
    start claude -> type text through the page -> dump screen text + screenshot -> close.
  Usage: PanelHost.exe <workdir> <outdir> }

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, Vcl.Forms, Vcl.Graphics,
  Vcl.Controls, Vcl.ExtCtrls, Vcl.Imaging.pngimage,
  ClaudeCode.Utils, ClaudeCode.Mcp, ClaudeCode.TerminalFrame, FakeBackend;

type
  TScript = class
  private
    FForm: TForm;
    FFrame: TClaudeTerminalFrame;
    FMcp: TMcpServer;
    FTimer: TTimer;
    FTick: Integer;
    FWorkDir: string;
    FOutDir: string;
    FLog: TStringList;
    FResizeMode: Boolean;
    function ResizeStep: Boolean;
    procedure Tick(Sender: TObject);
    procedure Screenshot(const FileName: string);
    function HostInfo: TTerminalHostInfo;
  public
    constructor Create(const WorkDir, OutDir: string);
    destructor Destroy; override;
    procedure AddLog(const S: string);
  end;

constructor TScript.Create(const WorkDir, OutDir: string);
begin
  FWorkDir := WorkDir;
  FOutDir := OutDir;
  FResizeMode := SameText(ParamStr(3), 'resize');
  FLog := TStringList.Create;
  LogProc := procedure(const Msg: string) begin AddLog(Msg); end;
  FMcp := TMcpServer.Create(TFakeBackend.Create(WorkDir));
  FMcp.Start;
  TClaudeTerminalFrame.HostInfo := HostInfo;

  Application.CreateForm(TForm, FForm);
  FForm.Caption := 'Claude Code panel test';
  FForm.SetBounds(80, 80, 1100, 700);
  FFrame := TClaudeTerminalFrame.Create(FForm);
  FFrame.Parent := FForm;
  FFrame.Align := alClient;

  FTimer := TTimer.Create(nil);
  FTimer.Interval := 1000;
  FTimer.OnTimer := Tick;
end;

destructor TScript.Destroy;
begin
  FTimer.Free;
  FMcp.Free;
  FLog.SaveToFile(TPath.Combine(FOutDir, 'panelhost.log'), TEncoding.UTF8);
  FLog.Free;
  inherited;
end;

procedure TScript.AddLog(const S: string);
begin
  FLog.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + S);
end;

function TScript.HostInfo: TTerminalHostInfo;
begin
  Result.Port := FMcp.Port;
  Result.WorkDir := FWorkDir;
  Result.Command := 'claude';
  Result.Background := $001E1E1E;
  Result.FontName := 'Consolas';
  Result.FontSize := 10;
end;

procedure TScript.Screenshot(const FileName: string);
var
  Bmp: TBitmap;
  Png: TPngImage;
  DC: HDC;
  R: TRect;
begin
  GetWindowRect(FForm.Handle, R);
  Bmp := TBitmap.Create;
  Png := TPngImage.Create;
  try
    Bmp.SetSize(R.Width, R.Height);
    DC := GetDC(0);
    try
      BitBlt(Bmp.Canvas.Handle, 0, 0, R.Width, R.Height, DC, R.Left, R.Top, SRCCOPY);
    finally
      ReleaseDC(0, DC);
    end;
    Png.Assign(Bmp);
    Png.SaveToFile(FileName);
  finally
    Png.Free;
    Bmp.Free;
  end;
end;

function TScript.ResizeStep: Boolean;

  procedure Shot(const Name: string);
  begin
    Screenshot(TPath.Combine(FOutDir, Name + '.png'));
    AddLog('Screenshot ' + Name + Format(' form %dx%d', [FForm.Width, FForm.Height]));
  end;

begin
  Result := True;
  case FTick of
    12: FForm.SetBounds(80, 80, 650, 700);
    14: Shot('r1-narrow');
    15: FForm.SetBounds(80, 80, 1300, 800);
    17: Shot('r2-wide');
    18: FForm.SetBounds(80, 80, 1000, 380);
    20: Shot('r3-short');
    21: begin
          FFrame.StopSession;
          FTimer.Enabled := False;
          FForm.Close;
        end;
  else
    Result := FTick < 12;
    if Result then Result := FTick <> 1;
  end;
end;

procedure TScript.Tick(Sender: TObject);
var
  T0: Cardinal;
begin
  Inc(FTick);
  if FResizeMode and ResizeStep then
    Exit;
  case FTick of
    1:
      begin
        SetForegroundWindow(FForm.Handle);
        AddLog('StartSession');
        FFrame.StartSession;
      end;
    14:
      begin
        AddLog('InjectInput');
        FFrame.InjectInput('hello from delphi');
      end;
    16:
      begin
        FFrame.RequestDump(
          procedure(Text: string)
          begin
            TFile.WriteAllText(TPath.Combine(FOutDir, 'panelhost.dump.txt'), Text, TEncoding.UTF8);
            AddLog('Dump received, ' + IntToStr(Length(Text)) + ' chars');
          end);
        Screenshot(TPath.Combine(FOutDir, 'panelhost.png'));
        AddLog('Screenshot saved');
      end;
    17:
      begin
        AddLog('Session running: ' + BoolToStr(FFrame.SessionRunning, True) +
          ', MCP clients: ' + IntToStr(FMcp.ClientCount));
        T0 := GetTickCount;
        FFrame.StopSession;
        AddLog(Format('StopSession took %d ms', [GetTickCount - T0]));
      end;
    18:
      begin
        // Tabs: a second tab for another folder, then back to the first by folder.
        FFrame.AddView(FOutDir);
        AddLog(Format('Tabs: %d, active "%s"', [FFrame.ViewCount, FFrame.ActiveView.TabCaption]));
        AddLog('ViewFor(workdir) is tab 0: ' + BoolToStr(FFrame.ViewFor(FWorkDir) = FFrame.Views[0], True) +
          ', tabs: ' + IntToStr(FFrame.ViewCount));
        AddLog('ViewFor(outdir) is tab 1: ' + BoolToStr(FFrame.ViewFor(FOutDir) = FFrame.Views[1], True) +
          ', tabs: ' + IntToStr(FFrame.ViewCount));
      end;
    19:
      begin
        AddLog('MCP clients after stop: ' + IntToStr(FMcp.ClientCount));
        FTimer.Enabled := False;
        FForm.Close;
      end;
  end;
end;

var
  Script: TScript;
begin
  Application.Initialize;
  Script := TScript.Create(ParamStr(1), ParamStr(2));
  try
    Application.Run;
  finally
    Script.Free;
  end;
end.
