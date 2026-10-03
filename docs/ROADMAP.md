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

## Етап 5. Контекстні меню та швидкі дії  `[x]`

Модуль: `src/ClaudeCode.ContextMenus.pas`.

- Локальне меню редактора (`INTAEditorLocalMenu.RegisterActionList`, підменю **Claude Code** після Clipboard):
  **Explain**, **Refactor**, **Find Bugs**, **Write DUnitX Test**, **Add XML Documentation** — запит з
  `@file#Lx-y` вставляється і надсилається (термінал: команда `s` = paste + Enter); **Ask Claude About This...**
  лише вставляє посилання. Шаблони перевизначаються у `~/.claude/delphi-prompts.json`.
- Project Manager (`IOTAProjectMenuItemCreatorNotifier`): **Add to Claude Context** → `@file` / `@folder/`.
- Messages view (`INTAMessageNotifier.MessageViewMenuShown`): **Fix Build Errors with Claude**. Текст рядків
  Messages через OTA недоступний, тому помилки збираються повторною збіркою (як у команді з меню Tools).

---

## Етап 6. Панель і diff  `[x]`

### 6.1 Diff  `[x]`
- Підсвітка зміненої частини рядка (спільні префікс/суфікс пари видалений/доданий рядок), режим side-by-side.
- Прийняття/пропуск окремих змін (hunk-ів): Space / подвійний клік, N / P — перехід; Accept пише лише
  взяті зміни (`ApplyHunks`, тести в TestHost); жодної — це Reject. Вкладка Proposed показує, що буде записано.

### 6.2 Статус сесії  `[x]`
- Сторінка передає заголовок (спінер Claude на початку), прогрес OSC 9;4, сигнали уваги (BEL, OSC 9, OSC 777).
- Рядок стану: Working... / Waiting for you / Ready + заголовок; якщо панель прихована або IDE неактивна —
  блимання IDE на панелі задач і ` *` у заголовку панелі.

### 6.3 Вставка зображень і drag & drop  `[x]`
- Ctrl+V через хост: файли з буфера → `@`-посилання, зображення → PNG у `%TEMP%\claude-delphi` і шлях
  (Claude Code прикріплює), текст — як раніше.
- Перетягування файлів: шляхи через `postMessageWithAdditionalObjects` / `ICoreWebView2File`.

### 6.4 Кілька сесій  `[x]`
- `TClaudeSessionView` (WebView2 + ConPTY + стан) на вкладку `TPageControl`; фрейм — контейнер, його API діє на
  активну вкладку. Open Claude Code → `ViewFor(тека проєкту)`: наявна вкладка, невикористана активна або нова.
  `+` / `x` / середній клік; позначки `●` / `!` на вкладках; Send Selection вставляє посилання лише в активну
  вкладку (`at_mentioned` пішов би в усі сесії). Перевірено `tests/PanelHost` (вкладки, ViewFor).

---

## Етап 7. Дрібниці  `[x]`

- **Create CLAUDE.md for Project...** (`src/ClaudeCode.ClaudeMd.pas`): розділ між `<!-- delphi:begin/end -->` —
  тип, framework, платформи/конфігурації, вихідний файл, defines/шляхи, група проєктів, команда збірки
  (`rsvars.bat` + msbuild), DUnitX-проєкти, переважне кодування юнітів, форми, підказки щодо `mcp__delphi__*`.
  Решта `CLAUDE.md` не чіпається; зміна переглядається у diff-вікні.
- **Settings** (`src/ClaudeCode.SettingsForm.pas`): команди панелі/консолі, `--model`, `--permission-mode`,
  інші аргументи, Delphi-інструменти (`--mcp-config`) так/ні, синхронізація редактора, надсилати запити з
  контекстного меню одразу.
- **`getFileHistory`** (`src/ClaudeCode.FileHistory.pas`, тест у protocol-test): версії з `__history`, текст версії.
- **Індикатор** у рядку стану вікон редактора: `Claude: off / connected (N) / working / waiting for you`;
  прибирається при вивантаженні пакета.

---

## Етап 8. «ВАУ»-функції  `[x]`

Порядок реалізації враховує залежності: спершу спільна інфраструктура та індекс Pascal-коду
(його використовують тести, карта проєкту й модернізація), найризикованіший UI (diff у редакторі) — останнім.

### 8.0 Інфраструктура  `[x]`
- `ClaudeCode.Process.pas`: запуск процесу з перехопленням виводу, таймаутом і Job Object (виноситься з
  `Build.pas`); фонова задача з відповіддю в головному потоці (`TJobRunner`).
- MCP **prompts** сервера `delphi`: готові сценарії стають slash-командами Claude Code
  (`/mcp__delphi__make-tests-pass`, `/mcp__delphi__screenshot-to-form`, `/mcp__delphi__hunt-bug`,
  `/mcp__delphi__crud-form`, `/mcp__delphi__modernize`).

### 8.1 «Скриншот → форма»: `pasteDfm`  `[x]`
- Claude пише DFM-текст (один чи кілька блоків `object ... end`), інструмент вставляє його в дизайнер
  через `IDesigner.PasteSelection` у вибраний батьківський контрол — як Ctrl+V DFM-тексту в дизайнері:
  колекції, вкладені компоненти, події, бінарні властивості. Буфер обміну користувача зберігається й
  відновлюється. Повертає фактичні імена (дизайнер перейменовує при конфлікті) і DFM результату.
- Цикл: картинка → `pasteDfm` → `captureForm` → порівняння → `setComponentProperties`.

### 8.2 Logpoints і автономне налагодження  `[x]`
- `setLogpoint(file, line, expressions[], condition, maxHits, stackFrames)`: звичайна точка зупину; коли
  програма стала на її рядку (і IDE завершила обробку зупинки), таймер обчислює вирази, записує спрацювання й
  запускає програму далі. Після `maxHits` logpoint вимикається.
- `getLogpointHits` (журнал: час, потік, значення, рядок), `removeLogpoint`.
- `debugControl` отримує `start` — дія Run IDE (F9), щоб Claude сам запускав програму.

### 8.3 Цикл TDD з DUnitX: `runTests`  `[x]`
- Збирає тестовий проєкт (автовизначення DUnitX-проєкту в групі), запускає exe з
  `--xmlfile --exitbehavior:Continue`, розбирає NUnit XML (fallback — консольний вивід), знаходить
  файл/рядок тесту через індекс (8.4). Результат — у вкладці **Claude Tests** вікна Messages.
- Команда **Make Tests Pass with Claude**: запуск тестів → запит у панель з упалими тестами та
  інструкцією «виправляй і запускай `runTests`, доки все не стане зеленим».
- Модуль `src/ClaudeCode.TestRunner.pas` (без ToolsAPI, тести в TestHost).

### 8.4 Навігація по коду: індекс Pascal  `[x]`
- `src/ClaudeCode.PascalIndex.pas` (без ToolsAPI): токенайзер (коментарі, рядки, директиви),
  оголошення (типи, класи, методи, властивості, поля, константи), посилання без коментарів/рядків,
  `uses`-клаузи, структура юніта.
- Інструменти: `getUnitOutline` (структура юніта з номерами рядків — економить токени),
  `findSymbol` (оголошення), `findReferences` (у .pas/.dpr/.inc і обробники/імена в .dfm/.fmx),
  `renameSymbol` (dryRun за замовчуванням; застосування — через буфери редактора з Undo для відкритих файлів).

### 8.5 Claude бачить і керує запущеною програмою  `[x]`
- `src/ClaudeCode.AppAutomation.pas` (без ToolsAPI): вікна процесу (налагоджуваного за замовчуванням),
  `PrintWindow` → PNG, дерево UI Automation (VCL і FMX), дії: click / doubleClick / setText /
  sendKeys / focus — через патерни UIA, інакше вводом миші/клавіатури.
- Інструменти `captureApp`, `getAppUI`, `appAction`. Фоновий потік і таймаути UIA, щоб IDE не зависала;
  відмова, якщо процес зупинено в налагоджувачі.

### 8.6 Зміни Claude прямо в редакторі коду  `[x]`
- Налаштування «Show proposed changes: Diff window / In the editor».
- Режим редактора: запропонований текст вставляється в буфер як одна undoable-правка, нові/змінені рядки
  підсвічуються (`INTACodeEditorEvents.PaintLine`), місця видалення — червоною позначкою; панель
  над редактором: кількість змін, ◀ ▶, «Revert change», «Accept all» (Ctrl+Alt+Enter),
  «Reject all» (Ctrl+Alt+Backspace). Підсвічування — це завжди diff(оригінал, поточний буфер),
  тож правки користувача під час перегляду враховуються. Accept зберігає файл; Reject повертає оригінал.
- Модуль `src/ClaudeCode.InlineDiff.pas`.

### 8.7 Таймлайн сесії і відкат ходу  `[x]`
- Хуки Claude Code (`--settings` з `UserPromptSubmit`, `PreToolUse` для Edit/Write/MultiEdit, `Stop`)
  надсилають події на `POST /hook` того самого сервера (той самий токен).
- `src/ClaudeCode.Timeline.pas` (без ToolsAPI): ходи (запит, час, файли до/після, +/- рядки).
- Вікно **Claude Timeline**: список ходів, файли ходу, перегляд diff, **Rewind to before this turn**
  (відновлює точні байти файлів; відкриті вкладки — через буфер з Undo).

### 8.8 Інтерактивна карта проєкту  `[x]`
- `src/ClaudeCode.ProjectMap.pas` (без ToolsAPI): граф `uses` (interface/implementation), розміри,
  fan-in/fan-out, цикли (Tarjan SCC), форми й дата-модулі.
- Вікно з WebView2: силова розкладка графа, пошук, підсвічування циклів, клік — відкрити юніт,
  «Ask Claude» — запит про юніт у панель. Інструмент `getUnitDependencies` для Claude.

### 8.9 Інструменти бази даних (FireDAC)  `[x]`
- `listConnections` (TFDConnection на формах/дата-модулях проєкту, без паролів),
  `getDatabaseSchema` (таблиці, колонки, ключі через `TFDMetaInfoQuery`),
  `runQuery` (лише читання: SELECT/WITH, транзакція з відкатом, ліміт рядків).
- Власне тимчасове з'єднання з параметрами дизайнерського — компонент на формі не чіпається.

### 8.10 Майстер модернізації  `[x]`
- `analyzeModernization(scenario)`: `win64`, `unicode`, `bde` (BDE/dbExpress → FireDAC), `warnings`
  (збірка й групування попереджень за кодом), з місцями в коді.
- `getMemoryLeaks`: розбір звіту FastMM4/5 (`*_MemoryManager_EventLog.txt`), групування за класом.
- Команда **Modernize Project with Claude...**: вибір сценарію → аналіз → запит у панель з планом
  поетапних виправлень, збіркою і тестами після кожного кроку.

### 8.11 Документація і перевірка  `[x]`
- README (en/uk), тести в TestHost для модулів без ToolsAPI, protocol-test для нових інструментів,
  наскрізна перевірка в окремому екземплярі IDE (`bds -r<профіль>`).

### Що з'ясувалося під час етапу 8
- **Інструменти виконуються з циклу повідомлень, а не з `TThread.Queue`.** `CheckSynchronize` не реентерабельний, а
  дебагер і дизайнер IDE самі покладаються на чергу головного потоку: Run (F9), обчислення на свіжій зупинці та перша
  вставка в щойно відкритий дизайнер ламалися всередині `CheckSynchronize`. `RunInMainLoop` (`ClaudeCode.Utils`)
  передає роботу через приховане вікно, як дію користувача; так само повертаються результати збірки й фонових задач.
- **`IOTADebuggerServices.CreateProcess` падає** (AV у dbkdebugide) — програма запускається дією Run IDE.
  Програма, зібрана лише MSBuild, запускається, але на першій зупинці ядро дебагера робить assert — Run компілює сам.
- **Заголовки кадрів стеку (`IOTAThread.CallHeaders`) викликають assert «item.src»** ядра дебагера Delphi 13 —
  кадри називаються з коду через `PascalIndex` (метод навколо рядка); `GetCallPos` працює.
- **Під час запуску програми не можна питати потоки й стек**: поки ядро вантажить процес, він виглядає зупиненим, і
  запити ламають ядро («Invalid debugger request») — очікування починаються після першого стану «running».
- **Breakpoint-нотифікатор (`Trigger` + `DefaultTrigger`) для logpoints не використовується**: обчислення з нього
  ламає ядро; logpoint — звичайна точка зупину, обробка — таймером після стабільної зупинки.
- **`IDesigner.PasteSelection` дає AV** — вставка через `IEditHandler.EditAction(eaPaste)` (шлях Edit > Paste) на
  формі, показаній ще раз після завантаження (`Module.Show`/`Editor.Show` перед кожною спробою).
- **`get_CurrentBoundingRectangle` у `Winapi.UIAutomation` оголошено з `TRectF` (single)**, а UIA повертає double —
  межі читаються як VARIANT-властивість. VCL-канва не потокобезпечна: знімок вікна — чистим GDI у фоні, PNG — у головному потоці.
- **Diff із пріоритетом префікса/суфікса неоднозначно ставить вставки** («end; … Result» замість цілої процедури) —
  `SlideRuns` у `ClaudeCode.Diff` зсуває чисті вставки/видалення вниз, як git; користь і для вікна diff.
- **`EditorSync` нормалізував диск до CRLF** і перетворював LF-файли при кожному збереженні IDE — тепер порівнює в
  стилі рядків буфера.
- **Хуки Claude Code на Windows**: команда `curl … || exit 0` однаково працює в cmd і bash; відповідь без тіла
  (вивід `UserPromptSubmit`-хука потрапив би в контекст Claude). Перевірено справжнім `claude -p`.
