#!/bin/sh
# Regenerates lib/core/browser/hermes_preview_engine.g.dart from a hermes-agent
# checkout: Hermes Desktop's injectable act engine (actEngineSource()) and
# overlay (watchInPage), as Desktop stringifies them, plus WATCH_TAG, with
# Console's privacy patch (render_preview_engine.py).
#
#   tool/browser/generate_preview_engine.sh /path/to/hermes-agent
#
# Needs node and the checkout's own esbuild (node_modules installed there).
# Nothing is written inside the checkout.
set -eu
AGENT="${1:?usage: $0 /path/to/hermes-agent}"
SRC="$AGENT/apps/desktop/src/lib/preview-act"
ESBUILD="$AGENT/node_modules/.bin/esbuild"
OUT="$(cd "$(dirname "$0")/../.." && pwd)/lib/core/browser/hermes_preview_engine.g.dart"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/entry.ts" <<TS
import { actEngineSource } from '$SRC/act-in-page'
import { watchInPage } from '$SRC/watch-in-page'
const watch = watchInPage.toString()
let hash = 5381
for (let i = 0; i < watch.length; i++) { hash = ((hash << 5) + hash + watch.charCodeAt(i)) | 0 }
process.stdout.write(JSON.stringify({ engine: actEngineSource(), watch, watchTag: hash }))
TS
"$ESBUILD" "$WORK/entry.ts" --bundle --platform=node --format=esm \
  --target=es2019 --outfile="$WORK/out.mjs" --log-level=warning
node "$WORK/out.mjs" > "$WORK/engine.json"
COMMIT="$(git -C "$AGENT" rev-parse HEAD)"
python3 -I "$(dirname "$0")/render_preview_engine.py" "$WORK/engine.json" "$COMMIT" "$OUT"
echo "wrote $OUT"
