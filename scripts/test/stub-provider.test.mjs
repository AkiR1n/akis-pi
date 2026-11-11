import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
test('loopback stub records bodies and supports JSON and SSE completion responses', async () => {
 const log=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'akis-stub-test-')),'requests.jsonl');
 const child=spawn(process.execPath,[path.resolve(import.meta.dirname,'../stub-provider.mjs'),'--port','0','--log',log],{stdio:['ignore','pipe','pipe']});
 try {
   const [chunk]=await once(child.stdout,'data');
   const base=String(chunk).trim().split(' ').at(-1);
   assert.match(base,/^http:\/\/127\.0\.0\.1:\d+$/);
   for(const stream of [false,true]) {
     const body={model:'stub-model',stream,messages:[{role:'user',content:'hello'}],tools:[]};
     const response=await fetch(base+'/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
     assert.equal(response.status,200); const output=await response.text();
     assert.ok(output.includes('stub-ok')); if(stream) assert.ok(output.includes('[DONE]'));
   }
   assert.equal(fs.readFileSync(log,'utf8').trim().split('\n').length,2);
 } finally { const exited=once(child,'exit'); child.kill('SIGTERM'); await exited; }
});
