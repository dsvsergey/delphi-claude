# Claude Code для Delphi (RAD Studio 13)

[English](README.md) | **Українська**

Пакет інтеграції IDE, що робить для Delphi те саме, що розширення Claude Code робить для VS Code:
- **панель Claude Code** всередині IDE (пристиковується, як Project Manager чи Messages) з повноцінним терміналом;
- Claude бачить редактор Delphi, отримує поточне виділення, відкриває файли
  й показує запропоновані зміни як diff, який ви приймаєте або відхиляєте в IDE.

## Як це працює

Протокол той самий, що в розширеннях для VS Code, JetBrains і Neovim:

1. Пакет запускає WebSocket-сервер на `127.0.0.1` (+ `::1`), випадковий порт.
2. Записує `%USERPROFILE%\.claude\ide\<port>.lock` (`pid`, `workspaceFolders`, `ideName`, `authToken`).
   Токен (128 біт, CSPRNG) перевіряється в заголовку `x-claude-code-ide-authorization`.
3. Claude Code знаходить lock-файл і підключається як MCP-клієнт (JSON-RPC 2.0 через WebSocket).

### MCP-інструменти, які надає IDE

| Інструмент | Що робить у Delphi |
|---|---|
| `openFile` | відкриває файл, за потреби виділяє діапазон між `startText`/`endText` |
| `openDiff` | показує вікно diff (кольоровий порядковий diff + вкладка для редагування); чекає на **Accept** / **Reject** |
| `getCurrentSelection` / `getLatestSelection` | виділений текст і позиція в активному редакторі |
| `getOpenEditors` | відкриті вкладки (шлях, активна, чи змінена) |
| `getWorkspaceFolders` | теки проєктів поточної групи проєктів |
| `getDiagnostics` | помилки/попередження Error Insight (LSP) для відкритих файлів |
| `checkDocumentDirty` / `saveDocument` | стан і збереження буфера редактора |
| `close_tab` / `closeAllDiffTabs` | закриття вікон diff (і незмінених вкладок) |

Сповіщення від IDE: `selection_changed` (кожні ~300 мс, коли змінюється виділення/курсор)
та `at_mentioned` (команда «Send Selection to Claude»).

### Delphi-інструменти для Claude (MCP-сервер `delphi`)

Claude Code використовує IDE-з'єднання сам і з нього показує моделі лише `getDiagnostics`,
тому Delphi-інструменти надаються другим MCP-сервером **`delphi`** (Streamable HTTP,
`POST http://127.0.0.1:<port>/mcp`, той самий токен у заголовку Bearer). Панель і
**Open in External Console** запускають Claude з `--mcp-config`, що вказує на нього: інструменти
видно як `mcp__delphi__*`, і Claude питає дозвіл на їх використання, як для будь-якого MCP-інструмента.

| Інструмент | Що робить |
|---|---|
| `buildProject` | збирає проєкт через MSBuild з налаштуваннями `.dproj` (за замовчуванням активні config/platform); повертає помилки, попередження й підказки та показує їх на вкладці **Claude Build** вікна Messages |
| `getProjectInfo` | група проєктів, активні config/platform, framework, вихідний файл, defines, шляхи пошуку, namespaces, модулі й форми |
| `getFormComponents` | форма в дизайнері зараз (з незбереженими змінами): компоненти і DFM-текст, або DFM-блок одного компонента |
| `getSelectedComponents` | компоненти, виділені в дизайнері, з їхніми DFM-блоками |
| `setComponentProperties` | змінює властивості через дизайнер: вкладені (`Font.Size`), enum/set, ідентифікатори на кшталт `clRed`, посилання на компоненти, `Items`/`Lines`, обробники подій (створюються, якщо їх немає); повертає старі/нові значення |
| `createComponent` / `deleteComponent` | кладе на форму зареєстрований компонент (ім'я, батько, розміри, властивості) / видаляє компонент |
| `captureForm` | PNG VCL-форми або контролу, як вони виглядають у дизайнері; Claude відкриває його інструментом Read |
| `getDebugState` | процес під налагодженням: стан, поточний потік зі стеком викликів і кодом навколо поточного рядка, виняток (якщо зупинка на ньому), усі потоки |
| `evaluateExpression` | обчислює вираз Delphi у зупиненому процесі (як Evaluate/Modify); побічні ефекти — лише якщо дозволено |
| `setBreakpoint` / `listBreakpoints` / `removeBreakpoint` | точки зупину в коді з умовою і лічильником проходів |
| `debugControl` | `stepOver`, `stepInto`, `runUntilReturn`, `runToCursor`, `pause` (чекає наступної зупинки й повертає новий стан), `run`, `terminate` |

Зміни в дизайнері не зберігаються автоматично: перегляньте їх в IDE і збережіть або відкотіть форму.
`claude`, запущений поза IDE, може використати інструменти останньої запущеної IDE:
`claude --mcp-config "%USERPROFILE%\.claude\ide\delphi-mcp.json"`.

## Панель Claude Code

Панель влаштована так само, як вбудований термінал VS Code:
- `claude` запускається в **Windows ConPTY** (псевдоконсоль, Windows 10 1809+);
- вивід відображає **xterm.js** (той самий рушій, що у VS Code) у **WebView2**;
- xterm.js, сторінка терміналу й `WebView2Loader.dll` вбудовані в BPL як ресурси, окремо нічого копіювати не треба.
  Потрібен лише Microsoft Edge WebView2 Runtime (є у Windows 11).

Кнопки панелі: **New Session**, **Continue** (`claude --continue`), **Resume...** (`claude --resume`), **Stop**, **+** (нова вкладка), **x** (закрити вкладку).
Коли сесія завершилась, Enter у панелі запускає нову.

**Вкладки.** Кожна вкладка — окрема сесія Claude Code. **Open Claude Code** перемикає на вкладку теки активного проєкту (або відкриває нову); **+** — нова вкладка для поточного проєкту, **x** або клік середньою кнопкою закриває вкладку (і зупиняє її сесію). Вкладка показує `●`, поки Claude працює, і `!`, коли він чекає на вас; кнопки панелі, **Send Selection** і запити з контекстних меню діють на активну вкладку.

Клавіатура в панелі:
- усі клавіші (Esc, Ctrl+C, Ctrl+R, Shift+Tab...) ідуть у Claude;
- **Ctrl+C** при виділеному тексті копіює, **Ctrl+V** / Shift+Insert вставляють текст; скопійоване зображення (скриншот) зберігається в PNG, і вставляється шлях, тож Claude його прикріплює; скопійовані файли стають `@`-посиланнями;
- файли, перетягнуті на термінал, вставляються як `@`-посилання (зображення — як шляхи);
- **F-клавіші**, на які в IDE призначено команди (F9, F7, F12...), виконують команди IDE;
- **Ctrl+Shift+Alt+C** повертає фокус у редактор коду (у редакторі ця ж комбінація відкриває/фокусує панель).

Рядок стану панелі показує **Working...**, **Waiting for you** або **Ready** і поточний заголовок Claude. Коли Claude закінчив або чекає на вас, а панель прихована чи IDE не активна, IDE блимає на панелі задач, а до заголовка панелі додається ` *`.

Закриття панелі чи IDE завершує сесію разом з усіма дочірніми процесами (Job Object).
Кольори терміналу підлаштовуються під світлу або темну тему IDE, шрифт береться з редактора коду.

## Збірка та встановлення

Потрібно: RAD Studio / Delphi 13 (BDS 37.0) і встановлений Claude Code CLI (`claude` у PATH).

```bat
build.bat
```
Результат: `bin\Win32\ClaudeCodeIDE370.bpl` (для `bin\bds.exe`) і `bin\Win64\ClaudeCodeIDE370.bpl` (для 64-бітної IDE `bin64\bds.exe`).

Закрийте IDE і зареєструйте пакет (для обох IDE):
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```
Або вручну: *Component → Install Packages… → Add…* і вкажіть BPL, що відповідає розрядності IDE.
Видалення: `install.ps1 -Uninstall`.

Якщо Delphi встановлено в іншому місці: `build.bat "C:\шлях\до\Studio\37.0"`.

## Використання

Меню **Tools → Claude Code**:

- **Open Claude Code** (`Ctrl+Shift+Alt+C`): відкриває панель Claude Code і запускає `claude` у теці активного проєкту.
  Claude отримує `CLAUDE_CODE_SSE_PORT` / `ENABLE_IDE_INTEGRATION` і підключається до IDE сам.
- **Open in External Console**: те саме в окремому вікні консолі (якщо WebView2 недоступний).
- **Build and Fix Errors with Claude**: зберігає змінені файли, збирає активний проєкт і, якщо збірка невдала, вставляє помилки в панель Claude як запит (Enter — надіслати).
- **Explain Debugger Stop with Claude**: коли програма під налагодженням зупинена (breakpoint, виняток, пауза), вставляє в панель Claude виняток, поточний рядок із кодом і стек викликів як запит.
- **Send Selection to Claude** (`Ctrl+Alt+K`): додає в підказку Claude `@файл#Lx-y` для виділеного фрагмента; у дизайнері форм вставляє виділені компоненти як DFM-текст.
- **Status and Log…**: порт, кількість підключених клієнтів, lock-файл, журнал.
- **Restart Server**: перезапуск із новим портом і токеном (запущеним сесіям потрібно виконати `/ide`).
- **Settings…**: команда для панелі (типово `claude`; наприклад `claude --model opus`), для зовнішньої консолі (типово `cmd.exe /k claude`) і чи застосовувати зміни файлів від Claude до відкритих редакторів (`1`/`0`).


### Контекстні меню

- **Редактор коду → Claude Code**: *Explain*, *Refactor*, *Find Bugs*, *Write DUnitX Test*, *Add XML Documentation*
  надсилають запит з `@файл#Lx-y` для виділення (або поточного рядка);
  *Ask Claude About This...* лише вставляє посилання в підказку. Тексти запитів можна змінити у
  `%USERPROFILE%\.claude\delphi-prompts.json`, наприклад `{"explain": "Поясни цей код: {ref}"}`
  (ключі: `explain`, `refactor`, `review`, `test`, `doc`, `ask`).
- **Project Manager → Add to Claude Context**: вставляє в підказку `@файл` (або `@тека/` для проєкту) для виділених вузлів.
- **Messages → Fix Build Errors with Claude**: те саме, що команда з меню Tools (вікно Messages не дає прочитати текст
  своїх рядків, тож проєкт перезбирається, щоб зібрати помилки).
Якщо Claude Code вже запущено в окремому терміналі в теці проєкту, виконайте в ньому `/ide` і виберіть **Delphi**.

Коли Claude пропонує правку, відкривається вікно diff:
**Accept (Ctrl+Enter)** передає вміст (разом із вашими правками з вкладки *Proposed*), після чого Claude записує файл;
**Reject (Esc)** або закриття вікна відхиляють правку. Відповісти можна й у терміналі Claude, тоді вікно закриється само.
Вікно diff підсвічує змінену частину кожного рядка, у звичайному режимі або **поруч** (вибір запам'ятовується).
Окремі зміни можна пропустити: **пробіл** або подвійний клік бере/пропускає зміну під курсором, **N** / **P** —
перехід між змінами; Accept записує лише взяті зміни (якщо не взято жодної — це відхилення).

### Файли, які Claude змінює на диску

- Відкрита вкладка без незбережених змін одразу отримує зміну Claude як одну правку, яку можна скасувати
  (**Ctrl+Z** у редакторі повертає попередній текст), і IDE зберігає файл сама: немає питання «file changed on disk»,
  кодування файлу зберігається. Вкладки з незбереженими змінами не чіпаються; про це з'являється запис на вкладці
  **Claude Code** вікна Messages.
- ANSI-файли (наприклад cp1251): Claude читає їх як UTF-8, і кожен не-ASCII символ приходить як `�`.
  Diff-вікно і синхронізація редактора повертають оригінальні символи (цілі незмінені рядки, а в змінених рядках —
  фрагменти `�`, якщо текст навколо збігається). Рядки, які не вдалося відновити, показуються окремо.
- Після прийнятого diff Delphi-файл (`.pas`, `.dpr`, `.dpk`, `.inc`), який Claude зберіг як UTF-8 без BOM, повертається
  в ANSI, якщо був ANSI, або отримує UTF-8 BOM, щоб компілятор правильно читав не-ASCII текст.
- Вимкнути: **Settings…**, третє поле `0`.

## Структура

```
ClaudeCodeIDE.dpk              design-time пакет (rtl, vcl, designide, IndySystem, IndyCore)
src/ClaudeCode.WebSocket.pas   WebSocket-сервер RFC 6455 на Indy (лише loopback, перевірка токена)
src/ClaudeCode.Mcp.pas         MCP / JSON-RPC: канал IDE (WebSocket, lock-файл) і сервер "delphi" (HTTP)
src/ClaudeCode.Build.pas      запуск MSBuild і розбір виводу компілятора
src/ClaudeCode.TextSync.pas   кодування, відновлення символів, мінімальна зміна (без ToolsAPI)
src/ClaudeCode.EditorSync.pas перенесення змін з диска у відкриті редактори, виправлення кодування після diff
src/ClaudeCode.ComponentProps.pas DFM-текст і встановлення властивостей з JSON через RTTI (без ToolsAPI)
src/ClaudeCode.FormTools.pas  інструменти дизайнера форм
src/ClaudeCode.DebugTools.pas інструменти дебагера (стан, обчислення, точки зупину, кроки)
src/ClaudeCode.ContextMenus.pas пункти контекстних меню редактора, Project Manager і Messages
src/ClaudeCode.IdeBackend.pas  реалізація інструментів через Open Tools API
src/ClaudeCode.DiffForm.pas    вікно diff
src/ClaudeCode.Diff.pas        порядковий diff (LCS)
src/ClaudeCode.Launcher.pas    запуск CLI з потрібним оточенням
src/ClaudeCode.TerminalPanel.pas  вбудовуване (dockable) вікно IDE
src/ClaudeCode.TerminalFrame.pas  фрейм панелі: xterm.js + ConPTY, кнопки, клавіатура
src/ClaudeCode.WebViewHost.pas    легкий хост WebView2 (сторінка переживає перестиковування)
src/ClaudeCode.ConPty.pas         псевдоконсоль Windows + Job Object
src/terminal/                     сторінка терміналу та .rc для ресурсів
src/ClaudeCode.Wizard.pas      майстер IDE: меню, таймери, налаштування
tests/TestHost.dpr             консольний хост із фейковим бекендом
tests/protocol-test.mjs        тест протоколу (Node, «сирий» WebSocket)
tests/PanelHost.dpr            панель у звичайному VCL-вікні: запускає claude, вводить текст, знімає екран
third_party/                   xterm.js 6.0 (MIT), WebView2Loader 1.0.4191 (BSD, Microsoft)
```

### Тест протоколу без IDE
```bash
cd tests
dcc32 -B -NSSystem;System.Win;Winapi;Vcl -U../src -NU../dcu/test -E. TestHost.dpr
TestHost.exe 20        # друкує PORT і TOKEN
TestHost.exe build     # збирає tests/buildsample через MSBuild (успіх, потім помилка компіляції)
node protocol-test.mjs <PORT> <TOKEN>

# панель поза IDE (потрібен довірений Claude каталог як робоча тека)
dcc32 -B -NSSystem;System.Win;Winapi;Vcl;Vcl.Imaging -U../src -R../src -NU../dcu/test -E. PanelHost.dpr
PanelHost.exe C:\path\to\project C:\tmp\out   # out: panelhost.log, panelhost.dump.txt, panelhost.png
```

## Обмеження

- `getDiagnostics` повертає дані Error Insight (LSP) для відкритих файлів; справжній вивід компілятора дає `buildProject`.
- `buildProject` компілює файли з диска: незбережені зміни в редакторі повертаються в `unsavedFiles`, якщо не задано `saveModified`.
- Позиції `character` — індекси UTF-16, обчислені з буфера редактора; на всіх крайніх випадках (табуляції, дуже довгі рядки) вони не перевірені.
- Виправлення кодування бачить лише файли, записані через прийнятий diff або відкриті в редакторі; закриті файли, які Claude пише в режимі auto-accept, лишаються в кодуванні Claude.
- API дебагера не дає списку локальних змінних: Claude читає код навколо поточного рядка й обчислює потрібне. Клас і текст винятку беруться з обчислення `ExceptObject` (за можливості).
