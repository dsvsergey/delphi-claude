object FormMain: TFormMain
  Left = 0
  Top = 0
  Caption = 'Orders'
  ClientHeight = 300
  ClientWidth = 420
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object LabelTotal: TLabel
    Left = 16
    Top = 264
    Width = 60
    Height = 15
    Caption = 'Total: 0.00'
  end
  object EditProduct: TEdit
    Left = 16
    Top = 16
    Width = 280
    Height = 23
    TabOrder = 0
    Text = 'Coffee'
  end
  object ButtonAdd: TButton
    Left = 312
    Top = 15
    Width = 90
    Height = 25
    Caption = 'Add'
    TabOrder = 1
    OnClick = ButtonAddClick
  end
  object ListLines: TListBox
    Left = 16
    Top = 56
    Width = 386
    Height = 193
    ItemHeight = 15
    TabOrder = 2
  end
end
