#!/usr/bin/env bash
# Fails unless the repository's .gitleaks.toml still detects a GitHub token.
#
# Why: the config once defined allowlists without `[extend] useDefault = true`,
# so gitleaks loaded zero rules and every CI scan passed while checking nothing.
# A clean scan only means something if this canary is caught first. The test/
# canaries prove the path-scoped allowlists for synthetic test fixtures do not
# blanket-ignore that folder: a GitHub token and a random generic API key there
# must both still be reported.
#
# Usage:
#   tool/security/gitleaks_canary.sh                    # gitleaks from PATH (or $GITLEAKS)
#   GITLEAKS_IMAGE=zricethezav/gitleaks@sha256:... tool/security/gitleaks_canary.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-canary.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/scan/test" "$work/out"
# The scanner may run as an unprivileged user inside a container.
chmod 0755 "$work" "$work/scan" "$work/scan/test"
chmod 0777 "$work/out"

# Same discovery as CI: gitleaks picks up .gitleaks.toml from the scanned root.
cp "$repo_root/.gitleaks.toml" "$work/scan/.gitleaks.toml"

# Built at run time so no token-shaped literal is ever committed.
random_alnum() {
  python3 -c 'import secrets, string, sys
print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(int(sys.argv[1]))))' "$1"
}
token="ghp""_$(random_alnum 36)"
api_key="$(random_alnum 32)"
printf 'GITHUB_TOKEN=%s\n' "$token" >"$work/scan/canary.env"
printf "const token = '%s';\nconst apiKey = '%s';\n" "$token" "$api_key" \
  >"$work/scan/test/canary_test.dart"
chmod 0644 "$work/scan/.gitleaks.toml" "$work/scan/canary.env" "$work/scan/test/canary_test.dart"

# Scan "." from inside the root so reported paths are repo-relative
# (test/...), exactly what the path-scoped allowlists are matched against.
if [[ -n "${GITLEAKS_IMAGE:-}" ]]; then
  run=(docker run --rm -v "$work/scan:/scan:ro" -v "$work/out:/out" -w /scan "$GITLEAKS_IMAGE")
  out=/out
else
  run=("${GITLEAKS:-gitleaks}")
  out="$work/out"
fi

set +e
(cd "$work/scan" && "${run[@]}" dir . --no-banner --redact=100 --exit-code 3 \
  --report-format json --report-path "$out/report.json")
rc=$?
set -e

if [[ "$rc" -ne 3 ]]; then
  echo "gitleaks canary: expected exit 3 (leaks found), got $rc." >&2
  echo "The repository config no longer detects a GitHub token." >&2
  exit 1
fi

python3 - "$work/out/report.json" <<'PY'
import json
import sys

findings = json.load(open(sys.argv[1], encoding="utf-8"))
caught = {
    (f.get("RuleID"), f["File"].replace("\\", "/").removeprefix("./"))
    for f in findings
}
expected = {
    ("github-pat", "canary.env"),
    ("github-pat", "test/canary_test.dart"),
    ("generic-api-key", "test/canary_test.dart"),
}
missing = sorted(expected - caught)
if missing:
    sys.exit(f"gitleaks canary: not reported {missing}; got {sorted(caught)}")
print("gitleaks canary: detected", sorted(expected))
PY
