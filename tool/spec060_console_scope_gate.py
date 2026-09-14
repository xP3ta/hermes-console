#!/usr/bin/env python3
"""Verify the declared and discovered Spec 060 Console-only write-set."""

import argparse
import hashlib
import os
import re
import stat
import sys
from pathlib import Path, PurePosixPath


_SENSITIVE_NAMES = {
    ".env",
    "google-services.json",
    "key.properties",
}
_SENSITIVE_SUFFIXES = {".jks", ".keystore", ".p12", ".pfx", ".pem", ".key"}
_SENSITIVE_DATA_SUFFIXES = {
    "",
    ".conf",
    ".config",
    ".db",
    ".json",
    ".properties",
    ".sqlite",
    ".sqlite3",
    ".txt",
    ".yaml",
    ".yml",
}
_SENSITIVE_COMPONENTS = {".ssh", "credentials", "secrets"}
_SENSITIVE_WORD = re.compile(
    r"(?:^|[._-])(credential|credentials|password|secret|secrets|token|tokens)"
    r"(?:$|[._-])"
)
_SENSITIVE_STORE = re.compile(
    r"(?:^|[._-])(?:cookies?(?:[._-](?:store|storage))?"
    r"|session[._-](?:store|storage))(?:$|[._-])"
)


def _is_sensitive(relative: str) -> bool:
    path = PurePosixPath(relative)
    lowered = path.name.lower()
    suffix = path.suffix.lower()
    components = {part.lower() for part in path.parts}
    if lowered == ".env" or lowered.startswith(".env.") or suffix == ".env":
        return True
    if lowered in _SENSITIVE_NAMES or suffix in _SENSITIVE_SUFFIXES:
        return True
    if components & _SENSITIVE_COMPONENTS:
        return True
    data_named = _SENSITIVE_WORD.search(lowered) or _SENSITIVE_STORE.search(lowered)
    return data_named is not None and suffix in _SENSITIVE_DATA_SUFFIXES


def _file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _inventory(
    root: Path,
    explicitly_sensitive: set[str],
) -> tuple[dict[str, tuple[object, ...]], list[str]]:
    entries: dict[str, tuple[object, ...]] = {}
    sensitive: list[str] = []
    for directory, names, files in os.walk(root, followlinks=False):
        names.sort()
        files.sort()
        parent = Path(directory)
        entry_names = [*names, *files]
        names[:] = [
            name
            for name in names
            if not (
                (parent / name).relative_to(root).as_posix()
                in explicitly_sensitive
                or _is_sensitive((parent / name).relative_to(root).as_posix())
            )
        ]
        # os.walk lists symlinked directories in names without traversing them.
        for name in entry_names:
            path = parent / name
            relative = path.relative_to(root).as_posix()
            metadata = path.lstat()
            mode = stat.S_IMODE(metadata.st_mode)
            if relative in explicitly_sensitive or _is_sensitive(relative):
                sensitive.append(relative)
                # Never open, resolve, or follow a potentially secret file.
                if stat.S_ISLNK(metadata.st_mode):
                    kind = "symlink"
                elif stat.S_ISDIR(metadata.st_mode):
                    kind = "dir"
                elif stat.S_ISREG(metadata.st_mode):
                    kind = "file"
                else:
                    kind = "special"
                entries[relative] = ("sensitive", kind, mode)
            elif stat.S_ISLNK(metadata.st_mode):
                entries[relative] = ("symlink", mode, os.readlink(path))
            elif stat.S_ISDIR(metadata.st_mode):
                entries[relative] = ("dir", mode)
            elif stat.S_ISREG(metadata.st_mode):
                entries[relative] = (
                    "file",
                    mode,
                    metadata.st_size,
                    _file_digest(path),
                )
            else:
                entries[relative] = (
                    "special",
                    stat.S_IFMT(metadata.st_mode),
                    mode,
                )
    return entries, sensitive


def _declared_relative(
    root: Path,
    raw_path: Path,
    *,
    resolve_links: bool,
) -> tuple[str | None, str | None]:
    candidate = raw_path if raw_path.is_absolute() else root / raw_path
    checked = (
        candidate.resolve(strict=False)
        if resolve_links
        else Path(os.path.abspath(candidate))
    )
    if checked != root and root not in checked.parents:
        return None, str(raw_path)
    try:
        relative = checked.relative_to(root).as_posix()
    except ValueError:
        return None, str(raw_path)
    if relative == ".":
        return None, str(raw_path)
    return relative, None


def _discover_write_set(
    base: Path,
    candidate: Path,
    explicitly_sensitive: set[str],
) -> tuple[set[str], list[str]]:
    baseline, baseline_sensitive = _inventory(base, explicitly_sensitive)
    current, current_sensitive = _inventory(candidate, explicitly_sensitive)
    sensitive = sorted(set(baseline_sensitive + current_sensitive))
    discovered = {
        relative
        for relative in baseline.keys() | current.keys()
        if baseline.get(relative) != current.get(relative)
    }
    return discovered, sensitive


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--sensitive-path", action="append", default=[], type=Path)
    parser.add_argument("paths", nargs="*", type=Path)
    arguments = parser.parse_args()

    root = arguments.root.resolve(strict=True)
    compare_mode = arguments.base is not None or arguments.candidate is not None
    declared: set[str] = set()
    escaped: list[str] = []
    for raw_path in arguments.paths:
        relative, error = _declared_relative(
            root,
            raw_path,
            resolve_links=not compare_mode,
        )
        if error is not None:
            escaped.append(error)
        elif relative is not None:
            declared.add(relative)

    if escaped:
        print(
            "Spec 060 write-set escapes Hermes Console: " + ", ".join(escaped),
            file=sys.stderr,
        )
        return 1

    if (arguments.base is None) != (arguments.candidate is None):
        parser.error("--base and --candidate must be provided together")

    explicitly_sensitive: set[str] = set()
    for raw_path in arguments.sensitive_path:
        relative, error = _declared_relative(root, raw_path, resolve_links=False)
        if error is not None or relative is None:
            print(
                "Spec 060 sensitive path escapes Hermes Console: " + str(raw_path),
                file=sys.stderr,
            )
            return 1
        explicitly_sensitive.add(relative)

    if arguments.base is None:
        if not arguments.paths:
            parser.error("declare at least one path, or pass --base/--candidate")
        print(f"Spec 060 Console-only write-set: {len(declared)} path(s)")
        return 0

    base = arguments.base.resolve(strict=True)
    candidate = arguments.candidate.resolve(strict=True)
    if candidate != root:
        print("Spec 060 candidate must equal the Console root", file=sys.stderr)
        return 1

    try:
        discovered, sensitive = _discover_write_set(
            base,
            candidate,
            explicitly_sensitive,
        )
    except OSError as error:
        print(
            "Spec 060 gate could not inspect non-sensitive tree metadata/content: "
            f"{error.__class__.__name__}",
            file=sys.stderr,
        )
        return 1
    if sensitive:
        print(
            "Spec 060 gate refuses to read secret-bearing paths: "
            + ", ".join(sensitive),
            file=sys.stderr,
        )
        return 1

    symlink_escapes: list[str] = []
    for relative in sorted(discovered):
        path = candidate / relative
        if path.is_symlink():
            resolved = path.resolve(strict=False)
            if resolved != root and root not in resolved.parents:
                symlink_escapes.append(relative)
    if symlink_escapes:
        print(
            "Spec 060 discovered symlink escape: " + ", ".join(symlink_escapes),
            file=sys.stderr,
        )
        return 1

    missing = sorted(discovered - declared)
    extra = sorted(declared - discovered)
    if missing or extra:
        details: list[str] = []
        if missing:
            details.append("missing=" + ",".join(missing))
        if extra:
            details.append("extra=" + ",".join(extra))
        print(
            "Spec 060 declared write-set does not match discovered write-set: "
            + "; ".join(details),
            file=sys.stderr,
        )
        return 1

    print(
        "Spec 060 Console-only discovered write-set: "
        f"{len(discovered)} path(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
