#!/usr/bin/env bash
# Validate one bound double-build output and stage its selected AAB privately.
set -Eeuo pipefail

# Keep source binding pinned to SOURCE_ROOT even in a contaminated parent shell.
unset GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'ERROR: private Play staging failed.\n' >&2
  exit 1
}
trap fail ERR

[[ $# -eq 4 ]] || fail
readonly SOURCE_ROOT="$1"
readonly DOUBLE_BUILD_ROOT="$2"
readonly EXPECTED_SIGNER_SHA256="${3,,}"
readonly DESTINATION="$4"
readonly SOURCE_CANONICAL="$(readlink -e -- "$SOURCE_ROOT")"
readonly DOUBLE_BUILD_CANONICAL="$(readlink -e -- "$DOUBLE_BUILD_ROOT")"
readonly DESTINATION_CANONICAL="$(readlink -m -- "$DESTINATION")"
readonly DESTINATION_NAME="$(basename -- "$DESTINATION_CANONICAL")"
readonly DOUBLE_BUILD_MANIFEST="$DOUBLE_BUILD_CANONICAL/double-build-manifest.json"
readonly FIRST_AAB="$DOUBLE_BUILD_CANONICAL/replica-a/app-play-release.aab"
readonly SECOND_AAB="$DOUBLE_BUILD_CANONICAL/replica-b/app-play-release.aab"
readonly ORIGINAL_COMPARISON="$DOUBLE_BUILD_CANONICAL/rebuild-comparison.json"

[[ -d "$SOURCE_CANONICAL" && ! -L "$SOURCE_ROOT" ]] || fail
[[ -d "$DOUBLE_BUILD_CANONICAL" && ! -L "$DOUBLE_BUILD_ROOT" ]] || fail
[[ -f "$DOUBLE_BUILD_MANIFEST" && ! -L "$DOUBLE_BUILD_MANIFEST" ]] || fail
[[ -f "$FIRST_AAB" && ! -L "$FIRST_AAB" ]] || fail
[[ -f "$SECOND_AAB" && ! -L "$SECOND_AAB" ]] || fail
[[ -f "$ORIGINAL_COMPARISON" && ! -L "$ORIGINAL_COMPARISON" ]] || fail
[[ "$EXPECTED_SIGNER_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail
[[ "${DESTINATION_NAME,,}" == *private* ]] || fail
[[ "$DESTINATION_CANONICAL" != "$SOURCE_CANONICAL"/* ]] || fail
[[ "$DESTINATION_CANONICAL" != "$DOUBLE_BUILD_CANONICAL"/* ]] || fail
IFS=/ read -r -a destination_parts <<< "$DESTINATION_CANONICAL"
for part in "${destination_parts[@]}"; do
  [[ "${part,,}" != *public* ]] || fail
done
[[ ! -e "$DESTINATION_CANONICAL" ]] || fail

: "${ANDROID_SDK_ROOT:?pinned Android SDK root required}"
: "${JAVA_HOME:?pinned JDK root required}"
readonly TOOL_POLICY="$SOURCE_CANONICAL/tool/release/release_contract.json"
[[ -f "$TOOL_POLICY" && ! -L "$TOOL_POLICY" ]] || fail

umask 077
readonly PARENT="$(dirname -- "$DESTINATION_CANONICAL")"
mkdir -p -- "$PARENT"
readonly WORK="$(mktemp -d "$PARENT/.play-private.XXXXXX")"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
chmod 700 "$WORK"

python3 "$ROOT/tool/release/compare_rebuilds.py" \
  --channel play-private \
  --first "$FIRST_AAB" \
  --second "$SECOND_AAB" \
  --output "$WORK/rebuild-comparison.json" >/dev/null
cmp -s -- "$WORK/rebuild-comparison.json" "$ORIGINAL_COMPARISON"

readonly FIRST_SHA256="$(sha256sum -- "$FIRST_AAB" | cut -d ' ' -f 1)"
readonly SECOND_SHA256="$(sha256sum -- "$SECOND_AAB" | cut -d ' ' -f 1)"
python3 "$ROOT/tool/release/inspect_play_aab.py" \
  --artifact "$FIRST_AAB" \
  --pubspec "$SOURCE_CANONICAL/pubspec.yaml" \
  --policy "$TOOL_POLICY" \
  --expected-sha256 "$FIRST_SHA256" \
  --expected-signer-sha256 "$EXPECTED_SIGNER_SHA256" \
  --android-sdk-root "$ANDROID_SDK_ROOT" \
  --jdk-root "$JAVA_HOME" \
  --output "$WORK/play-aab-facts.json" >/dev/null
python3 "$ROOT/tool/release/inspect_play_aab.py" \
  --artifact "$SECOND_AAB" \
  --pubspec "$SOURCE_CANONICAL/pubspec.yaml" \
  --policy "$TOOL_POLICY" \
  --expected-sha256 "$SECOND_SHA256" \
  --expected-signer-sha256 "$EXPECTED_SIGNER_SHA256" \
  --android-sdk-root "$ANDROID_SDK_ROOT" \
  --jdk-root "$JAVA_HOME" \
  --output "$WORK/second-play-aab-facts.json" >/dev/null

python3 "$ROOT/tool/release/play_build_binding.py" write \
  --root "$SOURCE_CANONICAL" \
  --artifact "$FIRST_AAB" \
  --double-build-manifest "$DOUBLE_BUILD_MANIFEST" \
  --binding "$WORK/build-binding.json" >/dev/null
install -m 600 -- "$FIRST_AAB" "$WORK/app-play-release.aab"
install -m 600 -- "$DOUBLE_BUILD_MANIFEST" "$WORK/double-build-manifest.json"
rm -- "$WORK/second-play-aab-facts.json"
(
  cd "$WORK"
  sha256sum \
    app-play-release.aab \
    build-binding.json \
    double-build-manifest.json \
    play-aab-facts.json \
    rebuild-comparison.json > SHA256SUMS
  chmod 600 SHA256SUMS
  [[ $(wc -l < SHA256SUMS) -eq 5 ]]
  sha256sum --strict --status -c SHA256SUMS
  [[ $(find . -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 6 ]]
)
mv -- "$WORK" "$DESTINATION_CANONICAL"
trap - EXIT
chmod 700 "$DESTINATION_CANONICAL"
trap - ERR
printf 'Play AAB staged in the owner-private lane; no publication performed.\n'
