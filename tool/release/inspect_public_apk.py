#!/usr/bin/env python3
"""Measure one public full-release APK with three independent Android tools."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

ANDROID = "{http://schemas.android.com/apk/res/android}"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SUPPORTED_ABIS = {"arm64-v8a", "armeabi-v7a", "x86_64"}
EXPECTED_KEYS = {
    "schema", "flavor", "package", "versionName", "versionCode",
    "abiVersionCodes", "minSdk", "targetSdk", "label", "permissions",
    "forbiddenPermissions", "foregroundServices", "requiredPackageQueries",
}
FACT_KEYS = {
    "schema", "artifact", "flavor", "abi", "package", "versionName",
    "versionCode", "minSdk", "targetSdk", "label", "permissions",
    "foregroundServices", "requiredPackageQueries", "signerCertificateSha256",
    "tools",
}
MAX_OUTPUT = 2 * 1024 * 1024
MAX_ENTRIES = 100_000
MAX_UNCOMPRESSED = 2 * 1024 * 1024 * 1024


class InspectionError(ValueError):
    pass


def strict_string(value: Any) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        raise InspectionError
    return value


def strict_int(value: Any) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise InspectionError
    return value


def normalize_permissions(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise InspectionError
    result = []
    names = set()
    for item in value:
        if isinstance(item, str):
            item = {"name": item}
        if not isinstance(item, dict) or set(item) not in ({"name"}, {"name", "maxSdkVersion"}):
            raise InspectionError
        name = strict_string(item["name"])
        if name in names:
            raise InspectionError
        names.add(name)
        entry: dict[str, Any] = {"name": name}
        if "maxSdkVersion" in item:
            maximum = strict_int(item["maxSdkVersion"])
            if maximum < 1:
                raise InspectionError
            entry["maxSdkVersion"] = maximum
        result.append(entry)
    return sorted(result, key=lambda entry: entry["name"])


def normalize_strings(value: Any, *, nonempty: bool = True) -> list[str]:
    if not isinstance(value, list) or (nonempty and not value):
        raise InspectionError
    result = sorted(strict_string(item) for item in value)
    if len(result) != len(set(result)):
        raise InspectionError
    return result


def normalize_services(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise InspectionError
    result = []
    names = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {"name", "types"}:
            raise InspectionError
        name = strict_string(item["name"])
        types = normalize_strings(item["types"])
        if name in names:
            raise InspectionError
        names.add(name)
        result.append({"name": name, "types": types})
    return sorted(result, key=lambda entry: entry["name"])


def expected_facts(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InspectionError from error
    if not isinstance(value, dict) or set(value) != EXPECTED_KEYS:
        raise InspectionError
    if value["schema"] != 1 or value["flavor"] != "full":
        raise InspectionError
    abi_codes = value["abiVersionCodes"]
    version_code = strict_int(value["versionCode"])
    if not isinstance(abi_codes, dict) or set(abi_codes) != SUPPORTED_ABIS:
        raise InspectionError
    normalized_codes = {abi: strict_int(abi_codes[abi]) for abi in sorted(abi_codes)}
    if any(code != version_code for code in normalized_codes.values()):
        raise InspectionError
    return {
        "schema": 1,
        "flavor": "full",
        "package": strict_string(value["package"]),
        "versionName": strict_string(value["versionName"]),
        "versionCode": version_code,
        "abiVersionCodes": normalized_codes,
        "minSdk": strict_int(value["minSdk"]),
        "targetSdk": strict_int(value["targetSdk"]),
        "label": strict_string(value["label"]),
        "permissions": normalize_permissions(value["permissions"]),
        "forbiddenPermissions": normalize_strings(value["forbiddenPermissions"], nonempty=False),
        "foregroundServices": normalize_services(value["foregroundServices"]),
        "requiredPackageQueries": normalize_strings(value["requiredPackageQueries"], nonempty=False),
    }


def sha256_file(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise InspectionError
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def resolve_tool(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise InspectionError
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise InspectionError
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise InspectionError from error
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise InspectionError
    return resolved


def run_tool(tool: Path, arguments: list[str], environment: dict[str, str] | None = None) -> str:
    try:
        result = subprocess.run(
            [str(tool), *arguments], check=False, capture_output=True, timeout=30, env=environment
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InspectionError from error
    if result.returncode != 0 or len(result.stdout) + len(result.stderr) > MAX_OUTPUT or b"\x00" in result.stdout:
        raise InspectionError
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise InspectionError from error


def one(pattern: str, value: str) -> str:
    matches = re.findall(pattern, value, re.MULTILINE)
    if len(matches) != 1:
        raise InspectionError
    return matches[0]


def parse_aapt(value: str) -> dict[str, Any]:
    package = re.findall(
        r"^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'\s+versionName='([^']+)'(?:\s.*)?$",
        value,
        re.MULTILINE,
    )
    if len(package) != 1:
        raise InspectionError
    name, code, version = package[0]
    permissions = sorted(re.findall(r"^uses-permission:\s+name='([^']+)'(?:\s.*)?$", value, re.MULTILINE))
    native = re.findall(r"^native-code:\s+((?:'[^']+'\s*)+)$", value, re.MULTILINE)
    abis = re.findall(r"'([^']+)'", native[0]) if len(native) == 1 else []
    if not permissions or len(permissions) != len(set(permissions)) or len(abis) != 1:
        raise InspectionError
    return {
        "package": name,
        "versionName": version,
        "versionCode": int(code),
        "minSdk": int(one(r"^sdkVersion:'([0-9]+)'\s*$", value)),
        "targetSdk": int(one(r"^targetSdkVersion:'([0-9]+)'\s*$", value)),
        "permissions": permissions,
        "abi": abis[0],
    }


def tool_value(value: str) -> str:
    lines = [line.strip() for line in value.splitlines() if line.strip()]
    if len(lines) != 1:
        raise InspectionError
    return strict_string(lines[0])


def parse_manifest(value: str) -> dict[str, Any]:
    raw = value.encode()
    if len(raw) > MAX_OUTPUT or b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
        raise InspectionError
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise InspectionError from error
    if root.tag.rsplit("}", 1)[-1] != "manifest":
        raise InspectionError
    uses_sdk = [child for child in root if child.tag.rsplit("}", 1)[-1] == "uses-sdk"]
    applications = [child for child in root if child.tag.rsplit("}", 1)[-1] == "application"]
    if len(uses_sdk) != 1 or len(applications) != 1:
        raise InspectionError
    permissions = []
    queries = []
    for child in root:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag.startswith("uses-permission") and tag != "uses-permission":
            raise InspectionError
        if tag == "uses-permission":
            entry: dict[str, Any] = {"name": strict_string(child.get(f"{ANDROID}name"))}
            maximum = child.get(f"{ANDROID}maxSdkVersion")
            if maximum is not None:
                if not maximum.isdecimal():
                    raise InspectionError
                entry["maxSdkVersion"] = int(maximum)
            permissions.append(entry)
        elif tag == "queries":
            for query in child:
                if query.tag.rsplit("}", 1)[-1] == "package":
                    queries.append(strict_string(query.get(f"{ANDROID}name")))
    services = []
    for child in applications[0]:
        if child.tag.rsplit("}", 1)[-1] != "service":
            continue
        raw_types = child.get(f"{ANDROID}foregroundServiceType")
        if raw_types:
            services.append({"name": strict_string(child.get(f"{ANDROID}name")), "types": raw_types.split("|")})
    return {
        "package": strict_string(root.get("package")),
        "versionName": strict_string(root.get(f"{ANDROID}versionName")),
        "versionCode": int(strict_string(root.get(f"{ANDROID}versionCode"))),
        "minSdk": int(strict_string(uses_sdk[0].get(f"{ANDROID}minSdkVersion"))),
        "targetSdk": int(strict_string(uses_sdk[0].get(f"{ANDROID}targetSdkVersion"))),
        "label": strict_string(applications[0].get(f"{ANDROID}label")),
        "permissions": normalize_permissions(permissions),
        "foregroundServices": normalize_services(services),
        "packageQueries": normalize_strings(queries, nonempty=False),
    }


def signer_digest(value: str) -> str:
    if "Verifies" not in value.splitlines():
        raise InspectionError
    matches = re.findall(r"^Signer #1 certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)\s*$", value, re.MULTILINE)
    if len(matches) != 1 or re.search(r"^Signer #[2-9][0-9]* ", value, re.MULTILINE):
        raise InspectionError
    digest = matches[0].replace(":", "").lower()
    if SHA256.fullmatch(digest) is None:
        raise InspectionError
    return digest


def validate_apk(path: Path) -> None:
    if not path.is_file() or path.is_symlink() or path.stat().st_size <= 0:
        raise InspectionError
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            names = set()
            total = 0
            for entry in entries:
                member = PurePosixPath(entry.filename)
                if (
                    not entry.filename or "\\" in entry.filename or member.is_absolute()
                    or "." in member.parts or ".." in member.parts or entry.filename in names
                    or entry.flag_bits & 1 or stat.S_ISLNK(entry.external_attr >> 16)
                    or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                ):
                    raise InspectionError
                names.add(entry.filename)
                total += entry.file_size
            if len(entries) > MAX_ENTRIES or total > MAX_UNCOMPRESSED or not {"AndroidManifest.xml", "resources.arsc"}.issubset(names) or not any(name.endswith(".dex") for name in names) or archive.testzip() is not None:
                raise InspectionError
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise InspectionError from error


def inspect(artifact: Path, expected: dict[str, Any], artifact_name: str, abi: str, signer: str, aapt: Path, apkanalyzer: Path, apksigner: Path, environment: dict[str, str] | None = None) -> dict[str, Any]:
    if artifact.name != artifact_name or abi not in SUPPORTED_ABIS or SHA256.fullmatch(signer) is None:
        raise InspectionError
    validate_apk(artifact)
    aapt_facts = parse_aapt(run_tool(aapt, ["dump", "badging", str(artifact)], environment))
    analyzer = {
        key: tool_value(run_tool(apkanalyzer, ["manifest", query, str(artifact)], environment))
        for key, query in (
            ("package", "application-id"), ("versionName", "version-name"),
            ("versionCode", "version-code"), ("minSdk", "min-sdk"),
            ("targetSdk", "target-sdk"),
        )
    }
    analyzer_permissions = normalize_strings(run_tool(apkanalyzer, ["manifest", "permissions", str(artifact)], environment).splitlines())
    manifest = parse_manifest(run_tool(apkanalyzer, ["manifest", "print", str(artifact)], environment))
    measured_signer = signer_digest(run_tool(apksigner, ["verify", "--verbose", "--print-certs", str(artifact)], environment))
    expected_code = expected["abiVersionCodes"].get(abi)
    for key in ("package", "versionName", "minSdk", "targetSdk"):
        if str(aapt_facts[key]) != analyzer[key] or aapt_facts[key] != manifest[key] or manifest[key] != expected[key]:
            raise InspectionError
    if (
        aapt_facts["versionCode"] != expected_code or manifest["versionCode"] != expected_code
        or analyzer["versionCode"] != str(expected_code) or aapt_facts["abi"] != abi
        or aapt_facts["permissions"] != analyzer_permissions
        or [entry["name"] for entry in manifest["permissions"]] != analyzer_permissions
        or manifest["permissions"] != expected["permissions"]
        or manifest["foregroundServices"] != expected["foregroundServices"]
        or not set(expected["requiredPackageQueries"]).issubset(manifest["packageQueries"])
        or set(expected["forbiddenPermissions"]).intersection(analyzer_permissions)
        or measured_signer != signer
    ):
        raise InspectionError
    return {
        "schema": 1,
        "artifact": {"name": artifact.name, "size": artifact.stat().st_size, "sha256": sha256_file(artifact)},
        "flavor": "full", "abi": abi, "package": expected["package"],
        "versionName": expected["versionName"], "versionCode": expected_code,
        "minSdk": expected["minSdk"], "targetSdk": expected["targetSdk"],
        "label": expected["label"], "permissions": manifest["permissions"],
        "foregroundServices": manifest["foregroundServices"],
        "requiredPackageQueries": expected["requiredPackageQueries"],
        "signerCertificateSha256": measured_signer,
        "tools": {name: {"path": str(path), "sha256": sha256_file(path)} for name, path in sorted({"aapt": aapt, "apkanalyzer": apkanalyzer, "apksigner": apksigner}.items())},
    }


def canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_exclusive(path: Path, value: dict[str, Any]) -> None:
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
        with os.fdopen(descriptor, "wb") as output:
            output.write(canonical(value))
    except OSError as error:
        raise InspectionError from error


def reviewed_signer(path: Path) -> str:
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_OUTPUT:
            raise InspectionError
        value = json.loads(path.read_text(encoding="utf-8"))
        record = value["signerContinuity"]["direct-public"]
        signer = strict_string(record["certificateSha256"].lower())
        baseline_tag = strict_string(record["baselineTag"])
        baseline_artifact = strict_string(record["baselineArtifact"])
        baseline_digest = strict_string(record["baselineArtifactSha256"].lower())
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise InspectionError from error
    if (
        value.get("schema") != 1
        or SHA256.fullmatch(signer) is None
        or SHA256.fullmatch(baseline_digest) is None
        or re.fullmatch(r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$", baseline_tag) is None
        or baseline_artifact != "app-arm64-v8a-full-release.apk"
    ):
        raise InspectionError
    return signer


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--expected", type=Path, required=True)
    parser.add_argument("--expected-artifact-name", required=True)
    parser.add_argument("--expected-abi", required=True)
    parser.add_argument("--expected-signer-sha256", required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--aapt", required=True)
    parser.add_argument("--apkanalyzer", required=True)
    parser.add_argument("--apksigner", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        signer = strict_string(args.expected_signer_sha256.lower())
        if signer != reviewed_signer(args.policy):
            raise InspectionError
        facts = inspect(
            args.artifact, expected_facts(args.expected), args.expected_artifact_name,
            args.expected_abi, signer,
            resolve_tool(args.aapt), resolve_tool(args.apkanalyzer), resolve_tool(args.apksigner),
        )
        write_exclusive(args.output, facts)
    except (InspectionError, OSError, ValueError):
        print("ERROR: public APK inspection failed.", file=sys.stderr)
        return 1
    print("Public APK inspection passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
