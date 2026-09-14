#!/usr/bin/env python3
"""Require non-empty COMPLETE license evidence bound to source and artifact."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

SHA256 = re.compile(r"^[0-9a-f]{64}$")
GIT_ID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
REVIEW_KEYS = {
    "schema", "status", "inputFingerprint", "sourceCommit",
    "dependencyComponents", "sourceAssets", "packagedEntries", "unresolved",
}


class LicenseError(ValueError):
    pass


def exact(value: Any, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise LicenseError
    return value


def resolved(value: Any) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        raise LicenseError
    if value.casefold() in {"noassertion", "none", "unknown", "unresolved"}:
        raise LicenseError
    return value


def digest(value: Any) -> str:
    value = resolved(value)
    if SHA256.fullmatch(value) is None:
        raise LicenseError
    return value


def commit(value: Any) -> str:
    value = resolved(value)
    if GIT_ID.fullmatch(value) is None:
        raise LicenseError
    return value


def normalize_entries(value: Any, identity_key: str) -> list[dict[str, str]]:
    if not isinstance(value, list) or not value:
        raise LicenseError
    result = []
    identities = set()
    for raw in value:
        entry = exact(raw, {identity_key, "license", "evidence"})
        identity = resolved(entry[identity_key])
        if identity in identities:
            raise LicenseError
        identities.add(identity)
        result.append(
            {
                identity_key: identity,
                "license": resolved(entry["license"]),
                "evidence": resolved(entry["evidence"]),
            }
        )
    return sorted(result, key=lambda item: item[identity_key])


def cyclone_license(component: dict[str, Any]) -> str:
    licenses = component.get("licenses")
    if not isinstance(licenses, list) or not licenses:
        raise LicenseError
    values = []
    for item in licenses:
        if not isinstance(item, dict):
            raise LicenseError
        if set(item) == {"expression"}:
            values.append(resolved(item["expression"]))
        elif set(item) == {"license"} and isinstance(item["license"], dict):
            license_value = item["license"].get("id", item["license"].get("name"))
            values.append(resolved(license_value))
        else:
            raise LicenseError
    if len(values) != len(set(values)):
        raise LicenseError
    return " OR ".join(sorted(values))


def cyclone_evidence(component: dict[str, Any]) -> str:
    properties = component.get("properties")
    if not isinstance(properties, list):
        raise LicenseError
    values = {}
    for item in properties:
        if not isinstance(item, dict) or set(item) != {"name", "value"}:
            raise LicenseError
        name = resolved(item["name"])
        if name in values:
            raise LicenseError
        values[name] = item["value"]
    return resolved(values.get("hermes.license.evidence") or values.get("hermes.license.files"))


def normalize_components(sbom: dict[str, Any]) -> list[dict[str, str]]:
    components = sbom.get("components")
    if not isinstance(components, list) or not components:
        raise LicenseError
    result = []
    for component_value in components:
        if not isinstance(component_value, dict):
            raise LicenseError
        if set(component_value) == {"id", "license", "evidence"}:
            result.extend(normalize_entries([component_value], "id"))
        else:
            result.append(
                {
                    "id": resolved(component_value.get("bom-ref")),
                    "license": cyclone_license(component_value),
                    "evidence": cyclone_evidence(component_value),
                }
            )
    result.sort(key=lambda item: item["id"])
    if len({item["id"] for item in result}) != len(result):
        raise LicenseError
    return result


def normalize_inventory(value: Any, key: str) -> list[dict[str, str]]:
    if not isinstance(value, list) or not value:
        raise LicenseError
    result = []
    for item in value:
        if not isinstance(item, dict):
            raise LicenseError
        result.append(
            {
                "path": resolved(item.get("path")),
                "license": resolved(item.get("license")),
                "evidence": resolved(item.get("evidence", item.get("licenseEvidence"))),
            }
        )
    result.sort(key=lambda item: item["path"])
    if len({item["path"] for item in result}) != len(result):
        raise LicenseError
    return result


def sbom_identity(sbom: dict[str, Any]) -> tuple[str, str]:
    metadata = sbom.get("metadata")
    if not isinstance(metadata, dict):
        raise LicenseError
    if set(metadata) == {"inputFingerprint", "sourceCommit"}:
        return digest(metadata["inputFingerprint"]), commit(metadata["sourceCommit"])
    properties = metadata.get("properties")
    if not isinstance(properties, list):
        raise LicenseError
    values = {}
    for item in properties:
        if not isinstance(item, dict):
            raise LicenseError
        name = item.get("name")
        if name in values:
            raise LicenseError
        values[name] = item.get("value")
    return digest(values.get("hermes.input.sha256")), commit(values.get("hermes.git.commit"))


def validate_documents(
    review: dict[str, Any],
    sbom: dict[str, Any],
    source_assets: dict[str, Any],
    artifact_inventory: dict[str, Any],
    *,
    expected_fingerprint: str,
    expected_commit: str,
    artifact_name: str,
    artifact_sha256: str,
) -> None:
    exact(review, REVIEW_KEYS)
    expected_fingerprint = digest(expected_fingerprint)
    expected_commit = commit(expected_commit)
    if (
        review["schema"] != 1
        or review["status"] != "COMPLETE"
        or review["inputFingerprint"] != expected_fingerprint
        or review["sourceCommit"] != expected_commit
        or not isinstance(review["unresolved"], list)
        or review["unresolved"]
        or sbom_identity(sbom) != (expected_fingerprint, expected_commit)
        or source_assets.get("inputFingerprint") != expected_fingerprint
        or source_assets.get("sourceCommit", source_assets.get("commit")) != expected_commit
        or artifact_inventory.get("inputFingerprint") != expected_fingerprint
        or artifact_inventory.get("sourceCommit", artifact_inventory.get("commit")) != expected_commit
    ):
        raise LicenseError
    recorded_artifact = artifact_inventory.get("artifact")
    if not isinstance(recorded_artifact, dict) or set(recorded_artifact) not in (
        {"name", "sha256"},
        {"name", "size", "sha256"},
    ):
        raise LicenseError
    if (
        recorded_artifact.get("name") != artifact_name
        or recorded_artifact.get("sha256") != digest(artifact_sha256)
        or (
            "size" in recorded_artifact
            and (
                not isinstance(recorded_artifact["size"], int)
                or isinstance(recorded_artifact["size"], bool)
                or recorded_artifact["size"] <= 0
            )
        )
    ):
        raise LicenseError
    components = normalize_components(sbom)
    assets = normalize_inventory(source_assets.get("assets", source_assets.get("files")), "source")
    packaged = normalize_inventory(
        artifact_inventory.get("packagedEntries", artifact_inventory.get("packagedFiles")),
        "artifact",
    )
    if normalize_entries(review["dependencyComponents"], "id") != components:
        raise LicenseError
    if normalize_entries(review["sourceAssets"], "path") != assets:
        raise LicenseError
    if normalize_entries(review["packagedEntries"], "path") != packaged:
        raise LicenseError


def load(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise LicenseError
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise LicenseError from error
    if not isinstance(value, dict):
        raise LicenseError
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--review", type=Path, required=True)
    parser.add_argument("--sbom", type=Path, required=True)
    parser.add_argument("--source-assets", type=Path, required=True)
    parser.add_argument("--artifact-inventory", type=Path, required=True)
    parser.add_argument("--expected-fingerprint", required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--artifact-name", required=True)
    parser.add_argument("--artifact-sha256", required=True)
    args = parser.parse_args()
    try:
        validate_documents(
            load(args.review), load(args.sbom), load(args.source_assets),
            load(args.artifact_inventory),
            expected_fingerprint=args.expected_fingerprint,
            expected_commit=args.expected_commit,
            artifact_name=args.artifact_name,
            artifact_sha256=args.artifact_sha256,
        )
    except LicenseError:
        print("ERROR: release license evidence validation failed.", file=sys.stderr)
        return 1
    print("Release license evidence validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
