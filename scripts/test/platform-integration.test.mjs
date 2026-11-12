import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = path.resolve(import.meta.dirname, '../..');
const values = { PROVIDER: 'example', MODEL: 'main', MODEL_EXEC: 'exec', MODEL_REVIEW: 'review', MODEL_PLAN: 'plan', MODEL_HISTORIAN: 'history', BRAVE_KEY_REF: '$BRAVE_API_KEY', BOCHA_KEY_REF: '$' + '{BOCHA_API_KEY}' };
function fixture(t) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-platform-'));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
  const home = path.join(tmp, '实验 学生');
  const agent = path.join(home, '自定义 Pi');
  const env = { ...process.env, XDG_CONFIG_HOME: path.join(home, '配置 空间'), XDG_DATA_HOME: path.join(home, '数据'), PI_CODING_AGENT_DIR: agent };
  delete env.WSL_DISTRO_NAME; delete env.BRAVE_API_KEY; delete env.BOCHA_API_KEY;
  return { tmp, home, agent, env };
}
function render(f, args = [], repo = root) {
  return spawnSync(process.execPath, [path.join(repo, 'scripts/render.mjs'), '--home', f.home, '--agent-dir', f.agent, ...Object.entries(values).flatMap(([k, v]) => ['--set', k + '=' + v]), '--strict', ...args], { env: f.env, encoding: 'utf8' });
}
const read = (file) => fs.readFileSync(file, 'utf8');

test('macos is rejected on Linux, WSL and native Windows before writes', (t) => {
  const f = fixture(t);
  for (const platform of ['linux', 'wsl', 'win32']) {
    const result = render(f, ['--platform', platform, '--modules', 'macos', '--apply']);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /macos module requires darwin/);
    assert.equal(fs.existsSync(f.agent), false);
  }
});

test('default npm uses no override; mise is explicit and rejected on native Windows', (t) => {
  const f = fixture(t);
  assert.equal(render(f, ['--apply']).status, 0);
  assert.equal('npmCommand' in JSON.parse(read(path.join(f.agent, 'settings.json'))), false);
  const g = fixture(t);
  assert.equal(render(g, ['--platform', 'linux', '--mise', '--apply']).status, 0);
  assert.deepEqual(JSON.parse(read(path.join(g.agent, 'settings.json'))).npmCommand, ['mise', 'exec', 'node@24.21.0', '--', 'npm']);
  const h = fixture(t);
  assert.equal(render(h, ['--platform', 'win32', '--set', 'USE_MISE=true', '--apply']).status, 2);
  assert.equal(fs.existsSync(h.agent), false);
});

test('PDF targets and systemd escaping follow policy; macos installs only its own extensions', (t) => {
  const f = fixture(t);
  f.home = path.join(f.home, 'percent% dollar$ quote"');
  const result = render(f, ['--platform', 'linux', '--modules', 'pdf', '--apply']);
  assert.equal(result.status, 0, result.stderr);
  const service = read(path.join(f.env.XDG_CONFIG_HOME, 'systemd/user/pi-pdf-parse.service'));
  assert.ok(service.includes('percent%% dollar$$ quote\\"'));
  assert.ok(fs.existsSync(path.join(f.home, '.local/share/pi-pdf-parse/server.py')));
  assert.equal(fs.existsSync(path.join(f.home, 'Library')), false);
  const g = fixture(t);
  assert.equal(render(g, ['--platform', 'darwin', '--modules', 'macos', '--apply']).status, 0);
  assert.equal(fs.existsSync(path.join(g.home, '.local/share/pi-pdf-parse/server.py')), false);
  assert.equal(render(g, ['--platform', 'darwin', '--modules', 'macos', '--apply']).status, 0);
  assert.deepEqual(JSON.parse(read(path.join(g.agent, '.akis-pi-render.json'))).modules, ['macos']);
});

test('v1 macos PDF state migration preserves edited PDF/plist and core bytes without duplicates', (t) => {
  const f = fixture(t);
  fs.mkdirSync(f.agent, { recursive: true });
  fs.writeFileSync(path.join(f.agent, '.akis-pi-render.json'), '\uFEFF' + JSON.stringify({ modules: ['core', 'macos'] }));
  const targets = [path.join(f.agent, 'settings.json'), path.join(f.home, '.local/share/pi-pdf-parse/server.py'), path.join(f.home, 'Library/LaunchAgents/com.example.pipdfparse.plist')];
  for (const file of targets) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, 'customized'); }
  const result = render(f, ['--platform', 'darwin', '--modules', 'core,macos,pdf', '--apply']);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /migration: adopted/);
  for (const file of targets) assert.equal(read(file), 'customized');
  assert.deepEqual(JSON.parse(read(path.join(f.agent, '.akis-pi-render.json'))), { schemaVersion: 2, modules: ['core', 'macos', 'pdf'] });
  const again = render(f, ['--platform', 'darwin', '--modules', 'pdf', '--apply']);
  assert.equal(again.status, 0, again.stderr);
  assert.match(again.stdout, /Wrote 0 file/);
});

test('CJK/space repository location renders correctly; doctor reads BOM and reports env status only', (t) => {
  const f = fixture(t);
  const repo = path.join(f.tmp, '中文 仓库');
  fs.mkdirSync(repo);
  for (const name of ['scripts', 'config', 'modules', 'extensions', 'skills', 'manifest.json']) fs.cpSync(path.join(root, name), path.join(repo, name), { recursive: true });
  const result = render(f, ['--modules', 'core,memory,pdf', '--apply'], repo);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(fs.existsSync(path.join(f.agent, 'web-search.json')));
  assert.ok(fs.existsSync(path.join(f.env.XDG_CONFIG_HOME, 'cortexkit/magic-context.jsonc')));
  assert.equal(JSON.parse(read(path.join(f.agent, 'web-search.json'))).githubClone.clonePath, undefined);
  for (const rel of ['settings.json', 'web-search.json']) {
    const file = path.join(f.agent, rel);
    fs.writeFileSync(file, '\uFEFF' + read(file).replace(/\n/g, '\r\n'));
  }
  const cli = path.join(f.tmp, '假 Pi.mjs');
  const calls = path.join(f.tmp, 'calls.jsonl');
  fs.writeFileSync(cli, 'import fs from "node:fs";fs.appendFileSync('+JSON.stringify(calls)+',JSON.stringify(process.argv.slice(2))+"\\n");if(process.argv[2]!=="--version")process.exit(9);console.log("1.5.2");');
  const before = read(path.join(f.agent, 'settings.json'));
  const sentinel = 'synthetic-env-value-do-not-emit';
  const report = spawnSync(process.execPath, [path.join(repo, 'scripts/doctor.mjs'), '--home', f.home, '--agent-dir', f.agent, '--modules', 'core,memory,pdf', '--pi-command', cli, '--json'], { env: { ...f.env, BRAVE_API_KEY: sentinel }, encoding: 'utf8' });
  const output = JSON.parse(report.stdout);
  assert.equal(output.platform, process.platform);
  assert.ok(output.results.some((r) => r.label.endsWith('braveApiKey') && r.detail === 'ok' && r.status === 'PASS'));
  assert.ok(output.results.some((r) => r.label.endsWith('bochaApiKey') && r.detail === 'missing' && r.status === 'WARN'));
  assert.equal((report.stdout + report.stderr).includes(sentinel), false);
  assert.equal(output.results.some((r) => r.label === 'doctor crashed in a check'), false);
  assert.deepEqual(read(calls).trim().split('\n').map(JSON.parse), [['--version']]);
  assert.equal(read(path.join(f.agent, 'settings.json')), before);
  const failures = output.results.filter((r) => r.status === 'FAIL');
  assert.ok(failures.length > 0, 'fixtures intentionally omit plugin installations');
  assert.ok(failures.every((r) => r.label === 'packages resolve on disk' || r.label.startsWith('manifest version ')), JSON.stringify(failures));
});
