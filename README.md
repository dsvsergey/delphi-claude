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

### Delphi tools for Claude (the `delphi` MCP server)

Claude Code uses the IDE connection itself and shows the model only `getDiagnostics` from it,
so Delphi-specific tools are served as a second MCP server, **`delphi`** (Streamable HTTP,
`POST http://127.0.0.1:<port>/mcp`, same token as a Bearer header). The panel and
**Open in External Console** start Claude with `--mcp-config` pointing at it, so the tools appear
as `mcp__delphi__*` and Claude asks for permission before using them like any MCP tool.

| Tool | What it does |
|---|---|
| `buildProject` | builds a project with MSBuild using its `.dproj` settings (active config/platform by default); returns errors, warnings and hints and shows them in the **Claude Build** tab of the Messages window |
| `getProjectInfo` | project group, active config/platform, framework, output file, defines, search paths, namespaces, units and forms |
| `getFormComponents` | a form as it is in the designer now (unsaved changes included): components and the DFM text, or one component's DFM block |
| `getSelectedComponents` | components selected in the form designer, with their DFM blocks |
| `setComponentProperties` | changes properties through the designer: nested (`Font.Size`), enums/sets, `clRed`-style identifiers, component references, `Items`/`Lines`, event handlers (created if missing); returns old/new values |
| `createComponent` / `deleteComponent` | drops a registered component on the form (name, parent, bounds, properties) / deletes one |
| `captureForm` | PNG of a VCL form or control as drawn in the designer; Claude opens it with its Read tool |
| `getDebugState` | the debugged process: state, current thread with call stack and source around the current line, the exception when stopped on one, all threads |
| `evaluateExpression` | evaluates a Delphi expression in the stopped process (like Evaluate/Modify); side effects only when allowed |
| `setBreakpoint` / `listBreakpoints` / `removeBreakpoint` | source breakpoints with an optional condition and pass count |
| `debugControl` | `stepOver`, `stepInto`, `runUntilReturn`, `runToCursor`, `pause` (waits for the next stop and returns the new state), `run`, `terminate` |

Designer changes are not saved automatically: review them in the IDE and save or revert the form.
A `claude` started outside the IDE can use the tools of the most recently started IDE with
`claude --mcp-config "%USERPROFILE%\.claude\ide\delphi-mcp.json"`.

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
- **Build and Fix Errors with Claude**: saves modified files, builds the active project and, if the build fails, pastes the errors into the Claude panel as a request (press Enter to send).
- **Explain Debugger Stop with Claude**: when the debugged program is stopped (breakpoint, exception, pause), pastes the exception, the current line with its source and the call stack into the Claude panel as a request.
- **Send Selection to Claude** (`Ctrl+Alt+K`): adds `@file#Lx-y` for the selected code to Claude's prompt; in the form designer it pastes the selected components as DFM text.
- **Status and Log…**: port, number of connected clients, lock file, log.
- **Restart Server**: restarts with a new port and token (running sessions need `/ide` to reconnect).
- **Settings…**: the panel command (default `claude`, e.g. `claude --model opus`), the external console command (default `cmd.exe /k claude`) and whether Claude's file changes are applied to open editors (`1`/`0`).

If Claude Code is already running in a separate terminal in the project folder, run `/ide` there and choose **Delphi**.

When Claude proposes an edit, a diff window opens:
**Accept (Ctrl+Enter)** sends the content (including your edits from the *Proposed* tab), then Claude writes the file;
**Reject (Esc)** or closing the window rejects the edit. You can also answer in the Claude terminal; the window then closes by itself.

### Files Claude changes on disk

- An open, unmodified editor tab picks up Claude's change right away as one undoable edit
  (**Ctrl+Z** in the editor restores the previous text) and is saved by the IDE, so there is no
  "file changed on disk" prompt and the file keeps its encoding. Tabs with unsaved edits are not touched;
  a note appears on the **Claude Code** tab of the Messages window.
- ANSI files (e.g. cp1251): Claude reads them as UTF-8 and every non-ASCII character arrives as `�`.
  The diff window and the editor sync put the original characters back (whole unchanged lines, and
  runs of `�` in changed lines when the text around them matches). Lines that could not be repaired are reported.
- After an accepted diff, a Delphi source (`.pas`, `.dpr`, `.dpk`, `.inc`) that Claude saved as UTF-8 without
  a BOM is converted back to ANSI if it was ANSI, or gets a UTF-8 BOM, so the compiler reads its non-ASCII text correctly.
- Turn it off in **Settings…** (third field: `0`).

## Layout

```
ClaudeCodeIDE.dpk                 design-time package (rtl, vcl, designide, IndySystem, IndyCore)
src/ClaudeCode.WebSocket.pas      RFC 6455 WebSocket server on Indy (loopback only, token check)
src/ClaudeCode.Mcp.pas            MCP / JSON-RPC: IDE channel (WebSocket, lock file) and the "delphi" server (HTTP)
src/ClaudeCode.Build.pas          MSBuild runner and compiler output parser
src/ClaudeCode.TextSync.pas       encodings, restoring lost characters, changed span (no ToolsAPI)
src/ClaudeCode.EditorSync.pas     applies disk changes to open editors, fixes encodings after a diff
src/ClaudeCode.ComponentProps.pas DFM text and setting properties from JSON via RTTI (no ToolsAPI)
src/ClaudeCode.FormTools.pas      form designer tools
src/ClaudeCode.DebugTools.pas     debugger tools (state, evaluate, breakpoints, stepping)
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
TestHost.exe build     # builds tests/buildsample with MSBuild (success, then a compile error)
node protocol-test.mjs <PORT> <TOKEN>

# the panel outside the IDE (the working folder must be trusted by Claude)
dcc32 -B -NSSystem;System.Win;Winapi;Vcl;Vcl.Imaging -U../src -R../src -NU../dcu/test -E. PanelHost.dpr
PanelHost.exe C:\path\to\project C:\tmp\out   # out: panelhost.log, panelhost.dump.txt, panelhost.png
```

## Limitations

- `getDiagnostics` returns Error Insight (LSP) data for open files; use `buildProject` for real compiler output.
- `buildProject` compiles files from disk: unsaved editor changes are reported in `unsavedFiles` unless `saveModified` is set.
- `character` positions are UTF-16 indexes computed from the editor buffer; they have not been verified against every IDE edge case (tabs, very long lines).
- Encoding repair only sees files written through an accepted diff or open in the editor; files Claude writes in auto-accept mode while closed keep whatever encoding Claude used.
- The debugger API has no list of local variables: Claude reads the code around the current line and evaluates what it needs. Exception class/message come from evaluating `ExceptObject` (best effort).
