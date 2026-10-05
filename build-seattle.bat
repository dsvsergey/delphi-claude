@echo off
rem Builds ClaudeCodeIDE for the Delphi 10 Seattle IDE (32-bit only) into bin\Seattle.
rem Seattle has no Winapi.WebView2 and Winapi.UIAutomation; they are compiled from the sources
rem of a newer Delphi (Delphi 13 by default, or the folder in the second argument).
rem   build-seattle.bat ["C:\path\to\Studio\17.0"] ["C:\path\to\Studio\37.0"]
setlocal
set "BDS="
set "NEWBDS="
if not "%~1"=="" set "BDS=%~1"
if not "%~2"=="" set "NEWBDS=%~2"
if not defined BDS for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Embarcadero\BDS\17.0" /v RootDir 2^>nul ^| find "RootDir"') do set "BDS=%%B"
if not defined BDS for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\WOW6432Node\Embarcadero\BDS\17.0" /v RootDir 2^>nul ^| find "RootDir"') do set "BDS=%%B"
if not defined BDS set "BDS=C:\Program Files (x86)\Embarcadero\Studio\17.0"
if "%BDS:~-1%"=="\" set "BDS=%BDS:~0,-1%"
if not defined NEWBDS for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Embarcadero\BDS\37.0" /v RootDir 2^>nul ^| find "RootDir"') do set "NEWBDS=%%B"
if not defined NEWBDS set "NEWBDS=C:\Program Files (x86)\Embarcadero\Studio\37.0"
if "%NEWBDS:~-1%"=="\" set "NEWBDS=%NEWBDS:~0,-1%"
if not exist "%BDS%\bin\dcc32.exe" (
  echo Delphi 10 Seattle not found at "%BDS%".
  echo Pass the path explicitly: build-seattle.bat "C:\path\to\Studio\17.0"
  exit /b 1
)
if not exist "%NEWBDS%\source\rtl\win\Winapi.WebView2.pas" (
  echo Winapi.WebView2.pas not found under "%NEWBDS%\source\rtl\win".
  echo Pass a Delphi 10.4 or later folder: build-seattle.bat "%BDS%" "C:\path\to\Studio\37.0"
  exit /b 1
)
echo Using Delphi at %BDS%
set "NS=System;System.Win;Winapi;Vcl;Vcl.Imaging;Data;Xml"
cd /d "%~dp0"

if not exist bin\Seattle mkdir bin\Seattle
if not exist dcu\Seattle\rtlsrc mkdir dcu\Seattle\rtlsrc
copy /y "%NEWBDS%\source\rtl\win\Winapi.WebView2.pas" dcu\Seattle\rtlsrc\ >nul || exit /b 1
copy /y "%NEWBDS%\source\rtl\win\Winapi.UIAutomation.pas" dcu\Seattle\rtlsrc\ >nul || exit /b 1

echo === Resources (terminal page, xterm.js, WebView2Loader) ===
pushd src\terminal
"%BDS%\bin\brcc32.exe" -foterminal.res terminal.rc || exit /b 1
"%BDS%\bin\brcc32.exe" -foloader32.res loader32.rc || exit /b 1
"%BDS%\bin\brcc32.exe" -foloader64.res loader64.rc || exit /b 1
"%BDS%\bin\brcc32.exe" -fopages.res pages.rc || exit /b 1
popd

echo === Win32 ===
"%BDS%\bin\dcc32.exe" -B -Q -NS%NS% -LE"bin\Seattle" -LN"bin\Seattle" -NU"dcu\Seattle" -I"src" -U"src;dcu\Seattle\rtlsrc" -R"src" ClaudeCodeIDE.dpk || exit /b 1

echo Done. The package is bin\Seattle\ClaudeCodeIDE230.bpl.
