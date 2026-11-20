#!/usr/bin/env bash
# Prints the Dart test files of one CI shard, one per line.
#
#   tool/ci/test_shard.sh <index> <total>     files of shard <index> (0-based)
#   tool/ci/test_shard.sh all                 every file the shards cover
#
# Why: the whole suite in one job takes about two and a half hours. The files
# are dealt to the shards largest first, so each shard gets a similar share
# of the big files, and the order depends only on the tree (size, then path):
# every job computes the same split from the same commit.
#
# test/chat_screen_test.dart is left out on purpose: alone it is about a
# quarter of the suite, so the workflow runs it in jobs of its own, split by
# test (`flutter test --total-shards`). test/ci_test_shards_test.py checks
# that the shards, plus that file, are exactly the test files in the tree.
set -Eeuo pipefail

cd "$(dirname "$0")/../.."

readonly SPLIT_BY_TEST='test/chat_screen_test.dart'

files() {
  find test -type f -name '*_test.dart' ! -path "$SPLIT_BY_TEST" -printf '%s\t%p\n' \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 \
    | cut -f2
}

if [ "${1:-}" = "all" ] && [ "$#" -eq 1 ]; then
  files
  exit 0
fi

index="${1:-}"
total="${2:-}"
case "$index$total" in
  '' | *[!0-9]*)
    echo "usage: $0 <index> <total> | all" >&2
    exit 64
    ;;
esac
if [ "$#" -ne 2 ] || [ "$total" -lt 1 ] || [ "$index" -ge "$total" ]; then
  echo "usage: $0 <index> <total> | all" >&2
  exit 64
fi

files | awk -v n="$total" -v i="$index" '(NR - 1) % n == i'
