# Claude Code for Delphi (RAD Studio 13)

**English** | [Українська](README.uk.md)

An IDE integration package that does for Delphi what the Claude Code extension does for VS Code:
- a **Claude Code panel** inside the IDE (dockable like the Project Manager or Messages) with a full terminal;
- Claude sees the Delphi editor, gets the current selection, opens files
  and shows proposed changes as a diff that you accept or reject in the IDE.

## How it works

It uses the same protocol as the VS Code, JetBrains and Neovim integrations:

1. The package starts a WebSocket server on `127.0.0.1` (+ `::1`) on a random port.
2. It writes `%USERPROFILE%\.claude\ide\<port>.lock` (`pid`, `workspaceFolders`, `ideName`, `authToken`).
   The token (128-bit, CSPRNG) is checked in the `x-claude-code-ide-authorization` header.
3. Claude Code finds the lock file and connects as an MCP client (JSON-RPC 2.0 over WebSocket).

### MCP tools provided by the IDE

| Tool | What it does in Delphi |
|---|---|
| `openFile` | opens a file, optionally selecting the range between `startText`/`endText` |
| `openDiff` | shows a diff window (colored line diff + editable tab); waits for **Accept** / **Reject** |
| `getCurrentSelection` / `getLatestSelection` | selected text and position in the active editor |
| `getOpenEditors` | open tabs (path, active, modified) |
| `getWorkspaceFolders` | project folders of the current project group |
| `getDiagnostics` | Error Insight (LSP) errors/warnings for open files |
| `checkDocumentDirty` / `saveDocument` | editor buffer state and saving |
| `close_tab` / `closeAllDiffTabs` | closing diff windows (and unmodified tabs) |

Notifications from the IDE: `selection_changed` (every ~300 ms when the selection/cursor changes)
and `at_mentioned` (the "Send Selection to Claude" command).

## The Claude Code panel

The panel works the same way as the VS Code integrated terminal:
- `claude` runs in a **Windows ConPTY** (pseudo console, Windows 10 1809+);
- output is rendered by **xterm.js** (the same engine VS Code uses) in **WebView2**;
- xterm.js, the terminal page and `WebView2Loader.dll` are embedded in the BPL as resources, nothing else to copy.
  Only the Microsoft Edge WebView2 Runtime is required (included in Windows 11).

Panel buttons: **New Session**, **Continue** (`claude --continue`), **Resume...** (`claude --resume`), **Stop**.
After a session ends, pressing Enter in the panel starts a new one.

Keyboard in the panel:
- all keys (Esc, Ctrl+C, Ctrl+R, Shift+Tab...) go to Claude;
- **Ctrl+C** copies when text is selected, **Ctrl+V** / Shift+Insert paste;
- **function keys** bound to IDE commands (F9, F7, F12...) run those IDE commands;
- **Ctrl+Shift+Alt+C** returns focus to the code editor (in the editor, the same shortcut opens/focuses the panel).

Closing the panel or the IDE ends the session together with all its child processes (Job Object).
Terminal colors follow the light or dark IDE theme; the font is taken from the code editor.

## Build and install

Requirements: RAD Studio / Delphi 13 (BDS 37.0) and the Claude Code CLI installed (`claude` on PATH).

```bat
build.bat
```
Output: `bin\Win32\ClaudeCodeIDE370.bpl` (for `bin\bds.exe`) and `bin\Win64\ClaudeCodeIDE370.bpl` (for the 64-bit IDE `bin64\bds.exe`).

Close the IDE and register the package (for both IDEs):
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```
Or manually: *Component → Install Packages… → Add…* and pick the BPL matching the IDE bitness.
Uninstall: `install.ps1 -Uninstall`.

If Delphi is installed elsewhere: `build.bat "C:\path\to\Studio\37.0"`.

## Usage

Menu **Tools → Claude Code**:

- **Open Claude Code** (`Ctrl+Shift+Alt+C`): opens the Claude Code panel and starts `claude` in the active project folder.
  Claude gets `CLAUDE_CODE_SSE_PORT` / `ENABLE_IDE_INTEGRATION` and connects to the IDE automatically.
- **Open in External Console**: the same in a separate console window (if WebView2 is unavailable).
- **Send Selection to Claude** (`Ctrl+Alt+K`): adds `@file#Lx-y` for the selected code to Claude's prompt.
- **Status and Log…**: port, number of connected clients, lock file, log.
- **Restart Server**: restarts with a new port and token (running sessions need `/ide` to reconnect).
- **Settings…**: the panel command (default `claude`, e.g. `claude --model opus`) and the external console command (default `cmd.exe /k claude`).

If Claude Code is already running in a separate terminal in the project folder, run `/ide` there and choose **Delphi**.

When Claude proposes an edit, a diff window opens:
**Accept (Ctrl+Enter)** sends the content (including your edits from the *Proposed* tab), then Claude writes the file;
**Reject (Esc)** or closing the window rejects the edit. You can also answer in the Claude terminal; the window then closes by itself.

## Layout

```
ClaudeCodeIDE.dpk                 design-time package (rtl, vcl, designide, IndySystem, IndyCore)
src/ClaudeCode.WebSocket.pas      RFC 6455 WebSocket server on Indy (loopback only, token check)
src/ClaudeCode.Mcp.pas            MCP / JSON-RPC, lock file, tool definitions
src/ClaudeCode.IdeBackend.pas     tool implementations via the Open Tools API
src/ClaudeCode.DiffForm.pas       diff window
src/ClaudeCode.Diff.pas           line diff (LCS)
src/ClaudeCode.Launcher.pas       starting the CLI with the right environment
src/ClaudeCode.TerminalPanel.pas  dockable IDE window
src/ClaudeCode.TerminalFrame.pas  panel frame: xterm.js + ConPTY, buttons, keyboard
src/ClaudeCode.WebViewHost.pas    lightweight WebView2 host (the page survives re-docking)
src/ClaudeCode.ConPty.pas         Windows pseudo console + Job Object
src/terminal/                     terminal page and .rc files for resources
src/ClaudeCode.Wizard.pas         IDE wizard: menu, timers, settings
tests/TestHost.dpr                console host with a fake backend
tests/protocol-test.mjs           protocol test (Node, raw WebSocket)
tests/PanelHost.dpr               the panel in a plain VCL window: starts claude, types text, takes a screenshot
third_party/                      xterm.js 6.0 (MIT), WebView2Loader 1.0.4191 (BSD, Microsoft)
```

### Testing without the IDE
```bash
cd tests
dcc32 -B -NSSystem;System.Win;Winapi;Vcl -U../src -NU../dcu/test -E. TestHost.dpr
TestHost.exe 20        # prints PORT and TOKEN
node protocol-test.mjs <PORT> <TOKEN>

# the panel outside the IDE (the working folder must be trusted by Claude)
dcc32 -B -NSSystem;System.Win;Winapi;Vcl;Vcl.Imaging -U../src -R../src -NU../dcu/test -E. PanelHost.dpr
PanelHost.exe C:\path\to\project C:\tmp\out   # out: panelhost.log, panelhost.dump.txt, panelhost.png
```

## Limitations

- `getDiagnostics` returns Error Insight (LSP) data for open files, not compiler output from the Messages window.
- `character` positions are counted by character index in the editor line; lines with non-ASCII characters may be slightly off.
