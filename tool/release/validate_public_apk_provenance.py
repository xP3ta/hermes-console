#!/usr/bin/env python3
"""Reinspect every public APK using an explicit trusted, pinned toolchain."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

import inspect_public_apk as inspector
import play_build_binding as build_binding
import public_build_binding
import validate_evidence_archive
import verify_license_reviews

REVIEWED_ROOT = Path(__file__).resolve().parents[2]
REVIEWED_POLICY = REVIEWED_ROOT / "tool/release/release_contract.json"
REVIEWED_EXPECTATIONS_POLICY = REVIEWED_ROOT / "tool/release/full_release_policy.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAX_JSON_BYTES = 2 * 1024 * 1024


class ProvenanceError(ValueError):
    pass


def exact(value: Any, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ProvenanceError
    return value


def strict_string(value: Any) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        raise ProvenanceError
    return value


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def regular_file(path: Path) -> Path:
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise ProvenanceError
        result = path.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError from error
    if not result.is_file() or result.is_symlink():
        raise ProvenanceError
    return result


def directory(path: Path) -> Path:
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise ProvenanceError
        result = path.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError from error
    if not result.is_dir():
        raise ProvenanceError
    return result


def child_file(root: Path, relative: str, *, executable: bool = False) -> Path:
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or "." in path.parts or ".." in path.parts:
        raise ProvenanceError
    candidate = root
    try:
        for part in path.parts:
            candidate /= part
            if stat.S_ISLNK(candidate.lstat().st_mode):
                raise ProvenanceError
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError from error
    if not is_within(resolved, root) or not resolved.is_file():
        raise ProvenanceError
    if executable and not os.access(resolved, os.X_OK):
        raise ProvenanceError
    return resolved


def child_directory(root: Path, relative: str) -> Path:
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or "." in path.parts or ".." in path.parts:
        raise ProvenanceError
    candidate = root
    try:
        for part in path.parts:
            candidate /= part
            if stat.S_ISLNK(candidate.lstat().st_mode):
                raise ProvenanceError
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError from error
    if not is_within(resolved, root) or not resolved.is_dir():
        raise ProvenanceError
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with regular_file(path).open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise ProvenanceError from error
    return digest.hexdigest()


def sha256_tree(path: Path) -> str:
    """Hash names, types, executable bits and bytes in a runtime directory."""
    root = directory(path)
    digest = hashlib.sha256()
    try:
        entries = sorted(root.rglob("*"), key=lambda entry: entry.relative_to(root).as_posix())
        for entry in entries:
            relative = entry.relative_to(root).as_posix().encode("utf-8")
            mode = entry.lstat().st_mode
            executable = b"1" if mode & 0o111 else b"0"
            if stat.S_ISDIR(mode):
                record = b"D\0" + relative + b"\0" + executable + b"\n"
            elif stat.S_ISREG(mode):
                record = (
                    b"F\0" + relative + b"\0" + executable + b"\0"
                    + hashlib.sha256(entry.read_bytes()).hexdigest().encode("ascii") + b"\n"
                )
            elif stat.S_ISLNK(mode):
                target = os.readlink(entry).encode("utf-8")
                try:
                    resolved = entry.resolve(strict=True)
                except FileNotFoundError:
                    resolved = None
                if resolved is not None and not resolved.is_file():
                    raise ProvenanceError
                target_digest = (
                    b"missing"
                    if resolved is None
                    else hashlib.sha256(resolved.read_bytes()).hexdigest().encode("ascii")
                )
                record = b"L\0" + relative + b"\0" + target + b"\0" + target_digest + b"\n"
            else:
                raise ProvenanceError
            digest.update(record)
    except (OSError, UnicodeError) as error:
        raise ProvenanceError from error
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    path = regular_file(path)
    try:
        raw = path.read_bytes()
        if not raw or len(raw) > MAX_JSON_BYTES or b"\x00" in raw:
            raise ProvenanceError
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProvenanceError from error
    if not isinstance(value, dict):
        raise ProvenanceError
    return value


def package_revision(root: Path, relative: str, expected: str) -> None:
    path = child_file(root, relative)
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        raise ProvenanceError from error
    matches = [line for line in lines if line.startswith("Pkg.Revision=")]
    if matches != [f"Pkg.Revision={expected}"]:
        raise ProvenanceError


def public_tool_policy(policy_path: Path = REVIEWED_POLICY) -> dict[str, Any]:
    policy = load_json(policy_path)
    try:
        value = exact(
            policy["publicInspectionTools"],
            {
                "platform",
                "buildToolsRevision",
                "commandLineToolsRevision",
                "tools",
                "runtimeTrees",
            },
        )
        tools = exact(value["tools"], {"aapt", "apkanalyzer", "apksigner"})
        result = {
            name: exact(record, {"path", "sha256"}) for name, record in tools.items()
        }
        runtime_trees = exact(
            value["runtimeTrees"],
            {"androidBuildTools", "androidCommandLineTools", "javaBinaries", "javaLibraries"},
        )
        tree_records = {
            name: exact(record, {"root", "path", "sha256"})
            for name, record in runtime_trees.items()
        }
    except (KeyError, TypeError) as error:
        raise ProvenanceError from error
    if value["platform"] != f"{sys.platform}-{platform.machine()}":
        raise ProvenanceError
    for record in result.values():
        strict_string(record["path"])
        if SHA256.fullmatch(strict_string(record["sha256"])) is None:
            raise ProvenanceError
    expected_roots = {
        "androidBuildTools": "android-sdk",
        "androidCommandLineTools": "android-sdk",
        "javaBinaries": "jdk",
        "javaLibraries": "jdk",
    }
    for name, record in tree_records.items():
        if record["root"] != expected_roots[name]:
            raise ProvenanceError
        strict_string(record["path"])
        if SHA256.fullmatch(strict_string(record["sha256"])) is None:
            raise ProvenanceError
    return value


def resolve_toolchain(
    manifest_path: Path,
    asset_directory: Path,
    policy_path: Path = REVIEWED_POLICY,
) -> dict[str, Path]:
    anchored = public_tool_policy(policy_path)
    tool_paths = {name: record["path"] for name, record in anchored["tools"].items()}
    manifest_file = regular_file(manifest_path)
    assets = directory(asset_directory)
    if is_within(manifest_file, assets):
        raise ProvenanceError
    manifest = exact(
        load_json(manifest_file),
        {
            "schema",
            "root",
            "javaRoot",
            "buildToolsRevision",
            "commandLineToolsRevision",
            "tools",
            "runtimeTrees",
        },
    )
    if (
        manifest["schema"] != 1
        or manifest["buildToolsRevision"] != anchored["buildToolsRevision"]
        or manifest["commandLineToolsRevision"] != anchored["commandLineToolsRevision"]
        or manifest["tools"] != anchored["tools"]
        or manifest["runtimeTrees"] != anchored["runtimeTrees"]
    ):
        raise ProvenanceError
    raw_root = Path(strict_string(manifest["root"]))
    raw_java_root = Path(strict_string(manifest["javaRoot"]))
    if not raw_root.is_absolute() or not raw_java_root.is_absolute():
        raise ProvenanceError
    root = directory(raw_root)
    java_root = directory(raw_java_root)
    if is_within(root, assets) or is_within(assets, root):
        raise ProvenanceError
    if is_within(java_root, assets) or is_within(assets, java_root):
        raise ProvenanceError
    package_revision(
        root,
        f"build-tools/{anchored['buildToolsRevision']}/source.properties",
        anchored["buildToolsRevision"],
    )
    package_revision(
        root,
        str(PurePosixPath(tool_paths["apkanalyzer"]).parents[1] / "source.properties"),
        anchored["commandLineToolsRevision"],
    )
    tools = exact(manifest["tools"], set(tool_paths))
    resolved: dict[str, Path] = {}
    for name, relative in tool_paths.items():
        entry = exact(tools[name], {"path", "sha256"})
        if entry["path"] != relative or SHA256.fullmatch(strict_string(entry["sha256"])) is None:
            raise ProvenanceError
        tool = child_file(root, relative, executable=True)
        if sha256_file(tool) != entry["sha256"]:
            raise ProvenanceError
        resolved[name] = tool
    roots = {"android-sdk": root, "jdk": java_root}
    for record in anchored["runtimeTrees"].values():
        runtime = child_directory(roots[record["root"]], record["path"])
        if sha256_tree(runtime) != record["sha256"]:
            raise ProvenanceError
    child_file(java_root, "bin/java", executable=True)
    resolved["javaHome"] = java_root
    return resolved


def canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def read_archive_json(archive: tarfile.TarFile, name: str) -> tuple[dict[str, Any], bytes]:
    try:
        member = archive.getmember(name)
    except KeyError as error:
        raise ProvenanceError from error
    if not member.isfile() or member.size <= 0 or member.size > MAX_JSON_BYTES:
        raise ProvenanceError
    stream = archive.extractfile(member)
    if stream is None:
        raise ProvenanceError
    raw = stream.read(member.size + 1)
    if len(raw) != member.size or b"\x00" in raw:
        raise ProvenanceError
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ProvenanceError from error
    if not isinstance(value, dict) or canonical(value) != raw:
        raise ProvenanceError
    return value, raw


def validate_provenance(
    archive_path: Path,
    asset_directory: Path,
    expected_path: Path,
    signer: str,
    trusted_toolchain: Path,
    source_root: Path,
    tool_policy: Path = REVIEWED_POLICY,
    inspection_log: Path | None = None,
) -> None:
    assets = directory(asset_directory)
    archive_file = regular_file(archive_path)
    if archive_file != regular_file(assets / "hermes-console-release-evidence.tar.gz"):
        raise ProvenanceError
    expected_file = regular_file(expected_path)
    if is_within(expected_file, assets) or SHA256.fullmatch(signer) is None:
        raise ProvenanceError
    validate_evidence_archive.validate(archive_file)
    tools = resolve_toolchain(trusted_toolchain, assets, tool_policy)
    expected = inspector.expected_facts(expected_file)
    artifacts = [regular_file(assets / name) for name in public_build_binding.PUBLIC_APKS]
    try:
        source, inputs = build_binding.source_and_inputs(source_root)
    except build_binding.BindingError as error:
        raise ProvenanceError from error
    with tarfile.open(archive_file, mode="r:gz") as archive:
        rebuild, _ = read_archive_json(
            archive, "release-evidence/rebuild-comparison.json"
        )
        try:
            rebuild_artifacts = {
                exact(item, {"name", "byteIdentical", "firstSha256", "secondSha256"})[
                    "name"
                ]: item
                for item in rebuild["artifacts"]
            }
        except (KeyError, TypeError) as error:
            raise ProvenanceError from error
        if set(rebuild_artifacts) != set(public_build_binding.PUBLIC_APKS):
            raise ProvenanceError
        for name, abi in public_build_binding.PUBLIC_APKS.items():
            artifact = regular_file(assets / name)
            artifact_sha256 = inspector.sha256_file(artifact)
            rebuild_artifact = rebuild_artifacts[name]
            if (
                rebuild_artifact["byteIdentical"] is not True
                or rebuild_artifact["firstSha256"] != artifact_sha256
                or rebuild_artifact["secondSha256"] != artifact_sha256
            ):
                raise ProvenanceError
            prefix = f"release-evidence/artifacts/full/{Path(name).stem}"
            archived_facts, facts_bytes = read_archive_json(
                archive, f"{prefix}/public-apk-facts.json"
            )
            try:
                environment = {
                    "HOME": "/nonexistent",
                    "JAVA_HOME": str(tools["javaHome"]),
                    "LANG": "C.UTF-8",
                    "LC_ALL": "C.UTF-8",
                    "PATH": "/usr/bin:/bin",
                }
                if inspection_log is not None:
                    environment["INSPECTION_LOG"] = str(inspection_log)
                fresh = inspector.inspect(
                    artifact,
                    expected,
                    name,
                    abi,
                    signer,
                    tools["aapt"],
                    tools["apkanalyzer"],
                    tools["apksigner"],
                    environment=environment,
                )
            except (inspector.InspectionError, OSError, ValueError) as error:
                raise ProvenanceError from error
            if set(archived_facts) != inspector.FACT_KEYS or inspector.canonical(fresh) != facts_bytes:
                raise ProvenanceError
            try:
                review, _ = read_archive_json(
                    archive, f"{prefix}/fullRelease.license-review.json"
                )
                sbom, _ = read_archive_json(archive, f"{prefix}/fullRelease.cdx.json")
                source_assets, _ = read_archive_json(
                    archive, f"{prefix}/source-assets.json"
                )
                artifact_inventory, _ = read_archive_json(
                    archive, f"{prefix}/fullRelease.artifact.json"
                )
                verify_license_reviews.validate_documents(
                    review,
                    sbom,
                    source_assets,
                    artifact_inventory,
                    expected_fingerprint=inputs["buildInputsSha256"],
                    expected_commit=source["commit"],
                    artifact_name=name,
                    artifact_sha256=inspector.sha256_file(artifact),
                )
            except (KeyError, verify_license_reviews.LicenseError) as error:
                raise ProvenanceError from error



def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-toolchain", action="store_true")
    parser.add_argument("--trusted-toolchain", type=Path, required=True)
    parser.add_argument("--asset-directory", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    try:
        if args.check_toolchain:
            if args.archive is not None:
                raise ProvenanceError
            resolve_toolchain(args.trusted_toolchain, args.asset_directory)
            message = "Trusted Android toolchain validation passed."
        else:
            if args.archive is None:
                raise ProvenanceError
            signer = inspector.reviewed_signer(REVIEWED_POLICY)
            with tempfile.TemporaryDirectory(prefix="hermes-public-expectations-") as temporary:
                expected = Path(temporary) / "full-release-expectations.json"
                result = subprocess.run(
                    [
                        sys.executable,
                        str(REVIEWED_ROOT / "tool/release/write_full_expectations.py"),
                        "--pubspec",
                        str(REVIEWED_ROOT / "pubspec.yaml"),
                        "--gradle",
                        str(REVIEWED_ROOT / "android/app/build.gradle.kts"),
                        "--manifest",
                        str(REVIEWED_ROOT / "android/app/src/main/AndroidManifest.xml"),
                        "--policy",
                        str(REVIEWED_EXPECTATIONS_POLICY),
                        "--output",
                        str(expected),
                    ],
                    check=False,
                    capture_output=True,
                    timeout=30,
                )
                if result.returncode != 0:
                    raise ProvenanceError
                validate_provenance(
                    args.archive,
                    args.asset_directory,
                    expected,
                    signer,
                    args.trusted_toolchain,
                    REVIEWED_ROOT,
                )
            message = "Public APK provenance validation passed."
    except (OSError, ProvenanceError, subprocess.TimeoutExpired, tarfile.TarError):
        print("ERROR: public APK provenance validation failed.", file=sys.stderr)
        return 1
    print(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
