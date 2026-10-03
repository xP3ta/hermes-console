#!/usr/bin/env bash
# Real-gateway E2E lane, local and CI.
#
# Builds a throwaway Hermes from a pinned public commit (or a local checkout
# given in HERMES_SRC), starts `hermes serve` + the API server against
# Hermes' own scripted loopback model provider in an isolated HOME, runs
# test/e2e_real_gateway with the real Console gateway client, and removes
# everything it created.
#
# Never touches ~/.hermes: HOME and HERMES_HOME point into a fresh temp dir,
# no provider key exists (the model is a loopback fake) and the child env is
# an allowlist.
#
# Usage: tool/e2e/run_local.sh [extra flutter test args]
# Env:
#   HERMES_REF   commit to test against (default: tool/e2e/hermes_pin)
#   HERMES_SRC   reuse an existing Hermes checkout instead of cloning
#                (copied, never modified)
#   KEEP_E2E=1   keep the temp dir (logs) after the run
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

pin_file="tool/e2e/hermes_pin"
hermes_repo="$(sed -n 's/^repo=//p' "$pin_file")"
hermes_ref="${HERMES_REF:-$(sed -n 's/^commit=//p' "$pin_file")}"
python_version="$(sed -n 's/^python=//p' "$pin_file")"
[[ "$hermes_ref" =~ ^[0-9a-f]{40}$ ]] || {
  echo "HERMES_REF must be a full commit sha, got '$hermes_ref'" >&2
  exit 2
}

for tool in uv git flutter python3; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 2; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/hermes-ci-e2e.XXXXXX")"
backend_pid=""
# Every process of this lane carries this marker in its environment (backend.py
# keeps it in the children's allowlist); tool/e2e/reap.py kills them by it.
lane_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
# shellcheck disable=SC2317 # invoked through the trap
cleanup() {
  local status=$?
  trap '' INT TERM
  # The backend tears its children down in KILL_BUDGET_S (8 s); give it 10 s,
  # then reap whatever is left of the lane (its process groups included, also
  # after an abnormal backend exit) in at most 10 s more.
  if [[ -n "$backend_pid" ]] && kill -0 "$backend_pid" 2>/dev/null; then
    kill -TERM "$backend_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$backend_pid" 2>/dev/null || break
      sleep 0.5
    done
  fi
  if [[ -n "$backend_pid" ]]; then
    if ! python3 tool/e2e/reap.py --marker "$lane_id" \
      --pgid-file "$work/run/children.pgid" --budget 10; then
      echo "lane teardown left processes behind" >&2
      [[ $status -ne 0 ]] || status=1
    fi
    wait "$backend_pid" 2>/dev/null || true
  fi
  if [[ $status -ne 0 && -d "$work/run" ]]; then
    for log in backend.log serve.stderr.log gateway.log; do
      [[ -f "$work/run/$log" ]] || continue
      echo "──── $log (tail) ────"
      tail -n 40 "$work/run/$log" | sed -E 's/(TOKEN|KEY|PASSWORD|SECRET)=[^ ]+/\1=***/g'
    done
  fi
  if [[ "${KEEP_E2E:-0}" == "1" ]]; then
    echo "kept $work"
  else
    rm -rf "$work"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

echo "▶ Hermes $hermes_repo @ $hermes_ref"
src="$work/hermes"
if [[ -n "${HERMES_SRC:-}" ]]; then
  git clone --quiet --no-checkout "$HERMES_SRC" "$src"
else
  git clone --quiet --filter=blob:none --no-checkout "$hermes_repo" "$src"
fi
git -C "$src" -c advice.detachedHead=false checkout --quiet "$hermes_ref"
test "$(git -C "$src" rev-parse HEAD)" == "$hermes_ref"

echo "▶ locked Hermes venv (python $python_version)"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$work/uv-cache}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$work/uv-python}"
(cd "$src" && uv sync --quiet --locked --no-dev --extra sms --python "$python_version")

echo "▶ backend"
mkdir -p "$work/run"
HERMES_E2E_LANE="$lane_id" "$src/.venv/bin/python" tool/e2e/backend.py --root "$work/run" --src "$src" --timeout 240 \
  >"$work/run/backend.log" 2>&1 &
backend_pid=$!
for _ in $(seq 1 1000); do
  [[ -f "$work/run/backend.env" ]] && break
  kill -0 "$backend_pid" 2>/dev/null || { echo "backend died" >&2; exit 1; }
  sleep 0.5
done
[[ -f "$work/run/backend.env" ]] || { echo "backend not ready" >&2; exit 1; }
cat "$work/run/backend.log"
set -a
# shellcheck disable=SC1091
. "$work/run/backend.env"
set +a

echo "▶ flutter test test/e2e_real_gateway"
set +e
flutter test --concurrency=1 --reporter=expanded test/e2e_real_gateway "$@" \
  2>&1 | tee "$work/flutter.log"
status="${PIPESTATUS[0]}"
set -e
echo "▶ budgets"
grep -h '^\[e2e-budget\]' "$work/flutter.log" || true
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Real-gateway E2E (Hermes \`${hermes_ref:0:12}\`)"
    echo '```'
    grep -h '^\[e2e-budget\]' "$work/flutter.log" || true
    tail -n 3 "$work/flutter.log"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$status"
