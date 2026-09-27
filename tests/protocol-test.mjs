// Protocol test for the Claude Code Delphi IDE server.
// Usage: node protocol-test.mjs <port> <token>   (TestHost.exe prints both)
import net from 'node:net';
import crypto from 'node:crypto';

const [port, token] = process.argv.slice(2);
let failures = 0;
const check = (cond, msg) => { console.log(`${cond ? 'PASS' : 'FAIL'} ${msg}`); if (!cond) failures++; };

function connect(authToken, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    const sock = net.connect(+port, host);
    const key = crypto.randomBytes(16).toString('base64');
    let buf = Buffer.alloc(0), upgraded = false;
    const frames = [], waiters = [];
    sock.on('error', reject);
    sock.on('connect', () => sock.write(
      `GET / HTTP/1.1\r\nHost: ${host}:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
      `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n` +
      (authToken ? `x-claude-code-ide-authorization: ${authToken}\r\n` : '') + `\r\n`));
    sock.on('data', d => {
      buf = Buffer.concat([buf, d]);
      if (!upgraded) {
        const i = buf.indexOf('\r\n\r\n'); if (i < 0) return;
        const head = buf.subarray(0, i).toString(); buf = buf.subarray(i + 4);
        if (!head.startsWith('HTTP/1.1 101')) { resolve({ status: head.split('\r\n')[0] }); sock.destroy(); return; }
        const expect = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        upgraded = true;
        resolve({ status: '101', acceptOk: head.includes(expect), send, sendRaw, next, close: () => sock.destroy() });
      }
      while (buf.length >= 2) {
        let len = buf[1] & 0x7f, off = 2;
        if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
        else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
        if (buf.length < off + len) return;
        const f = { op: buf[0] & 0x0f, data: buf.subarray(off, off + len) };
        buf = buf.subarray(off + len);
        const w = waiters.shift(); w ? w(f) : frames.push(f);
      }
    });
    function sendRaw(op, payload, fin = true) {
      const mask = crypto.randomBytes(4), n = payload.length;
      const hdr = n < 126 ? Buffer.from([ (fin ? 0x80 : 0) | op, 0x80 | n ])
        : n < 65536 ? Buffer.from([(fin ? 0x80 : 0) | op, 0x80 | 126, n >> 8, n & 255])
        : (() => { const h = Buffer.alloc(10); h[0] = (fin ? 0x80 : 0) | op; h[1] = 0x80 | 127; h.writeBigUInt64BE(BigInt(n), 2); return h; })();
      const body = Buffer.from(payload); for (let i = 0; i < n; i++) body[i] ^= mask[i & 3];
      sock.write(Buffer.concat([hdr, mask, body]));
    }
    function send(obj) { sendRaw(1, Buffer.from(JSON.stringify(obj))); }
    function next(ms = 3000) {
      return new Promise((res, rej) => {
        if (frames.length) return res(frames.shift());
        const t = setTimeout(() => rej(new Error('timeout')), ms);
        waiters.push(f => { clearTimeout(t); res(f); });
      });
    }
  });
}
const json = f => JSON.parse(f.data.toString());

// 1. Auth is enforced.
check((await connect('wrong')).status.includes('401'), 'wrong token -> 401');
check((await connect(null)).status.includes('401'), 'missing token -> 401');

// 2. Handshake + initialize.
const c = await connect(token);
check(c.status === '101' && c.acceptOk, 'handshake 101 with valid Sec-WebSocket-Accept');
c.send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 't', version: '1' } } });
let r = json(await c.next());
check(r.id === 1 && r.result.protocolVersion === '2025-06-18' && r.result.serverInfo.name === 'claude-code-delphi', 'initialize');
c.send({ jsonrpc: '2.0', method: 'notifications/initialized' });

// 3. tools/list
c.send({ jsonrpc: '2.0', id: 'abc', method: 'tools/list' });
r = json(await c.next());
const names = r.result.tools.map(t => t.name);
check(r.id === 'abc' && ['openFile','openDiff','getCurrentSelection','getLatestSelection','getOpenEditors','getWorkspaceFolders','getDiagnostics','checkDocumentDirty','saveDocument','close_tab','closeAllDiffTabs','buildProject','getProjectInfo'].every(n => names.includes(n)), `tools/list (${names.length} tools)`);

// 4. tools/call goes through the main thread; unicode + large payload (>64KiB) + fragmented frames.
const big = 'Привіт ✓ '.repeat(12000);
c.send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'echo', arguments: { s: big } } });
r = json(await c.next());
check(r.id === 2 && JSON.parse(r.result.content[0].text).s === big && r.result.isError === false, 'tools/call echo with 200KB unicode payload');
const part = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'echo', arguments: { x: 1 } } }));
c.sendRaw(1, part.subarray(0, 10), false); c.sendRaw(0, part.subarray(10), true);
r = json(await c.next());
check(r.id === 3 && r.result.content[0].text === '{"x":1}', 'fragmented message');

// 5. Deferred result (openDiff waits for the user).
c.send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'openDiff', arguments: {} } });
c.send({ jsonrpc: '2.0', id: 5, method: 'ping' });
r = json(await c.next());
check(r.id === 5, 'ping answered while openDiff is pending');
r = json(await c.next());
check(r.id === 4 && r.result.content[0].text === 'FILE_SAVED', 'openDiff deferred result');

// 6. Errors
c.send({ jsonrpc: '2.0', id: 6, method: 'nope' });
r = json(await c.next());
check(r.id === 6 && r.error.code === -32601, 'unknown method -> -32601');
c.send({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'nope' } });
r = json(await c.next());
check(r.id === 7 && r.result.isError === true, 'unknown tool -> isError');

// 7. Ping/pong control frame.
c.sendRaw(9, Buffer.from('hi'));
const pong = await c.next();
check(pong.op === 10 && pong.data.toString() === 'hi', 'websocket ping -> pong');

// 8. IPv6 loopback works too (localhost may resolve to ::1).
try { const c6 = await connect(token, '::1'); check(c6.status === '101', 'IPv6 ::1 connection'); c6.close(); }
catch (e) { check(false, 'IPv6 ::1 connection: ' + e.message); }

// 9. Server notification on shutdown.
try { const n = json(await c.next(25000)); check(n.method === 'selection_changed' && n.params.text === 'bye', 'notification broadcast'); }
catch (e) { check(false, 'notification broadcast: ' + e.message); }
c.close();
console.log(failures ? `${failures} FAILED` : 'ALL PASSED');
process.exit(failures ? 1 : 0);
