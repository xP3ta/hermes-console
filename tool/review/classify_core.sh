#!/usr/bin/env bash
# Print the files changed between BASE and HEAD that need the core Console
# reviewer. A file is core when either:
#   - its path matches a glob in tool/review/core_paths.txt, or
#   - it is under lib/ and a changed line (added or removed) matches a
#     regex in tool/review/core_content.txt (local persistence, drafts,
#     outbox, secure storage), whatever the file is called.
# Exit 0 always; empty output means the change does not touch core.
#
# Usage: tool/review/classify_core.sh <base-ref> [head-ref]
set -euo pipefail

base="${1:?usage: classify_core.sh <base-ref> [head-ref]}"
head="${2:-HEAD}"
root="$(git rev-parse --show-toplevel)"
list="$root/tool/review/core_paths.txt"
content="$root/tool/review/core_content.txt"

mapfile -t globs < <(grep -vE '^[[:space:]]*(#|$)' "$list")
pattern=""
if [[ -f "$content" ]]; then
  pattern="$(grep -vE '^[[:space:]]*(#|$)' "$content" | paste -sd'|' -)"
fi

git diff --name-only "$base...$head" | while IFS= read -r path; do
  for glob in "${globs[@]}"; do
    # shellcheck disable=SC2053 # intentional glob match
    if [[ "$path" == $glob ]]; then
      printf '%s\n' "$path"
      continue 2
    fi
  done
  if [[ -n "$pattern" && "$path" == lib/* ]] &&
    git diff "$base...$head" -- "$path" |
    grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' |
    grep -qE "$pattern"; then
    printf '%s\n' "$path"
  fi
done
