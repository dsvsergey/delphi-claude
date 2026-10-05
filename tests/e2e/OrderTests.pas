unit OrderTests;

interface

uses
  DUnitX.TestFramework, OrderLogic;

type
  [TestFixture]
  TOrderTests = class
  public
    [Test]
    procedure EmptyOrderTotalIsZero;
    [Test]
    procedure TotalAddsAllLines;
    [Test]
    procedure LineCountCountsLines;
  end;

implementation

procedure TOrderTests.EmptyOrderTotalIsZero;
var
  O: TOrder;
begin
  O := TOrder.Create('A');
  try
    Assert.AreEqual<Currency>(0, O.CalcTotal);
  finally
    O.Free;
  end;
end;

procedure TOrderTests.TotalAddsAllLines;
var
  O: TOrder;
begin
  O := TOrder.Create('A');
  try
    O.AddLine('Tea', 2, 3);
    O.AddLine('Cake', 1, 4);
    Assert.AreEqual<Currency>(10, O.CalcTotal, 'two lines');
  finally
    O.Free;
  end;
end;

procedure TOrderTests.LineCountCountsLines;
var
  O: TOrder;
begin
  O := TOrder.Create('A');
  try
    O.AddLine('Tea', 1, 1);
    Assert.AreEqual(1, O.LineCount);
  finally
    O.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TOrderTests);
end.
