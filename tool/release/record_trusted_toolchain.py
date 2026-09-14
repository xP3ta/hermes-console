#!/usr/bin/env python3
"""Record pinned Android tools from an explicit trusted installation root."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path, PurePosixPath

import validate_public_apk_provenance as validator


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--jdk-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        root = validator.directory(args.root)
        java_root = validator.directory(args.jdk_root)
        policy = validator.public_tool_policy()
        build_revision = policy["buildToolsRevision"]
        command_revision = policy["commandLineToolsRevision"]
        tools = policy["tools"]
        validator.package_revision(
            root,
            f"build-tools/{build_revision}/source.properties",
            build_revision,
        )
        analyzer = PurePosixPath(tools["apkanalyzer"]["path"])
        validator.package_revision(
            root,
            str(analyzer.parents[1] / "source.properties"),
            command_revision,
        )
        for record in tools.values():
            tool = validator.child_file(root, record["path"], executable=True)
            if validator.sha256_file(tool) != record["sha256"]:
                raise validator.ProvenanceError
        roots = {"android-sdk": root, "jdk": java_root}
        for record in policy["runtimeTrees"].values():
            runtime = validator.child_directory(roots[record["root"]], record["path"])
            if validator.sha256_tree(runtime) != record["sha256"]:
                raise validator.ProvenanceError
        validator.child_file(java_root, "bin/java", executable=True)
        document = {
            "schema": 1,
            "root": str(root),
            "javaRoot": str(java_root),
            "buildToolsRevision": build_revision,
            "commandLineToolsRevision": command_revision,
            "tools": tools,
            "runtimeTrees": policy["runtimeTrees"],
        }
        content = (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode()
        descriptor = os.open(
            args.output,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
    except (OSError, validator.ProvenanceError):
        print("ERROR: trusted Android toolchain could not be recorded.", file=sys.stderr)
        return 1
    print("Trusted Android toolchain recorded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
