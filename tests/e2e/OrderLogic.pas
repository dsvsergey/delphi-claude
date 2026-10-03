unit OrderLogic;

{ Business logic of the e2e sample. CalcTotal has a deliberate off-by-one bug
  (the last line is skipped) for the test, debugger and logpoint scenarios. }

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TOrderLine = record
    Product: string;
    Qty: Integer;
    Price: Currency;
  end;

  TOrder = class
  private
    FLines: TList<TOrderLine>;
    FCustomer: string;
  public
    constructor Create(const ACustomer: string);
    destructor Destroy; override;
    procedure AddLine(const Product: string; Qty: Integer; Price: Currency);
    function CalcTotal: Currency;
    function LineCount: Integer;
    property Customer: string read FCustomer;
  end;

function FormatTotal(const Order: TOrder): string;

implementation

constructor TOrder.Create(const ACustomer: string);
begin
  inherited Create;
  FCustomer := ACustomer;
  FLines := TList<TOrderLine>.Create;
end;

destructor TOrder.Destroy;
begin
  FLines.Free;
  inherited;
end;

procedure TOrder.AddLine(const Product: string; Qty: Integer; Price: Currency);
var
  L: TOrderLine;
begin
  L.Product := Product;
  L.Qty := Qty;
  L.Price := Price;
  FLines.Add(L);
end;

function TOrder.CalcTotal: Currency;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FLines.Count - 2 do
    Result := Result + FLines[I].Qty * FLines[I].Price;
end;

function TOrder.LineCount: Integer;
begin
  Result := FLines.Count;
end;

function FormatTotal(const Order: TOrder): string;
begin
  Result := Format('%s: %.2f', [Order.Customer, Double(Order.CalcTotal)]);
end;

end.
