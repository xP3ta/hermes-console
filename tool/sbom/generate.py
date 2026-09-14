#!/usr/bin/env python3
"""Generate deterministic CycloneDX inventories for Hermes Console.

This script intentionally uses only Python's standard library. It resolves the
exact Dart graph from ``pubspec.lock``/``dart pub deps`` and the exact Android
runtime classpath from Gradle. Unknown licences remain visible as NOASSERTION;
they are never guessed from a package name.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET  # nosemgrep: python.lang.security.use-defused-xml.use-defused-xml
import zipfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = "http://cyclonedx.org/schema/bom-1.6.schema.json"
MODEL_SUFFIXES = {".tflite", ".onnx", ".ort", ".bin", ".ggml", ".gguf"}
BINARY_SUFFIXES = {".aar", ".jar", ".so"}
VISUAL_ASSET_SUFFIXES = {".webp", ".png", ".svg", ".ttf", ".json"}
INVENTORY_ASSET_SUFFIXES = MODEL_SUFFIXES | BINARY_SUFFIXES | VISUAL_ASSET_SUFFIXES
LICENSE_NAMES = ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "COPYING.txt")
CATALOG_PATH = ROOT / "tool/sbom/maven-license-catalog.json"
PACKAGED_CATALOG_PATH = ROOT / "tool/sbom/packaged-license-catalog.json"
MAX_POM_BYTES = 2 * 1024 * 1024
MAX_ARTIFACT_ENTRIES = 10_000
MAX_ARTIFACT_MEMBER_BYTES = 256 * 1024 * 1024
MAX_ARTIFACT_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
ZIP_READ_CHUNK_BYTES = 1024 * 1024


def run(*args: str, cwd: Path = ROOT) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(f"command failed ({result.returncode}): {' '.join(args)}")
    return result.stdout


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_timestamp() -> str | None:
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if not epoch:
        return None
    instant = datetime.fromtimestamp(int(epoch), tz=timezone.utc)
    return instant.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def serial_number(variant: str, input_fingerprint: str, commit: str | None) -> str:
    seed = hashlib.sha256(
        f"hermes-console:{variant}:{input_fingerprint}:{commit or ''}".encode()
    ).hexdigest()[:32]
    return f"urn:uuid:{seed[0:8]}-{seed[8:12]}-4{seed[13:16]}-a{seed[17:20]}-{seed[20:32]}"


def inventory_asset_paths() -> list[Path]:
    """Return only source files that the asset inventory can publish."""
    paths: list[Path] = []
    for base in (ROOT / "assets", ROOT / "android/app/src"):
        if not base.exists():
            continue
        paths.extend(
            sorted(
                (
                    candidate
                    for candidate in base.rglob("*")
                    if candidate.is_file()
                    and candidate.suffix.lower() in INVENTORY_ASSET_SUFFIXES
                ),
                key=lambda candidate: candidate.relative_to(ROOT).as_posix(),
            )
        )
    return paths


def fingerprint_inputs() -> str:
    """Hash only inputs that affect the generated inventories.

    SBOM outputs and Git metadata are deliberately excluded so a checked-in
    SBOM does not need to predict the commit that will contain itself.
    """
    paths: set[Path] = set()
    for relative in (
        "pubspec.yaml",
        "pubspec.lock",
        "ASSET_PROVENANCE.md",
        "tool/sbom/generate.py",
        "tool/sbom/generate.sh",
        "tool/sbom/maven-license-catalog.json",
        "tool/sbom/packaged-license-catalog.json",
        "android/build.gradle.kts",
        "android/settings.gradle.kts",
        "android/gradle.properties",
        "android/app/build.gradle.kts",
        "android/gradle/wrapper/gradle-wrapper.properties",
    ):
        candidate = ROOT / relative
        if candidate.is_file():
            paths.add(candidate)
    paths.update(inventory_asset_paths())
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda candidate: candidate.relative_to(ROOT).as_posix()):
        relative = path.relative_to(ROOT).as_posix().encode()
        data = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def licence_expression(text: str) -> str | None:
    normal = " ".join(text.lower().split())
    # Inspect the licence heading, not every later cross-reference. GPLv3's
    # own appendix mentions the GNU Lesser GPL and would otherwise be
    # misclassified as LGPL-3.0-only.
    heading = normal[:512]
    if "apache license" in normal and "version 2.0" in normal:
        return "Apache-2.0"
    if "permission is hereby granted, free of charge" in normal:
        return "MIT"
    if "redistribution and use in source and binary forms" in normal:
        if "neither the name" in normal or "contributors may be used to endorse" in normal:
            return "BSD-3-Clause"
        return "BSD-2-Clause"
    if "mozilla public license version 2.0" in normal:
        return "MPL-2.0"
    if "isc license" in normal and "permission to use, copy, modify" in normal:
        return "ISC"
    if "sil open font license" in normal and "version 1.1" in normal:
        return "OFL-1.1"
    if "gnu lesser general public license" in heading and "version 3" in heading:
        return "LGPL-3.0-only"
    if "gnu general public license" in heading and "version 3" in heading:
        return "GPL-3.0-only"
    return None


def licence_files(package_root: Path) -> list[Path]:
    matches: list[Path] = []
    for name in LICENSE_NAMES:
        candidate = package_root / name
        if candidate.is_file():
            matches.append(candidate)
    # Flutter SDK support packages share the framework's BSD licence. Their
    # individual directories do not all duplicate the sibling flutter/LICENSE.
    flutter_framework_license = package_root.parent / "flutter/LICENSE"
    if not matches and flutter_framework_license.is_file():
        matches.append(flutter_framework_license)
    return matches


def cdx_licences(expressions: set[str]) -> list[dict]:
    if not expressions:
        return [{"license": {"name": "NOASSERTION"}}]
    return [{"expression": item} for item in sorted(expressions)]


def package_roots() -> dict[str, Path]:
    config_path = ROOT / ".dart_tool/package_config.json"
    if not config_path.exists():
        raise SystemExit("missing .dart_tool/package_config.json; run flutter pub get first")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    result: dict[str, Path] = {}
    for package in config["packages"]:
        uri = urllib.parse.urlparse(package["rootUri"])
        if uri.scheme == "file":
            result[package["name"]] = Path(urllib.parse.unquote(uri.path))
        else:
            result[package["name"]] = (config_path.parent / package["rootUri"]).resolve()
    return result


def dart_components() -> tuple[list[dict], list[dict]]:
    graph = json.loads(run("dart", "pub", "deps", "--json"))
    roots = package_roots()
    components: list[dict] = []
    dependencies: list[dict] = []
    known = {package["name"] for package in graph["packages"]}
    for package in sorted(graph["packages"], key=lambda item: item["name"]):
        name = package["name"]
        version = package["version"]
        ref = f"pkg:pub/{urllib.parse.quote(name, safe='')}@{urllib.parse.quote(version, safe='.+-')}"
        expressions: set[str] = set()
        evidence: list[str] = []
        for licence in licence_files(roots.get(name, ROOT)):
            expression = licence_expression(licence.read_text(encoding="utf-8", errors="replace"))
            if expression:
                expressions.add(expression)
            evidence.append(licence.name)
        component = {
            "type": "application" if package["kind"] == "root" else "library",
            "bom-ref": ref,
            "name": name,
            "version": version,
            "purl": ref,
            "licenses": cdx_licences(expressions),
            "properties": [
                {"name": "hermes.dependency.kind", "value": package["kind"]},
                {"name": "hermes.dependency.source", "value": package["source"]},
                {"name": "hermes.license.files", "value": ",".join(sorted(evidence)) or "none"},
            ],
        }
        components.append(component)
        depends_on = []
        for dependency in package.get("dependencies", []):
            if dependency not in known:
                continue
            target = next(p for p in graph["packages"] if p["name"] == dependency)
            depends_on.append(
                f"pkg:pub/{urllib.parse.quote(dependency, safe='')}@"
                f"{urllib.parse.quote(target['version'], safe='.+-')}"
            )
        dependencies.append({"ref": ref, "dependsOn": sorted(depends_on)})
    return components, dependencies


def selected_gradle_coordinates(output: str) -> list[tuple[str, str, str]]:
    coordinates: set[tuple[str, str, str]] = set()
    pattern = re.compile(r"--- ([A-Za-z0-9_.-]+):([A-Za-z0-9_.-]+):([^\s()]+)(?: -> ([^\s()]+))?")
    for line in output.splitlines():
        match = pattern.search(line)
        if not match:
            continue
        group, artifact, initial, selected = match.groups()
        version = selected or initial
        if version in {"unspecified", "FAILED"} or version.startswith("{"):
            continue
        coordinates.add((group, artifact, version))
    return sorted(coordinates)


def pom_licences(pom: Path) -> set[str]:
    expressions: set[str] = set()
    try:
        with pom.open("rb") as stream:
            data = stream.read(MAX_POM_BYTES + 1)
        if len(data) > MAX_POM_BYTES:
            raise ValueError("POM exceeds the 2 MiB parser limit")
        # Maven POMs do not need DTDs or entities. Strip NULs in the inspection
        # copy as well so UTF-16/32 declarations cannot bypass the guard.
        declaration_probe = data.upper().replace(b"\x00", b"")
        if b"<!DOCTYPE" in declaration_probe or b"<!ENTITY" in declaration_probe:
            raise ValueError("DTD and ENTITY declarations are not allowed in POMs")
        # ElementTree remains dependency-free and is safe here because input is
        # size-bounded and all DTD/ENTITY declarations were rejected above.
        root = ET.fromstring(data)  # nosemgrep: python.lang.security.use-defused-xml-parse.use-defused-xml-parse
        for element in root.iter():
            if element.tag.rsplit("}", 1)[-1] == "license":
                values = " ".join(child.text or "" for child in element)
                expression = licence_expression(values)
                if expression:
                    expressions.add(expression)
                lower = values.lower()
                if not expression and "apache" in lower and "2.0" in lower:
                    expressions.add("Apache-2.0")
                elif not expression and "eclipse public" in lower and "2.0" in lower:
                    expressions.add("EPL-2.0")
    except (ET.ParseError, OSError, ValueError):
        pass
    return expressions


def curated_maven_licence(group: str, artifact: str) -> tuple[str, str] | None:
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    for rule in catalog["rules"]:
        if "group" in rule and group != rule["group"]:
            continue
        if "groupPrefix" in rule and not group.startswith(rule["groupPrefix"]):
            continue
        if "artifact" in rule and artifact != rule["artifact"]:
            continue
        return rule["license"], rule["evidence"]
    return None


def gradle_module_cache() -> Path:
    """Return Gradle's Maven module cache without making it a source input."""
    gradle_home = os.environ.get("GRADLE_USER_HOME")
    root = Path(gradle_home).expanduser() if gradle_home else Path.home() / ".gradle"
    return root / "caches/modules-2/files-2.1"


def cached_maven_files(
    group: str,
    artifact: str,
    version: str,
    *,
    cache: Path | None = None,
) -> tuple[list[Path], list[Path]]:
    """Return exact cached POMs and runtime AAR/JARs for one coordinate.

    This helper is called only for per-artifact release evidence. The
    checked-in source SBOM deliberately never consults the workstation cache.
    """
    base = (cache or gradle_module_cache()) / group / artifact / version
    if not base.is_dir():
        return [], []
    files = sorted(
        (path for path in base.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(base).as_posix(),
    )
    poms = [path for path in files if path.suffix.lower() == ".pom"]
    binaries = [
        path
        for path in files
        if path.suffix.lower() in {".aar", ".jar"}
        and not re.search(r"-(sources|javadoc)\.(aar|jar)$", path.name)
    ]
    exact = [
        path
        for path in binaries
        if path.stem == f"{artifact}-{version}"
    ]
    return poms, exact or binaries


def gradle_components(
    variant: str,
    *,
    artifact_mode: bool = False,
    cache: Path | None = None,
) -> list[dict]:
    configuration = f"{variant}RuntimeClasspath"
    output = run(
        str(ROOT / "android/gradlew"),
        "-p",
        str(ROOT / "android"),
        ":app:dependencies",
        "--configuration",
        configuration,
        "--console",
        "plain",
    )
    components: list[dict] = []
    for group, artifact, version in selected_gradle_coordinates(output):
        expressions: set[str] = set()
        evidence = "none"
        evidence_kind = "none"
        # The Gradle cache is an implementation detail, not an SBOM input. A
        # warm workstation may contain AAR/JAR files while a clean CI runner
        # has only POM metadata after `:app:dependencies`; using either makes
        # checked-in output vary by machine. Exact coordinates come from the
        # resolved runtime classpath, while reviewed licence evidence comes
        # only from the versioned catalogue below. A new unmatched dependency
        # remains NOASSERTION until its evidence is deliberately reviewed.
        curated = curated_maven_licence(group, artifact)
        if curated:
            expression, evidence = curated
            expressions.add(expression)
            evidence_kind = "curated-catalog"
        poms: list[Path] = []
        binaries: list[Path] = []
        if artifact_mode:
            poms, binaries = cached_maven_files(
                group,
                artifact,
                version,
                cache=cache,
            )
            # The reviewed catalogue is authoritative. Cached POM declarations
            # are a release-evidence fallback only for a previously unmatched
            # coordinate; they never make source output depend on cache warmth.
            if not expressions:
                for pom in poms:
                    expressions.update(pom_licences(pom))
                if expressions:
                    evidence = ",".join(sorted(pom.name for pom in poms))
                    evidence_kind = "cached-pom"
        purl = (
            f"pkg:maven/{urllib.parse.quote(group, safe='.')}/"
            f"{urllib.parse.quote(artifact, safe='')}@{urllib.parse.quote(version, safe='.+-')}"
        )
        properties = [
            {"name": "hermes.gradle.configuration", "value": configuration},
            {"name": "hermes.license.evidence", "value": evidence},
            {"name": "hermes.license.evidenceKind", "value": evidence_kind},
        ]
        binary = binaries[0] if binaries else None
        if artifact_mode:
            properties.extend(
                [
                    {
                        "name": "hermes.gradle.binary",
                        "value": binary.name if binary else "not-in-cache",
                    },
                    {
                        "name": "hermes.gradle.pom",
                        "value": poms[0].name if poms else "not-in-cache",
                    },
                ]
            )
        component: dict = {
            "type": "library",
            "bom-ref": purl,
            "group": group,
            "name": artifact,
            "version": version,
            "purl": purl,
            "licenses": cdx_licences(expressions),
            "properties": properties,
        }
        if binary:
            component["hashes"] = [{"alg": "SHA-256", "content": sha256_file(binary)}]
        components.append(component)
    return components


def asset_licence(path: Path) -> tuple[str, str]:
    relative = path.relative_to(ROOT)
    if relative.parts[:2] == ("assets", "fonts") and (ROOT / "assets/fonts/OFL.txt").is_file():
        return "OFL-1.1", "assets/fonts/OFL.txt"
    if relative.parts[:2] == ("assets", "companions") and len(relative.parts) >= 4:
        manifest = ROOT.joinpath(*relative.parts[:3], "pet.json")
        if manifest.is_file():
            try:
                expression = json.loads(manifest.read_text(encoding="utf-8")).get("license")
                if expression:
                    return str(expression), manifest.relative_to(ROOT).as_posix()
            except (json.JSONDecodeError, OSError):
                pass
    provenance = ROOT / "ASSET_PROVENANCE.md"
    if provenance.is_file():
        identity = provenance.read_text(encoding="utf-8", errors="replace").split(
            "## Local companion sprites", 1
        )[0]
        mentioned = set(re.findall(r"`((?:assets|android)/[^`]+)`", identity))
        relative_text = relative.as_posix()
        if relative_text in mentioned:
            return "GPL-3.0-only", "ASSET_PROVENANCE.md"
        digest_manifest = ROOT / "assets/branding/android-launcher-splash.sha256"
        if digest_manifest.is_file():
            manifest_paths = {
                line.split(maxsplit=1)[1]
                for line in digest_manifest.read_text(encoding="utf-8").splitlines()
                if len(line.split(maxsplit=1)) == 2
            }
            if relative_text in manifest_paths:
                return "GPL-3.0-only", "assets/branding/android-launcher-splash.sha256"
    return "NOASSERTION", "none"


def source_assets() -> list[dict]:
    assets: list[dict] = []
    for path in inventory_asset_paths():
        expression, evidence = asset_licence(path)
        assets.append(
            {
                "path": path.relative_to(ROOT).as_posix(),
                "size": path.stat().st_size,
                "sha256": sha256_file(path),
                "kind": "model" if path.suffix.lower() in MODEL_SUFFIXES else "asset",
                "license": expression,
                "licenseEvidence": evidence,
            }
        )
    return assets


def packaged_license_catalog() -> list[tuple[re.Pattern[str], dict[str, str]]]:
    if (
        not PACKAGED_CATALOG_PATH.is_file()
        or PACKAGED_CATALOG_PATH.is_symlink()
        or PACKAGED_CATALOG_PATH.stat().st_size > MAX_POM_BYTES
    ):
        raise SystemExit("invalid packaged license catalog")
    try:
        value = json.loads(PACKAGED_CATALOG_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit("invalid packaged license catalog") from error
    if not isinstance(value, dict) or set(value) != {"schema", "entries"} or value["schema"] != 1:
        raise SystemExit("invalid packaged license catalog")
    records = value["entries"]
    if not isinstance(records, list) or not records:
        raise SystemExit("invalid packaged license catalog")
    result: list[tuple[re.Pattern[str], dict[str, str]]] = []
    patterns: set[str] = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "pathPattern", "component", "license", "evidence"
        }:
            raise SystemExit("invalid packaged license catalog")
        if any(not isinstance(record[key], str) or not record[key] for key in record):
            raise SystemExit("invalid packaged license catalog")
        pattern = record["pathPattern"]
        evidence = Path(record["evidence"])
        if (
            not pattern.startswith("^")
            or not pattern.endswith("$")
            or pattern in patterns
            or record["license"] == "NOASSERTION"
            or evidence.is_absolute()
            or "." in evidence.parts
            or ".." in evidence.parts
            or not (ROOT / evidence).is_file()
            or (ROOT / evidence).is_symlink()
        ):
            raise SystemExit("invalid packaged license catalog")
        try:
            compiled = re.compile(pattern)
        except re.error as error:
            raise SystemExit("invalid packaged license catalog") from error
        patterns.add(pattern)
        result.append((compiled, record))
    return result


def zip_member_sha256(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> str:
    digest = hashlib.sha256()
    size = 0
    try:
        with archive.open(info, "r") as stream:
            while block := stream.read(
                min(ZIP_READ_CHUNK_BYTES, info.file_size - size + 1)
            ):
                size += len(block)
                if size > info.file_size:
                    raise SystemExit(
                        f"artifact ZIP entry exceeds declared size: {info.filename}"
                    )
                digest.update(block)
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        raise SystemExit(f"invalid artifact ZIP entry: {info.filename}") from error
    if size != info.file_size:
        raise SystemExit(f"artifact ZIP entry size mismatch: {info.filename}")
    return digest.hexdigest()


def artifact_entries(path: Path) -> list[dict]:
    if not path.exists():
        raise SystemExit(f"artifact does not exist: {path}")
    entries: list[dict] = []
    catalog = packaged_license_catalog()
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > MAX_ARTIFACT_ENTRIES:
            raise SystemExit("artifact contains too many ZIP entries")
        if any(info.file_size > MAX_ARTIFACT_MEMBER_BYTES for info in infos):
            raise SystemExit("artifact ZIP entry exceeds the size limit")
        if sum(info.file_size for info in infos) > MAX_ARTIFACT_UNCOMPRESSED_BYTES:
            raise SystemExit("artifact exceeds the uncompressed size limit")
        for info in sorted(infos, key=lambda item: item.filename):
            suffix = Path(info.filename).suffix.lower()
            if suffix not in MODEL_SUFFIXES | BINARY_SUFFIXES:
                continue
            matches = [record for pattern, record in catalog if pattern.fullmatch(info.filename)]
            if len(matches) > 1:
                raise SystemExit(f"ambiguous packaged license evidence: {info.filename}")
            reviewed = matches[0] if matches else None
            entry = {
                "path": info.filename,
                "size": info.file_size,
                "sha256": zip_member_sha256(archive, info),
                "kind": "model" if suffix in MODEL_SUFFIXES else "native-binary",
                "license": reviewed["license"] if reviewed else "NOASSERTION",
                "licenseEvidence": reviewed["evidence"] if reviewed else "none",
            }
            if reviewed:
                entry["reviewedComponent"] = reviewed["component"]
            entries.append(entry)
    return entries


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def component_license_expression(component: dict) -> str:
    values: list[str] = []
    for item in component.get("licenses", []):
        if "expression" in item:
            values.append(item["expression"])
        elif isinstance(item.get("license"), dict):
            value = item["license"].get("id", item["license"].get("name"))
            if value:
                values.append(value)
    return " OR ".join(sorted(values)) if values else "NOASSERTION"


def component_license_evidence(component: dict) -> str:
    properties = {
        item.get("name"): item.get("value")
        for item in component.get("properties", [])
        if isinstance(item, dict)
    }
    return (
        properties.get("hermes.license.evidence")
        or properties.get("hermes.license.files")
        or "none"
    )


def artifact_license_review(
    variant: str,
    input_fingerprint: str,
    source_commit: str,
    components: list[dict],
    assets: list[dict],
    packaged_entries: list[dict],
) -> dict:
    dependency_components = [
        {
            "id": component["bom-ref"],
            "license": component_license_expression(component),
            "evidence": component_license_evidence(component),
        }
        for component in components
    ]
    source_asset_entries = [
        {
            "path": asset["path"],
            "license": asset.get("license", "NOASSERTION"),
            "evidence": asset.get("licenseEvidence", "none"),
        }
        for asset in assets
    ]
    packaged = [
        {
            "path": entry["path"],
            "license": entry.get("license", "NOASSERTION"),
            "evidence": entry.get("licenseEvidence", "none"),
        }
        for entry in packaged_entries
    ]
    unresolved = []
    for category, entries, identity in (
        ("dependency", dependency_components, "id"),
        ("source", source_asset_entries, "path"),
        ("packaged", packaged, "path"),
    ):
        if not entries:
            unresolved.append(f"{category}:empty")
        for entry in entries:
            if entry["license"] == "NOASSERTION" or entry["evidence"] in {"none", "unknown", ""}:
                unresolved.append(f"{category}:{entry[identity]}")
    return {
        "schema": 1,
        "status": "COMPLETE" if not unresolved else "REVIEW_REQUIRED",
        "inputFingerprint": input_fingerprint,
        "sourceCommit": source_commit,
        "dependencyComponents": dependency_components,
        "sourceAssets": source_asset_entries,
        "packagedEntries": packaged,
        "unresolved": sorted(unresolved),
    }


def unresolved_components(components: list[dict]) -> list[str]:
    return sorted(
        component["bom-ref"]
        for component in components
        if component.get("licenses") == [{"license": {"name": "NOASSERTION"}}]
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", choices=("playRelease", "fullRelease"), required=True)
    parser.add_argument("--artifact", type=Path, help="optional signed APK/AAB to inventory")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "sbom")
    args = parser.parse_args()

    commit = os.environ.get("SBOM_GIT_COMMIT") or None
    release_fingerprint = os.environ.get("RELEASE_INPUT_FINGERPRINT")
    if release_fingerprint is not None and re.fullmatch(r"[0-9a-f]{64}", release_fingerprint) is None:
        raise SystemExit("invalid RELEASE_INPUT_FINGERPRINT")
    input_fingerprint = release_fingerprint or fingerprint_inputs()
    timestamp = source_timestamp()
    dart, dependencies = dart_components()
    gradle = gradle_components(args.variant, artifact_mode=args.artifact is not None)
    root_component = next(component for component in dart if component["name"] == "hermes_android")
    components = sorted(dart + gradle, key=lambda component: component["bom-ref"])
    bom = {
        "$schema": SCHEMA,
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": serial_number(args.variant, input_fingerprint, commit),
        "version": 1,
        "metadata": {
            "component": root_component,
            "properties": [
                {"name": "hermes.input.sha256", "value": input_fingerprint},
                {"name": "hermes.android.variant", "value": args.variant},
                {"name": "hermes.generator", "value": "tool/sbom/generate.py"},
            ],
        },
        "components": components,
        "dependencies": dependencies,
    }
    if timestamp:
        bom["metadata"]["timestamp"] = timestamp
    if commit:
        bom["metadata"]["properties"].append(
            {"name": "hermes.git.commit", "value": commit}
        )
    output = args.output_dir.resolve()
    assets = source_assets()
    write_json(output / f"{args.variant}.cdx.json", bom)
    source_inventory: dict = {"inputFingerprint": input_fingerprint, "files": assets}
    if timestamp:
        source_inventory["generated"] = timestamp
    if commit:
        source_inventory["commit"] = commit
    write_json(output / "source-assets.json", source_inventory)
    packaged_entries = artifact_entries(args.artifact.resolve()) if args.artifact else None
    if packaged_entries is None:
        review: dict = {
            "inputFingerprint": input_fingerprint,
            "variant": args.variant,
            "status": "REVIEW_REQUIRED" if unresolved_components(components) else "COMPLETE",
            "unresolvedComponents": unresolved_components(components),
            "unresolvedSourceAssets": sorted(
                asset["path"] for asset in assets if asset["license"] == "NOASSERTION"
            ),
        }
        if timestamp:
            review["generated"] = timestamp
        if commit:
            review["commit"] = commit
    else:
        review = artifact_license_review(
            args.variant,
            input_fingerprint,
            commit or "UNVERIFIED",
            components,
            assets,
            packaged_entries,
        )
    write_json(
        output / f"{args.variant}.license-review.json",
        review,
    )
    if args.artifact:
        artifact = args.artifact.resolve()
        artifact_inventory: dict = {
            "inputFingerprint": input_fingerprint,
            "variant": args.variant,
            "artifact": {
                "name": artifact.name,
                "size": artifact.stat().st_size,
                "sha256": sha256_file(artifact),
            },
            "packagedFiles": packaged_entries,
        }
        if timestamp:
            artifact_inventory["generated"] = timestamp
        if commit:
            artifact_inventory["commit"] = commit
        write_json(
            output / f"{args.variant}.artifact.json",
            artifact_inventory,
        )
    print(f"wrote {args.variant} SBOM: {len(dart)} Dart + {len(gradle)} Gradle components")


if __name__ == "__main__":
    main()
