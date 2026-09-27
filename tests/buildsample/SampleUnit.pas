unit SampleUnit;

interface

function Answer: Integer;

implementation

function Answer: Integer;
var
  Unused: Integer;
begin
  {$IFDEF BREAK_BUILD}
  Result := UndeclaredThing;
  {$ELSE}
  Result := 42;
  {$ENDIF}
end;

end.
