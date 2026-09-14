#!/usr/bin/env python3
"""Create a canonical changed-publishable-path manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
from pathlib import Path, PurePosixPath
from typing import Any

EXCLUSIONS = (
    ".dart_tool/ (root generated runtime tree)",
    "build/ (root generated runtime tree)",
    ".flutter-plugins-dependencies",
    "android/local.properties",
    "any path component beginning .tmp",
)


def excluded(relative: PurePosixPath) -> bool:
    parts = relative.parts
    if not parts:
        return False
    return (
        parts[0] in {".dart_tool", "build"}
        or relative.as_posix() == ".flutter-plugins-dependencies"
        or relative.as_posix() == "android/local.properties"
        or any(part.startswith(".tmp") for part in parts)
    )


def payload(path: Path, mode: int) -> tuple[str, bytes]:
    if stat.S_ISLNK(mode):
        return "symlink", os.readlink(path).encode("utf-8", "surrogateescape")
    if stat.S_ISREG(mode):
        return "file", path.read_bytes()
    raise ValueError(f"unsupported publishable node type: {path}")


def inventory(root: Path) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}

    def visit(directory: Path, relative: PurePosixPath) -> None:
        for child in sorted(os.scandir(directory), key=lambda entry: entry.name):
            child_relative = relative / child.name
            if excluded(child_relative):
                continue
            child_path = Path(child.path)
            node_mode = child_path.lstat().st_mode
            if stat.S_ISDIR(node_mode):
                visit(child_path, child_relative)
                continue
            node_type, data = payload(child_path, node_mode)
            result[child_relative.as_posix()] = {
                "type": node_type,
                "mode": format(stat.S_IMODE(node_mode), "04o"),
                "sha256": hashlib.sha256(data).hexdigest(),
            }

    visit(root, PurePosixPath())
    return result


def generate(base: Path, candidate: Path) -> dict[str, Any]:
    baseline = inventory(base)
    current = inventory(candidate)
    entries: list[dict[str, Any]] = []
    for path in sorted(baseline.keys() | current.keys()):
        before = baseline.get(path)
        after = current.get(path)
        if before == after:
            continue
        change = "addition" if before is None else "removal" if after is None else "modification"
        entries.append(
            {
                "path": path,
                "change": change,
                "baseline": before,
                "candidate": after,
            }
        )
    canonical = b"".join(
        json.dumps(entry, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
        + b"\n"
        for entry in entries
    )
    counts = {
        kind: sum(entry["change"] == kind for entry in entries)
        for kind in ("addition", "modification", "removal")
    }
    return {
        "schema_version": 1,
        "algorithm": "SHA-256 of sorted compact-JSON entry lines, each terminated by LF",
        "baseline": str(base),
        "candidate": str(candidate),
        "exclusions": list(EXCLUSIONS),
        "counts": {"total": len(entries), **counts},
        "canonical_digest": hashlib.sha256(canonical).hexdigest(),
        "entries": entries,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("base", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    manifest = generate(args.base.resolve(), args.candidate.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"count={manifest['counts']['total']}")
    print(f"digest={manifest['canonical_digest']}")


if __name__ == "__main__":
    main()
