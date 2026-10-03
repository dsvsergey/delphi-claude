unit ClaudeCode.AppAutomation;

{ Looking at and driving a running Windows program (typically the one being debugged):
  - pictures of its windows (PrintWindow, also when they are covered by other windows);
  - its UI as a tree from UI Automation (VCL and FMX controls, names, values, positions);
  - actions on elements: invoke/toggle/select through UI Automation patterns, setting values,
    and as a fallback mouse and keyboard messages posted to the window - nothing takes the
    focus away from the user's foreground window.
  Element ids are paths of child indexes from the window ("0.2.1"). Call from a background
  thread: UI Automation calls wait for the target, which must not be stopped in the debugger.
  No ToolsAPI here, so it can be exercised outside the IDE. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types;

type
  TAppWindow = record
    Handle: HWND;
    Title: string;
    ClassName: string;
    Bounds: TRect;
  end;

  { A window picture as 32-bit BGRA pixels, top-down. }
  TWindowPixels = record
    Width, Height: Integer;
    Pixels: TBytes;
  end;

  TAppActionKind = (aaClick, aaDoubleClick, aaRightClick, aaSetText, aaSendKeys, aaFocus);

  TAppAction = record
    Kind: TAppActionKind;
    Element: string;   // element path; '' with X/Y
    X, Y: Integer;     // relative to the window's top-left, like the captured picture
    HasPoint: Boolean;
    Text: string;
    ExpectName: string; // the element's name when the tree was read, to detect a changed UI
  end;

{ Visible top-level windows of the process, largest first; Title filters by substring. }
function ProcessWindows(ProcessId: Cardinal; const Title: string = ''): TArray<TAppWindow>;
{ The window as drawn by the program (plain GDI: callable from any thread). }
function CaptureWindowPixels(Wnd: HWND): TWindowPixels;
{ PNG file from captured pixels (VCL graphics: main thread). }
procedure SavePixelsToPng(const P: TWindowPixels; const FileName: string);
{ The UI Automation tree of a window as text, one element per line:
  [0.2] Button "Add" id=ButtonAdd (312,15 90x25) }
function UiTreeText(Wnd: HWND; MaxDepth, MaxNodes: Integer): string;
{ Performs the action; returns what was done. Raises on failure. }
function PerformAppAction(Wnd: HWND; const A: TAppAction): string;
function ParseActionKind(const S: string; out Kind: TAppActionKind): Boolean;

implementation

uses
  Winapi.Messages, Winapi.ActiveX, Winapi.UIAutomation, Vcl.Graphics, Vcl.Imaging.pngimage,
  System.Generics.Collections, System.Math, System.Variants;

const
  UIA_TIMEOUT_MS = 3000;
  PW_RENDERFULLCONTENT = 2;

function PrintWindow(Wnd: HWND; DC: HDC; Flags: UINT): BOOL; stdcall; external user32 name 'PrintWindow';

{ Windows }

type
  TEnumData = record
    Pid: Cardinal;
    List: TList<TAppWindow>;
  end;
  PEnumData = ^TEnumData;

function EnumProc(Wnd: HWND; Param: LPARAM): BOOL; stdcall;
var
  D: PEnumData;
  Pid: Cardinal;
  W: TAppWindow;
  Buf: array[0..255] of Char;
begin
  Result := True;
  D := PEnumData(Param);
  GetWindowThreadProcessId(Wnd, Pid);
  if (Pid <> D.Pid) or not IsWindowVisible(Wnd) then
    Exit;
  W.Handle := Wnd;
  GetWindowText(Wnd, Buf, Length(Buf));
  W.Title := Buf;
  GetClassName(Wnd, Buf, Length(Buf));
  W.ClassName := Buf;
  GetWindowRect(Wnd, W.Bounds);
  // Skip zero-size helper windows (TApplication's hidden window and the like).
  if (W.Bounds.Width < 40) or (W.Bounds.Height < 20) then
    Exit;
  D.List.Add(W);
end;

function ProcessWindows(ProcessId: Cardinal; const Title: string): TArray<TAppWindow>;
var
  D: TEnumData;
  I, J: Integer;
  Swap: TAppWindow;
  L: TList<TAppWindow>;
begin
  D.Pid := ProcessId;
  D.List := TList<TAppWindow>.Create;
  try
    EnumWindows(@EnumProc, LPARAM(@D));
    L := D.List;
    for I := L.Count - 1 downto 0 do
      if (Title <> '') and not L[I].Title.ToLower.Contains(Title.ToLower) then
        L.Delete(I);
    // Largest first: usually the main form.
    for I := 1 to L.Count - 1 do
    begin
      J := I;
      while (J > 0) and (L[J - 1].Bounds.Width * L[J - 1].Bounds.Height < L[J].Bounds.Width * L[J].Bounds.Height) do
      begin
        Swap := L[J - 1];
        L[J - 1] := L[J];
        L[J] := Swap;
        Dec(J);
      end;
    end;
    Result := L.ToArray;
  finally
    D.List.Free;
  end;
end;

function CaptureWindowPixels(Wnd: HWND): TWindowPixels;
var
  R: TRect;
  ScreenDC, DC: HDC;
  Info: TBitmapInfo;
  Bits: Pointer;
  Dib, Old: HBITMAP;
begin
  if not GetWindowRect(Wnd, R) or (R.Width <= 0) or (R.Height <= 0) then
    raise Exception.Create('The window has no size');
  if IsIconic(Wnd) then
    raise Exception.Create('The window is minimized');
  Result.Width := R.Width;
  Result.Height := R.Height;
  FillChar(Info, SizeOf(Info), 0);
  Info.bmiHeader.biSize := SizeOf(Info.bmiHeader);
  Info.bmiHeader.biWidth := R.Width;
  Info.bmiHeader.biHeight := -R.Height; // top-down
  Info.bmiHeader.biPlanes := 1;
  Info.bmiHeader.biBitCount := 32;
  Info.bmiHeader.biCompression := BI_RGB;
  ScreenDC := GetDC(0);
  DC := CreateCompatibleDC(ScreenDC);
  try
    Dib := CreateDIBSection(ScreenDC, Info, DIB_RGB_COLORS, Bits, 0, 0);
    if Dib = 0 then
      RaiseLastOSError;
    Old := SelectObject(DC, Dib);
    try
      if not PrintWindow(Wnd, DC, PW_RENDERFULLCONTENT) then
        raise Exception.Create('PrintWindow failed: ' + SysErrorMessage(GetLastError));
      GdiFlush;
      SetLength(Result.Pixels, R.Width * R.Height * 4);
      Move(Bits^, Result.Pixels[0], Length(Result.Pixels));
    finally
      SelectObject(DC, Old);
      DeleteObject(Dib);
    end;
  finally
    DeleteDC(DC);
    ReleaseDC(0, ScreenDC);
  end;
end;

procedure SavePixelsToPng(const P: TWindowPixels; const FileName: string);
var
  Bmp: TBitmap;
  Png: TPngImage;
  Y: Integer;
begin
  Bmp := TBitmap.Create;
  Png := TPngImage.Create;
  try
    Bmp.PixelFormat := pf32bit;
    Bmp.SetSize(P.Width, P.Height);
    for Y := 0 to P.Height - 1 do
      Move(P.Pixels[Y * P.Width * 4], Bmp.ScanLine[Y]^, P.Width * 4);
    Bmp.PixelFormat := pf24bit; // no alpha channel in the picture
    Png.Assign(Bmp);
    Png.SaveToFile(FileName);
  finally
    Png.Free;
    Bmp.Free;
  end;
end;

{ UI Automation }

function Check(Hr: HRESULT; const What: string): HRESULT;
begin
  Result := Hr;
  if Failed(Hr) then
    raise Exception.CreateFmt('%s failed (0x%.8x)', [What, Cardinal(Hr)]);
end;

{ BSTR results are declared as PChar in Winapi.UIAutomation: copy and free them. }
function TakeBStr(P: PChar): string;
begin
  Result := P;
  if P <> nil then
    SysFreeString(P);
end;

function NewAutomation: IUIAutomation;
var
  A2: IUIAutomation2;
begin
  if Failed(CoCreateInstance(CLSID_CUIAutomation8, nil, CLSCTX_INPROC_SERVER, IUIAutomation, Result)) then
    Check(CoCreateInstance(CLSID_CUIAutomation, nil, CLSCTX_INPROC_SERVER, IUIAutomation, Result),
      'Creating UI Automation');
  // A program that hangs (or sits at a breakpoint) must not hang us for long.
  if Supports(Result, IUIAutomation2, A2) then
  begin
    A2.put_ConnectionTimeout(UIA_TIMEOUT_MS);
    A2.put_TransactionTimeout(UIA_TIMEOUT_MS);
  end;
end;

function ControlTypeName(Id: Integer): string;
const
  Names: array[0..40] of string = ('Button', 'Calendar', 'CheckBox', 'ComboBox', 'Edit', 'Hyperlink', 'Image',
    'ListItem', 'List', 'Menu', 'MenuBar', 'MenuItem', 'ProgressBar', 'RadioButton', 'ScrollBar', 'Slider',
    'Spinner', 'StatusBar', 'Tab', 'TabItem', 'Text', 'ToolBar', 'ToolTip', 'Tree', 'TreeItem', 'Custom',
    'Group', 'Thumb', 'DataGrid', 'DataItem', 'Document', 'SplitButton', 'Window', 'Pane', 'Header',
    'HeaderItem', 'Table', 'TitleBar', 'Separator', 'SemanticZoom', 'AppBar');
begin
  if (Id >= 50000) and (Id <= 50040) then
    Result := Names[Id - 50000]
  else
    Result := 'Control' + IntToStr(Id);
end;

type
  TElementInfo = record
    Name, AutomationId, ClassName, ControlType, Value: string;
    Bounds: TRect;
    Enabled, Offscreen: Boolean;
    Toggle: Integer; // -1 none, 0 off, 1 on, 2 indeterminate
  end;

function ReadElement(const E: IUIAutomationElement): TElementInfo;
var
  P: PChar;
  B: BOOL;
  CT: UIA_CONTROLTYPE_ID;
  V: OleVariant;
  Lo: Integer;
  Unk: IUnknown;
  VP: IUIAutomationValuePattern;
  TP: IUIAutomationTogglePattern;
  TS: ToggleState;
begin
  Result := Default(TElementInfo);
  Result.Toggle := -1;
  if Succeeded(E.get_CurrentName(P)) then
    Result.Name := TakeBStr(P);
  if Succeeded(E.get_CurrentAutomationId(P)) then
    Result.AutomationId := TakeBStr(P);
  if Succeeded(E.get_CurrentClassName(P)) then
    Result.ClassName := TakeBStr(P);
  if Succeeded(E.get_CurrentControlType(CT)) then
    Result.ControlType := ControlTypeName(CT);
  if Succeeded(E.get_CurrentIsEnabled(B)) then
    Result.Enabled := B;
  if Succeeded(E.get_CurrentIsOffscreen(B)) then
    Result.Offscreen := B;
  // Not get_CurrentBoundingRectangle: Winapi.UIAutomation declares it with TRectF (singles) while
  // UI Automation returns four doubles. The property value is a VARIANT array of doubles.
  if Succeeded(E.GetCurrentPropertyValue(UIA_BoundingRectanglePropertyId, V)) and VarIsArray(V) and
     (VarArrayHighBound(V, 1) - VarArrayLowBound(V, 1) = 3) then
  begin
    Lo := VarArrayLowBound(V, 1);
    Result.Bounds := Rect(Round(Double(V[Lo])), Round(Double(V[Lo + 1])), Round(Double(V[Lo]) + Double(V[Lo + 2])),
      Round(Double(V[Lo + 1]) + Double(V[Lo + 3])));
  end;
  if Succeeded(E.GetCurrentPattern(UIA_ValuePatternId, Unk)) and Supports(Unk, IUIAutomationValuePattern, VP) then
    if Succeeded(VP.get_CurrentValue(P)) then
      Result.Value := TakeBStr(P);
  if Succeeded(E.GetCurrentPattern(UIA_TogglePatternId, Unk)) and Supports(Unk, IUIAutomationTogglePattern, TP) then
    if Succeeded(TP.get_CurrentToggleState(TS)) then
      Result.Toggle := Ord(TS);
end;

function Quote(const S: string): string;
var
  T: string;
begin
  T := StringReplace(S, #13#10, '\n', [rfReplaceAll]);
  T := StringReplace(T, #10, '\n', [rfReplaceAll]);
  if Length(T) > 80 then
    T := Copy(T, 1, 80) + '...';
  Result := '"' + StringReplace(T, '"', '\"', [rfReplaceAll]) + '"';
end;

function UiTreeText(Wnd: HWND; MaxDepth, MaxNodes: Integer): string;
var
  UIA: IUIAutomation;
  Walker: IUIAutomationTreeWalker;
  Root: IUIAutomationElement;
  SB: TStringBuilder;
  Count: Integer;
  Origin: TPoint;
  WR: TRect;

  procedure Visit(const E: IUIAutomationElement; const Path: string; Depth: Integer);
  var
    Info: TElementInfo;
    Child, Next: IUIAutomationElement;
    Index: Integer;
    Line: string;
  begin
    if Count >= MaxNodes then
      Exit;
    Inc(Count);
    Info := ReadElement(E);
    Line := StringOfChar(' ', 2 * Depth) + '[' + Path + '] ' + Info.ControlType;
    if Info.Name <> '' then
      Line := Line + ' ' + Quote(Info.Name);
    if (Info.AutomationId <> '') and (Info.AutomationId <> Info.Name) then
      Line := Line + ' id=' + Info.AutomationId;
    if (Info.Value <> '') and (Info.Value <> Info.Name) then
      Line := Line + ' value=' + Quote(Info.Value);
    case Info.Toggle of
      0: Line := Line + ' unchecked';
      1: Line := Line + ' checked';
      2: Line := Line + ' indeterminate';
    end;
    if not Info.Enabled then
      Line := Line + ' disabled';
    if Info.Offscreen then
      Line := Line + ' offscreen';
    if Info.ClassName <> '' then
      Line := Line + ' class=' + Info.ClassName;
    if not Info.Bounds.IsEmpty then
      Line := Line + Format(' (%d,%d %dx%d)', [Info.Bounds.Left - Origin.X, Info.Bounds.Top - Origin.Y,
        Info.Bounds.Width, Info.Bounds.Height]);
    SB.Append(Line).AppendLine;
    if Depth >= MaxDepth then
      Exit;
    Index := 0;
    if Failed(Walker.GetFirstChildElement(E, Child)) then
      Exit;
    while Child <> nil do
    begin
      Visit(Child, Path + '.' + IntToStr(Index), Depth + 1);
      Inc(Index);
      if Failed(Walker.GetNextSiblingElement(Child, Next)) then
        Break;
      Child := Next;
    end;
  end;

begin
  UIA := NewAutomation;
  Check(UIA.get_ControlViewWalker(Walker), 'ControlViewWalker');
  Check(UIA.ElementFromHandle(Wnd, Root), 'ElementFromHandle');
  GetWindowRect(Wnd, WR);
  Origin := WR.TopLeft;
  SB := TStringBuilder.Create;
  try
    Count := 0;
    Visit(Root, '0', 0);
    if Count >= MaxNodes then
      SB.AppendFormat('... stopped after %d elements (raise maxNodes or depth)', [MaxNodes]).AppendLine;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function ElementByPath(const UIA: IUIAutomation; Wnd: HWND; const Path: string): IUIAutomationElement;
var
  Walker: IUIAutomationTreeWalker;
  Parts: TArray<string>;
  I, K, Index: Integer;
  Child, Next: IUIAutomationElement;
begin
  Check(UIA.get_ControlViewWalker(Walker), 'ControlViewWalker');
  Check(UIA.ElementFromHandle(Wnd, Result), 'ElementFromHandle');
  Parts := Path.Split(['.']);
  if (Length(Parts) = 0) or (Parts[0] <> '0') then
    raise Exception.Create('Element ids start with 0 (the window), e.g. 0.2.1');
  for I := 1 to High(Parts) do
  begin
    Index := StrToIntDef(Parts[I], -1);
    if Index < 0 then
      raise Exception.Create('Bad element id: ' + Path);
    if Failed(Walker.GetFirstChildElement(Result, Child)) or (Child = nil) then
      raise Exception.Create('No element ' + Path + ': the UI changed; read it again with getAppUI');
    for K := 1 to Index do
    begin
      if Failed(Walker.GetNextSiblingElement(Child, Next)) or (Next = nil) then
        raise Exception.Create('No element ' + Path + ': the UI changed; read it again with getAppUI');
      Child := Next;
    end;
    Result := Child;
  end;
end;

{ Input posted as window messages: works on a window in the background. }

function DeepestChildAt(Top: HWND; ScreenPt: TPoint; out ClientPt: TPoint): HWND;
var
  Child: HWND;
  P: TPoint;
begin
  Result := Top;
  repeat
    P := ScreenPt;
    ScreenToClient(Result, P);
    Child := RealChildWindowFromPoint(Result, P);
    if (Child = 0) or (Child = Result) then
      Break;
    Result := Child;
  until False;
  ClientPt := ScreenPt;
  ScreenToClient(Result, ClientPt);
end;

procedure PostClick(Top: HWND; ScreenPt: TPoint; Kind: TAppActionKind);
var
  Target: HWND;
  CP: TPoint;
  L: LPARAM;
begin
  Target := DeepestChildAt(Top, ScreenPt, CP);
  L := MakeLParam(Word(CP.X), Word(CP.Y));
  PostMessage(Target, WM_MOUSEMOVE, 0, L);
  case Kind of
    aaRightClick:
      begin
        PostMessage(Target, WM_RBUTTONDOWN, MK_RBUTTON, L);
        PostMessage(Target, WM_RBUTTONUP, 0, L);
      end;
    aaDoubleClick:
      begin
        PostMessage(Target, WM_LBUTTONDOWN, MK_LBUTTON, L);
        PostMessage(Target, WM_LBUTTONUP, 0, L);
        PostMessage(Target, WM_LBUTTONDBLCLK, MK_LBUTTON, L);
        PostMessage(Target, WM_LBUTTONUP, 0, L);
      end;
  else
    PostMessage(Target, WM_LBUTTONDOWN, MK_LBUTTON, L);
    PostMessage(Target, WM_LBUTTONUP, 0, L);
  end;
end;

function FocusedWindow(Top: HWND): HWND;
var
  Info: TGUIThreadInfo;
  Tid: Cardinal;
begin
  Tid := GetWindowThreadProcessId(Top, nil);
  Info.cbSize := SizeOf(Info);
  if GetGUIThreadInfo(Tid, Info) and (Info.hwndFocus <> 0) then
    Result := Info.hwndFocus
  else
    Result := Top;
end;

(* Keys: plain text, plus {ENTER} {TAB} {ESC} {BACKSPACE} {DELETE} {UP} {DOWN} {LEFT} {RIGHT}
   {HOME} {END} {PGUP} {PGDN} {F1}..{F12}. *)
procedure PostKeys(Top: HWND; const Keys: string);
var
  Target: HWND;
  I, J: Integer;
  Name: string;
  VK: Word;

  procedure Key(Code: Word);
  begin
    // The program's message loop translates the key down into WM_CHAR (Enter, Tab, Esc,
    // Backspace) itself; posting the character too would type it twice.
    PostMessage(Target, WM_KEYDOWN, Code, 1);
    PostMessage(Target, WM_KEYUP, Code, LPARAM($C0000001));
    // That WM_CHAR is queued behind what we post next: let the program take the key first.
    if (Code in [VK_RETURN, VK_TAB, VK_ESCAPE, VK_BACK]) and (J < Length(Keys)) then
      Sleep(100);
  end;

begin
  Target := FocusedWindow(Top);
  I := 1;
  while I <= Length(Keys) do
  begin
    if Keys[I] = '{' then
    begin
      J := Pos('}', Keys, I);
      if J > I then
      begin
        Name := UpperCase(Copy(Keys, I + 1, J - I - 1));
        VK := 0;
        if Name = 'ENTER' then VK := VK_RETURN
        else if Name = 'TAB' then VK := VK_TAB
        else if (Name = 'ESC') or (Name = 'ESCAPE') then VK := VK_ESCAPE
        else if (Name = 'BACKSPACE') or (Name = 'BS') then VK := VK_BACK
        else if (Name = 'DELETE') or (Name = 'DEL') then VK := VK_DELETE
        else if Name = 'UP' then VK := VK_UP
        else if Name = 'DOWN' then VK := VK_DOWN
        else if Name = 'LEFT' then VK := VK_LEFT
        else if Name = 'RIGHT' then VK := VK_RIGHT
        else if Name = 'HOME' then VK := VK_HOME
        else if Name = 'END' then VK := VK_END
        else if Name = 'PGUP' then VK := VK_PRIOR
        else if Name = 'PGDN' then VK := VK_NEXT
        else if (Length(Name) >= 2) and (Name[1] = 'F') and (StrToIntDef(Copy(Name, 2, 2), 0) in [1..12]) then
          VK := VK_F1 + StrToInt(Copy(Name, 2, 2)) - 1;
        if VK <> 0 then
        begin
          Key(VK);
          I := J + 1;
          Continue;
        end;
      end;
    end;
    PostMessage(Target, WM_CHAR, Ord(Keys[I]), 1);
    Inc(I);
  end;
end;

function ParseActionKind(const S: string; out Kind: TAppActionKind): Boolean;
var
  L: string;
begin
  L := LowerCase(S);
  Result := True;
  if L = 'click' then Kind := aaClick
  else if L = 'doubleclick' then Kind := aaDoubleClick
  else if L = 'rightclick' then Kind := aaRightClick
  else if L = 'settext' then Kind := aaSetText
  else if L = 'sendkeys' then Kind := aaSendKeys
  else if L = 'focus' then Kind := aaFocus
  else Result := False;
end;

function PerformAppAction(Wnd: HWND; const A: TAppAction): string;
var
  UIA: IUIAutomation;
  E: IUIAutomationElement;
  Info: TElementInfo;
  Unk: IUnknown;
  IP: IUIAutomationInvokePattern;
  TP: IUIAutomationTogglePattern;
  SP: IUIAutomationSelectionItemPattern;
  VP: IUIAutomationValuePattern;
  WR: TRect;
  Pt: TPoint;
  What: string;
begin
  GetWindowRect(Wnd, WR);
  E := nil;
  if A.Element <> '' then
  begin
    UIA := NewAutomation;
    E := ElementByPath(UIA, Wnd, A.Element);
    Info := ReadElement(E);
    if (A.ExpectName <> '') and (Info.Name <> A.ExpectName) then
      raise Exception.CreateFmt('Element %s is now %s "%s", not "%s": the UI changed; read it again with getAppUI',
        [A.Element, Info.ControlType, Info.Name, A.ExpectName]);
    What := Format('%s "%s"', [Info.ControlType, Info.Name]);
    Pt := Info.Bounds.CenterPoint;
  end
  else if A.HasPoint then
  begin
    Pt := Point(WR.Left + A.X, WR.Top + A.Y);
    What := Format('point (%d,%d)', [A.X, A.Y]);
  end
  else if not (A.Kind in [aaSendKeys]) then
    raise Exception.Create('Pass "element" (an id from getAppUI) or "x" and "y" (relative to the window)');

  case A.Kind of
    aaClick:
      begin
        if E <> nil then
        begin
          if Succeeded(E.GetCurrentPattern(UIA_InvokePatternId, Unk)) and Supports(Unk, IUIAutomationInvokePattern, IP) then
          begin
            Check(IP.Invoke, 'Invoke');
            Exit('Invoked ' + What);
          end;
          if Succeeded(E.GetCurrentPattern(UIA_TogglePatternId, Unk)) and Supports(Unk, IUIAutomationTogglePattern, TP) then
          begin
            Check(TP.Toggle, 'Toggle');
            Exit('Toggled ' + What);
          end;
          if Succeeded(E.GetCurrentPattern(UIA_SelectionItemPatternId, Unk)) and
             Supports(Unk, IUIAutomationSelectionItemPattern, SP) then
          begin
            Check(SP.Select, 'Select');
            Exit('Selected ' + What);
          end;
        end;
        PostClick(Wnd, Pt, aaClick);
        Result := 'Clicked ' + What;
      end;
    aaDoubleClick, aaRightClick:
      begin
        PostClick(Wnd, Pt, A.Kind);
        if A.Kind = aaDoubleClick then
          Result := 'Double-clicked ' + What
        else
          Result := 'Right-clicked ' + What;
      end;
    aaSetText:
      begin
        if (E <> nil) and Succeeded(E.GetCurrentPattern(UIA_ValuePatternId, Unk)) and
           Supports(Unk, IUIAutomationValuePattern, VP) then
        begin
          Check(VP.SetValue(PChar(A.Text)), 'SetValue');
          Exit('Set the text of ' + What);
        end;
        if E <> nil then
          E.SetFocus
        else
          PostClick(Wnd, Pt, aaClick);
        Sleep(50);
        PostKeys(Wnd, A.Text);
        Result := 'Typed into ' + What;
      end;
    aaSendKeys:
      begin
        if E <> nil then
        begin
          E.SetFocus;
          Sleep(50);
        end
        else if A.HasPoint then
        begin
          PostClick(Wnd, Pt, aaClick);
          Sleep(50);
        end;
        PostKeys(Wnd, A.Text);
        Result := 'Sent keys';
        if What <> '' then
          Result := Result + ' to ' + What;
      end;
    aaFocus:
      begin
        if E = nil then
          raise Exception.Create('focus needs "element"');
        Check(E.SetFocus, 'SetFocus');
        Result := 'Focused ' + What;
      end;
  end;
end;

end.
