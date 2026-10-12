#!/usr/bin/env python3
"""Compare one manifest, as text, with tool/release/full_release_policy.json.

The `play` and `full` flavors share one source manifest, so one policy describes
both. This helper checks the manifests that exist before and beside the signed
artifacts, with the same exact rules `inspect_public_apk.py` applies to an APK:

  * Gradle's merged manifest of either flavor
    (build/app/intermediates/merged_manifests/<flavor>Release/.../AndroidManifest.xml);
  * `bundletool dump manifest --bundle=<aab>` for the Play bundle;
  * `apkanalyzer manifest print <apk>` for an APK.

Permissions (with maxSdkVersion), foreground services (with types) and package
queries must equal the policy; nothing in `forbiddenPermissions` may appear.
With --pubspec the version name and build number must match pubspec.yaml too;
use it on the AAB's manifest, which carries them unsplit. A merged manifest from
Gradle alone (without `flutter build`) has no real version, and a split APK's
version code is the build number plus an ABI offset (inspect_public_apk.py).

It prints what differs and exits 1; it is a diagnostic for the maintainer, not
one of the fail-closed evidence gates.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

import inspect_public_apk as inspector

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*(?:#.*)?$", re.MULTILINE)


def describe(entries: list[dict[str, Any]]) -> set[str]:
    return {
        entry["name"] + (f" (maxSdkVersion {entry['maxSdkVersion']})" if "maxSdkVersion" in entry else "")
        for entry in entries
    }


def services(entries: list[dict[str, Any]]) -> set[str]:
    return {f"{entry['name']} [{'|'.join(entry['types'])}]" for entry in entries}


def differences(manifest: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    result: list[str] = []
    have, want = describe(manifest["permissions"]), describe(policy["permissions"])
    result += [f"permission not in policy: {item}" for item in sorted(have - want)]
    result += [f"permission missing from manifest: {item}" for item in sorted(want - have)]
    names = {entry["name"] for entry in manifest["permissions"]}
    result += [f"forbidden permission present: {item}" for item in sorted(names & set(policy["forbiddenPermissions"]))]
    have, want = services(manifest["foregroundServices"]), services(policy["foregroundServices"])
    result += [f"foreground service not in policy: {item}" for item in sorted(have - want)]
    result += [f"foreground service missing from manifest: {item}" for item in sorted(want - have)]
    queries, expected = set(manifest["packageQueries"]), set(policy["packageQueries"])
    result += [f"package query not in policy: {item}" for item in sorted(queries - expected)]
    result += [f"package query missing from manifest: {item}" for item in sorted(expected - queries)]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--policy", type=Path, default=ROOT / "tool/release/full_release_policy.json")
    parser.add_argument("--pubspec", type=Path)
    args = parser.parse_args()
    try:
        policy = inspector.expected_policy(args.policy)
        manifest = inspector.parse_manifest(args.manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError, inspector.InspectionError) as error:
        print(f"ERROR: cannot read the manifest or the policy ({type(error).__name__}).", file=sys.stderr)
        return 1
    problems = differences(manifest, policy)
    try:
        package = json.loads((ROOT / "tool/release/release_contract.json").read_text(encoding="utf-8"))["android"]["packageId"]
    except (OSError, UnicodeError, KeyError, TypeError, json.JSONDecodeError):
        package = None
    if manifest["package"] != package:
        problems.append(f"package {manifest['package']} != release_contract.json android.packageId {package}")
    if args.pubspec is not None:
        match = VERSION.search(args.pubspec.read_text(encoding="utf-8"))
        if match is None:
            problems.append("pubspec.yaml has no version: name+build line")
        else:
            if manifest["versionName"] != match.group(1):
                problems.append(f"versionName {manifest['versionName']} != pubspec {match.group(1)}")
            if str(manifest["versionCode"]) != match.group(2):
                problems.append(f"versionCode {manifest['versionCode']} != pubspec build number {match.group(2)}")
    for problem in problems:
        print(f"MISMATCH: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(
        f"Manifest matches the release policy: {len(manifest['permissions'])} permissions, "
        f"{len(manifest['foregroundServices'])} foreground services, "
        f"{len(manifest['packageQueries'])} package queries."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
