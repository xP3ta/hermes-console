# Public screenshots and media

`1.2.15/` is the public screenshot set of Console 1.2.15: dark theme (the
app's default look), English, 1080x2400 portrait, fixed 09:41 clock, full
battery, no notifications. `1.2.10-9008/` is the previous set and stays until
the README, the website and `ASSET_PROVENANCE.md` stop pointing at it.

| File | Screen |
|---|---|
| `home.png`, `home-light.png` | Home board: Now, Bots, Rooms, Cron, the dock, the floating pet |
| `chat.png`, `chat-light.png` | A finished turn: activity line, table, code block |
| `chat-live.png` | A live turn: reasoning, tool, task list |
| `voice.png` | Voice conversation inside a chat (strip, status line, End) |
| `bots.png`, `room.png` | Team roster with faces; a Room |
| `tasks-board.png`, `tasks-list.png` | Kanban board and list |
| `cron.png` | Scheduled tasks |
| `models.png` | Providers and models |
| `tools.png`, `terminal.png` | Tools hub; SSH terminal |
| `documents.png` | PDF viewer (the fictional Aurora brief) |
| `first-run.png`, `first-run-code.png` | Welcome; "Get the code on your computer" |
| `profile-editor.png` | Profile identity (faces, silhouettes) |

Play listing images are derived from these, never re-captured:
`docs/store/feature-graphic.png` (1024x500), `docs/store/play/phone/` (the
phone shots padded to 9:16 with the page colour, nothing stretched or
cropped), `docs/store/play/tablet-7/` (1920x1080) and
`docs/store/play/tablet-10/` (2560x1440), both landscape 16:9, where the app
shows its rail and list/detail layout.

## How they were captured

Real app, QA flavour, on the isolated emulator (`hermes-qa-api35`), never a
phone and never a real Hermes. Everything the app shows comes from a fictional
"Project Aurora" fixture. Nothing here talks to a private network.

```bash
# 1. QA build for the emulator (x86_64 profile, QA flavour, from a clean export)
systemd-run --user --wait --collect --pipe -q -p CPUQuota=500% -p MemoryMax=10G -p Nice=10 \
  tool/qa/build_emulator_x64.sh <sha> <build-number>
# 2. Fictional Hermes (gateway 18642, dashboard 19119; never the real 8642/9119)
dart run tool/qa/aurora_fixture_server.dart
# 3. Scripted SSH host for the terminal shot (needs asyncssh in a throw-away venv)
python tool/qa/aurora_ssh_server.py --port 2222
# 4. Emulator: 1080x2400, gesture navigation, demo status bar (09:41, full battery)
tool/qa/aurora_emulator_setup.sh emulator-5580
# 5. Pair by hand: Connect manually, 10.0.2.2:18642, key `aurora-demo-token`,
#    dashboard port 19119, then pick the profile "nova" in Tools > Profiles.
```

Fixture control (loopback only): `/__aurora/hold` keeps the next live turn open
so it can be photographed, `/__aurora/release` finishes it, `/__aurora/clock`
aligns its clock with the emulator, `/__aurora/unknown` lists anything the
fixture did not know. Do not move the emulator clock back after the app has
created its secure storage: sending a message then fails (Keystore).

Tablet shots: `adb shell wm size 1920x1080` + `wm density 180` (7") and
`2560x1440` at 180 (10"), then restart the app; reset with `wm size reset` and
`wm density reset`.

The emulator renders through the host GPU (Xvfb + `-gpu host`); blur and
translucency match a phone. Voice on the emulator has no microphone signal, so
the meter in "End" is idle.

## Rules for new media

- captured from the isolated emulator with the fictional dataset;
- English-only visual copy;
- no pairing QR/link, token, host, private address, device name or notification;
- reviewed at full resolution before being versioned;
- authorized by the owner for its stated public surface.

The first-run "Get the code" screen shows the app's own public helper command;
it is the only URL in the set.
