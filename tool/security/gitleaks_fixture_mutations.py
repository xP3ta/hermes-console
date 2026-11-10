#!/usr/bin/env python3
"""Proves the fixture allowlists in .gitleaks.toml are exact, not path-wide.

Why: some committed test fixtures hold synthetic values that trip gitleaks
rules (a fake Stripe key, throwaway SSH keys). The config allowlists them by rule AND exact path AND exact value or
exact line. This check fails if that ever widens, in four steps:

1. Config: every path-scoped allowlist names targetRules and at least one
   regex (no path-only exceptions).
2. Baseline: the committed fixtures, copied to their real paths in a scratch
   dir and scanned with the repository config, report nothing.
3. Control: the same mutated files are scanned with gitleaks' DEFAULT rules
   and no exceptions (same binary). A fresh value the default rule itself
   ignores is regenerated, at most MAX_CONTROL_ROUNDS times; if control still misses one,
   the run FAILS. Regeneration never looks at the candidate config.
4. Mutation: the exact bytes control detected, scanned with the repository
   config, must be reported at every injected line. A miss here is a real
   FAIL: nothing is regenerated or retried.

A gitleaks error, timeout, missing report or unsupported version is a FAIL.

Every injected value is generated at run time and the report is redacted, so
no secret-shaped literal is committed or printed.

Usage:
  tool/security/gitleaks_fixture_mutations.py                 # gitleaks from PATH (or $GITLEAKS)
  GITLEAKS_IMAGE=zricethezav/gitleaks@sha256:... tool/security/gitleaks_fixture_mutations.py
"""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import string
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
# [[allowlists]] with targetRules arrived in gitleaks 8.25.0.
MIN_VERSION = (8, 25, 0)
ALNUM = string.ascii_letters + string.digits
# Default rules only, no exceptions: the control the candidate is held to.
CONTROL_CONFIG = "[extend]\nuseDefault = true\n"
MAX_CONTROL_ROUNDS = 8
TIMEOUT = float(os.environ.get("GITLEAKS_TIMEOUT_SECONDS", "300"))


def rand(alphabet: str, n: int) -> str:
    return "".join(secrets.choice(alphabet) for _ in range(n))


def ssh_key(work: Path, name: str, locked: bool) -> list[str]:
    if shutil.which("ssh-keygen") is None:
        sys.exit("gitleaks fixture mutations: ssh-keygen is required")
    key = work / name
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-C", "mutation",
         "-N", rand(ALNUM, 24) if locked else "", "-f", str(key)],
        check=True,
    )
    lines = key.read_text().strip().splitlines()
    key.unlink()
    key.with_suffix(".pub").unlink()
    return lines


def stripe(_: Path) -> list[str]:
    token = "sk" + "_live_" + rand(ALNUM, 26)
    return [f"      'example.com key {token}',"]


def ssh(i: int, locked: bool):
    def block(work: Path) -> list[str]:
        lines = ssh_key(work, f"k{i}", locked)
        lines[0] = f"const _leakedKey{i} = '''" + lines[0]
        lines[-1] += "''';"
        return lines
    return block


SSH = [ssh(0, False), ssh(1, True)]


# path -> line after which a block is inserted (instead of appended)
INSERT_AFTER: dict[str, tuple] = {}

# path -> (rule each injection must trigger, blocks appended in order)
PROTECTED = {
    "test/release_log_redaction_test.dart": ("stripe-access-token", [stripe]),
    "test/ssh_tunnel/ssh_tunnel_connector_test.dart": ("private-key", SSH),
    "test/cnx/ssh_tunnel_page_test.dart": ("private-key", SSH),
}


def gitleaks_cmd(scan: Path, out: Path) -> tuple[list[str], str]:
    image = os.environ.get("GITLEAKS_IMAGE")
    if image:
        return (["docker", "run", "--rm", "-v", f"{scan}:/scan:ro",
                 "-v", f"{out}:/out", "-w", "/scan", image], "/out")
    return [os.environ.get("GITLEAKS", "gitleaks")], str(out)


def run(cmd: list[str], what: str, **kw) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, timeout=TIMEOUT, **kw)
    except subprocess.TimeoutExpired:
        sys.exit(f"gitleaks fixture mutations: FAIL: {what} timed out after {TIMEOUT:g}s")
    except OSError as e:
        sys.exit(f"gitleaks fixture mutations: FAIL: {what} could not run: {e.strerror}")


def check_version(work: Path) -> None:
    cmd, _ = gitleaks_cmd(work, work)
    p = run(cmd + ["version"], "gitleaks version", capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"gitleaks fixture mutations: FAIL: gitleaks version failed with exit {p.returncode}")
    raw = p.stdout.strip()
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", raw)
    if not m or tuple(map(int, m.groups())) < MIN_VERSION:
        sys.exit(f"gitleaks fixture mutations: need gitleaks >= 8.25.0, got {raw!r}")
    print(f"gitleaks version {raw} (>= 8.25.0)")


def check_config() -> list[str]:
    cfg = tomllib.loads((REPO / ".gitleaks.toml").read_text(encoding="utf-8"))
    errors = []
    for a in cfg.get("allowlists", []):
        if not a.get("paths"):
            continue
        name = a.get("description", "?")
        if not a.get("targetRules"):
            errors.append(f"path-scoped allowlist without targetRules: {name}")
        if not a.get("regexes"):
            errors.append(f"path-only allowlist (no regexes): {name}")
        elif a.get("condition") != "AND":
            errors.append(f"path-scoped allowlist without condition = AND: {name}")
    return errors


def scan(work: Path, files: dict[str, str], tag: str, config: str) -> list[dict]:
    root = work / tag
    out = work / f"{tag}-out"
    out.mkdir(mode=0o777)
    out.chmod(0o777)
    root.mkdir()
    (root / ".gitleaks.toml").write_text(config, encoding="utf-8")
    for rel, text in files.items():
        dest = root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")
    for p in [root, *root.rglob("*")]:
        p.chmod(0o755 if p.is_dir() else 0o644)
    cmd, out_dir = gitleaks_cmd(root, out)
    rc = run(
        cmd + ["dir", ".", "--no-banner", "--redact=100", "--exit-code", "3",
               "--report-format", "json", "--report-path", f"{out_dir}/report.json"],
        f"{tag} scan", cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    if rc not in (0, 3):
        sys.exit(f"gitleaks fixture mutations: FAIL: {tag} scan failed with exit {rc}")
    try:
        return json.loads((out / "report.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        sys.exit(f"gitleaks fixture mutations: FAIL: {tag} scan wrote no readable report")


def key(f: dict) -> tuple[str, str, int, int]:
    return (f.get("RuleID", ""), f["File"].replace("\\", "/").removeprefix("./"),
            f["StartLine"], f["EndLine"])


def build(originals: dict[str, str], blocks: dict) -> tuple[dict[str, str], dict]:
    """Mutated files plus slot -> (rule, path, first line of the injected block)."""
    files, expected = {}, {}
    for rel, (rule, _) in PROTECTED.items():
        lines = originals[rel].rstrip("\n").split("\n")
        if rel in INSERT_AFTER:
            after = INSERT_AFTER[rel][0]
            lines[after:after] = blocks[(rel, "insert")]
            expected[(rel, "insert")] = (rule, rel, after + 1)
        i = 0
        while (rel, i) in blocks:
            expected[(rel, i)] = (rule, rel, len(lines) + 1)
            lines.extend(blocks[(rel, i)])
            i += 1
        files[rel] = "\n".join(lines) + "\n"
    return files, expected


def covers(f, e) -> bool:
    # A finding counts for an injected line when its span covers it.
    return f[:2] == e[:2] and f[2] <= e[2] <= f[3]


def main() -> int:
    failures = check_config()
    work = Path(tempfile.mkdtemp(prefix="gitleaks-mutations."))
    try:
        work.chmod(0o755)
        check_version(work)
        candidate = (REPO / ".gitleaks.toml").read_text(encoding="utf-8")
        originals = {rel: (REPO / rel).read_text(encoding="utf-8") for rel in PROTECTED}

        base = scan(work, originals, "baseline", candidate)
        for k in sorted({key(f)[:2] for f in base}):
            n = sum(1 for f in base if key(f)[:2] == k)
            failures.append(f"baseline: {n} finding(s) {k[0]} in {k[1]}")
        print(f"baseline: {len(base)} finding(s) in {len(originals)} protected files")

        gens = {(rel, i): g for rel, (_, gs) in PROTECTED.items() for i, g in enumerate(gs)}
        gens.update({(rel, "insert"): g for rel, (_, g) in INSERT_AFTER.items()})
        blocks = {slot: g(work) for slot, g in gens.items()}
        regenerated = 0
        for rnd in range(1, MAX_CONTROL_ROUNDS + 1):
            mutated, expected = build(originals, blocks)
            ctrl = {key(f) for f in scan(work, mutated, f"control{rnd}", CONTROL_CONFIG)}
            missed = [s for s, e in expected.items() if not any(covers(f, e) for f in ctrl)]
            if not missed:
                break
            if rnd == MAX_CONTROL_ROUNDS:
                for s in sorted(missed, key=str):
                    e = expected[s]
                    failures.append(f"control: {e[0]} in {e[1]}:{e[2]} not detected by the "
                                    f"default rules after {MAX_CONTROL_ROUNDS} rounds")
                print(f"control: {len(expected) - len(missed)}/{len(expected)} detected "
                      f"by default rules; candidate not run")
                return report(failures)
            regenerated += len(missed)
            for s in missed:
                blocks[s] = gens[s](work)
        print(f"control: {len(expected)}/{len(expected)} detected by default rules "
              f"(rounds {rnd}, regenerated {regenerated})")

        # Same bytes control detected; a miss now is the candidate's, never retried.
        found = {key(f) for f in scan(work, mutated, "mutation", candidate)}
        exp = set(expected.values())
        caught = {e for e in exp if any(covers(f, e) for f in found)}
        for miss in sorted(exp - caught):
            failures.append(f"mutation not reported: {miss[0]} in {miss[1]}:{miss[2]}")
        for extra in sorted(f for f in found if not any(covers(f, e) for e in exp)):
            failures.append(f"mutation run, unexpected finding: {extra[:3]}")
        print(f"mutation: {len(caught)}/{len(exp)} injected secrets "
              f"reported across {len(PROTECTED)} protected files")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return report(failures)


def report(failures: list[str]) -> int:
    if failures:
        print("gitleaks fixture mutations: FAIL", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("gitleaks fixture mutations: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
