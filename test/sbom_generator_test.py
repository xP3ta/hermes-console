import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def properties(component):
    return {item["name"]: item["value"] for item in component["properties"]}


class SbomGeneratorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sbom = load_module(
            "sbom_generator_test_module",
            ROOT / "tool/sbom/generate.py",
        )

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sbom-generator-test-")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def dependency_output(*coordinates):
        return "\n".join(f"+--- {coordinate}" for coordinate in coordinates)

    def write_cached_coordinate(self, coordinate, suffix, licence_text):
        group, artifact, version = coordinate.split(":")
        directory = self.directory / group / artifact / version / "content-hash"
        directory.mkdir(parents=True)
        binary = directory / f"{artifact}-{version}.{suffix}"
        binary.write_bytes(f"{artifact}-{suffix}".encode())
        pom = directory / f"{artifact}-{version}.pom"
        pom.write_text(
            "<project><licenses><license><name>"
            f"{licence_text}</name></license></licenses></project>",
            encoding="utf-8",
        )
        return binary, pom

    def test_source_mode_never_reads_gradle_cache(self):
        output = self.dependency_output("example.invalid:source-only:1.0.0")
        with (
            mock.patch.object(self.sbom, "run", return_value=output),
            mock.patch.object(
                self.sbom,
                "cached_maven_files",
                side_effect=AssertionError("source mode accessed Gradle cache"),
            ) as cached,
        ):
            component = self.sbom.gradle_components("playRelease")[0]

        cached.assert_not_called()
        self.assertNotIn("hashes", component)
        self.assertNotIn("hermes.gradle.binary", properties(component))
        self.assertNotIn("hermes.gradle.pom", properties(component))
        self.assertEqual(
            component["licenses"],
            [{"license": {"name": "NOASSERTION"}}],
        )

    def test_artifact_mode_reports_an_empty_cache_without_guessing(self):
        output = self.dependency_output("example.invalid:cold-cache:1.0.0")
        with mock.patch.object(self.sbom, "run", return_value=output):
            component = self.sbom.gradle_components(
                "playRelease",
                artifact_mode=True,
                cache=self.directory,
            )[0]

        self.assertNotIn("hashes", component)
        self.assertEqual(properties(component)["hermes.gradle.binary"], "not-in-cache")
        self.assertEqual(properties(component)["hermes.gradle.pom"], "not-in-cache")
        self.assertEqual(properties(component)["hermes.license.evidenceKind"], "none")
        self.assertEqual(
            component["licenses"],
            [{"license": {"name": "NOASSERTION"}}],
        )

    def test_artifact_mode_hashes_cached_aar_and_jar_and_falls_back_to_poms(self):
        aar_coordinate = "example.invalid:cached-aar:1.0.0"
        jar_coordinate = "example.invalid:cached-jar:2.0.0"
        aar, aar_pom = self.write_cached_coordinate(
            aar_coordinate,
            "aar",
            "Apache License Version 2.0",
        )
        jar, jar_pom = self.write_cached_coordinate(
            jar_coordinate,
            "jar",
            "MIT License Permission is hereby granted, free of charge",
        )
        output = self.dependency_output(aar_coordinate, jar_coordinate)

        with mock.patch.object(self.sbom, "run", return_value=output):
            components = self.sbom.gradle_components(
                "fullRelease",
                artifact_mode=True,
                cache=self.directory,
            )

        by_name = {component["name"]: component for component in components}
        for name, binary, pom, expression in (
            ("cached-aar", aar, aar_pom, "Apache-2.0"),
            ("cached-jar", jar, jar_pom, "MIT"),
        ):
            with self.subTest(name=name):
                component = by_name[name]
                values = properties(component)
                self.assertEqual(values["hermes.gradle.binary"], binary.name)
                self.assertEqual(values["hermes.gradle.pom"], pom.name)
                self.assertEqual(values["hermes.license.evidence"], pom.name)
                self.assertEqual(values["hermes.license.evidenceKind"], "cached-pom")
                self.assertEqual(component["licenses"], [{"expression": expression}])
                self.assertEqual(
                    component["hashes"],
                    [
                        {
                            "alg": "SHA-256",
                            "content": hashlib.sha256(binary.read_bytes()).hexdigest(),
                        }
                    ],
                )

    def test_artifact_archive_inventory_hashes_aar_and_jar_entries(self):
        artifact = self.directory / "release.aab"
        with zipfile.ZipFile(artifact, "w") as archive:
            archive.writestr("base/root/libs/runtime.aar", b"aar-content")
            archive.writestr("base/root/libs/runtime.jar", b"jar-content")
            archive.writestr("base/root/ignored.txt", b"not-inventory")

        entries = self.sbom.artifact_entries(artifact)

        self.assertEqual(
            [entry["path"] for entry in entries],
            ["base/root/libs/runtime.aar", "base/root/libs/runtime.jar"],
        )
        self.assertTrue(all(entry["sha256"] for entry in entries))
        self.assertTrue(all(entry["kind"] == "native-binary" for entry in entries))

    def test_checked_in_source_sboms_cover_all_153_gradle_coordinates(self):
        coordinate_sets = []
        for variant in ("playRelease", "fullRelease"):
            bom = json.loads((ROOT / f"sbom/{variant}.cdx.json").read_text())
            components = [
                component
                for component in bom["components"]
                if component.get("purl", "").startswith("pkg:maven/")
            ]
            self.assertEqual(len(components), 153, variant)
            self.assertEqual(len({component["bom-ref"] for component in components}), 153)
            for component in components:
                self.assertNotIn("hashes", component)
                self.assertNotIn("hermes.gradle.binary", properties(component))
                self.assertNotIn("hermes.gradle.pom", properties(component))
            coordinate_sets.append({component["bom-ref"] for component in components})
        self.assertEqual(coordinate_sets[0], coordinate_sets[1])

    def test_journeyapps_catalog_evidence_points_to_copying(self):
        catalog = json.loads((ROOT / "tool/sbom/maven-license-catalog.json").read_text())
        rule = next(rule for rule in catalog["rules"] if rule.get("group") == "com.journeyapps")
        self.assertEqual(
            rule["evidence"],
            "https://github.com/journeyapps/zxing-android-embedded/blob/master/COPYING",
        )


if __name__ == "__main__":
    unittest.main()
