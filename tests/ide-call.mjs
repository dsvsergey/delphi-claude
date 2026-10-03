// Calls a tool of the IDE channel (WebSocket, like Claude Code's /ide connection) - openDiff,
// close_tab, getOpenEditors... - and prints the result.
//   node ide-call.mjs <port> <token> <tool> [json-arguments] [timeoutSec]
import net from 'node:net';
import crypto from 'node:crypto';

const [port, token, name, json, timeoutSec] = process.argv.slice(2);

const sock = net.connect(+port, '127.0.0.1');
const key = crypto.randomBytes(16).toString('base64');
let buf = Buffer.alloc(0), upgraded = false;

function send(obj) {
  const payload = Buffer.from(JSON.stringify(obj));
  const mask = crypto.randomBytes(4), n = payload.length;
  const hdr = n < 126 ? Buffer.from([0x81, 0x80 | n])
    : n < 65536 ? Buffer.from([0x81, 0x80 | 126, n >> 8, n & 255])
    : (() => { const h = Buffer.alloc(10); h[0] = 0x81; h[1] = 0x80 | 127; h.writeBigUInt64BE(BigInt(n), 2); return h; })();
  for (let i = 0; i < n; i++) payload[i] ^= mask[i & 3];
  sock.write(Buffer.concat([hdr, mask, payload]));
}

const timer = setTimeout(() => { console.error('timeout'); process.exit(2); }, (+timeoutSec || 600) * 1000);
sock.on('connect', () => sock.write(
  `GET / HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
  `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\nx-claude-code-ide-authorization: ${token}\r\n\r\n`));
sock.on('data', d => {
  buf = Buffer.concat([buf, d]);
  if (!upgraded) {
    const i = buf.indexOf('\r\n\r\n'); if (i < 0) return;
    if (!buf.subarray(0, i).toString().startsWith('HTTP/1.1 101')) { console.error('handshake failed'); process.exit(1); }
    buf = buf.subarray(i + 4); upgraded = true;
    send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'ide-call', version: '1' } } });
    send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name, arguments: json ? JSON.parse(json) : {} } });
  }
  while (buf.length >= 2) {
    let len = buf[1] & 0x7f, off = 2;
    if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
    else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
    if (buf.length < off + len) return;
    const msg = JSON.parse(buf.subarray(off, off + len).toString());
    buf = buf.subarray(off + len);
    if (msg.id === 2) {
      clearTimeout(timer);
      console.log(msg.result ? msg.result.content.map(c => c.text).join('\n---\n') : JSON.stringify(msg.error));
      sock.destroy();
      process.exit(msg.result && !msg.result.isError ? 0 : 1);
    }
  }
});
