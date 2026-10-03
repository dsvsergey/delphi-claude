// Calls one tool of the "delphi" MCP server of a running IDE, like Claude Code does.
//   node mcp-call.mjs <port> <token> <tool> [json-arguments]
//   node mcp-call.mjs <port> <token> --list
// Prints the text content of the result; exit code 1 when the tool reports an error.

export async function rpc(port, token, method, params) {
  const res = await fetch(`http://127.0.0.1:${port}/mcp`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}

export async function callTool(port, token, name, args = {}) {
  const r = await rpc(port, token, 'tools/call', { name, arguments: args });
  return { isError: r.isError, text: r.content.map((c) => c.text).join('\n') };
}

const isMain = process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop());
if (isMain) {
  const [port, token, name, json] = process.argv.slice(2);
  if (name === '--list') {
    const r = await rpc(port, token, 'tools/list', {});
    for (const t of r.tools) console.log(t.name);
  } else if (name === '--prompts') {
    const r = await rpc(port, token, 'prompts/list', {});
    for (const p of r.prompts) console.log(p.name, '-', p.description);
  } else {
    const r = await callTool(port, token, name, json ? JSON.parse(json) : {});
    console.log(r.text);
    if (r.isError) process.exitCode = 1;
  }
}
