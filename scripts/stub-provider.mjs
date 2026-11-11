#!/usr/bin/env node
// Local OpenAI-compatible request probe. Logs may contain private system prompts: keep in scratch.
import http from 'node:http';
import fs from 'node:fs';

let port = 8899, log;
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === '--port') port = Number(process.argv[++i]);
  else if (arg === '--log') log = process.argv[++i];
  else { console.error('Usage: node scripts/stub-provider.mjs [--port 8899] --log /tmp/requests.jsonl'); process.exit(2); }
}
if (!log || !Number.isInteger(port) || port < 0 || port > 65535) { console.error('Valid --port and --log are required'); process.exit(2); }
const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/v1/models') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({object:'list',data:[{id:'stub-model',object:'model',owned_by:'local'}]})); return;
  }
  if (req.method !== 'POST' || req.url !== '/v1/chat/completions') { res.writeHead(404).end(); return; }
  try {
    let raw = '';
    for await (const chunk of req) { raw += chunk; if (Buffer.byteLength(raw) > 16 * 1024 * 1024) throw new Error('body too large'); }
    const body = JSON.parse(raw);
    fs.appendFileSync(log, JSON.stringify(body) + '\n', {mode:0o600});
    const base = {id:'stub-local',created:Math.floor(Date.now()/1000),model:body.model || 'stub-model'};
    if (body.stream) {
      res.writeHead(200, {'Content-Type':'text/event-stream','Cache-Control':'no-cache'});
      const send = (choices, usage) => res.write('data: ' + JSON.stringify({...base,object:'chat.completion.chunk',choices,...(usage ? {usage}: {})}) + '\n\n');
      send([{index:0,delta:{role:'assistant',content:'stub-ok'},finish_reason:null}]);
      send([{index:0,delta:{},finish_reason:'stop'}], {prompt_tokens:1,completion_tokens:1,total_tokens:2});
      res.end('data: [DONE]\n\n');
    } else {
      res.setHeader('Content-Type','application/json');
      res.end(JSON.stringify({...base,object:'chat.completion',choices:[{index:0,message:{role:'assistant',content:'stub-ok'},finish_reason:'stop'}],usage:{prompt_tokens:1,completion_tokens:1,total_tokens:2}}));
    }
  } catch { res.writeHead(400).end('invalid request or log unavailable'); }
});
server.on('error', (error) => { console.error(error.message); process.exitCode=1; });
server.listen(port, '127.0.0.1', () => console.log('stub listening http://127.0.0.1:' + server.address().port));
for (const signal of ['SIGINT','SIGTERM']) process.on(signal, () => server.close());
