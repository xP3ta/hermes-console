# Changelog

All notable public changes are documented here. Internal QA/profile artifacts
are not releases.

## Unreleased

- Rendered automatic standing-goal continuations as compact resumed-turn
  events when reopening an active Desktop session, including legacy history
  persisted before display metadata was available.
- Notified when a session being driven from another surface (Desktop, another
  Console, TUI) reaches a proven terminal state (completed, failed or
  interrupted) while this device is connected, reusing the existing
  cross-surface activity projection and the Runs notification channel. The
  notification never names the originating surface or session content — the
  projection is deliberately blind to that identity.
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
