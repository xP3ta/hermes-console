#!/usr/bin/env python3
"""Tear down every process the real-gateway E2E lane started, within a budget.

``backend.py`` starts ``hermes serve`` and ``gateway.run`` in their own
sessions (process groups), so killing the backend alone leaves them, their
listeners and their sockets behind. Every process of the lane carries
``HERMES_E2E_LANE=<lane id>`` in its environment and every child group is
appended to ``<run>/children.pgid`` when it is spawned. This reaper:

1. collects the lane's processes: every PID whose environment holds the exact
   marker, plus every member of a recorded group while any member of that
   group holds it, or while the group was proven ours on an earlier pass of
   this run. A process group cannot be reused while it has a member, so once
   proven, a group stays ours until it is empty, even after its leader exits
   and the survivors scrubbed the marker. A recorded group whose leader
   (PID == PGID) is gone but which still has members is ours too: Linux keeps
   a PGID pinned while the group is non-empty, and a reused PGID needs a live
   creator with that PID. A recorded group with a live, unmarked leader and
   no marked member is a reused PGID and is left alone;
2. sends SIGTERM to all of them at once, waits up to half the budget;
3. sends SIGKILL to whatever is left and waits for it to disappear;
4. exits 0 only when no marked process remains, 1 otherwise.

Stdlib only (runs before any venv exists, and in CI). Linux ``/proc`` only.
Residuals: a descendant that both scrubs its environment and calls
``setsid()`` escapes; only a cgroup could contain that. A foreign group that
reused one of our recorded PGIDs (ours emptied, the PID wrapped to the same
number) and whose own creator already exited looks leaderless too; that
needs a full PID wrap within one lane run.

Usage: reap.py --marker ID [--pgid-file PATH] [--budget SECONDS]
"""

from __future__ import annotations

import argparse
import os
import signal
import sys
import time
from pathlib import Path

MARKER_VAR = "HERMES_E2E_LANE"


def _environ(pid: int) -> bytes:
    try:
        return Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return b""


def _alive(pid: int) -> bool:
    """True for a running (non-zombie) process."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return False
    # The state follows the parenthesised command name.
    return stat[stat.rfind(")") + 2:][:1] not in ("Z", "X", "")


def _pids() -> list[int]:
    return [int(p) for p in os.listdir("/proc") if p.isdigit()]


def _pgid(pid: int) -> int | None:
    try:
        return os.getpgid(pid)
    except OSError:
        return None


def lane_processes(marker: str, recorded_pgids: set[int],
                   owned_pgids: set[int] | None = None) -> set[int]:
    """Live PIDs of the lane (never this reaper).

    [owned_pgids] (updated in place) remembers the recorded groups proven to
    be the lane's: a still non-empty group keeps its PGID, so it cannot have
    been reused since it was proven.
    """
    owned = owned_pgids if owned_pgids is not None else set()
    needle = f"{MARKER_VAR}={marker}".encode()
    me = os.getpid()
    marked: set[int] = set()
    by_group: dict[int, list[int]] = {}
    for pid in _pids():
        if pid == me or not _alive(pid):
            continue
        if needle in _environ(pid).split(b"\0"):
            marked.add(pid)
        group = _pgid(pid)
        if group in recorded_pgids:
            by_group.setdefault(group, []).append(pid)
    for group, members in by_group.items():
        # Any marked member proves the group is ours, not a reused PGID; a
        # proven group stays ours while it has members (its PGID is pinned).
        leaderless = group not in members and not _alive(group)
        if (group in owned or leaderless
                or any(pid in marked for pid in members)):
            owned.add(group)
            marked.update(members)
    # An emptied group may be reused from now on: forget it.
    owned.intersection_update(by_group)
    return marked


def _signal(pids: set[int], sig: int) -> None:
    for pid in pids:
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def reap(marker: str, recorded_pgids: set[int], budget: float) -> set[int]:
    """Kill the lane within [budget] seconds; return the survivors."""
    deadline = time.monotonic() + budget
    term_until = time.monotonic() + budget / 2
    owned: set[int] = set()
    pids = lane_processes(marker, recorded_pgids, owned)
    _signal(pids, signal.SIGTERM)
    while pids and time.monotonic() < term_until:
        time.sleep(0.1)
        pids = lane_processes(marker, recorded_pgids, owned)
    while pids and time.monotonic() < deadline:
        _signal(pids, signal.SIGKILL)
        time.sleep(0.1)
        pids = lane_processes(marker, recorded_pgids, owned)
    return pids


def read_pgids(path: Path | None) -> set[int]:
    if path is None:
        return set()
    try:
        lines = path.read_text().split()
    except OSError:
        return set()
    return {int(x) for x in lines if x.isdigit() and int(x) > 1}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--marker", required=True)
    parser.add_argument("--pgid-file", type=Path)
    parser.add_argument("--budget", type=float, default=10.0)
    args = parser.parse_args()
    if len(args.marker) < 16 or not args.marker.isalnum():
        print("reap: refusing a short or non-alphanumeric marker", file=sys.stderr)
        return 2
    survivors = reap(args.marker, read_pgids(args.pgid_file), args.budget)
    if survivors:
        print(f"reap: {len(survivors)} lane process(es) survived: {sorted(survivors)}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
