#!/usr/bin/env python3
"""Derive direct APK expectations from pubspec, Gradle, manifest, and policy."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

VERSION = re.compile(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*(?:#.*)?$", re.MULTILINE)
APPLICATION = re.compile(r'^\s*applicationId\s*=\s*"([A-Za-z0-9_.]+)"\s*$', re.MULTILINE)
MIN_SDK = re.compile(r"^\s*minSdk\s*=\s*([0-9]+)\s*$", re.MULTILINE)
TARGET_SDK = re.compile(r"^\s*targetSdk\s*=\s*([0-9]+)\s*$", re.MULTILINE)
ANDROID = "{http://schemas.android.com/apk/res/android}"
ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")


class SourceError(ValueError):
    pass


def one(pattern: re.Pattern[str], text: str) -> str:
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise SourceError
    value = matches[0]
    if isinstance(value, tuple):
        raise SourceError
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pubspec", type=Path, required=True)
    parser.add_argument("--gradle", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        pubspec = args.pubspec.read_text(encoding="utf-8")
        versions = VERSION.findall(pubspec)
        if len(versions) != 1:
            raise SourceError
        version_name, version_code_value = versions[0]
        gradle = args.gradle.read_text(encoding="utf-8")
        package = one(APPLICATION, gradle)
        min_sdk = int(one(MIN_SDK, gradle))
        target_sdk = int(one(TARGET_SDK, gradle))
        raw_manifest = args.manifest.read_bytes()
        if b"<!DOCTYPE" in raw_manifest.upper() or b"<!ENTITY" in raw_manifest.upper():
            raise SourceError
        manifest = ET.fromstring(raw_manifest)
        applications = [child for child in manifest if child.tag.rsplit("}", 1)[-1] == "application"]
        if len(applications) != 1:
            raise SourceError
        label = applications[0].get(f"{ANDROID}label")
        if not label:
            raise SourceError
        policy = json.loads(args.policy.read_text(encoding="utf-8"))
        expected_policy_keys = {"schema", "permissions", "forbiddenPermissions", "foregroundServices", "requiredPackageQueries"}
        if not isinstance(policy, dict) or set(policy) != expected_policy_keys or policy["schema"] != 1:
            raise SourceError
        value = {
            "schema": 1,
            "flavor": "full",
            "package": package,
            "versionName": version_name,
            "versionCode": int(version_code_value),
            "abiVersionCodes": {abi: int(version_code_value) for abi in ABIS},
            "minSdk": min_sdk,
            "targetSdk": target_sdk,
            "label": label,
            "permissions": policy["permissions"],
            "forbiddenPermissions": policy["forbiddenPermissions"],
            "foregroundServices": policy["foregroundServices"],
            "requiredPackageQueries": policy["requiredPackageQueries"],
        }
        content = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
    except (OSError, UnicodeError, json.JSONDecodeError, ET.ParseError, SourceError, ValueError, AttributeError):
        print("ERROR: full-release expectations could not be derived.", file=sys.stderr)
        return 1
    print("Full-release expectations derived.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
