object DataOrders: TDataOrders
  Height = 200
  Width = 300
  object Connection: TFDConnection
    Params.Strings = (
      'Database=orders.db'
      'DriverID=SQLite')
    LoginPrompt = False
    Left = 48
    Top = 32
  end
end
