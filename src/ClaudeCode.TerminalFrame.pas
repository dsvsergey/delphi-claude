unit ClaudeCode.TerminalFrame;

{ Frame hosted in the "Claude Code" dockable IDE window: xterm.js in WebView2,
  wired to the Claude Code CLI running in a ConPTY. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.NetEncoding,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.ExtCtrls, Vcl.StdCtrls,
  ClaudeCode.WebViewHost, ClaudeCode.ConPty;

const
  WM_CC_HOSTKEY = WM_USER + 301;
  WM_CC_OPENLINK = WM_USER + 302;

type
  TTerminalHostInfo = record
    Port: Integer;      // IDE MCP server port, 0 when not running
    WorkDir: string;
    Command: string;    // e.g. 'claude'
    ExtraArgs: string;  // appended to Command, e.g. --mcp-config for the Delphi tools
    Background: TColor; // IDE window colour, decides light/dark terminal theme
    FontName: string;   // code editor font; empty = default
    FontSize: Integer;  // points
  end;

  TTerminalHostInfoFunc = reference to function: TTerminalHostInfo;
  { Execute=False: return True if the IDE wants this key (it is then taken from the terminal).
    Execute=True: perform the IDE command. }
  TTerminalHostKeyFunc = reference to function(Key: Word; Shift: TShiftState; Execute: Boolean): Boolean;

  TClaudeTerminalFrame = class(TFrame)
  private
    FToolbar: TPanel;
    FStatus: TLabel;
    FMessage: TLabel;
    FWeb: TWebViewHost;
    FSession: TConPtySession;
    FEncoder: TBase64Encoding;
    FPageReady: Boolean;
    FCols: Integer;
    FRows: Integer;
    FStartPending: Boolean;
    FPendingArgs: string;
    FBacklog: TBytes;
    FIdleHintShown: Boolean;
    FLinks: TStringList;
    FOnDump: TProc<string>;
    FSessionDir: string;
    FTitle: string;         // terminal title set by Claude
    FProgress: Boolean;     // OSC 9;4 progress is showing
    FBusy: Boolean;         // Claude is working on a turn
    FAttention: Boolean;    // Claude asked for the user (bell / notification) since the last key
    FCaptionMarked: Boolean;
    procedure BuildUI;
    function AddButton(const ACaption, AHint: string; AOnClick: TNotifyEvent): TButton;
    procedure LoadPage;
    procedure WebError(Sender: TObject; const Error: string);
    procedure WebMessage(Sender: TObject; const Msg: string);
    procedure WebAccelerator(Sender: TObject; VirtualKey: Cardinal; Shift: TShiftState;
      var HandledByHost: Boolean);
    procedure PageReady(Cols, Rows: Integer);
    procedure SessionOutput(const Data: TBytes);
    procedure SessionExit(ExitCode: Cardinal);
    procedure SendBytes(const Data: TBytes);
    procedure WriteLocal(const S: string);
    procedure SendConfig;
    procedure DoStart(const Args: string);
    procedure ShowIdleHint;
    procedure UpdateActivity;
    procedure UpdateStatus;
    procedure AlertUser;
    procedure ClearAlert;
    procedure PasteFromClipboard;
    procedure PastePaths(const Paths: TArray<string>);
    procedure NewClick(Sender: TObject);
    procedure ContinueClick(Sender: TObject);
    procedure ResumeClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure WMHostKey(var Msg: TMessage); message WM_CC_HOSTKEY;
    procedure WMOpenLink(var Msg: TMessage); message WM_CC_OPENLINK;
  public
    class var HostInfo: TTerminalHostInfoFunc;
    class var HostKey: TTerminalHostKeyFunc;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure StartSession(const Args: string = '');
    procedure StopSession;
    procedure FocusTerminal;
    function SessionRunning: Boolean;
    { Diagnostics/tests: feed input through the terminal page, read back its screen text. }
    procedure InjectInput(const S: string);
    { Pastes S like Ctrl+V: multi-line text is not submitted line by line. Submit presses Enter after it. }
    procedure PasteInput(const S: string; Submit: Boolean = False);
    procedure RequestDump(const OnDump: TProc<string>);
    { Working folder of the running session (paths in requests are relative to it). }
    property SessionDir: string read FSessionDir;
  end;

var
  // The live panel frame (the IDE creates at most one).
  ActiveTerminalFrame: TClaudeTerminalFrame;

implementation

{$R *.dfm}
{$R 'terminal\terminal.res'}
{$IFDEF WIN64}
{$R 'terminal\loader64.res'}
{$ELSE}
{$R 'terminal\loader32.res'}
{$ENDIF}

uses
  Winapi.ShellAPI, System.JSON, System.Types, System.StrUtils, System.IOUtils, Vcl.Clipbrd,
  Vcl.Imaging.pngimage,
  ClaudeCode.Launcher;

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

function BuildTerminalHtml: string;
begin
  Result := LoadTextResource('CC_TERMINAL_HTML');
  Result := StringReplace(Result, '/*XTERM_CSS*/', LoadTextResource('CC_XTERM_CSS'), []);
  Result := StringReplace(Result, '/*XTERM_JS*/', LoadTextResource('CC_XTERM_JS'), []);
  Result := StringReplace(Result, '/*FIT_JS*/', LoadTextResource('CC_FIT_JS'), []);
  Result := StringReplace(Result, '/*WEBLINKS_JS*/', LoadTextResource('CC_WEBLINKS_JS'), []);
  Result := StringReplace(Result, '/*UNICODE11_JS*/', LoadTextResource('CC_UNICODE11_JS'), []);
end;

function IsDark(Background: TColor): Boolean;
var
  RGB: Longint;
begin
  RGB := ColorToRGB(Background);
  Result := (GetRValue(RGB) * 299 + GetGValue(RGB) * 587 + GetBValue(RGB) * 114) div 1000 < 128;
end;

function ShiftToInt(Shift: TShiftState): Integer;
begin
  Result := 0;
  if ssShift in Shift then Result := Result or 1;
  if ssCtrl in Shift then Result := Result or 2;
  if ssAlt in Shift then Result := Result or 4;
end;

function IntToShift(Value: Integer): TShiftState;
begin
  Result := [];
  if Value and 1 <> 0 then Include(Result, ssShift);
  if Value and 2 <> 0 then Include(Result, ssCtrl);
  if Value and 4 <> 0 then Include(Result, ssAlt);
end;

function ColorToHtml(C: TColor): string;
var
  RGB: Longint;
begin
  RGB := ColorToRGB(C);
  Result := Format('#%.2x%.2x%.2x', [GetRValue(RGB), GetGValue(RGB), GetBValue(RGB)]);
end;

{ TClaudeTerminalFrame }

constructor TClaudeTerminalFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEncoder := TBase64Encoding.Create(0); // no line breaks
  FLinks := TStringList.Create;
  FCols := 120;
  FRows := 30;
  BuildUI;
  ActiveTerminalFrame := Self;
end;

destructor TClaudeTerminalFrame.Destroy;
begin
  if ActiveTerminalFrame = Self then
    ActiveTerminalFrame := nil;
  FreeAndNil(FSession);
  FLinks.Free;
  FEncoder.Free;
  inherited;
end;

function TClaudeTerminalFrame.AddButton(const ACaption, AHint: string; AOnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := FToolbar;
  Result.Caption := ACaption;
  Result.Hint := AHint;
  Result.ShowHint := True;
  Result.Width := 20 + Length(ACaption) * 7;
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(2, 2, 2, 2);
  Result.Align := alLeft;
  Result.Left := MaxInt div 2; // append after the previous buttons
  Result.OnClick := AOnClick;
  Result.TabStop := False;
end;

procedure TClaudeTerminalFrame.BuildUI;
begin
  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := 30;
  FToolbar.BevelOuter := bvNone;

  AddButton('New Session', 'Start a new Claude Code session', NewClick);
  AddButton('Continue', 'Continue the most recent conversation (claude --continue)', ContinueClick);
  AddButton('Resume...', 'Pick a previous conversation (claude --resume)', ResumeClick);
  AddButton('Stop', 'Stop the running Claude Code session', StopClick);

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FToolbar;
  FStatus.AlignWithMargins := True;
  FStatus.Margins.SetBounds(10, 8, 6, 2);
  FStatus.Align := alClient;
  FStatus.EllipsisPosition := epPathEllipsis;

  FMessage := TLabel.Create(Self);
  FMessage.Parent := Self;
  FMessage.Align := alTop;
  FMessage.AlignWithMargins := True;
  FMessage.Margins.SetBounds(8, 8, 8, 8);
  FMessage.WordWrap := True;
  FMessage.Visible := False;

  FWeb := TWebViewHost.Create(Self);
  FWeb.Parent := Self;
  FWeb.Align := alClient;
  if Assigned(HostInfo) then
    FWeb.Color := HostInfo().Background
  else
    FWeb.Color := clBlack;
  FWeb.OnError := WebError;
  FWeb.OnMessage := WebMessage;
  FWeb.OnAccelerator := WebAccelerator;
  LoadPage;
end;

procedure TClaudeTerminalFrame.LoadPage;
begin
  try
    FWeb.NavigateToString(BuildTerminalHtml);
  except
    on E: Exception do
      WebError(FWeb, 'Cannot load terminal page: ' + E.Message);
  end;
end;

procedure TClaudeTerminalFrame.WebError(Sender: TObject; const Error: string);
begin
  FMessage.Caption := Error + sLineBreak +
    'Use Tools > Claude Code > Open in External Console instead.';
  FMessage.Visible := True;
  FWeb.Visible := False;
end;

procedure TClaudeTerminalFrame.SendConfig;
var
  Cfg, Theme: TJSONObject;
  Info: TTerminalHostInfo;
  Bg: TColor;
  Dark: Boolean;
begin
  if not Assigned(HostInfo) then
    Exit;
  Info := HostInfo();
  Bg := Info.Background;
  Dark := IsDark(Bg);
  Theme := TJSONObject.Create;
  if Dark then
  begin
    Theme.AddPair('background', ColorToHtml(Bg));
    Theme.AddPair('foreground', '#cccccc');
    Theme.AddPair('cursor', '#aeafad');
    Theme.AddPair('selectionBackground', '#264f78');
  end
  else
  begin
    Theme.AddPair('background', ColorToHtml(Bg));
    Theme.AddPair('foreground', '#1e1e1e');
    Theme.AddPair('cursor', '#000000');
    Theme.AddPair('selectionBackground', '#add6ff');
    Theme.AddPair('yellow', '#949800');
    Theme.AddPair('brightYellow', '#b5ba00');
    Theme.AddPair('white', '#555555');
    Theme.AddPair('brightWhite', '#a5a5a5');
  end;
  Cfg := TJSONObject.Create;
  try
    Cfg.AddPair('theme', Theme);
    if Info.FontName <> '' then
      Cfg.AddPair('fontFamily', '''' + Info.FontName + ''', ''Cascadia Mono'', Consolas, monospace');
    if Info.FontSize > 0 then
      Cfg.AddPair('fontSize', TJSONNumber.Create(Round(Info.FontSize * 96 / 72)));
    FWeb.PostMessageToPage('c' + Cfg.ToJSON);
  finally
    Cfg.Free;
  end;
end;

procedure TClaudeTerminalFrame.WebMessage(Sender: TObject; const Msg: string);
var
  V: TJSONValue;
  O: TJSONObject;
  T, S: string;
  Arr: TJSONArray;
  I: Integer;
  Files: TArray<string>;
begin
  V := TJSONObject.ParseJSONValue(Msg);
  try
    if not (V is TJSONObject) then
      Exit;
    O := TJSONObject(V);
    T := O.GetValue<string>('t', '');
    if T = 'in' then
    begin
      S := O.GetValue<string>('d', '');
      if FAttention then
      begin
        FAttention := False;
        ClearAlert;
        UpdateStatus;
      end;
      if SessionRunning then
        FSession.WriteText(S)
      else if Pos(#13, S) > 0 then
        DoStart('');
    end
    else if T = 'resize' then
    begin
      FCols := O.GetValue<Integer>('cols', FCols);
      FRows := O.GetValue<Integer>('rows', FRows);
      if FSession <> nil then
        FSession.Resize(FCols, FRows);
    end
    else if T = 'ready' then
      PageReady(O.GetValue<Integer>('cols', FCols), O.GetValue<Integer>('rows', FRows))
    else if T = 'dump' then
    begin
      if Assigned(FOnDump) then
        FOnDump(O.GetValue<string>('text', ''));
    end
    else if T = 'copy' then
      Clipboard.AsText := O.GetValue<string>('text', '')
    else if T = 'pasteKey' then
      PasteFromClipboard
    else if T = 'files' then
    begin
      Arr := O.GetValue('paths') as TJSONArray;
      if Arr <> nil then
        for I := 0 to Arr.Count - 1 do
          Files := Files + [Arr.Items[I].Value];
      PastePaths(Files);
    end
    else if T = 'title' then
    begin
      FTitle := O.GetValue<string>('title', '');
      UpdateActivity;
    end
    else if T = 'progress' then
    begin
      // Windows Terminal progress states: 1 = value, 3 = indeterminate; 0 = none.
      FProgress := O.GetValue<Integer>('state', 0) in [1, 3];
      UpdateActivity;
    end
    else if T = 'attention' then
    begin
      FAttention := True;
      AlertUser;
      UpdateStatus;
    end
    else if T = 'link' then
    begin
      // Open outside the WebView2 callback.
      FLinks.Add(O.GetValue<string>('uri', ''));
      PostMessage(Handle, WM_CC_OPENLINK, 0, 0);
    end;
  finally
    V.Free;
  end;
end;

procedure TClaudeTerminalFrame.PageReady(Cols, Rows: Integer);
var
  Backlog: TBytes;
begin
  FPageReady := True;
  FCols := Cols;
  FRows := Rows;
  SendConfig;
  if Length(FBacklog) > 0 then
  begin
    Backlog := FBacklog;
    FBacklog := nil;
    SendBytes(Backlog);
  end;
  if FStartPending then
  begin
    FStartPending := False;
    DoStart(FPendingArgs);
  end
  else if SessionRunning then
  begin
    // The page was reloaded under a running session: make Claude redraw.
    FSession.Resize(FCols - 1, FRows);
    FSession.Resize(FCols, FRows);
  end
  else
    ShowIdleHint;
end;

procedure TClaudeTerminalFrame.ShowIdleHint;
var
  Dir: string;
begin
  if FIdleHintShown then
    Exit;
  FIdleHintShown := True;
  if Assigned(HostInfo) then
    Dir := HostInfo().WorkDir;
  WriteLocal(#27'[90mClaude Code' + IfThen(Dir <> '', ' - ' + Dir, '') + #13#10 +
    'Press Enter to start a session.'#27'[0m'#13#10);
end;

procedure TClaudeTerminalFrame.WebAccelerator(Sender: TObject; VirtualKey: Cardinal;
  Shift: TShiftState; var HandledByHost: Boolean);
begin
  // Keys go to Claude unless the IDE claims them (F-keys bound to IDE commands, our own shortcuts).
  if Assigned(HostKey) and HostKey(Word(VirtualKey), Shift, False) then
  begin
    HandledByHost := True;
    // Run the IDE command outside the WebView2 callback.
    PostMessage(Handle, WM_CC_HOSTKEY, VirtualKey, ShiftToInt(Shift));
  end;
end;

procedure TClaudeTerminalFrame.WMHostKey(var Msg: TMessage);
var
  Shift: TShiftState;
begin
  Shift := IntToShift(Msg.LParam);
  if Assigned(HostKey) then
    HostKey(Word(Msg.WParam), Shift, True);
end;

procedure TClaudeTerminalFrame.WMOpenLink(var Msg: TMessage);
var
  Uri: string;
begin
  while FLinks.Count > 0 do
  begin
    Uri := FLinks[0];
    FLinks.Delete(0);
    if Uri.StartsWith('http://', True) or Uri.StartsWith('https://', True) then
      ShellExecute(0, 'open', PChar(Uri), nil, nil, SW_SHOWNORMAL);
  end;
end;

procedure TClaudeTerminalFrame.SendBytes(const Data: TBytes);
begin
  if Length(Data) = 0 then
    Exit;
  if not FPageReady then
  begin
    FBacklog := FBacklog + Data;
    Exit;
  end;
  FWeb.PostMessageToPage('o' + FEncoder.EncodeBytesToString(Data));
end;

procedure TClaudeTerminalFrame.WriteLocal(const S: string);
begin
  SendBytes(TEncoding.UTF8.GetBytes(S));
end;

procedure TClaudeTerminalFrame.SessionOutput(const Data: TBytes);
begin
  SendBytes(Data);
end;

{ Claude animates a spinner at the start of the title while it works (braille dots U+2800..U+28FF or
  the U+00B7, U+2722, U+2736, U+273B, U+273D glyphs); the idle title starts with U+2733. }
function TitleShowsSpinner(const Title: string): Boolean;
var
  C: Char;
begin
  if Title = '' then
    Exit(False);
  C := Title[1];
  Result := ((Ord(C) >= $2800) and (Ord(C) <= $28FF)) or
    (C = #$00B7) or (C = #$2722) or (C = #$2736) or (C = #$273B) or (C = #$273D);
end;

function TitleText(const Title: string): string;
begin
  // Without the leading status glyph.
  Result := Title;
  if (Result <> '') and (Ord(Result[1]) > $7F) then
    Result := TrimLeft(Copy(Result, 2, MaxInt));
end;

procedure TClaudeTerminalFrame.UpdateActivity;
var
  WasBusy: Boolean;
begin
  WasBusy := FBusy;
  FBusy := FProgress or TitleShowsSpinner(FTitle);
  if WasBusy and not FBusy then
    AlertUser; // a turn finished
  UpdateStatus;
end;

procedure TClaudeTerminalFrame.UpdateStatus;
var
  State, Detail: string;
begin
  if not SessionRunning then
    Exit;
  if FAttention then
    State := 'Waiting for you'
  else if FBusy then
    State := 'Working...'
  else
    State := 'Ready';
  Detail := TitleText(FTitle);
  if Detail = '' then
    Detail := FSessionDir;
  FStatus.Caption := State + '   ' + Detail;
end;

{ Tells the user Claude needs them when they are not looking at the panel: the IDE flashes
  on the taskbar and the panel's caption gets a marker. }
procedure TClaudeTerminalFrame.AlertUser;
var
  Info: TFlashWInfo;
  Form: TCustomForm;
begin
  if Application.Active and Showing then
    Exit;
  if not Application.Active and (Application.MainFormHandle <> 0) then
  begin
    Info.cbSize := SizeOf(Info);
    Info.hwnd := Application.MainFormHandle;
    Info.dwFlags := FLASHW_TRAY or FLASHW_TIMERNOFG;
    Info.uCount := 0;
    Info.dwTimeout := 0;
    FlashWindowEx(Info);
  end;
  Form := GetParentForm(Self);
  if (Form <> nil) and not FCaptionMarked then
  begin
    Form.Caption := Form.Caption + ' *';
    FCaptionMarked := True;
  end;
end;

procedure TClaudeTerminalFrame.ClearAlert;
var
  Form: TCustomForm;
  S: string;
begin
  if not FCaptionMarked then
    Exit;
  FCaptionMarked := False;
  Form := GetParentForm(Self);
  if Form <> nil then
  begin
    S := Form.Caption;
    if S.EndsWith(' *') then
      Form.Caption := Copy(S, 1, Length(S) - 2);
  end;
end;

{ Paths for Claude's prompt, relative to the session folder when inside it: images as plain
  paths (Claude Code attaches them), other files as @-mentions, quoted when they contain spaces. }
procedure TClaudeTerminalFrame.PastePaths(const Paths: TArray<string>);
const
  ImageExts: array[0..5] of string = ('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp');
var
  Text, P, S, Base, Ext: string;
  IsImage: Boolean;
begin
  Text := '';
  Base := '';
  if FSessionDir <> '' then
    Base := IncludeTrailingPathDelimiter(FSessionDir);
  for P in Paths do
  begin
    Ext := LowerCase(ExtractFileExt(P));
    IsImage := MatchStr(Ext, ImageExts);
    if IsImage then
      S := P // absolute: Claude Code recognises image paths
    else if (Base <> '') and SameText(Copy(P, 1, Length(Base)), Base) then
      S := StringReplace(Copy(P, Length(Base) + 1, MaxInt), '\', '/', [rfReplaceAll])
    else
      S := StringReplace(P, '\', '/', [rfReplaceAll]);
    if DirectoryExists(P) and not S.EndsWith('/') then
      S := S + '/';
    if S.Contains(' ') then
      S := '"' + S + '"';
    if not IsImage then
      S := '@' + S;
    Text := Text + S + ' ';
  end;
  if Text <> '' then
    PasteInput(Text);
end;

procedure TClaudeTerminalFrame.PasteFromClipboard;
var
  Drop: THandle;
  Count, I: Integer;
  Buf: array[0..MAX_PATH] of Char;
  Files: TArray<string>;
  Bmp: TBitmap;
  Png: TPngImage;
  Dir, FileName: string;
begin
  try
    if Clipboard.HasFormat(CF_HDROP) then
    begin
      // Files copied in Explorer.
      Clipboard.Open;
      try
        Drop := Clipboard.GetAsHandle(CF_HDROP);
        Count := DragQueryFile(Drop, $FFFFFFFF, nil, 0);
        for I := 0 to Count - 1 do
          if DragQueryFile(Drop, I, Buf, Length(Buf)) > 0 then
            Files := Files + [string(Buf)];
      finally
        Clipboard.Close;
      end;
      PastePaths(Files);
    end
    else if Clipboard.HasFormat(CF_BITMAP) and not Clipboard.HasFormat(CF_UNICODETEXT) then
    begin
      // A screenshot or copied picture: save it and give Claude the file.
      Dir := TPath.Combine(TPath.GetTempPath, 'claude-delphi');
      ForceDirectories(Dir);
      FileName := TPath.Combine(Dir, 'clipboard-' + FormatDateTime('yyyymmdd-hhnnsszzz', Now) + '.png');
      Bmp := TBitmap.Create;
      Png := TPngImage.Create;
      try
        Bmp.Assign(Clipboard);
        Png.Assign(Bmp);
        Png.SaveToFile(FileName);
      finally
        Png.Free;
        Bmp.Free;
      end;
      PastePaths([FileName]);
    end
    else if Clipboard.HasFormat(CF_UNICODETEXT) then
      PasteInput(Clipboard.AsText);
  except
    on E: Exception do
      WriteLocal(#13#10#27'[31mPaste failed: ' + E.Message + #27'[0m'#13#10);
  end;
end;

procedure TClaudeTerminalFrame.SessionExit(ExitCode: Cardinal);
begin
  FBusy := False;
  FProgress := False;
  FAttention := False;
  ClearAlert;
  WriteLocal(#13#10#27'[90m[Claude Code exited with code ' + IntToStr(Integer(ExitCode)) +
    '. Press Enter to start a new session.]'#27'[0m'#13#10);
  FStatus.Caption := 'Not running';
end;

function TClaudeTerminalFrame.SessionRunning: Boolean;
begin
  Result := (FSession <> nil) and FSession.Running;
end;

procedure TClaudeTerminalFrame.StartSession(const Args: string);
begin
  if not FPageReady then
  begin
    FStartPending := True;
    FPendingArgs := Args;
    Exit;
  end;
  DoStart(Args);
end;

procedure TClaudeTerminalFrame.DoStart(const Args: string);
var
  Info: TTerminalHostInfo;
  Cmd, Dir: string;
begin
  if not Assigned(HostInfo) then
    Exit;
  Info := HostInfo();
  FreeAndNil(FSession);
  FWeb.PostMessageToPage('r');
  if Info.Port = 0 then
  begin
    WriteLocal(#27'[31mThe Claude Code IDE server is not running (see Tools > Claude Code > Status and Log).'#27'[0m'#13#10);
    Exit;
  end;
  Cmd := Trim(Info.Command + ' ' + Info.ExtraArgs + ' ' + Args);
  Dir := Info.WorkDir;
  if (Dir = '') or not DirectoryExists(Dir) then
    Dir := GetEnvironmentVariable('USERPROFILE');
  FSession := TConPtySession.Create;
  FSession.OnOutput := SessionOutput;
  FSession.OnExit := SessionExit;
  try
    FSession.Start(ResolveCommandLine(Cmd), Dir, ClaudeEnvironmentBlock(Info.Port), FCols, FRows);
    FStatus.Caption := Dir;
    FSessionDir := Dir;
    FTitle := '';
    FBusy := False;
    FProgress := False;
    FAttention := False;
    UpdateStatus;
    FStatus.Hint := Cmd;
    FStatus.ShowHint := True;
  except
    on E: Exception do
    begin
      FreeAndNil(FSession);
      WriteLocal(#27'[31mCould not start "' + Cmd + '": ' + E.Message + #27'[0m'#13#10 +
        'Check Tools > Claude Code > Settings. Press Enter to retry.'#13#10);
      FStatus.Caption := 'Not running';
    end;
  end;
  FocusTerminal;
end;

procedure TClaudeTerminalFrame.StopSession;
begin
  if SessionRunning then
  begin
    FSession.OnExit := nil;
    FreeAndNil(FSession);
    WriteLocal(#13#10#27'[90m[Session stopped. Press Enter to start a new session.]'#27'[0m'#13#10);
    FStatus.Caption := 'Not running';
  end;
end;

procedure TClaudeTerminalFrame.FocusTerminal;
begin
  ClearAlert;
  if FWeb.Visible and FWeb.CanFocus then
  begin
    FWeb.SetFocus;
    FWeb.FocusPage;
    FWeb.PostMessageToPage('f');
  end;
end;

procedure TClaudeTerminalFrame.InjectInput(const S: string);
begin
  FWeb.PostMessageToPage('i' + S);
end;

procedure TClaudeTerminalFrame.PasteInput(const S: string; Submit: Boolean);
begin
  if Submit then
    FWeb.PostMessageToPage('s' + S)
  else
    FWeb.PostMessageToPage('p' + S);
end;

procedure TClaudeTerminalFrame.RequestDump(const OnDump: TProc<string>);
begin
  FOnDump := OnDump;
  FWeb.PostMessageToPage('d');
end;

procedure TClaudeTerminalFrame.NewClick(Sender: TObject);
begin
  StartSession('');
end;

procedure TClaudeTerminalFrame.ContinueClick(Sender: TObject);
begin
  StartSession('--continue');
end;

procedure TClaudeTerminalFrame.ResumeClick(Sender: TObject);
begin
  StartSession('--resume');
end;

procedure TClaudeTerminalFrame.StopClick(Sender: TObject);
begin
  StopSession;
  FocusTerminal;
end;

end.
