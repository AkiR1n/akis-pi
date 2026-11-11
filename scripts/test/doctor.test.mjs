import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { versionStatus, parseJsonc } from '../config-utils.mjs';
test('version drift rules: exact PASS, ordinary drift WARN, Pi/MC major drift FAIL', () => {
 assert.equal(versionStatus('1.5.2','1.5.2',true),'PASS');
 assert.equal(versionStatus('1.6.0','1.5.2',true),'WARN');
 assert.equal(versionStatus('2.0.0','1.5.2',true),'FAIL');
 assert.equal(versionStatus('1.0.0','0.49.50',true),'FAIL');
 assert.equal(versionStatus('9.0.0','0.47.0'),'WARN');
});
test('JSONC parser retains comment markers and trailing comma text inside strings', () => {
 assert.deepEqual(parseJsonc('{/*a*/"url":"http://localhost", "text":",}",}'), {url:'http://localhost',text:',}'});
});
test('doctor compares manifest even when settings matches wrong disk versions, scans external configs, never pi list', () => {
 const home=fs.mkdtempSync(path.join(os.tmpdir(),'akis-doctor-test-'));
 const agent=path.join(home,'.pi/agent'); const bin=path.join(home,'bin'); fs.mkdirSync(bin,{recursive:true});
 // A fake pi would leave evidence if doctor ever invoked list.
 fs.writeFileSync(path.join(bin,'pi'), '#!/bin/sh\nif [ "$1" = "--version" ]; then echo 1.5.2; else touch "'+home+'/unexpected-list"; exit 7; fi\n',{mode:0o755});
 const write=(rel,data)=>{const file=path.join(home,rel);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(data));};
 fs.writeFileSync(path.join(bin,'rtk'), '#!/bin/sh\nexit 127\n', {mode:0o755});
 write('.pi/agent/npm/node_modules/@cortexkit/pi-magic-context/package.json',{version:'1.0.0'});
 write('.pi/agent/settings.json',{packages:['npm:pi-web-access@9.0.0'],codemode:{mode:'only'}});
 write('.pi/agent/npm/node_modules/pi-web-access/package.json',{version:'9.0.0'});
 write('.pi/web-search.json',{braveApiKey:'{{BRAVE_KEY_REF}}'});
 write('.config/cortexkit/magic-context.jsonc',{historian:{pi:{model:'{{MODEL_HISTORIAN}}'}}});
 const result=spawnSync(process.execPath,[path.resolve(import.meta.dirname,'../doctor.mjs'),'--home',home,'--modules','core,memory','--json'],{encoding:'utf8',env:{...process.env,PATH:bin+path.delimiter+process.env.PATH}});
 const output=JSON.parse(result.stdout);
 assert.ok(output.results.some(r=>r.label==='manifest version pi-web-access'&&r.status==='WARN'));
 assert.ok(output.results.some(r=>r.label==='manifest version pi-magic-context'&&r.status==='FAIL'));
 assert.ok(output.results.some(r=>r.label==='rtk rewrite'&&r.status==='WARN'));
 assert.ok(output.results.some(r=>r.label==='placeholders resolved'&&r.status==='FAIL'&&r.detail.includes('BRAVE_KEY_REF')&&r.detail.includes('MODEL_HISTORIAN')));
 assert.equal(fs.existsSync(path.join(home,'unexpected-list')),false);
});
