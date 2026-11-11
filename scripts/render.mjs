#!/usr/bin/env node
// Render this package onto a deployment machine.
//
//   node scripts/render.mjs --home "$HOME" --agent-dir "$HOME/.pi/agent"
//   node scripts/render.mjs --home "$HOME" --modules core,memory --apply
//
// Rules that are deliberately conservative:
//   - Dry run by default. Nothing is written without --apply.
//   - An existing target is backed up to <agent-dir>/backups/akis-pi-<stamp>/<mirrored path>
//     before it is replaced, and the difference is printed first.
//   - Unresolved {{PLACEHOLDER}}s do not stop the write, but every one of them is listed as a
//     WARNING: a config with a literal {{MODEL}} in it will not start, and the operator has to
//     see that before running pi.
//   - Files that cannot be merged mechanically (mcp.json) are printed as guidance instead of
//     written. Overwriting a user's MCP registry is not a renderer's decision.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

const ALL_MODULES = ['core', 'memory', 'macos', 'magpie'];

// source (relative to the repository root) -> { target, module }
// target is a function of the resolved paths so placeholders and locations stay in one place.
const PLAN = [
  { from: 'config/settings.json', module: 'core', to: (p) => p.agent('settings.json') },
  { from: 'config/AGENTS.md', module: 'core', to: (p) => p.agent('AGENTS.md') },
  { from: 'config/APPEND_SYSTEM.md', module: 'core', to: (p) => p.agent('APPEND_SYSTEM.md') },
  { from: 'config/compact-tools.json', module: 'core', to: (p) => p.agent('compact-tools.json') },
  { from: 'config/subagent/config.json', module: 'core', to: (p) => p.agent('extensions/subagent/config.json') },
  { from: 'config/agents/*.md', module: 'core', to: (p, name) => p.agent('agents/' + name) },
  { from: 'config/prompts/*.md', module: 'core', to: (p, name) => p.agent('prompts/' + name) },
  { from: 'config/web-search.json', module: 'core', to: (p) => p.home('.pi/web-search.json') },
  { from: 'extensions/rtk.ts', module: 'core', to: (p) => p.agent('extensions/rtk.ts') },
  { from: 'skills/pi-workflow-notes/SKILL.md', module: 'core', to: (p) => p.agent('skills/pi-workflow-notes/SKILL.md') },
  { from: 'modules/memory/magic-context.jsonc', module: 'memory', to: (p) => p.home('.config/cortexkit/magic-context.jsonc') },
  { from: 'modules/memory/resident-memory.ts', module: 'memory', to: (p) => p.agent('extensions/resident-memory.ts') },
  { from: 'modules/memory/RESIDENT.template.md', module: 'memory', to: (p) => p.agent('memory/RESIDENT.template.md') },
  { from: 'modules/macos/herdr-agent-state.ts', module: 'macos', to: (p) => p.agent('extensions/herdr-agent-state.ts') },
  { from: 'modules/macos/ego-gc.ts', module: 'macos', to: (p) => p.agent('extensions/ego-gc.ts') },
  { from: 'modules/macos/pdf-parse/server.py', module: 'macos', to: (p) => p.home('.local/share/pi-pdf-parse/server.py') },
  { from: 'modules/macos/pdf-parse/requirements.txt', module: 'macos', to: (p) => p.home('.local/share/pi-pdf-parse/requirements.txt') },
  { from: 'modules/macos/pdf-parse/com.example.pipdfparse.plist', module: 'macos', to: (p) => p.home('Library/LaunchAgents/com.example.pipdfparse.plist') },
  { from: 'modules/magpie/magpie.ts', module: 'magpie', to: (p) => p.agent('extensions/magpie.ts') },
];

// Printed, never written: these need a human decision or a merge.
const GUIDANCE = [
  {
    from: 'modules/magpie/mcp.json.example',
    module: 'magpie',
    text: 'Merge the two servers into your own mcp.json (do not replace it). Also see modules/magpie/README.md.',
    to: (p) => p.agent('mcp.json'),
  },
  {
    from: 'modules/memory/patches',
    module: 'memory',
    text: 'Apply the patches to a pi-knowledge clone with git am, then npm ci and npm run build (modules/memory/README.md).',
  },
];

const USAGE = [
  'Usage: node scripts/render.mjs --home DIR [options]',
  '',
  '  --home DIR            home directory of this machine (required)',
  '  --agent-dir DIR       Pi agent directory (default: <your-home>/.pi/agent)',
  '  --modules LIST        comma separated subset of: ' + ALL_MODULES.join(','),
  '  --apply               write files (default: dry run)',
  '  --backup-dir DIR      where existing files are preserved (default: <agent-dir>/backups)',
  '  --strict              exit non-zero when a placeholder stays unresolved',
  '  --set KEY=VALUE       fill one placeholder, repeatable (e.g. --set PROVIDER=work)',
  '',
  'Convenience (same as --set):',
  '  --provider NAME --model ID --model-exec ID --model-review ID --model-plan ID',
  '  --model-historian ID --brave-key-ref REF --bocha-key-ref REF',
].join('\n');

function parseArgs(argv) {
  const opts = { apply: false, sets: {}, modules: ['core'], strict: false };
  const takesValue = {
    '--home': (v) => (opts.home = v),
    '--agent-dir': (v) => (opts.agentDir = v),
    '--modules': (v) => (opts.modules = v.split(',').map((s) => s.trim()).filter(Boolean)),
    '--backup-dir': (v) => (opts.backupDir = v),
    '--set': (v) => {
      const index = v.indexOf('=');
      if (index < 1) throw new Error('--set needs KEY=VALUE, got: ' + v);
      opts.sets[v.slice(0, index)] = v.slice(index + 1);
    },
    '--provider': (v) => (opts.sets.PROVIDER = v),
    '--model': (v) => (opts.sets.MODEL = v),
    '--model-exec': (v) => (opts.sets.MODEL_EXEC = v),
    '--model-review': (v) => (opts.sets.MODEL_REVIEW = v),
    '--model-plan': (v) => (opts.sets.MODEL_PLAN = v),
    '--model-historian': (v) => (opts.sets.MODEL_HISTORIAN = v),
    '--brave-key-ref': (v) => (opts.sets.BRAVE_KEY_REF = v),
    '--bocha-key-ref': (v) => (opts.sets.BOCHA_KEY_REF = v),
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') opts.apply = true;
    else if (arg === '--strict') opts.strict = true;
    else if (arg === '--help' || arg === '-h') opts.help = true;
    else if (takesValue[arg]) {
      const value = argv[i + 1];
      if (value === undefined) throw new Error(arg + ' needs a value');
      i += 1;
      takesValue[arg](value);
    } else throw new Error('unknown argument: ' + arg);
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

/** Expand 'dir/*.md' into the actual package files, sorted, so output order is stable. */
function expandSources(from) {
  const star = from.indexOf('*');
  if (star < 0) return [from];
  const dir = path.join(ROOT, path.dirname(from));
  const suffix = from.slice(star + 1);
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((name) => name.endsWith(suffix))
    .sort()
    .map((name) => path.join(path.dirname(from), name));
}

function resolver(values, sets) {
  // values must be plain strings: a path helper here would stringify a function into the config.
  const known = { ...values, ...sets };
  return (text) => {
    const missing = new Set();
    const out = text.replace(/\{\{([A-Z0-9_]+)\}\}/g, (match, key) => {
      const value = known[key];
      if (value === undefined || value === '') {
        missing.add(match);
        return match;
      }
      return value;
    });
    return { text: out, missing: [...missing] };
  };
}

function diffSummary(before, after) {
  if (before === undefined) return ['create'];
  if (before === after) return ['unchanged'];
  const a = before.split('\n');
  const b = after.split('\n');
  let first = 0;
  while (first < a.length && first < b.length && a[first] === b[first]) first += 1;
  let tailA = a.length - 1;
  let tailB = b.length - 1;
  while (tailA > first && tailB > first && a[tailA] === b[tailB]) {
    tailA -= 1;
    tailB -= 1;
  }
  const lines = ['differs from line ' + (first + 1) + ': -' + (tailA - first + 1) + ' +' + (tailB - first + 1)];
  for (const line of a.slice(first, Math.min(tailA + 1, first + 4))) lines.push('  - ' + line.slice(0, 120));
  for (const line of b.slice(first, Math.min(tailB + 1, first + 4))) lines.push('  + ' + line.slice(0, 120));
  return lines;
}

function backup(relFromHome, target, backupRoot) {
  const destination = path.join(backupRoot, relFromHome);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(target, destination);
  return destination;
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
    console.error('--home is required (the renderer must not guess where to write)');
    console.error(USAGE);
    process.exit(2);
  }
  const unknownModules = opts.modules.filter((m) => !ALL_MODULES.includes(m));
  if (unknownModules.length > 0) {
    console.error('unknown module(s): ' + unknownModules.join(', '));
    process.exit(2);
  }

  const home = path.resolve(opts.home);
  const agent = path.resolve(opts.agentDir || path.join(home, '.pi', 'agent'));
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupRoot = path.resolve(opts.backupDir || path.join(agent, 'backups')) + '/akis-pi-' + stamp;
  const paths = {
    home: (...parts) => path.join(home, ...parts),
    agent: (...parts) => path.join(agent, ...parts),
  };
  const resolve = resolver({ HOME: home, AGENT_DIR: agent }, opts.sets);
  const enabled = new Set(opts.modules);

  console.log('akis-pi render');
  console.log('  home       ' + home);
  console.log('  agent dir  ' + agent);
  console.log('  modules    ' + opts.modules.join(', '));
  console.log('  mode       ' + (opts.apply ? 'apply' : 'dry run'));
  console.log('');

  if (enabled.has('memory') && !enabled.has('core')) {
    console.log('WARNING: the memory module assumes the core settings.json is installed too.');
    console.log('');
  }

  const warnings = [];
  const actions = [];

  for (const item of PLAN) {
    if (!enabled.has(item.module)) continue;
    for (const from of expandSources(item.from)) {
      const source = read(path.join(ROOT, from));
      if (source === undefined) {
        warnings.push('missing package file: ' + from);
        continue;
      }
      let text = source;
      if (from === 'config/settings.json' && !enabled.has('memory')) {
      // The memory module supplies pi-knowledge and Magic Context; installing either without
      // the module would leave a package entry pointing at nothing.
        const settings = JSON.parse(source);
        const removed = [];
        settings.packages = (settings.packages || []).filter((entry) => {
          const name = typeof entry === 'string' ? entry : entry.source;
          if (name.indexOf('pi-knowledge') >= 0 || name.indexOf('pi-magic-context') >= 0) {
            removed.push(name);
            return false;
          }
          return true;
        });
        text = JSON.stringify(settings, null, 2) + '\n';
        if (removed.length > 0) console.log('memory module not selected, dropped: ' + removed.join(', ') + '\n');
      }
      const resolved = resolve(text);
      for (const placeholder of resolved.missing) warnings.push(from + ': unresolved ' + placeholder);
      actions.push({ from, target: item.to(paths, path.basename(from)), content: resolved.text });
    }
  }

  for (const action of actions) {
    const before = read(action.target);
    const lines = diffSummary(before, action.content);
    console.log(action.from + '  ->  ' + action.target);
    for (const line of lines) console.log('  ' + line);
  }
  console.log('');

  if (opts.modules.indexOf('magpie') >= 0) {
    for (const guide of GUIDANCE.filter((g) => g.module === 'magpie')) {
      const target = guide.to ? guide.to(paths) : '(manual step)';
      console.log('guidance: ' + guide.from + '  ->  ' + target);
      console.log('  ' + guide.text);
      if (guide.from === 'modules/magpie/mcp.json.example') {
        for (const line of read(path.join(ROOT, guide.from)).split('\n')) console.log('  | ' + line);
      }
    }
    console.log('');
  }
  if (enabled.has('memory')) {
    for (const guide of GUIDANCE.filter((g) => g.module === 'memory')) {
      console.log('guidance: ' + guide.from);
      console.log('  ' + guide.text);
    }
    console.log('');
  }

  if (warnings.length > 0) {
    console.log('WARNINGS (' + warnings.length + '):');
    for (const warning of warnings) console.log('  - ' + warning);
    console.log('');
    console.log('Fill the missing values with --set KEY=VALUE (see DEPLOY.md, "placeholders") and run again.');
    console.log('');
  }

  if (!opts.apply) {
    console.log('Dry run: nothing written. Re-run with --apply.');
    if (opts.strict && warnings.length > 0) process.exit(1);
    return;
  }

  let written = 0;
  const backups = [];
  for (const action of actions) {
    const before = read(action.target);
    if (before === action.content) continue;
    if (before !== undefined) {
      const rel = path.relative(home, action.target);
      backups.push(backup(rel, action.target, backupRoot));
    }
    fs.mkdirSync(path.dirname(action.target), { recursive: true });
    fs.writeFileSync(action.target, action.content, { mode: 0o644 });
    written += 1;
  }

  // Never let MEMORY look like a config file: it is the user's to write.
  const memoryDir = paths.agent('memory');
  if (enabled.has('memory') && fs.existsSync(memoryDir)) {
    const resident = path.join(memoryDir, 'RESIDENT.md');
    if (!fs.existsSync(resident)) console.log('note: ' + resident + ' does not exist yet (that is fine: nothing is injected)');
  }

  console.log('Wrote ' + written + ' file(s).');
  if (backups.length > 0) {
    console.log('Backed up ' + backups.length + ' existing file(s) to ' + backupRoot + ':');
    for (const file of backups) console.log('  ' + file);
  }
  if (opts.strict && warnings.length > 0) process.exit(1);
}

main();
