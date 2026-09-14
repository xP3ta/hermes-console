#!/usr/bin/env python3
"""Apply the structural half of the release DSSE/SLSA provenance policy.

This does not verify cryptography. The release workflow must first run
``gh attestation verify`` with the exact repository, workflow, ref and commit
constraints from release_contract.json, then run this gate on the same bundle.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import re
import stat
import sys
from pathlib import Path
from typing import Any

TAG = re.compile(r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
COMMIT = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
RUN = re.compile(r"^https://github\.com/xP3ta/hermes-console/actions/runs/[1-9][0-9]*/attempts/[1-9][0-9]*$")
MAX_BUNDLE = 8 * 1024 * 1024
MAX_PAYLOAD = 2 * 1024 * 1024


class PolicyError(ValueError):
    pass


def exact(value: Any, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise PolicyError
    return value


def nonempty(value: Any) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        raise PolicyError
    return value


def regular_file(path: Path) -> Path:
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise PolicyError
        result = path.resolve(strict=True)
    except OSError as error:
        raise PolicyError from error
    if not result.is_file() or result.stat().st_size <= 0:
        raise PolicyError
    return result


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with regular_file(path).open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise PolicyError from error
    return digest.hexdigest()


def decode_base64(value: Any, *, maximum: int) -> bytes:
    try:
        result = base64.b64decode(nonempty(value), validate=True)
    except (binascii.Error, ValueError) as error:
        raise PolicyError from error
    if not result or len(result) > maximum:
        raise PolicyError
    return result


def load_json(path: Path) -> dict[str, Any]:
    file_path = regular_file(path)
    if file_path.stat().st_size > MAX_BUNDLE:
        raise PolicyError
    try:
        value = json.loads(file_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PolicyError from error
    if not isinstance(value, dict):
        raise PolicyError
    return value


def load_single_bundle(path: Path) -> dict[str, Any]:
    file_path = regular_file(path)
    if file_path.stat().st_size > MAX_BUNDLE:
        raise PolicyError
    try:
        lines = file_path.read_text(encoding="utf-8").splitlines()
        if len(lines) != 1 or not lines[0]:
            raise PolicyError
        value = json.loads(lines[0])
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PolicyError from error
    return exact(value, {"mediaType", "verificationMaterial", "dsseEnvelope"})


def validate(policy_path: Path, bundle_path: Path, assets_path: Path, tag: str, commit: str) -> None:
    if TAG.fullmatch(tag) is None or COMMIT.fullmatch(commit) is None:
        raise PolicyError
    policy = load_json(policy_path)
    if policy.get("schema") != 1:
        raise PolicyError
    provenance = policy.get("provenance")
    channels = policy.get("channels")
    if not isinstance(provenance, dict) or not isinstance(channels, dict):
        raise PolicyError
    direct = channels.get("direct-public")
    if not isinstance(direct, dict):
        raise PolicyError
    subject_names = direct.get("provenanceSubjects")
    if not isinstance(subject_names, list) or not subject_names:
        raise PolicyError
    subject_names = sorted(nonempty(name) for name in subject_names)
    if len(subject_names) != len(set(subject_names)):
        raise PolicyError

    bundle = load_single_bundle(bundle_path)
    if bundle["mediaType"] != provenance.get("bundleMediaType"):
        raise PolicyError
    verification = bundle["verificationMaterial"]
    if not isinstance(verification, dict):
        raise PolicyError
    certificate = verification.get("certificate")
    tlog = verification.get("tlogEntries")
    if not isinstance(certificate, dict) or set(certificate) != {"rawBytes"}:
        raise PolicyError
    decode_base64(certificate["rawBytes"], maximum=MAX_PAYLOAD)
    if not isinstance(tlog, list) or not tlog or not all(isinstance(item, dict) for item in tlog):
        raise PolicyError

    envelope = exact(bundle["dsseEnvelope"], {"payloadType", "payload", "signatures"})
    if envelope["payloadType"] != provenance.get("dssePayloadType"):
        raise PolicyError
    signatures = envelope["signatures"]
    if not isinstance(signatures, list) or len(signatures) != 1:
        raise PolicyError
    raw_signature = signatures[0]
    if not isinstance(raw_signature, dict) or set(raw_signature) not in ({"sig"}, {"keyid", "sig"}):
        raise PolicyError
    if "keyid" in raw_signature and not isinstance(raw_signature["keyid"], str):
        raise PolicyError
    decode_base64(raw_signature["sig"], maximum=MAX_PAYLOAD)
    payload = decode_base64(envelope["payload"], maximum=MAX_PAYLOAD)
    try:
        statement = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PolicyError from error
    statement = exact(statement, {"_type", "subject", "predicateType", "predicate"})
    if (
        statement["_type"] != provenance.get("statementType")
        or statement["predicateType"] != provenance.get("predicateType")
    ):
        raise PolicyError

    try:
        assets = assets_path.resolve(strict=True)
    except OSError as error:
        raise PolicyError from error
    if not assets.is_dir() or assets.is_symlink():
        raise PolicyError
    expected_subjects = [
        {
            "name": name,
            "digest": {"sha256": sha256_file(assets / name)},
        }
        for name in subject_names
    ]
    subjects = statement["subject"]
    if subjects != expected_subjects:
        raise PolicyError

    predicate = statement["predicate"]
    if not isinstance(predicate, dict):
        raise PolicyError
    definition = predicate.get("buildDefinition")
    details = predicate.get("runDetails")
    if not isinstance(definition, dict) or not isinstance(details, dict):
        raise PolicyError
    if definition.get("buildType") != provenance.get("buildType"):
        raise PolicyError
    external = definition.get("externalParameters")
    workflow = external.get("workflow") if isinstance(external, dict) else None
    repository = nonempty(provenance.get("repository"))
    workflow_path = nonempty(provenance.get("workflowPath"))
    ref = f"refs/tags/{tag}"
    if workflow != {"ref": ref, "repository": repository, "path": workflow_path}:
        raise PolicyError
    dependencies = definition.get("resolvedDependencies")
    expected_dependency = {
        "uri": f"git+{repository}@{ref}",
        "digest": {"gitCommit": commit},
    }
    if dependencies != [expected_dependency]:
        raise PolicyError
    identity_template = nonempty(provenance.get("certificateIdentityTemplate"))
    if identity_template.count("{tag}") != 1:
        raise PolicyError
    expected_builder = identity_template.replace("{tag}", tag)
    if expected_builder != f"{repository}/{workflow_path}@{ref}":
        raise PolicyError
    if details.get("builder") != {"id": expected_builder}:
        raise PolicyError
    metadata = details.get("metadata")
    invocation = metadata.get("invocationId") if isinstance(metadata, dict) else None
    if not isinstance(invocation, str) or RUN.fullmatch(invocation) is None:
        raise PolicyError


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--asset-directory", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        validate(args.policy, args.bundle, args.asset_directory, args.tag, args.commit)
    except (OSError, PolicyError):
        print("ERROR: DSSE/SLSA structural provenance policy failed.", file=sys.stderr)
        return 1
    print(
        "DSSE/SLSA structural policy passed; cryptographic identity is a separate gh attestation gate."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
