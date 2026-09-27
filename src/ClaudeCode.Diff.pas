unit ClaudeCode.Diff;

{ Line-based diff (LCS over the region between common prefix and suffix). }

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TDiffKind = (dkEqual, dkDelete, dkInsert);

  TDiffLine = record
    Kind: TDiffKind;
    OldLine: Integer; // 1-based, 0 when not applicable
    NewLine: Integer;
    Text: string;
  end;

  TDiffLines = TArray<TDiffLine>;

function SplitLines(const S: string): TArray<string>;
function ComputeLineDiff(const OldLines, NewLines: TArray<string>): TDiffLines;
procedure CountChanges(const Diff: TDiffLines; out Added, Removed: Integer);

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

end.
