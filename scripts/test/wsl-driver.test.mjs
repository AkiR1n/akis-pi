import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const script = path.resolve(import.meta.dirname, '../../tests/wsl/run.sh');

test('WSL packages exports CPU install flag before MC and requires deploy-check onnx', { skip: process.platform === 'win32' }, (t) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-wsl-onnx-'));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
  const bin = path.join(tmp, 'bin');
  fs.mkdirSync(bin);
  const installs = path.join(tmp, 'installs');
  fs.writeFileSync(path.join(bin, 'pi'), '#!/bin/sh\nprintf "%s %s %s\\n" "$ONNXRUNTIME_NODE_INSTALL" "$ONNXRUNTIME_NODE_INSTALL_CUDA" "$2" >> "$TEST_INSTALL_LOG"\n', { mode: 0o755 });
  const node = "'" + process.execPath.replaceAll("'", "'\\''") + "'";
  fs.writeFileSync(path.join(bin, 'node'), '#!/bin/sh\nif [ "$2" = onnx ]; then printf "onnx-probed\\n"; exit "$TEST_ONNX_EXIT"; fi\nexec ' + node + ' "$@"\n', { mode: 0o755 });
  const run = (code, modules = 'core,memory') => spawnSync('bash', [script, '--step', 'packages', '--modules', modules, '--out', tmp, '--agent-dir', path.join(tmp, 'agent')], {
    encoding: 'utf8', env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH, TEST_INSTALL_LOG: installs, TEST_ONNX_EXIT: String(code), ONNXRUNTIME_NODE_INSTALL: 'unexpected' },
  });
  assert.equal(run(1).status, 3);
  assert.match(fs.readFileSync(installs, 'utf8'), /skip skip npm:@cortexkit\/pi-magic-context@0\.49\.50/);
  assert.match(JSON.parse(fs.readFileSync(path.join(tmp, 'packages.json'))).error, /deploy-check onnx failed/);
  assert.equal(run(0).status, 0);
  assert.equal(JSON.parse(fs.readFileSync(path.join(tmp, 'packages.json'))).ok, 'true');
  assert.equal(run(1, 'core').status, 0, 'core-only does not require the memory runtime');
});
test('WSL stub copies MC config, isolates stores, and fails missing synthetic resident injection', { skip: process.platform === 'win32' }, (t) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-wsl-stub-'));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
  const bin = path.join(tmp, 'bin');
  const agent = path.join(tmp, 'agent');
  const config = path.join(tmp, 'config');
  fs.mkdirSync(bin);
  fs.mkdirSync(agent);
  fs.mkdirSync(path.join(config, 'cortexkit'), { recursive: true });
  fs.writeFileSync(path.join(config, 'cortexkit/magic-context.jsonc'), '{"syntheticConfig":true}');
  fs.writeFileSync(path.join(agent, 'settings.json'), '{}');
  fs.writeFileSync(path.join(bin, 'pi'), "#!/usr/bin/env node\nconst fs = require('node:fs');\nconst path = require('node:path');\nif (!process.env.XDG_CONFIG_HOME.startsWith(process.env.HOME)) process.exit(1);\nif (!process.env.MAGIC_CONTEXT_STORAGE_DIR.startsWith(process.env.HOME)) process.exit(1);\nif (!JSON.parse(fs.readFileSync(path.join(process.env.XDG_CONFIG_HOME, 'cortexkit/magic-context.jsonc'))).syntheticConfig) process.exit(1);\nconst text = fs.readFileSync(process.env.PI_RESIDENT_MEMORY_FILE, 'utf8').trim();\nconst model = JSON.parse(fs.readFileSync(path.join(process.env.PI_CODING_AGENT_DIR, 'models.json'))).providers.stub;\nfetch(model.baseUrl + '/chat/completions', { method: 'POST', headers: {'content-type':'application/json'}, body: JSON.stringify({messages:[{role:'system',content: process.env.TEST_OMIT_RESIDENT === '1' ? '' : '<resident_memory>' + text + '</resident_memory>'}],tools:['ask_user','codemode','contact_supervisor','subagent','subagent_supervisor','tool_search'].map(name => ({function:{name}}))}) }).then(async response => { await response.text(); console.log('stub-ok'); });\n", { mode: 0o755 });
  const run = (omit) => spawnSync('bash', [script, '--step', 'stub', '--out', tmp, '--agent-dir', agent, '--stub-port', '18997'], {
    encoding: 'utf8', env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH, XDG_CONFIG_HOME: config, TEST_OMIT_RESIDENT: omit },
  });
  assert.equal(run('1').status, 3);
  assert.match(JSON.parse(fs.readFileSync(path.join(tmp, 'stub.json'))).error, /resident/);
  const good = run('0');
  assert.equal(good.status, 0, good.stdout + good.stderr);
  assert.equal(JSON.parse(fs.readFileSync(path.join(tmp, 'stub.json'))).resident_memory, 'true');
});

test('WSL summary fails missing/failed knowledge steps and reports success only for all selected steps', { skip: process.platform === 'win32' }, (t) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-wsl-driver-'));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
  const run = () => spawnSync('bash', [script, '--step', 'summary', '--out', tmp, '--agent-dir', path.join(tmp, 'agent')], { encoding: 'utf8' });
  assert.equal(run().status, 3);
  assert.equal(JSON.parse(fs.readFileSync(path.join(tmp, 'summary.json'))).ok, 'false');
  for (const name of ['prereq', 'render', 'knowledge', 'packages', 'stub', 'doctor']) fs.writeFileSync(path.join(tmp, name + '.json'), JSON.stringify({ ok: 'true' }, null, 2));
  assert.equal(run().status, 0);
  assert.equal(JSON.parse(fs.readFileSync(path.join(tmp, 'summary.json'))).ok, 'true');
  fs.writeFileSync(path.join(tmp, 'knowledge.json'), JSON.stringify({ ok: 'false' }, null, 2));
  assert.equal(run().status, 3);
  const bin = path.join(tmp, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'node'), '#!/bin/sh\nprintf invalid-json\nexit 1\n', { mode: 0o755 });
  const doctor = spawnSync('bash', [script, '--step', 'doctor', '--out', tmp, '--agent-dir', path.join(tmp, 'agent')], { encoding: 'utf8', env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH } });
  assert.equal(doctor.status, 3);
  assert.match(JSON.parse(fs.readFileSync(path.join(tmp, 'doctor.json'))).error, /doctor exited 1/);
});
