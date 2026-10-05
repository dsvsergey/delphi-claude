// Stress test of the read-only tools on a large project open in a running IDE.
//   node stress-test.mjs <port> <token> <IDE process id> [units to outline, default 300]
// Takes the units from getProjectInfo, then: outlines, symbol searches and references over the
// whole project, unit dependencies, modernization scans, a build, opening many files, parallel
// requests and repeated rounds while watching the IDE's memory and handle count.
import net from 'node:net';
import crypto from 'node:crypto';
import { execSync } from 'node:child_process';
import fs from 'node:fs';

const [port, token, idePid, outlineArg] = process.argv.slice(2);
const OUTLINES = +(outlineArg || 300);
let failures = 0, passes = 0;
const check = (cond, msg, detail = '') => {
  if (cond) { passes++; console.log(`PASS ${msg}`); }
  else { failures++; console.log(`FAIL ${msg}${detail ? '\n     ' + String(detail).slice(0, 400).replace(/\n/g, '\n     ') : ''}`); }
};
const times = {};
const note = (name, ms) => { (times[name] ||= []).push(ms); };

async function rpc(method, params) {
  const res = await fetch(`http://127.0.0.1:${port}/mcp`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}
async function call(name, args = {}) {
  const t = Date.now();
  let r;
  try {
    const j = await rpc('tools/call', { name, arguments: args });
    r = j.error ? { isError: true, text: j.error.message } : { isError: j.result.isError, text: j.result.content.map(c => c.text).join('\n') };
  } catch (e) { r = { isError: true, text: 'transport: ' + e.message }; }
  r.ms = Date.now() - t;
  note(name, r.ms);
  return r;
}
const json = r => { try { return JSON.parse(r.text); } catch { return null; } };

function ideCall(name, args = {}, timeoutMs = 60000) {
  return new Promise((resolve) => {
    const sock = net.connect(+port, '127.0.0.1');
    const key = crypto.randomBytes(16).toString('base64');
    let buf = Buffer.alloc(0), up = false;
    const t = setTimeout(() => { sock.destroy(); resolve({ error: 'timeout' }); }, timeoutMs);
    const send = o => {
      const p = Buffer.from(JSON.stringify(o)), m = crypto.randomBytes(4), n = p.length;
      const h = n < 126 ? Buffer.from([0x81, 0x80 | n]) : Buffer.from([0x81, 0xfe, n >> 8, n & 255]);
      for (let i = 0; i < n; i++) p[i] ^= m[i & 3];
      sock.write(Buffer.concat([h, m, p]));
    };
    sock.on('error', e => { clearTimeout(t); resolve({ error: e.message }); });
    sock.on('connect', () => sock.write(`GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
      `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\nx-claude-code-ide-authorization: ${token}\r\n\r\n`));
    sock.on('data', d => {
      buf = Buffer.concat([buf, d]);
      if (!up) {
        const i = buf.indexOf('\r\n\r\n'); if (i < 0) return;
        buf = buf.subarray(i + 4); up = true;
        send({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } });
      }
      while (buf.length >= 2) {
        let len = buf[1] & 127, off = 2;
        if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
        else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
        if (buf.length < off + len) return;
        const msg = JSON.parse(buf.subarray(off, off + len).toString());
        buf = buf.subarray(off + len);
        if (msg.id === 1) { clearTimeout(t); sock.destroy(); resolve(msg.result || { error: msg.error?.message }); }
      }
    });
  });
}

function ideMemory() {
  try {
    const out = execSync(`powershell -NoProfile -Command "$p = Get-Process -Id ${idePid}; '{0} {1}' -f [int]($p.WorkingSet64/1MB), $p.HandleCount"`).toString().trim();
    const [mb, handles] = out.split(' ').map(Number);
    return { mb, handles };
  } catch { return null; }
}
const alive = () => ideMemory() !== null;

const mem0 = ideMemory();
console.log(`IDE at start: ${mem0?.mb} MB, ${mem0?.handles} handles`);

console.log('--- project');
let r = await call('getProjectInfo', {});
const info = json(r);
check(info && !r.isError, `getProjectInfo (${r.ms} ms)`, r.text);
const modules = info?.project?.modules || [];
const units = modules.map(m => m.file).filter(Boolean);
const pasUnits = units.filter(u => /\.pas$/i.test(u));
const forms = modules.filter(m => m.formName).map(m => m.formName);
console.log(`  ${units.length} units (${pasUnits.length} .pas), ${forms.length} forms`);
check(pasUnits.length > 0, 'the project has units', JSON.stringify(info).slice(0, 400));
const unitName = f => f.replace(/^.*[\\/]/, '').replace(/\.pas$/i, '');

r = await ideCall('getWorkspaceFolders', {});
check(!r.error && JSON.parse(r.content?.[0]?.text || '{}').folders?.length > 0, 'getWorkspaceFolders', JSON.stringify(r));

console.log('--- unit dependencies');
r = await call('getUnitDependencies', {});
const deps = r.text;
check(!r.isError && /\d+ units/.test(deps), `getUnitDependencies for the whole project (${r.ms} ms)`, r.text);
if (deps) console.log('  ' + JSON.stringify(deps).slice(0, 300));
r = await call('getUnitDependencies', {});
check(!r.isError, `getUnitDependencies again, cached (${r.ms} ms)`);
for (const u of pasUnits.slice(0, 5).map(unitName)) {
  r = await call('getUnitDependencies', { unit: u });
  check(!r.isError, `getUnitDependencies ${u} (${r.ms} ms)`, r.text);
}

console.log(`--- outlines of ${Math.min(OUTLINES, pasUnits.length)} units`);
let outlineErrors = [], slowest = { ms: 0 };
for (const f of pasUnits.slice(0, OUTLINES)) {
  r = await call('getUnitOutline', { unit: unitName(f) });
  if (r.isError) outlineErrors.push(`${unitName(f)}: ${r.text.slice(0, 120)}`);
  if (r.ms > slowest.ms) slowest = { ms: r.ms, unit: unitName(f) };
}
check(outlineErrors.length === 0, `getUnitOutline for every unit (slowest ${slowest.unit} ${slowest.ms} ms)`, outlineErrors.slice(0, 10).join('\n'));

console.log('--- symbols and references over the whole project');
const names = ['Create', 'Free', 'Execute', 'Result', 'TForm', 'ShowModal', 'Close', 'Open', 'FormCreate', 'Exception'];
for (const n of names) {
  r = await call('findSymbol', { name: n });
  check(!r.isError || /not found|No declaration/i.test(r.text), `findSymbol ${n} (${r.ms} ms)`, r.text);
  r = await call('findReferences', { name: n, resolve: false });
  const m = /(\d+) occurrence\(s\) of \S+ in (\d+) file/.exec(r.text);
  check(!r.isError, `findReferences ${n}: ${m ? m[1] + ' in ' + m[2] + ' files' : '?'} (${r.ms} ms, ${r.text.length} chars)`, r.text);
}
for (const f of pasUnits.slice(0, 3)) {
  const out = json(await call('getUnitOutline', { unit: unitName(f), members: false }));
  const typeName = JSON.stringify(out || '').match(/"name":"(T\w+)"/)?.[1];
  if (typeName) {
    r = await call('findSymbol', { name: typeName, kind: 'class' });
    check(!r.isError, `findSymbol ${typeName} as a class (${r.ms} ms)`, r.text);
  }
}

console.log('--- modernization scans');
for (const s of ['unicode', 'win64', 'bde']) {
  r = await call('analyzeModernization', { scenario: s });
  check(!r.isError, `analyzeModernization ${s} (${r.ms} ms, ${r.text.length} chars)`, r.text);
}

console.log('--- build');
r = await call('buildProject', {});
const b = json(r);
check(b && typeof b.success === 'boolean', `buildProject answers (${r.ms} ms): ${b?.summary ?? r.text.slice(0, 200)}`, r.text);
if (b && !b.success) check(Array.isArray(b.messages) && b.messages.length > 0, `build errors are parsed (${b.messages?.length} messages)`, r.text);

console.log('--- editors');
// Units without a form: opening a form whose components the IDE lacks shows modal errors.
const toOpen = pasUnits.filter(f => !fs.existsSync(f.replace(/\.pas$/i, '.dfm'))).slice(0, 30);
let openErr = 0;
for (const f of toOpen) { const x = await ideCall('openFile', { filePath: f, preview: false }); if (x.error || x.isError) openErr++; }
check(openErr === 0, `openFile for ${toOpen.length} units (${openErr} errors)`);
const eds = await ideCall('getOpenEditors', {});
const tabs = JSON.parse(eds?.content?.[0]?.text || '{}').tabs || [];
check(tabs.length >= toOpen.length, `getOpenEditors lists them (${tabs.length} tabs)`);
let dirtyErr = 0;
for (const f of toOpen) { const x = await ideCall('checkDocumentDirty', { filePath: f }); if (x.error || x.isError) dirtyErr++; }
check(dirtyErr === 0, `checkDocumentDirty for each (${dirtyErr} errors)`);
{ const t = Date.now(); const d = await ideCall('getDiagnostics', {}); check(!d.error && !d.isError, `getDiagnostics for ${tabs.length} open files (${Date.now() - t} ms)`, JSON.stringify(d).slice(0, 300)); }
if (forms.length) {
  const fr = await call('getFormComponents', { form: forms[0], includeDfm: false });
  check(!fr.isError, `getFormComponents ${forms[0]} (${fr.ms} ms)`, fr.text);
}

console.log('--- parallel requests');
const t0 = Date.now();
const par = await Promise.all([
  ...names.map(n => call('findReferences', { name: n, resolve: false })),
  ...pasUnits.slice(0, 20).map(f => call('getUnitOutline', { unit: unitName(f) })),
  ...Array.from({ length: 10 }, () => ideCall('getOpenEditors', {}))
]);
const parErr = par.filter(x => x.isError || x.error);
check(parErr.length === 0, `${par.length} requests at once (${Date.now() - t0} ms)`, parErr.slice(0, 3).map(x => x.text || x.error).join('\n'));
check(alive(), 'the IDE is alive after the parallel burst');

console.log('--- repeated rounds (memory)');
const before = ideMemory();
for (let round = 1; round <= 5; round++) {
  for (const n of names) await call('findReferences', { name: n, resolve: false });
  for (const f of pasUnits.slice(0, 50)) await call('getUnitOutline', { unit: unitName(f) });
  await call('getUnitDependencies', {});
  const m = ideMemory();
  console.log(`  round ${round}: ${m?.mb} MB, ${m?.handles} handles`);
}
const after = ideMemory();
check(after && before && after.mb - before.mb < 150, `memory after 5 rounds grew ${after?.mb - before?.mb} MB (< 150)`);
check(after && before && after.handles - before.handles < 500, `handles after 5 rounds grew ${after?.handles - before?.handles} (< 500)`);

console.log('--- timings (ms: count / median / max)');
for (const [k, v] of Object.entries(times)) {
  const s = [...v].sort((a, b) => a - b);
  console.log(`  ${k.padEnd(22)} ${String(s.length).padStart(4)} / ${String(s[s.length >> 1]).padStart(6)} / ${String(s[s.length - 1]).padStart(6)}`);
}
const memEnd = ideMemory();
console.log(`IDE at end: ${memEnd?.mb} MB, ${memEnd?.handles} handles (start ${mem0?.mb} MB, ${mem0?.handles} handles)`);
console.log(`\n${passes} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
