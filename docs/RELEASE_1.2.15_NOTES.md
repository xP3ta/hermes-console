# Console 1.2.15 — release notes

Release build: `1.2.15+9540` (2026-10-12). Public comparison base: `v1.2.14`.
The complete list of changes is in [CHANGELOG.md](../CHANGELOG.md); this page
is the short version for people deciding whether and how to update.

## The headline

**Console no longer needs the Mobile Bridge.** It talks to the two services of
Hermes itself, the Gateway and the Dashboard, and a new first run is "scan a
code and you are on Home". Everything else in this release is about making
Console read like Hermes Desktop and feel calmer.

## What you will notice

- **A first run that takes a minute.** The Console mark draws itself, you tap
  **Scan code**, confirm in plain words what it is about to connect, and land on
  Home. The connection screen explains what is reachable and what is not.
- **A chat that shows the work.** Reasoning, tools and tasks appear in the
  conversation in plain words, with a timer, and fold into one quiet line when
  the turn ends. A small island at the top names the profile and speaks up only
  when something needs you.
- **Voice inside the chat.** Status above the composer; pause, end and the
  contextual button in the composer; you can keep typing. The on-device
  recogniser is loaded ahead of time for people who talk to the phone.
- **Home as a board.** Now, Chats, Bots, Rooms, Cron and Tasks, each in three
  sizes, on a screen that never scrolls. Plan limits name their provider.
- **One identity per profile.** A pet, an image or a face, in the colour its
  owner chose, the same everywhere. The floating app pet appears on the screens
  that carry the dock.
- **A plain dock.** A tap goes where it says. No gestures, no automatic hiding;
  a hidden dock always has a visible handle to bring it back.
- **Models you can really edit.** Pick models from lists, edit the fallback
  chain, and remove a provider completely.
- **Calmer notifications.** A live row for a running turn with Stop, approvals
  and replies from the notification, plain rows for jobs and tasks with "Mute".
- **Launcher widgets that stay current.** Now, Quick chat, Cron, Bots, Rooms,
  Tasks and Chats, each resizable.
- **A floating, translucent look** across all themes, light and dark.

## Updating

- **From Google Play or Obtainium/GitHub:** update as usual. Stay on the channel
  you already use; the two are signed with different keys.
- **If you ran a bridge-era install (Console 1.2.14 or older):** on the first
  launch after updating, Console checks each connection's Dashboard once,
  deletes the bridge secrets it kept, and tells you once if a connection needs
  its Dashboard sign-in. The bridge service keeps running on the computer until
  you remove it. When every phone is on 1.2.15 or newer, run on the computer:

  ```sh
  curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh -s -- --retire-bridge
  ```

  or, in Windows PowerShell:

  ```powershell
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1))) -RetireBridge
  ```

  It removes the bridge and nothing else, and does nothing on a computer that
  has none.
- **New installs:** run the helper's setup line from the README on the
  computer where Hermes lives, then scan the code it shows.

## Compatibility

- Android 7.0 (API 24) and newer.
- A Hermes Agent with its Gateway and Dashboard reachable from the phone. There
  is no fixed minimum version; a feature appears when your server offers what it
  needs (some, such as per-session settings, need Hermes 0.19 or newer).
- The setup helper that matches this release needs Console 1.2.15 or newer.

## Removed

- The Mobile Bridge for new installs, and the app's copies of the setup scripts.
- Support for running Hermes on the phone itself.
- The gesture dock, its coach and the old first-run intro.
- Hiding a whole provider as a separate step.
- The pet of Home and its settings page.
- Choosing your own voice services in Voice settings; existing setups move to the
  matching Hermes server or phone voice.

## Known limits

- With the app closed, launcher widgets and the live notification show less
  detail and say since when their data is; background refresh needs "Listen in
  background" on.
- A question from Hermes can be answered from its notification, but a launcher
  widget only opens it.
- Pausing a GPT-Live session while Hermes works is not in this release.
- Attachments whose files no longer exist on the server show as "Not
  available".
- Search inside a chat covers the loaded conversation and older pages of it, not
  other chats.

## Distribution

Google Play receives the signed `play` bundle; GitHub Releases and Obtainium
receive the signed `full` APKs only. See
[Release and distribution](RELEASE_DISTRIBUTION.md).
