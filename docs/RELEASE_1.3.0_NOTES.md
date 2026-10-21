# Console 1.3.0 — release notes

Release build: `1.3.0` (build number and date to be filled in at release).
Public comparison base: `v1.2.15`. The complete list of changes is in
[CHANGELOG.md](../CHANGELOG.md); this page is the short version for people
deciding whether and how to update.

## The headline

**Console talks only to the Hermes Dashboard.** Connecting no longer asks for a
Gateway, an `API_SERVER_KEY` or a pairing code: you run one command on the
computer and scan the code it shows. The first start is calmer and clearer, the
connection is steadier after network cuts, and a few sources of background work
are gone.

## What you will notice

- **A simpler first start.** The welcome screen offers two options:
  **I already have Hermes** opens the camera, with the setup command below it,
  and **I don't have Hermes yet** opens the **Install Hermes** help. Paste one
  command in Terminal or PowerShell on the computer; it installs the official
  Hermes only if it is missing, leaves the Dashboard on behind a password at a
  private address (home network or Tailscale), starts it with the computer, and
  ends with the address, username, password and a QR code. Scan the code and
  Console is connected. On a server on the internet, install Tailscale on the
  server and the phone first. The README has the steps.
- **No Wi-Fi search.** Console no longer scans your network for Hermes. You scan
  the code, or type the details yourself.
- **Connect manually.** Still there, and simpler: the address, the username and
  the password the setup command printed. Nothing else to fill in.
- **Lost the password?** Run the setup command again with `--new-access` to get
  a new password and code. Console's sign-in page shows the exact command for
  your system.
- **A clear finish.** After a successful connection the **Connected** screen
  stays on for a moment, so you can see it worked, and then your first chat
  opens by itself. Tapping a button or going back there stops the wait (back
  takes you Home).
- **Easier to read.** The first-start screens have smoother, calmer animations
  (and still animations when you ask your phone to reduce motion), and the
  controls in the light theme have a clearer outline.
- **A logo on Home and in the side menu.** The Console logo sits next to the Home and side-menu titles. From
  25 October to 2 November it becomes a pumpkin, and from 20 December to
  6 January it gets Rudolph's red nose and antlers.
- **A connection that recovers.** One source decides whether Console is
  connected, reconnecting, offline or needs a sign-in, and Home, Conversations
  and chats show the same state. After a network cut, recovery waits for a
  network that works instead of retrying blindly. If a chat's connection drops,
  Console reconnects it by itself, and the notice has a **Retry** button for
  when you do not want to wait.
- **Expired sign-in in plain words.** When your Dashboard sign-in has expired,
  Home, Conversations and the instance panel say so and offer **Sign in**,
  instead of showing a technical error.
- **Fewer false alarms.** A brand-new chat no longer shows a false
  "missing messages" warning.
- **Images and files in named profiles.** Pictures and files that Hermes sends
  in a named profile load again. A web page is never saved as a file by
  mistake.
- **A bad message no longer breaks the chat.** If one message cannot be drawn,
  only that message shows a short notice, with a button to copy its text. A path
  with non-English letters in a file link no longer turns the chat grey.
- **Chat details.** Sending while Hermes is working is a live correction, like
  in Hermes Desktop. A very long thought is capped to part of the screen and
  scrolls inside its own box. A message waiting in the queue does not come back
  as a draft in the message box.
- **Less waiting and less background work.** Settings no longer waits for the
  Hermes update check, the voice recogniser loads when you first use the
  microphone and not when a chat opens, and a Conversations list covered by
  another screen stops polling.
- **Session actions that servers accept.** Archive, pin, rename, the
  hidden/unread switches and delete now send the preconditions that newer Hermes
  servers require, so they are no longer rejected and rolled back.
- **Profiles stay apart.** A live conversation of another profile no longer
  shows up as activity in the profile you are looking at.

## Updating

- **From Google Play or Obtainium/GitHub:** update as usual. Stay on the channel
  you already use; the two are signed with different keys.
- **Coming from 1.2.x with only the Gateway?** Console 1.3.0 talks only to the
  Dashboard, so that connection shows as offline until the Dashboard is
  running. Console tells you and takes you to the same guided page: paste the
  command on the computer and scan the code. Your existing connection is
  updated, not duplicated; your chats and settings on the phone are kept, and
  the connection keeps its Gateway key, which is no longer used. Forgot the
  password? Run `curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh -s -- --new-access` (Windows: `& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1))) -NewAccess`).
  The Gateway is left as it is: Console does not change its settings, so Open
  WebUI, cron jobs and Telegram that use it are not affected by this update.
- **If your computer still runs things from an older helper:** Console does not
  need the Mobile Bridge or an open Gateway port (8642). Both can be removed;
  see "Coming from an older install" in
  [server configuration](CONFIGURATION.md).
- **New installs:** follow the README: one setup command on the computer, then scan
  the code.

## Compatibility

- Android 7.0 (API 24) and newer.
- A Hermes Agent whose Dashboard is reachable from the phone. There is no fixed
  minimum version; a feature appears when your server offers what it needs.
  Archive, pin, rename and delete use the fenced writes of servers that own the
  session store; a server without that route keeps the plain write.

## Removed

- Asking for a Gateway key when you add or edit a connection.
- The Gateway as a transport: chat turns, approvals and stop go through the
  Dashboard's live channel only, and the model picker no longer asks the Gateway.

## Known limits

- A pairing code or link made by an older setup helper is still accepted.
- Over plain HTTP on a home network, the Dashboard sign-in is not encrypted.
  Prefer Tailscale or HTTPS.
- The setup-helper option that keeps the Dashboard always on is not part of this
  release.

## Thanks

Three people outside the project found problems and sent fixes or reports that
shape this release. Where they sent code, it ships with their name in the
history:

- **Luke Manning** ([@ManningWorks](https://github.com/ManningWorks)) found that
  a new chat started under a profile other than the default refused every
  message ([#200](https://github.com/xP3ta/hermes-console/issues/200)) and fixed
  it with a test ([#201](https://github.com/xP3ta/hermes-console/issues/201)).
  Thank you, Luke.
- **Rafael Telles** ([@rafael-telles](https://github.com/rafael-telles)) found
  that newer Hermes versions answered `409 client_upgrade_required` to session
  writes (archive, pin, rename) and wrote the fix that makes Console send the
  mutation fence they require
  ([#204](https://github.com/xP3ta/hermes-console/issues/204),
  [#205](https://github.com/xP3ta/hermes-console/issues/205)). His session-write fence is what the fix for
  archive, pin and rename in this release builds on. Thank you, Rafael.
- **@oeyhaga** reported a grey screen when a file link in a long answer had
  non-English letters in its path
  ([#208](https://github.com/xP3ta/hermes-console/issues/208)). It is fixed in
  this release. Thank you.

## Distribution

Google Play receives the signed `play` bundle; GitHub Releases and Obtainium
receive the signed `full` APKs only. See
[Release and distribution](RELEASE_DISTRIBUTION.md).
