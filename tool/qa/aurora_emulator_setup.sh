#!/usr/bin/env bash
# Prepare the isolated QA emulator for the public screenshot set.
#
#   tool/qa/aurora_emulator_setup.sh [serial]     (default: emulator-5580)
#
# Refuses anything that is not an emulator. Sets a 1080x2400 portrait screen,
# gesture navigation, English locale-neutral demo status bar (full battery,
# no notifications, fixed 09:41), dark mode and a fixed device clock. The
# device clock is moved to 09:41 so the times the app prints (chat list, Cron,
# Kanban) agree with the status bar; pair it with the fixture's clock:
#   curl "http://127.0.0.1:19119/__aurora/clock?epoch=$(adb -s SERIAL shell date +%s)"
set -Eeuo pipefail

SERIAL="${1:-emulator-5580}"
ADB="${ADB_BIN:-adb}"
[[ "$SERIAL" == emulator-* ]] || { echo "refusing: $SERIAL is not an emulator" >&2; exit 1; }
a() { "$ADB" -s "$SERIAL" "$@"; }
[[ "$(a shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]] || { echo "refusing: not qemu" >&2; exit 1; }

a root >/dev/null 2>&1 || true
sleep 3
a shell wm size 1080x2400
a shell wm density 420
a shell svc power stayon true
a shell input keyevent KEYCODE_WAKEUP
a shell wm dismiss-keyguard
a shell cmd overlay enable com.android.internal.systemui.navbar.gestural
a shell cmd uimode night yes

# Fixed clock: today, 09:41 (UTC), automatic time off.
a shell settings put global auto_time 0
a shell settings put global auto_time_zone 0
a shell setprop persist.sys.timezone UTC
a shell service call alarm 3 s16 UTC >/dev/null 2>&1 || true
a shell date "$(date -u +%m%d)0941$(date -u +%Y).00" >/dev/null

# Clean status bar (demo mode).
a shell settings put global sysui_demo_allowed 1
d() { a shell am broadcast -a com.android.systemui.demo "$@" >/dev/null; }
d -e command enter
d -e command clock -e hhmm 0941
d -e command battery -e level 100 -e plugged false
d -e command network -e wifi show -e level 4 -e fully true
d -e command network -e mobile hide
d -e command notifications -e visible false
d -e command status -e vpn hide
echo "ready: $(a shell wm size | tr -d '\r' | tail -1), clock $(a shell date | tr -d '\r')"
