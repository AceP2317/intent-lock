// approve-host.mjs -- a stand-in for the person who clicks "approve", used only by test/live.sh.
//
// A headless `claude -p` run offers ExitPlanMode only when something can answer its approval
// prompt. This is a minimal MCP server (stdio, no dependencies) with one tool, `approve`, passed to
// Claude Code with --permission-prompt-tool. It approves every request it is asked about and logs
// each one, so the test can show the intent gate ran BEFORE approval was ever asked for.
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const log = process.env.APPROVE_HOST_LOG;
const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

createInterface({ input: process.stdin }).on('line', (line) => {
  let req;
  try { req = JSON.parse(line); } catch { return; }
  const { id, method, params } = req;
  if (method === 'initialize') {
    send({ jsonrpc: '2.0', id, result: {
      protocolVersion: params?.protocolVersion ?? '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'approve-host', version: '1.0.0' } } });
  } else if (method === 'tools/list') {
    send({ jsonrpc: '2.0', id, result: { tools: [{
      name: 'approve',
      description: 'Approves a permission prompt, standing in for a person.',
      inputSchema: { type: 'object', properties: {
        tool_name: { type: 'string' }, input: { type: 'object' }, tool_use_id: { type: 'string' } } } }] } });
  } else if (method === 'tools/call') {
    const args = params?.arguments ?? {};
    if (log) appendFileSync(log, `${new Date().toLocaleString('sv').replace(' ', 'T')}  approve-host asked about ${args.tool_name}\n`);
    send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text',
      text: JSON.stringify({ behavior: 'allow', updatedInput: args.input ?? {} }) }] } });
  } else if (id !== undefined) {
    send({ jsonrpc: '2.0', id, error: { code: -32601, message: `no method ${method}` } });
  }
});
