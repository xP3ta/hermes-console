#!/usr/bin/env python3
"""Create or validate a fail-closed source-to-Play-AAB build binding."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

SHA256 = re.compile(r"^[0-9a-f]{64}$")
GIT_ID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
MAX_OUTPUT = 4 * 1024 * 1024
MAX_AAB_ENTRIES = 10_000
MAX_AAB_MEMBER_BYTES = 256 * 1024 * 1024
MAX_AAB_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
MAX_AAB_SIGNATURE_BYTES = 8 * 1024 * 1024
ZIP_READ_CHUNK_BYTES = 1024 * 1024
GIT_CONTEXT_VARIABLES = (
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_DIR",
    "GIT_WORK_TREE",
)
BUILD_COMMAND = (
    "flutter build appbundle --release --flavor play "
    "--dart-define=HERMES_FLAVOR=play --dart-define=HERMES_LOCAL_AGENT=false"
)


class BindingError(ValueError):
    pass


def git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for variable in GIT_CONTEXT_VARIABLES:
        environment.pop(variable, None)
    return environment


def run(root: Path, *arguments: str, binary: bool = False) -> bytes:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=False,
            capture_output=True,
            timeout=60,
            env=git_environment(),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BindingError from error
    if result.returncode != 0 or len(result.stdout) + len(result.stderr) > MAX_OUTPUT:
        raise BindingError
    if not binary and b"\x00" in result.stdout:
        raise BindingError
    return result.stdout


def repo_root(path: Path) -> Path:
    try:
        root = path.resolve(strict=True)
    except OSError as error:
        raise BindingError from error
    if not root.is_dir() or Path(run(root, "rev-parse", "--show-toplevel").decode().strip()).resolve() != root:
        raise BindingError
    return root


def sha256_file(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise BindingError
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise BindingError from error
    return digest.hexdigest()


def zip_member_sha256(
    archive: zipfile.ZipFile, info: zipfile.ZipInfo
) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with archive.open(info, "r") as stream:
        while block := stream.read(
            min(ZIP_READ_CHUNK_BYTES, info.file_size - size + 1)
        ):
            size += len(block)
            if size > info.file_size or size > MAX_AAB_SIGNATURE_BYTES:
                raise BindingError
            digest.update(block)
    return digest.hexdigest(), size


def clean_source(root: Path) -> None:
    if run(root, "status", "--porcelain=v1", "--untracked-files=all"):
        raise BindingError
    submodules = run(root, "submodule", "status", "--recursive").decode().splitlines()
    if any(not line.startswith(" ") for line in submodules):
        raise BindingError


def archive_sha256(root: Path) -> str:
    try:
        process = subprocess.Popen(
            ["git", "-C", str(root), "archive", "--format=tar", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=git_environment(),
        )
    except OSError as error:
        raise BindingError from error
    assert process.stdout is not None
    digest = hashlib.sha256()
    for block in iter(lambda: process.stdout.read(1024 * 1024), b""):
        digest.update(block)
    stderr = process.stderr.read(MAX_OUTPUT + 1) if process.stderr else b""
    try:
        returncode = process.wait(timeout=60)
    except subprocess.TimeoutExpired as error:
        process.kill()
        process.wait()
        raise BindingError from error
    if returncode != 0 or len(stderr) > MAX_OUTPUT:
        raise BindingError
    return digest.hexdigest()


def submodule_sha256(root: Path) -> str:
    output = run(root, "submodule", "status", "--recursive").decode()
    normalized = []
    for line in output.splitlines():
        match = re.fullmatch(r" ([0-9a-f]{40,64}) ([^ ]+)(?: .*)?", line)
        if match is None:
            raise BindingError
        normalized.append(f"{match.group(1)}\0{match.group(2)}\n")
    return hashlib.sha256("".join(normalized).encode()).hexdigest()


def tracked_build_files(root: Path) -> list[str]:
    entries = [
        value.decode("utf-8")
        for value in run(root, "ls-files", "-z", binary=True).split(b"\x00")
        if value
    ]
    selected = sorted(
        path
        for path in entries
        if path in {"pubspec.yaml", "pubspec.lock", ".gitmodules"}
        or path.startswith(("android/", "tool/sbom/"))
    )
    if "pubspec.yaml" not in selected or "pubspec.lock" not in selected or not any(
        path.startswith("android/") for path in selected
    ):
        raise BindingError
    for relative in selected:
        path = PurePosixPath(relative)
        if path.is_absolute() or "." in path.parts or ".." in path.parts:
            raise BindingError
    return selected


def file_set_sha256(root: Path, paths: list[str]) -> str:
    digest = hashlib.sha256()
    for relative in paths:
        candidate = root / relative
        if candidate.is_dir():
            continue
        digest.update(relative.encode("utf-8") + b"\0")
        digest.update(sha256_file(candidate).encode("ascii") + b"\n")
    return digest.hexdigest()


def source_and_inputs(root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    root = repo_root(root)
    clean_source(root)
    commit = run(root, "rev-parse", "HEAD").decode().strip()
    tree = run(root, "rev-parse", "HEAD^{tree}").decode().strip()
    if GIT_ID.fullmatch(commit) is None or GIT_ID.fullmatch(tree) is None:
        raise BindingError
    files = tracked_build_files(root)
    return (
        {
            "commit": commit,
            "treeObject": tree,
            "archiveSha256": archive_sha256(root),
            "submoduleStateSha256": submodule_sha256(root),
        },
        {
            "pubspecLockSha256": sha256_file(root / "pubspec.lock"),
            "buildInputsSha256": file_set_sha256(root, files),
            "buildFiles": files,
        },
    )


def artifact_facts(path: Path) -> dict[str, Any]:
    try:
        if path.is_symlink():
            raise BindingError
        artifact = path.resolve(strict=True)
    except OSError as error:
        raise BindingError from error
    if artifact.name != "app-play-release.aab" or not artifact.is_file() or artifact.stat().st_size <= 0:
        raise BindingError
    try:
        with zipfile.ZipFile(artifact) as archive:
            infos = archive.infolist()
            if not infos or len(infos) > MAX_AAB_ENTRIES:
                raise BindingError
            files: dict[str, zipfile.ZipInfo] = {}
            total = 0
            entries_digest = hashlib.sha256()
            for info in infos:
                name = info.filename
                normalized = PurePosixPath(name.rstrip("/"))
                mode = (info.external_attr >> 16) & 0o170000
                if (
                    not name
                    or "\\" in name
                    or normalized.is_absolute()
                    or "." in normalized.parts
                    or ".." in normalized.parts
                    or normalized.as_posix() != name.rstrip("/")
                    or mode == 0o120000
                    or info.flag_bits & 1
                    or info.file_size > MAX_AAB_MEMBER_BYTES
                ):
                    raise BindingError
                if info.is_dir():
                    continue
                if name in files:
                    raise BindingError
                files[name] = info
                total += info.file_size
                entries_digest.update(
                    f"{name}\0{info.file_size}\0{info.CRC:08x}\n".encode()
                )
            if (
                total <= 0
                or total > MAX_AAB_UNCOMPRESSED_BYTES
                or "base/manifest/AndroidManifest.xml" not in files
                or "BundleConfig.pb" not in files
                or "META-INF/MANIFEST.MF" not in files
            ):
                raise BindingError
            signature_infos = [
                info
                for name, info in files.items()
                if name.startswith("META-INF/")
                and Path(name).suffix.upper() in {".RSA", ".DSA", ".EC"}
            ]
            signature_sidecars = {
                Path(name).stem for name in files if name.startswith("META-INF/") and name.upper().endswith(".SF")
            }
            if (
                not signature_infos
                or any(info.file_size > MAX_AAB_SIGNATURE_BYTES for info in signature_infos)
                or any(Path(info.filename).stem not in signature_sidecars for info in signature_infos)
            ):
                raise BindingError
            signature_files = []
            for info in sorted(signature_infos, key=lambda item: item.filename):
                digest, size = zip_member_sha256(archive, info)
                if size == 0 or size != info.file_size:
                    raise BindingError
                signature_files.append(
                    {"path": info.filename, "sha256": digest}
                )
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise BindingError from error
    return {
        "name": artifact.name,
        "size": artifact.stat().st_size,
        "sha256": sha256_file(artifact),
        "zipEntryCount": len(files),
        "zipEntriesSha256": entries_digest.hexdigest(),
        "hasBaseManifest": True,
        "hasBundleConfig": True,
        "signatureFiles": signature_files,
    }


def create(
    root: Path, artifact: Path, double_build_manifest_path: Path
) -> dict[str, Any]:
    import double_build_manifest

    try:
        manifest = double_build_manifest.validate_output(
            double_build_manifest_path, root, "play-private"
        )
    except (double_build_manifest.ManifestError, BindingError) as error:
        raise BindingError from error
    facts = artifact_facts(artifact)
    emitted = manifest["replicas"]["a"]["artifacts"][0]
    if any(facts[key] != emitted[key] for key in ("name", "size", "sha256")):
        raise BindingError
    return {
        "schema": 2,
        "channel": "play-private",
        "artifact": facts,
        "source": manifest["source"],
        "inputs": manifest["inputs"],
        "buildCommand": BUILD_COMMAND,
        "doubleBuild": {
            "selectedReplica": "a",
            "manifestSha256": sha256_file(double_build_manifest_path),
            "manifest": manifest,
        },
    }


def canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_exclusive(path: Path, value: dict[str, Any]) -> None:
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        with os.fdopen(descriptor, "wb") as output:
            output.write(canonical(value))
        os.chmod(path, 0o600)
    except OSError as error:
        raise BindingError from error


def load(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise BindingError
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BindingError from error
    if not isinstance(value, dict) or canonical(value) != raw:
        raise BindingError
    return value


def validate(
    root: Path, artifact: Path, double_build_manifest_path: Path, binding: Path
) -> None:
    actual = load(binding)
    expected = create(root, artifact, double_build_manifest_path)
    if actual != expected:
        raise BindingError


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("write", "validate"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--double-build-manifest", type=Path, required=True)
    parser.add_argument("--binding", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == "write":
            write_exclusive(
                args.binding,
                create(args.root, args.artifact, args.double_build_manifest),
            )
        else:
            validate(
                args.root, args.artifact, args.double_build_manifest, args.binding
            )
    except BindingError:
        print("ERROR: Play build binding validation failed.", file=sys.stderr)
        return 1
    print("Play build binding passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
