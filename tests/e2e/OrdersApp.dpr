program OrdersApp;

uses
  Vcl.Forms,
  OrderLogic in 'OrderLogic.pas',
  MainForm in 'MainForm.pas' {FormMain},
  OrdersData in 'OrdersData.pas' {DataOrders: TDataModule};



begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormMain, FormMain);
  Application.CreateForm(TDataOrders, DataOrders);
  Application.Run;
end.
