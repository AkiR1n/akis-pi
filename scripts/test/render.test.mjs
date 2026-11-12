import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { backupRelativePath } from '../platform-utils.mjs';
const script = path.resolve(import.meta.dirname, '../render.mjs');
const home = () => fs.mkdtempSync(path.join(os.tmpdir(), 'akis-render-test-'));
const values = { PROVIDER: 'example', MODEL: 'main', MODEL_EXEC: 'exec', MODEL_REVIEW: 'review', MODEL_PLAN: 'plan', MODEL_HISTORIAN: 'history', BRAVE_KEY_REF: '$BRAVE_API_KEY', BOCHA_KEY_REF: '$BOCHA_API_KEY' };
const env = { ...process.env };
for (const key of ['PI_CODING_AGENT_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'WSL_DISTRO_NAME']) delete env[key];
const run = (dir, args = [], sets = values) => spawnSync(process.execPath, [script, '--home', dir, '--platform', 'darwin', ...Object.entries(sets).flatMap(([k,v]) => ['--set', k + '=' + v]), ...args], {encoding:'utf8',env});
const read = (dir, rel) => fs.readFileSync(path.join(dir, rel), 'utf8');
test('strict unresolved values refuse the entire apply before any writes', () => {
 const dir = home(); const result = run(dir, ['--apply', '--strict'], {});
 assert.equal(result.status, 1); assert.equal(fs.existsSync(path.join(dir, '.pi')), false);
});
test('non-strict skips unresolved files and keeps existing JSON untouched', () => {
 const dir = home(); fs.mkdirSync(path.join(dir,'.pi/agent'), {recursive:true});
 fs.writeFileSync(path.join(dir,'.pi/agent/settings.json'), '{}');
 const result = run(dir, ['--apply'], {});
 assert.equal(result.status, 0); assert.equal(read(dir,'.pi/agent/settings.json'), '{}');
 assert.equal(fs.existsSync(path.join(dir,'.pi/web-search.json')), false);
 assert.equal(fs.existsSync(path.join(dir,'.pi/agent/.akis-pi-render.json')), false);
});
test('JSON escaping preserves Keychain quotes, slashes and control characters', () => {
 const dir = home(); const ref = '!security find-generic-password -a "$USER" -s test-service -w';
 const model = 'main"\\id\nnext';
 const result = run(dir, ['--apply','--strict'], {...values, MODEL:model, BRAVE_KEY_REF:ref});
 assert.equal(result.status, 0, result.stderr);
 assert.equal(JSON.parse(read(dir,'.pi/agent/web-search.json')).braveApiKey, ref);
 assert.equal(JSON.parse(read(dir,'.pi/agent/settings.json')).defaultModel, model);
});
test('literal credentials are rejected without disclosure or writes', () => {
 const dir = home(); const literal = 'unacceptable-literal-credential';
 const result = run(dir, ['--apply'], {...values, BRAVE_KEY_REF:literal});
 assert.equal(result.status,2); assert.equal(fs.existsSync(path.join(dir,'.pi')), false);
 assert.equal((result.stdout + result.stderr).includes(literal), false);
});
test('adding macos and pdf preserves core bytes and memory packages; default is dry run', () => {
 const dir = home(); assert.equal(run(dir,['--modules','core,memory']).status,0);
 assert.equal(fs.existsSync(path.join(dir,'.pi')),false);
 assert.equal(run(dir,['--modules','core,memory','--apply','--strict']).status,0);
 const rel = '.pi/agent/settings.json'; const settings = JSON.parse(read(dir,rel)); settings.userCustom = 'keep';
 fs.writeFileSync(path.join(dir,rel), JSON.stringify(settings));
 const before=read(dir,rel); const rules=read(dir,'.pi/agent/AGENTS.md');
 assert.equal(run(dir,['--modules','core,macos,pdf','--apply','--strict']).status,0);
 assert.equal(read(dir,rel),before); assert.equal(read(dir,'.pi/agent/AGENTS.md'),rules);
 assert.ok(JSON.parse(before).packages.some(e=>String(e.source||e).includes('pi-magic-context')));
 assert.ok(fs.existsSync(path.join(dir,'Library/LaunchAgents/com.example.pipdfparse.plist')));
});
test('adding memory merges packages while retaining customized core settings', () => {
 const dir=home(); assert.equal(run(dir,['--apply','--strict']).status,0);
 const rel='.pi/agent/settings.json'; const settings=JSON.parse(read(dir,rel)); settings.defaultModel='custom'; settings.packages.push('npm:custom-package@1.0.0');
 fs.writeFileSync(path.join(dir,rel),JSON.stringify(settings));
 assert.equal(run(dir,['--modules','core,memory','--apply','--strict']).status,0);
 const after=JSON.parse(read(dir,rel)); assert.equal(after.defaultModel,'custom');
 assert.ok(after.packages.includes('npm:custom-package@1.0.0'));
 assert.equal(after.packages.filter(e=>String(e.source||e).includes('pi-magic-context')).length,1);
 assert.ok(fs.readdirSync(path.join(dir,'.pi/agent/backups')).length);
});

test('external targets are backed up beneath an external agent-dir before overwrite', () => {
 const root=home(); const dir=path.join(root,'home'); const agent=path.join(root,'external-agent');
 const targets=[path.join(agent,'web-search.json'),...['.config/cortexkit/magic-context.jsonc','.local/share/pi-pdf-parse/server.py','Library/LaunchAgents/com.example.pipdfparse.plist'].map(rel=>path.join(dir,rel))];
 for(const target of targets){fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,'previous-content');}
 const result=run(dir,['--agent-dir',agent,'--modules','core,memory,macos,pdf','--apply','--strict']);
 assert.equal(result.status,0,result.stderr);
 const backup=path.join(agent,'backups',fs.readdirSync(path.join(agent,'backups'))[0],'targets');
 for(const target of targets)assert.equal(fs.readFileSync(path.join(backup,backupRelativePath(target)),'utf8'),'previous-content');
});

test('memory merge also refuses inherited literal credential fields before writes', () => {
 const dir=home(); assert.equal(run(dir,['--apply','--strict']).status,0);
 const rel='.pi/agent/settings.json'; const settings=JSON.parse(read(dir,rel));settings.custom={apiKey:'literal-credential'};
 fs.writeFileSync(path.join(dir,rel),JSON.stringify(settings));const before=read(dir,rel);
 const result=run(dir,['--modules','memory','--apply','--strict']);
 assert.equal(result.status,2);assert.equal(read(dir,rel),before);
 assert.equal(fs.existsSync(path.join(dir,'.config/cortexkit/magic-context.jsonc')),false);
});
