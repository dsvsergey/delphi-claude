unit ClaudeCode.TerminalFrame;

{ Frame hosted in the "Claude Code" dockable IDE window: tabs of Claude Code sessions.
  Each tab is a TClaudeSessionView: xterm.js in WebView2, wired to the Claude Code CLI
  running in a ConPTY. The frame's own methods act on the active tab. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.NetEncoding,
  System.Generics.Collections, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.ExtCtrls,
  Vcl.StdCtrls, Vcl.ComCtrls, ClaudeCode.WebViewHost, ClaudeCode.ConPty, ClaudeCode.Compat;

const
  WM_CC_HOSTKEY = WM_USER + 301;
  WM_CC_OPENLINK = WM_USER + 302;
  WM_CC_CLOSETAB = WM_USER + 303;

type
  TTerminalHostInfo = record
    Port: Integer;      // IDE MCP server port, 0 when not running
    WorkDir: string;
    Command: string;    // e.g. 'claude'
    ExtraArgs: string;  // appended to Command, e.g. --mcp-config for the Delphi tools
    Background: TColor; // IDE window colour, decides light/dark terminal theme
    FontName: string;   // code editor font; empty = default
    FontSize: Integer;  // points
    ContinueLast: Boolean; // sessions not started with New Session continue the folder's last conversation
  end;

  TTerminalHostInfoFunc = reference to function: TTerminalHostInfo;
  { Execute=False: return True if the IDE wants this key (it is then taken from the terminal).
    Execute=True: perform the IDE command. }
  TTerminalHostKeyFunc = reference to function(Key: Word; Shift: TShiftState; Execute: Boolean): Boolean;
  { Paths of what is being dragged inside the IDE (the Project Manager's drag carries no file names). }
  TTerminalDropSourceFunc = reference to function: TArray<string>;

  TClaudeTerminalFrame = class;

  { One Claude Code session: the terminal page and the ConPTY process behind it. }
  TClaudeSessionView = class(TCustomPanel)
  private
    FFrame: TClaudeTerminalFrame;
    FMessage: TLabel;
    FWeb: TWebViewHost;
    FSession: TConPtySession;
    FEncoder: TBase64Encoding;
    FPageReady: Boolean;
    FCols: Integer;
    FRows: Integer;
    FStartPending: Boolean;
    FPendingArgs: string;
    FPendingFresh: Boolean;
    FAutoContinued: Boolean; // started with --continue on our own (not by the user's Continue)
    FStartTick: UInt64;
    FBacklog: TBytes;
    FIdleHintShown: Boolean;
    FLinks: TStringList;
    FOnDump: TProc<string>;
    FWorkDir: string;       // folder the session runs (or will run) in
    FCommand: string;
    FTitle: string;         // terminal title set by Claude
    FUsage: string;         // model, context and cost from Claude Code's status line
    FDragItems: TArray<string>; // noted when a drag from an IDE tree entered the terminal
    FDragTick: UInt64;
    FProgress: Boolean;     // OSC 9;4 progress is showing
    FBusy: Boolean;         // Claude is working on a turn
    FAttention: Boolean;    // Claude asked for the user (bell / notification) since the last key
    procedure BuildUI;
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
    procedure DoStart(const Args: string; Fresh: Boolean);
    procedure ShowIdleHint;
    procedure UpdateActivity;
    procedure SetAttention(Value: Boolean);
    procedure Changed;
    procedure PasteFromClipboard;
    procedure PastePaths(const Paths: TArray<string>);
    procedure DropWithoutFiles(const Text, Types: string);
    procedure WMHostKey(var Msg: TMessage); message WM_CC_HOSTKEY;
    procedure WMOpenLink(var Msg: TMessage); message WM_CC_OPENLINK;
  public
    constructor CreateView(AFrame: TClaudeTerminalFrame; const AWorkDir: string);
    destructor Destroy; override;
    { Fresh: a new conversation even when the host continues the last one by default. }
    procedure StartSession(const Args: string = ''; Fresh: Boolean = False);
    procedure StopSession;
    procedure FocusTerminal;
    function SessionRunning: Boolean;
    procedure InjectInput(const S: string);
    procedure PasteInput(const S: string; Submit: Boolean = False);
    procedure RequestDump(const OnDump: TProc<string>);
    function StateText: string;
    function TabCaption: string;
    property WorkDir: string read FWorkDir;
    property Busy: Boolean read FBusy;
    property Attention: Boolean read FAttention;
    property Title: string read FTitle;
    property Command: string read FCommand;
  end;

  TClaudeTerminalFrame = class(TFrame)
  private
    FToolbar: TPanel;
    FStatus: TLabel;
    FPages: TPageControl;
    FCaptionMarked: Boolean;
    function AddButton(const ACaption, AHint: string; AOnClick: TNotifyEvent): TButton;
    procedure BuildUI;
    function GetActiveView: TClaudeSessionView;
    function GetView(Index: Integer): TClaudeSessionView;
    function GetViewCount: Integer;
    procedure PagesChange(Sender: TObject);
    procedure PagesMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure UpdateStatus;
    procedure ViewChanged(View: TClaudeSessionView);
    procedure ViewNeedsUser(View: TClaudeSessionView);
    procedure MarkCaption(Marked: Boolean);
    procedure CloseView(View: TClaudeSessionView);
    procedure NewClick(Sender: TObject);
    procedure ContinueClick(Sender: TObject);
    procedure ResumeClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure NewTabClick(Sender: TObject);
    procedure CloseTabClick(Sender: TObject);
    procedure WMCloseTab(var Msg: TMessage); message WM_CC_CLOSETAB;
  public
    class var HostInfo: TTerminalHostInfoFunc;
    class var HostKey: TTerminalHostKeyFunc;
    class var DropSource: TTerminalDropSourceFunc;
    { What an IDE tree is dragging right now (asked while the drag enters the terminal). }
    class var DragSource: TTerminalDropSourceFunc;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { A new tab for WorkDir (the IDE's current project folder when empty), made active. }
    function AddView(const WorkDir: string = ''): TClaudeSessionView;
    { The tab for WorkDir: an existing one, the active tab when it has no session yet, or a new one. }
    function ViewFor(const WorkDir: string): TClaudeSessionView;
    { A tab for a new session in WorkDir: the active one when nothing was started in it, else a new tab. }
    function UnusedView(const WorkDir: string): TClaudeSessionView;
    { The status line of the sessions running in Dir (model, context, cost). }
    procedure SetSessionUsage(const Dir, Text: string);
    procedure ActivateView(View: TClaudeSessionView);
    { The active tab. }
    procedure StartSession(const Args: string = ''; Fresh: Boolean = False);
    procedure StopSession;
    procedure FocusTerminal;
    function SessionRunning: Boolean;
    function AnySessionRunning: Boolean;
    { Diagnostics/tests: feed input through the terminal page, read back its screen text. }
    procedure InjectInput(const S: string);
    { Pastes S like Ctrl+V: multi-line text is not submitted line by line. Submit presses Enter after it. }
    procedure PasteInput(const S: string; Submit: Boolean = False);
    procedure RequestDump(const OnDump: TProc<string>);
    { Working folder of the active session (paths in requests are relative to it). }
    function SessionDir: string;
    property ActiveView: TClaudeSessionView read GetActiveView;
    property ViewCount: Integer read GetViewCount;
    property Views[Index: Integer]: TClaudeSessionView read GetView;
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
  ClaudeCode.Launcher, ClaudeCode.Utils;

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

{ TClaudeSessionView }

constructor TClaudeSessionView.CreateView(AFrame: TClaudeTerminalFrame; const AWorkDir: string);
begin
  inherited Create(AFrame);
  FFrame := AFrame;
  FWorkDir := AWorkDir;
  FEncoder := TBase64Encoding.Create(0); // no line breaks
  FLinks := TStringList.Create;
  FCols := 120;
  FRows := 30;
  BevelOuter := bvNone;
  Caption := '';
  ShowCaption := False;
end;

destructor TClaudeSessionView.Destroy;
begin
  FreeAndNil(FSession);
  FLinks.Free;
  FEncoder.Free;
  inherited;
end;

procedure TClaudeSessionView.BuildUI;
begin
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
  if Assigned(TClaudeTerminalFrame.HostInfo) then
    FWeb.Color := TClaudeTerminalFrame.HostInfo().Background
  else
    FWeb.Color := clBlack;
  FWeb.OnError := WebError;
  FWeb.OnMessage := WebMessage;
  FWeb.OnAccelerator := WebAccelerator;
  LoadPage;
end;

procedure TClaudeSessionView.LoadPage;
begin
  try
    FWeb.NavigateToString(BuildTerminalHtml);
  except
    on E: Exception do
      WebError(FWeb, 'Cannot load terminal page: ' + E.Message);
  end;
end;

procedure TClaudeSessionView.WebError(Sender: TObject; const Error: string);
begin
  FMessage.Caption := Error + sLineBreak +
    'Use Tools > Claude Code > Open in External Console instead.';
  FMessage.Visible := True;
  FWeb.Visible := False;
end;

procedure TClaudeSessionView.SendConfig;
var
  Cfg, Theme: TJSONObject;
  Info: TTerminalHostInfo;
  Bg: TColor;
begin
  if not Assigned(TClaudeTerminalFrame.HostInfo) then
    Exit;
  Info := TClaudeTerminalFrame.HostInfo();
  Bg := Info.Background;
  Theme := TJSONObject.Create;
  if IsDark(Bg) then
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

procedure TClaudeSessionView.WebMessage(Sender: TObject; const Msg: string);
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
      SetAttention(False);
      if SessionRunning then
        FSession.WriteText(S)
      else if Pos(#13, S) > 0 then
        DoStart('', False);
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
    else if T = 'dragIde' then
    begin
      FDragItems := nil;
      if Assigned(TClaudeTerminalFrame.DragSource) then
        FDragItems := TClaudeTerminalFrame.DragSource();
      FDragTick := GetTickCount64;
    end
    else if T = 'dropOther' then
      DropWithoutFiles(O.GetValue<string>('text', ''), O.GetValue<string>('types', ''))
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
      SetAttention(True);
      FFrame.ViewNeedsUser(Self);
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

procedure TClaudeSessionView.PageReady(Cols, Rows: Integer);
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
    DoStart(FPendingArgs, FPendingFresh);
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

procedure TClaudeSessionView.ShowIdleHint;
var
  Dir: string;
begin
  if FIdleHintShown then
    Exit;
  FIdleHintShown := True;
  Dir := FWorkDir;
  if (Dir = '') and Assigned(TClaudeTerminalFrame.HostInfo) then
    Dir := TClaudeTerminalFrame.HostInfo().WorkDir;
  WriteLocal(#27'[90mClaude Code' + IfThen(Dir <> '', ' - ' + Dir, '') + #13#10 +
    'Press Enter to start a session.'#27'[0m'#13#10);
end;

procedure TClaudeSessionView.WebAccelerator(Sender: TObject; VirtualKey: Cardinal;
  Shift: TShiftState; var HandledByHost: Boolean);
begin
  // Keys go to Claude unless the IDE claims them (F-keys bound to IDE commands, our own shortcuts).
  if Assigned(TClaudeTerminalFrame.HostKey) and TClaudeTerminalFrame.HostKey(Word(VirtualKey), Shift, False) then
  begin
    HandledByHost := True;
    // Run the IDE command outside the WebView2 callback.
    PostMessage(Handle, WM_CC_HOSTKEY, VirtualKey, ShiftToInt(Shift));
  end;
end;

procedure TClaudeSessionView.WMHostKey(var Msg: TMessage);
begin
  if Assigned(TClaudeTerminalFrame.HostKey) then
    TClaudeTerminalFrame.HostKey(Word(Msg.WParam), IntToShift(Msg.LParam), True);
end;

procedure TClaudeSessionView.WMOpenLink(var Msg: TMessage);
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

procedure TClaudeSessionView.SendBytes(const Data: TBytes);
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

procedure TClaudeSessionView.WriteLocal(const S: string);
begin
  SendBytes(TEncoding.UTF8.GetBytes(S));
end;

procedure TClaudeSessionView.SessionOutput(const Data: TBytes);
begin
  SendBytes(Data);
end;

procedure TClaudeSessionView.UpdateActivity;
var
  WasBusy: Boolean;
begin
  WasBusy := FBusy;
  FBusy := FProgress or TitleShowsSpinner(FTitle);
  Changed;
  if WasBusy and not FBusy then
    FFrame.ViewNeedsUser(Self); // a turn finished
end;

procedure TClaudeSessionView.SetAttention(Value: Boolean);
begin
  if FAttention = Value then
    Exit;
  FAttention := Value;
  Changed;
end;

procedure TClaudeSessionView.Changed;
begin
  FFrame.ViewChanged(Self);
end;

function TClaudeSessionView.StateText: string;
var
  Detail: string;
begin
  if not SessionRunning then
    Exit('Not running   ' + FWorkDir);
  if FAttention then
    Result := 'Waiting for you'
  else if FBusy then
    Result := 'Working...'
  else
    Result := 'Ready';
  Detail := TitleText(FTitle);
  if Detail = '' then
    Detail := FWorkDir;
  Result := Result + '   ' + Detail;
  if FUsage <> '' then
    Result := Result + '   ' + FUsage;
end;

function TClaudeSessionView.TabCaption: string;
begin
  if FWorkDir <> '' then
    Result := ExtractFileName(ExcludeTrailingPathDelimiter(FWorkDir))
  else
    Result := 'Claude';
  if not SessionRunning then
    Exit;
  if FAttention then
    Result := Result + ' !'
  else if FBusy then
    Result := Result + ' ' + #$25CF; // black circle
end;

{ Paths for Claude's prompt, relative to the session folder when inside it: images as plain
  paths (Claude Code attaches them), other files as @-mentions, quoted when they contain spaces. }
procedure TClaudeSessionView.PastePaths(const Paths: TArray<string>);
const
  ImageExts: array[0..5] of string = ('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp');
var
  Text, P, S, Base, Ext: string;
  IsImage: Boolean;
begin
  Text := '';
  Base := '';
  if FWorkDir <> '' then
    Base := IncludeTrailingPathDelimiter(FWorkDir);
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

procedure TClaudeSessionView.DropWithoutFiles(const Text, Types: string);
var
  Paths: TArray<string>;
  Pid: DWORD;
begin
  // A drag inside the IDE (Project Manager nodes) brings no file names: the IDE says what was dragged.
  // Only while the IDE is the active application, so a drop from another program is never mistaken for it.
  Log('Drop without files; types: ' + Types);
  Paths := nil;
  GetWindowThreadProcessId(GetForegroundWindow, Pid);
  // What the drag carried, noted when it entered (all selected nodes, Structure view items too);
  // otherwise the node selected in the Project Manager.
  if (Length(FDragItems) > 0) and (GetTickCount64 - FDragTick < 120000) then
    Paths := FDragItems
  else if Assigned(TClaudeTerminalFrame.DropSource) and (Pid = GetCurrentProcessId) then
    Paths := TClaudeTerminalFrame.DropSource();
  FDragItems := nil;
  // Text that is not just the dragged node's name (e.g. code dragged from the editor) stays text.
  if (Length(Paths) > 0) and ((Trim(Text) = '') or
     SameText(Trim(Text), ExtractFileName(ExcludeTrailingPathDelimiter(Paths[0])))) then
    PastePaths(Paths)
  else if Text <> '' then
    PasteInput(Text);
end;

procedure TClaudeSessionView.PasteFromClipboard;
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

procedure TClaudeSessionView.SessionExit(ExitCode: Cardinal);
begin
  // Our own --continue found nothing to continue after all: start a new conversation instead.
  if FAutoContinued and (ExitCode <> 0) and (GetTickCount64 - FStartTick < 10000) then
  begin
    FAutoContinued := False;
    DoStart('', True);
    Exit;
  end;
  FBusy := False;
  FProgress := False;
  FAttention := False;
  WriteLocal(#13#10#27'[90m[Claude Code exited with code ' + IntToStr(Integer(ExitCode)) +
    '. Press Enter to start a new session.]'#27'[0m'#13#10);
  Changed;
end;

function TClaudeSessionView.SessionRunning: Boolean;
begin
  Result := (FSession <> nil) and FSession.Running;
end;

procedure TClaudeSessionView.StartSession(const Args: string; Fresh: Boolean);
begin
  if FWeb = nil then
    BuildUI;
  if not FPageReady then
  begin
    FStartPending := True;
    FPendingArgs := Args;
    FPendingFresh := Fresh;
    Exit;
  end;
  DoStart(Args, Fresh);
end;

procedure TClaudeSessionView.DoStart(const Args: string; Fresh: Boolean);
var
  Info: TTerminalHostInfo;
  Cmd, StartArgs: string;
begin
  if not Assigned(TClaudeTerminalFrame.HostInfo) then
    Exit;
  Info := TClaudeTerminalFrame.HostInfo();
  FreeAndNil(FSession);
  FWeb.PostMessageToPage('r');
  if Info.Port = 0 then
  begin
    WriteLocal(#27'[31mThe Claude Code IDE server is not running (see Tools > Claude Code > Status and Log).'#27'[0m'#13#10);
    Exit;
  end;
  if FWorkDir = '' then
    FWorkDir := Info.WorkDir;
  if (FWorkDir = '') or not DirectoryExists(FWorkDir) then
    FWorkDir := GetEnvironmentVariable('USERPROFILE');
  // Opening the panel picks up the folder's last conversation (if there is one to continue).
  StartArgs := Args;
  if (StartArgs = '') and not Fresh and Info.ContinueLast and HasClaudeConversation(FWorkDir) then
    StartArgs := '--continue';
  FAutoContinued := StartArgs <> Args;
  FStartTick := GetTickCount64;
  Cmd := Trim(Info.Command + ' ' + Info.ExtraArgs + ' ' + StartArgs);
  FCommand := Cmd;
  FSession := TConPtySession.Create;
  FSession.OnOutput := SessionOutput;
  FSession.OnExit := SessionExit;
  FTitle := '';
  FUsage := '';
  FBusy := False;
  FProgress := False;
  FAttention := False;
  try
    FSession.Start(ResolveCommandLine(Cmd), FWorkDir, ClaudeEnvironmentBlock(Info.Port), FCols, FRows);
  except
    on E: Exception do
    begin
      FreeAndNil(FSession);
      WriteLocal(#27'[31mCould not start "' + Cmd + '": ' + E.Message + #27'[0m'#13#10 +
        'Check Tools > Claude Code > Settings. Press Enter to retry.'#13#10);
    end;
  end;
  Changed;
  FocusTerminal;
end;

procedure TClaudeSessionView.StopSession;
begin
  if SessionRunning then
  begin
    FSession.OnExit := nil;
    FreeAndNil(FSession);
    FBusy := False;
    FAttention := False;
    WriteLocal(#13#10#27'[90m[Session stopped. Press Enter to start a new session.]'#27'[0m'#13#10);
    Changed;
  end;
end;

procedure TClaudeSessionView.FocusTerminal;
begin
  if (FWeb <> nil) and FWeb.Visible and FWeb.CanFocus then
  begin
    FWeb.SetFocus;
    FWeb.FocusPage;
    FWeb.PostMessageToPage('f');
  end;
end;

procedure TClaudeSessionView.InjectInput(const S: string);
begin
  if FWeb <> nil then
    FWeb.PostMessageToPage('i' + S);
end;

procedure TClaudeSessionView.PasteInput(const S: string; Submit: Boolean);
begin
  if FWeb = nil then
    Exit;
  if Submit then
    FWeb.PostMessageToPage('s' + S)
  else
    FWeb.PostMessageToPage('p' + S);
end;

procedure TClaudeSessionView.RequestDump(const OnDump: TProc<string>);
begin
  FOnDump := OnDump;
  if FWeb <> nil then
    FWeb.PostMessageToPage('d');
end;

{ TClaudeTerminalFrame }

constructor TClaudeTerminalFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BuildUI;
  AddView;
  ActiveTerminalFrame := Self;
end;

destructor TClaudeTerminalFrame.Destroy;
var
  I: Integer;
begin
  if ActiveTerminalFrame = Self then
    ActiveTerminalFrame := nil;
  // Sessions end with the panel (their processes are in kill-on-close jobs).
  for I := 0 to ViewCount - 1 do
    Views[I].StopSession;
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

  AddButton('New Session', 'Start a new Claude Code session in this tab', NewClick);
  AddButton('Continue', 'Continue the most recent conversation (claude --continue)', ContinueClick);
  AddButton('Resume...', 'Pick a previous conversation (claude --resume)', ResumeClick);
  AddButton('Stop', 'Stop the session of this tab', StopClick);
  AddButton('+', 'New tab for the current project', NewTabClick).Width := 28;
  AddButton('x', 'Close this tab (stops its session); middle-click a tab to close it', CloseTabClick).Width := 28;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FToolbar;
  FStatus.AlignWithMargins := True;
  FStatus.Margins.SetBounds(10, 8, 6, 2);
  FStatus.Align := alClient;
  FStatus.EllipsisPosition := epPathEllipsis;
  FStatus.ShowHint := True;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.OnChange := PagesChange;
  FPages.OnMouseUp := PagesMouseUp;
end;

function TClaudeTerminalFrame.GetViewCount: Integer;
begin
  Result := FPages.PageCount;
end;

function TClaudeTerminalFrame.GetView(Index: Integer): TClaudeSessionView;
begin
  Result := TClaudeSessionView(FPages.Pages[Index].Tag);
end;

function TClaudeTerminalFrame.GetActiveView: TClaudeSessionView;
begin
  if FPages.ActivePage = nil then
    Result := nil
  else
    Result := TClaudeSessionView(FPages.ActivePage.Tag);
end;

function TClaudeTerminalFrame.AddView(const WorkDir: string): TClaudeSessionView;
var
  Sheet: TTabSheet;
begin
  Sheet := TTabSheet.Create(Self);
  Sheet.PageControl := FPages;
  Result := TClaudeSessionView.CreateView(Self, WorkDir);
  Result.Parent := Sheet;
  Result.Align := alClient;
  Result.BuildUI;
  Sheet.Tag := NativeInt(Result);
  Sheet.Caption := Result.TabCaption;
  FPages.ActivePage := Sheet;
  UpdateStatus;
end;

procedure TClaudeTerminalFrame.SetSessionUsage(const Dir, Text: string);
var
  I: Integer;
  V: TClaudeSessionView;
begin
  for I := 0 to ViewCount - 1 do
  begin
    V := Views[I];
    if V.SessionRunning and SameFileName(ExcludeTrailingPathDelimiter(V.WorkDir), ExcludeTrailingPathDelimiter(Dir)) and
       (V.FUsage <> Text) then
    begin
      V.FUsage := Text;
      ViewChanged(V);
    end;
  end;
end;

function TClaudeTerminalFrame.UnusedView(const WorkDir: string): TClaudeSessionView;
var
  V: TClaudeSessionView;
begin
  V := ActiveView;
  if (V <> nil) and not V.SessionRunning and (V.Command = '') then
  begin
    V.FWorkDir := WorkDir;
    V.FIdleHintShown := True;
    ViewChanged(V);
    Exit(V);
  end;
  Result := AddView(WorkDir);
end;

function TClaudeTerminalFrame.ViewFor(const WorkDir: string): TClaudeSessionView;
var
  I: Integer;
  V: TClaudeSessionView;
begin
  for I := 0 to ViewCount - 1 do
  begin
    V := Views[I];
    if (WorkDir <> '') and SameFileName(ExcludeTrailingPathDelimiter(V.WorkDir),
       ExcludeTrailingPathDelimiter(WorkDir)) then
    begin
      ActivateView(V);
      Exit(V);
    end;
  end;
  // An unused tab (nothing started in it yet) is taken over.
  V := ActiveView;
  if (V <> nil) and not V.SessionRunning and (V.Command = '') then
  begin
    V.FWorkDir := WorkDir;
    V.FIdleHintShown := True;
    ViewChanged(V);
    Exit(V);
  end;
  Result := AddView(WorkDir);
end;

procedure TClaudeTerminalFrame.ActivateView(View: TClaudeSessionView);
begin
  if (View <> nil) and (View.Parent is TTabSheet) then
  begin
    FPages.ActivePage := TTabSheet(View.Parent);
    UpdateStatus;
  end;
end;

procedure TClaudeTerminalFrame.PagesChange(Sender: TObject);
begin
  UpdateStatus;
  if ActiveView <> nil then
  begin
    if ActiveView.Attention and not ActiveView.SessionRunning then
      ActiveView.SetAttention(False);
    ActiveView.FocusTerminal;
  end;
  MarkCaption(False);
end;

procedure TClaudeTerminalFrame.PagesMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Index: Integer;
begin
  if Button <> mbMiddle then
    Exit;
  Index := FPages.IndexOfTabAt(X, Y);
  if Index >= 0 then
    CloseView(Views[Index]);
end;

procedure TClaudeTerminalFrame.UpdateStatus;
begin
  if ActiveView = nil then
    Exit;
  FStatus.Caption := ActiveView.StateText;
  FStatus.Hint := ActiveView.Command;
end;

procedure TClaudeTerminalFrame.ViewChanged(View: TClaudeSessionView);
begin
  if View.Parent is TTabSheet then
    TTabSheet(View.Parent).Caption := View.TabCaption;
  if View = ActiveView then
    UpdateStatus;
end;

{ Tells the user a session needs them when they are not looking at it: the IDE flashes on the
  taskbar, and the panel caption gets a marker when the panel is hidden. The tab itself shows
  "!" (waiting) or the busy dot. }
procedure TClaudeTerminalFrame.ViewNeedsUser(View: TClaudeSessionView);
var
  Info: TFlashWInfo;
begin
  if Application.Active and Showing and (View = ActiveView) then
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
  if not Showing then
    MarkCaption(True);
end;

procedure TClaudeTerminalFrame.MarkCaption(Marked: Boolean);
var
  Form: TCustomForm;
  S: string;
begin
  if Marked = FCaptionMarked then
    Exit;
  Form := GetParentForm(Self);
  if Form = nil then
    Exit;
  FCaptionMarked := Marked;
  S := Form.Caption;
  if Marked then
    Form.Caption := S + ' *'
  else if S.EndsWith(' *') then
    Form.Caption := Copy(S, 1, Length(S) - 2);
end;

procedure TClaudeTerminalFrame.CloseView(View: TClaudeSessionView);
var
  Sheet: TTabSheet;
begin
  if View = nil then
    Exit;
  if View.SessionRunning and View.Busy and
     (Application.MessageBox('Claude is still working in this tab. Stop it and close the tab?',
       'Claude Code', MB_YESNO or MB_ICONQUESTION) <> IDYES) then
    Exit;
  View.StopSession;
  Sheet := View.Parent as TTabSheet;
  // Free after this event (the click came from a control of the frame); a message to our own
  // window is simply dropped if the frame is gone by then.
  PostMessage(Handle, WM_CC_CLOSETAB, 0, LPARAM(Sheet));
end;

procedure TClaudeTerminalFrame.WMCloseTab(var Msg: TMessage);
var
  I: Integer;
begin
  for I := 0 to FPages.PageCount - 1 do
    if LPARAM(FPages.Pages[I]) = Msg.LParam then
    begin
      FPages.Pages[I].Free;
      Break;
    end;
  if ViewCount = 0 then
    AddView;
  UpdateStatus;
  FocusTerminal;
end;

procedure TClaudeTerminalFrame.StartSession(const Args: string; Fresh: Boolean);
begin
  if ActiveView = nil then
    AddView;
  ActiveView.StartSession(Args, Fresh);
end;

procedure TClaudeTerminalFrame.StopSession;
begin
  if ActiveView <> nil then
    ActiveView.StopSession;
end;

procedure TClaudeTerminalFrame.FocusTerminal;
begin
  MarkCaption(False);
  if ActiveView <> nil then
    ActiveView.FocusTerminal;
end;

function TClaudeTerminalFrame.SessionRunning: Boolean;
begin
  Result := (ActiveView <> nil) and ActiveView.SessionRunning;
end;

function TClaudeTerminalFrame.AnySessionRunning: Boolean;
var
  I: Integer;
begin
  for I := 0 to ViewCount - 1 do
    if Views[I].SessionRunning then
      Exit(True);
  Result := False;
end;

procedure TClaudeTerminalFrame.InjectInput(const S: string);
begin
  if ActiveView <> nil then
    ActiveView.InjectInput(S);
end;

procedure TClaudeTerminalFrame.PasteInput(const S: string; Submit: Boolean);
begin
  if ActiveView <> nil then
    ActiveView.PasteInput(S, Submit);
end;

procedure TClaudeTerminalFrame.RequestDump(const OnDump: TProc<string>);
begin
  if ActiveView <> nil then
    ActiveView.RequestDump(OnDump);
end;

function TClaudeTerminalFrame.SessionDir: string;
begin
  if ActiveView <> nil then
    Result := ActiveView.WorkDir
  else
    Result := '';
end;

procedure TClaudeTerminalFrame.NewClick(Sender: TObject);
begin
  StartSession('', True);
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

procedure TClaudeTerminalFrame.NewTabClick(Sender: TObject);
var
  Dir: string;
begin
  Dir := '';
  if Assigned(HostInfo) then
    Dir := HostInfo().WorkDir;
  AddView(Dir).StartSession;
end;

procedure TClaudeTerminalFrame.CloseTabClick(Sender: TObject);
begin
  CloseView(ActiveView);
end;

end.
