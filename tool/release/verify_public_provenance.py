#!/usr/bin/env python3
"""Cryptographically verify every public provenance subject with pinned GitHub CLI."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

TAG = re.compile(r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
COMMIT = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAX_POLICY_BYTES = 1024 * 1024
MAX_OUTPUT_BYTES = 8 * 1024 * 1024


class VerificationError(ValueError):
    pass


def regular_file(path: Path) -> Path:
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise VerificationError from error
    if not resolved.is_file() or stat.S_ISLNK(resolved.lstat().st_mode):
        raise VerificationError
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with regular_file(path).open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise VerificationError from error
    return digest.hexdigest()


def strict_string(value: Any) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        raise VerificationError
    return value


def load_policy(path: Path) -> tuple[dict[str, Any], list[str]]:
    policy_file = regular_file(path)
    if policy_file.stat().st_size > MAX_POLICY_BYTES:
        raise VerificationError
    try:
        policy = json.loads(policy_file.read_text(encoding="utf-8"))
        provenance = policy["provenance"]
        subjects = policy["channels"]["direct-public"]["provenanceSubjects"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise VerificationError from error
    required = {
        "repositorySlug",
        "workflowPath",
        "oidcIssuer",
        "certificateIdentityTemplate",
        "verifierSignerWorkflow",
        "predicateType",
        "cryptographicVerifier",
        "verifierPlatform",
        "verifierVersion",
        "verifierSha256",
        "denySelfHostedRunners",
    }
    if (
        policy.get("schema") != 1
        or not isinstance(provenance, dict)
        or not required.issubset(provenance)
        or provenance["cryptographicVerifier"] != "gh attestation verify"
        or provenance["verifierPlatform"] != f"{sys.platform}-{platform.machine()}"
        or provenance["denySelfHostedRunners"] is not True
        or not isinstance(subjects, list)
        or not subjects
    ):
        raise VerificationError
    normalized_subjects = [strict_string(value) for value in subjects]
    if len(normalized_subjects) != len(set(normalized_subjects)):
        raise VerificationError
    for key in required - {"denySelfHostedRunners"}:
        strict_string(provenance[key])
    if SHA256.fullmatch(provenance["verifierSha256"]) is None:
        raise VerificationError
    return provenance, normalized_subjects


def resolve_verifier(provenance: dict[str, Any]) -> Path:
    selected = shutil.which("gh")
    if selected is None:
        raise VerificationError
    verifier = regular_file(Path(selected))
    if sha256_file(verifier) != provenance["verifierSha256"]:
        raise VerificationError
    try:
        result = subprocess.run(
            [str(verifier), "--version"],
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError from error
    expected = f"gh version {provenance['verifierVersion']} "
    try:
        version_output = result.stdout.decode("utf-8", "strict")
    except UnicodeError as error:
        raise VerificationError from error
    if result.returncode != 0 or not version_output.startswith(expected):
        raise VerificationError
    return verifier


def verified_result_has_subject(value: Any, name: str, digest: str) -> bool:
    if not isinstance(value, list) or not value:
        return False
    expected = {"name": name, "digest": {"sha256": digest}}
    for item in value:
        if not isinstance(item, dict):
            continue
        result = item.get("verificationResult")
        statement = result.get("statement") if isinstance(result, dict) else None
        subjects = statement.get("subject") if isinstance(statement, dict) else None
        if isinstance(subjects, list) and expected in subjects:
            return True
    return False


def verify(policy_path: Path, bundle_path: Path, assets_path: Path, tag: str, commit: str) -> None:
    if TAG.fullmatch(tag) is None or COMMIT.fullmatch(commit) is None:
        raise VerificationError
    provenance, subjects = load_policy(policy_path)
    bundle = regular_file(bundle_path)
    try:
        assets = assets_path.resolve(strict=True)
    except OSError as error:
        raise VerificationError from error
    if not assets.is_dir() or assets.is_symlink() or bundle != regular_file(
        assets / "provenance.intoto.jsonl"
    ):
        raise VerificationError
    verifier = resolve_verifier(provenance)
    identity_template = provenance["certificateIdentityTemplate"]
    if identity_template.count("{tag}") != 1:
        raise VerificationError
    identity = identity_template.replace("{tag}", tag)
    source_ref = f"refs/tags/{tag}"
    for name in subjects:
        artifact = regular_file(assets / name)
        digest = sha256_file(artifact)
        command = [
            str(verifier),
            "attestation",
            "verify",
            str(artifact),
            "--bundle",
            str(bundle),
            "--repo",
            provenance["repositorySlug"],
            "--cert-identity",
            identity,
            "--cert-oidc-issuer",
            provenance["oidcIssuer"],
            "--source-ref",
            source_ref,
            "--source-digest",
            commit,
            "--predicate-type",
            provenance["predicateType"],
            "--deny-self-hosted-runners",
            "--format",
            "json",
        ]
        try:
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                timeout=60,
                env={key: value for key, value in os.environ.items() if key != "GH_TOKEN"},
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise VerificationError from error
        if (
            result.returncode != 0
            or len(result.stdout) + len(result.stderr) > MAX_OUTPUT_BYTES
            or b"\x00" in result.stdout
        ):
            raise VerificationError
        try:
            output = json.loads(result.stdout.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise VerificationError from error
        if not verified_result_has_subject(output, name, digest):
            raise VerificationError


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--asset-directory", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        verify(args.policy, args.bundle, args.asset_directory, args.tag, args.commit)
    except (OSError, VerificationError):
        print("ERROR: cryptographic provenance verification failed.", file=sys.stderr)
        return 1
    print("Cryptographic provenance verification passed for every public subject.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
