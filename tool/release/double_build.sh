#!/usr/bin/env bash
# Build twice from clean clones. Never publishes and never writes into the repo.
set -Eeuo pipefail

# Never inherit repository-selection variables from the caller. In particular,
# a shared GIT_INDEX_FILE would make clean-source checks inspect the wrong index.
unset GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE

readonly LOCK_SHA256="f366fdfc011b65c1b3f44e777fc876be21d3492ec3b0b0cf014536c0ac3490c3"
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
[[ "$CHANNEL" == direct-public || "$CHANNEL" == play-private ]] || fail
[[ "$COMMIT" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || fail
[[ "$EXPECTED_CERT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail
[[ -d "$SOURCE_ROOT" && ! -L "$SOURCE_ROOT" ]] || fail
[[ -f "$KEY_PROPERTIES" && ! -L "$KEY_PROPERTIES" ]] || fail
[[ -z "$(git -C "$SOURCE_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || fail
[[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" == "$COMMIT" ]] || fail
[[ "$OUTPUT_ROOT" != "$SOURCE_ROOT" && "$OUTPUT_ROOT" != "$SOURCE_ROOT"/* ]] || fail
[[ ! -e "$OUTPUT_ROOT" ]] || fail
if [[ "$CHANNEL" == play-private ]]; then
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
cleanup() {
  rm -rf -- "$WORK"
  if [[ -e "$STAGING_ROOT" ]]; then
    rm -rf -- "$STAGING_ROOT"
  fi
}
trap cleanup EXIT
chmod 700 -- "$STAGING_ROOT"

build_replica() {
  local replica="$1"
  local clone="$WORK/source-$replica"
  local home="$WORK/home-$replica"
  local pub_cache="$WORK/pub-cache-$replica"
  local gradle_home="$WORK/gradle-$replica"
  local destination="$STAGING_ROOT/replica-$replica"
  mkdir -m 700 -- "$home" "$pub_cache" "$gradle_home" "$destination"
  git clone --no-local --no-hardlinks --recurse-submodules -- "$SOURCE_ROOT" "$clone" >/dev/null
  git -C "$clone" checkout --detach "$COMMIT" >/dev/null
  git -C "$clone" submodule update --init --recursive >/dev/null
  [[ -z "$(git -C "$clone" status --porcelain=v1 --untracked-files=all)" ]]
  printf '%s  %s\n' "$LOCK_SHA256" "$clone/pubspec.lock" | sha256sum --strict -c -
  install -m 600 -- "$KEY_PROPERTIES" "$clone/key.properties"
  local source_epoch
  source_epoch="$(git -C "$clone" show -s --format=%ct HEAD)"
  if [[ "$CHANNEL" == direct-public ]]; then
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
        flutter build apk --release --flavor full --split-per-abi \
          --dart-define=HERMES_FLAVOR=full \
          --dart-define=HERMES_LOCAL_AGENT=true
    )
    install -m 600 -- "$clone"/build/app/outputs/flutter-apk/*-full-release.apk "$destination/"
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
          --dart-define=HERMES_FLAVOR=play \
          --dart-define=HERMES_LOCAL_AGENT=false
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
build_replica b

if [[ "$CHANNEL" == direct-public ]]; then
  python3 "$SCRIPT_ROOT/tool/release/compare_rebuilds.py" \
    --channel direct-public \
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
