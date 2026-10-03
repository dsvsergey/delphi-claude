// End-to-end test of the Delphi tools in a running IDE that has tests/e2e (a copy) open.
//   node e2e-test.mjs <port> <token> <e2e folder> <IDE process id> [section,...]
// The IDE process id is used to drive the IDE's own windows (review bar, timeline) through
// UI Automation, with the same appAction tool Claude uses. Sections: code, tests, forms, debug,
// app, project, db, modernize, inline, timeline, prompts.
import net from 'node:net';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const [port, token, dir, idePid, only] = process.argv.slice(2);
const sections = only ? only.split(',') : null;
let failures = 0, passes = 0;
const check = (cond, msg, detail = '') => {
  if (cond) { passes++; console.log(`PASS ${msg}`); }
  else { failures++; console.log(`FAIL ${msg}${detail ? '\n     ' + String(detail).slice(0, 600).replace(/\n/g, '\n     ') : ''}`); }
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const file = n => path.join(dir, n);
const fwd = p => p.replace(/\\/g, '/');

// delphi server (HTTP)
async function rpc(method, params) {
  const res = await fetch(`http://127.0.0.1:${port}/mcp`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}
async function call(name, args = {}) {
  const j = await rpc('tools/call', { name, arguments: args });
  if (j.error) return { isError: true, text: j.error.message };
  return { isError: j.result.isError, text: j.result.content.map(c => c.text).join('\n') };
}
const json = r => { try { return JSON.parse(r.text); } catch { return null; } };

// IDE channel (WebSocket), for openDiff, openFile, close_tab
function ideCall(name, args = {}, timeoutMs = 120000) {
  // A timeout resolves with a marker instead of rejecting: a pending openDiff must not crash the run.
  return new Promise((resolve) => {
    const reject = e => resolve(['ERROR ' + e.message]);
    const sock = net.connect(+port, '127.0.0.1');
    const key = crypto.randomBytes(16).toString('base64');
    let buf = Buffer.alloc(0), up = false;
    const t = setTimeout(() => { sock.destroy(); reject(new Error('timeout: ' + name)); }, timeoutMs);
    const send = o => {
      const p = Buffer.from(JSON.stringify(o)), m = crypto.randomBytes(4), n = p.length;
      const h = n < 126 ? Buffer.from([0x81, 0x80 | n]) : n < 65536 ? Buffer.from([0x81, 0xfe, n >> 8, n & 255])
        : (() => { const x = Buffer.alloc(10); x[0] = 0x81; x[1] = 0xff; x.writeBigUInt64BE(BigInt(n), 2); return x; })();
      for (let i = 0; i < n; i++) p[i] ^= m[i & 3];
      sock.write(Buffer.concat([h, m, p]));
    };
    sock.on('error', reject);
    sock.on('connect', () => sock.write(`GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
      `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\nx-claude-code-ide-authorization: ${token}\r\n\r\n`));
    sock.on('data', d => {
      buf = Buffer.concat([buf, d]);
      if (!up) {
        const i = buf.indexOf('\r\n\r\n'); if (i < 0) return;
        buf = buf.subarray(i + 4); up = true;
        send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'e2e', version: '1' } } });
        send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name, arguments: args } });
      }
      while (buf.length >= 2) {
        let len = buf[1] & 0x7f, off = 2;
        if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
        else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
        if (buf.length < off + len) return;
        const msg = JSON.parse(buf.subarray(off, off + len).toString()); buf = buf.subarray(off + len);
        if (msg.id === 2) { clearTimeout(t); sock.destroy(); resolve(msg.result.content.map(c => c.text)); }
      }
    });
  });
}

// The IDE's own UI through UI Automation (what appAction sees).
async function ideUi(window, depth = 16) {
  return (await call('getAppUI', { processId: +idePid, window, depth, maxNodes: 4000 })).text;
}
function findEl(tree, re) {
  for (const line of tree.split('\n')) {
    if (!re.test(line)) continue;
    const m = line.match(/\[([\d.]+)\].*\((-?\d+),(-?\d+) (\d+)x(\d+)\)\s*$/);
    if (m) return { id: m[1], x: +m[2], y: +m[3], w: +m[4], h: +m[5], line };
  }
  return null;
}
async function clickIde(window, re, how = 'invoke') {
  const el = findEl(await ideUi(window), re);
  if (!el) return { isError: true, text: 'not found: ' + re };
  // Buttons that open a modal dialog are clicked with posted mouse messages (Invoke would wait for the dialog).
  return how === 'point'
    ? call('appAction', { processId: +idePid, window, action: 'click', x: el.x + (el.w >> 1), y: el.y + (el.h >> 1) })
    : call('appAction', { processId: +idePid, window, action: 'click', element: el.id });
}
async function ideWindows() {
  return (json(await call('captureApp', { processId: +idePid })) || { windows: [] }).windows;
}
async function waitFor(fn, ms = 20000, step = 500) {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(step)) { const v = await fn(); if (v) return v; }
  return null;
}
async function debugState() { return json(await call('getDebugState', { maxFrames: 6, contextLines: 0 })) || {}; }
async function ensureNoProcess() {
  const s = await debugState();
  if (s.state && s.state !== 'noProcess' && s.state !== 'terminated') {
    await call('debugControl', { action: 'terminate' });
    await waitFor(async () => ['noProcess', 'terminated'].includes((await debugState()).state), 20000);
  }
}
const want = s => !sections || sections.includes(s);

// ---------------------------------------------------------------------------------------------
if (want('code')) {
  console.log('--- code navigation');
  let r = await call('getUnitOutline', { unit: 'OrderLogic' });
  check(!r.isError && /type TOrder = class\s+\[\d+-\d+\]/.test(r.text) && /function TOrder\.CalcTotal: Currency;\s+\[58-65\]/.test(r.text),
    'getUnitOutline: classes and method bodies with line ranges', r.text);
  r = await call('getUnitOutline', { unit: 'OrderLogic', members: false });
  check(!r.text.includes('FLines'), 'getUnitOutline members=false hides fields');
  r = await call('getUnitOutline', { unit: 'NoSuchUnit' });
  check(r.isError, 'getUnitOutline: unknown unit is an error');
  r = await call('findSymbol', { name: 'TOrder.CalcTotal' });
  check(/^method TOrder\.CalcTotal\s+OrderLogic\.pas:26/m.test(r.text) && /^methodImpl TOrder\.CalcTotal\s+OrderLogic\.pas:58-65/m.test(r.text),
    'findSymbol: declaration and body', r.text);
  r = await call('findSymbol', { name: 'TOrder', kind: 'class' });
  check(/class TOrder/.test(r.text) && !/methodImpl/.test(r.text), 'findSymbol: kind filter');
  r = await call('findSymbol', { name: 'kNone' });
  check(r.text.startsWith('No declaration'), 'findSymbol: nothing found');
  r = await call('findReferences', { name: 'ButtonAddClick' });
  check(/3 occurrence/.test(r.text) && /MainForm\.dfm \(1\)/.test(r.text), 'findReferences: code and form', r.text);
  r = await call('findReferences', { name: 'CalcTotal', files: ['OrderTests'] });
  check(/2 occurrence\(s\) of CalcTotal in 1 file/.test(r.text), 'findReferences: files filter', r.text);
  r = await call('renameSymbol', { name: 'CalcTotal', newName: 'begin' });
  check(r.isError, 'renameSymbol: a reserved word is refused');
  r = await call('renameSymbol', { name: 'CalcTotal', newName: 'Total' });
  const ids = [...r.text.matchAll(/^\s+(\S+:\d+:\d+)\s/gm)].map(m => m[1]);
  check(ids.length === 5 && /Dry run/.test(r.text), 'renameSymbol: dry run lists 5 ids', r.text);
  // Rename with the unit open in the editor: changed in the buffer (undoable) and saved.
  await ideCall('openFile', { filePath: file('OrderLogic.pas'), makeFrontmost: false });
  r = await call('renameSymbol', { name: 'CalcTotal', newName: 'Total', dryRun: false });
  check(/OrderLogic\.pas: 3 change\(s\), changed in the editor and saved/.test(r.text) && /OrderTests\.pas: 2 change\(s\), written/.test(r.text),
    'renameSymbol: open file through the editor, closed file on disk', r.text);
  check(fs.readFileSync(file('OrderLogic.pas'), 'utf8').includes('function TOrder.Total: Currency;'), 'renameSymbol: saved to disk');
  r = await call('buildProject', { project: 'OrdersTests' });
  check(json(r)?.success === true, 'project still builds after the rename', r.text);
  r = await call('renameSymbol', { name: 'Total', newName: 'CalcTotal', dryRun: false, only: ids.map(i => i) });
  // "only" ids of the old name do not match the new positions exactly in OrderLogic (same lines/cols): they do.
  r = await call('findReferences', { name: 'CalcTotal' });
  check(/5 occurrence/.test(r.text), 'renameSymbol back with "only"', r.text);
  const dirty = await ideCall('checkDocumentDirty', { filePath: file('OrderLogic.pas') });
  check(JSON.parse(dirty[0]).isDirty === false, 'the editor buffer is saved after renaming');
}

if (want('tests')) {
  console.log('--- tests');
  let r = json(await call('runTests', {}));
  check(r && r.failed === 1 && r.passed === 2 && r.failures[0].test === 'OrderTests.TOrderTests.TotalAddsAllLines' &&
    /OrderTests\.pas$/.test(r.failures[0].file) && r.failures[0].line > 0, 'runTests: the failing test with its location', JSON.stringify(r));
  r = json(await call('runTests', { filter: 'OrderTests.TOrderTests.LineCountCountsLines' }));
  check(r && r.success && r.passed === 1, 'runTests: filter');
  r = await call('runTests', { project: 'NoSuchProject' });
  check(r.isError, 'runTests: unknown project');
}

if (want('forms')) {
  console.log('--- form designer');
  let r = await call('pasteDfm', { form: 'FormMain', dfm: "object X: TButton\r\n  Caption = 'unterminated\r\nend" });
  check(r.isError && /not valid/.test(r.text), 'pasteDfm: syntax error reported', r.text);
  r = await call('pasteDfm', { form: 'FormMain', dfm:
    "object PanelTools: TPanel\r\n  Left = 16\r\n  Top = 250\r\n  Width = 386\r\n  Height = 40\r\n  object EditFind: TEdit\r\n    Left = 8\r\n    Top = 8\r\n    Width = 200\r\n    Height = 23\r\n  end\r\n  object ButtonAdd: TButton\r\n    Left = 216\r\n    Top = 7\r\n    Caption = 'Find'\r\n  end\r\nend" });
  const j = json(r);
  check(j && j.created.length === 3 && j.created.some(c => c.name === 'EditFind' && c.parent === 'PanelTools') &&
    !j.created.some(c => c.name === 'ButtonAdd'), 'pasteDfm: nested controls, the duplicate name renamed', r.text);
  r = json(await call('getFormComponents', { form: 'FormMain', includeDfm: false }));
  check(r && r.components.some(c => c.name === 'PanelTools'), 'getFormComponents sees the pasted panel');
  r = json(await call('captureForm', { form: 'FormMain' }));
  check(r && fs.existsSync(r.file) && fs.statSync(r.file).size > 1000, 'captureForm writes a PNG');
  r = await call('deleteComponent', { form: 'FormMain', component: 'PanelTools' });
  check(!r.isError, 'deleteComponent removes the panel (and its children)');
  r = json(await call('getFormComponents', { form: 'FormMain', includeDfm: false }));
  check(r && !r.components.some(c => c.name === 'EditFind'), 'children are gone too');
}

if (want('debug')) {
  console.log('--- debugger and logpoints');
  await ensureNoProcess();
  await call('removeLogpoint', {});
  let r = await call('setLogpoint', { file: fwd(file('OrderLogic.pas')), line: 64, expressions: ['I', 'Result', 'FLines.FCount'] });
  check(!r.isError, 'setLogpoint in the loop', r.text);
  r = await call('setLogpoint', { file: fwd(file('OrderLogic.pas')), line: 69, expressions: ['FLines.FCount'], stackFrames: 3 });
  check(!r.isError, 'setLogpoint with call stacks');
  r = await call('setLogpoint', { file: fwd(file('OrderLogic.pas')), line: 64, expressions: [] });
  check(r.isError, 'setLogpoint without expressions is refused');
  r = json(await call('debugControl', { action: 'start', project: 'OrdersTests', waitSec: 60 }));
  check(r && r.note === 'The process ended', 'start runs the tests to the end (logpoint stops do not end the wait)', JSON.stringify(r));
  r = await call('getLogpointHits', {});
  check(/logpoint \d+ at OrderLogic\.pas:64 - 1 hit/.test(r.text) && /\b0 \| 0 \| 2\b/.test(r.text),
    'getLogpointHits: one loop iteration over two lines (the bug)', r.text);
  check(/OrderLogic\.pas:69 - 1 hit/.test(r.text) && /TOrderTests\.LineCountCountsLines \(OrderTests\.pas:\d+\)/.test(r.text),
    'getLogpointHits: call stack named from the source', r.text);
  r = await call('listBreakpoints', {});
  check((json(r)?.breakpoints || []).filter(b => b.logpoint).length === 2, 'listBreakpoints marks logpoints');
  await call('removeLogpoint', {});
  r = await call('setBreakpoint', { file: fwd(file('OrderLogic.pas')), line: 64 });
  r = json(await call('debugControl', { action: 'start', project: 'OrdersTests', waitSec: 60 }));
  const frames = r?.currentThread?.callStack || [];
  check(r?.state === 'stopped' && r.currentThread.line === 64 && frames.some(f => f.call === 'TOrderTests.TotalAddsAllLines'),
    'breakpoint stop with a call stack (no debugger assertion)', JSON.stringify(r).slice(0, 500));
  r = json(await call('evaluateExpression', { expression: 'FLines.FCount' }));
  check(r?.value === '2', 'evaluateExpression at the stop');
  r = json(await call('debugControl', { action: 'stepOver', waitSec: 10 }));
  check(r?.state === 'stopped', 'stepOver');
  r = await call('debugControl', { action: 'terminate' });
  check(!r.isError, 'terminate');
  await call('removeBreakpoint', { file: fwd(file('OrderLogic.pas')), line: 64 });
  await waitFor(async () => ['noProcess', 'terminated'].includes((await debugState()).state));
  const wins = await ideWindows();
  check(!wins.some(w => w.title === 'Error'), 'no debugger error dialog in the IDE', JSON.stringify(wins.map(w => w.title)));
}

if (want('app')) {
  console.log('--- running program');
  await ensureNoProcess();
  let r = await call('getAppUI', {});
  check(r.isError && /No program is being debugged/.test(r.text), 'getAppUI without a program');
  await call('setLogpoint', { file: fwd(file('OrderLogic.pas')), line: 64, expressions: ['I', 'FLines.FCount'] });
  r = json(await call('debugControl', { action: 'start', project: 'OrdersApp' }));
  check(r?.state === 'running', 'start the VCL program', JSON.stringify(r));
  await sleep(1500);
  const tree = (await call('getAppUI', {})).text;
  const edit = findEl(tree, /\] Edit /), add = findEl(tree, /Button "Add"/), list = findEl(tree, /\] List /);
  check(edit && add && list, 'getAppUI: edit, button and list with positions', tree);
  r = await call('appAction', { action: 'setText', element: edit.id, text: 'Tea' });
  check(/Set the text/.test(r.text), 'setText', r.text);
  r = await call('appAction', { action: 'click', element: add.id, expectName: 'Add' });
  check(/Invoked Button "Add"/.test(r.text), 'click (invoke)');
  r = await call('appAction', { action: 'click', element: add.id, expectName: 'Remove' });
  check(r.isError && /UI changed/.test(r.text), 'expectName detects a different element');
  r = await call('appAction', { action: 'setText', element: edit.id, text: 'Cake' });
  r = await call('appAction', { action: 'click', x: add.x + 10, y: add.y + 10 });
  check(/Clicked point/.test(r.text), 'click at x/y (posted mouse messages)');
  r = await call('appAction', { action: 'setText', element: edit.id, text: 'Tea2' });
  r = await call('appAction', { action: 'sendKeys', element: edit.id, text: '{END}xz{BACKSPACE}y' });
  const typed = (await call('getAppUI', { depth: 1 })).text;
  check(!r.isError && /value="Tea2xy"/.test(typed),
    'sendKeys with special keys (one Backspace deletes one character)', r.text + '\n' + (typed.match(/Edit [^\n]*/) || [typed])[0]);
  await sleep(500);
  const tree2 = (await call('getAppUI', {})).text;
  check(/ListItem "Tea"/.test(tree2) && /ListItem "Cake"/.test(tree2), 'the list shows both lines', tree2);
  r = json(await call('captureApp', {}));
  check(r && r.windows.length >= 1 && fs.statSync(r.windows[0].file).size > 2000, 'captureApp: PNG of the window');
  r = await call('getLogpointHits', {});
  check(/1 hit/.test(r.text), 'the logpoint saw the second click', r.text);
  await call('debugControl', { action: 'pause', waitSec: 10 });
  r = await call('getAppUI', {});
  check(r.isError && /stopped in the debugger/.test(r.text), 'refuses while the program is stopped');
  await call('debugControl', { action: 'terminate' });
  await call('removeLogpoint', {});
  await waitFor(async () => ['noProcess', 'terminated'].includes((await debugState()).state));
}

if (want('project')) {
  console.log('--- project map');
  let r = await call('getUnitDependencies', {});
  check(/6 units, \d+ lines, 0 cycle/.test(r.text) && /OrderLogic\s+4/.test(r.text), 'getUnitDependencies summary', r.text);
  r = await call('getUnitDependencies', { unit: 'MainForm' });
  check(/Uses in interface: OrderLogic/.test(r.text) && /Used by: OrdersApp/.test(r.text), 'getUnitDependencies of a unit', r.text);
  r = await call('showProjectMap', {});
  // WebView2 draws the page a moment after the window opens.
  const w = await waitFor(async () => {
    const x = (await ideWindows()).find(x => x.title.startsWith('Project Map'));
    return x && fs.statSync(x.file).size > 12000 ? x : null;
  });
  check(w, 'the map window is drawn', JSON.stringify(w));
  r = await call('getProjectInfo', {});
  check(json(r)?.project?.name, 'getProjectInfo still works');
  // Close the map: its WebView2 page makes UI Automation walks of the IDE slow.
  const mapClose = findEl(await ideUi('Project Map', 3), /Button "(Close|Закрыть|Закрити)"/);
  if (mapClose) await call('appAction', { processId: +idePid, window: 'Project Map', action: 'click', element: mapClose.id });
}

if (want('db')) {
  console.log('--- database');
  let r = json(await call('listConnections', {}));
  check(r?.connections?.[0]?.connection === 'DataOrders.Connection', 'listConnections');
  r = await call('getDatabaseSchema', {});
  check(/4 table/.test(r.text) && /id INTEGER PK/.test(r.text) && /customer_id -> customers\(id\)/.test(r.text), 'schema with keys', r.text);
  r = await call('runQuery', { sql: 'select name from customers order by id', maxRows: 2 });
  check(/\| Walk-in \|/.test(r.text) && /2 row\(s\) shown; more rows exist/.test(r.text), 'runQuery with maxRows', r.text);
  r = await call('runQuery', { sql: "select count(*) as n from orders where status = 'paid' -- delete" });
  check(/\| 1 \|/.test(r.text), 'keywords in strings and comments are fine', r.text);
  for (const sql of ['update orders set status = 1', 'select 1; delete from orders', 'with x as (select 1) delete from orders'])
    check((await call('runQuery', { sql })).isError, 'refused: ' + sql);
  r = await call('runQuery', { sql: 'select * from no_such_table' });
  check(r.isError && /no_such_table/.test(r.text), 'SQL errors are reported', r.text);
  r = await call('getDatabaseSchema', { connection: 'Nope' });
  check(r.isError, 'unknown connection');
  r = await call('getDatabaseSchema', { params: ['DriverID=SQLite', 'Database=' + file('orders.db')], table: 'products' });
  check(/products: id INTEGER PK, title TEXT not null/.test(r.text), 'explicit parameters', r.text);
}

if (want('modernize')) {
  console.log('--- modernization');
  let r = await call('analyzeModernization', { scenario: 'win64' });
  check(/No win64 findings/.test(r.text), 'the sample is clean for win64', r.text);
  r = await call('analyzeModernization', { scenario: 'cobol' });
  check(r.isError, 'unknown scenario');
  r = await call('analyzeModernization', { scenario: 'warnings', project: 'OrdersApp' });
  check(/succeeded/.test(r.text) && /No warnings/.test(r.text), 'warnings scenario builds', r.text);
  const log = path.join(os.tmpdir(), 'e2e_MemoryManager_EventLog.txt');
  fs.writeFileSync(log, 'A memory block has been leaked. The size is: 20\r\n\r\nThis block was allocated by thread 0x1, and the stack trace (return addresses) at the time was:\r\n4C1234 [OrderLogic.pas][OrderLogic][TOrder.Create][38]\r\n\r\nThe block is currently used for an object of class: TOrder\r\n');
  r = await call('getMemoryLeaks', { file: log });
  check(/TOrder x 1 \(20 bytes\)/.test(r.text) && /TOrder\.Create/.test(r.text), 'getMemoryLeaks reads a FastMM log', r.text);
  r = await call('getMemoryLeaks', { project: 'OrdersApp' });
  check(/No FastMM leak log/.test(r.text), 'getMemoryLeaks explains how to get a log');
}

if (want('inline')) {
  console.log('--- review in the editor');
  const orig = fs.readFileSync(file('OrderLogic.pas'));
  const proposal = orig.toString().replace('FLines.Count - 2', 'FLines.Count - 1')
    .replace('function TOrder.LineCount: Integer;', 'function TOrder.IsEmpty: Boolean;\nbegin\n  Result := FLines.Count = 0;\nend;\n\nfunction TOrder.LineCount: Integer;');
  const args = { old_file_path: file('OrderLogic.pas'), new_file_path: file('OrderLogic.pas'), new_file_contents: proposal, tab_name: 'e2e-inline' };
  // Reject through close_tab: the file is back byte for byte.
  let pending = ideCall('openDiff', args, 60000);
  let bar = await waitFor(async () => findEl(await ideUi('Delphi 13'), /Button "Accept all"/));
  check(bar, 'the review bar appears in the editor');
  const info = await ideUi('Delphi 13');
  check(/Claude proposes 2 change/.test(info) || bar, 'the bar describes the changes');
  let res = await ideCall('close_tab', { tab_name: 'e2e-inline' });
  check(res[0] === 'TAB_CLOSED', 'close_tab ends the review');
  res = await pending;
  check(res[0] === 'DIFF_REJECTED', 'openDiff answers DIFF_REJECTED');
  check(Buffer.compare(fs.readFileSync(file('OrderLogic.pas')), orig) === 0, 'rejected: the file is unchanged byte for byte');
  // Undo one change, accept the rest from the bar.
  pending = ideCall('openDiff', args, 60000);
  await waitFor(async () => findEl(await ideUi('Delphi 13'), /Button "Accept all"/));
  await clickIde('Delphi 13', /Button "Undo this change"/);
  await sleep(500);
  await clickIde('Delphi 13', /Button "Accept all"/);
  res = await pending;
  const saved = fs.readFileSync(file('OrderLogic.pas'), 'utf8');
  check(res[0] === 'FILE_SAVED' && res[1].includes('IsEmpty') && !res[1].includes('Count - 1'),
    'accepted after undoing the first change: only the new method', res.join('\n').slice(0, 300));
  check(saved.includes('IsEmpty') && saved.includes('Count - 2') && !saved.includes('\r\n'), 'saved, LF line breaks kept');
  fs.writeFileSync(file('OrderLogic.pas'), orig);
  await sleep(1500); // the editor follows the file on disk
  // Forms and files that do not exist yet go to the diff window.
  pending = ideCall('openDiff', { old_file_path: file('NewUnit.pas'), new_file_path: file('NewUnit.pas'), new_file_contents: 'unit NewUnit;\ninterface\nimplementation\nend.\n', tab_name: 'e2e-new' }, 60000);
  const dw = await waitFor(async () => (await ideWindows()).find(w => w.class === 'TClaudeDiffForm'));
  check(dw, 'a new file opens the diff window', JSON.stringify((await ideWindows()).map(w => w.class)));
  await ideCall('close_tab', { tab_name: 'e2e-new' });
  res = await pending;
  check(res[0] === 'DIFF_REJECTED' && !fs.existsSync(file('NewUnit.pas')), 'diff window rejected');
}

if (want('timeline')) {
  console.log('--- timeline');
  const hook = body => fetch(`http://127.0.0.1:${port}/hook`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify(body) });
  const notes = file('NOTES.md'), tests = file('OrderTests.pas');
  const testsOrig = fs.readFileSync(tests);
  if (fs.existsSync(notes)) fs.unlinkSync(notes);
  const sid = 'e2e-' + Date.now();
  let h = await hook({ session_id: sid, cwd: dir, hook_event_name: 'UserPromptSubmit', prompt: 'e2e: change tests and add notes' });
  check(h.status === 202 && (await h.text()) === '', '/hook answers 202 without a body');
  await hook({ session_id: sid, cwd: dir, hook_event_name: 'PreToolUse', tool_name: 'Edit', tool_input: { file_path: tests } });
  fs.writeFileSync(tests, testsOrig.toString() + '\n// e2e change\n');
  await hook({ session_id: sid, cwd: dir, hook_event_name: 'PreToolUse', tool_name: 'Write', tool_input: { file_path: 'NOTES.md' } });
  fs.writeFileSync(notes, 'notes\n');
  await hook({ session_id: sid, cwd: dir, hook_event_name: 'Stop' });
  let r = await call('showTimeline', {});
  check(/1 turn|\d+ turn/.test(r.text), 'showTimeline', r.text);
  const ui = await waitFor(async () => { const t = await ideUi('Claude Timeline'); return /e2e: change tests/.test(t) ? t : null; });
  check(ui, 'the turn is listed with its request', ui);
  // Select the turn, rewind, confirm, close the report.
  const row = findEl(ui, /ListItem "e2e: change tests/);
  await call('appAction', { processId: +idePid, window: 'Claude Timeline', action: 'click', x: row.x + 20, y: row.y + (row.h >> 1) });
  await sleep(500);
  const files = await ideUi('Claude Timeline');
  check(/OrderTests\.pas/.test(files) && /NOTES\.md/.test(files), 'the files of the turn', files);
  await clickIde('Claude Timeline', /Button "Rewind/, 'point');
  const confirm = await waitFor(async () => (await ideWindows()).find(w => /Confirm|Подтвер|Підтвер/.test(w.title)));
  check(confirm, 'the rewind asks for confirmation', JSON.stringify((await ideWindows()).map(w => w.title)));
  if (confirm) {
    await clickIde(confirm.title, /Button "OK"/, 'point');
    const report = await waitFor(async () => (await ideWindows()).find(w => w.class === 'TMessageForm'));
    if (report) await clickIde(report.title, /Button "OK"/, 'point');
  }
  await sleep(1000);
  check(Buffer.compare(fs.readFileSync(tests), testsOrig) === 0 && !fs.existsSync(notes),
    'rewind: the edited file is back byte for byte, the new file is deleted');
  const after = await ideUi('Claude Timeline');
  check(!/e2e: change tests/.test(after), 'the rewound turn left the timeline');
}

if (want('prompts')) {
  console.log('--- prompts and hooks settings');
  const l = await rpc('prompts/list', {});
  check(l.result.prompts.length === 8, 'eight prompts');
  const rv = await rpc('prompts/get', { name: 'review-changes', arguments: { focus: 'thread safety' } });
  check(/git diff HEAD/.test(rv.result.messages[0].content.text) && /thread safety/.test(rv.result.messages[0].content.text),
    'review-changes prompt');
  const g = await rpc('prompts/get', { name: 'hunt-bug', arguments: { description: 'total is 0' } });
  check(g.result.messages[0].content.text.includes('total is 0'), 'prompts/get fills arguments');
  const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.claude', 'ide', `${port}.delphi-settings.json`), 'utf8'));
  check(cfg.hooks.PreToolUse[0].matcher === 'Edit|Write|MultiEdit|NotebookEdit' &&
    cfg.hooks.Stop[0].hooks[0].command.includes(`127.0.0.1:${port}/hook`), 'the hooks settings file');
}

console.log(`\n${passes} passed, ${failures} failed`);
process.exitCode = failures ? 1 : 0;
