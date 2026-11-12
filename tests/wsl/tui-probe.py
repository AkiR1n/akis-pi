#!/usr/bin/env python3
"""Drive the interactive Pi TUI N times against the loopback stub and record clean exits.

Isolated from the deployed configuration: one temporary HOME holds a copy of the rendered
agent directory, a stub models.json, the rendered Magic Context config and a synthetic
RESIDENT. The stub provider logs every request, so a session that never reached the model is
distinguishable from one that did. Nothing here touches a real HOME or a real key.

The TUI needs about 10-15 s to become ready on a cold home (it downloads fd/ripgrep), so the
driver waits for the rendered status line instead of a fixed delay; typing into the startup
screen is swallowed. Enter is CR, and ctrl+d exits only once the input line is empty.
"""
import argparse
import fcntl
import json
import os
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import termios
import time
from pathlib import Path

MARKER = 'AKIS_STUB_RESIDENT_SENTINEL'


def proc_link(pid, name):
    try:
        return os.readlink('/proc/' + str(pid) + '/' + name)
    except OSError:
        return ''


def node_identity(env):
    info = {'version': '', 'bin': shutil.which('node', path=env.get('PATH', '')) or '', 'realpath': ''}
    if not info['bin']:
        return info
    info['realpath'] = os.path.realpath(info['bin'])
    try:
        info['version'] = subprocess.run(['node', '-p', 'process.version'], capture_output=True, text=True, env=env, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return info


def request_count(log):
    if not log.exists():
        return 0
    return len([line for line in log.read_text().splitlines() if line.strip()])


def pump(fd, buffer, seconds):
    """Read from the pty for at most the given number of seconds, appending to the buffer."""
    end = time.monotonic() + seconds
    while True:
        remaining = end - time.monotonic()
        if remaining <= 0:
            return
        ready, _, _ = select.select([fd], [], [], min(remaining, 0.2))
        if not ready:
            return
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            return
        if not chunk:
            return
        buffer.extend(chunk)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', type=Path, required=True)
    p.add_argument('--agent-dir', type=Path, required=True)
    p.add_argument('--mc-config', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--pi', default='pi')
    p.add_argument('--sessions', type=int, default=10)
    p.add_argument('--stub-port', type=int, default=0)
    p.add_argument('--ready-timeout', type=float, default=90)
    p.add_argument('--answer-timeout', type=float, default=60)
    p.add_argument('--exit-timeout', type=float, default=25)
    p.add_argument('--timeout', type=float, default=240, help='hard cap per session')
    args = p.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)

    home = args.out / 'home'
    agent = home / '.pi/agent'
    agent.mkdir(parents=True)
    for name in ['settings.json', 'AGENTS.md', 'APPEND_SYSTEM.md', 'compact-tools.json']:
        if (args.agent_dir / name).is_file():
            shutil.copy2(args.agent_dir / name, agent / name)
    for name in ['agents', 'prompts', 'extensions', 'skills']:
        if (args.agent_dir / name).is_dir():
            shutil.copytree(args.agent_dir / name, agent / name)
    (agent / 'npm').symlink_to(args.agent_dir / 'npm', target_is_directory=True)
    (agent / 'memory').mkdir(exist_ok=True)
    (agent / 'memory/RESIDENT.md').write_text(MARKER + '\n')
    (home / '.config/cortexkit').mkdir(parents=True)
    shutil.copy2(args.mc_config, home / '.config/cortexkit/magic-context.jsonc')

    port = args.stub_port
    if port == 0:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
    model = {'id': 'stub-model', 'name': 'Stub', 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 200000, 'maxTokens': 1000}
    (agent / 'models.json').write_text(json.dumps({'providers': {'stub': {'baseUrl': 'http://127.0.0.1:' + str(port) + '/v1', 'api': 'openai-completions', 'apiKey': 'dummy', 'models': [model]}}}))
    settings = json.loads((agent / 'settings.json').read_text())
    settings['defaultProvider'] = 'stub'
    settings['defaultModel'] = 'stub-model'
    settings['enabledModels'] = ['stub/stub-model']
    (agent / 'settings.json').write_text(json.dumps(settings, indent=2) + '\n')

    clean_env = {k: v for k, v in os.environ.items() if not k.startswith(('PI_', 'MAGIC_CONTEXT_', 'HERDR_'))}
    env = {**clean_env, 'HOME': str(home), 'USERPROFILE': str(home), 'PI_CODING_AGENT_DIR': str(agent), 'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_DATA_HOME': str(home / '.local/share'), 'MAGIC_CONTEXT_STORAGE_DIR': str(home / 'mc-store'), 'MAGIC_CONTEXT_LOG_PATH': str(args.out / 'mc.log'), 'PI_RESIDENT_MEMORY_FILE': str(agent / 'memory/RESIDENT.md'), 'PI_RESIDENT_MEMORY_OFF': '0', 'TERM': 'xterm-256color'}
    node = node_identity(env)
    print('node', node['version'], node['realpath'], flush=True)
    (args.out / 'node-identity.json').write_text(json.dumps(node, indent=2) + '\n')

    log = args.out / 'requests.jsonl'
    with (args.out / 'stub.txt').open('w') as stub_out:
        server = subprocess.Popen(['node', str(args.repo / 'scripts/stub-provider.mjs'), '--port', str(port), '--log', str(log)], stdout=stub_out, stderr=subprocess.STDOUT, env=env)
    results = []
    try:
        deadline = time.monotonic() + 15
        while True:
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError('stub failed to start')
                time.sleep(.05)
        for session in range(1, args.sessions + 1):
            folder = args.out / ('session-' + str(session).zfill(2))
            folder.mkdir()
            before = request_count(log)
            start = time.monotonic()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
            proc = subprocess.Popen([args.pi], stdin=slave, stdout=slave, stderr=slave, cwd=folder, env=env, start_new_session=True)
            os.close(slave)
            os.set_blocking(master, False)
            output = bytearray()
            exes = set()
            errors = []
            answered = False
            ready_seconds = None
            try:
                ready_deadline = min(start + args.timeout, time.monotonic() + args.ready_timeout)
                while time.monotonic() < ready_deadline and proc.poll() is None:
                    pump(master, output, 0.4)
                    exe = proc_link(proc.pid, 'exe')
                    if exe:
                        exes.add(exe)
                    if b'eady' in output:
                        ready_seconds = round(time.monotonic() - start, 2)
                        break
                if proc.poll() is None:
                    pump(master, output, 2.0)
                    os.write(master, b'hi')
                    pump(master, output, 1.0)
                    os.write(master, b'\r')
                    answer_deadline = min(start + args.timeout, time.monotonic() + args.answer_timeout)
                    while time.monotonic() < answer_deadline and proc.poll() is None:
                        if request_count(log) > before:
                            answered = True
                            break
                        pump(master, output, 0.3)
                        exe = proc_link(proc.pid, 'exe')
                        if exe:
                            exes.add(exe)
                if proc.poll() is None:
                    pump(master, output, 3.0)
                    os.write(master, b'\x04')
                exit_deadline = min(start + args.timeout, time.monotonic() + args.exit_timeout)
                while proc.poll() is None and time.monotonic() < exit_deadline:
                    pump(master, output, 0.3)
                    exe = proc_link(proc.pid, 'exe')
                    if exe:
                        exes.add(exe)
                if proc.poll() is None:
                    os.write(master, b'\x03')
                    pump(master, output, 1.5)
                    os.write(master, b'\x04')
                    retry_deadline = min(start + args.timeout, time.monotonic() + 10)
                    while proc.poll() is None and time.monotonic() < retry_deadline:
                        pump(master, output, 0.3)
                if proc.poll() is None:
                    errors.append('did not exit')
                    os.killpg(proc.pid, signal.SIGKILL)
                code = proc.wait()
                pump(master, output, 0.5)
            finally:
                os.close(master)
            text = output.decode('utf-8', 'replace')
            (folder / 'tui-output.txt').write_text(text)
            requests = request_count(log) - before
            result = {
                'session': session,
                'exit': code,
                'signal': -code if code < 0 else None,
                'seconds': round(time.monotonic() - start, 2),
                'readySeconds': ready_seconds,
                'answered': answered,
                'requests': requests,
                'stubOk': 'stub-ok' in text,
                'exe': '|'.join(sorted(exes)),
                'errors': errors,
            }
            result['ok'] = code == 0 and answered and result['stubOk'] and requests >= 1 and not errors
            results.append(result)
            (args.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            print('session', session, 'PASS' if result['ok'] else 'FAIL', 'exit', code, 'ready', ready_seconds, 'requests', requests, flush=True)
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.SubprocessError:
            server.kill()
    sessions = len(results)
    clean = [r for r in results if r['ok']]
    lines = [
        'TUI sessions=' + str(sessions) + ' clean=' + str(len(clean)) + ' failed=' + str(sessions - len(clean)),
        'answers=' + str(sum(1 for r in results if r['answered'])) + ' stubOk=' + str(sum(1 for r in results if r['stubOk'])) + ' requests_total=' + str(sum(r['requests'] for r in results)),
        'exe_seen=' + ' '.join(sorted({r['exe'] for r in results if r['exe']})),
    ]
    for r in results:
        lines.append('session ' + str(r['session']) + ': exit=' + str(r['exit']) + ' signal=' + str(r['signal']) + ' seconds=' + str(r['seconds']) + ' ready=' + str(r['readySeconds']) + ' requests=' + str(r['requests']) + ' answered=' + str(r['answered']) + ' stubOk=' + str(r['stubOk']) + ' ' + ','.join(r['errors']))
    (args.out / 'stats.txt').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines[:3]))
    return 0 if len(clean) == sessions else 1


if __name__ == '__main__':
    raise SystemExit(main())
