@echo off
rem Builds ClaudeCodeIDE for the 32-bit and 64-bit Delphi 13 IDE.
setlocal
set "BDS=d:\Program Files (x86)\Embarcadero\Studio\37.0"
if not "%~1"=="" set "BDS=%~1"
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
