#!/usr/bin/env python3
"""Compare two independently built Android release outputs without overclaiming."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

PUBLIC_APKS = (
    "app-arm64-v8a-full-release.apk",
    "app-armeabi-v7a-full-release.apk",
    "app-x86_64-full-release.apk",
)
PLAY_AAB = "app-play-release.aab"
SIGNATURE_SUFFIXES = (".SF", ".RSA", ".DSA", ".EC")
MAX_ENTRIES = 100_000
MAX_UNCOMPRESSED = 2 * 1024 * 1024 * 1024


class ComparisonError(ValueError):
    pass


def regular_file(path: Path, *, expected_name: str | None = None) -> Path:
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise ComparisonError
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ComparisonError from error
    if not resolved.is_file() or resolved.stat().st_size <= 0:
        raise ComparisonError
    if expected_name is not None and path.name != expected_name:
        raise ComparisonError
    return resolved


def exact_directory(path: Path, names: tuple[str, ...]) -> dict[str, Path]:
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise ComparisonError
        root = path.resolve(strict=True)
        entries = list(root.iterdir())
    except OSError as error:
        raise ComparisonError from error
    if not root.is_dir() or {entry.name for entry in entries} != set(names):
        raise ComparisonError
    return {name: regular_file(root / name, expected_name=name) for name in names}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise ComparisonError from error
    return digest.hexdigest()


def is_signature_metadata(name: str) -> bool:
    upper = name.upper()
    if not upper.startswith("META-INF/"):
        return False
    basename = upper.rsplit("/", 1)[-1]
    return basename == "MANIFEST.MF" or basename.endswith(SIGNATURE_SUFFIXES)


def zip_facts(path: Path) -> dict[str, Any]:
    file_path = regular_file(path, expected_name=PLAY_AAB)
    try:
        with zipfile.ZipFile(file_path) as archive:
            infos = archive.infolist()
            if not infos or len(infos) > MAX_ENTRIES:
                raise ComparisonError
            entries: dict[str, str] = {}
            metadata = []
            seen_names: set[str] = set()
            total = 0
            for index, info in enumerate(infos):
                raw_name = info.filename
                name = PurePosixPath(raw_name.rstrip("/"))
                if (
                    not raw_name
                    or "\\" in raw_name
                    or name.is_absolute()
                    or "." in name.parts
                    or ".." in name.parts
                    or name.as_posix() != raw_name.rstrip("/")
                    or raw_name in seen_names
                    or info.flag_bits & 1
                    or stat.S_ISLNK(info.external_attr >> 16)
                    or info.file_size < 0
                ):
                    raise ComparisonError
                seen_names.add(raw_name)
                if info.is_dir():
                    continue
                total += info.file_size
                if total > MAX_UNCOMPRESSED:
                    raise ComparisonError
                digest = hashlib.sha256()
                measured_size = 0
                with archive.open(info, "r") as stream:
                    while block := stream.read(1024 * 1024):
                        measured_size += len(block)
                        if measured_size > info.file_size:
                            raise ComparisonError
                        digest.update(block)
                if measured_size != info.file_size:
                    raise ComparisonError
                entries[raw_name] = digest.hexdigest()
                metadata.append(
                    {
                        "name": raw_name,
                        "order": index,
                        "timestamp": list(info.date_time),
                        "compression": info.compress_type,
                        "externalAttributes": info.external_attr,
                        "extraSha256": hashlib.sha256(info.extra).hexdigest(),
                        "commentSha256": hashlib.sha256(info.comment).hexdigest(),
                    }
                )
            if (
                total <= 0
                or total > MAX_UNCOMPRESSED
                or "base/manifest/AndroidManifest.xml" not in entries
                or "BundleConfig.pb" not in entries
                or "META-INF/MANIFEST.MF" not in entries
                or not any(name.upper().endswith((".RSA", ".DSA", ".EC")) for name in entries)
            ):
                raise ComparisonError
    except (OSError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise ComparisonError from error
    functional = {
        name: digest for name, digest in entries.items() if not is_signature_metadata(name)
    }
    return {
        "name": path.name,
        "size": file_path.stat().st_size,
        "sha256": sha256_file(file_path),
        "entries": dict(sorted(entries.items())),
        "functionalEntries": dict(sorted(functional.items())),
        "zipMetadata": metadata,
    }


def compare_public(first: Path, second: Path) -> tuple[dict[str, Any], bool]:
    left = exact_directory(first, PUBLIC_APKS)
    right = exact_directory(second, PUBLIC_APKS)
    artifacts = []
    equal = True
    for name in PUBLIC_APKS:
        first_digest = sha256_file(left[name])
        second_digest = sha256_file(right[name])
        identical = first_digest == second_digest
        equal = equal and identical
        artifacts.append(
            {
                "name": name,
                "firstSha256": first_digest,
                "secondSha256": second_digest,
                "byteIdentical": identical,
            }
        )
    report = {
        "schema": 1,
        "channel": "direct-public",
        "acceptance": "all signed APK bytes must be identical",
        "gatePassed": equal,
        "inputsCryptographicallyPinned": False,
        "observedTwoBuildByteIdentity": equal,
        "byteReproducible": False,
        "zipEntryPayloadReproducible": None,
        "functionalPayloadEquivalent": equal,
        "differenceClass": "none" if equal else "signed-apk-bytes-differ",
        "claim": "observed-two-build-byte-identical" if equal else "observed-two-build-bytes-differ",
        "artifacts": artifacts,
    }
    return report, equal


def compare_play(first: Path, second: Path) -> tuple[dict[str, Any], bool]:
    left = zip_facts(first)
    right = zip_facts(second)
    byte_equal = left["sha256"] == right["sha256"]
    entry_equal = left["entries"] == right["entries"]
    functional_equal = left["functionalEntries"] == right["functionalEntries"]
    if byte_equal:
        difference = "none"
        claim = "observed-two-build-byte-identical"
    elif entry_equal:
        difference = "zip-container-metadata-only"
        claim = "observed-two-build-entry-payload-identical"
    elif functional_equal:
        difference = "signature-metadata-only"
        claim = "observed-two-build-functional-equivalence"
    else:
        difference = "functional-payload-difference"
        claim = "observed-two-build-functional-difference"
    report = {
        "schema": 1,
        "channel": "play-private",
        "acceptance": (
            "functional ZIP entry payloads must match; byte, ZIP-container, and "
            "signature-metadata equality are reported separately"
        ),
        "gatePassed": functional_equal,
        "inputsCryptographicallyPinned": False,
        "observedTwoBuildByteIdentity": byte_equal,
        "byteReproducible": False,
        "zipEntryPayloadReproducible": entry_equal,
        "functionalPayloadEquivalent": functional_equal,
        "differenceClass": difference,
        "claim": claim,
        "artifacts": [
            {key: left[key] for key in ("name", "size", "sha256")},
            {key: right[key] for key in ("name", "size", "sha256")},
        ],
    }
    return report, functional_equal


def write_exclusive(path: Path, value: dict[str, Any]) -> None:
    data = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
    except OSError as error:
        raise ComparisonError from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=("direct-public", "play-private"), required=True)
    parser.add_argument("--first", type=Path, required=True)
    parser.add_argument("--second", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.channel == "direct-public":
            report, passed = compare_public(args.first, args.second)
        else:
            report, passed = compare_play(args.first, args.second)
        write_exclusive(args.output, report)
    except ComparisonError:
        print("ERROR: rebuild comparison failed closed.", file=sys.stderr)
        return 1
    if not passed:
        print("ERROR: rebuilds are not equivalent under channel policy.", file=sys.stderr)
        return 1
    print(f"Rebuild comparison passed: {report['claim']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
