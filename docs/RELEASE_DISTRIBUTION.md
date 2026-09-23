# Release and distribution

Hermes Console has three Android flavors built from one reviewed source commit.
A flavor name is a security boundary, not a rename operation.

| Lane | Flavor | Accepted artifact | Visibility |
|---|---|---|---|
| Google Play | `play` | signed release AAB | owner-private only |
| GitHub Releases / Obtainium | `full` | three signed split release APKs | public only in the approved publication |
| Emulator QA | `qa` | profile/debug APK | internal only; never public or release evidence |

The reviewed executable policy is `tool/release/release_contract.json`. The
source lock is `pubspec.lock` with SHA-256
`f366fdfc011b65c1b3f44e777fc876be21d3492ec3b0b0cf014536c0ac3490c3`.
Changing a lock, signer, authorized source actor or inspection-tool digest
requires a normal source review; release scripts never rewrite those values.
The reviewed contract anchors both channel signer certificates, all public and
Play inspection-tool digests, and the GitHub CLI verifier digest.

## Public-repository CI is verification-only

GitHub Actions artifacts are public-repository downloads for readers of this
repository. They must never carry a signed APK, AAB, keystore, mapping, private
comparison result, or pre-publication candidate. Cross-job artifact transfer is
therefore prohibited for release candidates.

`.github/workflows/build-apk.yml` is CI verification only. It checks the exact
tag/commit, authorized forge actor, lock, checked-in SBOMs, licenses, scanners,
analysis and tests. It has read-only repository permissions, receives no signing
secret, builds no signed candidate, creates no attestation, and invokes no
artifact upload/download action. Successful CI is not a build, staging,
publication or Play upload result.

Sensitive building, comparison and staging stay on one owner-controlled machine
and an owner-controlled local/private filesystem. No helper in this repository
uploads or publishes anything. A separate publication operation is permitted
only after explicit owner approval for the exact channel and exact bytes.

## Reviewed source and signer continuity

The source identity gate requires GitHub verification and binds both the forge
`authorLogin` and `committerLogin` to the reviewed `xP3ta` allowlist. A valid
signature from an unlisted actor is rejected.

Direct APK signing continuity is anchored to the prior public release rather
than to caller input alone:

- baseline tag: `v1.2.9`;
- baseline asset: `app-arm64-v8a-full-release.apk`;
- asset SHA-256: `f5187dbc57caa881ca3f21453335df320e271d7358e81e6095e6d9af50a9f734`;
- certificate SHA-256: `86edaa150fabd33d8184f5b958400cabadacb49632f7ec50ecbe49608058d159`.

The direct inspector requires the supplied expectation to equal that reviewed
record and then independently measures every candidate with `apksigner`.
Changing both a key and a runtime argument cannot bypass the baseline.

## Private local double build

On GNU/Linux x86-64, export explicit SDK/JDK discovery before invoking the gate:

```bash
export ANDROID_HOME=/absolute/path/to/android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME=/absolute/path/to/jdk
export PATH=/absolute/path/to/flutter/bin:$PATH

bash tool/release/double_build.sh \
  direct-public /absolute/path/to/clean/source COMMIT \
  /absolute/private/key.properties \
  /absolute/private/direct-output \
  86edaa150fabd33d8184f5b958400cabadacb49632f7ec50ecbe49608058d159
```

The script verifies required commands, preserves Android/JDK discovery through
its clean environment, and gives each replica an isolated `HOME`, `PUB_CACHE`
and `GRADLE_USER_HOME`. It builds into a mode-0700 temporary sibling of the
requested output and atomically renames that sibling only after both builds and
the comparison pass. Before promotion, the same build step writes the canonical
`double-build-manifest.json`: exact source/input identities, build command,
expected signer input, resolved build-tool paths and pre-build hashes (required
unchanged after both replicas), both replicas' artifact names/sizes/hashes, and
the comparison-report hash. Public/Play binding helpers consume that manifest
and reject artifacts not recorded as replica A. The manifest and generated
source binding remain maintainer-only and are excluded from the public evidence
archive. Any failure removes the temporary stage and leaves no output directory
or signed residue.

This manifest is a deterministic local causal record from the orchestrated
build, not cryptographic provenance. A principal that can replace the build
script, tools, artifacts and manifest on the owner machine remains outside this
control; external trust and attestation are separate gates.

Dependency inputs are not all cryptographically pinned: the Gradle distribution
has no `distributionSha256Sum`, Gradle/Maven verification metadata and locks are
absent, and Android packages are not content-pinned as a complete dependency
set. Equal APK output is only an observed two-build byte identity, not a general reproducible-build claim.
Play comparison similarly reports observed byte, ZIP-entry and
functional-payload relationships without claiming rebuildability by unrelated
builders.

## Play inspection and private staging

Play AABs never enter the public directory or GitHub Actions. Build and compare
them in the local private lane, then run:

```bash
bash tool/release/stage_play_private.sh \
  /absolute/path/to/clean/source \
  /absolute/private/double-build-output \
  EXPECTED_UPLOAD_CERTIFICATE_SHA256 \
  /absolute/private/play-candidate
```

The signer argument is not authority: it must equal the `play-private`
certificate SHA-256 anchored in `release_contract.json`. The current reviewed
contract requires the Play upload key to match the existing direct-release
certificate identity; a private signed AAB must confirm that identity before
release. Changing either lane requires a source-policy review.

`stage_play_private.sh` resolves `apkanalyzer` only below
`ANDROID_SDK_ROOT` and `jarsigner`/`keytool` only below `JAVA_HOME`. Paths and
SHA-256 digests are independently pinned in the reviewed source policy; caller
selected executable variables are ignored. The current policy anchors Android
command-line tools 12.0 and Debian OpenJDK 21 tool bytes on `linux-x86_64`.
The staging helper accepts the double-build output directory, not caller-chosen
AAB paths. It validates the fixed manifest, replicas, source, comparison and
captured build-tool hashes before selecting replica A. Package, version,
artifact hash and upload-certificate hash are measured for both AABs. A changed
artifact, manifest, source or fake tool fails before it can assert metadata.

The destination basename must contain `private`, no path component may contain
`public`, and promotion is atomic. The resulting AAB, double-build manifest and
four other evidence files remain local/private. The helper performs no Play or
external upload.

## SBOM and native-license evidence

`tool/sbom/packaged-license-catalog.json` is the reviewed path-to-component
catalog for packaged Flutter/native binaries. Entries are anchored by closed,
ABI-specific path patterns, SPDX expressions and repository evidence paths.
Unknown or overlapping paths remain `NOASSERTION` and force `REVIEW_REQUIRED`;
there is no blanket native-binary allow or suppression. Standard `libapp.so`,
Flutter engine and reviewed sherpa/ONNX/whisper native paths can reach
`COMPLETE` through this explicit evidence.

The catalog and generator are part of the SBOM input fingerprint. All five
checked-in `sbom/*.json` outputs must be regenerated when either changes. CI
regenerates them and rejects any diff.

Evidence tar validation caps compressed size before opening, iterates at most
128 headers in streaming mode, and caps individual and total uncompressed
content before retaining allowed evidence bytes. Duplicate, linked, traversal,
extra and malformed members fail closed.

## Eventual public allowlist

After all private gates and explicit owner publication approval, the final
public release may contain exactly these six basenames:

- `SHA256SUMS`
- `app-arm64-v8a-full-release.apk`
- `app-armeabi-v7a-full-release.apk`
- `app-x86_64-full-release.apk`
- `hermes-console-release-evidence.tar.gz`
- `provenance.intoto.jsonl`

No AAB, QA/debug/profile APK, mapping, log, keystore or diagnostic bundle is
allowed. `tool/release/validate_public_assets.sh` rejects missing files, extras,
links, directories, checksum drift, signer drift and stale evidence. For the final
gate it copies the allowlisted files into a private snapshot, runs every
cryptographic, structural and APK-evidence check against that one snapshot,
then revalidates and byte-compares the source directory before success.

The final validation command takes only release identity and a runtime manifest
for the reviewed public inspection toolchain; policy, expectations, signer,
executable hashes, Android companion runtime trees and the JDK binary/library
trees are always loaded from the reviewed source. Inspection runs with the
anchored JDK selected through a scrubbed environment:

```bash
python3 tool/release/record_trusted_toolchain.py \
  --root /absolute/path/to/reviewed/android-sdk \
  --jdk-root /absolute/path/to/reviewed/jdk \
  --output /absolute/private/trusted-public-toolchain.json
bash tool/release/validate_public_assets.sh \
  /absolute/private/release-public \
  v1.2.10 EXACT_RELEASE_COMMIT \
  /absolute/private/trusted-public-toolchain.json
```

`provenance.intoto.jsonl` is the keyless GitHub/Sigstore bundle for the exact
four subjects (three APKs plus evidence archive). Because obtaining that bundle
is external attestation, it belongs to the later owner-authorized publication
operation, not pre-publication CI or this hardening patch. It must be verified
cryptographically with `gh attestation verify` before the structural
`verify_slsa_bundle.py` check. A structurally valid unsigned envelope is not
provenance. The final validator performs both checks on the same bundle and
fails closed unless the reviewed GitHub CLI 2.98.0 binary digest is present.
It constrains repository, signer workflow, certificate identity, OIDC issuer,
tag ref, source commit, SLSA predicate, hosted runner and all four subject
digests. It validates only and never publishes or uploads.

## Operator gate

1. Select one exact reviewed tag/commit and require a clean tree.
2. Pass verification-only CI and local security/policy tests.
3. Build twice in the intended local/private channel with the intended key.
4. Require package, version, ABI/flavor, signer, hash, source binding, SBOM and
   license review to pass; keep all candidate bytes private.
5. Install and smoke-test the exact selected channel artifact.
6. Obtain explicit owner approval for the exact channel and bytes.
7. Only in that approved publication operation, produce/verify provenance and
   publish the exact six-file direct allowlist, or upload only the private AAB to
   Play. Never substitute `full`, `play` or `qa` artifacts across lanes.
