#!/usr/bin/env python3
"""Exercise the fixture-injected provenance core outside the final anchored CLI."""

from __future__ import annotations

import argparse
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool/release"))
import validate_public_apk_provenance as validator


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--asset-directory", type=Path, required=True)
    parser.add_argument("--expected", type=Path, required=True)
    parser.add_argument("--signer", required=True)
    parser.add_argument("--trusted-toolchain", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--tool-policy", type=Path, required=True)
    parser.add_argument("--inspection-log", type=Path)
    args = parser.parse_args()
    try:
        validator.validate_provenance(
            args.archive,
            args.asset_directory,
            args.expected,
            args.signer,
            args.trusted_toolchain,
            args.source_root,
            args.tool_policy,
            args.inspection_log,
        )
    except (OSError, validator.ProvenanceError, tarfile.TarError):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
