# Changelog

All notable public changes are documented here. Internal QA/profile artifacts
are not releases.

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

Final signed artifacts are published only after physical-device QA and the
release gate in [the distribution guide](docs/RELEASE_DISTRIBUTION.md).

## 1.2.6 (913)

- Previous Google Play baseline.

Earlier development history predates the fresh public repository. GitHub
Releases remain the authoritative source for future public release notes and
artifact checksums.
