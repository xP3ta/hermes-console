#!/usr/bin/env bash
# Refreshes the test-only copy of Hermes' published gateway wire contract.
#
# Usage: tool/contract/update_contract.sh [HERMES_AGENT_CHECKOUT]
#   default checkout: $HERMES_AGENT_DIR or ~/.hermes/hermes-agent
#
# The contract is generated upstream from tui_gateway/contracts by
# scripts/gen_gateway_contracts.py. Only a committed blob is vendored: a dirty
# upstream working copy is refused so SOURCE always names reproducible bytes.
# The copy lives under test/fixtures and is never packaged into the app.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SRC_REL="apps/shared/src/gateway-contract.openrpc.json"
readonly DEST_DIR="$ROOT/test/fixtures/contract"
readonly CHECKOUT="${1:-${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}}"

if ! git -C "$CHECKOUT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: $CHECKOUT is not a git checkout of hermes-agent" >&2
  exit 1
fi
if [[ -n "$(git -C "$CHECKOUT" status --porcelain -- "$SRC_REL")" ]]; then
  echo "error: $SRC_REL has uncommitted changes in $CHECKOUT" >&2
  exit 1
fi

commit="$(git -C "$CHECKOUT" rev-parse HEAD)"
blob_commit="$(git -C "$CHECKOUT" log -1 --format=%H -- "$SRC_REL")"
tmp="$(mktemp "${TMPDIR:-/tmp}/gateway-contract.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
git -C "$CHECKOUT" show "HEAD:$SRC_REL" >"$tmp"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert "x-notifications" in c and "x-server-requests" in c' "$tmp"
sha="$(sha256sum "$tmp" | cut -d' ' -f1)"

mkdir -p "$DEST_DIR"
mv "$tmp" "$DEST_DIR/gateway-contract.openrpc.json"
trap - EXIT
cat >"$DEST_DIR/SOURCE" <<SOURCE
repository: https://github.com/NousResearch/hermes-agent
path: $SRC_REL
checkout_commit: $commit
contract_last_changed_commit: $blob_commit
sha256: $sha
license: MIT (Copyright (c) 2025 Nous Research)
SOURCE
echo "vendored $SRC_REL @ $commit (sha256 $sha)"
