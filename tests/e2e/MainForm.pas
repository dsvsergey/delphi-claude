unit MainForm;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  OrderLogic;

type
  TFormMain = class(TForm)
    EditProduct: TEdit;
    ButtonAdd: TButton;
    ListLines: TListBox;
    LabelTotal: TLabel;
    procedure ButtonAddClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FOrder: TOrder;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.dfm}

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FOrder := TOrder.Create('Walk-in');
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  FOrder.Free;
end;

procedure TFormMain.ButtonAddClick(Sender: TObject);
begin
  FOrder.AddLine(EditProduct.Text, 1, 10);
  ListLines.Items.Add(EditProduct.Text);
  LabelTotal.Caption := FormatTotal(FOrder);
end;

end.
