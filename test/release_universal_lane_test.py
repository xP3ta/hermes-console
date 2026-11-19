"""Proposed `direct-universal` double-build lane (one universal APK).

The lane only builds and compares privately. It does not make a universal APK
publishable: the reviewed contract, the public binding and the public asset
allowlist still name the three split APKs, and these tests pin that.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYTHON = sys.executable
FIXTURE_ENV = {
    "ANDROID_HOME": "/fixture/android-home",
    "ANDROID_SDK_ROOT": "/fixture/android-sdk-root",
    "JAVA_HOME": "/fixture/java-home",
}


def git(path: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(path), *args], check=True, capture_output=True, text=True
    )


def fixture_source(root: Path) -> tuple[Path, str]:
    source = root / "source"
    source.mkdir()
    git(source, "init", "-q")
    git(source, "config", "user.email", "fixture@example.invalid")
    git(source, "config", "user.name", "Fixture")
    shutil.copy2(ROOT / "pubspec.lock", source / "pubspec.lock")
    (source / "pubspec.yaml").write_text("name: fixture\nversion: 1.2.3+4\n", encoding="utf-8")
    (source / "android").mkdir()
    (source / "android/build.gradle").write_text("// fixture\n", encoding="utf-8")
    git(source, "add", ".")
    git(source, "commit", "-q", "-m", "fixture")
    return source, git(source, "rev-parse", "HEAD").stdout.strip()


def fake_flutter(tools: Path, *, universal_only: bool) -> Path:
    """A deterministic stand-in for `flutter` that records nothing secret.

    Without --split-per-abi it emits the universal APK; with it, the splits.
    `universal_only` makes it ignore the flag, to show the split lane refuses
    a universal-only output.
    """
    tools.mkdir()
    flutter = tools / "flutter"
    flutter.write_text(
        "#!/usr/bin/env bash\n"
        "set -Eeuo pipefail\n"
        "if [[ $1 == pub ]]; then exit 0; fi\n"
        "[[ $1 == build && $2 == apk ]]\n"
        "mkdir -p build/app/outputs/flutter-apk\n"
        "split=0; for arg in \"$@\"; do [[ $arg == --split-per-abi ]] && split=1; done\n"
        + ("split=0\n" if universal_only else "")
        + "if [[ $split == 1 ]]; then\n"
        "  for name in app-arm64-v8a-full-release.apk app-armeabi-v7a-full-release.apk app-x86_64-full-release.apk; do\n"
        "    printf 'deterministic split fixture: %s\\n' \"$name\" > \"build/app/outputs/flutter-apk/$name\"\n"
        "  done\n"
        "else\n"
        "  printf 'deterministic universal fixture\\n' > build/app/outputs/flutter-apk/app-full-release.apk\n"
        "fi\n",
        encoding="utf-8",
    )
    flutter.chmod(0o700)
    return flutter


def double_build(root: Path, channel: str, source: Path, commit: str, tools: Path, output: Path):
    key_properties = root / "key.properties"
    key_properties.write_text("storeFile=/nonexistent-fixture\n", encoding="utf-8")
    return subprocess.run(
        [
            "bash", str(ROOT / "tool/release/double_build.sh"),
            channel, str(source), commit, str(key_properties), str(output), "ab" * 32,
        ],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "TMPDIR": str(root), **FIXTURE_ENV},
    )


class UniversalLaneTest(unittest.TestCase):
    def test_universal_lane_builds_twice_and_records_one_universal_apk(self):
        with tempfile.TemporaryDirectory(prefix="univ-lane-") as temporary:
            root = Path(temporary)
            source, commit = fixture_source(root)
            fake_flutter(root / "tools", universal_only=False)
            output = root / "double-output-private"
            result = double_build(root, "direct-universal", source, commit, root / "tools", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "double-build-manifest.json").read_text())
            report = json.loads((output / "rebuild-comparison.json").read_text())
            self.assertEqual(sorted(p.name for p in (output / "replica-a").iterdir()), ["app-full-release.apk"])
            self.assertEqual(sorted(p.name for p in (output / "replica-b").iterdir()), ["app-full-release.apk"])
        self.assertEqual(manifest["channel"], "direct-universal")
        self.assertEqual(manifest["source"]["commit"], commit)
        self.assertNotIn("--split-per-abi", manifest["build"]["command"])
        self.assertEqual(
            manifest["build"]["command"],
            "flutter build apk --release --flavor full --dart-define=HERMES_FLAVOR=full",
        )
        self.assertEqual(report["channel"], "direct-universal")
        self.assertTrue(report["observedTwoBuildByteIdentity"])
        self.assertEqual([a["name"] for a in report["artifacts"]], ["app-full-release.apk"])

    def test_universal_lane_only_writes_to_a_private_output(self):
        with tempfile.TemporaryDirectory(prefix="univ-lane-") as temporary:
            root = Path(temporary)
            source, commit = fixture_source(root)
            fake_flutter(root / "tools", universal_only=False)
            for name in ("double-output", "double-output-private-public"):
                with self.subTest(output=name):
                    output = root / name
                    result = double_build(root, "direct-universal", source, commit, root / "tools", output)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())

    def test_split_lane_still_refuses_a_universal_only_output(self):
        with tempfile.TemporaryDirectory(prefix="univ-lane-") as temporary:
            root = Path(temporary)
            source, commit = fixture_source(root)
            fake_flutter(root / "tools", universal_only=True)
            output = root / "double-output"
            result = double_build(root, "direct-public", source, commit, root / "tools", output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_universal_output_is_not_publishable_through_the_public_binding(self):
        with tempfile.TemporaryDirectory(prefix="univ-lane-") as temporary:
            root = Path(temporary)
            source, commit = fixture_source(root)
            fake_flutter(root / "tools", universal_only=False)
            output = root / "double-output-private"
            built = double_build(root, "direct-universal", source, commit, root / "tools", output)
            self.assertEqual(built.returncode, 0, built.stderr)
            binding = root / "binding.json"
            bound = subprocess.run(
                [
                    PYTHON, str(ROOT / "tool/release/public_build_binding.py"), "write",
                    "--root", str(source),
                    "--double-build-manifest", str(output / "double-build-manifest.json"),
                    "--binding", str(binding),
                    "--artifact", str(output / "replica-a" / "app-full-release.apk"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(bound.returncode, 0, bound.stdout + bound.stderr)
            self.assertFalse(binding.exists())

    def _flutter_script(self, tools: Path, body: str) -> None:
        tools.mkdir()
        flutter = tools / "flutter"
        flutter.write_text(
            "#!/usr/bin/env bash\n"
            "set -Eeuo pipefail\n"
            "if [[ $1 == pub ]]; then exit 0; fi\n"
            "[[ $1 == build && $2 == apk ]]\n"
            "mkdir -p build/app/outputs/flutter-apk\n" + body,
            encoding="utf-8",
        )
        flutter.chmod(0o700)

    # The fake flutter learns which replica it is building from a counter kept
    # next to itself (outside the build root): the two replicas now share one
    # canonical path, so the path no longer tells them apart.
    _REPLICA = (
        'count_file="$(dirname "$0")/count"\n'
        'n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))\n'
        'echo "$n" > "$count_file"\n'
    )

    def test_both_replicas_build_at_one_canonical_path(self):
        # 1.4.1: each replica built at its own absolute path (source-a/-b,
        # pub-cache-a/-b), and the path ended up inside libapp.so (the Dart
        # registrant's library key), libwhisper.so (__FILE__) and the build-id
        # of libdartjni.so, so the two builds could never compare equal.
        with tempfile.TemporaryDirectory(prefix="univ-lane-") as temporary:
            root = Path(temporary)
            source, commit = fixture_source(root)
            self._flutter_script(
                root / "tools",
                self._REPLICA
                + 'printf "%s|%s|%s|%s\\n" "$PWD" "$HOME" "$PUB_CACHE" "$GRADLE_USER_HOME" >> "$(dirname "$0")/paths.log"\n'
                "printf 'deterministic universal fixture\\n' > build/app/outputs/flutter-apk/app-full-release.apk\n",
            )
            output = root / "double-output-private"
            result = double_build(root, "direct-universal", source, commit, root / "tools", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            paths = (root / "tools/paths.log").read_text().splitlines()
        self.assertEqual(len(paths), 2)
        self.assertEqual(paths[0], paths[1], "both replicas build at the same absolute paths")

    def test_replica_b_starts_from_an_empty_canonical_root(self):
        # Same path, independent builds: nothing replica A left in the tree,
        # HOME, PUB_CACHE or GRADLE_USER_HOME may be there when B starts (and
        # two full trees at once ran the 1.4.1 build host out of disk).
        with tempfile.TemporaryDirectory(prefix="univ-lane-") as temporary:
            root = Path(temporary)
            source, commit = fixture_source(root)
            self._flutter_script(
                root / "tools",
                self._REPLICA
                + 'if [[ $n == 2 ]]; then\n'
                '  for d in "$PWD/build/marker" "$HOME/marker" "$PUB_CACHE/marker" "$GRADLE_USER_HOME/marker"; do\n'
                '    [[ ! -e $d ]] || exit 3\n'
                '  done\n'
                'fi\n'
                'for d in "$PWD/build" "$HOME" "$PUB_CACHE" "$GRADLE_USER_HOME"; do mkdir -p "$d"; touch "$d/marker"; done\n'
                "printf 'deterministic universal fixture\\n' > build/app/outputs/flutter-apk/app-full-release.apk\n",
            )
            output = root / "double-output-private"
            result = double_build(root, "direct-universal", source, commit, root / "tools", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((output / "replica-b" / "app-full-release.apk").is_file())

    def test_a_failed_replica_leaves_no_signed_stage_even_if_work_cannot_be_removed(self):
        # 1.4.1 on the build host: `rm -rf WORK` failed (a daemon still writing there)
        # and, under errexit, the stage with replica A's signed artifact stayed.
        with tempfile.TemporaryDirectory(prefix="univ-lane-") as temporary:
            root = Path(temporary)
            source, commit = fixture_source(root)
            self._flutter_script(
                root / "tools",
                self._REPLICA
                + "if [[ $n == 2 ]]; then\n"
                "  mkdir -p ../stuck/inner && touch ../stuck/inner/file && chmod 500 ../stuck/inner\n"
                "  exit 1\n"
                "fi\n"
                "printf 'deterministic universal fixture\\n' > build/app/outputs/flutter-apk/app-full-release.apk\n",
            )
            output = root / "double-output-private"
            try:
                result = double_build(root, "direct-universal", source, commit, root / "tools", output)
                residue = sorted(p.name for p in root.glob(".double-build.*"))
                signed = sorted(str(p.relative_to(root)) for p in root.rglob("app-full-release.apk"))
            finally:
                for stuck in root.rglob("stuck"):
                    for path in [stuck, *stuck.rglob("*")]:
                        if path.is_dir():
                            path.chmod(0o700)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertEqual(residue, [], "no unpromoted stage is left behind")
            self.assertEqual(signed, [], "no replica artifact is left anywhere")

    def test_a_failed_comparison_keeps_its_report_but_no_signed_artifact(self):
        # 1.4.1: the gate deleted its own comparison report with the stage, so
        # the difference class of the failure could not be read afterwards.
        with tempfile.TemporaryDirectory(prefix="univ-lane-") as temporary:
            root = Path(temporary)
            source, commit = fixture_source(root)
            self._flutter_script(
                root / "tools",
                self._REPLICA
                + "printf 'universal fixture of build %s\\n' \"$n\" > build/app/outputs/flutter-apk/app-full-release.apk\n",
            )
            output = root / "double-output-private"
            result = double_build(root, "direct-universal", source, commit, root / "tools", output)
            kept = root / "double-output-private.failed-rebuild-comparison.json"
            report = json.loads(kept.read_text()) if kept.is_file() else None
            mode = kept.stat().st_mode & 0o777 if kept.is_file() else None
            residue = sorted(p.name for p in root.glob(".double-build.*"))
            signed = sorted(str(p.relative_to(root)) for p in root.rglob("*.apk"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertIsNotNone(report, "the failed comparison report is kept")
        self.assertFalse(report["gatePassed"])
        self.assertEqual(report["differenceClass"], "signed-apk-bytes-differ")
        self.assertEqual(mode, 0o600)
        self.assertEqual(residue, [], "no unpromoted stage is left behind")
        self.assertEqual(signed, [], "no replica artifact is left anywhere")

    def test_contract_still_lists_only_the_split_public_assets(self):
        contract = json.loads((ROOT / "tool/release/release_contract.json").read_text(encoding="utf-8"))
        self.assertNotIn("app-full-release.apk", contract["channels"]["direct-public"]["publicAssets"])
        self.assertNotIn("direct-universal", contract["channels"])


if __name__ == "__main__":
    unittest.main()
