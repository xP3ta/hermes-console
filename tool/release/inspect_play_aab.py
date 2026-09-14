#!/usr/bin/env python3
"""Verify Play-private AAB package, version, signature identity and SHA-256."""

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
from pathlib import Path, PurePosixPath
from typing import Any

import compare_rebuilds

SHA256 = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(
    r"^version:\s*((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"
    r"\+((?:0|[1-9][0-9]*))\s*(?:#.*)?$"
)
CERTIFICATE = re.compile(
    r"^\s*SHA256:\s*((?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})\s*$",
    re.MULTILINE,
)
MAX_OUTPUT = 2 * 1024 * 1024


class InspectionError(ValueError):
    pass


def resolve_tool(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise InspectionError
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise InspectionError
        result = path.resolve(strict=True)
    except OSError as error:
        raise InspectionError from error
    if not result.is_file() or not os.access(result, os.X_OK):
        raise InspectionError
    return result


def sha256_file(path: Path) -> str:
    try:
        return compare_rebuilds.sha256_file(path)
    except compare_rebuilds.ComparisonError as error:
        raise InspectionError from error


def resolve_root(path: Path) -> Path:
    if not path.is_absolute():
        raise InspectionError
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise InspectionError
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise InspectionError from error
    if not resolved.is_dir():
        raise InspectionError
    return resolved


def pinned_tools(policy: Path, android_sdk_root: Path, jdk_root: Path) -> dict[str, Path]:
    if not policy.is_file() or policy.is_symlink() or policy.stat().st_size > 1024 * 1024:
        raise InspectionError
    try:
        value = json.loads(policy.read_text(encoding="utf-8"))
        tool_policy = value["playInspectionTools"]
        records = tool_policy["tools"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise InspectionError from error
    if (
        value.get("schema") != 1
        or set(tool_policy) != {"platform", "tools"}
        or tool_policy["platform"] != f"{sys.platform}-{platform.machine()}"
        or not isinstance(records, dict)
        or set(records) != {"apkanalyzer", "jarsigner", "keytool"}
    ):
        raise InspectionError
    roots = {
        "android-sdk": resolve_root(android_sdk_root),
        "jdk": resolve_root(jdk_root),
    }
    result: dict[str, Path] = {}
    for name, record in records.items():
        if not isinstance(record, dict) or set(record) != {"root", "path", "sha256"}:
            raise InspectionError
        root_name = record["root"]
        relative = record["path"]
        expected_digest = record["sha256"]
        if root_name not in roots or not isinstance(relative, str) or not isinstance(expected_digest, str):
            raise InspectionError
        relative_path = PurePosixPath(relative)
        if (
            relative != relative_path.as_posix()
            or relative_path.is_absolute()
            or not relative_path.parts
            or "." in relative_path.parts
            or ".." in relative_path.parts
            or SHA256.fullmatch(expected_digest) is None
        ):
            raise InspectionError
        root = roots[root_name]
        tool = resolve_tool(str(root.joinpath(*relative_path.parts)))
        try:
            tool.relative_to(root)
        except ValueError as error:
            raise InspectionError from error
        if sha256_file(tool) != expected_digest:
            raise InspectionError
        result[name] = tool
    return result


def run_tool(path: Path, arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            [str(path), *arguments],
            check=False,
            capture_output=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InspectionError from error
    if result.returncode != 0 or len(result.stdout) + len(result.stderr) > MAX_OUTPUT:
        raise InspectionError
    try:
        return (result.stdout + result.stderr).decode("utf-8")
    except UnicodeError as error:
        raise InspectionError from error


def one_line(value: str) -> str:
    lines = [line.strip() for line in value.splitlines() if line.strip()]
    if len(lines) != 1:
        raise InspectionError
    return lines[0]


def source_version(path: Path) -> tuple[str, int]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 1024 * 1024:
        raise InspectionError
    try:
        matches = [VERSION.fullmatch(line) for line in path.read_text(encoding="utf-8").splitlines()]
    except (OSError, UnicodeError) as error:
        raise InspectionError from error
    matches = [match for match in matches if match is not None]
    if len(matches) != 1:
        raise InspectionError
    return matches[0].group(1), int(matches[0].group(2))


def policy_package(path: Path) -> str:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 1024 * 1024:
        raise InspectionError
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        package = value["android"]["packageId"]
        channel = value["channels"]["play-private"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise InspectionError from error
    if (
        value.get("schema") != 1
        or not isinstance(package, str)
        or not package
        or channel.get("artifacts") != [compare_rebuilds.PLAY_AAB]
        or channel.get("visibility") != "private"
    ):
        raise InspectionError
    return package


def policy_signer(path: Path) -> str:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        signer = value["signerContinuity"]["play-private"]["certificateSha256"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise InspectionError from error
    if not isinstance(signer, str):
        raise InspectionError
    signer = signer.lower()
    if SHA256.fullmatch(signer) is None:
        raise InspectionError
    return signer


def signer_digest(value: str) -> str:
    matches = CERTIFICATE.findall(value)
    if len(matches) != 1:
        raise InspectionError
    digest = matches[0].replace(":", "").lower()
    if SHA256.fullmatch(digest) is None:
        raise InspectionError
    return digest


def inspect(
    artifact: Path,
    pubspec: Path,
    policy: Path,
    expected_sha256: str,
    expected_signer: str,
    apkanalyzer: Path,
    jarsigner: Path,
    keytool: Path,
) -> dict[str, Any]:
    if SHA256.fullmatch(expected_sha256) is None or SHA256.fullmatch(expected_signer) is None:
        raise InspectionError
    try:
        zip_facts = compare_rebuilds.zip_facts(artifact)
    except compare_rebuilds.ComparisonError as error:
        raise InspectionError from error
    if zip_facts["sha256"] != expected_sha256:
        raise InspectionError
    expected_version, expected_code = source_version(pubspec)
    expected_package = policy_package(policy)
    anchored_signer = policy_signer(policy)
    if expected_signer != anchored_signer:
        raise InspectionError
    package = one_line(run_tool(apkanalyzer, ["manifest", "application-id", str(artifact)]))
    version = one_line(run_tool(apkanalyzer, ["manifest", "version-name", str(artifact)]))
    raw_code = one_line(run_tool(apkanalyzer, ["manifest", "version-code", str(artifact)]))
    if not raw_code.isdecimal():
        raise InspectionError
    code = int(raw_code)
    run_tool(jarsigner, ["-verify", "-strict", "-certs", str(artifact)])
    certificate_output = run_tool(
        keytool,
        [
            "-J-Duser.language=en",
            "-J-Duser.country=US",
            "-printcert",
            "-jarfile",
            str(artifact),
        ],
    )
    measured_signer = signer_digest(certificate_output)
    if (
        package != expected_package
        or version != expected_version
        or code != expected_code
        or measured_signer != expected_signer
    ):
        raise InspectionError
    return {
        "schema": 1,
        "channel": "play-private",
        "artifact": {
            "name": compare_rebuilds.PLAY_AAB,
            "size": zip_facts["size"],
            "sha256": zip_facts["sha256"],
        },
        "package": package,
        "versionName": version,
        "versionCode": code,
        "signerCertificateSha256": measured_signer,
        "tools": {
            name: {"path": str(path), "sha256": sha256_file(path)}
            for name, path in sorted(
                {
                    "apkanalyzer": apkanalyzer,
                    "jarsigner": jarsigner,
                    "keytool": keytool,
                }.items()
            )
        },
    }


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
        raise InspectionError from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--pubspec", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--expected-signer-sha256", required=True)
    parser.add_argument("--android-sdk-root", type=Path, required=True)
    parser.add_argument("--jdk-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        tools = pinned_tools(args.policy, args.android_sdk_root, args.jdk_root)
        facts = inspect(
            args.artifact,
            args.pubspec,
            args.policy,
            args.expected_sha256.lower(),
            args.expected_signer_sha256.lower(),
            tools["apkanalyzer"],
            tools["jarsigner"],
            tools["keytool"],
        )
        write_exclusive(args.output, facts)
    except (OSError, InspectionError):
        print("ERROR: Play-private AAB identity inspection failed.", file=sys.stderr)
        return 1
    print("Play-private AAB package, version, signature and hash passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
