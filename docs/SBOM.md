# Software Bill of Materials (SBOM)

Hermes Console publishes a source SBOM for both Android distribution variants.
The generator resolves exact versions from `pubspec.lock` and from each Gradle
release runtime classpath; it does not infer dependency versions from source
imports or from a previously built APK.

## Generate the source inventories

Requirements: Flutter/Dart, JDK 17, Python 3 and the checked-in Gradle wrapper.
No signing key is required to resolve a release runtime classpath.

```bash
flutter pub get
./tool/sbom/generate.sh
```

This writes:

- `sbom/playRelease.cdx.json`: Dart packages and the Play release Gradle graph.
- `sbom/fullRelease.cdx.json`: Dart packages and the Full release Gradle graph.
- `sbom/source-assets.json`: checksums for model, native, font and visual assets.
- `sbom/*Release.license-review.json`: the explicit unresolved licence queue.

The CycloneDX files contain package URLs and exact versions from the resolved
runtime classpath. Dart licence evidence comes from package licence files;
Gradle licence evidence comes from reviewed mappings in
`tool/sbom/maven-license-catalog.json`. Every curated mapping includes its SPDX
identifier and a public evidence URL. The generator deliberately ignores the
machine's Gradle cache: cached POMs and AAR/JAR files differ between a clean CI
runner and a warm workstation and are therefore not reproducible source-SBOM
inputs. Explicit `NOASSERTION` entries remain when a new coordinate has not yet
been reviewed; they are a review queue, not an approval to redistribute it.

The checked-in output is deterministic for the same relevant inputs: lockfile,
package manifest, Gradle configuration, assets, provenance and the curated
licence catalogue. Each output records their combined SHA-256 as
`inputFingerprint`. Generated SBOM files and Git metadata are excluded from
that fingerprint, avoiding the impossible requirement that an SBOM predict the
commit that will contain itself. Absolute workstation paths are never written.

Checked-in inventories omit commit and timestamp metadata. For a release
artifact, CI should inject both explicitly:

```bash
SBOM_GIT_COMMIT="$(git rev-parse HEAD)" \
SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)" \
python3 tool/sbom/generate.py \
  --variant playRelease \
  --artifact build/app/outputs/bundle/playRelease/app-play-release.aab
```

`SBOM_GIT_COMMIT` and `SOURCE_DATE_EPOCH` are never inferred automatically.

## Inventory a signed APK or AAB

Pass exactly one release artifact to the matching variant command. This adds a
second JSON file with the artifact checksum and every packaged `.so`, AAR, JAR
and model file checksum. Artifact mode also records the exact name and SHA-256
of each resolved dependency's primary AAR/JAR when it is present in Gradle's
module cache. If a coordinate has no reviewed catalogue entry, its cached POM
may provide licence evidence as a fallback. These cache-derived fields are
release evidence only and are never used by the deterministic checked-in
source SBOM:

```bash
python3 tool/sbom/generate.py \
  --variant playRelease \
  --artifact build/app/outputs/bundle/playRelease/app-play-release.aab
```

Run the equivalent command with `fullRelease` for the direct-download build.
The short `generate.sh` convenience command is intended for source inventories;
do not pass a variant-specific artifact to it because it generates both
variants.

The release lane writes each split APK inventory to a separate local/private
directory so no ABI overwrites another. It archives those inventories with
`SHA256SUMS` and signing-certificate reports. Checked-in SBOMs describe source
only; generated artifact evidence never uses a GitHub Actions artifact before
publication approval.

Packaged native binaries are resolved only through the reviewed
`tool/sbom/packaged-license-catalog.json`. Its ABI-specific path patterns bind a
component and SPDX expression to a repository evidence file. Unknown or
ambiguous paths remain `NOASSERTION`; there is no global native-binary waiver.

## Release review gate

Before publishing a binary:

1. Generate both source SBOMs from a clean clone at the release commit.
2. Generate the matching artifact inventory after the signed build.
3. Compare its top-level SHA-256 with the artifact selected for publication.
4. Review every `NOASSERTION`, especially native libraries and model assets.
5. Reconcile all redistributable components with `THIRD_PARTY_NOTICES.md`.
6. Run a secret scan over both the working tree and the repository history.
7. Archive the SBOM and artifact inventory beside the release artifact.

The SBOM is factual dependency evidence. It is not legal advice and does not
replace review of trademarks, training-data terms, binary SDK terms, or the
compatibility of third-party licences with `GPL-3.0-only`.
