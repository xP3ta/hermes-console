# Changelog

All notable public changes are documented here. Internal QA/profile artifacts
are not releases.

## 1.2.8 (2939)

- Improved chat recovery across network loss, backgrounding and reopening,
  including duplicate protection, safer rewind boundaries and stronger
  profile/session isolation.
- Added complete Hermes Desktop `clarify` handling for single and batch
  questions, including restored pending prompts, sequential acknowledgements,
  partial retries, authoritative-answer fencing and fail-closed replay
  reconciliation.
- Improved local Android notifications for runs, Cron, Kanban and approvals,
  with stable channels, actionable tap destinations and approvals that only
  open the app instead of acting from the lock screen.
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
