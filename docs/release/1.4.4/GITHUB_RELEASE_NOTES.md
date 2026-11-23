## Console 1.4.4

A corrective release for 1.4.3, plus memory provider settings as Hermes
Desktop offers them. Console still talks only to the Hermes Dashboard.

**New**

- **Memory provider settings.** The Memory screen shows the *active* provider
  apart from the one *selected*, with its readiness, and the built-in
  MEMORY.md / USER.md layer, which no provider replaces. Choose the provider
  from the server's own list and fill in the settings its plugin declares
  (for Hindsight: connection mode, API key, API URL, bank and recall
  budget). Credentials are write-only and never shown. «Full config…» and
  OAuth connect appear when the provider has them. Hermes keeps **one**
  external provider active at a time: choosing another replaces the previous
  one in that role. Needs a Hermes server with the provider settings routes;
  an older one says so and is left untouched.
- **Traffic in the local diagnostic (#226).** *Settings › Data › Generate
  local diagnostic* now includes how much the app talked to your server in
  the last 48 hours: requests and bytes per kind of route, WebSocket messages
  and reconnections, split by foreground and background. No addresses,
  identifiers or content; counted on the phone only and shared only if you
  share the report.

- **/steer from the composer.** Type `/steer <prompt>` (or `/s`) to guide
  the turn in flight without cutting it, the same as the queue's steer
  button. With no prompt it shows the usage line; with nothing running the
  prompt goes as the next message, as in Hermes. A normal message sent while
  the agent works still waits in the queue.

**Fixed**

- **A message shown twice while the agent worked.** A message that reached
  the running turn as a correction appeared as its own bubble and again,
  sometimes several times, under «Added while … was working» until the turn
  ended. It is shown once.
- **PDFs and other files in the in-app browser (#232).** A PDF, an archive
  or an office file left the spinner turning with «Open in browser»
  disabled. A PDF now opens in the app's viewer; anything else says it
  cannot be shown here and offers the system browser and a retry.
- **A download that stops arriving** no longer leaves an image as a skeleton
  for ever.
- **Attachments you sent** can be retried after a timeout, and their preview
  offers Share and Save.
- **Chat previews no longer blink or jump** when a chat is opened, and an
  HTML page holds the place of its preview while it downloads.
- **The summary under a reply** is one quiet line of small text, like
  «Memory updated», instead of a tall two-line capsule; opened, its steps
  are plain lines on the connector, without outlined pills.
- **The self-improvement notice** is a small one-line receipt like «Memory
  updated», not a block of large text; tap it to read all of it. A patched
  skill is named once, not twice.
- **A long folder scrolls.** The folder opened with «Open folder» from a
  file of a reply could not be scrolled past the first screen.
- **A step that failed says so.** A command that exits with an error, or a
  tool whose result reports a failure, shows as failed in the steps of the
  turn and in its summary, as in Hermes Desktop; it used to show as done.
  A turn that ended with a failed step reads «Completed with errors».
- **Less repeated reading (#226).** After every reply the app downloaded
  the newest page of the chat twice and the whole session record once. It
  reads the page once and the record at most once a minute: about a third
  of the REST traffic over 20 replies, measured on a phone.
- **The profile strip in Conversations** appears at once instead of filling
  in face by face.
- **Rooms**: a queued message and its files survive Android closing the app.
- **Messaging**: with no profile picked, calls no longer name `default`;
  credential fields never teach the keyboard; Save and Test no longer
  overlap; slow servers still load the page.
- **Background updates** follow cron jobs of other profiles, rooms with
  unread pages, Kanban board switches and edited endpoints without waiting
  for the long backstop.
- **Bots**: dismissed delivery failures stay dismissed per bot.
- **Terminal**: Back to the shell lasts for the live connection only; Compose
  text comes back when the link was already dead; localhost links from Herdr
  agents go through the SSH profile.
- **Browser over SSH**: uploads are forwarded intact; a page from elsewhere
  asks before reaching the server's loopback.
- **Files**: the editor keeps unsaved text when the panel's folder changes,
  and leaving the chat with unsaved text asks «Discard changes?» first.
- **Local storage**: safer writes of encrypted files; older transcripts are
  moved out of secure storage after launch.

The full list is in `CHANGELOG.md`.
