# Roadmap: Delphi-specific features

Статус: `[ ]` не почато · `[~]` в роботі · `[x]` готово

Принцип: додавати те, чого Claude не може отримати з командного рядка — стан IDE,
компілятор з налаштуваннями проєкту, дизайнер форм, дебагер. Кожен новий MCP-інструмент
описується в `ClaudeCode.Mcp.ToolDefinitions`, реалізується в `ClaudeCode.IdeBackend`,
а логіка без ToolsAPI виноситься в окремі модулі, щоб її можна було тестувати в `tests/TestHost`.

---

## Етап 1. Збірка та проєкт  `[x]`

### 1.1 `buildProject`  `[x]`
- MSBuild у фоновому потоці (`rsvars.bat` + `msbuild <dproj> /t:Make|Build|Clean /p:Config /p:Platform`),
  процес у Job Object, таймаут, одночасно лише одна збірка.
- Розбір виводу DCC/MSBuild: `file(line,col): error E2003: ...`, `hint warning H2164`, `fatal`, `MSBxxxx`.
- Повідомлення дублюються у вікно Messages IDE (вкладка **Claude Build**), по них можна клікати.
- Аргументи: `project` (за замовчуванням активний), `target` (`make`/`build`/`clean`), `config`, `platform`,
  `saveModified`, `includeHints`, `timeoutSec`. Результат: `success`, `summary`, лічильники, `messages[]`
  (спершу помилки в порядку компілятора), `unsavedFiles`/`savedFiles`, `outputTail`, якщо помилки не розпізнано.
- Модуль: `src/ClaudeCode.Build.pas` (без ToolsAPI, тестується в TestHost).

### 1.2 `getProjectInfo`  `[x]`
- Група проєктів (усі проєкти, активний), для обраного проєкту: тип, framework (VCL/FMX),
  активні Config/Platform, платформи, конфігурації, `TargetName`, defines, search path,
  namespaces, output-каталоги, пакети, список модулів (файл, форма, клас дизайну).
- Версія IDE, каталог BDS, розрядність IDE.

### 1.3 Команда меню  `[x]`
- **Build and Fix Errors with Claude**: зберегти змінені файли, зібрати активний проєкт і, якщо є помилки,
  вставити їх у термінал Claude готовим запитом (без відправки — Enter робить користувач).

---

## Етап 2. Синхронізація з редактором  `[x]`

Модулі: `src/ClaudeCode.TextSync.pas` (без ToolsAPI, тести в TestHost), `src/ClaudeCode.EditorSync.pas`.

### 2.1 Зміни Claude → буфер редактора  `[x]`
- Claude сам записує файл після Accept (і в режимі auto-accept). Таймер (500 мс) бачить зміну файлу
  відкритої вкладки, чекає, поки запис завершиться, і переносить у буфер лише змінений фрагмент через
  `CreateUndoableWriter` (Ctrl+Z повертає попередній текст), потім IDE зберігає файл (`Module.Save`):
  діалогу «file changed on disk» немає, кодування файлу — те, з яким його відкрила IDE.

### 2.2 Незбережені зміни  `[x]`
- Вкладки з незбереженими змінами (або змінена форма модуля) не чіпаються → запис на вкладці
  **Claude Code** вікна Messages. `.dfm`/`.fmx`/`.dproj` лишаються IDE.
- Власне збереження IDE (Ctrl+S) розпізнається як «текст не змінився» і нічого не робить.
- Вимикається в Settings (`SyncEditor` = 0).

### 2.3 Кодування файлів  `[x]`
- ANSI-файли (cp1251): Claude читає їх як UTF-8 → `�`. Відновлення: цілі рядки за маскою не-ASCII
  символів, а в змінених рядках — фрагменти `�` за контекстом навколо (однозначний збіг у старому тексті).
  Працює в diff-вікні (з приміткою в заголовку) і при синхронізації буфера.
- Після Accept для закритих `.pas/.dpr/.dpk/.inc`: UTF-8 без BOM → назад в ANSI (якщо файл був ANSI і
  символи вміщаються) або UTF-8 з BOM (новий файл / символи поза кодовою сторінкою).
- Позиції `character` (виділення, openFile, діагностика) рахуються як UTF-16 індекси через байтові
  зсуви буфера (`CharPosToPos`/`PosToCharPos`).
- Не покрито: закриті файли, які Claude пише в режимі auto-accept без diff.

---

## Етап 3. Дизайнер форм  `[x]`

### 3.0 Сервер `delphi` для інструментів  `[x]`
- Виявлено: Claude Code (2.1.x) з IDE-з'єднання показує моделі лише `getDiagnostics`/`executeCode`
  (`mcp__ide__*` фільтруються), тож інструменти етапу 1 модель не бачила.
- Той самий порт тепер приймає MCP Streamable HTTP (`POST /mcp`, `Authorization: Bearer <token>`) —
  сервер `delphi` лише з Delphi-інструментами. Файл `~/.claude/ide/<port>.delphi-mcp.json` (+ `delphi-mcp.json`
  для останньої IDE) передається `claude` через `--mcp-config` з панелі та External Console.
- Перевірено справжнім Claude CLI: бачить `mcp__delphi__*` і викликає їх; дозволи — як для будь-якого MCP.

### 3.1 `getFormComponents`  `[x]`
- Живий стан дизайнера (`INTAFormEditor.GetFormResource` → DFM-текст UTF-8), список компонентів
  (ім'я, клас, батько), або DFM-блок одного компонента.

### 3.2 `getSelectedComponents` + Ctrl+Alt+K у дизайнері  `[x]`
- Виділені компоненти з DFM-блоками; **Send Selection to Claude** у дизайнері вставляє їх у панель.

### 3.3 `setComponentProperties` / `createComponent` / `deleteComponent`  `[x]`
- Через дизайнер (`IOTAFormEditor.CreateComponent`, `IOTAComponent.Delete`, RTTI + `IDesigner.Modified`).
  Властивості з JSON (`src/ClaudeCode.ComponentProps.pas`, тести в TestHost): вкладені шляхи, enum/set,
  ідентифікатори (`clRed`), посилання на компоненти, TStrings, події (`IDesigner.CreateMethod`).
  Повертаються старі/нові значення. Підтвердження — дозвіл Claude Code на MCP-інструмент; форма не зберігається сама.

### 3.4 `captureForm`  `[x]`
- `TWinControl.PaintTo` → PNG у `%TEMP%\claude-delphi`; лише VCL.

---

## Етап 4. Дебагер  `[x]`

Модуль: `src/ClaudeCode.DebugTools.pas` (інструменти сервера `delphi`).

### 4.1 `getDebugState`  `[x]`
- Стан процесу, поточний потік (файл/рядок, код навколо, стек викликів через `StartCallStackAccess`),
  усі потоки. На винятку — клас і повідомлення через обчислення `ExceptObject` (за можливості).
- Списку локальних змінних в OTA немає: Claude читає код і обчислює потрібні вирази.

### 4.2 `evaluateExpression`  `[x]`
- `IOTAThread.Evaluate`; відкладений результат (`erDeferred`) чекається через `IOTAThreadNotifier`
  + `ProcessDebugEvents` (таймаут 5 с). Побічні ефекти — лише з `allowSideEffects`.

### 4.3 `setBreakpoint` / `listBreakpoints` / `removeBreakpoint`  `[x]`
- Точки зупину в коді з умовою і лічильником проходів.

### 4.4 `debugControl`  `[x]`
- `stepOver`/`stepInto`/`runUntilReturn`/`runToCursor`/`pause` чекають наступної зупинки і повертають
  новий стан; `run` (за бажанням чекає `waitSec`, наприклад до breakpoint), `terminate`.

### 4.5 Команда **Explain Debugger Stop with Claude**  `[x]`
- Виняток + поточний рядок з кодом + стек → запит у панель (без відправки).

---

## Етап 5. Контекстні меню та швидкі дії  `[ ]`

- Локальне меню редактора: **Explain**, **Refactor**, **Write DUnitX Test**, **Add XML Doc**
  (підставляє `@file#Lx-y` + шаблон запиту; шаблони редагуються в Settings).
- Messages view (`INTAMessageNotifier.MessageViewMenuShown`): **Fix with Claude** для рядка помилки.
- Project Manager (`IOTAProjectManagerMenu`): **Add to Claude Context** (`@path`).

---

## Етап 6. Панель і diff  `[ ]`

### 6.1 Diff
- Підсвітка змін усередині рядка, режим side-by-side.
- Прийняття/відхилення окремих hunk-ів.

### 6.2 Статус сесії
- Стан Claude (працює / чекає відповіді / простій) за заголовком термінала (OSC 0/2).
- Індикатор у заголовку панелі; повідомлення, коли Claude чекає дозволу, а панель прихована.

### 6.3 Вставка зображень і drag & drop
- Ctrl+V із зображенням у буфері → PNG у `%TEMP%`, шлях у промпт.
- Перетягування файлів у термінал → шляхи.

### 6.4 Кілька сесій
- Вкладки в панелі, окрема сесія на проєкт.

---

## Етап 7. Дрібниці  `[ ]`

- **Init CLAUDE.md for Delphi**: генерація з даних `getProjectInfo` (версія, VCL/FMX,
  платформи, команда збірки, тести, правила кодування).
- Settings: модель, permission mode, додаткові аргументи CLI — окремими полями.
- `getFileHistory`: попередні версії з `__history` (`IOTAFileHistoryManager`).
- Статус-бар IDE: кількість підключених клієнтів.
