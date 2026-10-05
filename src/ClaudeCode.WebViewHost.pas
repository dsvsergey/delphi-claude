unit ClaudeCode.WebViewHost;

{ Minimal WebView2 host control.
  Unlike TEdgeBrowser it
  - keeps the page alive when the VCL window handle is recreated (IDE docking),
  - lets the owner decide which accelerator keys go to the page and which to the IDE,
  - loads WebView2Loader.dll from a resource embedded in the package. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, Vcl.Controls,
  Winapi.WebView2, ClaudeCode.Compat;

type
  TWebViewMessageEvent = procedure(Sender: TObject; const Msg: string) of object;
  TWebViewErrorEvent = procedure(Sender: TObject; const Error: string) of object;
  { Return True to take the key away from the page (it is then reported via OnHostKey). }
  TWebViewAcceleratorEvent = procedure(Sender: TObject; VirtualKey: Cardinal; Shift: TShiftState;
    var HandledByHost: Boolean) of object;

  TWebViewHost = class(TWinControl)
  private
    FEnvironment: ICoreWebView2Environment;
    FController: ICoreWebView2Controller;
    FWebView: ICoreWebView2;
    FCreating: Boolean;
    FFailed: Boolean;
    FRetried: Boolean;
    FParking: HWND;
    FHandlers: TInterfaceList;
    FUserDataFolder: string;
    FPendingHtml: string;
    FHasPendingHtml: Boolean;
    FOnReady: TNotifyEvent;
    FOnMessage: TWebViewMessageEvent;
    FOnError: TWebViewErrorEvent;
    FOnAccelerator: TWebViewAcceleratorEvent;
    procedure StartCreation;
    procedure EnvironmentCreated(Result: HResult; const Env: ICoreWebView2Environment);
    procedure ControllerCreated(Result: HResult; const Controller: ICoreWebView2Controller);
    procedure Fail(const Msg: string);
    function RetryWithPrivateFolder(Hr: HResult): Boolean;
    procedure UpdateBounds;
    procedure UpdateVisibility;
    function ParkingWindow: HWND;
    procedure WMSize(var Msg: TWMSize); message WM_SIZE;
    procedure WMSetFocus(var Msg: TWMSetFocus); message WM_SETFOCUS;
    procedure WMEraseBkgnd(var Msg: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure CMShowingChanged(var Msg: TMessage); message CM_SHOWINGCHANGED;
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure NavigateToString(const Html: string);
    function PostMessageToPage(const Msg: string): Boolean;
    procedure FocusPage;
    function Ready: Boolean;
    property CreationFailed: Boolean read FFailed;
    property UserDataFolder: string read FUserDataFolder write FUserDataFolder;
    property OnReady: TNotifyEvent read FOnReady write FOnReady;
    property OnMessage: TWebViewMessageEvent read FOnMessage write FOnMessage;
    property OnError: TWebViewErrorEvent read FOnError write FOnError;
    property OnAccelerator: TWebViewAcceleratorEvent read FOnAccelerator write FOnAccelerator;
    property Align;
    property Color;
  end;

{ Directory for WebView2 profile data and the extracted loader. }
function ClaudeCodeDataDir: string;

implementation

uses
  Winapi.ActiveX, System.IOUtils, System.Types, System.JSON, Vcl.Graphics;

const
  COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC_ = 0;
  COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN_ = 0;
  COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN_ = 2;

type
  TCreateEnvFunc = function(browserExecutableFolder, userDataFolder: PWideChar;
    environmentOptions: IUnknown;
    const environmentCreatedHandler: ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler): HResult; stdcall;

  { Callback objects are owned by WebView2 (COM ref counting) and may outlive the
    host; the host detaches them in its destructor. }
  THostHandler = class(TInterfacedObject)
  protected
    FHost: TWebViewHost;
  public
    constructor Create(AHost: TWebViewHost);
  end;

  TEnvCompleted = class(THostHandler, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)
  public
    function Invoke(errorCode: HResult; const createdEnvironment: ICoreWebView2Environment): HResult; stdcall;
  end;

  TControllerCompleted = class(THostHandler, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)
  public
    function Invoke(errorCode: HResult; const createdController: ICoreWebView2Controller): HResult; stdcall;
  end;

  TMessageReceived = class(THostHandler, ICoreWebView2WebMessageReceivedEventHandler)
  public
    function Invoke(const sender: ICoreWebView2; const args: ICoreWebView2WebMessageReceivedEventArgs): HResult; stdcall;
  end;

  TAcceleratorPressed = class(THostHandler, ICoreWebView2AcceleratorKeyPressedEventHandler)
  public
    function Invoke(const sender: ICoreWebView2Controller; const args: ICoreWebView2AcceleratorKeyPressedEventArgs): HResult; stdcall;
  end;

var
  GLoader: HMODULE;
  GCreateEnv: TCreateEnvFunc;
  GLoaderError: string;

function ClaudeCodeDataDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'ClaudeCodeDelphi');
end;

function LoadWebView2Loader: Boolean;
var
  Res: TResourceStream;
  Dir, FileName: string;
  Bytes: TBytes;
begin
  if Assigned(GCreateEnv) then
    Exit(True);
  if GLoaderError <> '' then
    Exit(False);
  try
    {$IFDEF WIN64}
    Dir := TPath.Combine(ClaudeCodeDataDir, 'x64');
    {$ELSE}
    Dir := TPath.Combine(ClaudeCodeDataDir, 'x86');
    {$ENDIF}
    ForceDirectories(Dir);
    FileName := TPath.Combine(Dir, 'WebView2Loader.dll');
    Res := TResourceStream.Create(HInstance, 'CC_WEBVIEW2LOADER', RT_RCDATA);
    try
      SetLength(Bytes, Res.Size);
      Res.ReadBuffer(Bytes[0], Length(Bytes));
    finally
      Res.Free;
    end;
    if not FileExists(FileName) or (TFile.GetSize(FileName) <> Length(Bytes)) then
      TFile.WriteAllBytes(FileName, Bytes);
    GLoader := LoadLibrary(PChar(FileName));
    if GLoader = 0 then
      RaiseLastOSError;
    @GCreateEnv := GetProcAddress(GLoader, 'CreateCoreWebView2EnvironmentWithOptions');
    if not Assigned(GCreateEnv) then
      raise Exception.Create('CreateCoreWebView2EnvironmentWithOptions not found');
    Result := True;
  except
    on E: Exception do
    begin
      GLoaderError := 'Cannot load WebView2Loader.dll: ' + E.Message;
      Result := False;
    end;
  end;
end;

{ Handlers }

constructor THostHandler.Create(AHost: TWebViewHost);
begin
  inherited Create;
  FHost := AHost;
  AHost.FHandlers.Add(Self);
end;

function TEnvCompleted.Invoke(errorCode: HResult; const createdEnvironment: ICoreWebView2Environment): HResult;
begin
  if FHost <> nil then
    FHost.EnvironmentCreated(errorCode, createdEnvironment);
  Result := S_OK;
end;

function TControllerCompleted.Invoke(errorCode: HResult; const createdController: ICoreWebView2Controller): HResult;
begin
  if FHost <> nil then
    FHost.ControllerCreated(errorCode, createdController);
  Result := S_OK;
end;

function TMessageReceived.Invoke(const sender: ICoreWebView2;
  const args: ICoreWebView2WebMessageReceivedEventArgs): HResult;
var
  P: PWideChar;
  S: string;
  Args2: ICoreWebView2WebMessageReceivedEventArgs2;
  Objects: ICoreWebView2ObjectCollectionView;
  Count: SYSUINT;
  I: Integer;
  Obj: IUnknown;
  F: ICoreWebView2File;
  Msg: TJSONObject;
  Paths: TJSONArray;
begin
  Result := S_OK;
  if (FHost = nil) or not Assigned(FHost.FOnMessage) then
    Exit;
  P := nil;
  if Succeeded(args.TryGetWebMessageAsString(P)) and (P <> nil) then
  begin
    S := P;
    CoTaskMemFree(P);
    // Files dropped on the page arrive as additional objects; hand their paths over as
    // {"t":"files","paths":[...]} (the page only sees file names).
    if Supports(args, ICoreWebView2WebMessageReceivedEventArgs2, Args2) and
       Succeeded(Args2.Get_additionalObjects(Objects)) and (Objects <> nil) and
       Succeeded(Objects.Get_Count(Count)) and (Count > 0) then
    begin
      Msg := TJSONObject.Create;
      try
        Paths := TJSONArray.Create;
        Msg.AddPair('t', 'files');
        Msg.AddPair('paths', Paths);
        for I := 0 to Integer(Count) - 1 do
          if Succeeded(Objects.GetValueAtIndex(I, Obj)) and Supports(Obj, ICoreWebView2File, F) then
          begin
            P := nil;
            if Succeeded(F.Get_Path(P)) and (P <> nil) then
            begin
              Paths.Add(string(P));
              CoTaskMemFree(P);
            end;
          end;
        S := Msg.ToJSON;
      finally
        Msg.Free;
      end;
    end;
    FHost.FOnMessage(FHost, S);
  end;
end;

function TAcceleratorPressed.Invoke(const sender: ICoreWebView2Controller;
  const args: ICoreWebView2AcceleratorKeyPressedEventArgs): HResult;
var
  Kind: COREWEBVIEW2_KEY_EVENT_KIND;
  Key: SYSUINT;
  Shift: TShiftState;
  Handled: Boolean;
begin
  Result := S_OK;
  if (FHost = nil) or not Assigned(FHost.FOnAccelerator) then
    Exit;
  args.Get_KeyEventKind(Kind);
  if (Ord(Kind) <> COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN_) and
     (Ord(Kind) <> COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN_) then
    Exit;
  args.Get_VirtualKey(Key);
  Shift := [];
  if GetKeyState(VK_SHIFT) < 0 then Include(Shift, ssShift);
  if GetKeyState(VK_CONTROL) < 0 then Include(Shift, ssCtrl);
  if GetKeyState(VK_MENU) < 0 then Include(Shift, ssAlt);
  Handled := False;
  FHost.FOnAccelerator(FHost, Key, Shift, Handled);
  if Handled then
    args.Set_Handled(1);
end;

{ TWebViewHost }

constructor TWebViewHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  FHandlers := TInterfaceList.Create;
  FUserDataFolder := TPath.Combine(ClaudeCodeDataDir, 'WebView2');
end;

destructor TWebViewHost.Destroy;
var
  I: Integer;
begin
  // Sets csDestroying now, so a window recreated while the IDE tears the dock
  // site down does not start WebView creation again (see StartCreation).
  Destroying;
  for I := 0 to FHandlers.Count - 1 do
    THostHandler(FHandlers[I] as TObject).FHost := nil;
  FreeAndNil(FHandlers);
  FOnReady := nil;
  FOnMessage := nil;
  FOnError := nil;
  FOnAccelerator := nil;
  if FController <> nil then
    FController.Close;
  FWebView := nil;
  FController := nil;
  FEnvironment := nil;
  if FParking <> 0 then
    DestroyWindow(FParking);
  inherited;
end;

function TWebViewHost.ParkingWindow: HWND;
begin
  // Hidden top-level window that holds the WebView while our handle is being recreated.
  if FParking = 0 then
    FParking := CreateWindowEx(WS_EX_TOOLWINDOW, 'STATIC', 'ClaudeCodeWebViewParking', WS_POPUP,
      0, 0, 0, 0, 0, 0, HInstance, nil);
  Result := FParking;
end;

procedure TWebViewHost.CreateWnd;
begin
  inherited;
  if FController <> nil then
  begin
    FController.Set_ParentWindow(wireHWND(Handle));
    UpdateBounds;
    UpdateVisibility;
  end
  else
    StartCreation;
end;

procedure TWebViewHost.DestroyWnd;
begin
  if (FController <> nil) and not (csDestroying in ComponentState) then
    FController.Set_ParentWindow(wireHWND(ParkingWindow));
  inherited;
end;

procedure TWebViewHost.StartCreation;
var
  Hr: HResult;
begin
  if FCreating or FFailed or (FController <> nil) or
     (ComponentState * [csDesigning, csDestroying] <> []) then
    Exit;
  if not LoadWebView2Loader then
  begin
    Fail(GLoaderError);
    Exit;
  end;
  FCreating := True;
  ForceDirectories(FUserDataFolder);
  Hr := GCreateEnv(nil, PWideChar(FUserDataFolder), nil, TEnvCompleted.Create(Self));
  if Failed(Hr) then
  begin
    FCreating := False;
    Fail(Format('WebView2 environment could not be created (0x%.8x). ' +
      'Is the Microsoft Edge WebView2 Runtime installed?', [Hr]));
  end;
end;

procedure TWebViewHost.EnvironmentCreated(Result: HResult; const Env: ICoreWebView2Environment);
var
  Hr: HResult;
begin
  if Failed(Result) or (Env = nil) then
  begin
    FCreating := False;
    if RetryWithPrivateFolder(Result) then
      Exit;
    Fail(Format('WebView2 environment failed (0x%.8x)', [Result]));
    Exit;
  end;
  FEnvironment := Env;
  if HandleAllocated then
    Hr := Env.CreateCoreWebView2Controller(Handle, TControllerCompleted.Create(Self))
  else
    Hr := Env.CreateCoreWebView2Controller(ParkingWindow, TControllerCompleted.Create(Self));
  if Failed(Hr) then
  begin
    FCreating := False;
    Fail(Format('WebView2 controller could not be created (0x%.8x)', [Hr]));
  end;
end;

procedure TWebViewHost.ControllerCreated(Result: HResult; const Controller: ICoreWebView2Controller);
var
  Settings: ICoreWebView2Settings;
  Settings3: ICoreWebView2Settings3;
  Token: EventRegistrationToken;
begin
  FCreating := False;
  if Failed(Result) or (Controller = nil) then
  begin
    if RetryWithPrivateFolder(Result) then
      Exit;
    Fail(Format('WebView2 controller failed (0x%.8x)', [Result]));
    Exit;
  end;
  FController := Controller;
  FController.Get_CoreWebView2(FWebView);

  if Succeeded(FWebView.Get_Settings(Settings)) and (Settings <> nil) then
  begin
    Settings.Set_AreDefaultContextMenusEnabled(0);
    Settings.Set_AreDevToolsEnabled(0);
    Settings.Set_IsStatusBarEnabled(0);
    Settings.Set_IsZoomControlEnabled(0);
    Settings.Set_AreDefaultScriptDialogsEnabled(1);
    Settings.Set_IsWebMessageEnabled(1);
    // Ctrl+R, Ctrl+F, F5, Ctrl+P... belong to Claude, not to the browser.
    if Supports(Settings, ICoreWebView2Settings3, Settings3) then
      Settings3.Set_AreBrowserAcceleratorKeysEnabled(0);
  end;
  FWebView.add_WebMessageReceived(TMessageReceived.Create(Self), Token);
  FController.add_AcceleratorKeyPressed(TAcceleratorPressed.Create(Self), Token);

  if HandleAllocated then
    FController.Set_ParentWindow(wireHWND(Handle));
  UpdateBounds;
  UpdateVisibility;

  if FHasPendingHtml then
  begin
    FHasPendingHtml := False;
    FWebView.NavigateToString(PWideChar(FPendingHtml));
    FPendingHtml := '';
  end;
  if Assigned(FOnReady) then
    FOnReady(Self);
end;

function TWebViewHost.RetryWithPrivateFolder(Hr: HResult): Boolean;
const
  ERROR_INVALID_STATE_HR = HResult($8007139F);
begin
  // The shared profile folder is in use by another process with a different
  // browser setup (e.g. the 32- and 64-bit IDE running side by side).
  Result := (Hr = ERROR_INVALID_STATE_HR) and not FRetried;
  if not Result then
    Exit;
  FRetried := True;
  FEnvironment := nil;
  FUserDataFolder := FUserDataFolder + '-' + IntToStr(GetCurrentProcessId);
  StartCreation;
end;

procedure TWebViewHost.Fail(const Msg: string);
begin
  FFailed := True;
  if Assigned(FOnError) then
    FOnError(Self, Msg);
end;

function TWebViewHost.Ready: Boolean;
begin
  Result := FWebView <> nil;
end;

procedure TWebViewHost.UpdateBounds;
var
  R: TRect;
begin
  if (FController <> nil) and HandleAllocated then
  begin
    R := ClientRect;
    FController.Set_Bounds(tagRECT(R));
  end;
end;

procedure TWebViewHost.UpdateVisibility;
begin
  if FController <> nil then
    FController.Set_IsVisible(Ord(Showing));
end;

procedure TWebViewHost.NavigateToString(const Html: string);
begin
  if FWebView <> nil then
    FWebView.NavigateToString(PWideChar(Html))
  else
  begin
    FPendingHtml := Html;
    FHasPendingHtml := True;
    if HandleAllocated then
      StartCreation;
  end;
end;

function TWebViewHost.PostMessageToPage(const Msg: string): Boolean;
begin
  Result := (FWebView <> nil) and Succeeded(FWebView.PostWebMessageAsString(PWideChar(Msg)));
end;

procedure TWebViewHost.FocusPage;
begin
  if FController <> nil then
    FController.MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC_);
end;

procedure TWebViewHost.WMSize(var Msg: TWMSize);
begin
  inherited;
  UpdateBounds;
end;

procedure TWebViewHost.WMSetFocus(var Msg: TWMSetFocus);
begin
  inherited;
  FocusPage;
end;

procedure TWebViewHost.WMEraseBkgnd(var Msg: TWMEraseBkgnd);
var
  Brush: HBRUSH;
begin
  Brush := CreateSolidBrush(ColorToRGB(Color));
  FillRect(Msg.DC, ClientRect, Brush);
  DeleteObject(Brush);
  Msg.Result := 1;
end;

procedure TWebViewHost.CMShowingChanged(var Msg: TMessage);
begin
  inherited;
  UpdateVisibility;
end;

end.
