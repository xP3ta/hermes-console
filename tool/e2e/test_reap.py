"""Teardown of the real-gateway E2E lane leaves no process and no listener.

Run: python3 -m unittest discover -s tool/e2e -p 'test_*.py'

A fake backend reproduces backend.py's shape: children in their own sessions
(process groups), recorded in ``children.pgid``, each holding a listening
socket and ignoring SIGTERM (a slow ``hermes serve`` shutdown), plus a
grandchild that calls ``setsid()``. The backend then exits abnormally
(SIGKILL), which is what the wrapper's timeout used to do while the
children were still alive.
"""

from __future__ import annotations

import os
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REAP = HERE / "reap.py"

LISTENER = textwrap.dedent("""
    import os, signal, socket, subprocess, sys, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
    with open(sys.argv[1], "a") as f:
        f.write(f"{s.getsockname()[1]}\\n")
    if len(sys.argv) > 2:
        # A grandchild in yet another session (setsid), same environment.
        subprocess.Popen([sys.executable, "-c", sys.argv[2], sys.argv[1]],
                         start_new_session=True)
    while True:
        time.sleep(1)
""")

BACKEND = textwrap.dedent("""
    import signal, subprocess, sys, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    ports, pgids, listener = sys.argv[1], sys.argv[2], sys.argv[3]
    for extra in ([listener], []):
        child = subprocess.Popen([sys.executable, "-c", listener, ports, *extra],
                                 start_new_session=True)
        with open(pgids, "a") as f:
            f.write(f"{child.pid}\\n")
    while True:
        time.sleep(1)
""")


def _marked(marker: str) -> list[int]:
    needle = f"HERMES_E2E_LANE={marker}".encode()
    found = []
    for pid in (int(p) for p in os.listdir("/proc") if p.isdigit()):
        try:
            env = Path(f"/proc/{pid}/environ").read_bytes()
            state = Path(f"/proc/{pid}/stat").read_text()
        except OSError:
            continue
        if needle in env.split(b"\0") and state[state.rfind(")") + 2] not in "ZX":
            found.append(pid)
    return found


def _listening(port: int) -> bool:
    with socket.socket() as probe:
        probe.settimeout(0.5)
        return probe.connect_ex(("127.0.0.1", port)) == 0


class ReapTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="hermes-e2e-reap-"))
        self.marker = secrets.token_hex(16)
        self.ports = self.tmp / "ports"
        self.pgids = self.tmp / "children.pgid"
        self.cleanup: list[subprocess.Popen] = []

    def tearDown(self) -> None:
        # Never leave anything behind even when an assertion failed.
        for pid in _marked(self.marker):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        for proc in self.cleanup:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        for f in self.tmp.iterdir():
            f.unlink()
        self.tmp.rmdir()

    def _start_backend(self) -> subprocess.Popen:
        env = dict(os.environ, HERMES_E2E_LANE=self.marker)
        backend = subprocess.Popen(
            [sys.executable, "-c", BACKEND, str(self.ports), str(self.pgids), LISTENER],
            env=env, start_new_session=True)
        self.cleanup.append(backend)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.ports.exists() and len(self.ports.read_text().split()) == 3:
                break
            time.sleep(0.05)
        ports = [int(p) for p in self.ports.read_text().split()]
        self.assertEqual(len(ports), 3)
        self.assertTrue(all(_listening(p) for p in ports))
        self.assertEqual(len(_marked(self.marker)), 4)
        return backend

    def _reap(self, budget: float) -> tuple[int, float]:
        start = time.monotonic()
        rc = subprocess.run(
            [sys.executable, str(REAP), "--marker", self.marker,
             "--pgid-file", str(self.pgids), "--budget", str(budget)],
            timeout=budget + 10).returncode
        return rc, time.monotonic() - start

    def test_abnormal_backend_exit_leaves_no_process_or_listener(self) -> None:
        backend = self._start_backend()
        ports = [int(p) for p in self.ports.read_text().split()]
        backend.kill()  # abnormal exit: no teardown of its own
        backend.wait(timeout=5)
        self.assertTrue(all(_listening(p) for p in ports), "orphans still serve")

        rc, elapsed = self._reap(budget=4)

        self.assertEqual(rc, 0)
        self.assertLess(elapsed, 4 + 1.5, "teardown must fit the budget")
        self.assertEqual(_marked(self.marker), [])
        self.assertFalse(any(_listening(p) for p in ports))

    def test_term_ignoring_live_backend_is_killed_within_budget(self) -> None:
        backend = self._start_backend()
        ports = [int(p) for p in self.ports.read_text().split()]

        rc, elapsed = self._reap(budget=3)

        self.assertEqual(rc, 0)
        self.assertLess(elapsed, 3 + 1.5)
        backend.wait(timeout=5)
        self.assertEqual(_marked(self.marker), [])
        self.assertFalse(any(_listening(p) for p in ports))

    def test_a_recorded_group_without_the_marker_is_not_touched(self) -> None:
        # A reused PGID: same number in children.pgid, unrelated process.
        env = {k: v for k, v in os.environ.items() if k != "HERMES_E2E_LANE"}
        stranger = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                    env=env, start_new_session=True)
        self.cleanup.append(stranger)
        self.pgids.write_text(f"{stranger.pid}\n")

        rc, _ = self._reap(budget=2)

        self.assertEqual(rc, 0)
        self.assertIsNone(stranger.poll(), "an unrelated group must survive")

    def test_a_short_marker_is_refused(self) -> None:
        rc = subprocess.run([sys.executable, str(REAP), "--marker", "x"],
                            timeout=10).returncode
        self.assertEqual(rc, 2)


class KillGroupsTest(unittest.TestCase):
    """backend.py's own teardown: every group at once, within its budget."""

    def test_term_ignoring_groups_die_within_the_budget(self) -> None:
        sys.path.insert(0, str(HERE))
        try:
            import backend  # noqa: PLC0415 - stdlib-only at import time
        finally:
            sys.path.remove(str(HERE))
        tmp = Path(tempfile.mkdtemp(prefix="hermes-e2e-kill-"))
        ports = tmp / "ports"
        children = [
            subprocess.Popen([sys.executable, "-c", LISTENER, str(ports), *extra],
                             start_new_session=True)
            for extra in ([], [])
        ]
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not (
                    ports.exists() and len(ports.read_text().split()) == 2):
                time.sleep(0.05)
            bound = [int(p) for p in ports.read_text().split()]
            start = time.monotonic()
            backend._kill_groups(children, budget=2.0)
            elapsed = time.monotonic() - start
            self.assertLess(elapsed, 2.5)
            self.assertTrue(all(c.poll() is not None for c in children))
            self.assertFalse(any(_listening(p) for p in bound))
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
            ports.unlink(missing_ok=True)
            tmp.rmdir()


if __name__ == "__main__":
    unittest.main()
