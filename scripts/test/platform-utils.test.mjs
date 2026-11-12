import test from 'node:test';
import assert from 'node:assert/strict';
import { detectPlatform, deploymentPaths, backupRelativePath, resolveCommand } from '../platform-utils.mjs';
import { parseJsonc } from '../config-utils.mjs';

test('WSL detection uses environment or proc with a safe non-proc fallback', () => {
  assert.equal(detectPlatform({ platform: 'linux', env: { WSL_DISTRO_NAME: 'Example' } }), 'wsl');
  assert.equal(detectPlatform({ platform: 'linux', env: {}, readFile: () => 'Linux microsoft-standard-WSL2' }), 'wsl');
  assert.equal(detectPlatform({ platform: 'linux', env: {}, readFile: () => { throw Error(); } }), 'linux');
  assert.equal(detectPlatform({ platform: 'darwin', env: { WSL_DISTRO_NAME: 'ignored' } }), 'darwin');
});

test('Windows MC defaults match upstream dot directories and absolute XDG, never APPDATA', () => {
  const home = 'C:\\Profiles\\实验 学生';
  const base = { home, platform: 'win32', env: { APPDATA: 'D:\\Roaming' }, exists: () => false };
  assert.equal(deploymentPaths(base).mcConfig, home + '\\.config\\cortexkit\\magic-context.jsonc');
  assert.equal(deploymentPaths(base).webSearch, home + '\\.pi\\agent\\web-search.json');
  const custom = deploymentPaths({ ...base, env: { XDG_CONFIG_HOME: 'D:\\配置 空间', XDG_DATA_HOME: 'D:\\数据' } });
  assert.equal(custom.mcConfig, 'D:\\配置 空间\\cortexkit\\magic-context.jsonc');
  assert.equal(custom.webSearch, 'D:\\配置 空间\\pi\\web-search.json');
  assert.equal(custom.dataHome, 'D:\\数据');
  assert.equal(deploymentPaths({ ...base, env: { XDG_CONFIG_HOME: 'relative' } }).mcConfig, deploymentPaths(base).mcConfig);
});

test('web-access precedence: explicit agent, XDG existing, legacy, XDG new; default agent then legacy', () => {
  const home = '/profiles/student';
  const base = { home, platform: 'linux', exists: () => true };
  assert.equal(deploymentPaths({ ...base, env: { PI_CODING_AGENT_DIR: '/custom/agent', XDG_CONFIG_HOME: '/xdg' } }).webSearch, '/custom/agent/web-search.json');
  assert.equal(deploymentPaths({ ...base, agentDir: '/arg/agent', env: { PI_CODING_AGENT_DIR: '/env/agent' } }).webSearch, '/arg/agent/web-search.json');
  assert.equal(deploymentPaths({ ...base, env: { XDG_CONFIG_HOME: '/xdg' } }).webSearch, '/xdg/pi/web-search.json');
  assert.equal(deploymentPaths({ ...base, exists: (f) => f === home + '/.pi/web-search.json', env: { XDG_CONFIG_HOME: '/xdg' } }).webSearch, home + '/.pi/web-search.json');
  assert.equal(deploymentPaths({ ...base, exists: () => false, env: { XDG_CONFIG_HOME: '/xdg' } }).webSearch, '/xdg/pi/web-search.json');
  assert.equal(deploymentPaths({ ...base, exists: (f) => f === home + '/.pi/web-search.json', env: {} }).webSearch, home + '/.pi/web-search.json');
});

test('backup roots preserve drives, UNC server/share and Unicode without collision', () => {
  const c = backupRelativePath('C:\\Profiles\\实验 学生\\settings.json', 'win32');
  const d = backupRelativePath('D:\\Profiles\\实验 学生\\settings.json', 'win32');
  assert.equal(c, 'drive-C/Profiles/实验 学生/settings.json');
  assert.equal(d, 'drive-D/Profiles/实验 学生/settings.json');
  assert.equal(backupRelativePath('\\\\server\\share\\目录\\settings.json', 'win32'), 'unc/server/share/目录/settings.json');
  assert.notEqual(backupRelativePath('\\\\server\\other\\目录\\settings.json', 'win32'), backupRelativePath('\\\\server\\share\\目录\\settings.json', 'win32'));
  assert.equal(backupRelativePath('/profiles/student/config.json', 'linux'), 'profiles/student/config.json');
});

test('npm Windows cmd shims resolve to Node + CLI as arguments without a shell', () => {
  const dir = 'C:\\工具 空间';
  const script = dir + '\\node_modules\\@scope\\pi\\dist\\cli.js';
  const files = new Set([dir + '\\pi.cmd', script, 'D:\\Node Runtime\\node.exe']);
  const env = { Path: dir + ';D:\\Node Runtime' };
  const opts = { platform: 'win32', env, exists: (file) => files.has(file), readFile: () => '@ECHO off\r\n"%_prog%" "%dp0%\\node_modules\\@scope\\pi\\dist\\cli.js" %*\r\n' };
  assert.deepEqual(resolveCommand('pi', opts), { command: 'D:\\Node Runtime\\node.exe', args: [script] });
  files.add(dir + '\\node.exe');
  assert.equal(resolveCommand(dir + '\\pi.cmd', opts).command, dir + '\\node.exe');
  assert.throws(() => resolveCommand('pi', { ...opts, readFile: () => 'powershell.exe -Command arbitrary' }), /unsupported Windows command shim/);
  assert.throws(() => resolveCommand('pi', { ...opts, readFile: () => '"%_prog%" "%dp0%\\evil&code.js" %*' }), /unsupported/);
  files.delete(script);
  assert.throws(() => resolveCommand('pi', opts), /missing Node or CLI/);
});

test('UTF-8 BOM and CRLF JSONC preserve Unicode and string comment markers', () => {
  assert.deepEqual(parseJsonc('\uFEFF{\r\n// comment\r\n"目录":"中文 空格", "url":"https://example.invalid",\r\n}'), { 目录: '中文 空格', url: 'https://example.invalid' });
});
