#!/usr/bin/env python3
"""Isolated exit regression; no retries. Retains homes/databases for diagnosis.

Use only a disposable deployment. --config default reproduces the old driver's
missing MC config; deployed copies its rendered MC config into each isolated HOME.
The four variants omit packages only for diagnosis; memory keeps all functionality.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import time

EXPECTED = sorted(['ask_user', 'codemode', 'contact_supervisor', 'subagent', 'subagent_supervisor', 'tool_search'])
PROMPTS = [('smoke', 'hi'), ('roles', 'delegate nothing; list the subagent roles you can use'), ('tools', 'answer with the number of tools you can call directly')]
MARKER = 'AKIS_STUB_RESIDENT_SENTINEL'


def proc_link(pid, name):
    """Resolve /proc/<pid>/<name>; '' when the process is gone or the entry is unreadable."""
    try:
        return os.readlink('/proc/' + str(pid) + '/' + name)
    except OSError:
        return ''


def node_identity(env):
    """Which node the probe's PATH resolves to: the version Pi must actually run on."""
    info = {'version': '', 'bin': shutil.which('node', path=env.get('PATH', '')) or '', 'realpath': ''}
    if not info['bin']:
        return info
    info['realpath'] = os.path.realpath(info['bin'])
    try:
        info['version'] = subprocess.run(['node', '-p', 'process.version'], capture_output=True, text=True, env=env, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return info


def native_maps(pid):
    """Sample main process and descendants on Linux; an empty sample is not proof of absence."""
    found = set()
    todo = [pid]
    while todo:
        current = todo.pop()
        try:
            for line in Path('/proc', str(current), 'maps').read_text().splitlines():
                if '.node' in line:
                    found.add(line.split()[-1])
            for task in Path('/proc', str(current), 'task').iterdir():
                todo.extend(map(int, (task / 'children').read_text().split()))
        except (OSError, ValueError):
            pass
    return found


def integrity(home):
    result = []
    for file in sorted(home.rglob('*.db')) + sorted(home.rglob('*.sqlite')):
        try:
            with sqlite3.connect(file.as_uri() + '?mode=ro', uri=True) as db:
                rows = [r[0] for r in db.execute('PRAGMA integrity_check')]
                tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
            result.append({'file': str(file.relative_to(home)), 'integrity': rows, 'tables': tables})
        except sqlite3.Error as error:
            result.append({'file': str(file.relative_to(home)), 'error': str(error)})
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', type=Path, required=True)
    p.add_argument('--agent-dir', type=Path, required=True)
    p.add_argument('--mc-config', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--pi', default='pi')
    p.add_argument('--rounds', type=int, default=20)
    p.add_argument('--variants', default='memory')
    p.add_argument('--config', choices=['default', 'deployed'], default='deployed')
    p.add_argument('--timeout', type=float, default=90)
    args = p.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    results = []
    node = node_identity(dict(os.environ))
    print('node', node['version'], node['realpath'], flush=True)
    (args.out / 'node-identity.json').write_text(json.dumps(node, indent=2) + '\n')
    for variant in args.variants.split(','):
        if variant not in ['core', 'mc', 'knowledge', 'memory']:
            p.error('unknown variant: ' + variant)
        for round_number in range(1, args.rounds + 1):
            folder = args.out / (variant + '-' + str(round_number).zfill(2))
            home = folder / 'home'
            agent = home / '.pi/agent'
            agent.mkdir(parents=True)
            for name in ['settings.json', 'AGENTS.md', 'APPEND_SYSTEM.md', 'compact-tools.json']:
                if (args.agent_dir / name).is_file():
                    shutil.copy2(args.agent_dir / name, agent / name)
            for name in ['agents', 'prompts', 'extensions', 'skills']:
                if (args.agent_dir / name).is_dir():
                    shutil.copytree(args.agent_dir / name, agent / name)
            (agent / 'npm').symlink_to(args.agent_dir / 'npm', target_is_directory=True)
            settings = json.loads((agent / 'settings.json').read_text())
            def keep(package):
                source = package if isinstance(package, str) else package['source']
                return not (('pi-magic-context' in source and variant not in ['mc', 'memory']) or ('pi-knowledge' in source and variant not in ['knowledge', 'memory']))
            settings['packages'] = [pkg for pkg in settings['packages'] if keep(pkg)]
            (agent / 'settings.json').write_text(json.dumps(settings))
            if variant != 'memory':
                (agent / 'extensions/resident-memory.ts').unlink(missing_ok=True)
            (agent / 'memory').mkdir(exist_ok=True)
            (agent / 'memory/RESIDENT.md').write_text(MARKER + '\n')
            config_home = home / '.config'
            if args.config == 'deployed' and variant in ['mc', 'memory']:
                (config_home / 'cortexkit').mkdir(parents=True)
                shutil.copy2(args.mc_config, config_home / 'cortexkit/magic-context.jsonc')
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            model = {'id': 'stub-model', 'name': 'Stub', 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 200000, 'maxTokens': 1000}
            (agent / 'models.json').write_text(json.dumps({'providers': {'stub': {'baseUrl': 'http://127.0.0.1:' + str(port) + '/v1', 'api': 'openai-completions', 'apiKey': 'dummy', 'models': [model]}}}))
            # Do not inherit the caller's child-agent flags, log paths or stores.
            clean_env = {k: v for k, v in os.environ.items() if not k.startswith(('PI_', 'MAGIC_CONTEXT_', 'HERDR_'))}
            env = {**clean_env, 'HOME': str(home), 'USERPROFILE': str(home), 'PI_CODING_AGENT_DIR': str(agent), 'XDG_CONFIG_HOME': str(config_home), 'XDG_DATA_HOME': str(home / '.local/share'), 'MAGIC_CONTEXT_STORAGE_DIR': str(home / 'mc-store'), 'MAGIC_CONTEXT_LOG_PATH': str(folder / 'mc.log'), 'PI_RESIDENT_MEMORY_FILE': str(agent / 'memory/RESIDENT.md'), 'PI_RESIDENT_MEMORY_OFF': '0'}
            log = folder / 'requests.jsonl'
            runs = []
            native = set()
            round_exes = set()
            with (folder / 'stub.txt').open('w') as output:
                server = subprocess.Popen(['node', str(args.repo / 'scripts/stub-provider.mjs'), '--port', str(port), '--log', str(log)], stdout=output, stderr=subprocess.STDOUT, env=env)
                try:
                    deadline = time.monotonic() + 10
                    while True:
                        try:
                            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                raise RuntimeError('stub failed to start')
                            time.sleep(.05)
                    for label, prompt in PROMPTS:
                        start = time.monotonic()
                        with (folder / (label + '.stdout')).open('w') as stdout, (folder / (label + '.stderr')).open('w') as stderr:
                            proc = subprocess.Popen([args.pi, '--provider', 'stub', '--model', 'stub-model', '--print', '--no-session', prompt], cwd=folder, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
                            timed_out = False
                            run_exes = set()
                            while proc.poll() is None:
                                native.update(native_maps(proc.pid))
                                exe = proc_link(proc.pid, 'exe')
                                if exe:
                                    run_exes.add(exe)
                                    round_exes.add(exe)
                                if time.monotonic() - start > args.timeout:
                                    timed_out = True
                                    os.killpg(proc.pid, signal.SIGKILL)
                                    break
                                time.sleep(.02)
                            code = proc.wait()
                        runs.append({'name': label, 'exit': code, 'signal': -code if code < 0 else None, 'timedOut': timed_out, 'seconds': round(time.monotonic() - start, 3), 'stubOk': 'stub-ok' in (folder / (label + '.stdout')).read_text(), 'exe': '|'.join(sorted(run_exes))})
                finally:
                    server.terminate()
                    server.wait(timeout=10)
            requests = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            tools = [sorted(t['function']['name'] for t in row.get('tools', [])) for row in requests]
            resident = [MARKER in '\n'.join(str(m.get('content', '')) for m in row.get('messages', []) if m['role'] in ['system', 'developer']) for row in requests]
            checks = integrity(home)
            result = {'variant': variant, 'round': round_number, 'config': args.config, 'runs': runs, 'requestCount': len(requests), 'tools': tools, 'resident': resident, 'nativeMaps': sorted(native), 'piExe': sorted(round_exes), 'node': node, 'databases': checks}
            result['ok'] = all(r['exit'] == 0 and r['stubOk'] for r in runs) and len(requests) == 3 and all(t == EXPECTED for t in tools) and (variant != 'memory' or all(resident)) and all(db.get('integrity') == ['ok'] for db in checks)
            results.append(result)
            (folder / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
            (args.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            print(variant, round_number, 'PASS' if result['ok'] else 'FAIL', [r['exit'] for r in runs], flush=True)
    return 0 if all(r['ok'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
