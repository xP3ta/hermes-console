import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

for inherited_git_variable in (
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_DIR",
    "GIT_WORK_TREE",
):
    os.environ.pop(inherited_git_variable, None)

ROOT = Path(__file__).resolve().parents[1]
PYTHON = sys.executable
sys.path.insert(0, str(ROOT / "tool/release"))
import validate_public_apk_provenance as public_provenance_validator
APKS = {
    "app-arm64-v8a-full-release.apk": "arm64-v8a",
    "app-armeabi-v7a-full-release.apk": "armeabi-v7a",
    "app-x86_64-full-release.apk": "x86_64",
}
EVIDENCE_FILES = {
    "rebuild-comparison.json",
    *{
        f"artifacts/full/{Path(name).stem}/{leaf}"
        for name in APKS
        for leaf in (
            "fullRelease.cdx.json",
            "fullRelease.artifact.json",
            "fullRelease.license-review.json",
            "source-assets.json",
            "public-apk-facts.json",
        )
    },
}


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def make_evidence_archive(root: Path, *, omit=(), extras=(), rebuild_pass=True):
    evidence = root / "release-evidence"
    evidence.mkdir()
    omitted = set(omit)
    for relative in sorted(EVIDENCE_FILES - omitted):
        path = evidence / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if relative == "rebuild-comparison.json":
            payload = canonical(
                {
                    "schema": 1,
                    "channel": "direct-public",
                    "gatePassed": rebuild_pass,
                    "byteReproducible": False,
                    "inputsCryptographicallyPinned": False,
                    "observedTwoBuildByteIdentity": rebuild_pass,
                    "claim": "observed-two-build-byte-identical" if rebuild_pass else "observed-two-build-bytes-differ",
                    "artifacts": [
                        {
                            "name": name,
                            "byteIdentical": rebuild_pass,
                            "firstSha256": "a" * 64,
                            "secondSha256": "a" * 64 if rebuild_pass else "b" * 64,
                        }
                        for name in APKS
                    ],
                }
            )
        elif relative.endswith("license-review.json"):
            payload = canonical(
                {
                    "schema": 1,
                    "status": "COMPLETE",
                    "dependencyComponents": [{"id": "pkg:fixture", "license": "MIT", "evidence": "LICENSE"}],
                    "sourceAssets": [{"path": "assets/fixture", "license": "MIT", "evidence": "LICENSE"}],
                    "packagedEntries": [{"path": "lib/fixture.so", "license": "MIT", "evidence": "LICENSE"}],
                    "unresolved": [],
                }
            )
        else:
            payload = canonical({"schema": 1, "fixture": relative})
        path.write_bytes(payload)
    for relative in extras:
        path = evidence / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"malicious\n")
    checksums = []
    for path in sorted(p for p in evidence.rglob("*") if p.is_file()):
        relative = path.relative_to(evidence).as_posix()
        checksums.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}\n")
    (evidence / "SHA256SUMS").write_text("".join(checksums), encoding="utf-8")
    archive = root / "evidence.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        output.add(evidence, arcname="release-evidence")
    return archive


class Slice1EvidenceSchemaTest(unittest.TestCase):
    def run_validator(self, archive: Path):
        return subprocess.run(
            [PYTHON, str(ROOT / "tool/release/validate_evidence_archive.py"), str(archive)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_valid_exact_evidence_schema_passes(self):
        with tempfile.TemporaryDirectory(prefix="s09-evidence-valid-") as temporary:
            result = self.run_validator(make_evidence_archive(Path(temporary)))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_omitted_required_evidence_and_private_extras_fail(self):
        malicious = (
            ({next(path for path in EVIDENCE_FILES if path.endswith("fullRelease.cdx.json"))}, set()),
            ({next(path for path in EVIDENCE_FILES if path.endswith("fullRelease.license-review.json"))}, set()),
            ({"rebuild-comparison.json"}, set()),
            (set(), {"app-play-release.aab"}),
            (set(), {"qa/app-qa-profile.apk"}),
            (set(), {"mapping.txt"}),
            (set(), {"release.keystore"}),
        )
        for omitted, extras in malicious:
            with self.subTest(omitted=omitted, extras=extras), tempfile.TemporaryDirectory(prefix="s09-evidence-bad-") as temporary:
                result = self.run_validator(
                    make_evidence_archive(Path(temporary), omit=omitted, extras=extras)
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_reproducible_direct_rebuild_report_fails(self):
        with tempfile.TemporaryDirectory(prefix="s09-evidence-rebuild-bad-") as temporary:
            result = self.run_validator(
                make_evidence_archive(Path(temporary), rebuild_pass=False)
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tar_member_bomb_is_stream_rejected_before_materialization(self):
        with tempfile.TemporaryDirectory(prefix="s09-tar-member-bomb-") as temporary:
            archive = Path(temporary) / "member-bomb.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                for index in range(10_000):
                    member = tarfile.TarInfo(f"release-evidence/bomb-{index}")
                    member.type = tarfile.DIRTYPE
                    output.addfile(member)
            result = self.run_validator(archive)
        validator = (ROOT / "tool/release/validate_evidence_archive.py").read_text(
            encoding="utf-8"
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("getmembers(", validator)
        self.assertIn("MAX_ARCHIVE_BYTES", validator)


class Slice1PublicAssetAllowlistTest(unittest.TestCase):
    def fixture(self, root: Path):
        public = root / "release-public"
        public.mkdir()
        archive = make_evidence_archive(root)
        shutil.move(archive, public / "hermes-console-release-evidence.tar.gz")
        for name in APKS:
            (public / name).write_bytes((name + "\n").encode())
        (public / "provenance.intoto.jsonl").write_bytes(b'{"fixture":"dsse"}\n')
        checksummed = [
            *APKS,
            "hermes-console-release-evidence.tar.gz",
            "provenance.intoto.jsonl",
        ]
        (public / "SHA256SUMS").write_text(
            "".join(
                f"{hashlib.sha256((public / name).read_bytes()).hexdigest()}  {name}\n"
                for name in checksummed
            ),
            encoding="ascii",
        )
        return public

    def run_validator(self, public: Path):
        return subprocess.run(
            ["bash", str(ROOT / "tool/release/validate_public_assets.sh"), str(public), "--assets-only"],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_exact_six_public_assets_pass(self):
        with tempfile.TemporaryDirectory(prefix="s09-public-valid-") as temporary:
            result = self.run_validator(self.fixture(Path(temporary)))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_any_extra_public_asset_fails(self):
        for extra in (
            "app-play-release.aab",
            "app-qa-profile.apk",
            "mapping.txt",
            "release.keystore",
            "test-fixture.json",
            "build.log",
            "screenshot.png",
            "credentials.json",
            "internal-debug.json",
        ):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory(prefix="s09-public-bad-") as temporary:
                public = self.fixture(Path(temporary))
                (public / extra).write_bytes(b"private\n")
                result = self.run_validator(public)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class Slice2TrustedToolchainTest(unittest.TestCase):
    def write_toolchain(self, root: Path, label: str):
        sdk = root / label
        build = sdk / "build-tools/36.0.0"
        command = sdk / "cmdline-tools/19.0"
        jdk = root / f"{label}-jdk"
        build.mkdir(parents=True)
        (command / "bin").mkdir(parents=True)
        (build / "lib").mkdir()
        (command / "lib").mkdir()
        (jdk / "bin").mkdir(parents=True)
        (jdk / "lib").mkdir()
        (build / "source.properties").write_text("Pkg.Revision=36.0.0\n", encoding="ascii")
        (command / "source.properties").write_text("Pkg.Revision=19.0\n", encoding="ascii")
        (build / "lib/apksigner.jar").write_bytes(f"{label}-apksigner-jar".encode())
        (command / "lib/apkanalyzer.jar").write_bytes(f"{label}-apkanalyzer-jar".encode())
        (jdk / "bin/java").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (jdk / "bin/java").chmod(0o700)
        (jdk / "lib/modules").write_bytes(f"{label}-java-modules".encode())
        paths = {
            "aapt": build / "aapt",
            "apksigner": build / "apksigner",
            "apkanalyzer": command / "bin/apkanalyzer",
        }
        for name, path in paths.items():
            path.write_text(f"#!/bin/sh\nprintf '%s\\n' '{label}-{name}'\n", encoding="utf-8")
            path.chmod(0o700)
        manifest = root / f"{label}-toolchain.json"
        manifest.write_bytes(
            canonical(
                {
                    "schema": 1,
                    "root": str(sdk.resolve()),
                    "javaRoot": str(jdk.resolve()),
                    "buildToolsRevision": "36.0.0",
                    "commandLineToolsRevision": "19.0",
                    "tools": {
                        name: {
                            "path": path.relative_to(sdk).as_posix(),
                            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        }
                        for name, path in sorted(paths.items())
                    },
                    "runtimeTrees": {
                        "androidBuildTools": {
                            "root": "android-sdk",
                            "path": "build-tools/36.0.0",
                            "sha256": public_provenance_validator.sha256_tree(build),
                        },
                        "androidCommandLineTools": {
                            "root": "android-sdk",
                            "path": "cmdline-tools/19.0",
                            "sha256": public_provenance_validator.sha256_tree(command),
                        },
                        "javaBinaries": {
                            "root": "jdk",
                            "path": "bin",
                            "sha256": public_provenance_validator.sha256_tree(jdk / "bin"),
                        },
                        "javaLibraries": {
                            "root": "jdk",
                            "path": "lib",
                            "sha256": public_provenance_validator.sha256_tree(jdk / "lib"),
                        },
                    },
                }
            )
        )
        manifest_value = json.loads(manifest.read_text(encoding="utf-8"))
        policy_value = json.loads(
            (ROOT / "tool/release/release_contract.json").read_text(encoding="utf-8")
        )
        policy_value["publicInspectionTools"] = {
            "platform": "linux-x86_64",
            **{
                key: value
                for key, value in manifest_value.items()
                if key not in {"schema", "root", "javaRoot"}
            },
        }
        (root / f"{label}-policy.json").write_bytes(canonical(policy_value))
        return sdk, manifest, paths

    def run_check(self, manifest: Path, asset_dir: Path, evil_sdk: Path):
        try:
            public_provenance_validator.resolve_toolchain(
                manifest,
                asset_dir,
                manifest.with_name(manifest.name.replace("-toolchain.json", "-policy.json")),
            )
        except public_provenance_validator.ProvenanceError as error:
            return subprocess.CompletedProcess([], 1, "", str(error))
        return subprocess.CompletedProcess([], 0, "", "")

    def test_ignores_attacker_android_roots_and_accepts_digest_pinned_trusted_tools(self):
        with tempfile.TemporaryDirectory(prefix="s09-tools-valid-") as temporary:
            root = Path(temporary)
            trusted, manifest, _ = self.write_toolchain(root, "trusted")
            evil, _, _ = self.write_toolchain(root, "evil")
            assets = root / "assets"
            assets.mkdir()
            result = self.run_check(manifest, assets, evil)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(str(evil), result.stdout)
        self.assertNotEqual(trusted, evil)

    def test_rejects_changed_tool_digest_or_unpinned_revision(self):
        with tempfile.TemporaryDirectory(prefix="s09-tools-bad-") as temporary:
            root = Path(temporary)
            _trusted, manifest, paths = self.write_toolchain(root, "trusted")
            evil, _, _ = self.write_toolchain(root, "evil")
            assets = root / "assets"
            assets.mkdir()
            paths["aapt"].write_text("#!/bin/sh\necho forged\n", encoding="utf-8")
            paths["aapt"].chmod(0o700)
            changed = self.run_check(manifest, assets, evil)
            _, revision_manifest, _ = self.write_toolchain(root, "other")
            value = json.loads(revision_manifest.read_text(encoding="utf-8"))
            value["buildToolsRevision"] = "35.0.0"
            revision_manifest.write_bytes(canonical(value))
            revision = self.run_check(revision_manifest, assets, evil)
        self.assertNotEqual(changed.returncode, 0, changed.stdout + changed.stderr)
        self.assertNotEqual(revision.returncode, 0, revision.stdout + revision.stderr)

    def test_rejects_changed_executable_companion_or_java_runtime(self):
        mutations = (
            ("sdk", "build-tools/36.0.0/lib/apksigner.jar"),
            ("sdk", "cmdline-tools/19.0/lib/apkanalyzer.jar"),
            ("jdk", "bin/java"),
            ("jdk", "lib/modules"),
        )
        for root_name, relative in mutations:
            with self.subTest(root=root_name, relative=relative):
                with tempfile.TemporaryDirectory(prefix="s09-tools-companion-") as temporary:
                    root = Path(temporary)
                    trusted, manifest, _ = self.write_toolchain(root, "trusted")
                    assets = root / "assets"
                    assets.mkdir()
                    selected_root = trusted if root_name == "sdk" else root / "trusted-jdk"
                    (selected_root / relative).write_bytes(b"forged runtime")
                    changed = self.run_check(manifest, assets, trusted)
                self.assertNotEqual(changed.returncode, 0, changed.stdout + changed.stderr)


class Slice3BuildBindingTest(unittest.TestCase):
    def git(self, root: Path, *args: str):
        return subprocess.run(
            [
                "git",
                "-c",
                "protocol.file.allow=always",
                "-c",
                "commit.gpgsign=false",
                *args,
            ],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
            env={key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
        )

    def fixture(self, temporary: Path):
        sub = temporary / "dependency"
        sub.mkdir()
        self.git(sub, "init")
        self.git(sub, "config", "user.email", "fixture@example.invalid")
        self.git(sub, "config", "user.name", "Fixture")
        (sub / "dependency.txt").write_text("dependency\n", encoding="utf-8")
        self.git(sub, "add", "dependency.txt")
        self.git(sub, "commit", "-m", "dependency")

        root = temporary / "source"
        root.mkdir()
        self.git(root, "init")
        self.git(root, "config", "user.email", "fixture@example.invalid")
        self.git(root, "config", "user.name", "Fixture")
        files = {
            ".gitignore": "build/\n",
            "pubspec.yaml": "name: fixture\nversion: 9.8.7+42\n",
            "pubspec.lock": "packages: {}\n",
            "android/app/build.gradle.kts": "// fixture\n",
            "android/gradle.properties": "fixture=true\n",
            "lib/main.dart": "void main() {}\n",
        }
        for relative, content in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        self.git(root, "add", ".")
        self.git(root, "commit", "-m", "source")
        self.git(root, "submodule", "add", str(sub), "vendor/dependency")
        self.git(root, "commit", "-am", "add submodule")
        artifact = root / "build/app/outputs/bundle/playRelease/app-play-release.aab"
        artifact.parent.mkdir(parents=True)
        with zipfile.ZipFile(artifact, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("base/manifest/AndroidManifest.xml", b"binary manifest")
            archive.writestr("BundleConfig.pb", b"bundle config")
            archive.writestr("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\n")
            archive.writestr("META-INF/CERT.SF", b"signature metadata")
            archive.writestr("META-INF/CERT.RSA", b"signature block")
        binding = artifact.parent / "build-binding.json"
        output, manifest = self.double_output(root, [artifact], "play-private")
        return root, output / "replica-a" / artifact.name, binding, manifest

    def double_output(
        self, root: Path, artifacts: list[Path], channel: str
    ) -> tuple[Path, Path]:
        output = root.parent / f"{channel}-double-output"
        first = output / "replica-a"
        second = output / "replica-b"
        first.mkdir(parents=True)
        second.mkdir(parents=True)
        for artifact in artifacts:
            shutil.copy2(artifact, first / artifact.name)
            shutil.copy2(artifact, second / artifact.name)
        comparison = output / "rebuild-comparison.json"
        compare = [
            PYTHON,
            str(ROOT / "tool/release/compare_rebuilds.py"),
            "--channel", channel,
            "--first", str(first if channel == "direct-public" else first / "app-play-release.aab"),
            "--second", str(second if channel == "direct-public" else second / "app-play-release.aab"),
            "--output", str(comparison),
        ]
        compared = subprocess.run(compare, check=False, capture_output=True, text=True)
        self.assertEqual(compared.returncode, 0, compared.stderr)
        manifest = output / "double-build-manifest.json"
        command = [
            PYTHON,
            str(ROOT / "tool/release/double_build_manifest.py"),
            "write",
            "--root", str(root),
            "--channel", channel,
            "--first", str(first),
            "--second", str(second),
            "--comparison", str(comparison),
            "--expected-signer-sha256", "ab" * 32,
            "--android-home", "/fixture/android-home",
            "--android-sdk-root", "/fixture/android-sdk-root",
            "--java-home", "/fixture/java-home",
            "--output", str(manifest),
        ]
        tool_digest = hashlib.sha256(Path(PYTHON).resolve().read_bytes()).hexdigest()
        for name in ("flutter", "git", "python3", "java", "sha256sum", "install", "mktemp", "mv"):
            command.extend(("--tool", f"{name}={PYTHON}"))
            command.extend(("--expected-tool-sha", f"{name}={tool_digest}"))
        emitted = subprocess.run(command, check=False, capture_output=True, text=True)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        return output, manifest

    def run_binding(
        self,
        action: str,
        root: Path,
        artifact: Path,
        binding: Path,
        manifest: Path,
        environment: dict[str, str] | None = None,
    ):
        return subprocess.run(
            [
                PYTHON,
                str(ROOT / "tool/release/play_build_binding.py"),
                action,
                "--root",
                str(root),
                "--artifact",
                str(artifact),
                "--double-build-manifest",
                str(manifest),
                "--binding",
                str(binding),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_clean_full_source_submodule_inputs_and_artifact_are_bound(self):
        with tempfile.TemporaryDirectory(prefix="s09-binding-valid-") as temporary:
            root, artifact, binding, manifest = self.fixture(Path(temporary))
            written = self.run_binding("write", root, artifact, binding, manifest)
            verified = self.run_binding("validate", root, artifact, binding, manifest)
            document = json.loads(binding.read_text(encoding="utf-8")) if binding.exists() else {}
        self.assertEqual(written.returncode, 0, written.stderr)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(
            set(document.get("source", {})),
            {"commit", "treeObject", "archiveSha256", "submoduleStateSha256"},
        )
        self.assertEqual(
            set(document.get("inputs", {})),
            {"pubspecLockSha256", "buildInputsSha256", "buildFiles"},
        )

    def test_inherited_git_index_cannot_redirect_source_binding(self):
        with tempfile.TemporaryDirectory(prefix="s09-binding-git-env-") as temporary:
            root, artifact, binding, manifest = self.fixture(Path(temporary))
            poisoned_index = root.parent / "foreign-index"
            poisoned_index.write_bytes(b"not a git index")
            result = self.run_binding(
                "write",
                root,
                artifact,
                binding,
                manifest,
                {**os.environ, "GIT_INDEX_FILE": str(poisoned_index)},
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_artifact_dirty_source_untracked_source_and_submodule_fail(self):
        with tempfile.TemporaryDirectory(prefix="s09-binding-bad-") as temporary:
            root, artifact, binding, manifest = self.fixture(Path(temporary))
            self.assertEqual(
                self.run_binding("write", root, artifact, binding, manifest).returncode,
                0,
            )
            original_artifact = artifact.read_bytes()
            artifact.write_bytes(b"substituted")
            changed_artifact = self.run_binding(
                "validate", root, artifact, binding, manifest
            )
            artifact.write_bytes(original_artifact)
            (root / "lib/main.dart").write_text("void main() { print('dirty'); }\n", encoding="utf-8")
            dirty = self.run_binding("validate", root, artifact, binding, manifest)
            self.git(root, "checkout", "--", "lib/main.dart")
            untracked_path = root / "unexpected.txt"
            untracked_path.write_text("untracked\n", encoding="utf-8")
            untracked = self.run_binding("validate", root, artifact, binding, manifest)
            untracked_path.unlink()
            (root / "vendor/dependency/dependency.txt").write_text("dirty submodule\n", encoding="utf-8")
            dirty_submodule = self.run_binding(
                "validate", root, artifact, binding, manifest
            )
        for result in (changed_artifact, dirty, untracked, dirty_submodule):
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tampered_archive_or_input_binding_fails(self):
        with tempfile.TemporaryDirectory(prefix="s09-binding-tamper-") as temporary:
            root, artifact, binding, manifest = self.fixture(Path(temporary))
            self.assertEqual(
                self.run_binding("write", root, artifact, binding, manifest).returncode,
                0,
            )
            for section, key in (("source", "archiveSha256"), ("inputs", "buildInputsSha256")):
                document = json.loads(binding.read_text(encoding="utf-8"))
                document[section][key] = "f" * 64
                binding.write_bytes(canonical(document))
                result = self.run_binding(
                    "validate", root, artifact, binding, manifest
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    self.run_binding(
                        "write", root, artifact, binding, manifest
                    ).returncode,
                    1,
                )
                binding.unlink()
                self.assertEqual(
                    self.run_binding(
                        "write", root, artifact, binding, manifest
                    ).returncode,
                    0,
                )

    def test_public_binding_binds_all_three_apks_to_the_clean_source(self):
        with tempfile.TemporaryDirectory(prefix="s09-public-binding-") as temporary:
            root, _, _, _ = self.fixture(Path(temporary))
            public = root / "build/public"
            public.mkdir(parents=True)
            artifacts = []
            for name in APKS:
                path = public / name
                path.write_bytes((name + " bytes").encode())
                artifacts.append(path)
            binding = public / "source-binding.json"
            _, manifest = self.double_output(root, artifacts, "direct-public")
            command = [
                PYTHON,
                str(ROOT / "tool/release/public_build_binding.py"),
                "write",
                "--root",
                str(root),
                "--binding",
                str(binding),
                "--double-build-manifest",
                str(manifest),
            ]
            for artifact in artifacts:
                command.extend(("--artifact", str(artifact)))
            written = subprocess.run(command, check=False, capture_output=True, text=True)
            command[2] = "validate"
            verified = subprocess.run(command, check=False, capture_output=True, text=True)
            artifacts[1].write_bytes(b"substituted public APK")
            changed = subprocess.run(command, check=False, capture_output=True, text=True)
            artifacts[1].write_bytes((artifacts[1].name + " bytes").encode())
            (root / "unexpected-source.txt").write_text("dirty\n", encoding="utf-8")
            dirty = subprocess.run(command, check=False, capture_output=True, text=True)
        self.assertEqual(written.returncode, 0, written.stderr)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertNotEqual(changed.returncode, 0, changed.stdout + changed.stderr)
        self.assertNotEqual(dirty.returncode, 0, dirty.stdout + dirty.stderr)

    def test_symlinked_play_or_public_artifacts_fail(self):
        with tempfile.TemporaryDirectory(prefix="s09-binding-links-") as temporary:
            root, artifact, _, manifest = self.fixture(Path(temporary))
            external = root.parent / "external"
            external.mkdir()
            target = external / artifact.name
            artifact.replace(target)
            artifact.symlink_to(target)
            self.assertNotEqual(
                self.run_binding(
                    "write",
                    root,
                    artifact,
                    root / "play-binding.json",
                    manifest,
                ).returncode,
                0,
            )

            command = [
                PYTHON,
                str(ROOT / "tool/release/public_build_binding.py"),
                "write",
                "--root",
                str(root),
                "--binding",
                str(root / "public-binding.json"),
                "--double-build-manifest",
                str(manifest),
            ]
            for name in APKS:
                link = root / name
                destination_dir = external / name.removesuffix(".apk")
                destination_dir.mkdir()
                destination = destination_dir / name
                destination.write_bytes(b"apk")
                link.symlink_to(destination)
                command.extend(("--artifact", str(link)))
            result = subprocess.run(command, check=False, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class Slice4ArtifactReinspectionTest(unittest.TestCase):
    signer = "a" * 64

    def write_apk(self, path: Path, marker: str = "fixture"):
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr("AndroidManifest.xml", b"binary manifest")
            output.writestr("resources.arsc", b"resources")
            output.writestr("classes.dex", marker.encode())

    def write_inspection_toolchain(self, root: Path):
        _, manifest, paths = Slice2TrustedToolchainTest().write_toolchain(root, "trusted")
        xml = '''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.example.console" android:versionName="9.8.7" android:versionCode="42"><uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36"/><uses-permission android:name="android.permission.INTERNET"/><application android:label="Example Console"><service android:name=".SyncService" android:foregroundServiceType="dataSync"/></application><queries><package android:name="com.termux"/></queries></manifest>'''
        paths["aapt"].write_text(
            "#!/usr/bin/env python3\n"
            "import os,sys\n"
            f"abis={dict(APKS)!r}\n"
            "name=os.path.basename(sys.argv[-1])\n"
            "log=os.environ.get('INSPECTION_LOG')\n"
            "open(log,'a').write(name+'\\n') if log else None\n"
            "print(\"package: name='dev.example.console' versionCode='42' versionName='9.8.7'\")\n"
            "print(\"sdkVersion:'24'\")\n"
            "print(\"targetSdkVersion:'36'\")\n"
            "print(\"uses-permission: name='android.permission.INTERNET'\")\n"
            "print(\"native-code: '%s'\" % abis[name])\n",
            encoding="utf-8",
        )
        paths["apkanalyzer"].write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            f"xml={xml!r}\n"
            "values={'application-id':'dev.example.console','version-name':'9.8.7','version-code':'42','min-sdk':'24','target-sdk':'36','permissions':'android.permission.INTERNET','print':xml}\n"
            "print(values[sys.argv[2]])\n",
            encoding="utf-8",
        )
        paths["apksigner"].write_text(
            "#!/usr/bin/env python3\n"
            "print('Verifies')\n"
            f"print('Signer #1 certificate SHA-256 digest: {self.signer}')\n",
            encoding="utf-8",
        )
        for path in paths.values():
            path.chmod(0o700)
        document = json.loads(manifest.read_text(encoding="utf-8"))
        for name, path in paths.items():
            document["tools"][name]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        roots = {
            "android-sdk": Path(document["root"]),
            "jdk": Path(document["javaRoot"]),
        }
        for record in document["runtimeTrees"].values():
            record["sha256"] = public_provenance_validator.sha256_tree(
                roots[record["root"]] / record["path"]
            )
        manifest.write_bytes(canonical(document))
        return manifest, paths

    def expected(self, path: Path):
        value = {
            "schema": 1,
            "flavor": "full",
            "package": "dev.example.console",
            "versionName": "9.8.7",
            "versionCode": 42,
            "abiVersionCodes": {abi: 42 for abi in APKS.values()},
            "minSdk": 24,
            "targetSdk": 36,
            "label": "Example Console",
            "permissions": ["android.permission.INTERNET"],
            "forbiddenPermissions": ["android.permission.READ_PHONE_STATE"],
            "foregroundServices": [{"name": ".SyncService", "types": ["dataSync"]}],
            "requiredPackageQueries": ["com.termux"],
        }
        path.write_bytes(canonical(value))
        return path

    def refresh_archive(self, evidence: Path, public: Path):
        checksums = []
        for path in sorted(p for p in evidence.rglob("*") if p.is_file() and p.name != "SHA256SUMS"):
            relative = path.relative_to(evidence).as_posix()
            checksums.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}\n")
        (evidence / "SHA256SUMS").write_text("".join(checksums), encoding="ascii")
        archive = public / "hermes-console-release-evidence.tar.gz"
        if archive.exists():
            archive.unlink()
        with tarfile.open(archive, "w:gz") as output:
            output.add(evidence, arcname="release-evidence")
        return archive

    def fixture(self, temporary: Path):
        source, _, _, _ = Slice3BuildBindingTest().fixture(temporary)
        public = source / "build/release-public"
        public.mkdir(parents=True)
        artifacts = []
        for name in APKS:
            artifact = public / name
            self.write_apk(artifact)
            artifacts.append(artifact)
        binding = source / "build/source-binding.json"
        double_output, manifest = Slice3BuildBindingTest().double_output(
            source, artifacts, "direct-public"
        )
        command = [PYTHON, str(ROOT / "tool/release/public_build_binding.py"), "write", "--root", str(source), "--binding", str(binding), "--double-build-manifest", str(manifest)]
        for artifact in artifacts:
            command.extend(("--artifact", str(artifact)))
        written = subprocess.run(command, check=False, capture_output=True, text=True)
        self.assertEqual(written.returncode, 0, written.stderr)

        expected = self.expected(temporary / "expected.json")
        policy = temporary / "release-contract.json"
        policy_value = json.loads(
            (ROOT / "tool/release/release_contract.json").read_text(encoding="utf-8")
        )
        policy_value["signerContinuity"]["direct-public"]["certificateSha256"] = self.signer
        toolchain, tools = self.write_inspection_toolchain(temporary)
        toolchain_value = json.loads(toolchain.read_text(encoding="utf-8"))
        policy_value["publicInspectionTools"] = {
            "platform": "linux-x86_64",
            **{
                key: value
                for key, value in toolchain_value.items()
                if key not in {"schema", "root", "javaRoot"}
            },
        }
        policy.write_bytes(canonical(policy_value))
        evidence = source / "build/release-evidence"
        evidence.mkdir()
        shutil.copy2(
            double_output / "rebuild-comparison.json",
            evidence / "rebuild-comparison.json",
        )
        source_binding_document = json.loads(binding.read_text(encoding="utf-8"))
        input_fingerprint = source_binding_document["inputs"]["buildInputsSha256"]
        source_commit = source_binding_document["source"]["commit"]
        for name, abi in APKS.items():
            directory = evidence / f"artifacts/full/{Path(name).stem}"
            directory.mkdir(parents=True)
            facts = directory / "public-apk-facts.json"
            inspected = subprocess.run(
                [
                    PYTHON,
                    str(ROOT / "tool/release/inspect_public_apk.py"),
                    "--artifact", str(public / name),
                    "--expected", str(expected),
                    "--expected-artifact-name", name,
                    "--expected-abi", abi,
                    "--expected-signer-sha256", self.signer,
                    "--policy", str(policy),
                    "--aapt", str(tools["aapt"]),
                    "--apkanalyzer", str(tools["apkanalyzer"]),
                    "--apksigner", str(tools["apksigner"]),
                    "--output", str(facts),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(inspected.returncode, 0, inspected.stderr)
            artifact_digest = hashlib.sha256((public / name).read_bytes()).hexdigest()
            documents = {
                "fullRelease.cdx.json": {
                    "schema": 1,
                    "metadata": {"inputFingerprint": input_fingerprint, "sourceCommit": source_commit},
                    "components": [{"id": "pkg:fixture", "license": "MIT", "evidence": "LICENSE"}],
                },
                "fullRelease.artifact.json": {
                    "schema": 1,
                    "inputFingerprint": input_fingerprint,
                    "sourceCommit": source_commit,
                    "artifact": {"name": name, "sha256": artifact_digest},
                    "packagedEntries": [{"path": "lib/fixture.so", "license": "MIT", "evidence": "LICENSE"}],
                },
                "source-assets.json": {
                    "schema": 1,
                    "inputFingerprint": input_fingerprint,
                    "sourceCommit": source_commit,
                    "assets": [{"path": "assets/fixture", "license": "MIT", "evidence": "LICENSE"}],
                },
                "fullRelease.license-review.json": {
                    "schema": 1,
                    "status": "COMPLETE",
                    "inputFingerprint": input_fingerprint,
                    "sourceCommit": source_commit,
                    "dependencyComponents": [{"id": "pkg:fixture", "license": "MIT", "evidence": "LICENSE"}],
                    "sourceAssets": [{"path": "assets/fixture", "license": "MIT", "evidence": "LICENSE"}],
                    "packagedEntries": [{"path": "lib/fixture.so", "license": "MIT", "evidence": "LICENSE"}],
                    "unresolved": [],
                },
            }
            for leaf, document in documents.items():
                (directory / leaf).write_bytes(canonical(document))
        archive = self.refresh_archive(evidence, public)
        return source, public, evidence, archive, expected, toolchain

    def run_validator(self, source: Path, public: Path, archive: Path, expected: Path, toolchain: Path, log: Path):
        return subprocess.run(
            [
                PYTHON,
                str(ROOT / "test/support_validate_public_fixture.py"),
                "--archive",
                str(archive),
                "--asset-directory",
                str(public),
                "--expected",
                str(expected),
                "--signer",
                self.signer,
                "--trusted-toolchain",
                str(toolchain),
                "--source-root",
                str(source),
                "--tool-policy",
                str(expected.with_name("release-contract.json")),
                "--inspection-log",
                str(log),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
        )

    def test_valid_fixture_is_reinspected_for_every_abi(self):
        with tempfile.TemporaryDirectory(prefix="s09-reinspect-valid-") as temporary:
            root = Path(temporary)
            source, public, _, archive, expected, toolchain = self.fixture(root)
            log = root / "inspection.log"
            result = self.run_validator(source, public, archive, expected, toolchain, log)
            inspected = set(log.read_text(encoding="utf-8").splitlines()) if log.exists() else set()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(inspected, set(APKS))

    def test_public_validator_rejects_replaced_policy_signer_and_toolchain(self):
        with tempfile.TemporaryDirectory(prefix="s09-replaced-public-trust-") as temporary:
            root = Path(temporary)
            source, public, _, archive, expected, toolchain = self.fixture(root)
            result = subprocess.run(
                [
                    PYTHON,
                    str(ROOT / "tool/release/validate_public_apk_provenance.py"),
                    "--archive",
                    str(archive),
                    "--asset-directory",
                    str(public),
                    "--trusted-toolchain",
                    str(toolchain),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_caller_cannot_replace_reviewed_prior_signer(self):
        with tempfile.TemporaryDirectory(prefix="s09-signer-drift-") as temporary:
            root = Path(temporary)
            _, public, _, _, expected, toolchain = self.fixture(root)
            manifest = json.loads(toolchain.read_text(encoding="utf-8"))
            tool_root = Path(manifest["root"])
            tools = {
                name: tool_root / record["path"]
                for name, record in manifest["tools"].items()
            }
            drifted = "cd" * 32
            tools["apksigner"].write_text(
                "#!/usr/bin/env python3\n"
                "print('Verifies')\n"
                f"print('Signer #1 certificate SHA-256 digest: {drifted}')\n",
                encoding="utf-8",
            )
            tools["apksigner"].chmod(0o700)
            result = subprocess.run(
                [
                    PYTHON,
                    str(ROOT / "tool/release/inspect_public_apk.py"),
                    "--artifact", str(public / "app-arm64-v8a-full-release.apk"),
                    "--expected", str(expected),
                    "--expected-artifact-name", "app-arm64-v8a-full-release.apk",
                    "--expected-abi", "arm64-v8a",
                    "--expected-signer-sha256", drifted,
                    "--policy", str(expected.with_name("release-contract.json")),
                    "--aapt", str(tools["aapt"]),
                    "--apkanalyzer", str(tools["apkanalyzer"]),
                    "--apksigner", str(tools["apksigner"]),
                    "--output", str(root / "drifted-facts.json"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rebuild_report_digest_must_bind_the_selected_public_apk(self):
        with tempfile.TemporaryDirectory(prefix="s09-rebuild-binding-bad-") as temporary:
            root = Path(temporary)
            source, public, evidence, _, expected, toolchain = self.fixture(root)
            report_path = evidence / "rebuild-comparison.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report["artifacts"][0]["firstSha256"] = "f" * 64
            report["artifacts"][0]["secondSha256"] = "f" * 64
            report_path.write_bytes(canonical(report))
            archive = self.refresh_archive(evidence, public)
            result = self.run_validator(
                source, public, archive, expected, toolchain, root / "digest.log"
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_stale_sidecar_or_substituted_apk_fails_even_with_refreshed_checksums(self):
        with tempfile.TemporaryDirectory(prefix="s09-reinspect-bad-") as temporary:
            root = Path(temporary)
            source, public, evidence, _, expected, toolchain = self.fixture(root)
            facts_path = evidence / "artifacts/full/app-arm64-v8a-full-release/public-apk-facts.json"
            facts = json.loads(facts_path.read_text(encoding="utf-8"))
            facts["package"] = "forged.example"
            facts_path.write_bytes(canonical(facts))
            archive = self.refresh_archive(evidence, public)
            stale = self.run_validator(source, public, archive, expected, toolchain, root / "stale.log")
            facts["package"] = "dev.example.console"
            facts_path.write_bytes(canonical(facts))
            self.write_apk(public / "app-x86_64-full-release.apk", marker="substituted")
            archive = self.refresh_archive(evidence, public)
            substituted = self.run_validator(source, public, archive, expected, toolchain, root / "substituted.log")
        self.assertNotEqual(stale.returncode, 0, stale.stdout + stale.stderr)
        self.assertNotEqual(substituted.returncode, 0, substituted.stdout + substituted.stderr)


class Slice5LicenseGateTest(unittest.TestCase):
    def test_incomplete_empty_or_unresolved_license_ledgers_fail(self):
        helper = Slice4ArtifactReinspectionTest()
        with tempfile.TemporaryDirectory(prefix="s09-license-bad-") as temporary:
            root = Path(temporary)
            source, public, evidence, _, expected, toolchain = helper.fixture(root)
            review_path = evidence / "artifacts/full/app-arm64-v8a-full-release/fullRelease.license-review.json"
            sbom_path = evidence / "artifacts/full/app-arm64-v8a-full-release/fullRelease.cdx.json"
            original_review = review_path.read_bytes()
            original_sbom = sbom_path.read_bytes()
            results = []
            mutations = (
                lambda review, sbom: review.update(status="PENDING"),
                lambda review, sbom: review.update(dependencyComponents=[]),
                lambda review, sbom: review.update(unresolved=["pkg:unresolved"]),
                lambda review, sbom: sbom["components"][0].update(license="NOASSERTION"),
                lambda review, sbom: review["packagedEntries"][0].update(evidence="none"),
            )
            for index, mutation in enumerate(mutations):
                review = json.loads(original_review)
                sbom = json.loads(original_sbom)
                mutation(review, sbom)
                review_path.write_bytes(canonical(review))
                sbom_path.write_bytes(canonical(sbom))
                archive = helper.refresh_archive(evidence, public)
                results.append(helper.run_validator(source, public, archive, expected, toolchain, root / f"license-{index}.log"))
            review_path.write_bytes(original_review)
            sbom_path.write_bytes(original_sbom)
            archive = helper.refresh_archive(evidence, public)
            valid = helper.run_validator(source, public, archive, expected, toolchain, root / "license-valid.log")
        for result in results:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(valid.returncode, 0, valid.stderr)


class Slice6ReleaseIdentityTest(unittest.TestCase):
    def run_identity(self, root: Path, **overrides):
        commit = "a" * 40
        values = {
            "tag": "v9.8.7",
            "build": "42",
            "expected": commit,
            "checkout": commit,
            "tag_commit": commit,
            "verified": True,
            "reason": "valid",
            "author_login": "trusted-release-owner",
            "committer_login": "trusted-release-owner",
        }
        values.update(overrides)
        pubspec = root / "pubspec.yaml"
        pubspec.write_text("name: fixture\nversion: 9.8.7+42\n", encoding="utf-8")
        policy = root / "policy.json"
        policy.write_bytes(
            canonical(
                {
                    "schema": 1,
                    "sourceAuthorization": {
                        "forge": "github.com",
                        "authorizedActors": ["trusted-release-owner"],
                        "requireAuthorAndCommitter": True,
                    },
                }
            )
        )
        verification = root / "verification.json"
        verification.write_bytes(
            canonical(
                {
                    "authorLogin": values["author_login"],
                    "committerLogin": values["committer_login"],
                    "verification": {
                        "verified": values["verified"],
                        "reason": values["reason"],
                        "signature": "signed fixture",
                        "payload": "commit payload",
                        "verified_at": "2026-09-04T00:00:00Z",
                    },
                }
            )
        )
        return subprocess.run(
            [
                PYTHON,
                str(ROOT / "tool/release/verify_release_identity.py"),
                "--tag", values["tag"],
                "--pubspec", str(pubspec),
                "--build-number", values["build"],
                "--expected-commit", values["expected"],
                "--checkout-commit", values["checkout"],
                "--tag-commit", values["tag_commit"],
                "--verification-json", str(verification),
                "--policy", str(policy),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_exact_tag_pubspec_build_and_verified_commit_pass(self):
        with tempfile.TemporaryDirectory(prefix="s09-identity-valid-") as temporary:
            result = self.run_identity(Path(temporary))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tag_build_unsigned_and_wrong_commit_fixtures_fail(self):
        malicious = (
            {"tag": "v9.8.8"},
            {"tag": "v9.8.7+42"},
            {"build": "43"},
            {"checkout": "b" * 40},
            {"tag_commit": "b" * 40},
            {"verified": False, "reason": "unsigned"},
            {"verified": True, "reason": "unknown_key"},
            {"author_login": "attacker"},
            {"committer_login": "attacker"},
        )
        for overrides in malicious:
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory(prefix="s09-identity-bad-") as temporary:
                result = self.run_identity(Path(temporary), **overrides)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class PrivatePlayLaneTest(unittest.TestCase):
    signer = "ab" * 32

    def fixture(self, root: Path):
        source, _, _, _ = Slice3BuildBindingTest().fixture(root)
        tools = root / "tools"
        tools.mkdir()
        apkanalyzer = tools / "apkanalyzer"
        apkanalyzer.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "values={'application-id':'dev.xpetalab.hermesconsole',"
            "'version-name':'9.8.7','version-code':'42'}\n"
            "print(values[sys.argv[2]])\n",
            encoding="utf-8",
        )
        jarsigner = tools / "jarsigner"
        jarsigner.write_text("#!/bin/sh\nprintf 'jar verified.\\n'\n", encoding="utf-8")
        keytool = tools / "keytool"
        fingerprint = ":".join(
            self.signer[index : index + 2]
            for index in range(0, len(self.signer), 2)
        )
        keytool.write_text(
            f"#!/bin/sh\nprintf 'SHA256: {fingerprint}\\n'\n", encoding="utf-8"
        )
        for tool in (apkanalyzer, jarsigner, keytool):
            tool.chmod(0o700)
        policy = source / "tool/release/release_contract.json"
        policy.parent.mkdir(parents=True)
        policy_value = json.loads(
            (ROOT / "tool/release/release_contract.json").read_text(encoding="utf-8")
        )
        policy_value["signerContinuity"]["play-private"]["certificateSha256"] = self.signer
        policy_value["playInspectionTools"] = {
            "platform": "linux-x86_64",
            "tools": {
                "apkanalyzer": {
                    "root": "android-sdk",
                    "path": "apkanalyzer",
                    "sha256": hashlib.sha256(apkanalyzer.read_bytes()).hexdigest(),
                },
                "jarsigner": {
                    "root": "jdk",
                    "path": "jarsigner",
                    "sha256": hashlib.sha256(jarsigner.read_bytes()).hexdigest(),
                },
                "keytool": {
                    "root": "jdk",
                    "path": "keytool",
                    "sha256": hashlib.sha256(keytool.read_bytes()).hexdigest(),
                },
            },
        }
        policy.write_bytes(canonical(policy_value))
        shutil.copy2(ROOT / "pubspec.lock", source / "pubspec.lock")
        Slice3BuildBindingTest().git(source, "add", "tool/release/release_contract.json")
        Slice3BuildBindingTest().git(source, "add", "pubspec.lock")
        Slice3BuildBindingTest().git(source, "commit", "-m", "review tool policy")
        environment = {
            **os.environ,
            "ANDROID_SDK_ROOT": str(tools),
            "JAVA_HOME": str(tools),
            "GIT_ALLOW_PROTOCOL": "file",
        }
        flutter = tools / "flutter"
        flutter.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib,sys,zipfile\n"
            "if sys.argv[1:2] == ['pub']: raise SystemExit(0)\n"
            "if sys.argv[1:3] != ['build','appbundle']: raise SystemExit(2)\n"
            "path=pathlib.Path('build/app/outputs/bundle/playRelease/app-play-release.aab')\n"
            "path.parent.mkdir(parents=True,exist_ok=True)\n"
            "with zipfile.ZipFile(path,'w') as archive:\n"
            " archive.writestr('base/manifest/AndroidManifest.xml',b'manifest')\n"
            " archive.writestr('BundleConfig.pb',b'config')\n"
            " archive.writestr('base/dex/classes.dex',b'program')\n"
            " archive.writestr('META-INF/MANIFEST.MF',b'manifest index')\n"
            " archive.writestr('META-INF/RELEASE.SF',b'signature index')\n"
            " archive.writestr('META-INF/RELEASE.RSA',b'signature')\n",
            encoding="utf-8",
        )
        flutter.chmod(0o700)
        key_properties = root / "key.properties"
        key_properties.write_text("storeFile=/nonexistent-fixture\n", encoding="utf-8")
        commit = Slice3BuildBindingTest().git(source, "rev-parse", "HEAD").stdout.strip()
        double_output = root / "play-double-private"
        built = subprocess.run(
            [
                "bash", str(ROOT / "tool/release/double_build.sh"),
                "play-private", str(source), commit, str(key_properties),
                str(double_output), self.signer,
            ],
            check=False,
            capture_output=True,
            text=True,
            env={**environment, "PATH": f"{tools}:{os.environ['PATH']}"},
        )
        self.assertEqual(built.returncode, 0, built.stderr)
        return source, double_output, environment

    def run_stage(
        self,
        source: Path,
        double_output: Path,
        destination: Path,
        environment: dict[str, str],
        signer: str | None = None,
    ):
        return subprocess.run(
            [
                "bash",
                str(ROOT / "tool/release/stage_play_private.sh"),
                str(source),
                str(double_output),
                signer or self.signer,
                str(destination),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_two_inspected_aabs_stage_only_to_private_directory(self):
        with tempfile.TemporaryDirectory(prefix="s09-play-private-") as temporary:
            root = Path(temporary)
            source, double_output, environment = self.fixture(root)
            destination = root / "owner-private"
            staged = self.run_stage(
                source, double_output, destination, environment
            )
            names = sorted(path.name for path in destination.iterdir()) if destination.exists() else []
            modes = {path.name: path.stat().st_mode & 0o777 for path in destination.iterdir()} if destination.exists() else {}
            facts = json.loads((destination / "play-aab-facts.json").read_text()) if destination.exists() and (destination / "play-aab-facts.json").exists() else {}
            comparison = json.loads((destination / "rebuild-comparison.json").read_text()) if destination.exists() and (destination / "rebuild-comparison.json").exists() else {}
            binding = json.loads((destination / "build-binding.json").read_text()) if destination.exists() and (destination / "build-binding.json").exists() else {}
            manifest_bytes = (destination / "double-build-manifest.json").read_bytes() if destination.exists() and (destination / "double-build-manifest.json").exists() else b""
            manifest = json.loads(manifest_bytes) if manifest_bytes else {}
        self.assertEqual(staged.returncode, 0, staged.stderr)
        self.assertEqual(
            names,
            [
                "SHA256SUMS",
                "app-play-release.aab",
                "build-binding.json",
                "double-build-manifest.json",
                "play-aab-facts.json",
                "rebuild-comparison.json",
            ],
        )
        self.assertEqual(set(modes.values()), {0o600})
        self.assertEqual(facts.get("package"), "dev.xpetalab.hermesconsole")
        self.assertEqual(facts.get("versionName"), "9.8.7")
        self.assertEqual(facts.get("versionCode"), 42)
        self.assertEqual(facts.get("signerCertificateSha256"), self.signer)
        self.assertTrue(comparison.get("functionalPayloadEquivalent"))
        self.assertEqual(binding.get("schema"), 2)
        self.assertEqual(binding.get("doubleBuild", {}).get("manifest"), manifest)
        self.assertEqual(
            binding.get("doubleBuild", {}).get("manifestSha256"),
            hashlib.sha256(manifest_bytes).hexdigest(),
        )
        self.assertEqual(binding.get("source"), manifest.get("source"))
        self.assertEqual(binding.get("inputs"), manifest.get("inputs"))
        self.assertEqual(
            binding.get("artifact", {}).get("sha256"),
            manifest.get("replicas", {})
            .get("a", {})
            .get("artifacts", [{}])[0]
            .get("sha256"),
        )
        self.assertNotIn("provenance", names)
        self.assertNotIn("upload", staged.stdout.casefold())

    def test_play_stage_rejects_caller_swapped_artifact_and_cleans_failure(self):
        with tempfile.TemporaryDirectory(prefix="s09-play-private-bad-") as temporary:
            root = Path(temporary)
            source, double_output, environment = self.fixture(root)
            first = double_output / "replica-a/app-play-release.aab"
            second = double_output / "replica-b/app-play-release.aab"
            rejected_public = self.run_stage(
                source, double_output, root / "release-public", environment
            )
            RebuildComparisonTest.write_aab(
                second,
                timestamp=(2020, 1, 1, 0, 0, 0),
                payload=b"changed program",
            )
            payload_destination = root / "payload-private"
            rejected_payload = self.run_stage(
                source, double_output, payload_destination, environment
            )
            shutil.copy2(first, second)
            signer_destination = root / "signer-private"
            rejected_signer = self.run_stage(
                source, double_output, signer_destination, environment, "cd" * 32
            )
            RebuildComparisonTest.write_aab(
                first,
                timestamp=(2020, 1, 1, 0, 0, 0),
                payload=b"caller-swapped unrelated program",
            )
            swapped_destination = root / "swapped-private"
            rejected_swapped = self.run_stage(
                source, double_output, swapped_destination, environment
            )
            residue = list(root.glob(".play-private.*"))
        for result in (
            rejected_public,
            rejected_payload,
            rejected_signer,
            rejected_swapped,
        ):
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        for destination in (
            payload_destination,
            signer_destination,
            swapped_destination,
        ):
            self.assertFalse(destination.exists())
        self.assertEqual(residue, [])

    def test_private_stage_rejects_fake_tool_after_policy_review(self):
        with tempfile.TemporaryDirectory(prefix="s09-play-private-fake-tool-") as temporary:
            root = Path(temporary)
            source, double_output, environment = self.fixture(root)
            (Path(environment["ANDROID_SDK_ROOT"]) / "apkanalyzer").write_text(
                "#!/bin/sh\nprintf 'forged metadata\\n'\n", encoding="utf-8"
            )
            result = self.run_stage(
                source, double_output, root / "fake-tool-private", environment
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_play_stage_rejects_caller_replaced_signer_even_when_artifact_and_tool_output_match(self):
        with tempfile.TemporaryDirectory(prefix="s09-play-replaced-signer-") as temporary:
            root = Path(temporary)
            source, double_output, environment = self.fixture(root)
            replaced = "cd" * 32
            keytool = Path(environment["JAVA_HOME"]) / "keytool"
            fingerprint = ":".join(
                replaced[index : index + 2] for index in range(0, len(replaced), 2)
            )
            keytool.write_text(
                f"#!/bin/sh\nprintf 'SHA256: {fingerprint}\\n'\n", encoding="utf-8"
            )
            keytool.chmod(0o700)
            policy_path = source / "tool/release/release_contract.json"
            policy = json.loads(policy_path.read_text(encoding="utf-8"))
            policy["playInspectionTools"]["tools"]["keytool"]["sha256"] = hashlib.sha256(
                keytool.read_bytes()
            ).hexdigest()
            policy_path.write_bytes(canonical(policy))
            Slice3BuildBindingTest().git(source, "add", "tool/release/release_contract.json")
            Slice3BuildBindingTest().git(source, "commit", "-m", "replace measured Play signer")
            result = self.run_stage(
                source,
                double_output,
                root / "replaced-signer-private",
                environment,
                replaced,
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class BoundedArtifactArchiveTest(unittest.TestCase):
    def load_sbom(self, name: str):
        import importlib.util

        specification = importlib.util.spec_from_file_location(
            name, ROOT / "tool/sbom/generate.py"
        )
        module = importlib.util.module_from_spec(specification)
        assert specification.loader is not None
        specification.loader.exec_module(module)
        return module

    def load_play_binding(self, name: str):
        import importlib.util

        specification = importlib.util.spec_from_file_location(
            name, ROOT / "tool/release/play_build_binding.py"
        )
        module = importlib.util.module_from_spec(specification)
        assert specification.loader is not None
        specification.loader.exec_module(module)
        return module

    def test_artifact_inventory_rejects_member_bomb(self):
        module = self.load_sbom("s09_sbom_member_bomb")
        with tempfile.TemporaryDirectory(prefix="s09-sbom-member-bomb-") as temporary:
            artifact = Path(temporary) / "member-bomb.apk"
            with zipfile.ZipFile(artifact, "w") as archive:
                for index in range(10_001):
                    archive.writestr(f"empty/{index}.txt", b"")
            with self.assertRaises(SystemExit):
                module.artifact_entries(artifact)

    def test_artifact_inventory_rejects_uncompressed_size_bomb(self):
        import types
        from unittest import mock

        module = self.load_sbom("s09_sbom_member_size_bomb")
        info = types.SimpleNamespace(
            filename="lib/arm64-v8a/libbomb.so",
            file_size=256 * 1024 * 1024 + 1,
        )

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return [info]

            def read(self, _info):
                return b"tiny"

        with tempfile.TemporaryDirectory(prefix="s09-sbom-size-bomb-") as temporary:
            artifact = Path(temporary) / "size-bomb.apk"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(SystemExit),
            ):
                module.artifact_entries(artifact)

    def test_artifact_inventory_rejects_total_uncompressed_size_bomb(self):
        import types
        from unittest import mock

        module = self.load_sbom("s09_sbom_total_size_bomb")
        infos = [
            types.SimpleNamespace(
                filename=f"ignored/{index}.txt",
                file_size=256 * 1024 * 1024,
            )
            for index in range(5)
        ]

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return infos

        with tempfile.TemporaryDirectory(prefix="s09-sbom-total-bomb-") as temporary:
            artifact = Path(temporary) / "total-bomb.aab"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(SystemExit),
            ):
                module.artifact_entries(artifact)

    def test_artifact_inventory_hashes_entries_while_streaming(self):
        import io
        import types
        from unittest import mock

        module = self.load_sbom("s09_sbom_streaming_hash")
        payload = b"a" * (2 * 1024 * 1024 + 17)
        info = types.SimpleNamespace(
            filename="lib/arm64-v8a/libfixture.so",
            file_size=len(payload),
        )

        class TrackingStream(io.BytesIO):
            def __init__(self, data):
                super().__init__(data)
                self.requests = []

            def read(self, size=-1):
                self.requests.append(size)
                return super().read(size)

        stream = TrackingStream(payload)

        class FakeArchive:
            read_calls = 0
            open_calls = 0

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return [info]

            def read(self, _info):
                self.read_calls += 1
                return payload

            def open(self, _info, mode="r"):
                self.open_calls += 1
                self.open_mode = mode
                return stream

        archive = FakeArchive()
        with tempfile.TemporaryDirectory(prefix="s09-sbom-stream-") as temporary:
            artifact = Path(temporary) / "streaming.apk"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with mock.patch.object(module.zipfile, "ZipFile", return_value=archive):
                entries = module.artifact_entries(artifact)

        self.assertEqual(archive.read_calls, 0)
        self.assertEqual(archive.open_calls, 1)
        self.assertEqual(archive.open_mode, "r")
        self.assertTrue(stream.requests)
        self.assertLessEqual(max(stream.requests), 1024 * 1024)
        self.assertEqual(entries[0]["size"], len(payload))
        self.assertEqual(entries[0]["sha256"], hashlib.sha256(payload).hexdigest())

    def test_artifact_inventory_rejects_streamed_size_mismatch(self):
        import io
        import types
        from unittest import mock

        module = self.load_sbom("s09_sbom_stream_size_mismatch")
        info = types.SimpleNamespace(
            filename="lib/arm64-v8a/libtruncated.so",
            file_size=5,
        )

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return [info]

            def open(self, _info, mode="r"):
                self.open_mode = mode
                return io.BytesIO(b"four")

        with tempfile.TemporaryDirectory(prefix="s09-sbom-size-mismatch-") as temporary:
            artifact = Path(temporary) / "truncated.apk"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(SystemExit),
            ):
                module.artifact_entries(artifact)

    def test_artifact_inventory_stops_at_streamed_size_overrun(self):
        import types
        from unittest import mock

        module = self.load_sbom("s09_sbom_stream_overrun")
        info = types.SimpleNamespace(
            filename="lib/arm64-v8a/liboverrun.so",
            file_size=4,
        )

        class OverrunStream:
            def __init__(self):
                self.requests = []

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, size=-1):
                self.requests.append(size)
                return b"x" * size if len(self.requests) < 3 else b""

        stream = OverrunStream()

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return [info]

            def open(self, _info, mode="r"):
                return stream

        with tempfile.TemporaryDirectory(prefix="s09-sbom-overrun-") as temporary:
            artifact = Path(temporary) / "overrun.apk"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(SystemExit),
            ):
                module.artifact_entries(artifact)

        self.assertEqual(stream.requests, [info.file_size + 1])

    def test_artifact_inventory_rejects_streamed_hash_mismatch(self):
        module = self.load_sbom("s09_sbom_stream_hash_mismatch")
        payload = b"expected-native-payload"
        with tempfile.TemporaryDirectory(prefix="s09-sbom-hash-mismatch-") as temporary:
            artifact = Path(temporary) / "hash-mismatch.apk"
            with zipfile.ZipFile(artifact, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("lib/arm64-v8a/libcorrupt.so", payload)
            corrupted = bytearray(artifact.read_bytes())
            payload_offset = corrupted.index(payload)
            corrupted[payload_offset] ^= 0x01
            artifact.write_bytes(corrupted)
            with self.assertRaises(SystemExit):
                module.artifact_entries(artifact)

    def test_play_binding_rejects_oversized_signature_without_reading_it(self):
        from unittest import mock

        module = self.load_play_binding("s09_play_signature_size_bomb")

        class Info:
            def __init__(self, filename, file_size):
                self.filename = filename
                self.file_size = file_size
                self.external_attr = 0
                self.flag_bits = 0
                self.CRC = 0

            def is_dir(self):
                return False

        infos = [
            Info("base/manifest/AndroidManifest.xml", 1),
            Info("BundleConfig.pb", 1),
            Info("META-INF/MANIFEST.MF", 1),
            Info("META-INF/CERT.SF", 1),
            Info("META-INF/CERT.RSA", 8 * 1024 * 1024 + 1),
        ]

        class FakeArchive:
            read_calls = 0

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return infos

            def read(self, _info):
                self.read_calls += 1
                return b"tiny"

        archive = FakeArchive()
        with tempfile.TemporaryDirectory(prefix="s09-play-signature-bomb-") as temporary:
            artifact = Path(temporary) / "app-play-release.aab"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=archive),
                self.assertRaises(module.BindingError),
            ):
                module.artifact_facts(artifact)

        self.assertEqual(archive.read_calls, 0)

    def test_play_binding_hashes_signature_while_streaming(self):
        import io
        from unittest import mock

        module = self.load_play_binding("s09_play_signature_stream")
        signature = b"s" * (2 * 1024 * 1024 + 17)

        class Info:
            def __init__(self, filename, payload):
                self.filename = filename
                self.payload = payload
                self.file_size = len(payload)
                self.external_attr = 0
                self.flag_bits = 0
                self.CRC = 0

            def is_dir(self):
                return False

        infos = [
            Info("base/manifest/AndroidManifest.xml", b"m"),
            Info("BundleConfig.pb", b"b"),
            Info("META-INF/MANIFEST.MF", b"manifest"),
            Info("META-INF/CERT.SF", b"sidecar"),
            Info("META-INF/CERT.RSA", signature),
        ]

        class TrackingStream(io.BytesIO):
            def __init__(self, data):
                super().__init__(data)
                self.requests = []

            def read(self, size=-1):
                self.requests.append(size)
                return super().read(size)

        stream = TrackingStream(signature)

        class FakeArchive:
            read_calls = 0
            open_calls = 0

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return infos

            def read(self, info):
                self.read_calls += 1
                return info.payload

            def open(self, info, mode="r"):
                self.open_calls += 1
                self.open_mode = mode
                self.opened = info.filename
                return stream

        archive = FakeArchive()
        with tempfile.TemporaryDirectory(prefix="s09-play-signature-stream-") as temporary:
            artifact = Path(temporary) / "app-play-release.aab"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with mock.patch.object(module.zipfile, "ZipFile", return_value=archive):
                facts = module.artifact_facts(artifact)

        self.assertEqual(archive.read_calls, 0)
        self.assertEqual(archive.open_calls, 1)
        self.assertEqual(archive.open_mode, "r")
        self.assertEqual(archive.opened, "META-INF/CERT.RSA")
        self.assertTrue(stream.requests)
        self.assertLessEqual(max(stream.requests), 1024 * 1024)
        self.assertEqual(
            facts["signatureFiles"],
            [{"path": "META-INF/CERT.RSA", "sha256": hashlib.sha256(signature).hexdigest()}],
        )

    def test_play_binding_rejects_streamed_signature_size_mismatch(self):
        import io
        from unittest import mock

        module = self.load_play_binding("s09_play_signature_mismatch")

        class Info:
            def __init__(self, filename, file_size):
                self.filename = filename
                self.file_size = file_size
                self.external_attr = 0
                self.flag_bits = 0
                self.CRC = 0

            def is_dir(self):
                return False

        infos = [
            Info("base/manifest/AndroidManifest.xml", 1),
            Info("BundleConfig.pb", 1),
            Info("META-INF/MANIFEST.MF", 1),
            Info("META-INF/CERT.SF", 1),
            Info("META-INF/CERT.RSA", 5),
        ]

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return infos

            def open(self, _info, mode="r"):
                return io.BytesIO(b"four")

        with tempfile.TemporaryDirectory(prefix="s09-play-signature-mismatch-") as temporary:
            artifact = Path(temporary) / "app-play-release.aab"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(module.BindingError),
            ):
                module.artifact_facts(artifact)

    def test_play_binding_stops_at_streamed_signature_overrun(self):
        from unittest import mock

        module = self.load_play_binding("s09_play_signature_overrun")

        class Info:
            def __init__(self, filename, file_size):
                self.filename = filename
                self.file_size = file_size
                self.external_attr = 0
                self.flag_bits = 0
                self.CRC = 0

            def is_dir(self):
                return False

        infos = [
            Info("base/manifest/AndroidManifest.xml", 1),
            Info("BundleConfig.pb", 1),
            Info("META-INF/MANIFEST.MF", 1),
            Info("META-INF/CERT.SF", 1),
            Info("META-INF/CERT.RSA", 4),
        ]

        class OverrunStream:
            def __init__(self):
                self.requests = []

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, size=-1):
                self.requests.append(size)
                return b"x" * size if len(self.requests) < 3 else b""

        stream = OverrunStream()

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return infos

            def open(self, _info, mode="r"):
                return stream

        with tempfile.TemporaryDirectory(prefix="s09-play-signature-overrun-") as temporary:
            artifact = Path(temporary) / "app-play-release.aab"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(module.BindingError),
            ):
                module.artifact_facts(artifact)

        self.assertEqual(stream.requests, [infos[-1].file_size + 1])

    def test_play_binding_rejects_declared_member_size_bomb(self):
        import io
        from unittest import mock

        module = self.load_play_binding("s09_play_member_size_bomb")

        class Info:
            def __init__(self, filename, file_size):
                self.filename = filename
                self.file_size = file_size
                self.external_attr = 0
                self.flag_bits = 0
                self.CRC = 0

            def is_dir(self):
                return False

        infos = [
            Info("base/manifest/AndroidManifest.xml", 1),
            Info("BundleConfig.pb", 1),
            Info("META-INF/MANIFEST.MF", 1),
            Info("META-INF/CERT.SF", 1),
            Info("META-INF/CERT.RSA", 1),
            Info("base/assets/member-bomb.bin", 256 * 1024 * 1024 + 1),
        ]

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return infos

            def open(self, _info, mode="r"):
                return io.BytesIO(b"s")

        with tempfile.TemporaryDirectory(prefix="s09-play-member-size-bomb-") as temporary:
            artifact = Path(temporary) / "app-play-release.aab"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(module.BindingError),
            ):
                module.artifact_facts(artifact)

    def test_play_binding_rejects_declared_total_size_bomb(self):
        import io
        from unittest import mock

        module = self.load_play_binding("s09_play_total_size_bomb")

        class Info:
            def __init__(self, filename, file_size):
                self.filename = filename
                self.file_size = file_size
                self.external_attr = 0
                self.flag_bits = 0
                self.CRC = 0

            def is_dir(self):
                return False

        infos = [
            Info("base/manifest/AndroidManifest.xml", 1),
            Info("BundleConfig.pb", 1),
            Info("META-INF/MANIFEST.MF", 1),
            Info("META-INF/CERT.SF", 1),
            Info("META-INF/CERT.RSA", 1),
            *[
                Info(f"base/assets/total-bomb-{index}.bin", 220 * 1024 * 1024)
                for index in range(5)
            ],
        ]

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return infos

            def open(self, _info, mode="r"):
                return io.BytesIO(b"s")

        with tempfile.TemporaryDirectory(prefix="s09-play-total-size-bomb-") as temporary:
            artifact = Path(temporary) / "app-play-release.aab"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(module.BindingError),
            ):
                module.artifact_facts(artifact)

    def test_play_binding_rejects_member_count_bomb(self):
        import io
        from unittest import mock

        module = self.load_play_binding("s09_play_member_count_bomb")

        class Info:
            def __init__(self, filename):
                self.filename = filename
                self.file_size = 1
                self.external_attr = 0
                self.flag_bits = 0
                self.CRC = 0

            def is_dir(self):
                return False

        infos = [
            Info("base/manifest/AndroidManifest.xml"),
            Info("BundleConfig.pb"),
            Info("META-INF/MANIFEST.MF"),
            Info("META-INF/CERT.SF"),
            Info("META-INF/CERT.RSA"),
            *[Info(f"base/assets/empty-{index}.txt") for index in range(9_996)],
        ]

        class FakeArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return infos

            def open(self, _info, mode="r"):
                return io.BytesIO(b"s")

        with tempfile.TemporaryDirectory(prefix="s09-play-member-count-bomb-") as temporary:
            artifact = Path(temporary) / "app-play-release.aab"
            artifact.write_bytes(b"fake ZIP selected by the test double")
            with (
                mock.patch.object(module.zipfile, "ZipFile", return_value=FakeArchive()),
                self.assertRaises(module.BindingError),
            ):
                module.artifact_facts(artifact)


class Slice5GeneratorReviewTest(unittest.TestCase):
    def test_generator_emits_nonempty_complete_review_only_when_every_entry_is_resolved(self):
        import importlib.util

        specification = importlib.util.spec_from_file_location(
            "s09_sbom_generator", ROOT / "tool/sbom/generate.py"
        )
        module = importlib.util.module_from_spec(specification)
        assert specification.loader is not None
        specification.loader.exec_module(module)
        components = [
            {
                "bom-ref": "pkg:fixture",
                "licenses": [{"expression": "MIT"}],
                "properties": [{"name": "hermes.license.evidence", "value": "LICENSE"}],
            }
        ]
        assets = [
            {"path": "assets/fixture", "license": "MIT", "licenseEvidence": "LICENSE"}
        ]
        packaged = [
            {"path": "lib/fixture.so", "license": "MIT", "licenseEvidence": "LICENSE"}
        ]
        complete = module.artifact_license_review(
            "fullRelease", "a" * 64, "b" * 40, components, assets, packaged
        )
        packaged[0]["license"] = "NOASSERTION"
        incomplete = module.artifact_license_review(
            "fullRelease", "a" * 64, "b" * 40, components, assets, packaged
        )
        self.assertEqual(complete["status"], "COMPLETE")
        self.assertTrue(complete["dependencyComponents"])
        self.assertTrue(complete["sourceAssets"])
        self.assertTrue(complete["packagedEntries"])
        self.assertEqual(complete["unresolved"], [])
        self.assertEqual(incomplete["status"], "REVIEW_REQUIRED")
        self.assertTrue(incomplete["unresolved"])

    def test_real_flutter_native_path_uses_explicit_reviewed_catalog_evidence(self):
        import importlib.util

        specification = importlib.util.spec_from_file_location(
            "s09_sbom_native_catalog", ROOT / "tool/sbom/generate.py"
        )
        module = importlib.util.module_from_spec(specification)
        assert specification.loader is not None
        specification.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix="s09-native-license-") as temporary:
            artifact = Path(temporary) / "app-arm64-v8a-full-release.apk"
            with zipfile.ZipFile(artifact, "w") as archive:
                archive.writestr("lib/arm64-v8a/libapp.so", b"native fixture")
                archive.writestr("lib/arm64-v8a/libevil.so", b"unknown fixture")
            entries = module.artifact_entries(artifact)
        by_path = {entry["path"]: entry for entry in entries}
        reviewed = by_path["lib/arm64-v8a/libapp.so"]
        unknown = by_path["lib/arm64-v8a/libevil.so"]
        self.assertEqual(reviewed["license"], "GPL-3.0-only")
        self.assertEqual(reviewed["licenseEvidence"], "LICENSE")
        self.assertEqual(unknown["license"], "NOASSERTION")
        self.assertEqual(unknown["licenseEvidence"], "none")
        review = module.artifact_license_review(
            "fullRelease",
            "a" * 64,
            "b" * 40,
            [{
                "bom-ref": "pkg:fixture",
                "licenses": [{"expression": "MIT"}],
                "properties": [{"name": "hermes.license.evidence", "value": "LICENSE"}],
            }],
            [{"path": "assets/fixture", "license": "MIT", "licenseEvidence": "LICENSE"}],
            [reviewed],
        )
        self.assertEqual(review["status"], "COMPLETE")
        self.assertEqual(review["unresolved"], [])

    def test_checked_in_sboms_match_current_generator_inputs(self):
        import importlib.util

        specification = importlib.util.spec_from_file_location(
            "s09_sbom_fingerprint", ROOT / "tool/sbom/generate.py"
        )
        module = importlib.util.module_from_spec(specification)
        assert specification.loader is not None
        specification.loader.exec_module(module)
        expected = module.fingerprint_inputs()
        for name in (
            "fullRelease.cdx.json",
            "playRelease.cdx.json",
            "fullRelease.license-review.json",
            "playRelease.license-review.json",
            "source-assets.json",
        ):
            with self.subTest(name=name):
                document = json.loads((ROOT / "sbom" / name).read_text(encoding="utf-8"))
                if name.endswith(".cdx.json"):
                    properties = {
                        item["name"]: item["value"]
                        for item in document["metadata"]["properties"]
                    }
                    actual = properties["hermes.input.sha256"]
                else:
                    actual = document["inputFingerprint"]
                self.assertEqual(actual, expected)


class WorkflowContractTest(unittest.TestCase):
    def test_public_workflow_never_uploads_or_builds_signed_candidates(self):
        workflow = (ROOT / ".github/workflows/build-apk.yml").read_text(encoding="utf-8")
        forbidden = (
            "actions/upload-artifact",
            "actions/download-artifact",
            "actions/attest",
            "flutter build apk",
            "flutter build appbundle",
            "KEYSTORE_BASE64",
            "STORE_PASSWORD",
            "KEY_PASSWORD",
            "KEY_ALIAS",
            "EXPECTED_CERT_SHA256",
            "release-public",
            "replica-output",
        )
        for marker in forbidden:
            with self.subTest(marker=marker):
                self.assertNotIn(marker, workflow)
        self.assertIn("CI verification only", workflow)

    def test_release_workflow_rejects_semver_named_branch(self):
        workflow = (ROOT / ".github/workflows/build-apk.yml").read_text(encoding="utf-8")
        self.assertNotIn("if: github.ref_type == 'tag'", workflow)
        self.assertIn("RELEASE_REF_TYPE: ${{ github.ref_type }}", workflow)
        self.assertIn('[[ "$RELEASE_REF_TYPE" == "tag" ]]', workflow)
        self.assertIn('[[ "$GITHUB_REF" == "refs/tags/$RELEASE_TAG" ]]', workflow)
        self.assertIn('git rev-parse "refs/tags/$RELEASE_TAG^{commit}"', workflow)
        self.assertNotIn('git rev-list -n 1 "$RELEASE_TAG"', workflow)

    def test_final_public_validator_anchors_commit_to_fully_qualified_tag(self):
        validator = (ROOT / "tool/release/validate_public_assets.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('git -C "$ROOT" rev-parse "refs/tags/$RELEASE_TAG^{commit}"', validator)
        self.assertIn('[[ "$SOURCE_COMMIT" == "$RELEASE_COMMIT" ]]', validator)
        self.assertIn('[[ "$TAG_COMMIT" == "$RELEASE_COMMIT" ]]', validator)
        self.assertNotIn('git -C "$ROOT" rev-list -n 1 "$RELEASE_TAG"', validator)

    def test_final_public_validator_freezes_one_bundle_for_all_gates(self):
        validator = (ROOT / "tool/release/validate_public_assets.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('VALIDATION_DIRECTORY="$(mktemp -d', validator)
        self.assertIn('validate_asset_directory "$VALIDATION_DIRECTORY"', validator)
        self.assertIn('--bundle "$VALIDATION_DIRECTORY/provenance.intoto.jsonl"', validator)
        self.assertIn('--asset-directory "$VALIDATION_DIRECTORY"', validator)
        self.assertIn('--archive "$VALIDATION_DIRECTORY/hermes-console-release-evidence.tar.gz"', validator)
        self.assertIn('cmp -- "$PUBLIC_DIRECTORY/$expected" "$VALIDATION_DIRECTORY/$expected"', validator)

    def test_crypto_verifier_uses_one_nonconflicting_certificate_identity_constraint(self):
        verifier = (ROOT / "tool/release/verify_public_provenance.py").read_text(
            encoding="utf-8"
        )
        command = verifier[verifier.index("        command = [") : verifier.index(
            "        try:\n            result = subprocess.run", verifier.index("        command = [")
        )]
        self.assertIn('"--cert-identity"', command)
        self.assertNotIn('"--signer-workflow"', command)

    def test_distribution_policy_documents_private_local_staging_only(self):
        policy = (ROOT / "docs/RELEASE_DISTRIBUTION.md").read_text(encoding="utf-8")
        self.assertIn("GitHub Actions artifacts are public-repository downloads", policy)
        self.assertIn("must never carry a signed APK, AAB", policy)
        self.assertIn("owner-controlled local/private filesystem", policy)
        self.assertIn("observed two-build byte identity", policy)
        self.assertIn("not a general reproducible-build claim", policy)
        self.assertIn("v1.2.9", policy)
        self.assertIn("86edaa150fabd33d8184f5b958400cabadacb49632f7ec50ecbe49608058d159", policy)
        self.assertIn(
            "f366fdfc011b65c1b3f44e777fc876be21d3492ec3b0b0cf014536c0ac3490c3",
            policy,
        )

    def test_direct_workflow_is_fail_closed_and_preserves_channel_separation(self):
        workflow = (ROOT / ".github/workflows/build-apk.yml").read_text(encoding="utf-8")
        self.assertIn("verify_release_identity.py", workflow)
        self.assertIn(".commit.verification", workflow)
        self.assertIn("authorLogin", workflow)
        self.assertIn("committerLogin", workflow)
        self.assertIn("--policy tool/release/release_contract.json", workflow)
        self.assertNotIn("if: startsWith(github.ref, 'refs/tags/v')", workflow)
        self.assertNotIn("if: github.ref_type == 'tag'", workflow)
        self.assertNotIn("--flavor play", workflow)
        self.assertNotIn("--flavor qa", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("id-token: write", workflow)
        self.assertNotIn("attestations: write", workflow)
        self.assertNotIn("artifact-metadata: write", workflow)
        self.assertNotIn("gh release", workflow)
        self.assertIn("python3 -m unittest discover", workflow)
        self.assertIn("./tool/sbom/generate.sh", workflow)
        self.assertIn("git diff --exit-code -- sbom", workflow)
        self.assertIn(
            "f366fdfc011b65c1b3f44e777fc876be21d3492ec3b0b0cf014536c0ac3490c3",
            workflow,
        )


class RebuildComparisonTest(unittest.TestCase):
    def run_compare(
        self, channel: str, first: Path, second: Path, output: Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                PYTHON,
                str(ROOT / "tool/release/compare_rebuilds.py"),
                "--channel",
                channel,
                "--first",
                str(first),
                "--second",
                str(second),
                "--output",
                str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def write_aab(
        path: Path,
        *,
        timestamp: tuple[int, int, int, int, int, int],
        reverse: bool = False,
        signature: bytes = b"signature",
        payload: bytes = b"program",
    ) -> None:
        entries = [
            ("base/manifest/AndroidManifest.xml", b"manifest"),
            ("BundleConfig.pb", b"config"),
            ("base/dex/classes.dex", payload),
            ("META-INF/MANIFEST.MF", b"manifest-signature-index"),
            ("META-INF/RELEASE.SF", b"signature-index"),
            ("META-INF/RELEASE.RSA", signature),
        ]
        if reverse:
            entries.reverse()
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in entries:
                info = zipfile.ZipInfo(name, timestamp)
                info.compress_type = (
                    zipfile.ZIP_DEFLATED if reverse else zipfile.ZIP_STORED
                )
                archive.writestr(info, data)

    def test_direct_apks_require_byte_identical_rebuilds(self):
        with tempfile.TemporaryDirectory(prefix="s09-rebuild-apk-") as temporary:
            root = Path(temporary)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            for name in APKS:
                (first / name).write_bytes((name + "\n").encode())
                (second / name).write_bytes((name + "\n").encode())
            output = root / "equal.json"
            equal = self.run_compare("direct-public", first, second, output)
            report = json.loads(output.read_text()) if output.exists() else {}
            (second / next(iter(APKS))).write_bytes(b"different signed APK")
            different = self.run_compare(
                "direct-public", first, second, root / "different.json"
            )
        self.assertEqual(equal.returncode, 0, equal.stderr)
        self.assertFalse(report.get("byteReproducible"))
        self.assertFalse(report.get("inputsCryptographicallyPinned"))
        self.assertTrue(report.get("observedTwoBuildByteIdentity"))
        self.assertEqual(report.get("claim"), "observed-two-build-byte-identical")
        self.assertNotEqual(different.returncode, 0)

    def test_aab_reports_zip_metadata_without_claiming_byte_reproducibility(self):
        with tempfile.TemporaryDirectory(prefix="s09-rebuild-aab-meta-") as temporary:
            root = Path(temporary)
            first = root / "first/app-play-release.aab"
            second = root / "second/app-play-release.aab"
            first.parent.mkdir()
            second.parent.mkdir()
            self.write_aab(first, timestamp=(2020, 1, 1, 0, 0, 0))
            self.write_aab(
                second,
                timestamp=(2026, 2, 2, 2, 2, 2),
                reverse=True,
            )
            output = root / "report.json"
            result = self.run_compare("play-private", first, second, output)
            report = json.loads(output.read_text()) if output.exists() else {}
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(report.get("byteReproducible"))
        self.assertFalse(report.get("inputsCryptographicallyPinned"))
        self.assertTrue(report.get("zipEntryPayloadReproducible"))
        self.assertTrue(report.get("functionalPayloadEquivalent"))
        self.assertEqual(report.get("claim"), "observed-two-build-entry-payload-identical")
        self.assertEqual(report.get("differenceClass"), "zip-container-metadata-only")

    def test_aab_distinguishes_signature_metadata_from_functional_payload(self):
        with tempfile.TemporaryDirectory(prefix="s09-rebuild-aab-signature-") as temporary:
            root = Path(temporary)
            first = root / "first/app-play-release.aab"
            second = root / "second/app-play-release.aab"
            first.parent.mkdir()
            second.parent.mkdir()
            self.write_aab(first, timestamp=(2020, 1, 1, 0, 0, 0))
            self.write_aab(
                second,
                timestamp=(2020, 1, 1, 0, 0, 0),
                signature=b"different signature encoding",
            )
            output = root / "report.json"
            equivalent = self.run_compare(
                "play-private", first, second, output
            )
            report = json.loads(output.read_text()) if output.exists() else {}
            third = root / "third/app-play-release.aab"
            third.parent.mkdir()
            self.write_aab(
                third,
                timestamp=(2020, 1, 1, 0, 0, 0),
                payload=b"different program",
            )
            changed = self.run_compare(
                "play-private", first, third, root / "changed.json"
            )
        self.assertEqual(equivalent.returncode, 0, equivalent.stderr)
        self.assertFalse(report.get("zipEntryPayloadReproducible"))
        self.assertTrue(report.get("functionalPayloadEquivalent"))
        self.assertFalse(report.get("inputsCryptographicallyPinned"))
        self.assertEqual(report.get("claim"), "observed-two-build-functional-equivalence")
        self.assertEqual(report.get("differenceClass"), "signature-metadata-only")
        self.assertNotEqual(changed.returncode, 0)


class DsseSlsaPolicyTest(unittest.TestCase):
    tag = "v9.8.7"
    commit = "a" * 40

    def write_fixture(self, root: Path, mutate=None) -> tuple[Path, Path]:
        assets = root / "assets"
        assets.mkdir()
        subjects = []
        for name in (*APKS, "hermes-console-release-evidence.tar.gz"):
            path = assets / name
            path.write_bytes((name + " fixture\n").encode())
            subjects.append(
                {
                    "name": name,
                    "digest": {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()},
                }
            )
        statement = {
            "_type": "https://in-toto.io/Statement/v1",
            "subject": sorted(subjects, key=lambda item: item["name"]),
            "predicateType": "https://slsa.dev/provenance/v1",
            "predicate": {
                "buildDefinition": {
                    "buildType": "https://actions.github.io/buildtypes/workflow/v1",
                    "externalParameters": {
                        "workflow": {
                            "ref": f"refs/tags/{self.tag}",
                            "repository": "https://github.com/xP3ta/hermes-console",
                            "path": ".github/workflows/build-apk.yml",
                        }
                    },
                    "resolvedDependencies": [
                        {
                            "uri": "git+https://github.com/xP3ta/hermes-console"
                            f"@refs/tags/{self.tag}",
                            "digest": {"gitCommit": self.commit},
                        }
                    ],
                },
                "runDetails": {
                    "builder": {
                        "id": "https://github.com/xP3ta/hermes-console/"
                        f".github/workflows/build-apk.yml@refs/tags/{self.tag}"
                    },
                    "metadata": {
                        "invocationId": "https://github.com/xP3ta/hermes-console/"
                        "actions/runs/123456/attempts/1"
                    },
                },
            },
        }
        if mutate is not None:
            mutate(statement)
        bundle = {
            "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
            "verificationMaterial": {
                "certificate": {"rawBytes": base64.b64encode(b"certificate").decode()},
                "tlogEntries": [{"logIndex": "1"}],
            },
            "dsseEnvelope": {
                "payloadType": "application/vnd.in-toto+json",
                "payload": base64.b64encode(canonical(statement)).decode(),
                "signatures": [
                    {"keyid": "", "sig": base64.b64encode(b"signature").decode()}
                ],
            },
        }
        path = root / "provenance.intoto.jsonl"
        path.write_bytes(canonical(bundle))
        return assets, path

    def run_validator(self, assets: Path, bundle: Path):
        return subprocess.run(
            [
                PYTHON,
                str(ROOT / "tool/release/verify_slsa_bundle.py"),
                "--bundle",
                str(bundle),
                "--asset-directory",
                str(assets),
                "--policy",
                str(ROOT / "tool/release/release_contract.json"),
                "--tag",
                self.tag,
                "--commit",
                self.commit,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_exact_dsse_slsa_statement_and_subject_hashes_pass_structural_gate(self):
        with tempfile.TemporaryDirectory(prefix="s09-dsse-valid-") as temporary:
            assets, bundle = self.write_fixture(Path(temporary))
            result = self.run_validator(assets, bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("structural", result.stdout.casefold())
        self.assertNotIn("signature verified", result.stdout.casefold())

    def test_standard_sigstore_signature_without_optional_keyid_passes_structural_gate(self):
        with tempfile.TemporaryDirectory(prefix="s09-dsse-no-keyid-") as temporary:
            assets, bundle = self.write_fixture(Path(temporary))
            value = json.loads(bundle.read_text(encoding="utf-8"))
            del value["dsseEnvelope"]["signatures"][0]["keyid"]
            bundle.write_bytes(canonical(value))
            result = self.run_validator(assets, bundle)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tampered_subject_source_workflow_or_predicate_fails(self):
        mutations = (
            lambda value: value["subject"][0]["digest"].update(sha256="f" * 64),
            lambda value: value["predicate"]["buildDefinition"]["externalParameters"]["workflow"].update(repository="https://github.com/attacker/fork"),
            lambda value: value["predicate"]["buildDefinition"]["externalParameters"]["workflow"].update(ref="refs/heads/main"),
            lambda value: value.update(predicateType="https://example.invalid/provenance"),
            lambda value: value["predicate"]["buildDefinition"]["resolvedDependencies"][0]["digest"].update(gitCommit="b" * 40),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                prefix="s09-dsse-bad-"
            ) as temporary:
                assets, bundle = self.write_fixture(Path(temporary), mutation)
                result = self.run_validator(assets, bundle)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class FinalPublicProvenanceGateTest(unittest.TestCase):
    tag = "v9.8.7"
    commit = "a" * 40

    def write_public_fixture(self, root: Path, mutation: str) -> Path:
        public = Slice1PublicAssetAllowlistTest().fixture(root)
        subjects = [
            {
                "name": name,
                "digest": {"sha256": hashlib.sha256((public / name).read_bytes()).hexdigest()},
            }
            for name in sorted((*APKS, "hermes-console-release-evidence.tar.gz"))
        ]
        statement = {
            "_type": "https://in-toto.io/Statement/v1",
            "subject": subjects,
            "predicateType": "https://slsa.dev/provenance/v1",
            "predicate": {
                "buildDefinition": {
                    "buildType": "https://actions.github.io/buildtypes/workflow/v1",
                    "externalParameters": {
                        "workflow": {
                            "ref": f"refs/tags/{self.tag}",
                            "repository": "https://github.com/xP3ta/hermes-console",
                            "path": ".github/workflows/build-apk.yml",
                        }
                    },
                    "resolvedDependencies": [
                        {
                            "uri": "git+https://github.com/xP3ta/hermes-console"
                            f"@refs/tags/{self.tag}",
                            "digest": {"gitCommit": self.commit},
                        }
                    ],
                },
                "runDetails": {
                    "builder": {
                        "id": "https://github.com/xP3ta/hermes-console/"
                        f".github/workflows/build-apk.yml@refs/tags/{self.tag}"
                    },
                    "metadata": {
                        "invocationId": "https://github.com/xP3ta/hermes-console/"
                        "actions/runs/123456/attempts/1"
                    },
                },
            },
        }
        certificate = b"unsigned certificate fixture"
        if mutation == "wrong-oidc":
            certificate = b"certificate claiming https://issuer.example.invalid"
        elif mutation == "wrong-workflow":
            statement["predicate"]["buildDefinition"]["externalParameters"]["workflow"]["path"] = ".github/workflows/attacker.yml"
        elif mutation == "wrong-ref":
            statement["predicate"]["buildDefinition"]["externalParameters"]["workflow"]["ref"] = "refs/heads/v9.8.7"
        elif mutation == "wrong-commit":
            statement["predicate"]["buildDefinition"]["resolvedDependencies"][0]["digest"]["gitCommit"] = "b" * 40
        elif mutation == "wrong-subject":
            statement["subject"][0]["digest"]["sha256"] = "f" * 64
        bundle = {
            "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
            "verificationMaterial": {
                "certificate": {"rawBytes": base64.b64encode(certificate).decode()},
                "tlogEntries": [{"logIndex": "1"}],
            },
            "dsseEnvelope": {
                "payloadType": "application/vnd.in-toto+json",
                "payload": base64.b64encode(canonical(statement)).decode(),
                "signatures": [
                    {"keyid": "", "sig": base64.b64encode(b"unsigned signature").decode()}
                ],
            },
        }
        (public / "provenance.intoto.jsonl").write_bytes(canonical(bundle))
        checksummed = [*APKS, "hermes-console-release-evidence.tar.gz", "provenance.intoto.jsonl"]
        (public / "SHA256SUMS").write_text(
            "".join(
                f"{hashlib.sha256((public / name).read_bytes()).hexdigest()}  {name}\n"
                for name in checksummed
            ),
            encoding="ascii",
        )
        return public

    def test_final_public_gate_rejects_unsigned_wrong_oidc_workflow_ref_commit_and_subject_provenance(self):
        for mutation in (
            "unsigned",
            "wrong-oidc",
            "wrong-workflow",
            "wrong-ref",
            "wrong-commit",
            "wrong-subject",
        ):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                prefix="s09-final-provenance-"
            ) as temporary:
                root = Path(temporary)
                public = self.write_public_fixture(root, mutation)
                result = subprocess.run(
                    [
                        "bash",
                        str(ROOT / "tool/release/validate_public_assets.sh"),
                        str(public),
                        self.tag,
                        self.commit,
                        str(root / "trusted-toolchain.json"),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "cryptographic provenance verification failed",
                    result.stderr.casefold(),
                )


class ReleaseContractAndDoubleBuildTest(unittest.TestCase):
    def test_contract_pins_lock_channels_and_keyless_identity(self):
        policy = json.loads(
            (ROOT / "tool/release/release_contract.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            policy["source"]["authoritativeLockSha256"],
            "f366fdfc011b65c1b3f44e777fc876be21d3492ec3b0b0cf014536c0ac3490c3",
        )
        self.assertEqual(policy["android"]["packageId"], "dev.xpetalab.hermesconsole")
        self.assertEqual(set(policy["channels"]), {"direct-public", "play-private"})
        self.assertEqual(policy["sourceAuthorization"]["forge"], "github.com")
        self.assertEqual(policy["sourceAuthorization"]["authorizedActors"], ["xP3ta"])
        self.assertTrue(policy["sourceAuthorization"]["requireAuthorAndCommitter"])
        play_tools = policy["playInspectionTools"]
        self.assertEqual(play_tools["platform"], "linux-x86_64")
        self.assertEqual(
            play_tools["tools"],
            {
                "apkanalyzer": {
                    "root": "android-sdk",
                    "path": "cmdline-tools/latest/bin/apkanalyzer",
                    "sha256": "c3277b8f17d26159c6496740114b5ed639d221107d94f47ff8a2ed4a5ea29026",
                },
                "jarsigner": {
                    "root": "jdk",
                    "path": "bin/jarsigner",
                    "sha256": "2c3ad93fbe432cda2f3338acd0a150a472860c38477845208b673f306f5e09d7",
                },
                "keytool": {
                    "root": "jdk",
                    "path": "bin/keytool",
                    "sha256": "bfd62a2ed799d9f2760ca528df3dc2df31fb6a33c521321b84e2ab67007b987d",
                },
            },
        )
        continuity = policy["signerContinuity"]["direct-public"]
        self.assertEqual(continuity["baselineTag"], "v1.2.9")
        self.assertEqual(
            continuity["baselineArtifact"], "app-arm64-v8a-full-release.apk"
        )
        self.assertEqual(
            continuity["baselineArtifactSha256"],
            "f5187dbc57caa881ca3f21453335df320e271d7358e81e6095e6d9af50a9f734",
        )
        self.assertEqual(
            continuity["certificateSha256"],
            "86edaa150fabd33d8184f5b958400cabadacb49632f7ec50ecbe49608058d159",
        )
        self.assertEqual(
            policy["signerContinuity"]["play-private"]["certificateSha256"],
            continuity["certificateSha256"],
        )
        public_tools = policy["publicInspectionTools"]
        self.assertEqual(public_tools["platform"], "linux-x86_64")
        self.assertEqual(public_tools["buildToolsRevision"], "36.0.0")
        self.assertEqual(public_tools["commandLineToolsRevision"], "12.0")
        self.assertEqual(
            public_tools["tools"]["apksigner"]["sha256"],
            "b47549e373b895ce6ca620d0c7887e674d9615ffa837a86ac601dcfd04adb0f0",
        )
        direct = policy["channels"]["direct-public"]
        self.assertEqual(
            direct["publicAssets"],
            [
                "SHA256SUMS",
                "app-arm64-v8a-full-release.apk",
                "app-armeabi-v7a-full-release.apk",
                "app-x86_64-full-release.apk",
                "hermes-console-release-evidence.tar.gz",
                "provenance.intoto.jsonl",
            ],
        )
        self.assertNotIn("app-play-release.aab", direct["publicAssets"])
        self.assertEqual(direct["rebuildAcceptance"], "observed-two-build-byte-identity")
        self.assertFalse(direct["inputsCryptographicallyPinned"])
        self.assertEqual(policy["channels"]["play-private"]["visibility"], "private")
        self.assertEqual(policy["provenance"]["oidcIssuer"], "https://token.actions.githubusercontent.com")
        self.assertEqual(policy["provenance"]["signatureMode"], "keyless")
        self.assertEqual(policy["provenance"]["cryptographicVerifier"], "gh attestation verify")
        self.assertEqual(policy["provenance"]["verifierVersion"], "2.98.0")
        self.assertEqual(
            policy["provenance"]["verifierSha256"],
            "62885b97de6a0cd85e616cdd94bcda908bf5cf1018094385892b05cea3537163",
        )
        self.assertEqual(
            policy["provenance"]["certificateIdentityTemplate"],
            "https://github.com/xP3ta/hermes-console/.github/workflows/build-apk.yml@refs/tags/{tag}",
        )
        self.assertEqual(
            policy["provenance"]["verifierSignerWorkflow"],
            "xP3ta/hermes-console/.github/workflows/build-apk.yml",
        )

    def test_double_build_script_uses_clean_clones_and_isolated_caches(self):
        script = ROOT / "tool/release/double_build.sh"
        result = subprocess.run(
            ["bash", "-n", str(script)], check=False, capture_output=True, text=True
        )
        source = script.read_text(encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("git clone --no-local", source)
        self.assertIn("PUB_CACHE", source)
        self.assertIn("GRADLE_USER_HOME", source)
        self.assertIn("f366fdfc011b65c1b3f44e777fc876be21d3492ec3b0b0cf014536c0ac3490c3", source)
        self.assertIn("compare_rebuilds.py", source)
        self.assertIn("ANDROID_HOME", source)
        self.assertIn("ANDROID_SDK_ROOT", source)
        self.assertIn("JAVA_HOME", source)
        for tool in ("flutter", "git", "python3", "java", "sha256sum", "install", "mktemp", "mv"):
            self.assertIn(f'command -v "$tool"', source)
        self.assertNotIn("gh release", source)

    def test_release_gate_rejects_artifacts_not_emitted_by_the_bound_double_build(self):
        with tempfile.TemporaryDirectory(prefix="s09-double-build-") as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            git = Slice3BuildBindingTest()
            git.git(source, "init")
            git.git(source, "config", "user.email", "fixture@example.invalid")
            git.git(source, "config", "user.name", "Fixture")
            shutil.copy2(ROOT / "pubspec.lock", source / "pubspec.lock")
            (source / "pubspec.yaml").write_text(
                "name: fixture\nversion: 1.2.3+4\n", encoding="utf-8"
            )
            (source / "android").mkdir()
            (source / "android/build.gradle").write_text("// fixture\n", encoding="utf-8")
            git.git(source, "add", ".")
            git.git(source, "commit", "-m", "fixture")
            commit = git.git(source, "rev-parse", "HEAD").stdout.strip()
            key_properties = root / "key.properties"
            key_properties.write_text("storeFile=/nonexistent-fixture\n", encoding="utf-8")
            tools = root / "tools"
            tools.mkdir()
            flutter = tools / "flutter"
            flutter.write_text(
                "#!/usr/bin/env bash\n"
                "set -Eeuo pipefail\n"
                ": \"${ANDROID_HOME:?}\" \"${ANDROID_SDK_ROOT:?}\" \"${JAVA_HOME:?}\"\n"
                "[[ $ANDROID_HOME == /fixture/android-home ]]\n"
                "[[ $ANDROID_SDK_ROOT == /fixture/android-sdk-root ]]\n"
                "[[ $JAVA_HOME == /fixture/java-home ]]\n"
                "if [[ $1 == pub ]]; then exit 0; fi\n"
                "[[ $1 == build && $2 == apk ]]\n"
                "mkdir -p build/app/outputs/flutter-apk\n"
                "for name in app-arm64-v8a-full-release.apk app-armeabi-v7a-full-release.apk app-x86_64-full-release.apk; do\n"
                "  printf 'deterministic signed fixture: %s\\n' \"$name\" > \"build/app/outputs/flutter-apk/$name\"\n"
                "done\n",
                encoding="utf-8",
            )
            flutter.chmod(0o700)
            output = root / "double-output"
            result = subprocess.run(
                [
                    "bash",
                    str(ROOT / "tool/release/double_build.sh"),
                    "direct-public",
                    str(source),
                    commit,
                    str(key_properties),
                    str(output),
                    "ab" * 32,
                ],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "PATH": f"{tools}:{os.environ['PATH']}",
                    "GIT_INDEX_FILE": str(root / "poisoned-index"),
                    "ANDROID_HOME": "/fixture/android-home",
                    "ANDROID_SDK_ROOT": "/fixture/android-sdk-root",
                    "JAVA_HOME": "/fixture/java-home",
                },
            )
            report_path = output / "rebuild-comparison.json"
            manifest_path = output / "double-build-manifest.json"
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
            manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
            emitted = [output / "replica-a" / name for name in APKS]
            valid_binding = root / "valid-source-binding.json"
            valid_command = [
                PYTHON,
                str(ROOT / "tool/release/public_build_binding.py"),
                "write",
                "--root", str(source),
                "--double-build-manifest", str(manifest_path),
                "--binding", str(valid_binding),
            ]
            for artifact in emitted:
                valid_command.extend(("--artifact", str(artifact)))
            bound = subprocess.run(
                valid_command, check=False, capture_output=True, text=True
            )

            unrelated = root / "unrelated"
            unrelated.mkdir()
            swapped_command = valid_command[:]
            swapped_command[swapped_command.index(str(valid_binding))] = str(
                root / "rejected-source-binding.json"
            )
            for artifact in emitted:
                replacement = unrelated / artifact.name
                replacement.write_bytes(b"caller-swapped unrelated artifact\n")
                index = swapped_command.index(str(artifact))
                swapped_command[index] = str(replacement)
            rejected = subprocess.run(
                swapped_command, check=False, capture_output=True, text=True
            )
            tampered_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            tampered_manifest["toolchain"]["executables"]["flutter"]["sha256"] = (
                "f" * 64
            )
            manifest_path.write_bytes(canonical(tampered_manifest))
            tampered_command = valid_command[:]
            tampered_command[tampered_command.index(str(valid_binding))] = str(
                root / "rejected-toolchain-binding.json"
            )
            rejected_toolchain = subprocess.run(
                tampered_command, check=False, capture_output=True, text=True
            )
            flutter_hash = hashlib.sha256(flutter.read_bytes()).hexdigest()
            source_tree = git.git(source, "rev-parse", "HEAD^{tree}").stdout.strip()
            emitted_hashes = {
                path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in emitted
            }
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(bound.returncode, 0, bound.stderr)
        self.assertNotEqual(rejected.returncode, 0, rejected.stdout + rejected.stderr)
        self.assertNotEqual(
            rejected_toolchain.returncode,
            0,
            rejected_toolchain.stdout + rejected_toolchain.stderr,
        )
        self.assertFalse((root / "rejected-source-binding.json").exists())
        self.assertFalse((root / "rejected-toolchain-binding.json").exists())
        self.assertFalse(report.get("byteReproducible"))
        self.assertFalse(report.get("inputsCryptographicallyPinned"))
        self.assertTrue(report.get("observedTwoBuildByteIdentity"))
        self.assertEqual(report.get("claim"), "observed-two-build-byte-identical")
        self.assertEqual(manifest.get("schema"), 1)
        self.assertEqual(manifest.get("kind"), "hermes-double-build-output")
        self.assertEqual(manifest.get("channel"), "direct-public")
        self.assertEqual(manifest.get("source", {}).get("commit"), commit)
        self.assertEqual(manifest.get("source", {}).get("treeObject"), source_tree)
        self.assertEqual(
            manifest.get("build", {}).get("expectedSignerSha256"), "ab" * 32
        )
        self.assertEqual(
            manifest.get("toolchain", {}).get("environment"),
            {
                "ANDROID_HOME": "/fixture/android-home",
                "ANDROID_SDK_ROOT": "/fixture/android-sdk-root",
                "JAVA_HOME": "/fixture/java-home",
            },
        )
        self.assertEqual(
            manifest.get("toolchain", {})
            .get("executables", {})
            .get("flutter", {})
            .get("sha256"),
            flutter_hash,
        )
        for replica in ("a", "b"):
            self.assertEqual(
                {
                    entry["name"]: entry["sha256"]
                    for entry in manifest.get("replicas", {})
                    .get(replica, {})
                    .get("artifacts", [])
                },
                emitted_hashes,
            )
        self.assertEqual(
            manifest.get("comparison", {}).get("sha256"),
            hashlib.sha256(canonical(report)).hexdigest(),
        )

    def test_failed_second_build_leaves_no_output_or_signed_residue(self):
        with tempfile.TemporaryDirectory(prefix="s09-double-build-failure-") as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            git = Slice3BuildBindingTest()
            git.git(source, "init")
            git.git(source, "config", "user.email", "fixture@example.invalid")
            git.git(source, "config", "user.name", "Fixture")
            shutil.copy2(ROOT / "pubspec.lock", source / "pubspec.lock")
            (source / "pubspec.yaml").write_text(
                "name: fixture\nversion: 1.2.3+4\n", encoding="utf-8"
            )
            (source / "android").mkdir()
            (source / "android/build.gradle").write_text("// fixture\n", encoding="utf-8")
            git.git(source, "add", ".")
            git.git(source, "commit", "-m", "fixture")
            commit = git.git(source, "rev-parse", "HEAD").stdout.strip()
            key_properties = root / "key.properties"
            key_properties.write_text("storeFile=/nonexistent-fixture\n", encoding="utf-8")
            tools = root / "tools"
            tools.mkdir()
            flutter = tools / "flutter"
            flutter.write_text(
                "#!/usr/bin/env bash\n"
                "set -Eeuo pipefail\n"
                "if [[ $1 == pub ]]; then exit 0; fi\n"
                "state=\"${BASH_SOURCE[0]}.state\"\n"
                "count=0; [[ ! -f $state ]] || count=$(<\"$state\")\n"
                "count=$((count + 1)); printf '%s' \"$count\" > \"$state\"\n"
                "[[ $count -lt 2 ]] || exit 23\n"
                "mkdir -p build/app/outputs/flutter-apk\n"
                "for name in app-arm64-v8a-full-release.apk app-armeabi-v7a-full-release.apk app-x86_64-full-release.apk; do\n"
                "  printf 'signed residue fixture' > \"build/app/outputs/flutter-apk/$name\"\n"
                "done\n",
                encoding="utf-8",
            )
            flutter.chmod(0o700)
            output = root / "failed-output"
            result = subprocess.run(
                [
                    "bash", str(ROOT / "tool/release/double_build.sh"),
                    "direct-public", str(source), commit, str(key_properties),
                    str(output), "ab" * 32,
                ],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "PATH": f"{tools}:{os.environ['PATH']}",
                    "ANDROID_HOME": "/fixture/android-home",
                    "ANDROID_SDK_ROOT": "/fixture/android-sdk-root",
                    "JAVA_HOME": "/fixture/java-home",
                },
            )
            residue_exists = output.exists()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(residue_exists, "failed build left candidate output")

    def test_toolchain_drift_after_build_cleans_manifest_and_artifacts(self):
        with tempfile.TemporaryDirectory(prefix="s09-double-build-tool-drift-") as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            git = Slice3BuildBindingTest()
            git.git(source, "init")
            git.git(source, "config", "user.email", "fixture@example.invalid")
            git.git(source, "config", "user.name", "Fixture")
            shutil.copy2(ROOT / "pubspec.lock", source / "pubspec.lock")
            (source / "pubspec.yaml").write_text(
                "name: fixture\nversion: 1.2.3+4\n", encoding="utf-8"
            )
            (source / "android").mkdir()
            (source / "android/build.gradle").write_text("// fixture\n", encoding="utf-8")
            git.git(source, "add", ".")
            git.git(source, "commit", "-m", "fixture")
            commit = git.git(source, "rev-parse", "HEAD").stdout.strip()
            key_properties = root / "key.properties"
            key_properties.write_text("storeFile=/nonexistent-fixture\n", encoding="utf-8")
            tools = root / "tools"
            tools.mkdir()
            flutter = tools / "flutter"
            flutter.write_text(
                "#!/usr/bin/env bash\n"
                "set -Eeuo pipefail\n"
                "if [[ $1 == pub ]]; then exit 0; fi\n"
                "state=\"${BASH_SOURCE[0]}.state\"\n"
                "count=0; [[ ! -f $state ]] || count=$(<\"$state\")\n"
                "count=$((count + 1)); printf '%s' \"$count\" > \"$state\"\n"
                "mkdir -p build/app/outputs/flutter-apk\n"
                "for name in app-arm64-v8a-full-release.apk app-armeabi-v7a-full-release.apk app-x86_64-full-release.apk; do\n"
                "  printf 'signed residue fixture: %s\\n' \"$name\" > \"build/app/outputs/flutter-apk/$name\"\n"
                "done\n"
                "if [[ $count -eq 2 ]]; then printf '\\n# drifted after use\\n' >> \"${BASH_SOURCE[0]}\"; fi\n",
                encoding="utf-8",
            )
            flutter.chmod(0o700)
            output = root / "drifted-output"
            result = subprocess.run(
                [
                    "bash", str(ROOT / "tool/release/double_build.sh"),
                    "direct-public", str(source), commit, str(key_properties),
                    str(output), "ab" * 32,
                ],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "PATH": f"{tools}:{os.environ['PATH']}",
                    "ANDROID_HOME": "/fixture/android-home",
                    "ANDROID_SDK_ROOT": "/fixture/android-sdk-root",
                    "JAVA_HOME": "/fixture/java-home",
                },
            )
            residue = list(root.glob(".double-build.*"))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(output.exists(), "tool drift left promoted build output")
        self.assertEqual(residue, [])


class PlayArtifactIdentityTest(unittest.TestCase):
    signer = "ab" * 32

    def run_inspection(
        self,
        root: Path,
        *,
        package: str = "dev.xpetalab.hermesconsole",
        version: str = "9.8.7",
        code: str = "42",
        signer: str | None = None,
        expected_hash: str | None = None,
        tamper_tool: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
        artifact = root / "app-play-release.aab"
        RebuildComparisonTest.write_aab(
            artifact, timestamp=(2020, 1, 1, 0, 0, 0)
        )
        pubspec = root / "pubspec.yaml"
        pubspec.write_text("name: fixture\nversion: 9.8.7+42\n", encoding="utf-8")
        tools = root / "tools"
        tools.mkdir()
        apkanalyzer = tools / "apkanalyzer"
        apkanalyzer.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            f"values={{'application-id':{package!r},'version-name':{version!r},'version-code':{code!r}}}\n"
            "print(values[sys.argv[2]])\n",
            encoding="utf-8",
        )
        jarsigner = tools / "jarsigner"
        jarsigner.write_text("#!/bin/sh\nprintf 'jar verified.\\n'\n", encoding="utf-8")
        keytool = tools / "keytool"
        measured = signer or self.signer
        fingerprint = ":".join(
            measured[index : index + 2] for index in range(0, len(measured), 2)
        )
        keytool.write_text(
            f"#!/bin/sh\nprintf 'SHA256: {fingerprint}\\n'\n", encoding="utf-8"
        )
        for tool in (apkanalyzer, jarsigner, keytool):
            tool.chmod(0o700)
        policy = root / "release-contract.json"
        policy_value = json.loads(
            (ROOT / "tool/release/release_contract.json").read_text(encoding="utf-8")
        )
        policy_value["signerContinuity"]["play-private"]["certificateSha256"] = self.signer
        policy_value["playInspectionTools"] = {
            "platform": "linux-x86_64",
            "tools": {
                "apkanalyzer": {
                    "root": "android-sdk",
                    "path": "apkanalyzer",
                    "sha256": hashlib.sha256(apkanalyzer.read_bytes()).hexdigest(),
                },
                "jarsigner": {
                    "root": "jdk",
                    "path": "jarsigner",
                    "sha256": hashlib.sha256(jarsigner.read_bytes()).hexdigest(),
                },
                "keytool": {
                    "root": "jdk",
                    "path": "keytool",
                    "sha256": hashlib.sha256(keytool.read_bytes()).hexdigest(),
                },
            },
        }
        policy.write_bytes(canonical(policy_value))
        if tamper_tool:
            apkanalyzer.write_text("#!/bin/sh\nprintf 'forged metadata\\n'\n", encoding="utf-8")
            apkanalyzer.chmod(0o700)
        output = root / "facts.json"
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        result = subprocess.run(
            [
                PYTHON,
                str(ROOT / "tool/release/inspect_play_aab.py"),
                "--artifact",
                str(artifact),
                "--pubspec",
                str(pubspec),
                "--policy",
                str(policy),
                "--expected-sha256",
                expected_hash or digest,
                "--expected-signer-sha256",
                self.signer,
                "--android-sdk-root",
                str(tools),
                "--jdk-root",
                str(tools),
                "--output",
                str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        return result, output, artifact

    def test_play_aab_package_version_signature_and_hash_pass(self):
        with tempfile.TemporaryDirectory(prefix="s09-play-identity-") as temporary:
            result, output, artifact = self.run_inspection(Path(temporary))
            facts = json.loads(output.read_text()) if output.exists() else {}
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(facts.get("channel"), "play-private")
        self.assertEqual(facts.get("package"), "dev.xpetalab.hermesconsole")
        self.assertEqual(facts.get("versionName"), "9.8.7")
        self.assertEqual(facts.get("versionCode"), 42)
        self.assertEqual(facts.get("signerCertificateSha256"), self.signer)
        self.assertEqual(facts.get("artifact", {}).get("sha256"), digest)

    def test_wrong_package_version_signature_or_hash_fails(self):
        cases = (
            {"package": "attacker.example"},
            {"version": "9.8.8"},
            {"code": "43"},
            {"signer": "cd" * 32},
            {"expected_hash": "ef" * 32},
        )
        for values in cases:
            with self.subTest(values=values), tempfile.TemporaryDirectory(
                prefix="s09-play-identity-bad-"
            ) as temporary:
                result, _, _ = self.run_inspection(Path(temporary), **values)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_changed_tool_after_reviewed_digest_fails(self):
        with tempfile.TemporaryDirectory(prefix="s09-play-fake-tool-") as temporary:
            result, _, _ = self.run_inspection(
                Path(temporary), tamper_tool=True
            )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
