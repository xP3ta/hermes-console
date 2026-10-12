#!/usr/bin/env bash
# QA flavour, x86_64 PROFILE APK for the emulator, from a clean export of a commit.
# Own build root (media-1215); never a release/signing config. Usage: build_x64.sh <sha> <build-number>
# Run it under:
#   systemd-run --user --wait --collect --pipe -q -p CPUQuota=500% -p MemoryMax=10G -p Nice=10 build_x64.sh <sha> <n>
set -euo pipefail
exec 9>"${AURORA_BUILD_LOCK:-/tmp/aurora-build.lock}"; flock 9
REPO="$(git rev-parse --show-toplevel)"
B="${AURORA_BUILD_ROOT:-$HOME/aurora-build}"
sha=$(git -C "$REPO" rev-parse "$1"); num=$2
out="$B/out/HermesConsole-QA-x64-$num-${sha:0:7}.apk"
mkdir -p "$B/tmp" "$B/out"
rm -rf "$B/src"; mkdir "$B/src"
git -C "$REPO" archive "$sha" | tar -x -C "$B/src"
cd "$B/src"
export PATH=${FLUTTER_ROOT:-$HOME/flutter}/bin:$PATH
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}" ANDROID_SDK_ROOT="${ANDROID_HOME:-$HOME/Android/Sdk}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}" TMPDIR="$B/tmp"
( while sleep 15; do
    free_mb=$(df --output=avail -BM /home | tail -1 | tr -dc 0-9)
    if [ "$free_mb" -lt 3000 ]; then echo "DISK_GUARD: ${free_mb} MB free, stopping" >&2; pkill -TERM -P $$ -f '[f]lutter' || true; exit 0; fi
  done ) &
guard=$!; trap 'kill $guard 2>/dev/null || true' EXIT
flutter pub get --offline >"$B/out/pub-$num.log" 2>&1
flutter build apk --profile --flavor qa --build-number "$num" --target-platform android-x64 >"$B/out/build-$num.log" 2>&1
cp build/app/outputs/flutter-apk/app-qa-profile.apk "$out"
sha256sum "$out"; echo "BUILD_OK sha=$sha number=$num size=$(stat -c %s "$out")"; df -h /home | tail -1
