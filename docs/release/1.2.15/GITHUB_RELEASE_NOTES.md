## Console 1.2.15

Console no longer needs the Mobile Bridge. It talks to Hermes' own Gateway and
Dashboard, and the new first run is: scan a code, confirm, you are on Home.

**What is new**

- A chat that shows Hermes' work in plain words, like Hermes Desktop, with an
  island at the top that speaks up only when something needs you.
- Voice conversations inside the chat; the on-device recogniser is ready when you
  tap.
- A Home board of sized widgets (Now, Chats, Bots, Rooms, Cron, Tasks) that
  never scrolls.
- A plain tap dock, one identity per profile, and a floating app pet.
- Models: edit the fallback chain and remove a provider completely.
- Calmer notifications and launcher widgets that stay current.
- A floating, translucent look in every theme, light and dark.

**Connecting**

Run one line on the computer where Hermes lives and scan the code it shows (see
the [README](https://github.com/xP3ta/hermes-console#connect)).
The current setup helper needs Console 1.2.15 or newer.

**Coming from a bridge-era install?** The app cleans up its side on the first
launch. When every phone is on 1.2.15, remove the bridge from the computer with
the helper's `--retire-bridge` line (Windows: `-RetireBridge`).

Full list of changes: [CHANGELOG](https://github.com/xP3ta/hermes-console/blob/main/CHANGELOG.md#1215-9540--2026-10-12).

**Installing:** Android 7.0 or newer. These APKs are the signed `full` release,
one per CPU architecture (most phones need `arm64-v8a`); verify the SHA-256 and
signing certificate before installing. Google Play and GitHub/Obtainium builds
are signed with different keys: stay on one channel.
