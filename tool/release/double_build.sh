#!/usr/bin/env bash
# Build twice from clean clones. Never publishes and never writes into the repo.
# Both replicas build one after the other at ONE canonical absolute path
# ($WORK/build: source, HOME, PUB_CACHE, GRADLE_USER_HOME), recreated empty from
# a fresh clone for each replica. $WORK is a fresh temporary directory per run:
# the path is shared by the two replicas of that run, not a fixed published path.
# Absolute build paths end up inside native
# libraries and the Dart snapshot, so equality is claimed only for builds made
# at that same path; the root is verified empty before replica B starts.
set -Eeuo pipefail

# Never inherit repository-selection variables from the caller. In particular,
# a shared GIT_INDEX_FILE would make clean-source checks inspect the wrong index.
unset GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE

readonly LOCK_SHA256="48d6da0ead3f18dc1aa599fdfe314b5ff7825fa834653e5aacd94322300cbe35"
readonly SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'ERROR: clean double-build gate failed.\n' >&2
  exit 1
}
trap fail ERR

[[ $# -eq 6 ]] || fail
readonly CHANNEL="$1"
readonly SOURCE_ROOT="$(readlink -e -- "$2")"
readonly COMMIT="$3"
readonly KEY_PROPERTIES="$(readlink -e -- "$4")"
readonly OUTPUT_ROOT="$(readlink -m -- "$5")"
readonly EXPECTED_CERT_SHA256="${6,,}"
[[ "$CHANNEL" == direct-public || "$CHANNEL" == direct-universal || "$CHANNEL" == play-private ]] || fail
[[ "$COMMIT" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || fail
[[ "$EXPECTED_CERT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail
[[ -d "$SOURCE_ROOT" && ! -L "$SOURCE_ROOT" ]] || fail
[[ -f "$KEY_PROPERTIES" && ! -L "$KEY_PROPERTIES" ]] || fail
[[ -z "$(git -C "$SOURCE_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || fail
[[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" == "$COMMIT" ]] || fail
[[ "$OUTPUT_ROOT" != "$SOURCE_ROOT" && "$OUTPUT_ROOT" != "$SOURCE_ROOT"/* ]] || fail
[[ ! -e "$OUTPUT_ROOT" ]] || fail
if [[ "$CHANNEL" == play-private || "$CHANNEL" == direct-universal ]]; then
  [[ "${OUTPUT_ROOT,,}" == *private* && "${OUTPUT_ROOT,,}" != *public* ]] || fail
fi

for tool in flutter git python3 java sha256sum install mktemp mv; do
  command -v "$tool" >/dev/null
done
readonly CLEAN_ANDROID_HOME="${ANDROID_HOME-}"
readonly CLEAN_ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT-}"
if [[ -n "${JAVA_HOME-}" ]]; then
  CLEAN_JAVA_HOME="$JAVA_HOME"
else
  CLEAN_JAVA_HOME="$(dirname -- "$(dirname -- "$(readlink -e -- "$(command -v java)")")")"
fi
readonly CLEAN_JAVA_HOME
[[ -n "$CLEAN_ANDROID_HOME" || -n "$CLEAN_ANDROID_SDK_ROOT" ]] || fail
[[ -n "$CLEAN_JAVA_HOME" ]] || fail
readonly WORK="$(mktemp -d "${TMPDIR:-/tmp}/hermes-double-build.XXXXXX")"
umask 077
readonly OUTPUT_PARENT="$(dirname -- "$OUTPUT_ROOT")"
mkdir -p -- "$OUTPUT_PARENT"
readonly STAGING_ROOT="$(mktemp -d "$OUTPUT_PARENT/.double-build.XXXXXX")"
# Where a failed comparison's report is kept (no signed bytes: names, sizes,
# hashes and the difference class), beside the output that was not created.
readonly FAILED_REPORT="$OUTPUT_ROOT.failed-rebuild-comparison.json"
cleanup() {
  # A comparison that ran and failed keeps its report; never an artifact.
  if [[ -f "$STAGING_ROOT/rebuild-comparison.json" && ! -e "$OUTPUT_ROOT" \
        && ! -e "$FAILED_REPORT" ]]; then
    install -m 600 -- "$STAGING_ROOT/rebuild-comparison.json" "$FAILED_REPORT" || true
  fi
  # The stage may hold signed artifacts: it goes first, whatever happens to
  # the work tree. A Gradle daemon still writing under WORK made `rm` fail
  # there and, under errexit, kept the stage (1.4.1 build).
  if [[ -e "$STAGING_ROOT" ]]; then
    rm -rf -- "$STAGING_ROOT" || true
    if [[ -e "$STAGING_ROOT" ]]; then
      printf 'WARNING: unpromoted stage left at %s; remove it.\n' "$STAGING_ROOT" >&2
    fi
  fi
  release_replica
  rm -rf -- "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
chmod 700 -- "$STAGING_ROOT"

# The one canonical root both replicas build in, one after the other.
readonly BUILD_ROOT="$WORK/build"

# Stops the current replica's Gradle daemon (its own GRADLE_USER_HOME) and
# frees the canonical root. Once its artifact is staged nothing reads the tree
# again, so the next replica builds with the disk and memory the first one
# held: two full trees at once ran the build host out of disk in the 1.4.1 run.
release_replica() {
  # Only a replica whose Gradle daemon started: on an early failure the
  # wrapper would otherwise fetch a distribution just to stop nothing.
  if [[ -x "$BUILD_ROOT/source/android/gradlew" && -d "$BUILD_ROOT/gradle/daemon" ]]; then
    (
      cd "$BUILD_ROOT/source/android"
      env -i PATH="$PATH" HOME="$BUILD_ROOT/home" \
        GRADLE_USER_HOME="$BUILD_ROOT/gradle" JAVA_HOME="$CLEAN_JAVA_HOME" \
        ./gradlew --stop
    ) >/dev/null 2>&1 || true
  fi
  rm -rf -- "$BUILD_ROOT" 2>/dev/null || true
}

build_replica() {
  local replica="$1"
  # Independent builds at the same path: the root must be gone before each one.
  [[ ! -e "$BUILD_ROOT" ]]
  local clone="$BUILD_ROOT/source"
  local home="$BUILD_ROOT/home"
  local pub_cache="$BUILD_ROOT/pub-cache"
  local gradle_home="$BUILD_ROOT/gradle"
  local destination="$STAGING_ROOT/replica-$replica"
  mkdir -m 700 -- "$BUILD_ROOT"
  mkdir -m 700 -- "$home" "$pub_cache" "$gradle_home" "$destination"
  git clone --no-local --no-hardlinks --recurse-submodules -- "$SOURCE_ROOT" "$clone" >/dev/null
  git -C "$clone" checkout --detach "$COMMIT" >/dev/null
  git -C "$clone" submodule update --init --recursive >/dev/null
  [[ -z "$(git -C "$clone" status --porcelain=v1 --untracked-files=all)" ]]
  printf '%s  %s\n' "$LOCK_SHA256" "$clone/pubspec.lock" | sha256sum --strict -c -
  install -m 600 -- "$KEY_PROPERTIES" "$clone/key.properties"
  local source_epoch
  source_epoch="$(git -C "$clone" show -s --format=%ct HEAD)"
  if [[ "$CHANNEL" == direct-public || "$CHANNEL" == direct-universal ]]; then
    # direct-public: three split APKs; direct-universal: one APK with all ABIs
    # (versionCode = build number), the shape 1.4.0 shipped.
    local split=()
    if [[ "$CHANNEL" == direct-public ]]; then split=(--split-per-abi); fi
    (
      cd "$clone"
      env -i PATH="$PATH" HOME="$home" PUB_CACHE="$pub_cache" \
        GRADLE_USER_HOME="$gradle_home" SOURCE_DATE_EPOCH="$source_epoch" \
        ANDROID_HOME="$CLEAN_ANDROID_HOME" \
        ANDROID_SDK_ROOT="$CLEAN_ANDROID_SDK_ROOT" JAVA_HOME="$CLEAN_JAVA_HOME" \
        flutter pub get --enforce-lockfile
      env -i PATH="$PATH" HOME="$home" PUB_CACHE="$pub_cache" \
        GRADLE_USER_HOME="$gradle_home" SOURCE_DATE_EPOCH="$source_epoch" \
        ANDROID_HOME="$CLEAN_ANDROID_HOME" \
        ANDROID_SDK_ROOT="$CLEAN_ANDROID_SDK_ROOT" JAVA_HOME="$CLEAN_JAVA_HOME" \
        flutter build apk --release --flavor full "${split[@]}" \
          --dart-define=HERMES_FLAVOR=full
    )
    if [[ "$CHANNEL" == direct-public ]]; then
      install -m 600 -- "$clone"/build/app/outputs/flutter-apk/*-full-release.apk "$destination/"
    else
      install -m 600 -- \
        "$clone/build/app/outputs/flutter-apk/app-full-release.apk" \
        "$destination/app-full-release.apk"
    fi
  else
    (
      cd "$clone"
      env -i PATH="$PATH" HOME="$home" PUB_CACHE="$pub_cache" \
        GRADLE_USER_HOME="$gradle_home" SOURCE_DATE_EPOCH="$source_epoch" \
        ANDROID_HOME="$CLEAN_ANDROID_HOME" \
        ANDROID_SDK_ROOT="$CLEAN_ANDROID_SDK_ROOT" JAVA_HOME="$CLEAN_JAVA_HOME" \
        flutter pub get --enforce-lockfile
      env -i PATH="$PATH" HOME="$home" PUB_CACHE="$pub_cache" \
        GRADLE_USER_HOME="$gradle_home" SOURCE_DATE_EPOCH="$source_epoch" \
        ANDROID_HOME="$CLEAN_ANDROID_HOME" \
        ANDROID_SDK_ROOT="$CLEAN_ANDROID_SDK_ROOT" JAVA_HOME="$CLEAN_JAVA_HOME" \
        flutter build appbundle --release --flavor play \
          --dart-define=HERMES_FLAVOR=play
    )
    install -m 600 -- \
      "$clone/build/app/outputs/bundle/playRelease/app-play-release.aab" \
      "$destination/app-play-release.aab"
  fi
  rm -f -- "$clone/key.properties"
}

manifest_tools=()
manifest_tool_hashes=()
for tool in flutter git python3 java sha256sum install mktemp mv; do
  tool_path="$(command -v "$tool")"
  tool_resolved="$(readlink -e -- "$tool_path")"
  tool_digest="$(sha256sum -- "$tool_resolved")"
  tool_digest="${tool_digest%% *}"
  manifest_tools+=(--tool "$tool=$tool_resolved")
  manifest_tool_hashes+=(--expected-tool-sha "$tool=$tool_digest")
done

build_replica a
release_replica
build_replica b
release_replica

if [[ "$CHANNEL" == direct-public || "$CHANNEL" == direct-universal ]]; then
  python3 "$SCRIPT_ROOT/tool/release/compare_rebuilds.py" \
    --channel "$CHANNEL" \
    --first "$STAGING_ROOT/replica-a" \
    --second "$STAGING_ROOT/replica-b" \
    --output "$STAGING_ROOT/rebuild-comparison.json"
else
  python3 "$SCRIPT_ROOT/tool/release/compare_rebuilds.py" \
    --channel play-private \
    --first "$STAGING_ROOT/replica-a/app-play-release.aab" \
    --second "$STAGING_ROOT/replica-b/app-play-release.aab" \
    --output "$STAGING_ROOT/rebuild-comparison.json"
fi
chmod 600 "$STAGING_ROOT/rebuild-comparison.json"
python3 "$SCRIPT_ROOT/tool/release/double_build_manifest.py" write \
  --root "$SOURCE_ROOT" \
  --channel "$CHANNEL" \
  --first "$STAGING_ROOT/replica-a" \
  --second "$STAGING_ROOT/replica-b" \
  --comparison "$STAGING_ROOT/rebuild-comparison.json" \
  --expected-signer-sha256 "$EXPECTED_CERT_SHA256" \
  --android-home "$CLEAN_ANDROID_HOME" \
  --android-sdk-root "$CLEAN_ANDROID_SDK_ROOT" \
  --java-home "$CLEAN_JAVA_HOME" \
  "${manifest_tools[@]}" \
  "${manifest_tool_hashes[@]}" \
  --output "$STAGING_ROOT/double-build-manifest.json"
chmod 600 "$STAGING_ROOT/double-build-manifest.json"
mv -- "$STAGING_ROOT" "$OUTPUT_ROOT"
trap - ERR
printf 'Clean double-build completed outside the repository; no publication performed.\n'
