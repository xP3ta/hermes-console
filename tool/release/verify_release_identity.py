#!/usr/bin/env python3
"""Verify strict release tag, pubspec build, commit identity, and forge signature."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

TAG = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
VERSION_LINE = re.compile(
    r"^version:\s*((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\+((?:0|[1-9][0-9]*))\s*(?:#.*)?$"
)
GIT_ID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
VERIFICATION_KEYS = {"verified", "reason", "signature", "payload", "verified_at"}
VERIFICATION_RECORD_KEYS = {"authorLogin", "committerLogin", "verification"}
SOURCE_POLICY_KEYS = {"forge", "authorizedActors", "requireAuthorAndCommitter"}
LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
MAX_FILE_BYTES = 1024 * 1024


class IdentityError(ValueError):
    pass


def strict_string(value: Any) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        raise IdentityError
    return value


def pubspec_version(path: Path) -> tuple[str, int]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_FILE_BYTES:
        raise IdentityError
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise IdentityError from error
    matches = [VERSION_LINE.fullmatch(line) for line in lines]
    matches = [match for match in matches if match is not None]
    if len(matches) != 1:
        raise IdentityError
    return matches[0].group(1), int(matches[0].group(2))


def load_json(path: Path) -> Any:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_FILE_BYTES:
        raise IdentityError
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IdentityError from error


def authorized_actors(policy_path: Path) -> set[str]:
    value = load_json(policy_path)
    if not isinstance(value, dict) or value.get("schema") != 1:
        raise IdentityError
    source = value.get("sourceAuthorization")
    if not isinstance(source, dict) or set(source) != SOURCE_POLICY_KEYS:
        raise IdentityError
    actors = source["authorizedActors"]
    if (
        source["forge"] != "github.com"
        or source["requireAuthorAndCommitter"] is not True
        or not isinstance(actors, list)
        or not actors
        or any(not isinstance(actor, str) or LOGIN.fullmatch(actor) is None for actor in actors)
    ):
        raise IdentityError
    normalized = {actor.casefold() for actor in actors}
    if len(normalized) != len(actors):
        raise IdentityError
    return normalized


def verification(path: Path, policy_path: Path) -> dict[str, Any]:
    value = load_json(path)
    if not isinstance(value, dict) or set(value) != VERIFICATION_RECORD_KEYS:
        raise IdentityError
    author = strict_string(value["authorLogin"])
    committer = strict_string(value["committerLogin"])
    if LOGIN.fullmatch(author) is None or LOGIN.fullmatch(committer) is None:
        raise IdentityError
    allowed = authorized_actors(policy_path)
    if author.casefold() not in allowed or committer.casefold() not in allowed:
        raise IdentityError
    signature = value["verification"]
    if not isinstance(signature, dict) or set(signature) != VERIFICATION_KEYS:
        raise IdentityError
    if (
        signature["verified"] is not True
        or signature["reason"] != "valid"
        or not strict_string(signature["signature"])
        or not strict_string(signature["payload"])
        or not strict_string(signature["verified_at"])
    ):
        raise IdentityError
    return value


def validate(
    *,
    tag: str,
    pubspec: Path,
    build_number: str,
    expected_commit: str,
    checkout_commit: str,
    tag_commit: str,
    verification_json: Path,
    policy: Path,
) -> None:
    tag_match = TAG.fullmatch(tag)
    if tag_match is None or not build_number.isdecimal() or (
        len(build_number) > 1 and build_number.startswith("0")
    ):
        raise IdentityError
    version, build = pubspec_version(pubspec)
    commits = (expected_commit, checkout_commit, tag_commit)
    if (
        version != tag[1:]
        or build != int(build_number)
        or any(GIT_ID.fullmatch(value) is None for value in commits)
        or len(set(commits)) != 1
    ):
        raise IdentityError
    verification(verification_json, policy)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--pubspec", type=Path, required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--checkout-commit", required=True)
    parser.add_argument("--tag-commit", required=True)
    parser.add_argument("--verification-json", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    args = parser.parse_args()
    try:
        validate(
            tag=args.tag,
            pubspec=args.pubspec,
            build_number=args.build_number,
            expected_commit=args.expected_commit,
            checkout_commit=args.checkout_commit,
            tag_commit=args.tag_commit,
            verification_json=args.verification_json,
            policy=args.policy,
        )
    except IdentityError:
        print("ERROR: release source identity validation failed.", file=sys.stderr)
        return 1
    print("Release source identity validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
