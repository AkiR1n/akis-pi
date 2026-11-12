import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import { checkOnnx } from '../onnx-check.mjs';

const script = path.resolve(import.meta.dirname, '../deploy-check.mjs');
test('deployment checks preserve credential refs, detect role placeholders and refuse resident overwrite', (t) => {
  const agent = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-check-'));
  t.after(() => fs.rmSync(agent, { recursive: true, force: true }));
  for (const sub of ['agents', 'memory']) fs.mkdirSync(path.join(agent, sub));
  const write = (file, text) => fs.writeFileSync(path.join(agent, file), text);
  const run = (command, extraEnv = {}) => spawnSync(process.execPath, [script, command], { encoding: 'utf8', env: { ...process.env, PI_CODING_AGENT_DIR: agent, ...extraEnv } });
  write('web-search.json', JSON.stringify({ braveApiKey: '$BRAVE_API_KEY', bochaApiKey: '!command' }));
  assert.match(run('web-search').stdout, /braveApiKey ref-ok[\s\S]*bochaApiKey ref-ok/);
  write('agents/example.md', 'model: example/model\n');
  assert.match(run('roles').stdout, /example.md  example\/model/);
  write('agents/example.md', 'model: {{MODEL}}\n');
  assert.equal(run('placeholders').status, 1);
  write('memory/RESIDENT.template.md', 'template');
  assert.equal(run('resident-init').status, 0);
  write('memory/RESIDENT.md', 'user-owned');
  assert.match(run('resident-init').stdout, /not overwritten/);
  assert.equal(fs.readFileSync(path.join(agent, 'memory/RESIDENT.md'), 'utf8'), 'user-owned');
  assert.equal(run('stub-config', { PI_CODING_AGENT_DIR: path.parse(agent).root }).status, 1);
});

test('onnx diagnostics inspect injected Windows System32 files and preserve load errors', () => {
  const attempted = [];
  const require = () => { throw Object.assign(Error('LoadLibrary Win32 126'), { code: 'ERR_DLOPEN_FAILED' }); };
  require.resolve = () => 'binding';
  const probe = (existsSync) => checkOnnx({ agentDir: os.tmpdir(), platform: 'win32', env: { SystemRoot: 'D:\\Windows' }, requireFactory: () => require, existsSync });
  const missing = probe((file) => { attempted.push(file); return path.win32.basename(file) === 'vcruntime140.dll'; });
  assert.equal(missing.ok, false);
  assert.match(missing.detail, /Win32 126/);
  assert.match(missing.detail, /vcruntime140_1.dll, msvcp140.dll/);
  assert.match(missing.detail, /Visual C\+\+ 2015-2022 x64.*https:\/\/aka.ms\/vs\/17\/release\/vc_redist.x64.exe/);
  assert.deepEqual(attempted, ['vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll'].map((name) => path.win32.join('D:\\Windows', 'System32', name)));
  const present = probe(() => true);
  assert.equal(present.ok, false);
  assert.match(present.detail, /files exist in System32/);
  assert.doesNotMatch(present.detail, /Install Microsoft/);
  const defaults = checkOnnx({ agentDir: os.tmpdir(), platform: 'win32', env: {}, requireFactory: () => require, existsSync: (file) => { assert.ok(file.startsWith('C:\\Windows\\System32\\')); return false; } });
  assert.equal(defaults.ok, false);
});

test('onnx Linux missing-package hint differs from a broken installed binding', () => {
  const require = () => { throw Error('binding dependency missing'); };
  require.resolve = () => { throw Object.assign(Error("Cannot find module 'onnxruntime-node'"), { code: 'MODULE_NOT_FOUND' }); };
  const probe = (platform = 'linux') => checkOnnx({ agentDir: os.tmpdir(), platform, requireFactory: () => require });
  assert.match(probe().detail, /ONNXRUNTIME_NODE_INSTALL=skip npm install --include=optional/);
  assert.doesNotMatch(probe('darwin').detail, /ONNXRUNTIME_NODE_INSTALL/);
  require.resolve = () => 'binding';
  const broken = probe();
  assert.equal(broken.ok, false);
  assert.match(broken.detail, /binding dependency missing/);
  assert.doesNotMatch(broken.detail, /ONNXRUNTIME_NODE_INSTALL/);
});

test('deploy-check onnx returns nonzero for a missing or broken package and prints versions on success', (t) => {
  const agent = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-onnx-check-'));
  t.after(() => fs.rmSync(agent, { recursive: true, force: true }));
  const run = () => spawnSync(process.execPath, [script, 'onnx'], { encoding: 'utf8', env: { ...process.env, PI_CODING_AGENT_DIR: agent } });
  const missing = run();
  assert.equal(missing.status, 1);
  if (process.platform === 'linux') assert.match(missing.stderr, /ONNXRUNTIME_NODE_INSTALL=skip/);
  const pkg = path.join(agent, 'npm/node_modules/onnxruntime-node');
  fs.mkdirSync(pkg, { recursive: true });
  fs.writeFileSync(path.join(pkg, 'index.js'), "throw Error('broken native binding');");
  assert.equal(run().status, 1);
  assert.match(run().stderr, /broken native binding/);
  fs.writeFileSync(path.join(pkg, 'index.js'), "exports.env = { versions: { common: 'test', node: 'test' } };");
  const good = run();
  assert.equal(good.status, 0, good.stderr);
  assert.match(good.stdout, /common: 'test', node: 'test'/);
});

test('stub-resident checks every system prompt and refuses absent or user-only fixtures', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-resident-check-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const log = path.join(dir, 'requests.jsonl');
  const marker = 'SYNTHETIC_RESIDENT';
  const write = (messages) => fs.writeFileSync(log, messages.map((content) => JSON.stringify({ messages: content })).join('\n'));
  const run = () => spawnSync(process.execPath, [script, 'stub-resident', log, marker], { encoding: 'utf8' });
  const good = [{ role: 'system', content: '<resident_memory>' + marker + '</resident_memory>' }];
  write([good, good]);
  assert.equal(run().status, 0);
  write([good, [{ role: 'user', content: good[0].content }]]);
  assert.equal(run().status, 1);
  assert.match(run().stderr, /request 2 missing resident_memory/);
  write([[{ role: 'developer', content: '<resident_memory>different fixture</resident_memory>' }]]);
  assert.equal(run().status, 1);
  write([]);
  assert.equal(run().status, 1);
});

const expectedTools = ['ask_user', 'codemode', 'contact_supervisor', 'subagent', 'subagent_supervisor', 'tool_search'];
function stubFixture(t) {
  const agent = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-stub-check-'));
  t.after(() => fs.rmSync(agent, { recursive: true, force: true }));
  const log = path.join(agent, 'stub-requests.jsonl');
  const request = (names) => ({ tools: names.map((name) => ({ type: 'function', function: { name } })), messages: [{ role: 'developer', content: 'stub system prompt' }] });
  return {
    write: (sets) => fs.writeFileSync(log, sets.map((names) => JSON.stringify(request(names))).join('\r\n') + '\r\n'),
    run: (explicit = false) => spawnSync(process.execPath, [script, 'stub-requests', ...(explicit ? [log] : [])], {
      encoding: 'utf8', env: { ...process.env, PI_CODING_AGENT_DIR: explicit ? path.parse(agent).root : agent },
    }),
  };
}

test('stub-requests accepts exactly six direct tools in any order through either log entry point', (t) => {
  const f = stubFixture(t);
  f.write([[...expectedTools].reverse(), expectedTools]);
  for (const explicit of [false, true]) {
    const result = f.run(explicit);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /request 2 actual tools:/);
    assert.ok(result.stdout.includes(JSON.stringify(expectedTools)));
    assert.match(result.stdout, /stub system prompt/);
    assert.equal(result.stderr, '');
  }
});

test('stub-requests rejects missing tools and prints actual, missing and extra sets', (t) => {
  const f = stubFixture(t);
  const actual = expectedTools.filter((name) => name !== 'contact_supervisor');
  f.write([actual]);
  const result = f.run();
  assert.equal(result.status, 1);
  assert.ok(result.stdout.includes('actual tools: ' + JSON.stringify(actual)));
  assert.match(result.stderr, /missing tools: \["contact_supervisor"\]/);
  assert.match(result.stderr, /extra tools: \[\]/);
});

test('stub-requests rejects extra tools even when the count remains six', (t) => {
  const f = stubFixture(t);
  for (const actual of [[...expectedTools, 'read'], [...expectedTools.filter((name) => name !== 'ask_user'), 'read']]) {
    f.write([actual]);
    const result = f.run();
    assert.equal(result.status, 1);
    assert.ok(result.stdout.includes('actual tools: ' + JSON.stringify([...actual].sort())));
    assert.match(result.stderr, /missing tools:/);
    assert.match(result.stderr, /extra tools: \["read"\]/);
  }
});

test('stub-requests rejects empty logs and checks requests after the first', (t) => {
  const f = stubFixture(t);
  f.write([]);
  const empty = f.run();
  assert.equal(empty.status, 1);
  assert.match(empty.stderr, /no captured stub requests/);
  f.write([expectedTools, []]);
  const later = f.run();
  assert.equal(later.status, 1);
  assert.match(later.stdout, /request 2 actual tools: \[\]/);
  assert.ok(later.stderr.includes('request 2 missing tools: ' + JSON.stringify(expectedTools)));
});
