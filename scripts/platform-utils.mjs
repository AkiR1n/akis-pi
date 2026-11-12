// Platform policy and read-only path/command resolution. No shell is used to invoke a CLI.
import fs from 'node:fs';
import path from 'node:path';

export const ALL_MODULES = ['core', 'memory', 'macos', 'pdf', 'magpie'];
export const PLATFORMS = ['darwin', 'linux', 'win32', 'wsl'];
export const pathApi = (platform = process.platform) => platform === 'win32' ? path.win32 : path.posix;

export function detectPlatform({ platform = process.platform, env = process.env, readFile = fs.readFileSync } = {}) {
  if (platform !== 'linux') return platform;
  if (env.WSL_DISTRO_NAME) return 'wsl';
  try { if (/microsoft|wsl/i.test(readFile('/proc/version', 'utf8'))) return 'wsl'; } catch { /* non-proc host */ }
  return 'linux';
}

export function validateModules(modules, platform) {
  if (!PLATFORMS.includes(platform)) throw new Error('unsupported platform: ' + platform);
  const unknown = modules.filter((m) => !ALL_MODULES.includes(m));
  if (unknown.length) throw new Error('unknown module(s): ' + unknown.join(', '));
  if (modules.includes('macos') && platform !== 'darwin') throw new Error('macos module requires darwin; select pdf separately on ' + platform);
}

// MC 0.49.50 configHome() uses absolute XDG_CONFIG_HOME or <home>/.config, including Windows.
// pi-web-access 0.47.0 getWebSearchConfigDir() uses explicit agent, XDG, agent, legacy order.
// APPDATA is not an upstream default for either package.
export function deploymentPaths({ home, agentDir, platform = process.platform, env = process.env, exists = fs.existsSync }) {
  const p = pathApi(platform);
  const agent = p.resolve(agentDir || env.PI_CODING_AGENT_DIR || p.join(home, '.pi', 'agent'));
  const configHome = env.XDG_CONFIG_HOME && p.isAbsolute(env.XDG_CONFIG_HOME) ? env.XDG_CONFIG_HOME : p.join(home, '.config');
  const dataHome = env.XDG_DATA_HOME || p.join(home, '.local', 'share');
  const legacy = p.join(home, '.pi', 'web-search.json');
  const agentSearch = p.join(agent, 'web-search.json');
  let webSearch;
  if (agentDir || env.PI_CODING_AGENT_DIR) webSearch = agentSearch;
  else if (env.XDG_CONFIG_HOME) {
    const xdgSearch = p.join(env.XDG_CONFIG_HOME, 'pi', 'web-search.json');
    webSearch = exists(xdgSearch) ? xdgSearch : exists(legacy) ? legacy : xdgSearch;
  } else webSearch = exists(agentSearch) ? agentSearch : exists(legacy) ? legacy : agentSearch;
  return { agent, configHome, dataHome, webSearch, mcConfig: p.join(configHome, 'cortexkit', 'magic-context.jsonc'), pdfDir: p.join(home, '.local', 'share', 'pi-pdf-parse') };
}

// Keep POSIX backup layout compatible. Windows roots are encoded as distinct path segments;
// drive C, drive D, and each UNC server/share have disjoint namespaces.
export function backupRelativePath(target, platform = process.platform) {
  const p = pathApi(platform);
  const absolute = p.resolve(target);
  const root = p.parse(absolute).root;
  if (platform !== 'win32') return absolute.slice(root.length);
  const tail = absolute.slice(root.length).split(/[\\/]+/).filter(Boolean);
  if (/^[A-Za-z]:/.test(root)) return ['drive-' + root[0].toUpperCase(), ...tail].join('/');
  if (root.startsWith('\\\\')) {
    const parts = root.split(/[\\/]+/).filter(Boolean).map(encodeURIComponent);
    return ['unc', ...parts, ...tail].join('/');
  }
  throw new Error('Windows backup target requires a drive or UNC root');
}

export function resolveCommand(command, { platform = process.platform, env = process.env, exists = fs.existsSync, readFile = fs.readFileSync, execPath = process.execPath } = {}) {
  const p = pathApi(platform);
  const directories = String(env.PATH || env.Path || '').split(platform === 'win32' ? ';' : ':').filter(Boolean).map((v) => v.replace(/^"|"$/g, ''));
  const locate = (name) => {
    const explicit = /[\\/]/.test(name) || p.isAbsolute(name);
    const bases = explicit ? [name] : directories.map((dir) => p.join(dir, name));
    const extensions = platform === 'win32' && !p.extname(name) ? ['.exe', '.cmd', ''] : [''];
    return bases.flatMap((base) => extensions.map((ext) => base + ext)).find(exists);
  };
  const file = locate(command);
  if (!file) throw new Error('command not found: ' + command);
  if (/\.[cm]?js$/i.test(file)) return { command: execPath, args: [file] };
  if (platform !== 'win32' || !/\.cmd$/i.test(file)) return { command: file, args: [] };
  const shim = readFile(file, 'utf8').replace(/^\uFEFF/, '');
  // npm cmd-shim emits a quoted %dp0% CLI script followed by %*. Extract data only;
  // arbitrary cmd/bat commands, substitutions and shell arguments are never evaluated.
  const match = shim.match(/"%dp0%[\\/]([^"\r\n]+\.[cm]?js)"\s+%\*/i);
  if (!match || /[%!^&|<>]/.test(match[1])) throw new Error('unsupported Windows command shim: ' + file);
  const script = p.resolve(p.dirname(file), match[1]);
  const localNode = p.join(p.dirname(file), 'node.exe');
  const node = exists(localNode) ? localNode : locate('node.exe') || (/node\.exe$/i.test(execPath) ? execPath : undefined);
  if (!node || !exists(script)) throw new Error('Windows npm shim is missing Node or CLI script: ' + file);
  return { command: node, args: [script] };
}
