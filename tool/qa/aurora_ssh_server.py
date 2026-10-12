#!/usr/bin/env python3
"""A scripted, harmless SSH "server" for the Terminal screenshot.

It is NOT a shell: it never runs a command. It accepts the user `deploy` with
any password, prints a fictional "Project Aurora" workspace banner, echoes what
is typed and answers a short list of canned commands (git status, git diff,
git log, cat of the launch checklist, ls). Anything else says "command not
found". It listens on 127.0.0.1 only; the emulator reaches it at 10.0.2.2.

Needs asyncssh (use a throw-away venv, not the system Python):

    python3 -m venv /tmp/aurora-ssh && /tmp/aurora-ssh/bin/pip install asyncssh
    /tmp/aurora-ssh/bin/python tool/qa/aurora_ssh_server.py [--port 2222]
"""
import argparse
import asyncio
import os
import tempfile

import asyncssh

Y = '\x1b[93m'   # bright yellow
G = '\x1b[32m'
B = '\x1b[34m'
R = '\x1b[0m'
BOLD = '\x1b[1m'
PROMPT = f'{G}${R} '

BANNER = (
    f'{Y}{BOLD}AURORA BUILD HOST{R}\r\n'
    'Release workspace for Project Aurora\r\n\r\n'
)

COMMANDS = {
    'git status --short': (
        f' {Y}M{R} web/landing.html\r\n'
        f' {Y}M{R} docs/getting-started.md\r\n'
        f' {G}A{R} media/product-preview.png\r\n'
    ),
    'git diff --stat': (
        ' web/landing.html         | 24 ++++++--\r\n'
        ' docs/getting-started.md  | 12 +++-\r\n'
        ' 2 files changed, 29 insertions(+)\r\n'
    ),
    'git log --oneline -3': (
        f'{Y}8f2a4c1{R} Polish the voice flow\r\n'
        f'{Y}3b7d902{R} Simplify first connection\r\n'
        f'{Y}1a6e8b4{R} Add the launch checklist\r\n'
    ),
    'cat docs/launch-checklist.md': (
        '# Launch checklist\r\n\r\n'
        '[x] First-run walkthrough\r\n'
        '[x] Voice flow review\r\n'
        '[x] Getting-started guide\r\n'
        '[ ] Store screenshots\r\n'
        '[ ] Final pricing page review\r\n'
    ),
    'ls': (
        f'{B}docs/{R}   {B}media/{R}   {B}web/{R}\r\n'
        'README.md  package.json\r\n'
    ),
}


class Session(asyncssh.SSHServerSession):
    def __init__(self):
        self._chan = None
        self._line = ''

    def connection_made(self, chan):
        self._chan = chan

    def pty_requested(self, term_type, term_size, term_modes):
        return True

    def shell_requested(self):
        return True

    def session_started(self):
        self._chan.write(BANNER + PROMPT)

    def data_received(self, data, datatype):
        # A quick command arrives as one chunk ending in a newline: show the
        # command once (the terminal already echoes keystrokes it sends).
        if len(data) > 1 and data[-1] in '\r\n':
            line = data.rstrip('\r\n')
            self._chan.write('\r\n')
            self._run(line.strip())
            self._chan.write(PROMPT)
            return
        for ch in data:
            if ch in ('\r', '\n'):
                self._chan.write('\r\n')
                self._run(self._line.strip())
                self._line = ''
                self._chan.write(PROMPT)
            elif ch in ('\x7f', '\b'):
                if self._line:
                    self._line = self._line[:-1]
                    self._chan.write('\b \b')
            elif ch == '\x03':
                self._line = ''
                self._chan.write('^C\r\n' + PROMPT)
            elif ch >= ' ':
                self._line += ch
                self._chan.write(ch)

    def _run(self, command):
        if not command:
            return
        out = COMMANDS.get(command)
        if out is None:
            out = f'sh: {command.split()[0]}: command not found\r\n'
        self._chan.write(out)

    def eof_received(self):
        return False


class Server(asyncssh.SSHServer):
    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return username == 'deploy'

    def session_requested(self):
        return Session()


async def main(port):
    # One throw-away host key per user session, kept so a restart does not
    # make the app warn that the "server key changed".
    key_dir = os.path.join(tempfile.gettempdir(), 'aurora-ssh-hostkey')
    os.makedirs(key_dir, exist_ok=True)
    path = os.path.join(key_dir, 'host_key')
    if not os.path.exists(path):
        asyncssh.generate_private_key('ssh-ed25519').write_private_key(path)
    await asyncssh.create_server(
        Server,
        '127.0.0.1',
        port,
        server_host_keys=[path],
        encoding='utf-8',
    )
    print(f'Aurora SSH fixture on 127.0.0.1:{port} (user deploy, any password)')
    await asyncio.Event().wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=2222)
    args = parser.parse_args()
    if args.port in (22, 2200):
        raise SystemExit('refusing a port a real sshd may use')
    asyncio.run(main(args.port))
