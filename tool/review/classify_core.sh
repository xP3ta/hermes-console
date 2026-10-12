#!/usr/bin/env bash
# Print the files changed between BASE and HEAD that match a glob in
# tool/review/core_paths.txt. Exit 0 always; empty output means the
# change does not touch a core path.
#
# Usage: tool/review/classify_core.sh <base-ref> [head-ref]
set -euo pipefail

base="${1:?usage: classify_core.sh <base-ref> [head-ref]}"
head="${2:-HEAD}"
root="$(git rev-parse --show-toplevel)"
list="$root/tool/review/core_paths.txt"

mapfile -t globs < <(grep -vE '^[[:space:]]*(#|$)' "$list")

git diff --name-only "$base...$head" | while IFS= read -r path; do
  for glob in "${globs[@]}"; do
    # shellcheck disable=SC2053 # intentional glob match
    if [[ "$path" == $glob ]]; then
      printf '%s\n' "$path"
      break
    fi
  done
done
