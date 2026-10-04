@echo off
rem Builds ClaudeCodeIDE for the 32-bit and 64-bit Delphi 13 IDE.
setlocal
set "BDS="
if not "%~1"=="" set "BDS=%~1"
rem No argument: take RootDir of BDS 37.0 from the registry.
if not defined BDS for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Embarcadero\BDS\37.0" /v RootDir 2^>nul ^| find "RootDir"') do set "BDS=%%B"
if not defined BDS for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\WOW6432Node\Embarcadero\BDS\37.0" /v RootDir 2^>nul ^| find "RootDir"') do set "BDS=%%B"
if not defined BDS set "BDS=C:\Program Files (x86)\Embarcadero\Studio\37.0"
if "%BDS:~-1%"=="\" set "BDS=%BDS:~0,-1%"
if not exist "%BDS%\bin\dcc32.exe" (
  echo Delphi 13 not found at "%BDS%".
  echo Pass the path explicitly: build.bat "C:\path\to\Studio\37.0"
  exit /b 1
)
echo Using Delphi at %BDS%
set "NS=System;System.Win;Winapi;Vcl;Vcl.Imaging;Data;Xml"
cd /d "%~dp0"

if not exist bin\Win32 mkdir bin\Win32
if not exist bin\Win64 mkdir bin\Win64
if not exist dcu\Win32 mkdir dcu\Win32
if not exist dcu\Win64 mkdir dcu\Win64

echo === Resources (terminal page, xterm.js, WebView2Loader) ===
pushd src\terminal
"%BDS%\bin\brcc32.exe" -foterminal.res terminal.rc || exit /b 1
"%BDS%\bin\brcc32.exe" -foloader32.res loader32.rc || exit /b 1
"%BDS%\bin\brcc32.exe" -foloader64.res loader64.rc || exit /b 1
"%BDS%\bin\brcc32.exe" -fopages.res pages.rc || exit /b 1
popd

echo === Win32 (bds.exe in bin) ===
"%BDS%\bin\dcc32.exe" -B -Q -NS%NS% -LE"bin\Win32" -LN"bin\Win32" -NU"dcu\Win32" -I"src" -U"src" -R"src" ClaudeCodeIDE.dpk || exit /b 1

echo === Win64 (bds.exe in bin64) ===
"%BDS%\bin\dcc64.exe" -B -Q -NS%NS% -LE"bin\Win64" -LN"bin\Win64" -NU"dcu\Win64" -I"src" -U"src" -R"src" ClaudeCodeIDE.dpk || exit /b 1

echo Done. Packages are in bin\Win32 and bin\Win64.
