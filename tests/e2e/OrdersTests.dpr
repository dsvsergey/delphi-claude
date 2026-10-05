program OrdersTests;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  OrderLogic in 'OrderLogic.pas',
  OrderTests in 'OrderTests.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
begin
  try
    // Older DUnitX (Delphi 10 Seattle) waits for Enter at the end by default.
    TDUnitX.Options.ExitBehavior := TDUnitXExitBehavior.Continue;
    TDUnitX.CheckCommandLine;
    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;
    Runner.FailsOnNoAsserts := False;
    {$IF Declared(TDunitXConsoleMode)}
    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
      Runner.AddLogger(TDUnitXConsoleLogger.Create(TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet));
    {$ELSE}
    // Older DUnitX (Delphi 10 Seattle) has no --consolemode.
    Runner.AddLogger(TDUnitXConsoleLogger.Create(True));
    {$IFEND}
    Runner.AddLogger(TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile));
    Results := Runner.Execute;
    if not Results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
    if TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause then
      ReadLn;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
