#!/usr/bin/env python3
"""Deterministic tests of the gitleaks_fixture_mutations.py harness itself.

They pin the harness's control flow, not the gitleaks config; the real check
is still `tool/security/gitleaks_fixture_mutations.py` against real gitleaks.

- In-process cases swap `scan` for a fake scanner that mimics the default rules
  (control) and exact allowlists (candidate: lines identical to the committed
  fixture are allowlisted), so a "value the default rule filters" is exact.
- Subprocess cases point $GITLEAKS at a fake binary to drive version, exit-code,
  timeout and missing-report failures through the real subprocess path.

Run: python3 -B -m unittest discover -s tool/security -p '*_test.py'
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gitleaks_fixture_mutations as m  # noqa: E402

FILTERED = "F" * 26  # stands in for a value the default rule drops
SHAPE = re.compile(r'-----BEGIN|sk_live_')


class FakeScanner:
    def __init__(self, hide_in_candidate: str | None = None):
        self.originals = {rel: (m.REPO / rel).read_text(encoding="utf-8") for rel in m.PROTECTED}
        self.hide = hide_in_candidate
        self.tags: list[tuple[str, bool]] = []

    def __call__(self, work, files, tag, config=None):
        control = config == getattr(m, "CONTROL_CONFIG", object())
        self.tags.append((tag, control))
        out = []
        for rel, text in files.items():
            orig = set(self.originals[rel].split("\n"))
            for i, line in enumerate(text.split("\n"), 1):
                if not SHAPE.search(line) or FILTERED in line:
                    continue
                if not control and (line in orig or rel == self.hide):
                    continue
                out.append({"RuleID": m.PROTECTED[rel][0], "File": rel,
                            "StartLine": i, "EndLine": i})
        return out

    def count(self, control: bool) -> int:
        return sum(1 for _, c in self.tags if c == control)


def run_main(scanner, filter_draws):
    """Run main() with `scan` faked; ALNUM-26 draws in `filter_draws` (1-based,
    or "all") return FILTERED. Returns (rc, stdout, stderr, ssh_key calls)."""
    real_rand, real_ssh = m.rand, m.ssh_key
    draws = {"n": 0}
    ssh_calls = {"n": 0}

    def rand(alphabet, n):
        if alphabet == m.ALNUM and n == 26:
            draws["n"] += 1
            if filter_draws == "all" or draws["n"] in filter_draws:
                return FILTERED
        return real_rand(alphabet, n)

    def ssh_key(*a, **k):
        ssh_calls["n"] += 1
        return real_ssh(*a, **k)

    out, err = io.StringIO(), io.StringIO()
    with mock.patch.object(m, "scan", scanner), \
         mock.patch.object(m, "check_version", lambda work: None), \
         mock.patch.object(m, "rand", rand), \
         mock.patch.object(m, "ssh_key", ssh_key), \
         contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = m.main()
        except SystemExit as e:
            rc = e.code
    return rc, out.getvalue(), err.getvalue(), ssh_calls["n"]


class ControlFlowTest(unittest.TestCase):
    def test_value_the_default_rule_filters_is_regenerated_not_a_failure(self):
        # The Stripe token (the only ALNUM-26 draw) is one the default rule
        # itself ignores the first time.
        scanner = FakeScanner()
        rc, out, err, _ = run_main(scanner, {1})
        self.assertEqual(rc, 0, err)
        self.assertIn("5/5", out)
        self.assertEqual(scanner.count(control=True), 2)  # first control, then after regen
        self.assertIn("regenerated 1", out)

    def test_candidate_miss_after_control_detected_fails_without_regen(self):
        # Control sees every injection; the candidate config hides one file.
        scanner = FakeScanner(hide_in_candidate="test/cnx/ssh_tunnel_page_test.dart")
        rc, out, err, ssh_calls = run_main(scanner, set())
        self.assertEqual(rc, 1)
        self.assertIn("mutation not reported: private-key in test/cnx/ssh_tunnel_page_test.dart", err)
        self.assertIn("3/5", out)
        self.assertEqual(scanner.count(control=True), 1)   # no second control round
        self.assertEqual(scanner.count(control=False), 2)  # baseline + one candidate run
        self.assertEqual(ssh_calls, 4)                     # no SSH key regenerated

    def test_control_never_detecting_fails_after_bounded_regen(self):
        scanner = FakeScanner()
        rc, out, err, _ = run_main(scanner, "all")
        self.assertEqual(rc, 1)
        self.assertIn("control", err)
        self.assertIn("not detected by the default rules", err)
        self.assertEqual(scanner.count(control=True), m.MAX_CONTROL_ROUNDS)
        self.assertEqual(scanner.count(control=False), 1)  # baseline only, no candidate run


FAKE_GITLEAKS = r'''#!/usr/bin/env python3
import os, pathlib, sys, time
mode = os.environ["FAKE_GITLEAKS_MODE"]
if sys.argv[1] == "version":
    if mode == "version-old":
        print("v8.24.0"); sys.exit(0)
    if mode == "version-crash":
        sys.exit(2)
    print("8.30.1"); sys.exit(0)
control = "allowlists" not in pathlib.Path(".gitleaks.toml").read_text()
if mode == "control-crash" and control:
    sys.exit(2)
if mode == "hang":
    time.sleep(600)
if mode == "no-report":
    sys.exit(0)
report = sys.argv[sys.argv.index("--report-path") + 1]
pathlib.Path(report).write_text("[]")
sys.exit(0)
'''


class FailureModesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="fake-gitleaks.")
        cls.fake = Path(cls.tmp.name) / "gitleaks"
        cls.fake.write_text(FAKE_GITLEAKS)
        cls.fake.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_harness(self, mode):
        env = {k: v for k, v in os.environ.items() if k != "GITLEAKS_IMAGE"}
        env.update(GITLEAKS=str(self.fake), FAKE_GITLEAKS_MODE=mode,
                   GITLEAKS_TIMEOUT_SECONDS="2", PYTHONDONTWRITEBYTECODE="1")
        p = subprocess.run([sys.executable, "-B", str(HERE / "gitleaks_fixture_mutations.py")],
                           env=env, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertNotIn("PASS", p.stdout)
        self.assertNotIn("Traceback", p.stderr)
        return p.stderr

    def test_unsupported_version_fails(self):
        self.assertIn("need gitleaks >= 8.25.0", self.run_harness("version-old"))

    def test_version_command_error_fails(self):
        self.assertIn("version", self.run_harness("version-crash"))

    def test_control_scan_error_fails(self):
        err = self.run_harness("control-crash")
        self.assertIn("control", err)
        self.assertIn("exit 2", err)

    def test_scan_timeout_fails(self):
        self.assertIn("timed out", self.run_harness("hang"))

    def test_missing_report_fails(self):
        self.assertIn("report", self.run_harness("no-report"))


if __name__ == "__main__":
    unittest.main()
