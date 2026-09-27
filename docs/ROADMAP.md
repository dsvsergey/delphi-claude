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

## Етап 2. Синхронізація з редактором  `[ ]`

### 2.1 Accept у diff → буфер редактора
- Якщо файл відкритий у редакторі, прийняті зміни записуються через `IOTAEditWriter`
  (одна операція, скасовується Ctrl+Z), а не лише на диск. Прибирає діалог «file changed on disk».

### 2.2 Автоперечитування
- Незмінені буфери перечитуються після зміни файлу на диску (перевірка timestamp по таймеру).
- Змінені буфери → попередження в Messages, без автоперезапису.

### 2.3 Кодування файлів
- Перед Accept визначати кодування оригіналу (ANSI/cp1251, UTF-8 з/без BOM);
  якщо новий вміст не вміщається в ANSI-кодування — попередження в diff-вікні.
- Виправити позиції `character` для рядків з не-ASCII (UTF-8 байти → UTF-16 індекси).

---

## Етап 3. Дизайнер форм  `[ ]`

### 3.1 `getFormComponents`
- Дерево компонентів форми (`IOTAFormEditor`/`IOTAComponent`): ім'я, клас, батько,
  змінені (non-default) властивості, обробники подій.

### 3.2 `getSelectedComponents` + нотифікація
- Виділені в дизайнері компоненти; команда **Send Selected Components to Claude**.

### 3.3 `setComponentProperty` / `createComponent` / `deleteComponent`
- Зміни форми через дизайнер (з підтвердженням користувача, як diff), щоб не редагувати
  `.dfm`, відкритий у дизайнері.

### 3.4 `captureForm`
- Знімок форми в PNG у `%TEMP%`, шлях повертається Claude (аналіз UI за зображенням).

---

## Етап 4. Дебагер  `[ ]`

### 4.1 `getDebugState`
- Стан процесу, поточний потік, call stack (`IOTAThread.GetOTAStackFrame...`),
  поточна позиція, останній виняток (клас, повідомлення).

### 4.2 `evaluateExpression`
- `IOTAThread.Evaluate` у зупиненому процесі (з обмеженням розміру результату).

### 4.3 `setBreakpoint` / `listBreakpoints` / `removeBreakpoint`

### 4.4 Команда **Explain Exception with Claude**
- При зупинці на винятку: стек + локальні змінні + рядок коду → запит у термінал.

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
