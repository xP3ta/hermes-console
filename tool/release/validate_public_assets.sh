#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly POLICY="$ROOT/tool/release/release_contract.json"
readonly EXPECTED_ASSETS=(
  SHA256SUMS
  app-arm64-v8a-full-release.apk
  app-armeabi-v7a-full-release.apk
  app-x86_64-full-release.apk
  hermes-console-release-evidence.tar.gz
  provenance.intoto.jsonl
)
readonly CHECKSUMMED_ASSETS=(
  app-arm64-v8a-full-release.apk
  app-armeabi-v7a-full-release.apk
  app-x86_64-full-release.apk
  hermes-console-release-evidence.tar.gz
  provenance.intoto.jsonl
)
readonly PRIVATE_METADATA_PATTERN='(/home/[A-Za-z0-9_.-]+|/Users/[A-Za-z0-9_.-]+|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+|/root/|(^|[^0-9])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)|(^|[^0-9])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)|(^|[^0-9])172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$))'

VALIDATION_DIRECTORY=""
SCAN_DIRECTORY=""
cleanup() {
  if [[ -n "$VALIDATION_DIRECTORY" ]]; then
    rm -rf -- "$VALIDATION_DIRECTORY"
    VALIDATION_DIRECTORY=""
  fi
  if [[ -n "$SCAN_DIRECTORY" ]]; then
    rm -rf -- "$SCAN_DIRECTORY"
    SCAN_DIRECTORY=""
  fi
}
fail() {
  trap - ERR
  cleanup
  printf 'ERROR: public release asset validation failed.\n' >&2
  exit 1
}
trap fail ERR

scan_private_metadata() {
  local label="$1"
  local matches
  if matches="$(LC_ALL=C grep -aEn "$PRIVATE_METADATA_PATTERN")"; then
    while IFS= read -r match; do
      printf 'ERROR: private path or IP in %s:%s\n' "$label" "$match" >&2
    done <<< "$matches"
    return 1
  fi
}

scan_public_metadata() {
  local archive="hermes-console-release-evidence.tar.gz"
  local path
  local relative
  scan_private_metadata "SHA256SUMS" < SHA256SUMS
  scan_private_metadata "provenance.intoto.jsonl" < provenance.intoto.jsonl
  tar -tzf "$archive" | scan_private_metadata "$archive member list"
  SCAN_DIRECTORY="$(mktemp -d /tmp/hermes-public-metadata.XXXXXXXX)"
  chmod 0700 "$SCAN_DIRECTORY"
  tar -xzf "$archive" -C "$SCAN_DIRECTORY" --no-same-owner --no-same-permissions
  while IFS= read -r -d '' path; do
    relative="${path#"$SCAN_DIRECTORY"/}"
    scan_private_metadata "$archive:$relative" < "$path"
  done < <(find "$SCAN_DIRECTORY" -type f -print0)
  rm -rf -- "$SCAN_DIRECTORY"
  SCAN_DIRECTORY=""
}

validate_asset_directory() {
  local directory="$1"
  [[ -d "$directory" && ! -L "$directory" ]]
  (
    cd "$directory"
    mapfile -d '' entries < <(find . -mindepth 1 -maxdepth 1 -printf '%f\0' | LC_ALL=C sort -z)
    [[ ${#entries[@]} -eq ${#EXPECTED_ASSETS[@]} ]]
    for index in "${!EXPECTED_ASSETS[@]}"; do
      [[ "${entries[$index]}" == "${EXPECTED_ASSETS[$index]}" ]]
      [[ -f "${entries[$index]}" && ! -L "${entries[$index]}" ]]
    done
    [[ $(wc -l < SHA256SUMS) -eq ${#CHECKSUMMED_ASSETS[@]} ]]
    for expected in "${CHECKSUMMED_ASSETS[@]}"; do
      awk -v expected="$expected" '
        $0 ~ /^[0-9a-f]{64}  [A-Za-z0-9._-]+$/ && $2 == expected { matches++ }
        END { exit matches == 1 ? 0 : 1 }
      ' SHA256SUMS
    done
    sha256sum --strict --status -c SHA256SUMS
    python3 "$ROOT/tool/release/validate_evidence_archive.py" \
      hermes-console-release-evidence.tar.gz
    scan_public_metadata
  )
}

[[ $# -eq 2 || $# -eq 4 ]] || fail
readonly PUBLIC_DIRECTORY="$1"
validate_asset_directory "$PUBLIC_DIRECTORY"

if [[ "$2" == "--assets-only" ]]; then
  [[ $# -eq 2 ]] || fail
else
  [[ $# -eq 4 ]] || fail
  readonly RELEASE_TAG="$2"
  readonly RELEASE_COMMIT="${3,,}"
  readonly TRUSTED_TOOLCHAIN="$4"
  [[ "$RELEASE_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail
  [[ "$RELEASE_COMMIT" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || fail

  VALIDATION_DIRECTORY="$(mktemp -d /tmp/hermes-public-validation.XXXXXXXX)"
  chmod 0700 "$VALIDATION_DIRECTORY"
  for expected in "${EXPECTED_ASSETS[@]}"; do
    cp --no-dereference --preserve=mode,timestamps -- \
      "$PUBLIC_DIRECTORY/$expected" "$VALIDATION_DIRECTORY/$expected"
  done
  validate_asset_directory "$VALIDATION_DIRECTORY"

  python3 "$ROOT/tool/release/verify_public_provenance.py" \
    --bundle "$VALIDATION_DIRECTORY/provenance.intoto.jsonl" \
    --asset-directory "$VALIDATION_DIRECTORY" \
    --policy "$POLICY" \
    --tag "$RELEASE_TAG" \
    --commit "$RELEASE_COMMIT"

  [[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ]]
  readonly SOURCE_COMMIT="$(git -C "$ROOT" rev-parse "HEAD^{commit}")"
  readonly TAG_COMMIT="$(git -C "$ROOT" rev-parse "refs/tags/$RELEASE_TAG^{commit}")"
  [[ "$SOURCE_COMMIT" == "$RELEASE_COMMIT" ]]
  [[ "$TAG_COMMIT" == "$RELEASE_COMMIT" ]]

  python3 "$ROOT/tool/release/verify_slsa_bundle.py" \
    --bundle "$VALIDATION_DIRECTORY/provenance.intoto.jsonl" \
    --asset-directory "$VALIDATION_DIRECTORY" \
    --policy "$POLICY" \
    --tag "$RELEASE_TAG" \
    --commit "$RELEASE_COMMIT"
  python3 "$ROOT/tool/release/validate_public_apk_provenance.py" \
    --archive "$VALIDATION_DIRECTORY/hermes-console-release-evidence.tar.gz" \
    --asset-directory "$VALIDATION_DIRECTORY" \
    --trusted-toolchain "$TRUSTED_TOOLCHAIN"

  validate_asset_directory "$PUBLIC_DIRECTORY"
  for expected in "${EXPECTED_ASSETS[@]}"; do
    cmp -- "$PUBLIC_DIRECTORY/$expected" "$VALIDATION_DIRECTORY/$expected"
  done
fi

trap - ERR
cleanup
printf 'Public release asset validation passed; no publication performed.\n'
