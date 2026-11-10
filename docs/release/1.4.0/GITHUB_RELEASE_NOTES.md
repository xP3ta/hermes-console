## Console 1.4.0

A large release on top of 1.3.1. Console still talks only to the Hermes Dashboard.

**Workspace**

- Chat options sheet with Terminal, Git and an in-app browser one tap away.
- SSH terminal: full screen, extra key row, automatic reconnection.
- Git review screen: changed files, per-file diff, stage/unstage and local commit
  (no push, no PR).
- In-app browser for web links. Pages load straight from their own site; Console
  keeps no browsing history.
- Artifacts: images, files and links of a conversation in one view, plus a view
  across recent conversations.
- Tablets and open foldables (>= 840 dp): chat and workspace side by side.

**Agent work, live**

- Subagents reach parity with the official app: failed delegations are kept,
  pause/Retry, nested children, a tappable "Subagents n/N" card in reloaded chats
  (list, detail, "Open conversation"), and live detail of a running subagent.
- New look for the running turn: a "Working m:ss - N tools" card with a window of
  at most four actions, tree connector, grouped repeated tools, small grey live
  reasoning, and a final "Worked ..." fold.
- The chat no longer jumps down while you read earlier messages ("Go to end"
  appears).
- Connection errors behave like Hermes Desktop: no connection wording before five
  minutes of real outage, then one persistent notice; unconfirmed messages get a
  Retry card.
- "Keep connection while working in the background" (on by default; off with App
  Lock): a short foreground service of type dataSync, bounded to the running turn
  (30 minutes at most), with a single notification and a Stop action.

**Alerts**

- With the app closed, alerts use the opt-in background listening (Settings >
  Notifications > "Listen in background"), as in 1.3.1: off by default, one
  persistent notification with Stop, it checks only your own Hermes server, and it
  resumes after a reboot or update only if you had it on. Console uses no Firebase
  or third-party service for notifications. "Hide sensitive content" is on by
  default and App Lock removes the content of those alerts.
- Home screen widgets (Now, Chats, Cron, Tasks, New chat) load by themselves,
  follow the app theme, and with App Lock they only offer "Open".
- Haptic feedback setting (Appearance), on by default.
- Fewer loading flickers: lists keep their rows while refreshing; the chat
  skeleton waits 180 ms.

**Removed**

- The Bots and Rooms launcher widgets.

**Also**

- Digital assistant: Console can be chosen under Default apps > Digital assistant
  app (#217).
- Bot desktop viewer and takeover over noVNC, from PR #210 by @lucasliet. Not yet
  checked on a real bot display: treat it as experimental.
- Windows native server paths (#215/#216, thanks @mikyan) and the tablet drawer /
  "Go to" fix (#218/#219, thanks @xgooz3x).

**Known limits**

- Not yet verified on a real device: the Android 16 Live Update chip, haptic feel,
  and Doze with the screen off.
