# Changelog

All notable public changes are documented here. Internal QA/profile artifacts
are not releases.

## 1.2.15 (9470) — 2026-09-30

A release about feeling faster and more dependable: Bot Mode opens instantly and tells you who is replying, chats open right away and can now be searched, and dictation no longer loses what you said.

### Bot Mode
- Opens instantly with what you last saw and refreshes in the background; rooms load in parallel and only fetch what is new.
- Each room's status strip shows who is replying (with a timer) and who is next. In the conversation, the bot's face appears with "is replying…" right where the answer will land.
- "Needs you" only shows while something actually still needs you: opening a room clears mentions and failures you have already seen. Approvals keep asking until you answer them.
- Failure cards can always be dismissed, and Retry only appears when it can really be done.
- Reading older messages no longer moves the conversation; an "N new" button takes you back to the bottom.
- Sending in a long room is much faster, and an action in one room no longer wipes the state of the others.
- Each bot's notifications wear its own colour, the live card shows the state as clear text, and muting a room withdraws its live card.
- Approval buttons work again after answering, and read-only connections can change a room's notification level.

### Chats
- *Faster opening:* a recent chat shows its conversation immediately while it refreshes. Bot chats for profiles without their own key no longer sit on a loader for seconds.
- *Attachments and generated files:* images and files you sent show up again when you reopen a chat (they used to appear as text). Files created by tools (audio, images, documents) appear in the reply and in Artifacts.
- *Search:* a new in-conversation search (magnifier icon, or `/find` and `/buscar`) that ignores case and accents, steps through matches and can look through older messages.
- *Scrolling:* the jump-to-bottom button shows how many new messages there are; when you come back to a chat, a "New since you left" line marks where you stopped. New content no longer drags you to the end while you read further up, and the edge bounce is smooth.
- Sending a message and leaving right away no longer leaves a duplicate draft behind.
- A queued message that was never confirmed can be retired with "Stop waiting", without resending it and without blocking the rest of the queue. Already-accepted messages no longer offer actions that do nothing, and Send now and Delete tell you when they fail.
- `/skills` opens the Capabilities hub and `/model <name>` now always responds.

### Voice
- *More reliable dictation:* text is no longer dropped with engines that record first and transcribe after; backgrounding the app or leaving the chat keeps what you dictated; a double tap on the mic no longer starts two recordings. The dictation bars now follow your voice.
- *Automatic language (issue #65):* choosing "Automatic" for server dictation no longer causes errors with some providers, and settings saved by the previous version are repaired when you open dictation settings and save. Thanks to the user who reported it.
- *Read aloud:* keeps working after choosing the Hermes server voice, with no need to restart the app.
- *Real server errors:* when the server rejects a voice request you now see its reason instead of a generic message, and the voice card no longer says "ready" after a failed test.
- *Warm-up:* with server voice on, Console lets Hermes get the voice ready in advance so the first spoken reply starts without dead air.

### Connection and stability
- A turn recovered after a dropout no longer stays on "reconnecting" and "working" forever: it settles on its own, without duplicate bubbles, and the chat reconnects.
- Status no longer says "connected" or "agent online" when the Dashboard password or API key is rejected; it now says so in amber.
- The chat side menu reflects whether you are really connected.
- Restarting the gateway only confirms the restart once it is actually back.
- Switching instance takes you back to the start, so every tool points at the new one.
- Removing SSH access also closes any open terminal session.
- Tapping a notification while the app is open takes you to its content: chat approvals and results open their conversation, and room or bot notifications open once, without stacking a second copy of the screen.

### Fixes
- Many texts that were stuck in Spanish or English now follow the app language: session titles, instance states, SSH and SFTP errors, gateway diagnostics, activity logs and voice notices.
- Screens under the floating dock no longer hide their last rows; the dock gains a sliding indicator and press feedback.
- Chats archived or hidden on the device also disappear from Home and the side menu.
- Cron explains the "All profiles" view instead of calling the instance read-only.
- The SOUL screen no longer claims it cannot be edited when it can.
- The status panel hides the repair button after a successful repair.
- In rooms, @mentions are only links when they lead somewhere, and bot names are consistent across the room.

### Known limits
- Attachments whose files no longer exist on the server show as "Not available"; files attached by a relative path are listed but not downloaded.
- Search inside a chat covers the loaded conversation and can page older messages; it does not search other chats.

## 1.2.14 (9420) — 2026-09-27

Reconnection and reliability fixes, a redesigned Bot Mode, one shared design
system, rich conversation notifications and Grok-style widgets, an
action-first subagent/session/task detail experience, and a single
Capabilities hub for skills, plugins, MCP servers and connectors. Physically
QA'd on a Pixel with the full stack installed.

### Reconnection, activity pill and chat
- Reconcile the OPEN conversation transcript — not just the session list — when
  Hermes signals `sessions.changed` from another surface (Desktop, CLI, another
  Console instance) on the same session: a message written elsewhere now
  appears in an already-open chat automatically, deferred while Console's own
  turn is streaming and applied once it settles, verified across reconnects
  and a provisional-to-durable session promotion, with no cross-profile
  leakage. Physically QA'd end to end on a Pixel against the real gateway.
- A turn whose completion was lost during a disconnect is recovered from
  server state instead of staying "running" forever; a pending approval is
  restored the same way.
- Network change / app resume probes the socket without ever killing a
  healthy one, and the close reason (heartbeat/probe timeout vs close/error)
  is logged without private data.
- Background processes and the subagent count stay visible as *last known
  state* across a lost transport until a fenced refresh, a newer durable
  completion, or a bounded max age settles them; old history pages and
  compaction clones never falsely settle retained work.
- Every persistent in-chat notice (Dashboard sign-in, truncated history,
  ownership conflict, refresh errors) can be closed with an accessible 48dp
  button; approval/progress dialogs stay non-dismissible on purpose.
- A queued turn whose acknowledgement was lost is removed once the durable
  transcript proves delivery, and the queue resumes automatically.
- Hermes updates launched from Console are tracked until the server proves
  completion. Fixes the abnormal WebSocket closures (#46) reported against
  1.2.13 with reconnect-storm backoff and clean close codes.

### Bot Mode redesign
- One roster screen for bots and rooms, with faces/avatars in a grid, a
  read-only Desktop room, and a "needs you" summary for pending approvals.
- Grok-style home-screen widgets: near-black card, state glow, large hero
  face, a room ticker and a Stop action; the original Hermes Console widgets
  are preserved unchanged for anyone who already placed them.
- Rich, groupable conversation notifications with a shared identity resolver
  (avatar → Desktop face → neutral glyph) across widgets, notifications and
  Live Updates.

### Design system, cron and connections
- One shared design system (dialogs, lists, content pages) replacing mixed
  boxed pills, ad-hoc modals and several model pickers.
- Human-readable cron schedules and a redesigned cron list/detail/builder.
- Reconnect-storm backoff and clean WebSocket close codes on every gateway
  connection.

### Subagents, sessions and tasks
- A flat activity row and a dedicated subagent detail page: live status,
  elapsed time, a working Stop/open action, a live tail while visible, a steer
  field and a public timeline.
- Session detail as one scrolling page with collapsed technical details and a
  full Kanban task detail page with the block reason inline.

### Single-scroll details and dialog sweep
- Skill, memory, bridge/gateway log and run detail pages are single-scroll;
  35 confirm/decide dialogs moved to the floating dialog system.
- *Settings › About* shows the install source (Google Play, GitHub/Obtainium
  or manual) with the matching update path and an uninstall-to-switch note.

### Capabilities
- A single *Capabilities* hub (Catalog / Installed / Connectors) replaces the
  separate Skills and Extensions entries, with install/update/enable/disable
  actions that call the real server and honest read-only/error states.

### Known limits
- If the device is disconnected for more than ~20s, Hermes reaps the live
  session even with work running; Console shows the last known state as
  stale and cannot confirm the work is still alive (upstream, not Console).
- Home-screen widgets redraw on update only; faces do not animate
  continuously (Android RemoteViews/Glance limit).
- Connecting accounts and adding MCP servers from the Capabilities hub are
  not yet available there; use *Advanced settings* meanwhile.

## 1.2.13 (9345) — 2026-09-25

Chat reliability, long-session performance and attachment fixes, aligned with
Hermes Desktop behavior. Physically tested on a Pixel 9 Pro (Android 17).

### Sending, retry and subagents
- Show the first turn of a new chat once: the provisional-to-durable session
  boundary no longer duplicates the user message or the reply.
- Retry a failed send only when durable history proves it was not delivered;
  ambiguous states keep the error and offer discard, so a retry can never send
  twice. The created session id is persisted, so this holds even if Android
  kills the app between the failure and the retry.
- Update the live subagent card to its final counts and duration in the first
  turn of a new chat; delegation metadata with ids only is hydrated from
  history. Historical subagent activity is one compact line.
- Do not count gateway processes reported as `exited` as background work in the
  session list (Desktop parity), and clear stale "working" rows after network
  loss.
- Repeat history hydration only after transient connection errors or timeouts,
  never on permanent server errors.
- Keep durable history usable while a session is compacting (Desktop parity);
  projection caches are byte-bounded and invalidated on profile or connection
  changes.
- Keep the Home composer draft across backgrounding and force-stop; delete it
  with the profile's data.

### Chat and long sessions
- Keep narrated assistant text visible across tool calls and interim segments.
- Prevent a retained historical assistant row from displaying the next external
  turn's live response a second time. Reset the visual turn identity without
  deduplicating text or discarding the historical answer.
- Keep durable in-flight corrections out of the real user-turn count, preserving
  edit targets and transcript reconciliation after refresh.
- Queue ordinary sends durably in FIFO order while a turn is running, without
  implicit steering or interrupting the parent or its children. Explicit
  "Steer now" and edit/rewind actions retain their existing behavior.
- Re-arm plain-text queues when a turn reaches its authoritative terminal state.
- Reduce repeated transcript projection and Markdown work in long chats, while
  preserving split-rendering equivalence and streaming frame-budget coverage.
- Keep the composer editable during transcript refresh and avoid invalidating
  the whole transcript during keyboard opening. Submission remains fenced until
  the interactive refresh publishes.
- Share only identical in-flight opening reads of the stored transcript;
  scrollback and recovery retain independent reads and authority checks.
- Settle interrupted subagents as cancelled after an explicit edit/rewind, rather
  than leaving old activity running or presenting cancellation as a failure.

### Attachments and previews
- Render `::preview{file="..."}` image/file directives through the authenticated
  media pipeline (#49). HTML previews are downloadable file cards, not live
  embedded Desktop widgets. Unknown directives remain visible as text.
- Preserve image thumbnails across transcript rebuilds, keep their aspect ratio,
  align composer attachments to the start, and remove misleading pending badges.

### Recovery and navigation
- Recover idle chats after the server reaps their runtime instead of remaining
  indefinitely on "Reconnecting…" (#46). This fixes a demonstrated recovery path,
  not every possible Android process crash or network failure.
- Let Kanban logs and other long text panes scroll under a vertical drag (#48).
- Allow Home or Bots to be selected as the initial screen, without overriding
  notification or deep-link navigation (#47).
- Add regression coverage for composer drafts across navigation and Bot Chat
  (#37), and for speech-engine recycling between recordings (#39).

## 1.2.12 (9320) — 2026-09-23

Reliability and long-session release. Hermes kept working when Console was
closed, stopped or lost its connection; what failed was what Console showed
and what its controls did afterwards. This version follows Hermes Desktop's own
behaviour for Stop, editing, queueing and reconnecting instead of a bespoke
one, and it was checked on a real Android device and emulator against a live
Hermes backend.

### Stop, edit and queue (Desktop parity)
- Stop always reaches the server, like Desktop: it is no longer blocked by a
  local ownership check or by a failed disk write, it settles from the
  gateway's real terminal signal, and it escalates within a bounded eight
  seconds instead of hanging on "Stopping…".
- Stop is available whenever Hermes is busy for any reason — a running turn, a
  background process, a subagent, a loop or work started elsewhere — from the
  chat composer and from the working rows on Home and in the list. It also
  stops the background processes, refreshes their state right away, and a
  stopped turn now says "Stopped" instead of "Completed". A session that was
  left running from an earlier auto-continue shows a one-tap "Stop this
  session" banner.
- Sending right after Stop interrupts first (Desktop's three-second window).
- Editing a message resolves the row by content like Desktop, sends the row
  ids the gateway needs so consecutive edits work, restores the transcript
  cleanly if an edit fails, and never leaves an orphan bubble.
- Queue and "force": a redirect the backend declines because the turn had just
  finished is no longer reported as a failure — the message simply stays
  queued, like Desktop; drained messages are flagged as queued; "Steer now" is
  hidden where the connection cannot steer.

### Reconnecting and network loss
- After losing the network mid-turn the chat now recovers on its own: retries
  back off with full jitter up to fifteen seconds, wake up as soon as Android
  reports the network is back or the app returns to the foreground, mint a
  fresh gateway ticket on every attempt, treat only a confirmed sign-in
  failure as final, and adopt the finished answer from the stored transcript
  when the turn ended while the app was offline. While the connection is down
  the chat says so calmly instead of claiming the model is thinking, and
  announces "Reconnected" once.
- The conversation lists refresh from gateway events with one slow safety
  poll, and the chat's own background polls are event-driven with adaptive
  backstops, like Desktop. Reconnect backoff only resets after a stable
  connection and replayed events are not applied twice.
- Approvals, clarifying questions, sudo and secret prompts work again: Console
  now tells the gateway it can answer server requests (#42).

### Chat
- One assistant bubble per turn, with a single floating activity pill above
  the composer for whatever is live (current action, task progress, a timer)
  that expands in place into a compact, scrollable live panel: tasks with
  animated checks (a finished task keeps its check on screen for a moment
  instead of vanishing instantly), the current step, a "Done" list with
  durations, and background work, subagents and loops each keeping their own
  controls. The bubble itself keeps only a muted line under the assistant
  name, worded and timed like Hermes Desktop's "Thought for 40s" / "Thought
  briefly" / "Thought" ("Pensó durante 40s" / "Pensó un momento" / "Pensó" in
  Spanish; the measured time while you watch it live, no time once reopened),
  expandable to the same detail;
  internal bridge-only steps (tool routing plumbing) are never shown, and a
  reply that only reasoned or only ran bridge steps no longer leaves an empty
  second bubble.
- The assistant header shows the companion avatar plain, without a loading
  ring, next to its name in the theme's accent colour; the line under the name
  is that turn's collapsed status, not the model name (already shown at the
  top of the chat).
- Editing your own message happens in the bubble itself — tap the pencil and
  the text becomes an editable field in place, no modal sheet — and the field
  now opens with room for several lines from the start instead of a single
  cramped line.
- Compacting a conversation, automatic or manual, shows one small floating
  pill above the composer (never overlapping the composer, the turn's own
  activity pill or the last message): a ring, "Compactando", the real facts the
  backend reports (message/token counts) and a real timer — never an invented
  percentage, since the backend does not report compaction progress. When it
  finishes the same pill turns into "Compactado · 38 → 34 mensajes" (or
  "Nada que compactar · N mensajes" when the server had nothing to do) and
  fades. Like Hermes Desktop it is driven by the server's own events while the
  app is alive, and the composer is locked only during that live compaction.
- If the app is closed or loses its connection while Hermes is compacting,
  Console never guesses and never locks you out: when you reopen the chat it
  reads what the gateway recorded while you were away and shows the pill again
  (with the real elapsed time) only if the server is still compressing, then a
  single "Compactado" result; if it cannot tell, it shows nothing and leaves the
  composer free. Sending while the server is compacting keeps your text and
  says Hermes is busy.
- A conversation whose session no longer exists on the server opens as a
  fresh chat with a small notice instead of a red error card, and a compacted
  transcript shows the server's own display text instead of the internal
  "prior context" marker. An edit whose target was compressed away is no longer
  retried pointlessly. The slash-command palette closes when the drawer opens or
  the composer loses focus instead of floating over the drawer.
- In the conversation lists (Conversaciones and Inicio) the status line under
  a chat's title now has its own colour and weight instead of the title's:
  green for "working / using tools", a calm secondary tone for compacting,
  amber when it needs you, red for a failure and muted when idle — all meeting
  WCAG AA contrast on every theme.
- Stop's confirmation is a small, discreet single line above the composer that
  clears itself a few seconds after a clean stop and disappears the moment a
  new turn starts; it only stays on screen while something still needs your
  attention (a retry, background work that would not confirm as stopped).
- Stop now also reaches active subagents, not only the foreground turn and
  background processes, and it only reports success once the roster actually
  confirms nothing is left running; if something could not be confirmed
  stopped it says so instead of claiming otherwise. Stopping one session can
  no longer affect another session's background processes on a shared
  connection.
- The "scroll up" arrow only appears when there is a real signal that more
  history remains to load, never as a generic "scroll to the top of what's
  already loaded" shortcut based on scroll position; the "scroll to bottom"
  arrow only appears when the conversation actually overflows the screen,
  live or after reopening a chat — a short conversation that fits no longer
  shows a spurious arrow either way.
- The text file viewer can actually be scrolled: a text-selection widget was
  claiming every vertical drag before it reached the scroll view.
- The compact context-usage chip never shows cumulative session tokens where
  the occupancy percentage belongs; when the context window size isn't known
  yet it shows a neutral placeholder, and the same rounding is used everywhere
  a token count is shown so it can't disagree with itself near a
  thousand/million boundary. Its accessible label is restored for screen
  readers.
- Files and media Hermes delivers (`MEDIA:`) load by themselves and open in
  in-app viewers: images (zoom), video, PDF (first-page preview and page
  viewer rendered natively on Android), text files (inline preview and a
  selectable viewer), audio, plus Save and Share. Only paths Hermes announces
  are fetched, the server stays the authority, large files ask for a tap and
  previews are cached on disk.
- Background work stays visible: running subagents and processes, watch
  patterns and hits, loops, heartbeats and goals show as one compact pill in
  the chat and as a "Background · N" chip on Home and in the list, and clear
  only when the backend confirms they are gone. Home and the list keep showing
  what Hermes is working on after the app was closed completely.
- Reopening the app mid-turn no longer duplicates your message or sticks on
  "Connecting"; a turn Hermes starts by itself appears as its own message and
  no longer overwrites the previous one.
- Transient messages float at the top in one calm style (no coloured side
  bar) and never cover the composer; the floating activity pills reserve their
  own space; the "scroll up" arrow appears only when it has something to
  reach; internal rows (personality switch, auto-continue, process completion)
  no longer appear as your messages; conversation previews show readable text
  instead of raw tool-call JSON.
- Silence no longer fails a turn: a long foreground tool no longer produces a
  false "Modelo sin respuesta" (a hint appears after five minutes).

### Security
- The generated-file/`MEDIA:` denylist that keeps Console from ever fetching
  or rendering a sensitive path is substantially wider (SSH keys and
  `.ssh`/`.gnupg`/`.aws`/`.kube`/`.docker`/`.azure`/`.gcloud` directories,
  `.netrc`, shell history files, more certificate/key extensions, `/proc`,
  `/sys`, `/dev`), with a second check right before a text file is ever shown
  inline. Installer/executable files (`.apk`, `.exe`, `.msi`, `.dmg`, `.sh`)
  can no longer auto-load, preview, or be opened through the external-open
  path. This is defense in depth on the client for gateway configurations that
  do not confine file access to a workspace folder.
- Downloading an attachment can no longer be redirected to another host with
  Console's session credentials attached; an incoming share from another app
  is only accepted from a `content://` source, never a raw file path.
- A concurrent download of two attachments failing to authenticate could,
  under a burst, retry without bound; a single failed authentication now
  always resolves within one retry.
- The public release-evidence package no longer includes the maintainer-only
  build manifest, which carried this machine's local toolchain paths; the
  packaging gate now also scans every shipped file for a personal path or
  private IP before release.

### Fixes from GitHub issues
- #42 approval and prompt requests were withdrawn by the gateway (see above).
- #39 voice transcription became unreliable from the second recording: the
  speech socket is now closed cleanly before the next recording starts.
- #37 the composer draft: covered by regression tests for normal, new, Bot
  Chat and room conversations, restarts and quick exits; drafts are shown on
  the list row.

### Correctness and performance
- An edit that got interrupted mid-flight by a Stop or by another turn
  starting could truncate the visible transcript while quietly reporting the
  edit as sent; it now rolls back and shows the failure like any other failed
  edit.
- A short local network failure while checking for older history no longer
  permanently pins "more history available"; it now retries transparently.
- The activity panel no longer recomputes on every keystroke, scroll frame or
  unrelated screen update — the guard that was meant to skip that work now
  actually does.
- Four new interface strings that shipped in English by mistake are now in
  Spanish; a few other small text and one-off state inconsistencies around
  Stop and the compaction indicator are fixed.

### Other
- The GitHub-release (`full`) app icon now has the same cream launcher
  background as the QA/Play builds; it previously inherited an unrelated dark
  background because that flavor never had its own icon override.
- Long history stays reachable after a compaction and the local transcript
  cache keeps the newest 1,000 messages (2 MiB), telling you when it is
  truncated.
- Sharing a link to Console pastes only the link; an empty shared session no
  longer fails. Bot Chat resumes its stored conversation and the "no companion"
  choice persists.
- The app now declares the normal `ACCESS_NETWORK_STATE` permission so it can
  reconnect the moment Android reports the network is back.

### Known limits
- Notifications for work finishing on another device (for example a tablet)
  are not included: Hermes routes those events only to the surface that owns
  the session.
- The gateway does not yet give exactly-once certainty when the connection
  drops while a message is being submitted, and a turn that produces no
  activity for ten minutes while detached can be interrupted by the server.
- Console and Hermes Desktop still cannot continue the same live turn across
  clients (cross-process lease on the server), and force-stopping the app from
  Android settings stops all delivery until it is opened again.

## 1.2.11 (9009) — 2026-09-19

- Bot Mode reaches parity with Hermes Desktop's bundled plugin, using only the
  server APIs that exist today: bot sections (create, rename, delete, file a
  bot, undo), create a bot from a clone, a fresh profile or an empty one with
  skills, toolsets, MCP servers, model and SOUL, create on another saved
  connection, an advanced editor for existing bots, full duplicate (memory
  and look included), geometric and blob faces, AI-generated avatars, a
  cross-connection roster with a bounded offline cache, `[bot:<name>]`
  attribution on routines, and native rooms that span machines through
  RoomLink. What Desktop keeps in local plugin storage (empty-section order,
  room pin/order, courier DMs, warm backends) has no server equivalent and is
  documented as such rather than faked.
- `@mention` handoff between bots, with an autocomplete palette that resolves
  friendly names and aliases, plus room recipients, per-member presence and a
  compact room summary pill.
- Bot and chat history now loads over the already-authenticated gateway
  WebSocket (`session.history`), the same channel Desktop uses, instead of the
  per-profile REST key. Profiles without their own `API_SERVER_KEY` no longer
  show "Could not load messages" (HTTP 401). REST stays as the fallback.
- Shared rooms: `groups.send` is enabled again, the room driver is re-checked
  instead of caching a negative answer while the server worker starts, the open
  room refreshes on its own, `@all` and `@everyone` are offered by the
  autocomplete, and send/refresh failures are shown inside the room.
- A dropped socket no longer hides a finished reply. Console reads the durable
  transcript first and only falls back to reconnecting, and it stops polling
  the whole conversation while you are typing a draft. Thanks to
  @josephsellers for #38 and #40, including the field-tested analysis behind
  them.
- Dock v2 (per-profile items, contextual Back, style customization) extended to
  Cron, Tasks and Tools; drawer grouped into header, navigation and footer
  zones; Tasks gets a List/Board toggle; flatter floating Cron, subagent and
  preview surfaces; Bot Chat is writable like any other chat; per-item
  notification mute for cron jobs and Kanban tasks; 44 dp minimum tap targets
  on two dismiss/refresh buttons.
- About 50 previously hard-coded strings (chat, memory, bridge, SSH/SFTP,
  mascots, local install, Ollama, Skills) now live in the English and Spanish
  resources.
- Screen changes no longer fade the whole page in; the slide and parallax stay,
  and the per-frame full-screen offscreen layer is gone.
- Rendered automatic standing-goal continuations as compact resumed-turn
  events when reopening an active Desktop session, including legacy history
  persisted before display metadata was available.
- Standing goals (`/goal`) now show live in the composer: a compact one-line
  status (turn count, paused/waiting/blocked/done) sourced from the
  structured `session.control` contract, not text scraping. Tapping it opens
  the full contract, criteria and quality gates, with pause/resume/resume-now
  and clear actions. A state transition (not each intermediate turn) notifies
  through a new `local_agent` source, with its own settings toggle. Scope
  note: this is observed live while the session's socket stays connected —
  there is no background poll for a fully closed app, since
  `session.control.read` is a control-channel RPC, not a REST endpoint the
  background service can poll the way it does Cron/Kanban.
- Notified when a session being driven from another surface (Desktop, another
  Console, TUI) reaches a proven terminal state (completed, failed or
  interrupted) while this device is connected, reusing the existing
  cross-surface activity projection and the Runs notification channel. The
  notification never names the originating surface or session content — the
  projection is deliberately blind to that identity.
- Surfaced the result of a background task started from the Agent Center
  (`prompt.background` / `background.complete`) as a single-line strip above
  the composer, tap to read the full text, plus a notification when the app
  is backgrounded but the process is still alive. The system notification
  never repeats the task's own output, only its outcome. This only works
  while the app's process stays alive (foreground, or background before
  Android reaps it) — there is no gateway endpoint yet to reconstruct a
  background task's outcome after a cold start; closing that gap needs either
  a new poll endpoint or the shared gateway.
- Raised the default JSON-RPC request timeout from 30 s to 120 s across the
  gateway client's general-purpose request paths, so a slow mobile connection
  no longer times out calls that a desktop connection would complete
  comfortably. Call sites that already pin their own explicit timeout are
  unaffected.
- Fixed the on-screen keyboard closing unexpectedly while typing in the chat
  composer. The attachment preview strip and the text-field row had no
  `Key`, so attaching a file (or a session compression starting) while
  typing changed the number of children ahead of the row and Flutter
  reconciled by position, remounting the row — and its `EditableText` — even
  though the same `FocusNode` stayed logically focused. Both now have stable
  keys.

## 1.2.10 (9008) — 2026-09-14

- "Reintentar" on a failed turn always does something: it first reconciles
  with the durable transcript and, when the server has no evidence of the
  turn, resends the prompt instead of ending silently. The error bubble's own
  prompt is used when the screen no longer remembers the last one (relaunch).
- Redesigned the blocking prompt card (clarify, sudo, secret): it now rises as
  a compact sheet above the composer over the dimmed transcript instead of
  replacing the whole screen. Choices are full-width option rows with a
  selection indicator and a "Recommended" tag parsed from the agent's label;
  free-text answers use an inline field; the question list scrolls under the
  keyboard instead of overflowing.
- Fixed the false "Modelo sin respuesta" (`firstTokenTimeout`) while the agent
  waits on a human: liveness events (`status.update`, `tool.*`,
  `session.info`) no longer restart the 90 s inactivity watchdog under a
  pending approval, clarify, sudo or vault card. The budget resumes once the
  card is answered or withdrawn.
- Speak the Hermes Agent v7 prompt contract: `approval`, `clarify`, `sudo`,
  `secret` and `terminal.read` now arrive as JSON-RPC server→client requests
  and are answered on the same socket with the request id. Batch clarify
  answers lock through `clarify.lock`, `request.cancel` withdraws the card,
  and `open_requests` returned by `session.resume` / `session.events.since`
  re-deliver questions that were waiting across a reconnect. A backend that
  still emits the legacy `*.request` events keeps working unchanged.
- A socket drop mid-turn against a gateway without `turn_idempotency_v1` (the
  official one) now resumes the live session and adopts its inflight turn
  instead of failing the turn immediately; the turn only degrades to a
  recoverable failure when the server has no evidence of it.
- Added a global, privacy-bounded activity projection to the session list for
  work started from Desktop or another Console. It reconciles active-session
  and process lists, blocking prompts, reconnects and replay uncertainty without
  persisting free-form event payloads or acquiring session ownership.
- Fixed consecutive turns in one Desktop runtime disappearing after a terminal
  event while preserving ordered Stop evidence against genuinely older roster
  responses. Unknown runtimes, session-library changes and pull-to-refresh now
  trigger bounded authoritative reconciliation.
- Activity reconnect now uses capped backoff and an age ceiling: stale state is
  presented neutrally and stops claiming current liveness. Session/profile
  deletion purges the encrypted public journal and lifecycle pauses flush it.
- Kept ordinary input and edits on the established next-turn FIFO path; this
  activity display does not add redirect/steer, invent background process
  events, or claim that queued work is already running.
- Made the Spanish activity pill fit at 200% text scale and expose one merged
  accessibility label rather than duplicate row live-region announcements.
- Approval actions now follow Desktop's exact `choices`, `allow_session` and
  `allow_permanent` capabilities in both UI and automatic policy paths.
- Vault unlock, login-save and code requests remain visibly blocked with a safe
  Desktop-continuation card; Console stores none of their secret payload.
- Rewrites restore their optimistic transcript rollback whenever submission is
  not accepted. Queued composer turns are encrypted before clearing, restore in
  FIFO order, retain rejected heads with bounded retry and expose manual retry.
- A matching `session.reclaimed` event invalidates only its exact owned binding
  and performs a cold reattach. Steering automation, `background.complete` and
  `missing_servers` handling remain deferred to 1.2.11.

- Captured structured `video_generate` results from live Gateway events and
  durable REST history even when the final assistant prose does not repeat a
  `MEDIA:` directive. Media cache identity and managed-file downloads are now
  scoped to the active connection and profile.
- Rendered generated images and videos inline from Hermes `MEDIA:` responses.
  Media stays behind an explicit load action, downloads through authenticated
  bounded streams into app-private cache, validates the file signature and
  never exposes server paths or signed URLs through chat, copy, speech, link
  previews or notifications.
- Mirrored turns started from Desktop, TUI or another Console while they are
  running, without acquiring session authority or leaving a permanent loader.
  Durable refresh replaces only the matching live projection and preserves
  legitimate repeated prompts and replies.
- Replaced the quadratic JSON-number parser that could block Android's UI thread
  on large numeric Gateway frames with a grammar-preserving linear scanner.
- Preserved newest-first chronology when compacted terminal projections and
  newer durable turns meet during pagination or refresh, including multiple
  compacted groups whose old identities disappear in the same pass.

- Loaded retained compacted display history through Hermes' existing passive
  Dashboard API (`include_compacted=true`), accepting both current `messages`
  and legacy `data` response shapes without merging them. Older servers or
  rotated lineages that cannot prove full coverage remain explicitly partial.
- Kept confirmed conversation history visible while refreshing, reconnecting or
  reopening chats, without reloading a duplicate transcript.
- Kept an active subagent card mounted when a new human turn is inserted; late
  completion updates the same stable row once. The card shows only authoritative
  status, model, duration and aggregate counts, and labels unavailable historical
  detail instead of inventing an identity, goal, activity or result.
- Made WebSocket reconnect replay sequence-aware: ordered replay, live-frame
  fencing, epoch isolation and fail-closed recovery when replay is truncated.
- Kept malformed replay sequence values from corrupting the monotonic watermark.
- Queued ordinary Chat and Voice input received during an active turn for the
  next FIFO turn; these surfaces no longer call `session.redirect` or
  `session.steer`, and remote queued turns do not fall back to REST.
- Improved durable recovery of queued turns and safe persisted subagent
  completion projection.
- Kept session listing, opening, hydration and pagination passive. Ownership
  conflicts during explicit mutations fail closed without automatic resume,
  retry or takeover.
- Added native `/compress` progress/results and preserved safe persisted
  subagent history as editorial cards. Public completion events can settle a
  card without implying current cross-process liveness or exposing internal
  transport markers in chat or lists.
- Separated Cron, Kanban and safe persisted subagent history from user chats;
  Cron delivery failures remain visible while no-op runs and completed Kanban
  items stay quiet.
- Preserved conversations already observed by Console when the legacy Gateway
  returns a later bounded list that omits them, without retaining rows that are
  explicitly archived or outside the active filter.
- Kept API-originated conversations — including Console chats — in «Chats»;
  `api_server` is a transport and is no longer treated as an automation source.

## 1.2.9 (4964)

- Replaced raw Desktop session-owner rejections with private, actionable UI,
  preserved the server's structured rejection reason and made safe retries
  replace the failed local turn instead of duplicating it.
- Fixed chat history disappearing, reordering or losing visible content during
  overlapping refreshes, pagination, reconnection and Desktop snapshot
  recovery.
- Restored the final assistant reply automatically after reopening a chat that
  was backgrounded or closed while tools such as web search were still running.
- Unified the exact Desktop and Console message identities used by refresh,
  backfill and Stop, so cancelled replies stay cancelled without hiding or
  reviving legitimate responses.
- Preserved partial transcripts conservatively until the server proves they are
  complete, including long conversations and compacted histories.
- Improved WebSocket heartbeat recovery after Android suspends the app, avoiding
  false Gateway disconnects when returning from the background.
- Added optional persistent background listening that remains active until the
  user turns it off and can privately notify about replies, runs, Cron and
  Kanban transitions.
- Hardened notification deduplication and cross-isolate persistence across app
  restarts, package updates and process death.
- Kept Voice, dictation, read-aloud, SSH and SFTP foreground ownership isolated
  from the persistent Android 15+ messaging listener.
- Expanded deterministic coverage for transcript identity, pagination races,
  Stop tombstones, Desktop recovery, subagents, Gateway suspension and
  background automation.

## 1.2.8 (4943)

- Improved chat recovery across network loss, backgrounding and reopening,
  including duplicate protection, safer rewind boundaries and stronger
  profile/session isolation.
- Added complete Hermes Desktop `clarify` handling for single and batch
  questions, including restored pending prompts, sequential acknowledgements,
  partial retries, authoritative-answer fencing and fail-closed replay
  reconciliation.
- Kept completed-reply notifications private and routed to the exact session
  while the app process remains available in the background. Durable
  closed-app notifications for runs, Cron, Kanban and approvals remain deferred.
- Preserved queued and interrupted turns durably across reconnects without
  resending prompts, duplicating messages or crossing profiles.
- Ordered conversations by canonical activity, added reliable relative times
  and made the composer support natural multiline prompts while keeping an
  explicit send action.
- Improved slash commands, dictation focus, compressed-task transcript hiding
  and chat controls aligned with Hermes Desktop.
- Refined Bots, Kanban and active-task clarity, plus voice lifecycle,
  interruption and waveform behavior on mobile.
- Hardened pairing, Windows onboarding, external providers and authentication
  fallbacks without rotating existing dashboard credentials.
- Made connection diagnostics honor authenticated `skills_toggle` and
  `plugins_api` capabilities using read-only, same-origin probes, with credit to
  Austin Law for the original contribution.
- Refreshed deterministic tests and Android/Flutter CI alignment. Final SBOMs
  and third-party license evidence are regenerated from the exact release tree.

## 1.2.7 (915)

- Added the Bots workspace with profiles, rooms, mentions and task-focused
  collaboration adapted from Hermes Desktop contracts.
- Added native companion rendering and configurable Blobatar bot identities.
- Added structured generated-image and artifact viewing without changing the
  approved textual chat streaming path.
- Improved Android back navigation between regular conversations and Bots.
- Redesigned voice and dictation settings so the active on-device/server route
  is explicit.
- Aligned Voice with the Hermes Desktop streaming contract, including
  `speak-stream`, single-response fallback, interruption acknowledgement and
  cleanup behavior.
- Improved typography, floating menus and transient notifications across small
  Android screens.
- Raised the Android target SDK to 36 and addressed current Play requirements.
- Prepared the project for publication under GPL-3.0-only with a fresh public
  history and preserved upstream notices.

Final signed artifacts are published only after the emulator/Desktop E2E matrix
and the release gate in [the distribution guide](docs/RELEASE_DISTRIBUTION.md).

## 1.2.6 (913)

- Previous Google Play baseline.

Earlier development history predates the fresh public repository. GitHub
Releases remain the authoritative source for future public release notes and
artifact checksums.
