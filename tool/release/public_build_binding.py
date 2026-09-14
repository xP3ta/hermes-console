#!/usr/bin/env python3
"""Bind all three public APKs to one clean source and build-input snapshot."""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path
from typing import Any

import play_build_binding as binding
import double_build_manifest

PUBLIC_APKS = {
    "app-arm64-v8a-full-release.apk": "arm64-v8a",
    "app-armeabi-v7a-full-release.apk": "armeabi-v7a",
    "app-x86_64-full-release.apk": "x86_64",
}
BUILD_COMMAND = (
    "flutter build apk --release --flavor full --split-per-abi "
    "--dart-define=HERMES_FLAVOR=full --dart-define=HERMES_LOCAL_AGENT=true"
)


def artifact_entry(path: Path) -> dict[str, Any]:
    try:
        if path.is_symlink():
            raise binding.BindingError
        artifact = path.resolve(strict=True)
    except OSError as error:
        raise binding.BindingError from error
    if artifact.name not in PUBLIC_APKS or not artifact.is_file() or artifact.stat().st_size <= 0:
        raise binding.BindingError
    return {
        "name": artifact.name,
        "abi": PUBLIC_APKS[artifact.name],
        "size": artifact.stat().st_size,
        "sha256": binding.sha256_file(artifact),
    }


def create_embedded(
    root: Path,
    artifacts: list[Path],
    manifest: dict[str, Any],
    manifest_bytes: bytes,
    comparison: dict[str, Any],
) -> dict[str, Any]:
    entries = sorted((artifact_entry(path) for path in artifacts), key=lambda item: item["name"])
    if {entry["name"] for entry in entries} != set(PUBLIC_APKS) or len(entries) != len(PUBLIC_APKS):
        raise binding.BindingError
    try:
        if double_build_manifest.canonical(manifest) != manifest_bytes:
            raise double_build_manifest.ManifestError
        ordered_artifacts = [
            next(path for path in artifacts if path.name == name) for name in PUBLIC_APKS
        ]
        double_build_manifest.validate_embedded(
            manifest, root, "direct-public", ordered_artifacts, comparison
        )
        emitted = sorted(
            manifest["replicas"]["a"]["artifacts"], key=lambda item: item["name"]
        )
    except (StopIteration, double_build_manifest.ManifestError, binding.BindingError) as error:
        raise binding.BindingError from error
    expected_entries = [
        {key: record[key] for key in ("name", "size", "sha256")}
        | {"abi": PUBLIC_APKS[record["name"]]}
        for record in emitted
    ]
    expected_entries.sort(key=lambda item: item["name"])
    if entries != expected_entries:
        raise binding.BindingError
    return {
        "schema": 2,
        "channel": "direct-public",
        "source": manifest["source"],
        "inputs": manifest["inputs"],
        "artifacts": entries,
        "buildCommand": BUILD_COMMAND,
        "doubleBuild": {
            "selectedReplica": "a",
            "manifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "manifest": manifest,
        },
    }


def create(
    root: Path, artifacts: list[Path], double_build_manifest_path: Path
) -> dict[str, Any]:
    try:
        manifest = double_build_manifest.validate_output(
            double_build_manifest_path, root, "direct-public"
        )
        manifest_bytes = double_build_manifest.canonical(manifest)
        comparison = double_build_manifest.load_json(
            double_build_manifest_path.parent / "rebuild-comparison.json"
        )
        return create_embedded(
            root, artifacts, manifest, manifest_bytes, comparison
        )
    except (double_build_manifest.ManifestError, binding.BindingError) as error:
        raise binding.BindingError from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("write", "validate"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--artifact", action="append", type=Path, required=True)
    parser.add_argument("--double-build-manifest", type=Path, required=True)
    parser.add_argument("--binding", type=Path, required=True)
    args = parser.parse_args()
    try:
        expected = create(args.root, args.artifact, args.double_build_manifest)
        if args.action == "write":
            binding.write_exclusive(args.binding, expected)
        elif binding.load(args.binding) != expected:
            raise binding.BindingError
    except binding.BindingError:
        print("ERROR: public build binding validation failed.", file=sys.stderr)
        return 1
    print("Public build binding passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
