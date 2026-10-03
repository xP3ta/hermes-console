#!/usr/bin/env python3
"""Real `hermes serve` backend for the Console end-to-end lane.

Runs inside the Hermes checkout's own virtualenv (``HERMES_SRC`` on
``sys.path``) and wires three pieces together:

* Hermes' own recording loopback provider (``tests/fakes/fake_llm_provider.py``)
  scripted by tags the Dart tests put in their prompts;
* an isolated ``HOME``/``HERMES_HOME`` under ``--root`` (never the operator's)
  holding a minimal config, a fake API key and one seeded 300-row session;
* ``python -m hermes_cli.main serve --port 0``, the exact argv Desktop spawns
  (Dashboard REST + ``/api/ws`` JSON-RPC, auth gate on);
* ``python -m gateway.run`` with the API-server platform, the ``:8642``
  surface Console reads durable transcripts from.

When the backend is ready it writes ``<root>/backend.env`` with
``HERMES_E2E_URL``, ``HERMES_E2E_TOKEN`` and ``HERMES_E2E_CONTROL_URL`` and
then blocks until SIGTERM/SIGINT, tearing every child down on exit.

The control endpoint (loopback only) lets a test ask what the model was sent,
which is the only honest way to prove "a queued prompt reached the model
exactly once": ``GET /main-requests?tag=Q1`` returns the number of main-turn
provider requests whose newest user message carries the tag.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SEEDED_SESSION_ID = "e2e-seeded-300"
SEEDED_ROWS = 300
# Small independent sessions, one per scenario, so tests never share a runtime.
CHAT_SESSIONS = tuple(f"e2e-chat-{i:02d}" for i in range(1, 13))
# Exported by tool/e2e/run_local.sh and kept in the children's allowlisted
# env: tool/e2e/reap.py finds every process of this lane by it.
LANE_VAR = "HERMES_E2E_LANE"
# Whole teardown of the children; run_local.sh waits longer than this.
KILL_BUDGET_S = 8.0
READY_RE = re.compile(r"HERMES_BACKEND_READY port=(\d+)")
TAG_RE = re.compile(r"\[E2E:([A-Z_]+)(?::([A-Za-z0-9_-]+))?\]")

# No network from the backend: no update check, models.dev fails fast on a
# closed port, no background review racing the scripted turns.
OFFLINE_CONFIG = (
    "updates:\n  check: false\n"
    "models_dev:\n  url: http://127.0.0.1:9/api.json\n"
    "skills:\n  creation_nudge_interval: 0\n"
    "memory:\n  nudge_interval: 0\n"
    "clarify:\n  timeout: 300\n"
    "approvals:\n  mode: manual\n  timeout: 300\n"
    "terminal:\n  backend: local\n"
    # The system prompt + tool schemas alone are ~15.5K tokens (chars/4), so
    # ordinary chats stay below 30K while one tool-heavy turn crosses it in
    # the middle of the turn, with enough rows for compaction to progress.
    "compression:\n  threshold_tokens: 30000\n  protect_last_n: 4\n"
    "auxiliary:\n  title_generation:\n    enabled: false\n"
)
COMPACT_ROUNDS = 12
COMPACT_FILE_CHARS = 9000


def _newest_user_text(body: dict) -> str:
    for message in reversed(body.get("messages") or []):
        if message.get("role") == "user":
            content = message.get("content")
            return content if isinstance(content, str) else json.dumps(content)
    return ""


def estimate_prompt_tokens(body: dict) -> int:
    """Reported ``usage.prompt_tokens``: chars/4, so the trigger sees growth."""
    return (len(json.dumps(body.get("messages", []))) + len(json.dumps(body.get("tools", [])))) // 4


def summary(_record: dict):
    from tests.fakes import fake_llm_provider as fake  # noqa: PLC0415
    return fake.Text("## Goal\nKeep helping with the e2e task (SUMMARY-OK).\n"
                     "## Progress\n### Done\n- Read several files.\n"
                     "## Next Steps\n- Continue with the latest request.\n", chunk_chars=64)


def make_responder(fake, work_dir: Path):
    """Main-turn script keyed by the newest user message's `[E2E:KIND:tag]`."""
    compact_rounds: dict[str, int] = {}
    lock = threading.Lock()

    def respond(record: dict):
        body = record["body"]
        messages = body.get("messages") or []
        match = TAG_RE.search(_newest_user_text(body))
        kind, tag = (match.group(1), match.group(2) or "") if match else ("", "")
        last = messages[-1] if messages else {}
        after_tool = last.get("role") == "tool"
        if kind == "STREAM":
            # Enough chunks, slow enough, that the client sees several deltas.
            return fake.Text(f"streamed reply {tag} " + "lorem ipsum " * 20,
                             chunk_chars=12, delay_per_chunk=0.02)
        if kind == "SLOW":
            # A long stream so a test can cut the socket mid-turn.
            return fake.Text(f"slow reply {tag} " + "dolor sit amet " * 60,
                             chunk_chars=10, delay_per_chunk=0.05)
        if kind == "CLARIFY":
            if after_tool:
                return fake.Text(f"clarified {tag}: {str(last.get('content'))[:200]}")
            return fake.ToolCall("clarify", {"question": f"Colour for {tag}?",
                                             "choices": ["red", "blue"]})
        if kind == "COMPACT":
            # Read big files one tool round at a time until the context
            # crosses the compaction trigger in the middle of the turn. The
            # round count lives here: compaction shrinks the request itself.
            with lock:
                rounds = compact_rounds.get(tag, 0)
                compact_rounds[tag] = rounds + 1
            if rounds < COMPACT_ROUNDS:
                return fake.ToolCall("read_file", {"path": str(work_dir / f"compact{rounds}.txt")})
            return fake.Text(f"compact report {tag}: done", chunk_chars=64)
        if kind == "BATCH":
            if after_tool:
                return fake.Text(f"batch done {tag}: {str(last.get('content'))[:300]}")
            return fake.ToolCall("clarify", {"questions": [
                {"id": "colour", "question": f"Colour for {tag}?", "choices": ["red", "blue"]},
                {"id": "name", "question": f"Name for {tag}?"},
            ]})
        return fake.Text(f"ok {tag}".strip())

    return respond


def seed_session(hermes_home: Path) -> None:
    """One durable desktop session with SEEDED_ROWS alternating rows, plus
    CHAT_SESSIONS with one exchange each."""
    os.environ["HERMES_HOME"] = str(hermes_home)
    from hermes_state import SessionDB  # noqa: PLC0415 - needs HERMES_HOME first

    db = SessionDB(hermes_home / "state.db")
    try:
        db.create_session(SEEDED_SESSION_ID, "desktop", model="fake-model")
        base = time.time() - SEEDED_ROWS * 10
        for i in range(1, SEEDED_ROWS + 1):
            role = "user" if i % 2 else "assistant"
            db.append_message(SEEDED_SESSION_ID, role, f"{role} row {i} " + "x" * 200,
                              timestamp=base + i * 10)
        for sid in CHAT_SESSIONS:
            db.create_session(sid, "desktop", model="fake-model")
            db.append_message(sid, "user", f"hello {sid}", timestamp=base)
            db.append_message(sid, "assistant", f"hi from {sid}", timestamp=base + 1)
    finally:
        close = getattr(db, "close", None)
        if callable(close):
            close()


class Control:
    def __init__(self, llm, db_path: Path) -> None:
        self.llm = llm
        self.db_path = db_path
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def _handler(self):
        llm = self.llm
        db_path = self.db_path

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_a) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802
                url = urlparse(self.path)
                query = parse_qs(url.query)
                if url.path == "/main-requests":
                    tag = (query.get("tag") or [""])[0]
                    count = sum(1 for body in llm.main_requests()
                                if tag and tag in _newest_user_text(body)
                                and (body.get("messages") or [{}])[-1].get("role") == "user")
                    payload = {"count": count}
                elif url.path == "/compacted-rows":
                    # Read-only peek: rows a committed compaction archived.
                    sid = (query.get("session") or [""])[0]
                    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=30)
                    try:
                        row = conn.execute(
                            "SELECT COUNT(*) FROM messages m JOIN sessions s ON s.id = m.session_id "
                            "WHERE (s.id = ? OR s.parent_session_id = ?) AND m.compacted = 1",
                            (sid, sid)).fetchone()
                    finally:
                        conn.close()
                    payload = {"count": int(row[0])}
                elif url.path == "/stats":
                    payload = {"main": len(llm.main_requests()), "aux": len(llm.aux_requests())}
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                raw = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        return Handler


def _child_env(home: Path, hermes_home: Path, token: str, src: Path,
               user: str, password: str) -> dict[str, str]:
    """Allowlisted env: nothing provider- or Hermes-shaped leaks from the runner."""
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", "TERM", LANE_VAR)
           if k in os.environ}
    tmp = home.parent / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    env.update(
        HOME=str(home), HERMES_HOME=str(hermes_home), PYTHONPATH=str(src),
        TMPDIR=str(tmp), HERMES_DASHBOARD_SESSION_TOKEN=token,
        PYTHONUNBUFFERED="1", NO_COLOR="1",
        # The sandbox HOME is the child's "real" home; the live-DB guard exists
        # to protect the operator's state.db, which main() proves is elsewhere.
        HERMES_STATE_DB_GUARD_BYPASS="1",
        HERMES_DISABLE_LAZY_INSTALLS="1",
        # The bind host is not a loopback literal, so the Dashboard auth gate
        # is on exactly as for a phone: password login -> cookie -> ws-ticket.
        # Throwaway per-run credentials, never a real secret.
        HERMES_DASHBOARD_BASIC_AUTH_USERNAME=user,
        HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=password,
        HERMES_DASHBOARD_BASIC_AUTH_SECRET=secrets.token_hex(32),
    )
    return env


def _record_group(root: Path, child: subprocess.Popen) -> None:
    """Append the child's process group (its own session) to
    ``children.pgid`` so tool/e2e/reap.py can find it after an abnormal exit."""
    with open(root / "children.pgid", "a", encoding="utf-8") as f:
        f.write(f"{child.pid}\n")


def _kill_groups(children: list[subprocess.Popen], budget: float = KILL_BUDGET_S) -> None:
    """SIGTERM every child's process group at once, SIGKILL whatever is left
    at half of [budget], all within [budget] seconds in total. The runner
    waits longer than this before its own reap, so a slow ``hermes serve``
    shutdown cannot outlive the backend."""
    live = [c for c in children if c.poll() is None]
    deadline = time.monotonic() + budget

    def signal_all(sig: int) -> None:
        for child in live:
            try:
                os.killpg(child.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass

    def wait_until(until: float) -> None:
        for child in live:
            try:
                child.wait(timeout=max(0.0, until - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass

    signal_all(signal.SIGTERM)
    wait_until(time.monotonic() + budget / 2)
    signal_all(signal.SIGKILL)  # also the group's stragglers, not only the leader
    wait_until(deadline)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--src", required=True, type=Path, help="Hermes checkout")
    parser.add_argument("--timeout", type=float, default=120.0)
    # 127.0.0.2 is loopback on Linux but not one of Hermes' loopback host
    # literals, which turns the Dashboard auth gate on (the phone topology).
    parser.add_argument("--host", default="127.0.0.2")
    args = parser.parse_args()

    root: Path = args.root.resolve()
    src: Path = args.src.resolve()
    home = root / "home"
    hermes_home = home / ".hermes"
    # The sandbox must be a fresh directory and never an operator Hermes home
    # or profile root. (A scratch dir *below* an operator home is fine: the
    # backend only ever sees the explicit HERMES_HOME set here.)
    operator = (Path(os.path.expanduser("~")) / ".hermes").resolve()
    if hermes_home in (operator, *operator.glob("profiles/*")) or hermes_home.exists():
        print(f"refusing: {hermes_home} is not a fresh sandbox", file=sys.stderr)
        return 2

    sys.path.insert(0, str(src))
    from tests.fakes import fake_llm_provider as fake  # noqa: PLC0415

    work_dir = root / "work"
    work_dir.mkdir()
    for i in range(COMPACT_ROUNDS):
        (work_dir / f"compact{i}.txt").write_text(
            "\n".join(f"compact{i}:{n} " + "alpha bravo delta omega sigma " * 3
                      for n in range(COMPACT_FILE_CHARS // 100)), encoding="utf-8")
    llm = fake.FakeLLMServer(make_responder(fake, work_dir), aux=summary,
                             prompt_tokens_fn=estimate_prompt_tokens)
    llm.start()
    fake.write_hermes_home(hermes_home, llm.base_url, extra_config=OFFLINE_CONFIG)
    seed_session(hermes_home)
    control = Control(llm, hermes_home / "state.db")

    token = secrets.token_hex(16)
    user, password = "e2e", secrets.token_urlsafe(18)
    stdout = open(root / "serve.stdout.log", "wb")
    stderr = open(root / "serve.stderr.log", "wb")
    proc = subprocess.Popen(
        [sys.executable, "-m", "hermes_cli.main", "serve", "--host", args.host, "--port", "0"],
        cwd=str(root), env=_child_env(home, hermes_home, token, src, user, password),
        stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
    _record_group(root, proc)

    stopping = threading.Event()
    api_procs: list[subprocess.Popen] = []

    def start_api_server(attempts: int = 5) -> tuple[int, str]:
        """``gateway.run`` serving only the API-server platform on a free port."""
        api_key = secrets.token_hex(32)
        env_before = (hermes_home / ".env").read_text(encoding="utf-8")
        for _ in range(attempts):
            with socket.socket() as probe:
                probe.bind((args.host, 0))
                api_port = probe.getsockname()[1]
            (hermes_home / ".env").write_text(env_before + "".join(
                f"{k}={v}\n" for k, v in {
                    "API_SERVER_ENABLED": "true", "API_SERVER_KEY": api_key,
                    "API_SERVER_HOST": args.host, "API_SERVER_PORT": str(api_port)}.items()),
                encoding="utf-8")
            log = open(root / "gateway.log", "ab")
            gw = subprocess.Popen(
                [sys.executable, "-m", "gateway.run"], cwd=str(root),
                env=_child_env(home, hermes_home, token, src, user, password),
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True)
            api_procs.append(gw)
            _record_group(root, gw)
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline and gw.poll() is None and not stopping.is_set():
                try:
                    req = urllib.request.Request(
                        f"http://{args.host}:{api_port}/health/detailed",
                        headers={"Authorization": f"Bearer {api_key}"})
                    with urllib.request.urlopen(req, timeout=2) as resp:
                        if json.loads(resp.read()).get("pid") == gw.pid:
                            return api_port, api_key
                except (OSError, ValueError):
                    pass
                time.sleep(0.2)
            _kill_groups([gw])
        raise RuntimeError("gateway API server never became ready")

    def stop(*_a) -> None:
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    try:
        deadline = time.monotonic() + args.timeout
        port = None
        while port is None:
            if proc.poll() is not None:
                print(f"hermes serve exited {proc.returncode} before ready", file=sys.stderr)
                return 1
            if time.monotonic() > deadline or stopping.is_set():
                print("hermes serve never reported ready", file=sys.stderr)
                return 1
            found = READY_RE.search((root / "serve.stdout.log").read_text(errors="replace"))
            port = int(found.group(1)) if found else None
            time.sleep(0.1)
        api_port, api_key = start_api_server()
        # Written atomically: the runner polls for this file's existence.
        env_file = root / "backend.env"
        partial = root / "backend.env.partial"
        partial.touch(mode=0o600)
        partial.write_text(
            f"HERMES_E2E_URL=http://{args.host}:{port}\n"
            f"HERMES_E2E_USER={user}\n"
            f"HERMES_E2E_TOKEN={password}\n"
            f"HERMES_E2E_CONTROL_URL={control.url}\n"
            f"HERMES_E2E_API_URL=http://{args.host}:{api_port}\n"
            f"HERMES_E2E_API_KEY={api_key}\n"
            f"HERMES_E2E_SEEDED_SESSION={SEEDED_SESSION_ID}\n"
            f"HERMES_E2E_SEEDED_ROWS={SEEDED_ROWS}\n", encoding="utf-8")
        partial.replace(env_file)
        print(f"backend ready on port {port}, api server on {api_port}", flush=True)
        while not stopping.is_set() and proc.poll() is None:
            stopping.wait(0.5)
        return 0 if proc.poll() is None else 1
    finally:
        _kill_groups([*api_procs, proc])
        control.server.shutdown()
        llm.stop()
        stdout.close()
        stderr.close()


if __name__ == "__main__":
    sys.exit(main())
