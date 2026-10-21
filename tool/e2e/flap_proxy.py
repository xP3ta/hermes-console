#!/usr/bin/env python3
"""Fault-injecting TCP proxy for the real-gateway E2E lane (stdlib only).

Sits between Console and the isolated Hermes backend, in user space: no root,
no iptables. One listener per ``--target NAME=host:port`` on ``host:0``; each
``NAME=http://host:port`` goes to ``--ports-file`` as an env-file line. Loopback
traffic is plain HTTP: the request line of every request is read (never a body)
to count requests per route (forwarded or swallowed by ``blackhole``) and to
time those that get no answer.

Control (Unix socket, a command per line, a JSON reply each):
  pass | blackhole | rst | refuse | flap N DOWN UP | stats | reset
  blackhole  stop forwarding without closing: a half-open socket
  rst        reset every live connection and every new one (SO_LINGER 0)
  refuse     close the listeners: new connections are refused
  flap       N cycles of DOWN seconds in ``rst`` then UP seconds in ``pass``
On SIGTERM the proxy prints ``[e2e-net] accepted=.. live_max=.. by_path=..``.
"""
import argparse
import asyncio
import json
import re
import signal
import socket
import struct
import time

REQUEST = re.compile(rb"^([A-Z]+) (\S+) HTTP/1\.[01]\r\n")


def route(method: str, target: str) -> str:
    parts = target.split("?")[0].split("/")
    for i in range(1, len(parts) - 1):
        if parts[i] == "sessions":
            parts[i + 1] = ":id"
    return f"{method} {'/'.join(parts)}"


class Conn:
    def __init__(self, name, writer):
        self.name, self.client, self.upstream = name, writer, None
        self.held, self.ws, self.pending = False, False, []  # (t, route)


class Proxy:
    def __init__(self, targets):
        self.targets = targets  # name -> (host, port)
        self.listen = {}  # name -> [host, port, server]
        self.mode, self.conns, self.windows = "pass", set(), []
        self.clear()

    def reset(self):
        self.windows.append(self.stats())  # the final line sums every window
        self.clear()

    def clear(self):
        self.accepted = self.rejected = self.cuts = self.ws_live_max = 0
        self.live_max = len(self.conns)
        self.by_path, self.wait_ms = {}, {}
        self.severed_ws, self.opens_by_window = 0, {}  # observation only

    async def start(self):
        for name, (host, _) in self.targets.items():
            self.listen[name] = [host, 0, None]  # bind where the target is
            await self.open(name)

    async def open(self, name):
        entry = self.listen[name]
        entry[2] = await asyncio.start_server(
            lambda r, w, n=name: self.handle(n, r, w),
            entry[0], entry[1], reuse_address=True)
        entry[1] = entry[2].sockets[0].getsockname()[1]

    @staticmethod
    def abort(writer):
        sock = writer.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                            struct.pack("ii", 1, 0))
        writer.transport.abort()

    def note_wait(self, key, ms):
        self.wait_ms[key] = max(self.wait_ms.get(key, 0), int(ms))

    async def handle(self, name, reader, writer):
        self.accepted += 1
        if self.mode == "rst":
            self.rejected += 1
            return self.abort(writer)
        conn = Conn(name, writer)
        conn.held = self.mode == "blackhole"
        self.conns.add(conn)
        self.live_max = max(self.live_max, len(self.conns))
        try:
            if not conn.held:
                host, port = self.targets[name]
                up_r, up_w = await asyncio.open_connection(host, port)
                conn.upstream = up_w
                asyncio.ensure_future(self.pump_up(conn, up_r))
            while chunk := await reader.read(65536):
                self.on_request(conn, chunk)
                if not conn.held and conn.upstream is not None:
                    conn.upstream.write(chunk)
        except OSError:
            pass
        finally:
            self.close(conn)

    def on_request(self, conn, chunk):
        match = REQUEST.match(chunk)
        key = match and route(match[1].decode(), match[2].decode())
        if not key:
            return
        self.by_path[key] = self.by_path.get(key, 0) + 1
        if key.endswith(" /api/ws"):
            conn.ws = True
            win = str(self.cuts)  # the cut window this upgrade arrives in
            self.opens_by_window[win] = self.opens_by_window.get(win, 0) + 1
            self.ws_live_max = max(
                self.ws_live_max, sum(1 for c in self.conns if c.ws))
        conn.pending.append((time.monotonic(), key))

    async def pump_up(self, conn, reader):
        try:
            while chunk := await reader.read(65536):
                if conn.pending:
                    t, key = conn.pending.pop(0)
                    self.note_wait(key, (time.monotonic() - t) * 1000)
                if not conn.held:
                    conn.client.write(chunk)
        except OSError:
            pass
        if not conn.held:  # a dead link relays no FIN: the client keeps waiting
            self.close(conn)

    def close(self, conn):
        if conn not in self.conns:
            return
        self.conns.discard(conn)
        for t, key in conn.pending:  # never answered
            self.note_wait(key, (time.monotonic() - t) * 1000)
        for w in (conn.client, conn.upstream):
            if w is not None:
                w.close()

    async def set_mode(self, mode):
        if mode == "refuse":
            for entry in self.listen.values():
                if entry[2] is not None:
                    entry[2].close()
                    entry[2] = None
        else:
            for name, entry in self.listen.items():
                if entry[2] is None:
                    await self.open(name)
        if mode == "blackhole":
            for conn in self.conns:
                conn.held = True
        if mode == "rst":
            self.severed_ws += sum(1 for c in self.conns if c.ws)
            for conn in list(self.conns):
                self.abort(conn.client)
                if conn.upstream is not None:
                    self.abort(conn.upstream)
                self.close(conn)
        self.cuts += mode != "pass" and mode != self.mode
        self.mode = mode

    async def flap(self, n, down, up):
        for _ in range(n):
            await self.set_mode("rst")
            await asyncio.sleep(down)
            await self.set_mode("pass")
            await asyncio.sleep(up)

    def stats(self):
        now = time.monotonic()
        wait = dict(self.wait_ms)
        for conn in self.conns:
            for t, key in conn.pending:
                wait[key] = max(wait.get(key, 0), int((now - t) * 1000))
        return {"mode": self.mode, "cuts": self.cuts, "accepted": self.accepted,
                "rejected": self.rejected, "live": len(self.conns),
                "live_max": self.live_max, "ws_live_max": self.ws_live_max,
                "by_path": self.by_path, "wait_ms": wait,
                "severed_ws": self.severed_ws,
                "ws_opens_by_window": dict(self.opens_by_window)}

    def lifetime(self):
        out = {"accepted": 0, "rejected": 0, "cuts": 0, "live_max": 0,
               "ws_live_max": 0, "by_path": {}}
        for s in self.windows + [self.stats()]:
            for key in ("accepted", "rejected", "cuts"):
                out[key] += s[key]
            for key in ("live_max", "ws_live_max"):
                out[key] = max(out[key], s[key])
            for path, n in s["by_path"].items():
                out["by_path"][path] = out["by_path"].get(path, 0) + n
        return out

    async def command(self, line):
        words = line.split() or [""]
        verb = words[0]
        if verb in ("pass", "blackhole", "rst", "refuse"):
            await self.set_mode(verb)
        elif verb == "flap" and len(words) == 4:
            n, down, up = int(words[1]), float(words[2]), float(words[3])
            asyncio.ensure_future(self.flap(n, down, up))
        elif verb == "reset":
            self.reset()
        elif verb != "stats":
            return {"ok": False, "error": f"unknown command {verb}"}
        return {"ok": True, **self.stats()}

    async def control(self, reader, writer):
        try:
            while line := await reader.readline():
                reply = await self.command(line.decode().strip())
                writer.write(json.dumps(reply).encode() + b"\n")
                await writer.drain()
        except (OSError, ValueError):
            pass
        writer.close()


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", action="append", required=True,
                    metavar="NAME=HOST:PORT")
    ap.add_argument("--control", required=True)
    ap.add_argument("--ports-file", required=True)
    args = ap.parse_args()
    targets = {}
    for spec in args.target:
        name, _, addr = spec.partition("=")
        host, _, port = addr.rpartition(":")
        targets[name] = (host, int(port))
    proxy = Proxy(targets)
    await proxy.start()
    await asyncio.start_unix_server(proxy.control, args.control)
    with open(args.ports_file, "w", encoding="utf-8") as out:
        for name, (host, port, _) in proxy.listen.items():
            out.write(f"{name}=http://{host}:{port}\n")  # sourceable env lines
    done, loop = asyncio.Event(), asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, done.set)
    await done.wait()
    s = proxy.lifetime()
    print(f"[e2e-net] accepted={s['accepted']} rejected={s['rejected']} "
          f"live_max={s['live_max']} ws_live_max={s['ws_live_max']} "
          f"cuts={s['cuts']} by_path={json.dumps(s['by_path'], sort_keys=True)}",
          flush=True)


if __name__ == "__main__":
    asyncio.run(main())
