import subprocess
import sys
import tempfile
import unittest
import os
from pathlib import Path


class ConsoleScopeGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.project = Path(__file__).resolve().parents[1]
        self.gate = self.project / "tool" / "spec060_console_scope_gate.py"

    def run_gate(
        self,
        root: Path,
        *paths: Path,
        base: Path | None = None,
        candidate: Path | None = None,
        sensitive_paths: tuple[Path, ...] = (),
    ) -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(self.gate), "--root", str(root)]
        if base is not None:
            command.extend(["--base", str(base)])
        if candidate is not None:
            command.extend(["--candidate", str(candidate)])
        for sensitive_path in sensitive_paths:
            command.extend(["--sensitive-path", str(sensitive_path)])
        command.extend(map(str, paths))
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_accepts_only_paths_resolving_inside_console_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "console"
            root.mkdir()
            inside = root / "lib" / "change.dart"
            inside.parent.mkdir()
            inside.write_text("ok", encoding="utf-8")
            result = self.run_gate(root, inside)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_upstream_or_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "console"
            upstream = base / "upstream" / "desktop.dart"
            root.mkdir()
            upstream.parent.mkdir()
            upstream.write_text("read only", encoding="utf-8")
            direct = self.run_gate(root, upstream)
            self.assertNotEqual(direct.returncode, 0)

            escape = root / "desktop-link"
            escape.symlink_to(upstream)
            linked = self.run_gate(root, escape)
            self.assertNotEqual(linked.returncode, 0)

    def test_base_candidate_rejects_added_undeclared_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            (base / "lib").mkdir(parents=True)
            (candidate / "lib").mkdir(parents=True)
            (base / "lib" / "declared.dart").write_text("old", encoding="utf-8")
            (candidate / "lib" / "declared.dart").write_text("new", encoding="utf-8")
            (candidate / "lib" / "undeclared.dart").write_text(
                "added", encoding="utf-8"
            )

            result = self.run_gate(
                candidate,
                Path("lib/declared.dart"),
                base=base,
                candidate=candidate,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing=lib/undeclared.dart", result.stderr)

    def test_base_candidate_discovers_symlink_escape_without_reading_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            outside = sandbox / "private" / "credential.txt"
            base.mkdir()
            candidate.mkdir()
            outside.parent.mkdir()
            outside.write_text("do-not-read", encoding="utf-8")
            (candidate / "link").symlink_to(outside)

            result = self.run_gate(
                candidate,
                Path("link"),
                base=base,
                candidate=candidate,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink", result.stderr)

    def test_base_candidate_accepts_exact_discovered_console_write_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            (base / "lib").mkdir(parents=True)
            (candidate / "lib").mkdir(parents=True)
            (base / "lib" / "change.dart").write_text("old", encoding="utf-8")
            (candidate / "lib" / "change.dart").write_text("new", encoding="utf-8")

            result = self.run_gate(
                candidate,
                Path("lib/change.dart"),
                base=base,
                candidate=candidate,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("discovered write-set: 1", result.stdout)

    def test_discovers_chmod_only_change_and_requires_exact_declaration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            base.mkdir()
            candidate.mkdir()
            (base / "script.sh").write_text("same", encoding="utf-8")
            (candidate / "script.sh").write_text("same", encoding="utf-8")
            os.chmod(base / "script.sh", 0o600)
            os.chmod(candidate / "script.sh", 0o700)

            missing = self.run_gate(candidate, base=base, candidate=candidate)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("missing=script.sh", missing.stderr)
            exact = self.run_gate(
                candidate,
                Path("script.sh"),
                base=base,
                candidate=candidate,
            )
            self.assertEqual(exact.returncode, 0, exact.stderr)

    def test_discovers_added_and_removed_empty_directories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            (base / "removed-empty").mkdir(parents=True)
            (candidate / "added-empty").mkdir(parents=True)

            result = self.run_gate(
                candidate,
                Path("added-empty"),
                Path("removed-empty"),
                base=base,
                candidate=candidate,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("discovered write-set: 2", result.stdout)

    def test_type_and_symlink_target_are_part_of_entry_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            base.mkdir()
            candidate.mkdir()
            (base / "kind").write_text("", encoding="utf-8")
            (candidate / "kind").mkdir()
            (base / "target-a").write_text("same", encoding="utf-8")
            (candidate / "target-a").write_text("same", encoding="utf-8")
            (base / "target-b").write_text("same", encoding="utf-8")
            (candidate / "target-b").write_text("same", encoding="utf-8")
            (base / "link").symlink_to("target-a")
            (candidate / "link").symlink_to("target-b")

            result = self.run_gate(
                candidate,
                Path("kind"),
                Path("link"),
                base=base,
                candidate=candidate,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_reports_missing_and_extra_in_posix_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            base.mkdir()
            candidate.mkdir()
            for name in ("zeta", "alpha"):
                (candidate / name).write_text(name, encoding="utf-8")

            result = self.run_gate(
                candidate,
                Path("omega"),
                base=base,
                candidate=candidate,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing=alpha,zeta; extra=omega", result.stderr)

    def test_sensitive_name_matrix_fails_closed_before_content_read(self) -> None:
        sensitive_names = (
            ".env.production",
            "release.env",
            "upload.pfx",
            "signing.key",
            "service-credentials.json",
            "api_token.txt",
            "db-password",
            "browser-cookies.sqlite",
            "session-store.db",
        )
        for name in sensitive_names:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                sandbox = Path(directory)
                base = sandbox / "base"
                candidate = sandbox / "candidate"
                base.mkdir()
                candidate.mkdir()
                secret = candidate / name
                secret.write_text("must-not-open", encoding="utf-8")
                os.chmod(secret, 0)
                try:
                    result = self.run_gate(
                        candidate,
                        Path(name),
                        base=base,
                        candidate=candidate,
                    )
                finally:
                    os.chmod(secret, 0o600)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refuses to read secret-bearing paths", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertNotIn("PermissionError", result.stderr)

    def test_explicit_sensitive_path_is_rejected_even_with_innocent_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            base.mkdir()
            candidate.mkdir()
            protected = candidate / "config.bin"
            protected.write_bytes(b"private")
            os.chmod(protected, 0)
            try:
                result = self.run_gate(
                    candidate,
                    Path("config.bin"),
                    base=base,
                    candidate=candidate,
                    sensitive_paths=(Path("config.bin"),),
                )
            finally:
                os.chmod(protected, 0o600)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("config.bin", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
    def test_explicit_sensitive_directory_is_never_traversed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            base = sandbox / "base"
            candidate = sandbox / "candidate"
            base.mkdir()
            protected = candidate / "innocent-config"
            protected.mkdir(parents=True)
            child = protected / "payload.bin"
            child.write_bytes(b"private")
            os.chmod(child, 0)
            try:
                result = self.run_gate(
                    candidate,
                    Path("innocent-config"),
                    base=base,
                    candidate=candidate,
                    sensitive_paths=(Path("innocent-config"),),
                )
            finally:
                os.chmod(child, 0o600)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("innocent-config", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertNotIn("PermissionError", result.stderr)


if __name__ == "__main__":
    unittest.main()
