#!/usr/bin/env python3
"""Emit and validate the canonical manifest for one completed double build.

This is a local causal binding: it records exactly what this orchestrator emitted.
It is not a cryptographic provenance or an attestation boundary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import stat
import sys
from pathlib import Path
from typing import Any

import play_build_binding as source_binding

SHA256 = re.compile(r"^[0-9a-f]{64}$")
PUBLIC_APKS = (
    "app-arm64-v8a-full-release.apk",
    "app-armeabi-v7a-full-release.apk",
    "app-x86_64-full-release.apk",
)
PLAY_AAB = "app-play-release.aab"
TOOL_NAMES = ("flutter", "git", "python3", "java", "sha256sum", "install", "mktemp", "mv")
BUILD_COMMANDS = {
    "direct-public": (
        "flutter build apk --release --flavor full --split-per-abi "
        "--dart-define=HERMES_FLAVOR=full --dart-define=HERMES_LOCAL_AGENT=true"
    ),
    "play-private": (
        "flutter build appbundle --release --flavor play "
        "--dart-define=HERMES_FLAVOR=play --dart-define=HERMES_LOCAL_AGENT=false"
    ),
}
MAX_JSON_BYTES = 2 * 1024 * 1024


class ManifestError(ValueError):
    pass


def canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def exact(value: Any, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ManifestError
    return value


def regular_file(path: Path) -> Path:
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise ManifestError
        result = path.resolve(strict=True)
    except OSError as error:
        raise ManifestError from error
    if not result.is_file() or result.stat().st_size <= 0:
        raise ManifestError
    return result


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with regular_file(path).open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise ManifestError from error
    return digest.hexdigest()


def artifact_record(path: Path, expected_name: str) -> dict[str, Any]:
    artifact = regular_file(path)
    if path.name != expected_name:
        raise ManifestError
    return {
        "name": expected_name,
        "size": artifact.stat().st_size,
        "sha256": sha256_file(artifact),
    }


def expected_artifact_names(channel: str) -> tuple[str, ...]:
    if channel == "direct-public":
        return PUBLIC_APKS
    if channel == "play-private":
        return (PLAY_AAB,)
    raise ManifestError


def replica_records(path: Path, channel: str) -> list[dict[str, Any]]:
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise ManifestError
        root = path.resolve(strict=True)
        entries = list(root.iterdir())
    except OSError as error:
        raise ManifestError from error
    names = expected_artifact_names(channel)
    if not root.is_dir() or {entry.name for entry in entries} != set(names):
        raise ManifestError
    return [artifact_record(root / name, name) for name in names]


def host_platform() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if machine == "amd64":
        machine = "x86_64"
    return f"{system}-{machine}"


def tool_record(path: Path) -> dict[str, str]:
    try:
        executable = path.resolve(strict=True)
    except OSError as error:
        raise ManifestError from error
    if not executable.is_file() or not executable.is_absolute() or not os.access(executable, os.X_OK):
        raise ManifestError
    return {"path": str(executable), "sha256": sha256_file(executable)}


def parse_tools(values: list[str]) -> dict[str, Path]:
    tools: dict[str, Path] = {}
    for value in values:
        name, separator, raw_path = value.partition("=")
        if not separator or name not in TOOL_NAMES or name in tools or not raw_path:
            raise ManifestError
        tools[name] = Path(raw_path)
    if set(tools) != set(TOOL_NAMES):
        raise ManifestError
    return tools


def parse_tool_hashes(values: list[str]) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for value in values:
        name, separator, digest = value.partition("=")
        if (
            not separator
            or name not in TOOL_NAMES
            or name in hashes
            or SHA256.fullmatch(digest) is None
        ):
            raise ManifestError
        hashes[name] = digest
    if set(hashes) != set(TOOL_NAMES):
        raise ManifestError
    return hashes


def validate_comparison(
    channel: str,
    report: dict[str, Any],
    replicas: dict[str, dict[str, list[dict[str, Any]]]],
) -> None:
    if report.get("schema") != 1 or report.get("channel") != channel or report.get("gatePassed") is not True:
        raise ManifestError
    left = replicas["a"]["artifacts"]
    right = replicas["b"]["artifacts"]
    if channel == "direct-public":
        if report.get("observedTwoBuildByteIdentity") is not True:
            raise ManifestError
        expected = [
            {
                "name": first["name"],
                "byteIdentical": True,
                "firstSha256": first["sha256"],
                "secondSha256": second["sha256"],
            }
            for first, second in zip(left, right, strict=True)
        ]
        if report.get("artifacts") != expected:
            raise ManifestError
    else:
        expected = [
            {key: record[key] for key in ("name", "size", "sha256")}
            for record in (left[0], right[0])
        ]
        if report.get("functionalPayloadEquivalent") is not True or report.get("artifacts") != expected:
            raise ManifestError


def create(
    root: Path,
    channel: str,
    first: Path,
    second: Path,
    comparison: Path,
    expected_signer_sha256: str,
    environment: dict[str, str],
    tools: dict[str, Path],
    expected_tool_hashes: dict[str, str],
) -> dict[str, Any]:
    if channel not in BUILD_COMMANDS or SHA256.fullmatch(expected_signer_sha256) is None:
        raise ManifestError
    if (
        set(environment) != {"ANDROID_HOME", "ANDROID_SDK_ROOT", "JAVA_HOME"}
        or any(not isinstance(value, str) for value in environment.values())
        or not environment["JAVA_HOME"]
        or not (environment["ANDROID_HOME"] or environment["ANDROID_SDK_ROOT"])
    ):
        raise ManifestError
    if (
        set(tools) != set(TOOL_NAMES)
        or set(expected_tool_hashes) != set(TOOL_NAMES)
    ):
        raise ManifestError
    try:
        source, inputs = source_binding.source_and_inputs(root)
    except source_binding.BindingError as error:
        raise ManifestError from error
    replicas = {
        "a": {"artifacts": replica_records(first, channel)},
        "b": {"artifacts": replica_records(second, channel)},
    }
    comparison_file = regular_file(comparison)
    report = load_json(comparison_file)
    validate_comparison(channel, report, replicas)
    toolchain = {
        "platform": host_platform(),
        "environment": environment,
        "executables": {
            name: tool_record(tools[name]) for name in sorted(TOOL_NAMES)
        },
    }
    if {
        name: record["sha256"]
        for name, record in toolchain["executables"].items()
    } != expected_tool_hashes:
        raise ManifestError
    return {
        "schema": 1,
        "kind": "hermes-double-build-output",
        "channel": channel,
        "source": source,
        "inputs": inputs,
        "build": {
            "command": BUILD_COMMANDS[channel],
            "expectedSignerSha256": expected_signer_sha256,
        },
        "toolchain": toolchain,
        "replicas": replicas,
        "comparison": {
            "name": "rebuild-comparison.json",
            "sha256": sha256_file(comparison_file),
        },
    }


def validate_schema(value: dict[str, Any]) -> None:
    exact(
        value,
        {
            "schema", "kind", "channel", "source", "inputs", "build",
            "toolchain", "replicas", "comparison",
        },
    )
    channel = value["channel"]
    if value["schema"] != 1 or value["kind"] != "hermes-double-build-output" or channel not in BUILD_COMMANDS:
        raise ManifestError
    exact(value["source"], {"commit", "treeObject", "archiveSha256", "submoduleStateSha256"})
    exact(value["inputs"], {"pubspecLockSha256", "buildInputsSha256", "buildFiles"})
    build = exact(value["build"], {"command", "expectedSignerSha256"})
    if build["command"] != BUILD_COMMANDS[channel] or not isinstance(build["expectedSignerSha256"], str) or SHA256.fullmatch(build["expectedSignerSha256"]) is None:
        raise ManifestError
    for key in ("archiveSha256", "submoduleStateSha256"):
        if not isinstance(value["source"][key], str) or SHA256.fullmatch(value["source"][key]) is None:
            raise ManifestError
    for key in ("pubspecLockSha256", "buildInputsSha256"):
        if not isinstance(value["inputs"][key], str) or SHA256.fullmatch(value["inputs"][key]) is None:
            raise ManifestError
    if not isinstance(value["inputs"]["buildFiles"], list) or not all(
        isinstance(item, str) and item for item in value["inputs"]["buildFiles"]
    ):
        raise ManifestError
    toolchain = exact(value["toolchain"], {"platform", "environment", "executables"})
    if not isinstance(toolchain["platform"], str) or not toolchain["platform"]:
        raise ManifestError
    environment = exact(toolchain["environment"], {"ANDROID_HOME", "ANDROID_SDK_ROOT", "JAVA_HOME"})
    if (
        any(not isinstance(item, str) for item in environment.values())
        or not environment["JAVA_HOME"]
        or not (environment["ANDROID_HOME"] or environment["ANDROID_SDK_ROOT"])
    ):
        raise ManifestError
    executables = exact(toolchain["executables"], set(TOOL_NAMES))
    for record in executables.values():
        record = exact(record, {"path", "sha256"})
        if not isinstance(record["path"], str) or not Path(record["path"]).is_absolute() or not isinstance(record["sha256"], str) or SHA256.fullmatch(record["sha256"]) is None:
            raise ManifestError
    replicas = exact(value["replicas"], {"a", "b"})
    expected_names = expected_artifact_names(channel)
    for replica in ("a", "b"):
        records = exact(replicas[replica], {"artifacts"})["artifacts"]
        if not isinstance(records, list) or len(records) != len(expected_names):
            raise ManifestError
        for expected_name, record in zip(expected_names, records, strict=True):
            record = exact(record, {"name", "size", "sha256"})
            if record["name"] != expected_name or not isinstance(record["size"], int) or record["size"] <= 0 or not isinstance(record["sha256"], str) or SHA256.fullmatch(record["sha256"]) is None:
                raise ManifestError
    comparison = exact(value["comparison"], {"name", "sha256"})
    if comparison["name"] != "rebuild-comparison.json" or not isinstance(comparison["sha256"], str) or SHA256.fullmatch(comparison["sha256"]) is None:
        raise ManifestError


def load_json(path: Path) -> dict[str, Any]:
    file_path = regular_file(path)
    try:
        raw = file_path.read_bytes()
        if len(raw) > MAX_JSON_BYTES or b"\x00" in raw:
            raise ManifestError
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError from error
    if not isinstance(value, dict) or canonical(value) != raw:
        raise ManifestError
    return value


def load(path: Path) -> dict[str, Any]:
    value = load_json(path)
    validate_schema(value)
    return value


def validate_output(
    manifest_path: Path,
    root: Path,
    expected_channel: str,
    expected_signer_sha256: str | None = None,
) -> dict[str, Any]:
    manifest_file = regular_file(manifest_path)
    if manifest_file.name != "double-build-manifest.json":
        raise ManifestError
    output_root = manifest_file.parent
    manifest = load(manifest_file)
    if manifest["channel"] != expected_channel:
        raise ManifestError
    if expected_signer_sha256 is not None and manifest["build"]["expectedSignerSha256"] != expected_signer_sha256:
        raise ManifestError
    try:
        source, inputs = source_binding.source_and_inputs(root)
    except source_binding.BindingError as error:
        raise ManifestError from error
    if manifest["source"] != source or manifest["inputs"] != inputs:
        raise ManifestError
    actual_replicas = {
        replica: {"artifacts": replica_records(output_root / f"replica-{replica}", expected_channel)}
        for replica in ("a", "b")
    }
    if manifest["replicas"] != actual_replicas:
        raise ManifestError
    comparison_path = output_root / "rebuild-comparison.json"
    if manifest["comparison"]["sha256"] != sha256_file(comparison_path):
        raise ManifestError
    report = load_json(comparison_path)
    validate_comparison(expected_channel, report, actual_replicas)
    for record in manifest["toolchain"]["executables"].values():
        path = Path(record["path"])
        if sha256_file(path) != record["sha256"] or not os.access(path, os.X_OK):
            raise ManifestError
    expected_top_level = {
        "replica-a", "replica-b", "rebuild-comparison.json", "double-build-manifest.json"
    }
    try:
        if {entry.name for entry in output_root.iterdir()} != expected_top_level:
            raise ManifestError
    except OSError as error:
        raise ManifestError from error
    return manifest


def validate_embedded(
    manifest: dict[str, Any],
    root: Path,
    expected_channel: str,
    selected_artifacts: list[Path],
    comparison: dict[str, Any],
) -> None:
    """Validate archived build facts without claiming external provenance."""
    validate_schema(manifest)
    if manifest["channel"] != expected_channel:
        raise ManifestError
    try:
        source, inputs = source_binding.source_and_inputs(root)
    except source_binding.BindingError as error:
        raise ManifestError from error
    if manifest["source"] != source or manifest["inputs"] != inputs:
        raise ManifestError
    names = expected_artifact_names(expected_channel)
    if len(selected_artifacts) != len(names):
        raise ManifestError
    selected = [
        artifact_record(path, name)
        for path, name in zip(selected_artifacts, names, strict=True)
    ]
    if manifest["replicas"]["a"]["artifacts"] != selected:
        raise ManifestError
    if manifest["comparison"]["sha256"] != hashlib.sha256(
        canonical(comparison)
    ).hexdigest():
        raise ManifestError
    validate_comparison(expected_channel, comparison, manifest["replicas"])


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
        raise ManifestError from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("write", nargs="?")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--channel", choices=tuple(BUILD_COMMANDS), required=True)
    parser.add_argument("--first", type=Path, required=True)
    parser.add_argument("--second", type=Path, required=True)
    parser.add_argument("--comparison", type=Path, required=True)
    parser.add_argument("--expected-signer-sha256", required=True)
    parser.add_argument("--android-home", required=True)
    parser.add_argument("--android-sdk-root", required=True)
    parser.add_argument("--java-home", required=True)
    parser.add_argument("--tool", action="append", default=[])
    parser.add_argument("--expected-tool-sha", action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.write != "write":
            raise ManifestError
        value = create(
            args.root,
            args.channel,
            args.first,
            args.second,
            args.comparison,
            args.expected_signer_sha256.lower(),
            {
                "ANDROID_HOME": args.android_home,
                "ANDROID_SDK_ROOT": args.android_sdk_root,
                "JAVA_HOME": args.java_home,
            },
            parse_tools(args.tool),
            parse_tool_hashes(args.expected_tool_sha),
        )
        write_exclusive(args.output, value)
    except (ManifestError, source_binding.BindingError):
        print("ERROR: double-build output manifest failed.", file=sys.stderr)
        return 1
    print("Double-build output manifest written; no provenance or publication claimed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
