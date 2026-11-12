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
 // A portable Node fake CLI records any unexpected command (including list).
 const cli=path.join(bin,'pi.mjs');
 fs.writeFileSync(cli, 'import fs from "node:fs"; if(process.argv[2] === "--version")console.log("1.5.2");else {fs.writeFileSync('+JSON.stringify(path.join(home,'unexpected-list'))+',"unexpected");process.exit(7);}\n');
 const write=(rel,data)=>{const file=path.join(home,rel);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(data));};
 write('.pi/agent/npm/node_modules/@cortexkit/pi-magic-context/package.json',{version:'1.0.0'});
 write('.pi/agent/settings.json',{packages:['npm:pi-web-access@9.0.0'],codemode:{mode:'only'}});
 write('.pi/agent/npm/node_modules/pi-web-access/package.json',{version:'9.0.0'});
 write('.pi/web-search.json',{braveApiKey:'{{BRAVE_KEY_REF}}'});
 write('.config/cortexkit/magic-context.jsonc',{historian:{pi:{model:'{{MODEL_HISTORIAN}}'}}});
 const env={...process.env,PATH:bin+path.delimiter+process.env.PATH};
 for(const key of ['PI_CODING_AGENT_DIR','XDG_CONFIG_HOME','XDG_DATA_HOME','WSL_DISTRO_NAME'])delete env[key];
 const result=spawnSync(process.execPath,[path.resolve(import.meta.dirname,'../doctor.mjs'),'--home',home,'--pi-command',cli,'--modules','core,memory','--json'],{encoding:'utf8',env});
 const output=JSON.parse(result.stdout);
 assert.ok(output.results.some(r=>r.label==='manifest version pi-web-access'&&r.status==='WARN'));
 assert.ok(output.results.some(r=>r.label==='manifest version pi-magic-context'&&r.status==='FAIL'));
 assert.ok(output.results.some(r=>r.label==='placeholders resolved'&&r.status==='FAIL'&&r.detail.includes('BRAVE_KEY_REF')&&r.detail.includes('MODEL_HISTORIAN')));
 assert.equal(fs.existsSync(path.join(home,'unexpected-list')),false);
 assert.equal(result.status,1);
 assert.ok(output.results.some(r=>r.label==='onnxruntime-node load'&&r.status==='FAIL'));
 fs.rmSync(home,{recursive:true,force:true});
});

test('doctor checks memory native loading in isolation, reports FAIL for broken bindings, and leaves core alone', (t) => {
 const home=fs.mkdtempSync(path.join(os.tmpdir(),'akis-doctor-onnx-'));
 t.after(()=>fs.rmSync(home,{recursive:true,force:true}));
 const agent=path.join(home,'agent');
 const pkg=path.join(agent,'npm/node_modules/onnxruntime-node');
 fs.mkdirSync(pkg,{recursive:true});
 const run=(modules)=>{
  const result=spawnSync(process.execPath,[path.resolve(import.meta.dirname,'../doctor.mjs'),'--home',home,'--agent-dir',agent,'--modules',modules,'--json'],{encoding:'utf8'});
  return {code:result.status,output:JSON.parse(result.stdout)};
 };
 fs.writeFileSync(path.join(pkg,'index.js'),"throw Error('synthetic native binding failure');");
 const broken=run('core,memory');
 assert.equal(broken.code,1);
 assert.ok(broken.output.results.some(r=>r.label==='onnxruntime-node load'&&r.status==='FAIL'&&r.detail.includes('synthetic native binding failure')));
 const core=run('core');
 assert.ok(!core.output.results.some(r=>r.label==='onnxruntime-node load'));
 fs.writeFileSync(path.join(pkg,'index.js'),"exports.env={versions:{common:'test',node:'test'}};");
 const good=run('core,memory');
 assert.ok(good.output.results.some(r=>r.label==='onnxruntime-node load'&&r.status==='PASS'&&r.detail.includes('test')));
 fs.rmSync(pkg,{recursive:true});
 const missing=run('core,memory');
 const failure=missing.output.results.find(r=>r.label==='onnxruntime-node load');
 assert.equal(failure.status,'FAIL');
 if(process.platform==='linux')assert.match(failure.detail,/ONNXRUNTIME_NODE_INSTALL=skip/);
});
