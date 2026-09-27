unit ClaudeCode.Diff;

{ Line-based diff (LCS over the region between common prefix and suffix). }

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections;

type
  TDiffKind = (dkEqual, dkDelete, dkInsert);

  TDiffLine = record
    Kind: TDiffKind;
    OldLine: Integer; // 1-based, 0 when not applicable
    NewLine: Integer;
    Text: string;
  end;

  TDiffLines = TArray<TDiffLine>;

  { A run of changed lines: Diff[First..Last] are all deletes/inserts. }
  THunk = record
    First, Last: Integer;
  end;

  { The changed part of a line compared with its counterpart: Start is 1-based, Len may be 0. }
  TInlineRange = record
    Start, Len: Integer;
  end;

function SplitLines(const S: string): TArray<string>;
function ComputeLineDiff(const OldLines, NewLines: TArray<string>): TDiffLines;
procedure CountChanges(const Diff: TDiffLines; out Added, Removed: Integer);

function FindHunks(const Diff: TDiffLines): TArray<THunk>;
{ For each line of a hunk, the index of the line it replaces/is replaced by (k-th deleted line
  with k-th inserted line of the same hunk), or -1. }
function PairLines(const Diff: TDiffLines; const Hunks: TArray<THunk>): TArray<Integer>;
{ The text with only the Accepted hunks applied; rejected hunks keep the old lines. }
function ApplyHunks(const Diff: TDiffLines; const Hunks: TArray<THunk>; const Accepted: TArray<Boolean>;
  const LineBreak: string; TrailingBreak: Boolean): string;
{ The differing middle of A and B (common prefix and suffix removed). }
procedure InlineChange(const A, B: string; out InA, InB: TInlineRange);

implementation

const
  MAX_LCS_CELLS = 16 * 1024 * 1024;

function SplitLines(const S: string): TArray<string>;
var
  L: TList<string>;
  I, Start, N: Integer;
begin
  L := TList<string>.Create;
  try
    N := Length(S);
    Start := 1;
    I := 1;
    while I <= N do
    begin
      if (S[I] = #13) or (S[I] = #10) then
      begin
        L.Add(Copy(S, Start, I - Start));
        if (S[I] = #13) and (I < N) and (S[I + 1] = #10) then
          Inc(I);
        Start := I + 1;
      end;
      Inc(I);
    end;
    if Start <= N then
      L.Add(Copy(S, Start, N - Start + 1));
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function ComputeLineDiff(const OldLines, NewLines: TArray<string>): TDiffLines;
var
  Res: TList<TDiffLine>;
  Ids: TDictionary<string, Integer>;
  A, B: TArray<Integer>;
  NA, NB, Pre, Suf, N, M, I, J, W: Integer;
  Lcs: TArray<Word>;

  procedure Emit(Kind: TDiffKind; OldIdx, NewIdx: Integer);
  var
    D: TDiffLine;
  begin
    D.Kind := Kind;
    D.OldLine := 0;
    D.NewLine := 0;
    if Kind <> dkInsert then
    begin
      D.OldLine := OldIdx + 1;
      D.Text := OldLines[OldIdx];
    end;
    if Kind <> dkDelete then
    begin
      D.NewLine := NewIdx + 1;
      D.Text := NewLines[NewIdx];
    end;
    Res.Add(D);
  end;

  function IdOf(const S: string): Integer;
  begin
    if not Ids.TryGetValue(S, Result) then
    begin
      Result := Ids.Count;
      Ids.Add(S, Result);
    end;
  end;

begin
  NA := Length(OldLines);
  NB := Length(NewLines);
  Res := TList<TDiffLine>.Create;
  Ids := TDictionary<string, Integer>.Create;
  try
    Pre := 0;
    while (Pre < NA) and (Pre < NB) and (OldLines[Pre] = NewLines[Pre]) do
      Inc(Pre);
    Suf := 0;
    while (Suf < NA - Pre) and (Suf < NB - Pre) and
          (OldLines[NA - 1 - Suf] = NewLines[NB - 1 - Suf]) do
      Inc(Suf);

    for I := 0 to Pre - 1 do
      Emit(dkEqual, I, I);

    N := NA - Pre - Suf;
    M := NB - Pre - Suf;
    if (Int64(N + 1) * (M + 1) > MAX_LCS_CELLS) or (N = 0) or (M = 0) then
    begin
      // Degenerate or too large: all removed, then all added.
      for I := 0 to N - 1 do
        Emit(dkDelete, Pre + I, 0);
      for J := 0 to M - 1 do
        Emit(dkInsert, 0, Pre + J);
    end
    else
    begin
      SetLength(A, N);
      SetLength(B, M);
      for I := 0 to N - 1 do
        A[I] := IdOf(OldLines[Pre + I]);
      for J := 0 to M - 1 do
        B[J] := IdOf(NewLines[Pre + J]);
      // Lcs[i*(M+1)+j] = LCS length of A[i..] and B[j..]; min(N,M) <= 4096 so Word fits.
      W := M + 1;
      SetLength(Lcs, (N + 1) * W);
      for I := N - 1 downto 0 do
        for J := M - 1 downto 0 do
          if A[I] = B[J] then
            Lcs[I * W + J] := Lcs[(I + 1) * W + J + 1] + 1
          else if Lcs[(I + 1) * W + J] >= Lcs[I * W + J + 1] then
            Lcs[I * W + J] := Lcs[(I + 1) * W + J]
          else
            Lcs[I * W + J] := Lcs[I * W + J + 1];
      I := 0;
      J := 0;
      while (I < N) and (J < M) do
        if A[I] = B[J] then
        begin
          Emit(dkEqual, Pre + I, Pre + J);
          Inc(I);
          Inc(J);
        end
        else if Lcs[(I + 1) * W + J] >= Lcs[I * W + J + 1] then
        begin
          Emit(dkDelete, Pre + I, 0);
          Inc(I);
        end
        else
        begin
          Emit(dkInsert, 0, Pre + J);
          Inc(J);
        end;
      while I < N do
      begin
        Emit(dkDelete, Pre + I, 0);
        Inc(I);
      end;
      while J < M do
      begin
        Emit(dkInsert, 0, Pre + J);
        Inc(J);
      end;
    end;

    for I := 0 to Suf - 1 do
      Emit(dkEqual, NA - Suf + I, NB - Suf + I);
    Result := Res.ToArray;
  finally
    Ids.Free;
    Res.Free;
  end;
end;

procedure CountChanges(const Diff: TDiffLines; out Added, Removed: Integer);
var
  D: TDiffLine;
begin
  Added := 0;
  Removed := 0;
  for D in Diff do
    case D.Kind of
      dkInsert: Inc(Added);
      dkDelete: Inc(Removed);
    end;
end;

function FindHunks(const Diff: TDiffLines): TArray<THunk>;
var
  L: TList<THunk>;
  H: THunk;
  I: Integer;
begin
  L := TList<THunk>.Create;
  try
    I := 0;
    while I <= High(Diff) do
    begin
      if Diff[I].Kind = dkEqual then
      begin
        Inc(I);
        Continue;
      end;
      H.First := I;
      while (I <= High(Diff)) and (Diff[I].Kind <> dkEqual) do
        Inc(I);
      H.Last := I - 1;
      L.Add(H);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function PairLines(const Diff: TDiffLines; const Hunks: TArray<THunk>): TArray<Integer>;
var
  H: THunk;
  Dels, Ins: TList<Integer>;
  I: Integer;
begin
  SetLength(Result, Length(Diff));
  for I := 0 to High(Result) do
    Result[I] := -1;
  Dels := TList<Integer>.Create;
  Ins := TList<Integer>.Create;
  try
    for H in Hunks do
    begin
      Dels.Clear;
      Ins.Clear;
      for I := H.First to H.Last do
        if Diff[I].Kind = dkDelete then
          Dels.Add(I)
        else
          Ins.Add(I);
      for I := 0 to Min(Dels.Count, Ins.Count) - 1 do
      begin
        Result[Dels[I]] := Ins[I];
        Result[Ins[I]] := Dels[I];
      end;
    end;
  finally
    Ins.Free;
    Dels.Free;
  end;
end;

function ApplyHunks(const Diff: TDiffLines; const Hunks: TArray<THunk>; const Accepted: TArray<Boolean>;
  const LineBreak: string; TrailingBreak: Boolean): string;
var
  Keep: TArray<Boolean>;
  SB: TStringBuilder;
  I, H: Integer;
  First: Boolean;
begin
  // Equal lines stay; in an accepted hunk the inserts stay, in a rejected one the deletes.
  SetLength(Keep, Length(Diff));
  for I := 0 to High(Diff) do
    Keep[I] := Diff[I].Kind = dkEqual;
  for H := 0 to High(Hunks) do
    for I := Hunks[H].First to Hunks[H].Last do
      if (H <= High(Accepted)) and Accepted[H] then
        Keep[I] := Diff[I].Kind = dkInsert
      else
        Keep[I] := Diff[I].Kind = dkDelete;
  SB := TStringBuilder.Create;
  try
    First := True;
    for I := 0 to High(Diff) do
      if Keep[I] then
      begin
        if not First then
          SB.Append(LineBreak);
        SB.Append(Diff[I].Text);
        First := False;
      end;
    if TrailingBreak and not First then
      SB.Append(LineBreak);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure InlineChange(const A, B: string; out InA, InB: TInlineRange);
var
  Pre, Suf, LA, LB: Integer;
begin
  LA := Length(A);
  LB := Length(B);
  Pre := 0;
  while (Pre < LA) and (Pre < LB) and (A[Pre + 1] = B[Pre + 1]) do
    Inc(Pre);
  Suf := 0;
  while (Suf < LA - Pre) and (Suf < LB - Pre) and (A[LA - Suf] = B[LB - Suf]) do
    Inc(Suf);
  InA.Start := Pre + 1;
  InA.Len := LA - Pre - Suf;
  InB.Start := Pre + 1;
  InB.Len := LB - Pre - Suf;
end;

end.
