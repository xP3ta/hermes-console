#!/usr/bin/env bash
# Regenerates the goldens of the launcher widget pictures, and only those
# (test/goldens/launcher_widgets/), then the contact sheets for review.
#
#   tool/qa/launcher_widget_goldens.sh            # goldens + sheets
#   tool/qa/launcher_widget_goldens.sh --check    # compare only, no update
#
# The versioned goldens are made without extra fonts, as the gate runs them
# (Japanese, Chinese and emoji then draw as the test font's boxes). For the
# contact sheets, give a CJK and an emoji font so those scripts are measured
# with real glyphs:
#   LW_EXTRA_FONTS="cjk=/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc:emoji=/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "${1:-}" == "--check" ]]; then
  env -u LW_EXTRA_FONTS flutter test test/launcher_widget_golden_test.dart
  exit
fi
env -u LW_EXTRA_FONTS flutter test --update-goldens test/launcher_widget_golden_test.dart
LW_EVIDENCE=1 flutter test test/launcher_widget_evidence_test.dart
echo "goldens: test/goldens/launcher_widgets/   sheets: build/lw-sheets/"
