#!/usr/bin/env node
// Deployment checks live in a file so PowerShell 5.1 never has to quote JavaScript for node -e.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { checkOnnx } from './onnx-check.mjs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseJsonc } from './config-utils.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const agent = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent');
const knowledge = path.join(os.homedir(), '.pi', 'vendor', 'pi-knowledge');
const readJson = (file) => parseJsonc(fs.readFileSync(file, 'utf8'));
const writeJson = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
function temporaryAgent() {
  const dir = process.env.PI_CODING_AGENT_DIR;
  if (!dir || !path.resolve(dir).startsWith(path.resolve(os.tmpdir()) + path.sep)) throw Error('requires PI_CODING_AGENT_DIR under the OS temporary directory');
  return dir;
}
const commands = {
  async helper() {
    let helper;
    if (process.platform === 'darwin') {
      const source = path.join(agent, 'npm/node_modules/@injaneity/pi-computer-use/src/platform/macos/helper-path.mjs');
      const { resolveMacosHelperAppPath } = await import(pathToFileURL(source));
      helper = path.join(resolveMacosHelperAppPath(), 'Contents/MacOS/bridge');
    } else if (process.platform === 'linux') {
      helper = process.env.PI_COMPUTER_USE_LINUX_HELPER_PATH || path.join(os.homedir(), '.pi/agent/helpers/pi-computer-use/linux-bridge');
    } else throw Error('Windows: inspect the installed windows-bridge.exe path as documented');
    fs.accessSync(helper, fs.constants.X_OK);
    console.log('helper executable exists:', helper);
  },
  'web-search'() {
    const config = readJson(path.join(agent, 'web-search.json'));
    console.log(Object.keys(config));
    for (const key of ['braveApiKey', 'bochaApiKey']) console.log(key, /^(?:!\S|\$(?:[A-Za-z_]|\{))/.test(config[key] || '') ? 'ref-ok' : 'MISSING-OR-LITERAL');
  },
  roles() {
    const dir = path.join(agent, 'agents');
    for (const name of fs.readdirSync(dir).filter((n) => n.endsWith('.md')).sort()) {
      const match = fs.readFileSync(path.join(dir, name), 'utf8').match(/^model:\s*(.+)$/m);
      console.log(name + '  ' + (match ? match[1].trim() : '(no model line)'));
    }
  },
  placeholders() {
    let hits = 0;
    for (const sub of ['agents', 'prompts']) {
      const dir = path.join(agent, sub);
      if (!fs.existsSync(dir)) continue;
      for (const name of fs.readdirSync(dir)) {
        const matches = fs.readFileSync(path.join(dir, name), 'utf8').match(/{{[A-Z0-9_]+}}/g);
        if (matches) { hits++; console.log(sub + '/' + name + ': ' + matches.join(' ')); }
      }
    }
    if (!hits) console.log('no placeholders');
    else process.exitCode = 1;
  },
  'mc-version'() { console.log(readJson(path.join(agent, 'npm/node_modules/@cortexkit/pi-magic-context/package.json')).version); },
  onnx() {
    const result = checkOnnx({ agentDir: agent });
    if (!result.ok) throw Error(result.detail);
    console.log(result.versions);
  },
  'resident-init'() {
    const dst = path.join(agent, 'memory/RESIDENT.md');
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    try { fs.copyFileSync(path.join(agent, 'memory/RESIDENT.template.md'), dst, fs.constants.COPYFILE_EXCL); console.log('created: ' + dst); }
    catch (error) { if (error.code !== 'EEXIST') throw error; console.log('exists: ' + dst + ' -- not overwritten'); }
  },
  'apply-patches'() {
    for (const name of fs.readdirSync(path.join(repo, 'modules/memory/patches')).filter((n) => n.endsWith('.patch')).sort()) {
      execFileSync('git', ['am', path.join(repo, 'modules/memory/patches', name)], { stdio: 'inherit' });
      console.log('applied ' + name);
    }
  },
  'knowledge-version'() { console.log(readJson(path.join(knowledge, 'package.json')).version); fs.accessSync(path.join(knowledge, 'dist/index.js')); },
  backups() {
    const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(path.join(dir, e.name)) : e.name === 'settings.json' ? [path.join(dir, e.name)] : []);
    const dir = path.join(agent, 'backups');
    for (const file of fs.existsSync(dir) ? walk(dir) : []) console.log(file);
  },
  'stub-init'() {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'akis-pi-stub-'));
    const dir = path.join(home, '.pi/agent');
    fs.mkdirSync(dir, { recursive: true });
    console.log('temporary home: ' + home); console.log('temporary agent: ' + dir);
  },
  'stub-config'() {
    const file = path.join(temporaryAgent(), 'settings.json');
    const settings = readJson(file);
    settings.defaultProvider = 'stub'; settings.defaultModel = 'stub-model'; settings.enabledModels = ['stub/stub-model'];
    writeJson(file, settings);
  },
  'stub-requests'() {
    const file = process.argv[3] || path.join(temporaryAgent(), 'stub-requests.jsonl');
    const rows = fs.readFileSync(file, 'utf8').split(/\r?\n/).filter((line) => line.trim()).map(JSON.parse);
    if (!rows.length) throw Error('no captured stub requests');
    const expected = ['ask_user', 'codemode', 'contact_supervisor', 'subagent', 'subagent_supervisor', 'tool_search'];
    for (const [index, row] of rows.entries()) {
      const actual = [...new Set((row.tools || []).map((t) => t.function?.name ?? null))].sort();
      const missing = expected.filter((name) => !actual.includes(name));
      const extra = actual.filter((name) => !expected.includes(name));
      console.log('request ' + (index + 1) + ' actual tools: ' + JSON.stringify(actual));
      if (missing.length || extra.length) {
        console.error('request ' + (index + 1) + ' missing tools: ' + JSON.stringify(missing));
        console.error('request ' + (index + 1) + ' extra tools: ' + JSON.stringify(extra));
        process.exitCode = 1;
      }
      console.log((row.messages || []).filter((m) => ['system', 'developer'].includes(m.role)).map((m) => m.content).join('\n'));
    }
  },
  'stub-resident'() {
    const file = process.argv[3] || path.join(temporaryAgent(), 'stub-requests.jsonl');
    const marker = process.argv[4];
    const rows = fs.readFileSync(file, 'utf8').split(/\r?\n/).filter((line) => line.trim()).map(JSON.parse);
    if (!rows.length) throw Error('no captured stub requests');
    for (const [index, row] of rows.entries()) {
      const system = (row.messages || []).filter((m) => ['system', 'developer'].includes(m.role)).map((m) => m.content).join('\n');
      if (!system.includes('<resident_memory>') || (marker && !system.includes(marker))) {
        throw Error('request ' + (index + 1) + ' missing resident_memory' + (marker ? ' synthetic marker' : ''));
      }
    }
    console.log('resident_memory present in all ' + rows.length + ' requests');
  },
};
try {
  const command = commands[process.argv[2]];
  if (!command) throw Error('Choose a deployment check: ' + Object.keys(commands).join(', '));
  await command();
} catch (error) { console.error(error.message); process.exitCode = 1; }
