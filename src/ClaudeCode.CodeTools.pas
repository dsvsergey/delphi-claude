unit ClaudeCode.CodeTools;

{ Code navigation tools on top of ClaudeCode.PascalIndex: unit outlines, finding declarations
  and references, and renaming an identifier across the project. Sources are read the way the
  IDE sees them (open editor buffers first), parse results are cached by file time. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, ClaudeCode.Mcp, ClaudeCode.PascalIndex, ClaudeCode.ProjectMap;

function ToolGetUnitOutline(Args: TJSONObject): TToolResult;
function ToolFindSymbol(Args: TJSONObject): TToolResult;
function ToolFindReferences(Args: TJSONObject): TToolResult;
function ToolRenameSymbol(Args: TJSONObject): TToolResult;
{ The same, with each occurrence checked by DelphiLSP: findReferences groups them by the declaration they
  refer to, renameSymbol with "declaration" changes the uses of that one. Fall back to names alone. }
procedure ToolFindReferencesAsync(Args: TJSONObject; const Done: TToolDone);
procedure ToolRenameSymbolAsync(Args: TJSONObject; const Done: TToolDone);
{ Stops the DelphiLSP process and a running check. }
procedure ShutdownCodeTools;

{ Source files of the project group and its folders (.pas, .dpr, .dpk, .inc and, with Forms,
  .dfm/.fmx), at most MaxFiles. }
function ProjectSourceFiles(Forms: Boolean; MaxFiles: Integer = 5000): TArray<string>;
{ The parsed unit (cached while the file and its buffer do not change). }
function UnitInfoOf(const FileName: string; out Info: TPasUnitInfo): Boolean;
{ A unit file by path or unit name, '' when not found. }
function ResolveUnitFile(const Spec: string): string;
{ Units and project sources of the project group (or of one project), for the project map. }
function ProjectMapSources(const ProjectName: string): TArray<TMapSource>;

implementation

uses
  Winapi.Windows, System.IOUtils, System.StrUtils, System.Generics.Collections, System.DateUtils, System.Win.Registry,
  ToolsAPI, ClaudeCode.Utils, ClaudeCode.IdeBackend, ClaudeCode.TextSync, ClaudeCode.DelphiLsp, ClaudeCode.Process;

const
  SKIP_DIRS: array[0..17] of string = ('__history', '__recovery', '.git', '.svn', '.hg', 'win32', 'win64',
    'debug', 'release', 'dcu', 'bin', 'node_modules', 'linux64', 'osx64', 'osxarm64', 'android', 'android64',
    'iosdevice64');
  PASCAL_EXTS: array[0..3] of string = ('.pas', '.dpr', '.dpk', '.inc');
  FORM_EXTS: array[0..1] of string = ('.dfm', '.fmx');

type
  TCachedUnit = record
    WriteTime: Int64;
    Size: Int64;
    Info: TPasUnitInfo;
  end;

var
  Cache: TDictionary<string, TCachedUnit>;

function FileStamp(const FileName: string; out WriteTime, Size: Int64): Boolean;
var
  Data: TWin32FileAttributeData;
begin
  Result := GetFileAttributesEx(PChar(FileName), GetFileExInfoStandard, @Data);
  if Result then
  begin
    WriteTime := Int64(Data.ftLastWriteTime.dwHighDateTime) shl 32 or Data.ftLastWriteTime.dwLowDateTime;
    Size := Int64(Data.nFileSizeHigh) shl 32 or Data.nFileSizeLow;
  end;
end;

function HasExt(const FileName: string; const Exts: array of string): Boolean;
var
  E, X: string;
begin
  E := LowerCase(ExtractFileExt(FileName));
  for X in Exts do
    if E = X then
      Exit(True);
  Result := False;
end;

function IsPascalFile(const FileName: string): Boolean;
begin
  Result := HasExt(FileName, PASCAL_EXTS);
end;

function IsFormFile(const FileName: string): Boolean;
begin
  Result := HasExt(FileName, FORM_EXTS);
end;

function UnitInfoOf(const FileName: string; out Info: TPasUnitInfo): Boolean;
var
  Buffer: IOTAEditBuffer;
  Text, K: string;
  C: TCachedUnit;
  WT, Size: Int64;
  Stamped: Boolean;
begin
  K := AnsiLowerCase(FileName);
  Buffer := FindEditBuffer(FileName);
  // A modified buffer differs from the file: parse it every time (only a few are open).
  Stamped := ((Buffer = nil) or not Buffer.IsModified) and FileStamp(FileName, WT, Size);
  if Stamped and Cache.TryGetValue(K, C) and (C.WriteTime = WT) and (C.Size = Size) then
  begin
    Info := C.Info;
    Exit(True);
  end;
  if not ReadSourceText(FileName, Text) then
    Exit(False);
  Info := ParsePascalUnit(Text);
  if Stamped then
  begin
    C.WriteTime := WT;
    C.Size := Size;
    C.Info := Info;
    Cache.AddOrSetValue(K, C);
  end;
  Result := True;
end;

function ProjectSourceFiles(Forms: Boolean; MaxFiles: Integer): TArray<string>;
var
  Seen: TDictionary<string, Boolean>;
  L: TList<string>;
  G: IOTAProjectGroup;
  P: IOTAProject;
  MI: IOTAModuleInfo;
  I, J: Integer;
  F, Ext: string;
  Folders: TArray<string>;

  procedure AddFile(const FileName: string);
  var
    K: string;
  begin
    if (FileName = '') or (L.Count >= MaxFiles) then
      Exit;
    if not (IsPascalFile(FileName) or (Forms and IsFormFile(FileName))) then
      Exit;
    K := AnsiLowerCase(FileName);
    if Seen.ContainsKey(K) then
      Exit;
    if not FileExists(FileName) and (FindEditBuffer(FileName) = nil) then
      Exit;
    Seen.Add(K, True);
    L.Add(FileName);
  end;

  procedure Walk(const Dir: string; Depth: Integer);
  var
    SR: TSearchRec;
    Name, Low: string;
    Skip: Boolean;
    X: string;
  begin
    if (Depth > 8) or (L.Count >= MaxFiles) then
      Exit;
    if FindFirst(TPath.Combine(Dir, '*'), faAnyFile, SR) <> 0 then
      Exit;
    try
      repeat
        Name := SR.Name;
        if (Name = '.') or (Name = '..') then
          Continue;
        if (SR.Attr and faDirectory) <> 0 then
        begin
          Low := LowerCase(Name);
          Skip := False;
          for X in SKIP_DIRS do
            if Low = X then
              Skip := True;
          if not Skip then
            Walk(TPath.Combine(Dir, Name), Depth + 1);
        end
        else
          AddFile(TPath.Combine(Dir, Name));
      until (FindNext(SR) <> 0) or (L.Count >= MaxFiles);
    finally
      System.SysUtils.FindClose(SR);
    end;
  end;

begin
  Seen := TDictionary<string, Boolean>.Create;
  L := TList<string>.Create;
  try
    // Project modules first: they are what matters even when the folder walk hits the limit.
    G := (BorlandIDEServices as IOTAModuleServices).MainProjectGroup;
    if G <> nil then
      for I := 0 to G.ProjectCount - 1 do
      begin
        P := G.Projects[I];
        for Ext in PASCAL_EXTS do
          AddFile(ChangeFileExt(P.FileName, Ext));
        for J := 0 to P.GetModuleCount - 1 do
        begin
          MI := P.GetModule(J);
          if (MI = nil) or (MI.FileName = '') then
            Continue;
          AddFile(MI.FileName);
          if Forms and (MI.FormName <> '') then
            for Ext in FORM_EXTS do
              AddFile(ChangeFileExt(MI.FileName, Ext));
        end;
      end;
    Folders := nil;
    if G <> nil then
      for I := 0 to G.ProjectCount - 1 do
      begin
        F := ExtractFileDir(G.Projects[I].FileName);
        if (F <> '') and not Seen.ContainsKey('dir:' + AnsiLowerCase(F)) then
        begin
          Seen.Add('dir:' + AnsiLowerCase(F), True);
          Folders := Folders + [F];
        end;
      end;
    for F in Folders do
      Walk(F, 0);
    Result := L.ToArray;
  finally
    L.Free;
    Seen.Free;
  end;
end;

function ResolveUnitFile(const Spec: string): string;
var
  S, F, Base: string;
begin
  S := Trim(Spec);
  if S = '' then
  begin
    if EditorServices.TopBuffer <> nil then
      Exit(EditorServices.TopBuffer.FileName);
    Exit('');
  end;
  if S.Contains('\') or S.Contains('/') or S.Contains(':') then
  begin
    Result := PathFromUri(S);
    if not FileExists(Result) and (FindEditBuffer(Result) = nil) then
      Result := '';
    Exit;
  end;
  // A unit name (Unit1, Data.Orders) or a file name (Unit1.pas)
  Base := S;
  if IsPascalFile(Base) then
    Base := ChangeFileExt(Base, '');
  for F in ProjectSourceFiles(False) do
    if SameText(ChangeFileExt(ExtractFileName(F), ''), Base) then
      Exit(F);
  Result := '';
end;

function ProjectMapSources(const ProjectName: string): TArray<TMapSource>;
var
  G: IOTAProjectGroup;
  P: IOTAProject;
  Projects: TArray<IOTAProject>;
  MI: IOTAModuleInfo;
  I: Integer;
  Seen: TDictionary<string, Boolean>;
  S: TMapSource;
  Ext: string;

  procedure Add(const FileName, FormKind: string);
  begin
    if (FileName = '') or Seen.ContainsKey(AnsiLowerCase(FileName)) then
      Exit;
    Seen.Add(AnsiLowerCase(FileName), True);
    S.FileName := FileName;
    S.FormKind := FormKind;
    if ReadSourceText(FileName, S.Text) then
      Result := Result + [S];
  end;

begin
  Result := nil;
  Projects := nil;
  if ProjectName <> '' then
  begin
    P := FindProject(ProjectName);
    if P <> nil then
      Projects := [P];
  end
  else
  begin
    G := (BorlandIDEServices as IOTAModuleServices).MainProjectGroup;
    if G <> nil then
      for I := 0 to G.ProjectCount - 1 do
        Projects := Projects + [G.Projects[I]];
  end;
  Seen := TDictionary<string, Boolean>.Create;
  try
    for P in Projects do
    begin
      for Ext in TArray<string>.Create('.dpr', '.dpk') do
        if FileExists(ChangeFileExt(P.FileName, Ext)) then
          Add(ChangeFileExt(P.FileName, Ext), '');
      for I := 0 to P.GetModuleCount - 1 do
      begin
        MI := P.GetModule(I);
        if (MI = nil) or not SameText(ExtractFileExt(MI.FileName), '.pas') then
          Continue;
        if MI.FormName = '' then
          Add(MI.FileName, '')
        else if SameText(MI.DesignClass, 'TDataModule') then
          Add(MI.FileName, 'dataModule')
        else if SameText(MI.DesignClass, 'TFrame') then
          Add(MI.FileName, 'frame')
        else
          Add(MI.FileName, 'form');
      end;
    end;
  finally
    Seen.Free;
  end;
end;

function FilesArg(Args: TJSONObject; Forms: Boolean): TArray<string>;
var
  V: TJSONValue;
  Item: TJSONValue;
  F: string;
begin
  // "files": a path or an array of paths/unit names; default: the whole project.
  V := nil;
  if Args <> nil then
    V := Args.GetValue('files');
  if V is TJSONArray then
  begin
    Result := nil;
    for Item in TJSONArray(V) do
    begin
      F := ResolveUnitFile(Item.Value);
      if F <> '' then
        Result := Result + [F];
    end;
  end
  else if (V is TJSONString) and (V.Value <> '') then
  begin
    F := ResolveUnitFile(V.Value);
    if F <> '' then
      Result := [F]
    else
      Result := nil;
  end
  else
    Result := ProjectSourceFiles(Forms);
end;

function IntArg(Args: TJSONObject; const Name: string; Default: Integer): Integer;
begin
  Result := Trunc(StrToFloatDef(JsonStr(Args, Name), Default, TFormatSettings.Invariant));
end;

function RelName(const FileName: string): string;
var
  Base: string;
  P: IOTAProject;
begin
  // Relative to the active project folder when inside it: shorter, and what Claude's tools accept.
  Result := FileName;
  P := GetActiveProject;
  if P = nil then
    Exit;
  Base := IncludeTrailingPathDelimiter(ExtractFilePath(P.FileName));
  if SameText(Copy(FileName, 1, Length(Base)), Base) then
    Result := Copy(FileName, Length(Base) + 1, MaxInt);
end;

{ getUnitOutline }

function ToolGetUnitOutline(Args: TJSONObject): TToolResult;
var
  F: string;
  Info: TPasUnitInfo;
begin
  F := ResolveUnitFile(JsonStr(Args, 'unit'));
  if F = '' then
    Exit(TToolResult.Error('Unit not found: ' + JsonStr(Args, 'unit', '(no active editor)') +
      '. Pass a file path or a unit name of the project.'));
  if not UnitInfoOf(F, Info) then
    Exit(TToolResult.Error('Cannot read ' + F));
  Result := TToolResult.Ok([F + #10 + UnitOutlineText(Info, F, JsonBool(Args, 'members', True))]);
end;

{ findSymbol }

function ToolFindSymbol(Args: TJSONObject): TToolResult;
var
  Name, Qualifier, KindFilter, F, Line: string;
  Dot, Max, Count: Integer;
  Info: TPasUnitInfo;
  D: TPasDecl;
  SB: TStringBuilder;
begin
  Name := Trim(JsonStr(Args, 'name'));
  if Name = '' then
    Exit(TToolResult.Error('"name" is required, e.g. TOrder, TOrder.Save or Save'));
  Qualifier := '';
  Dot := Name.LastIndexOf('.');
  if Dot > 0 then
  begin
    Qualifier := Copy(Name, 1, Dot);
    Name := Copy(Name, Dot + 2, MaxInt);
  end;
  KindFilter := LowerCase(JsonStr(Args, 'kind'));
  Max := IntArg(Args, 'maxResults', 50);
  Count := 0;
  SB := TStringBuilder.Create;
  try
    for F in FilesArg(Args, False) do
    begin
      if not UnitInfoOf(F, Info) then
        Continue;
      for D in Info.Decls do
      begin
        if not SameText(D.Name, Name) then
          Continue;
        // "TOrder.Save" matches members and bodies of TOrder; a unit name matches its declarations.
        if (Qualifier <> '') and not SameText(D.Parent, Qualifier) and
           not (SameText(Info.UnitName, Qualifier) and (D.Parent = '')) then
          Continue;
        if (KindFilter <> '') and (LowerCase(D.KindName) <> KindFilter) then
          Continue;
        Inc(Count);
        if Count > Max then
          Continue;
        if D.EndLine > D.Line then
          Line := Format('%d-%d', [D.Line, D.EndLine])
        else
          Line := IntToStr(D.Line);
        SB.AppendFormat('%s %s  %s:%s', [D.KindName, D.QualifiedName, RelName(F), Line]);
        if D.Section <> '' then
          SB.Append(' (').Append(D.Section).Append(')');
        if D.Signature <> '' then
          SB.AppendLine.Append('    ').Append(D.Signature);
        SB.AppendLine;
      end;
    end;
    if Count = 0 then
      Result := TToolResult.Ok(['No declaration of ' + JsonStr(Args, 'name') + ' found in the project sources.'])
    else
    begin
      if Count > Max then
        SB.AppendFormat('... %d more (raise maxResults or narrow with "kind"/"files")', [Count - Max]).AppendLine;
      Result := TToolResult.Ok([SB.ToString]);
    end;
  finally
    SB.Free;
  end;
end;

{ findReferences / renameSymbol }

type
  TFileOccurrences = record
    FileName: string;
    Text: string;
    Occ: TArray<TPasOccurrence>;
  end;

function SimpleName(const Name: string): string;
var
  Dot: Integer;
begin
  Result := Trim(Name);
  Dot := Result.LastIndexOf('.');
  if Dot >= 0 then
    Result := Copy(Result, Dot + 2, MaxInt);
  if Result.StartsWith('&') then
    Delete(Result, 1, 1);
end;

function IsBinaryForm(const Text: string): Boolean;
begin
  Result := (Text <> '') and ((Text[1] = #$FF) or Text.StartsWith('TPF0'));
end;

function CollectOccurrences(Args: TJSONObject; const Name: string): TArray<TFileOccurrences>;
var
  F, Text: string;
  FO: TFileOccurrences;
  L: TList<TFileOccurrences>;
begin
  L := TList<TFileOccurrences>.Create;
  try
    for F in FilesArg(Args, True) do
    begin
      if not ReadSourceText(F, Text) or (IsFormFile(F) and IsBinaryForm(Text)) then
        Continue;
      FO.Occ := FindOccurrences(Text, Name);
      if Length(FO.Occ) = 0 then
        Continue;
      FO.FileName := F;
      FO.Text := Text;
      L.Add(FO);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function OccurrenceId(const F: string; const O: TPasOccurrence): string;
begin
  Result := Format('%s:%d:%d', [RelName(F), O.Line, O.Col]);
end;

function ToolFindReferences(Args: TJSONObject): TToolResult;
var
  Name: string;
  All: TArray<TFileOccurrences>;
  FO: TFileOccurrences;
  O: TPasOccurrence;
  Max, Count, Total: Integer;
  SB: TStringBuilder;
begin
  Name := SimpleName(JsonStr(Args, 'name'));
  if not IsValidIdentifier(Name) and not IsPascalKeyword(LowerCase(Name)) then
    Exit(TToolResult.Error('"name" must be an identifier, e.g. Save or TOrder.Save'));
  Max := IntArg(Args, 'maxResults', 300);
  All := CollectOccurrences(Args, Name);
  Total := 0;
  for FO in All do
    Inc(Total, Length(FO.Occ));
  SB := TStringBuilder.Create;
  try
    SB.AppendFormat('%d occurrence(s) of %s in %d file(s) (code only: comments and strings are skipped; ' +
      'any symbol with this name matches, the qualifier is shown when the code has one)',
      [Total, Name, Length(All)]).AppendLine;
    Count := 0;
    for FO in All do
    begin
      if Count >= Max then
        Break;
      SB.AppendLine.Append(RelName(FO.FileName)).AppendFormat(' (%d)', [Length(FO.Occ)]).AppendLine;
      for O in FO.Occ do
      begin
        if Count >= Max then
          Break;
        Inc(Count);
        SB.AppendFormat('  %d:%d  %s', [O.Line, O.Col, Trim(SourceLine(FO.Text, O.Line))]);
        if O.Qualifier <> '' then
          SB.Append('   [').Append(O.Qualifier).Append('.]');
        SB.AppendLine;
      end;
    end;
    if Total > Count then
      SB.AppendFormat('... %d more (raise maxResults or pass "files")', [Total - Count]).AppendLine;
    Result := TToolResult.Ok([SB.ToString]);
  finally
    SB.Free;
  end;
end;

function FormOpenInIde(const FormFile: string): Boolean;
var
  Module: IOTAModule;
begin
  Module := (BorlandIDEServices as IOTAModuleServices).FindModule(ChangeFileExt(FormFile, '.pas'));
  Result := Module <> nil;
end;

function WriteSourceFile(const FileName, NewText: string; out Note: string): Boolean;
var
  Buffer: IOTAEditBuffer;
  Module: IOTAModule;
  Bytes, Old: TBytes;
  WasModified: Boolean;
begin
  Note := '';
  Buffer := FindEditBuffer(FileName);
  if Buffer <> nil then
  begin
    if Buffer.IsReadOnly then
    begin
      Note := 'read-only in the editor';
      Exit(False);
    end;
    WasModified := Buffer.IsModified;
    ReplaceBufferText(Buffer, NewText);
    Module := (BorlandIDEServices as IOTAModuleServices).FindModule(FileName);
    if WasModified then
      Note := 'changed in the editor (it had unsaved changes, so it was not saved)'
    else if (Module <> nil) and Module.Save(False, True) then
      Note := 'changed in the editor and saved (Ctrl+Z undoes it)'
    else
      Note := 'changed in the editor, not saved';
    Exit(True);
  end;
  if not ReadFileBytes(FileName, Old) then
  begin
    Note := 'cannot read the file';
    Exit(False);
  end;
  Bytes := EncodeLike(NewText, DetectEncoding(Old));
  try
    TFile.WriteAllBytes(FileName, Bytes);
  except
    on E: Exception do
    begin
      Note := E.Message;
      Exit(False);
    end;
  end;
  Note := 'written (' + DetectEncoding(Old).Name + ')';
  Result := True;
end;

function ToolRenameSymbol(Args: TJSONObject): TToolResult;
var
  Name, NewName, Id, Note: string;
  All: TArray<TFileOccurrences>;
  FO: TFileOccurrences;
  O: TPasOccurrence;
  Only: TDictionary<string, Boolean>;
  Chosen: TList<TPasOccurrence>;
  OnlyArr: TJSONArray;
  V: TJSONValue;
  DryRun: Boolean;
  SB: TStringBuilder;
  Total, Changed, Files: Integer;
begin
  Name := SimpleName(JsonStr(Args, 'name'));
  NewName := Trim(JsonStr(Args, 'newName'));
  if not IsValidIdentifier(Name) then
    Exit(TToolResult.Error('"name" must be an identifier'));
  if not IsValidIdentifier(NewName) then
    Exit(TToolResult.Error('"newName" must be a valid Delphi identifier and not a reserved word'));
  DryRun := JsonBool(Args, 'dryRun', True);
  Only := TDictionary<string, Boolean>.Create;
  Chosen := TList<TPasOccurrence>.Create;
  SB := TStringBuilder.Create;
  try
    if Args.GetValue('only') is TJSONArray then
    begin
      OnlyArr := TJSONArray(Args.GetValue('only'));
      for V in OnlyArr do
        Only.AddOrSetValue(LowerCase(V.Value), True);
    end;
    All := CollectOccurrences(Args, Name);
    Total := 0;
    Changed := 0;
    Files := 0;
    if DryRun then
      SB.AppendFormat('Dry run: renaming %s to %s would change these occurrences. Check them: every symbol named ' +
        '%s matches. Then call renameSymbol with dryRun=false, passing "only" with the ids to change ' +
        '(or without "only" to change all of them).', [Name, NewName, Name]).AppendLine;
    for FO in All do
    begin
      Chosen.Clear;
      for O in FO.Occ do
      begin
        Id := OccurrenceId(FO.FileName, O);
        if (Only.Count = 0) or Only.ContainsKey(LowerCase(Id)) then
          Chosen.Add(O);
      end;
      if Chosen.Count = 0 then
        Continue;
      Inc(Total, Chosen.Count);
      if DryRun then
      begin
        SB.AppendLine.Append(RelName(FO.FileName)).AppendLine;
        for O in Chosen do
          SB.AppendFormat('  %s  %s', [OccurrenceId(FO.FileName, O), Trim(SourceLine(FO.Text, O.Line))]).AppendLine;
        if IsFormFile(FO.FileName) and FormOpenInIde(FO.FileName) then
          SB.Append('  (the form is open in the IDE: this file will be skipped; close it first or ' +
            'rename components with setComponentProperties)').AppendLine;
        Continue;
      end;
      if IsFormFile(FO.FileName) and FormOpenInIde(FO.FileName) then
      begin
        SB.AppendFormat('SKIPPED %s: the form is open in the IDE designer, which owns the file. Close the form ' +
          'and run renameSymbol for it again, or rename the component with setComponentProperties.',
          [RelName(FO.FileName)]).AppendLine;
        Continue;
      end;
      if WriteSourceFile(FO.FileName, ReplaceOccurrences(FO.Text, Chosen.ToArray, NewName), Note) then
      begin
        Inc(Changed, Chosen.Count);
        Inc(Files);
        SB.AppendFormat('%s: %d change(s), %s', [RelName(FO.FileName), Chosen.Count, Note]).AppendLine;
      end
      else
        SB.AppendFormat('FAILED %s: %s', [RelName(FO.FileName), Note]).AppendLine;
    end;
    if Total = 0 then
      Exit(TToolResult.Ok(['No occurrences of ' + Name + ' found' +
        IfThen(Only.Count > 0, ' with those ids', '') + '.']));
    if not DryRun then
      SB.AppendFormat('Renamed %d of %d occurrence(s) in %d file(s). Build the project (buildProject) to check ' +
        'that nothing else needs to change.', [Changed, Total, Files]).AppendLine;
    Result := TToolResult.Ok([SB.ToString]);
  finally
    SB.Free;
    Chosen.Free;
    Only.Free;
  end;
end;

{ Occurrences checked by DelphiLSP: which declaration each one refers to }

type
  TResolvedOcc = record
    FileIndex: Integer;  // into the occurrences per file
    Occ: TPasOccurrence;
    Decl: TLspLocation;  // Line = 0: not resolved
  end;
  TResolvedDone = reference to procedure(const Resolved: TArray<TResolvedOcc>; const Note: string);

var
  Lsp: TDelphiLsp;          // used by LspRunner's thread only
  LspRunner: TJobRunner;

const
  MAX_RESOLVED = 600;
  RESOLVE_SECONDS = 90;

{ A project or library path with $(BDS), $(Platform), $(Config) and other environment macros expanded;
  '' when a macro is unknown. }
function ExpandMacros(const S, Platform, Config: string): string;
var
  I, J: Integer;
  Name, V: string;
begin
  Result := S;
  I := Pos('$(', Result);
  while I > 0 do
  begin
    J := PosEx(')', Result, I);
    if J = 0 then
      Break;
    Name := Copy(Result, I + 2, J - I - 2);
    if SameText(Name, 'Platform') then
      V := Platform
    else if SameText(Name, 'Config') then
      V := Config
    else
      V := GetEnvironmentVariable(Name);
    if V = '' then
      Exit('');
    Result := Copy(Result, 1, I - 1) + V + Copy(Result, J + 1, MaxInt);
    I := PosEx('$(', Result, I + Length(V));
  end;
end;

{ The existing folders of a ';' list, absolute (relative ones are relative to BaseDir). }
function PathList(const Value, BaseDir, Platform, Config: string): TArray<string>;
var
  P, S: string;
begin
  Result := nil;
  for P in Value.Split([';']) do
  begin
    S := ExpandMacros(Trim(P), Platform, Config);
    if S = '' then
      Continue;
    if not TPath.IsPathRooted(S) then
      S := TPath.Combine(BaseDir, S);
    S := ExcludeTrailingPathDelimiter(ExpandFileName(S));
    if DirectoryExists(S) and (IndexText(S, Result) < 0) then
      Result := Result + [S];
  end;
end;

function ProjectConfigValue(const P: IOTAProject; const Name: string): string;
var
  Configs: IOTAProjectOptionsConfigurations;
  Cfg: IOTABuildConfiguration;
begin
  Result := '';
  if Supports(P.ProjectOptions, IOTAProjectOptionsConfigurations, Configs) and
     (Configs.ActiveConfiguration <> nil) then
  begin
    Cfg := Configs.ActiveConfiguration.PlatformConfiguration[P.CurrentPlatform];
    if Cfg = nil then
      Cfg := Configs.ActiveConfiguration;
    Result := Cfg.GetValue(Name, True);
  end;
end;

function IdeLibraryPath(const Platform: string): string;
var
  Reg: TRegistry;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly((BorlandIDEServices as IOTAServices).GetBaseRegistryKey + '\Library\' + Platform) and
       Reg.ValueExists('Search Path') then
      Result := Reg.ReadString('Search Path');
  finally
    Reg.Free;
  end;
end;

function QuotedList(const Paths: TArray<string>): string;
var
  P: string;
begin
  Result := '';
  for P in Paths do
  begin
    if Result <> '' then
      Result := Result + ';';
    Result := Result + '"' + P + '"';
  end;
end;

{ DelphiLSP's settings for the active project: the compiler, its options, the project's units. }
function LspSetup(out Exe, RootDir: string; out Settings: TJSONObject; out Why: string): Boolean;
var
  Project: IOTAProject;
  Platform, Config, Dir, Dll, Opts, S: string;
  Units, Includes: TArray<string>;
  Files: TJSONArray;
  I: Integer;
  MI: IOTAModuleInfo;
begin
  Result := False;
  Settings := nil;
  Why := '';
  Project := GetActiveProject;
  if Project = nil then
  begin
    Why := 'no active project';
    Exit;
  end;
  Exe := ExtractFilePath(ParamStr(0)) + 'DelphiLSP.exe';
  if not FileExists(Exe) then
  begin
    Why := 'DelphiLSP.exe was not found next to the IDE';
    Exit;
  end;
  Platform := Project.CurrentPlatform;
  if Platform = '' then
    Platform := 'Win32';
  if not (SameText(Platform, 'Win32') or SameText(Platform, 'Win64')) then
  begin
    Why := 'the active platform ' + Platform + ' is not checked (Win32 and Win64 are)';
    Exit;
  end;
  Config := Project.CurrentConfiguration;
  Dll := Format('dcc%s%d.dll', [IfThen(SameText(Platform, 'Win64'), '64', '32'), Round(CompilerVersion * 10)]);
  Dir := ExtractFilePath(Project.FileName);
  Units := PathList(ProjectConfigValue(Project, 'DCC_UnitSearchPath'), Dir, Platform, Config) +
    PathList(IdeLibraryPath(Platform), Dir, Platform, Config) +
    PathList('$(BDS)\lib\' + LowerCase(Platform) + '\release', Dir, Platform, Config);
  Includes := PathList(ProjectConfigValue(Project, 'DCC_IncludePath'), Dir, Platform, Config);
  Opts := '-$D+';
  S := ProjectConfigValue(Project, 'DCC_Define');
  if S <> '' then
    Opts := Opts + ' -D' + S;
  S := ProjectConfigValue(Project, 'DCC_Namespace');
  if S <> '' then
    Opts := Opts + ' -NS' + S;
  if Length(Units) > 0 then
    Opts := Opts + ' -U' + QuotedList(Units) + ' -R' + QuotedList(Units);
  if Length(Includes) > 0 then
    Opts := Opts + ' -I' + QuotedList(Includes);
  Files := TJSONArray.Create;
  for I := 0 to Project.GetModuleCount - 1 do
  begin
    MI := Project.GetModule(I);
    if (MI <> nil) and SameText(ExtractFileExt(MI.FileName), '.pas') then
      Files.Add(TJSONObject.Create.AddPair('name', ChangeFileExt(ExtractFileName(MI.FileName), ''))
        .AddPair('file', LspUri(MI.FileName)));
  end;
  Settings := TJSONObject.Create;
  Settings.AddPair('project', LspUri(Project.FileName));
  Settings.AddPair('dllname', Dll);
  Settings.AddPair('dccOptions', Opts);
  Settings.AddPair('projectFiles', Files);
  Settings.AddPair('includeDCUsInUsesCompletion', TJSONBool.Create(False));
  Settings.AddPair('enableKeyWordCompletion', TJSONBool.Create(False));
  Settings.AddPair('browsingPaths', TJSONArray.Create);
  RootDir := Dir;
  Result := True;
end;

{ Asks DelphiLSP where each occurrence is declared, in the background; Done runs in the main thread. }
procedure ResolveOccurrences(const All: TArray<TFileOccurrences>; const Done: TResolvedDone);
var
  Exe, RootDir, Why, Key: string;
  Settings: TJSONObject;
  Resolved: TArray<TResolvedOcc>;
  Note: string;
begin
  if LspRunner.Busy then
  begin
    Done(nil, 'another check by DelphiLSP is still running');
    Exit;
  end;
  if not LspSetup(Exe, RootDir, Settings, Why) then
  begin
    Done(nil, Why);
    Exit;
  end;
  Key := Exe + '|' + Settings.ToJSON;
  Resolved := nil;
  Note := '';
  LspRunner.Start(
    procedure(const Cancelled: TFunc<Boolean>)
    var
      I, Count: Integer;
      O: TPasOccurrence;
      R: TResolvedOcc;
      Deadline: TDateTime;
      Err: string;
      Checking: Boolean;
    begin
      // Another DelphiLSP.exe (the 64-bit IDE has its own): a new client.
      if (Lsp <> nil) and (Lsp.ConfigKey <> '') and not Lsp.ConfigKey.StartsWith(Exe + '|') then
        FreeAndNil(Lsp);
      if Lsp = nil then
        Lsp := TDelphiLsp.Create(Exe);
      if not Lsp.Running or (Lsp.ConfigKey <> Key) then
        if not Lsp.Start(RootDir, Settings, Key, Err) then
          Note := Err;
      Checking := Note = '';
      Count := 0;
      Deadline := IncSecond(Now, RESOLVE_SECONDS);
      for I := 0 to High(All) do
      begin
        if Cancelled() then
          Exit;
        if Checking and IsPascalFile(All[I].FileName) then
          Lsp.OpenText(All[I].FileName, All[I].Text);
        for O in All[I].Occ do
        begin
          R := Default(TResolvedOcc);
          R.FileIndex := I;
          R.Occ := O;
          if Checking and IsPascalFile(All[I].FileName) then
            if (Count >= MAX_RESOLVED) or (Now > Deadline) then
              Note := Format('only the first %d occurrences were checked', [Count])
            else
            begin
              // A character inside the name (the first one may be '&').
              R.Decl := Lsp.Definition(All[I].FileName, O.Line, O.Col + Ord(O.Len > 1));
              Inc(Count);
            end;
          Resolved := Resolved + [R];
        end;
      end;
    end,
    procedure
    begin
      Settings.Free;
      Done(Resolved, Note);
    end);
end;

{ "OrderLogic.pas:20" as renameSymbol takes it back. }
function DeclSpec(const L: TLspLocation): string;
begin
  if TPath.IsPathRooted(L.FileName) then
    Result := RelName(L.FileName) + ':' + IntToStr(L.Line)
  else
    Result := L.FileName + ':' + IntToStr(L.Line);
end;

{ The parameter list of a signature, for telling overloads apart: "(const a: string)" -> "(consta:string)". }
function ParamsOf(const Signature: string): string;
var
  A, B: Integer;
begin
  A := Pos('(', Signature);
  B := Signature.LastIndexOf(')') + 1;
  if (A = 0) or (B < A) then
    Exit('');
  Result := LowerCase(Copy(Signature, A, B - A + 1)).Replace(' ', '');
end;

type
  TSymbolInfo = record
    Key: string;       // the same for a method's declaration and its implementation
    Title: string;     // "method TOrder.Save (OrderLogic.pas:11)"
    IsBody: Boolean;   // the location is an implementation (methodImpl or a routine body)
  end;

{ What a definition location stands for. DelphiLSP sends a declaration in the class to the method
  body and the body back to the declaration, so both are one symbol: file, qualified name and
  parameters (overloads stay apart). }
function SymbolAt(const L: TLspLocation): TSymbolInfo;
var
  Info: TPasUnitInfo;
  D: TPasDecl;
begin
  Result.Key := AnsiLowerCase(L.FileName) + ':' + IntToStr(L.Line);
  Result.Title := DeclSpec(L);
  Result.IsBody := False;
  if not (TPath.IsPathRooted(L.FileName) and FileExists(L.FileName) and UnitInfoOf(L.FileName, Info)) then
    Exit;
  for D in Info.Decls do
    if D.Line = L.Line then
    begin
      Result.Title := Format('%s %s (%s)', [D.KindName, D.QualifiedName, DeclSpec(L)]);
      if D.Kind in [pdMethod, pdMethodImpl, pdRoutine] then
      begin
        Result.Key := AnsiLowerCase(L.FileName) + '|' + LowerCase(D.QualifiedName) + '|' + ParamsOf(D.Signature);
        Result.IsBody := (D.Kind = pdMethodImpl) or ((D.Kind = pdRoutine) and SameText(D.Section, 'implementation'));
      end;
      Exit;
    end;
end;

{ The symbol of a "file:line" spec among the locations found (the file may be given by name only). }
function SpecSymbol(const Spec: string; const Resolved: TArray<TResolvedOcc>; out Sym: TSymbolInfo): Boolean;
var
  P, Line: Integer;
  F: string;
  R: TResolvedOcc;
  L: TLspLocation;
  Info: TPasUnitInfo;
  D: TPasDecl;
begin
  Result := False;
  P := Spec.LastIndexOf(':');
  if P <= 0 then
    Exit;
  Line := StrToIntDef(Copy(Spec, P + 2, MaxInt), -1);
  F := ExtractFileName(Copy(Spec, 1, P).Replace('/', '\'));
  // A location DelphiLSP gave (declaration or body), or a declaration line of a file it points into.
  for R in Resolved do
    if (R.Decl.Line > 0) and SameText(ExtractFileName(R.Decl.FileName), F) then
    begin
      L := R.Decl;
      L.Line := Line;
      if TPath.IsPathRooted(L.FileName) and UnitInfoOf(L.FileName, Info) then
        for D in Info.Decls do
          if D.Line = Line then
          begin
            Sym := SymbolAt(L);
            Exit(True);
          end;
      if R.Decl.Line = Line then
      begin
        Sym := SymbolAt(L);
        Exit(True);
      end;
    end;
end;

procedure ToolFindReferencesAsync(Args: TJSONObject; const Done: TToolDone);
var
  Name: string;
  All: TArray<TFileOccurrences>;
  Max: Integer;
begin
  Name := SimpleName(JsonStr(Args, 'name'));
  if not JsonBool(Args, 'resolve', True) or not IsValidIdentifier(Name) then
  begin
    Done(ToolFindReferences(Args));
    Exit;
  end;
  Max := IntArg(Args, 'maxResults', 300);
  All := CollectOccurrences(Args, Name);
  if Length(All) = 0 then
  begin
    Done(ToolFindReferences(Args));
    Exit;
  end;
  ResolveOccurrences(All,
    procedure(const Resolved: TArray<TResolvedOcc>; const Note: string)
    var
      Groups: TDictionary<string, TList<Integer>>;
      Titles, Specs: TDictionary<string, string>;
      Order: TList<string>;
      Unresolved: TList<Integer>;
      I, J, Count, Checked: Integer;
      K, T: string;
      Sym: TSymbolInfo;
      SB: TStringBuilder;

      procedure Line(Index: Integer);
      var
        R: TResolvedOcc;
      begin
        R := Resolved[Index];
        if Count >= Max then
          Exit;
        Inc(Count);
        SB.AppendFormat('  %s  %s', [OccurrenceId(All[R.FileIndex].FileName, R.Occ),
          Trim(SourceLine(All[R.FileIndex].Text, R.Occ.Line))]).AppendLine;
      end;

    begin
      if Length(Resolved) = 0 then
      begin
        // DelphiLSP could not run: matching by name, with the reason.
        Done(TToolResult.Ok([ToolFindReferences(Args).Texts[0] + sLineBreak +
          '(Not checked by DelphiLSP: ' + Note + '.)']));
        Exit;
      end;
      Groups := TDictionary<string, TList<Integer>>.Create;
      Titles := TDictionary<string, string>.Create;
      Specs := TDictionary<string, string>.Create;
      Order := TList<string>.Create;
      Unresolved := TList<Integer>.Create;
      SB := TStringBuilder.Create;
      try
        Checked := 0;
        for I := 0 to High(Resolved) do
          if Resolved[I].Decl.Line = 0 then
            Unresolved.Add(I)
          else
          begin
            Inc(Checked);
            Sym := SymbolAt(Resolved[I].Decl);
            K := Sym.Key;
            if not Groups.ContainsKey(K) then
            begin
              Groups.Add(K, TList<Integer>.Create);
              Order.Add(K);
            end;
            Groups[K].Add(I);
            // The declaration names the group better than the body.
            if not Titles.ContainsKey(K) or not Sym.IsBody then
            begin
              Titles.AddOrSetValue(K, Sym.Title);
              Specs.AddOrSetValue(K, DeclSpec(Resolved[I].Decl));
            end;
          end;
        SB.AppendFormat('%d occurrence(s) of %s; DelphiLSP (the compiler) resolved %d of them to %d declaration(s). ' +
          'To rename the uses of one declaration only, call renameSymbol with "declaration" set to its file:line.',
          [Length(Resolved), Name, Checked, Order.Count]).AppendLine;
        Count := 0;
        for K in Order do
        begin
          T := Titles[K];
          SB.AppendLine.AppendFormat('%s - %d occurrence(s), declaration "%s"', [T, Groups[K].Count, Specs[K]])
            .AppendLine;
          for J in Groups[K] do
            Line(J);
        end;
        if Unresolved.Count > 0 then
        begin
          SB.AppendLine.AppendFormat('Not resolved - %d occurrence(s) (form files, other projects, or code the ' +
            'compiler could not read; check them by hand):', [Unresolved.Count]).AppendLine;
          for J in Unresolved do
            Line(J);
        end;
        if Count < Length(Resolved) then
          SB.AppendFormat('... %d more (raise maxResults or pass "files")', [Length(Resolved) - Count]).AppendLine;
        if Note <> '' then
          SB.Append('Note: ').Append(Note).AppendLine;
        Done(TToolResult.Ok([SB.ToString]));
      finally
        SB.Free;
        Unresolved.Free;
        for K in Order do
          Groups[K].Free;
        Order.Free;
        Specs.Free;
        Titles.Free;
        Groups.Free;
      end;
    end);
end;

procedure ToolRenameSymbolAsync(Args: TJSONObject; const Done: TToolDone);
var
  Name, Spec: string;
  All: TArray<TFileOccurrences>;
  ArgsCopy: TJSONObject;
begin
  Spec := Trim(JsonStr(Args, 'declaration'));
  Name := SimpleName(JsonStr(Args, 'name'));
  if (Spec = '') or not IsValidIdentifier(Name) then
  begin
    Done(ToolRenameSymbol(Args));
    Exit;
  end;
  All := CollectOccurrences(Args, Name);
  ArgsCopy := Args.Clone as TJSONObject;
  ResolveOccurrences(All,
    procedure(const Resolved: TArray<TResolvedOcc>; const Note: string)
    var
      Ids: TJSONArray;
      Other: TStringList;
      R: TResolvedOcc;
      V: TJSONValue;
      Target: TSymbolInfo;
      Res: TToolResult;
      Extra, T: string;
    begin
      Other := TStringList.Create;
      try
        if Length(Resolved) = 0 then
        begin
          Done(TToolResult.Error('The occurrences could not be checked by DelphiLSP (' + Note + '). Run ' +
            'renameSymbol without "declaration" (dry run) and pass the ids to change in "only".'));
          Exit;
        end;
        if not SpecSymbol(Spec, Resolved, Target) then
        begin
          Done(TToolResult.Error(Format('No occurrence of %s refers to the declaration %s. Call findReferences ' +
            'to see the declarations DelphiLSP found.', [Name, Spec])));
          Exit;
        end;
        Ids := TJSONArray.Create;
        for R in Resolved do
          if (R.Decl.Line > 0) and (SymbolAt(R.Decl).Key = Target.Key) then
            Ids.Add(OccurrenceId(All[R.FileIndex].FileName, R.Occ))
          else if R.Decl.Line = 0 then
            Other.Add(OccurrenceId(All[R.FileIndex].FileName, R.Occ));
        // Ids the caller adds by hand (form files, unresolved code) count too.
        if ArgsCopy.GetValue('only') is TJSONArray then
          for V in TJSONArray(ArgsCopy.GetValue('only')) do
            Ids.Add(V.Value);
        if Ids.Count = 0 then
        begin
          Ids.Free;
          Done(TToolResult.Error(Format('No occurrence of %s refers to the declaration %s.', [Name, Spec])));
          Exit;
        end;
        ArgsCopy.RemovePair('only').Free;
        ArgsCopy.AddPair('only', Ids);
        Res := ToolRenameSymbol(ArgsCopy);
        Extra := Format('DelphiLSP: %d occurrence(s) refer to %s.', [Ids.Count, Target.Title]);
        if Other.Count > 0 then
          Extra := Extra + Format(' %d could not be resolved and are not included: %s. Add the ones that belong ' +
            'to it in "only".', [Other.Count, string.Join(', ', Other.ToStringArray)]);
        if Note <> '' then
          Extra := Extra + ' Note: ' + Note + '.';
        if Res.IsError then
        begin
          Done(Res);
          Exit;
        end;
        T := Res.Texts[0];
        // The dry run's own header speaks of matching by name: here the compiler chose.
        if JsonBool(ArgsCopy, 'dryRun', True) and (Pos(sLineBreak + sLineBreak, T) > 0) then
          T := Format('Dry run: renaming the uses of %s to %s would change these occurrences (each one checked ' +
            'by DelphiLSP). Call renameSymbol again with dryRun=false and the same "declaration".',
            [Target.Title, JsonStr(ArgsCopy, 'newName')]) + Copy(T, Pos(sLineBreak + sLineBreak, T), MaxInt);
        Done(TToolResult.Ok([T + sLineBreak + Extra]));
      finally
        Other.Free;
        ArgsCopy.Free;
      end;
    end);
end;

procedure ShutdownCodeTools;
begin
  LspRunner.Cancel;
  FreeAndNil(Lsp);
end;

initialization
  Cache := TDictionary<string, TCachedUnit>.Create;
  LspRunner := TJobRunner.Create;
finalization
  LspRunner.Free;
  Lsp.Free;
  Cache.Free;
end.
