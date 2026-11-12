#!/usr/bin/env node
// Portable self-check for an akis-pi deployment.
//
//   node scripts/doctor.mjs --home <your-home>
//   node scripts/doctor.mjs --home <your-home> --modules core,memory
//
// It answers one question: does this machine actually run the configuration that DEPLOY.md
// describes? Every check is read-only. Nothing here installs, downloads or edits anything, which
// is why it never calls 'pi list': on Pi 1.5.2 that command installs missing packages.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { parseJsonc, versionStatus } from './config-utils.mjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { detectPlatform, validateModules, deploymentPaths, resolveCommand } from './platform-utils.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const REQUIRED_CORE = [
  'settings.json',
  'AGENTS.md',
  'APPEND_SYSTEM.md',
  'compact-tools.json',
  'extensions/rtk.ts',
  'extensions/subagent/config.json',
  'prompts/delegate.md',
  'skills/pi-workflow-notes/SKILL.md',
];
const REQUIRED_MEMORY = ['extensions/resident-memory.ts'];
const REQUIRED_MACOS = ['extensions/ego-gc.ts', 'extensions/herdr-agent-state.ts'];
const REQUIRED_MAGPIE = ['extensions/magpie.ts'];

// Files whose content is checked for unresolved placeholders: a literal {{MODEL}} in a deployed
// config is not a style issue, it is a Pi that will not start.
const PLACEHOLDER_TARGETS = ['settings.json', 'AGENTS.md', 'APPEND_SYSTEM.md', 'extensions/subagent/config.json'];

const USAGE = [
  'Usage: node scripts/doctor.mjs --home DIR [options]',
  '',
  '  --home DIR          home directory of this machine (required)',
  '  --agent-dir DIR     Pi agent directory (default: <your-home>/.pi/agent)',
  '  --modules LIST      modules expected to be installed (default: core)',
  '  --mc-profile FILE   extra Magic Context JSONC config file to compare, repeatable',
  '  --platform NAME     platform policy override (default: auto)',
  '  --pi-command FILE   Pi executable or Node CLI script (default: pi on PATH)',
  '  --json              print the result as JSON',
].join('\n');

function parseArgs(argv) {
  const opts = { modules: ['core'], mcProfiles: [], json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = () => {
      const next = argv[i + 1];
      if (next === undefined) throw new Error(arg + ' needs a value');
      i += 1;
      return next;
    };
    if (arg === '--home') opts.home = value();
    else if (arg === '--agent-dir') opts.agentDir = value();
    else if (arg === '--modules') opts.modules = value().split(',').map((s) => s.trim()).filter(Boolean);
    else if (arg === '--mc-profile') opts.mcProfiles.push(value());
    else if (arg === '--platform') opts.platform = value();
    else if (arg === '--pi-command') opts.piCommand = value();
    else if (arg === '--json') opts.json = true;
    else if (arg === '--help' || arg === '-h') opts.help = true;
    else throw new Error('unknown argument: ' + arg);
  }
  return opts;
}

const read = (file) => {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return undefined;
  }
};

const exists = (file) => fs.existsSync(file);

function parseSource(source) {
  if (typeof source !== 'string') return { kind: 'unknown', name: String(source) };
  if (source.startsWith('npm:')) {
    const rest = source.slice(4);
    const cut = rest.startsWith('@') ? rest.indexOf('@', rest.indexOf('/') + 1) : rest.lastIndexOf('@');
    return cut > 0
      ? { kind: 'npm', name: rest.slice(0, cut), version: rest.slice(cut + 1) }
      : { kind: 'npm', name: rest, version: undefined };
  }
  if (source.startsWith('git:')) return { kind: 'git', name: source };
  return { kind: 'path', name: source };
}

function installedVersion(agentDir, name) {
  const text = read(path.join(agentDir, 'npm', 'node_modules', name, 'package.json'));
  if (text === undefined) return undefined;
  try {
    return parseJsonc(text).version;
  } catch {
    return undefined;
  }
}

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    console.error(USAGE);
    process.exit(2);
  }
  if (opts.help) {
    console.log(USAGE);
    return;
  }
  if (!opts.home) {
    console.error('--home is required');
    console.error(USAGE);
    process.exit(2);
  }

  const platform = opts.platform && opts.platform !== 'auto' ? opts.platform : detectPlatform();
  try { validateModules(opts.modules, platform); }
  catch (error) { console.error(error.message); process.exit(2); }

  const home = path.resolve(opts.home);
  const locations = deploymentPaths({ home, agentDir: opts.agentDir });
  const agent = locations.agent;
  const enabled = new Set(opts.modules);
  const results = [];
  const add = (status, label, detail) => results.push({ status, label, detail: detail || '' });
  const guard = (fn) => {
    try {
      fn();
    } catch (error) {
      add('FAIL', 'doctor crashed in a check', String(error && error.message ? error.message : error));
    }
  };

  const manifestText = read(path.join(ROOT, 'manifest.json'));
  let manifest = {};
  guard(() => {
    manifest = parseJsonc(manifestText);
    add('PASS', 'manifest.json readable', manifest.components.length + ' components, tested on ' + manifest.verifiedOn.os);
  });

  add('PASS', 'platform', platform + '-' + process.arch);
  for (const component of manifest.components || []) {
    if (!enabled.has(component.module)) continue;
    if (!(component.verified || []).includes(platform + '-' + process.arch)) add('WARN', 'platform verification ' + component.id, 'not verified on ' + platform + '-' + process.arch + (platform === 'win32' ? '; native Windows is experimental; WSL2 core+memory is recommended' : ''));
  }
  const invoke = (command, args, options) => {
    const resolved = resolveCommand(command);
    return execFileSync(resolved.command, [...resolved.args, ...args], options);
  };

  // 1. Pi binary and version
  guard(() => {
    const expected = (manifest.components || []).find((c) => c.id === 'pi');
    let actual;
    try {
      actual = invoke(opts.piCommand || 'pi', ['--version'], { encoding: 'utf8', timeout: 30000 }).trim();
    } catch {
      add('FAIL', 'pi binary', 'pi --version failed; is Pi installed and on PATH?');
      return;
    }
    if (!expected) {
      add('WARN', 'pi version', actual + ' (manifest has no pi component)');
      return;
    }
    add(versionStatus(actual, expected.version, true), 'pi version', 'installed ' + actual + ', manifest ' + expected.version + ' (major drift FAIL, other drift WARN)');
  });

  // 2. Package resolution and manifest version comparison (never pi list)
  const settingsText = read(path.join(agent, 'settings.json'));
  let settings = {};
  guard(() => {
    if (settingsText === undefined) {
      add('FAIL', 'settings.json', 'missing at ' + path.join(agent, 'settings.json'));
      return;
    }
    settings = parseJsonc(settingsText);
    add('PASS', 'settings.json', 'parsed');
  });

  const unresolvedPackages = [];
  guard(() => {
    if (!settings.packages) {
      add('WARN', 'packages', 'settings.json has no packages list');
      return;
    }
    let checked = 0;
    for (const entry of settings.packages) {
      const source = typeof entry === 'string' ? entry : entry.source;
      const parsed = parseSource(source);
      checked += 1;
      if (parsed.kind === 'npm') {
        const version = installedVersion(agent, parsed.name);
        if (version === undefined) unresolvedPackages.push(parsed.name + ' (not installed)');
        else if (parsed.version && version !== parsed.version) add('WARN', 'settings package version', parsed.name + ': installed ' + version + ', settings ' + parsed.version);
      } else {
        const target = source.replace('{{HOME}}', home).replace('{{AGENT_DIR}}', agent);
        if (!exists(target)) unresolvedPackages.push(source + ' (path missing)');
      }
    }
    if (unresolvedPackages.length === 0) add('PASS', 'packages resolve on disk', checked + ' entries');
    else add('FAIL', 'packages resolve on disk', unresolvedPackages.join('; '));
  });

  guard(() => {
    // Inspect every selected npm component, even if settings and disk drift together.
    for (const component of manifest.components || []) {
      if (!enabled.has(component.module) || component.id === 'pi' || !component.source.startsWith('npm:')) continue;
      const parsed = parseSource(component.source);
      const actual = installedVersion(agent, parsed.name);
      add(actual ? versionStatus(actual, component.version, component.id === 'pi-magic-context') : 'FAIL',
        'manifest version ' + component.id, 'installed ' + (actual || 'missing') + ', manifest ' + component.version + (actual ? '' : '; install in DEPLOY.md step 5 (memory: step 9)'));
    }
  });

  guard(() => {
    try {
      const version = invoke('rtk', ['--version'], { encoding: 'utf8', timeout: 5000 }).trim();
      invoke('rtk', ['rewrite', '--help'], { stdio: 'pipe', timeout: 5000 });
      add('PASS', 'rtk rewrite', version);
    } catch { add('WARN', 'rtk rewrite', 'rtk missing or rewrite unavailable; install/check in DEPLOY.md step 1'); }
  });

  // 3. Required files for the selected modules
  for (const [module, files] of [
    ['core', REQUIRED_CORE],
    ['memory', REQUIRED_MEMORY],
    ['macos', REQUIRED_MACOS],
    ['magpie', REQUIRED_MAGPIE],
  ]) {
    if (!enabled.has(module)) continue;
    guard(() => {
      const missing = files.filter((rel) => !exists(path.join(agent, rel)));
      if (module === 'core') {
        const agentsDir = path.join(agent, 'agents');
        const agentFiles = exists(agentsDir) ? fs.readdirSync(agentsDir).filter((name) => name.endsWith('.md')) : [];
        if (agentFiles.length === 0) missing.push('agents/*.md');
        if (!exists(locations.webSearch)) missing.push(locations.webSearch);
      }
      if (missing.length === 0) add('PASS', module + ' files', files.length + ' checked');
      else add('FAIL', module + ' files', 'missing: ' + missing.join(', '));
    });
  }

  // 4. No unresolved placeholders in deployed config
  guard(() => {
    const offenders = [];
    const targets = [...PLACEHOLDER_TARGETS.map((rel) => path.join(agent, rel)), path.join(home, '.pi/web-search.json'), locations.webSearch, path.join(agent, 'web-search.json'), locations.mcConfig, ...opts.mcProfiles];
    const profileRoot = path.join(agent, 'mc-profiles');
    for (const name of exists(profileRoot) ? fs.readdirSync(profileRoot) : []) targets.push(path.join(profileRoot, name, 'xdg/cortexkit/magic-context.jsonc'));
    for (const rel of targets) {
      const text = read(rel);
      if (text === undefined) continue;
      const found = text.match(/\{\{[A-Z0-9_]+\}\}/g);
      if (found) offenders.push(rel + ': ' + [...new Set(found)].join(' '));
    }
    for (const name of exists(path.join(agent, 'agents')) ? fs.readdirSync(path.join(agent, 'agents')) : []) {
      if (!name.endsWith('.md')) continue;
      const found = (read(path.join(agent, 'agents', name)) || '').match(/\{\{[A-Z0-9_]+\}\}/g);
      if (found) offenders.push('agents/' + name + ': ' + [...new Set(found)].join(' '));
    }
    if (offenders.length === 0) add('PASS', 'placeholders resolved', targets.filter(exists).length + ' files checked');
    else add('FAIL', 'placeholders resolved', offenders.join('; '));
  });

  // 4b. Subagent role definitions: no pinned models, child-only extensions must exist after render
  guard(() => {
    const agentsDir = path.join(agent, 'agents');
    const names = exists(agentsDir) ? fs.readdirSync(agentsDir).filter((name) => name.endsWith('.md')) : [];
    const problems = [];
    for (const name of names) {
      const text = read(path.join(agentsDir, name)) ?? '';
      if (/^model:\s*\S/m.test(text)) problems.push('agents/' + name + ': pins a model (tiers belong in settings.subagents)');
      const match = text.match(/^subagentOnlyExtensions:(.*)$/m);
      if (!match) continue;
      for (const raw of match[1].split(',').map((value) => value.trim()).filter(Boolean)) {
        const target = raw.replace(/^["']|["']$/g, '');
        if (!target.startsWith('/')) problems.push('agents/' + name + ': extension path is not absolute after render: ' + target);
        else if (!exists(target)) problems.push('agents/' + name + ': extension missing: ' + target);
      }
    }
    if (problems.length === 0) add('PASS', 'subagent roles', names.length + ' role(s) checked');
    else add('FAIL', 'subagent roles', problems.join('; '));
  });

  // Resolve environment credentials once; never invoke arbitrary credential commands.
  // Only status is reported, including references in models.json.
  guard(() => {
    const cache = new Map();
    const walk = (value, prefix) => {
      if (!value || typeof value !== 'object') return;
      for (const [key, child] of Object.entries(value)) {
        if (/apikey$/i.test(key) && typeof child === 'string') {
          const variable = /^\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})$/.exec(child);
          if (variable) {
            const name = variable[1] || variable[2];
            if (!cache.has(name)) cache.set(name, Boolean(process.env[name]?.trim()));
            add(cache.get(name) ? 'PASS' : 'WARN', 'credential ' + prefix + '.' + key, cache.get(name) ? 'ok' : 'missing');
          } else if (child.startsWith('!')) add('WARN', 'credential ' + prefix + '.' + key, 'command reference not evaluated');
          else add('FAIL', 'credential ' + prefix + '.' + key, 'missing or invalid reference (value withheld)');
        }
        walk(child, prefix + '.' + key);
      }
    };
    for (const file of [path.join(agent, 'settings.json'), locations.webSearch, path.join(agent, 'models.json')]) {
      const text = read(file);
      if (text !== undefined) walk(parseJsonc(text), path.basename(file));
    }
  });

  // A rendered config must contain values, never the source text of the renderer. This catches the
  // class of bug where a helper function is substituted into a path slot instead of its result.
  guard(() => {
    const suspicious = [];
    for (const rel of ['settings.json', 'extensions/subagent/config.json']) {
      const text = read(path.join(agent, rel));
      if (text === undefined) continue;
      for (const line of text.split('\n')) {
        if (line.includes('=>') || line.includes('function ')) suspicious.push(rel + ': ' + line.trim().slice(0, 80));
      }
    }
    if (suspicious.length === 0) add('PASS', 'no code where a value belongs', '2 files checked');
    else add('FAIL', 'no code where a value belongs', suspicious.join(' | '));
  });

  // 5. codemode mode
  guard(() => {
    const mode = settings.codemode && settings.codemode.mode;
    if (mode === 'only') add('PASS', 'codemode.mode', 'only (the tradeoff is in docs/decisions.md)');
    else add('WARN', 'codemode.mode', 'current ' + (mode || 'unset (default on)') + '; this package is built for only');
  });

  // 6. Magic Context: values and multi-profile consistency
  if (enabled.has('memory')) {
    guard(() => {
      // Isolate native loading; no install, download or inference is performed.
      try {
        const versions = execFileSync(process.execPath, [path.join(ROOT, 'scripts/deploy-check.mjs'), 'onnx'], {
          encoding: 'utf8', timeout: 30000, stdio: 'pipe',
          env: { ...process.env, PI_CODING_AGENT_DIR: agent },
        }).trim();
        add('PASS', 'onnxruntime-node load', versions);
      } catch (error) {
        add('FAIL', 'onnxruntime-node load', String(error.stderr || error.message).trim());
      }
    });

    guard(() => {
      const globalConfig = locations.mcConfig;
      if (!exists(globalConfig)) {
        add('FAIL', 'magic-context config', 'missing ' + globalConfig);
        return;
      }
      const profiles = opts.mcProfiles.slice();
      const profileRoot = path.join(agent, 'mc-profiles');
      if (exists(profileRoot)) {
        for (const name of fs.readdirSync(profileRoot)) {
          const candidate = path.join(profileRoot, name, 'xdg', 'cortexkit', 'magic-context.jsonc');
          if (exists(candidate)) profiles.push(candidate);
        }
      }
      const files = [globalConfig, ...profiles];
      const pinned = [
        ['execute_threshold_tokens.default', (c) => c.execute_threshold_tokens && c.execute_threshold_tokens.default, 400000],
        ['memory.injection_budget_tokens', (c) => c.memory && c.memory.injection_budget_tokens, 3000],
        ['historian_timeout_ms', (c) => c.historian_timeout_ms, 600000],
      ];
      const problems = [];
      for (const file of files) {
        const text = read(file);
        let config;
        try {
          config = parseJsonc(text);
        } catch (error) {
          problems.push(path.basename(path.dirname(path.dirname(path.dirname(file)))) + ': unparsable');
          continue;
        }
        for (const [label, get, expected] of pinned) {
          const actual = get(config);
          if (actual !== expected) problems.push(label + ' = ' + actual + ' (expected ' + expected + ')');
        }
      }
      if (problems.length === 0) {
        add('PASS', 'magic context parameters', files.length + ' config file(s), 3 pinned values each');
        if (files.length > 1) add('PASS', 'magic context consistency', files.length + ' profiles agree');
        else add('WARN', 'magic context consistency', 'only the global config exists; nothing else to compare (fine for a single entry point)');
      } else {
        add('FAIL', 'magic context parameters', problems.join('; '));
      }
    });

    guard(() => {
      const packageJson = read(path.join(agent, 'npm', 'node_modules', '@cortexkit', 'pi-magic-context', 'package.json'));
      if (packageJson === undefined) {
        add('WARN', 'magic context package', 'not installed under the agent dir yet');
        return;
      }
      const version = parseJsonc(packageJson).version;
      const expected = manifest.components.find((c) => c.id === 'pi-magic-context')?.version;
      add(expected ? versionStatus(version, expected, true) : 'WARN', 'magic context package', 'installed ' + version + ', manifest ' + (expected || 'missing'));
    });

    guard(() => {
      const resident = path.join(agent, 'memory', 'RESIDENT.md');
      if (!exists(resident)) add('WARN', 'resident memory', 'no RESIDENT.md; nothing is injected (fine until you write one)');
      else add('PASS', 'resident memory', read(resident).length + ' chars in RESIDENT.md');
    });
  }

  // 7. Optional module status
  guard(() => {
    const mcp = read(path.join(agent, 'mcp.json'));
    const hasMagpie = mcp !== undefined && mcp.indexOf('magpie') >= 0;
    if (enabled.has('magpie')) {
      if (mcp === undefined) add('FAIL', 'magpie mcp', 'mcp.json missing');
      else if (!hasMagpie) add('WARN', 'magpie mcp', 'no magpie server in mcp.json (see modules/magpie/README.md)');
      else add('PASS', 'magpie mcp', 'magpie server entries present');
    } else if (hasMagpie) {
      add('WARN', 'magpie mcp', 'mcp.json mentions magpie but the module is not selected; APPEND_SYSTEM.md already marks those tools as optional');
    } else {
      add('PASS', 'magpie mcp', 'not selected, not configured');
    }
  });

  guard(() => {
    if (!enabled.has('macos')) {
      add('PASS', 'macos module', 'not selected');
      return;
    }
    const notes = [];
    if (!exists(path.join(home, '.local', 'bin', 'ego-gc')) && !exists(path.join(home, '.local', 'bin', 'ego-browser'))) {
      notes.push('ego-browser CLI not found in ~/.local/bin (ego-gc disables itself)');
    }
    if (notes.length === 0) add('PASS', 'macos module', 'ego CLI present');
    else add('WARN', 'macos module', notes.join('; '));
  });

  if (enabled.has('pdf')) guard(() => {
    const required = [path.join(locations.pdfDir, 'server.py'), path.join(locations.pdfDir, 'requirements.txt')];
    if (platform === 'darwin') required.push(path.join(home, 'Library/LaunchAgents/com.example.pipdfparse.plist'));
    if (platform === 'linux' || platform === 'wsl') required.push(path.join(locations.configHome, 'systemd/user/pi-pdf-parse.service'));
    const missing = required.filter((file) => !exists(file));
    add(missing.length ? 'FAIL' : 'PASS', 'pdf files', missing.length ? 'missing: ' + missing.join(', ') : 'rendered files present; runtime health and service startup require separate validation');
    if (platform === 'win32') add('WARN', 'pdf scheduled task', 'configure and verify the login task in modules/pdf/README.md');
  });

  // Output
  const counts = { PASS: 0, WARN: 0, FAIL: 0 };
  for (const result of results) counts[result.status] += 1;
  if (opts.json) {
    console.log(JSON.stringify({ platform, arch: process.arch, counts, results }, null, 2));
  } else {
    console.log('akis-pi doctor - home ' + home);
    console.log('               agent dir ' + agent);
    console.log('               modules ' + opts.modules.join(', '));
    console.log('');
    for (const result of results) {
      console.log(result.status + '  ' + result.label + (result.detail ? '  ' + result.detail : ''));
    }
    console.log('');
    console.log(counts.PASS + ' PASS / ' + counts.WARN + ' WARN / ' + counts.FAIL + ' FAIL');
    if (counts.FAIL > 0) {
      console.log('');
      console.log('FAIL means the deployment does not match DEPLOY.md. Fix those before trusting the setup.');
    }
  }
  if (counts.FAIL > 0) process.exit(1);
}

main();
