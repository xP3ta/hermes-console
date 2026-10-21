## Console 1.3.0

Console now talks only to the Hermes Dashboard. There is no Gateway, API key or
pairing code to set up: choose an option on the welcome screen, run one command
on the computer where Hermes lives, and scan the code it shows.

**What is new**

- A welcome screen with two options: **I already have Hermes** (the camera, with
  the setup command under it) and **I don't have Hermes yet** (the **Install
  Hermes** help). Console no longer searches your Wi-Fi.
- **Connect manually** with the address, username and password the setup command
  prints.
- Lost the password? Run the setup command again with `--new-access` for a new
  one; Console's sign-in page shows the exact command.
- The **Connected** screen stays on for a moment before your first chat opens.
- Calmer first-start animations and a clearer outline on controls in the light
  theme.
- The Console logo next to the Home and side-menu titles: a pumpkin from 25 October to
  2 November and Rudolph from 20 December to 6 January.
- A steadier connection: one state on Home, Conversations and chats, automatic
  reconnection after network cuts, and plain words with a **Sign in** button when
  your sign-in expires.
- Lighter: Settings no longer waits for the update check, and a covered
  Conversations list stops polling.

**Fixed**

- A new chat no longer warns about "missing messages".
- Images and files from profiles with a name load again, and a web page is never
  saved as a file.
- One message that cannot be drawn no longer turns the whole chat grey, and a
  file link with non-English letters in its path no longer does either.
- Archive, pin, rename and delete are accepted by servers that require the
  session-write precondition.
- A new chat under a profile other than the default sends again.

**Connecting**

Run one line on the computer where Hermes lives and scan the code it shows (see
the [README](https://github.com/xP3ta/hermes-console#connect)). On a server on
the internet, install Tailscale on the server and the phone first.

**Updating**

- From Google Play or Obtainium/GitHub: update as usual and stay on the channel
  you already use; the two are signed with different keys.
- **Only had the Gateway before?** Console 1.3.0 talks only to the Dashboard, so
  that connection shows as offline until the Dashboard is running. Console tells
  you and takes you to a guided page: paste the setup command on the computer and
  scan the code. Your connection is updated, not duplicated, and your chats and
  settings on the phone stay. The Gateway is not touched: Open WebUI, cron jobs
  and Telegram that use it keep working.
- If your computer still runs the Mobile Bridge or an open Gateway port (8642)
  from an older helper, Console does not need them; the
  [README](https://github.com/xP3ta/hermes-console#readme) explains how to remove
  them.

**Thanks**

- **Luke Manning** ([@ManningWorks](https://github.com/ManningWorks)) found that
  a new chat under a non-default profile refused every message
  ([#200](https://github.com/xP3ta/hermes-console/issues/200)) and fixed it
  ([#201](https://github.com/xP3ta/hermes-console/issues/201)).
- **Rafael Telles** ([@rafael-telles](https://github.com/rafael-telles)) found
  that newer Hermes servers rejected archive, pin and rename, and wrote the
  session-write fix that this release builds on
  ([#204](https://github.com/xP3ta/hermes-console/issues/204),
  [#205](https://github.com/xP3ta/hermes-console/issues/205)).
- **@oeyhaga** reported the grey screen on a file link with a non-English path
  ([#208](https://github.com/xP3ta/hermes-console/issues/208)).

Full list of changes: [CHANGELOG](https://github.com/xP3ta/hermes-console/blob/main/CHANGELOG.md).

**Installing:** Android 7.0 or newer. These APKs are the signed `full` release,
one per CPU architecture (most phones need `arm64-v8a`). Download the APK for
your phone together with `SHA256SUMS`, check the file with
`sha256sum -c SHA256SUMS --ignore-missing`, and verify the signing certificate
before installing. Google Play and GitHub/Obtainium builds are signed with
different keys: stay on one channel.
