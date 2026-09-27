# Tasks 070 — Bot Mode, rich notifications and widgets

Legend: [P] parallel-safe · each task = test first (RED) → code (GREEN) → commit.

## Phase 1 — Shared chat pieces
- T101 Golden/widget baseline for main chat assistant message (markdown, code, table, list, link, inline code).
- T102 Extract `ChatMarkdownBody` from chat_screen.dart; main chat uses it; baseline identical.
- T103 Extract `ChatMessageFrame` (face/name/time/actions) incl. `ChatMessageSelectionArea`.
- T104 Extract `ConsoleComposer` (attach, dictation, send/stop) with a flag to hide Bot Mode toggle.

## Phase 2 — Data layer & sync
- T201 Contract fixtures for groups.capabilities/list/state/log/send/stop/approve/retry, profiles.list (from gateway-contract.generated.ts).
- T202 `BotModeRepository` over `SharedGatewayPool`; remove ephemeral clients in mission_control_screen/remote_bot_roster.
- T203 `RoomLogCursor` incremental (since_seq, has_more, backoff, pause in background).
- T204 `BotPresence` from worker_session/session status/driver_status (no 90 s heuristic).
- T205 `Attention` aggregation (pending_actions approvals/retry, @user, failures).
- T206 Canonical Bot Chat + preview/time from `canonical_session`/`worker_session`; drop legacy pin.
- T207 [P] Desktop projection rooms read-only (`ui_meta['hermes-bots-groups']` v3).
- T208 [P] Sections, pins, hidden Bots read/write via `ui_meta` (Desktop-compatible keys).
- T209 Measure sockets per minute with Bot Mode open (#46 evidence).

## Phase 3 — Room screen
- T301 Header (faces, name, availability) + overflow actions.
- T302 `RoomStatusLine` from driver_status; Stop (groups.stop).
- T303 Transcript with shared markdown/frame, mentions accent, copy, reply-to, thread.
- T304 Activity sheet; remove inline passes; remove "N listas" pill.
- T305 Approval card (groups.approve, server choices only, idempotent).
- T30A Round panel (collapsible per-member state) + Stop all.
- T30B Overflow menu with Console floating surface: members, threads, room files, activity, notifications setting, settings, disband.
- T306 Retry card (groups.retry).
- T307 Composer = ConsoleComposer; `@` member palette.
- T308 Attachments G1 interim: upload + reference suffix + card; disabled cross-gateway with reason.
- T309 Attachment card actions: download/open/share; image viewer.

## Phase 4 — Roster, profile, motion
- T401 Roster S1 (filter, pinned, needs-you, sections, rows); header "New" menu; no FAB; dock insets.
- T402 Long-press actions (pin, section, hide, profile).
- T403 Bot profile S4 (Now, model & reasoning, shortcuts, profile links).
- T404 Living faces: state mapping + entrance; reduced motion; off-screen pause.
- T405 Perf trace on device (20 faces) within budget.

## Phase 5 — Downloads everywhere
- T501 Audit download/open/share in normal chat + Bot Chat; fix gaps; tests.

## Phase 6 — Rich notifications
- [x] T601 Kotlin channel `hermes/rich_notifications` (`HermesRichNotifications.kt`): MessagingStyle with a Person per Bot (face PNG rendered in Dart by `BotFaceBitmapCache`, pure `PictureRecorder`, works in the listener isolate), long-lived conversation shortcuts (`pushDynamicShortcut` + LocusId + `setShortcutId`), category MESSAGE, public lock-screen version. Bubble metadata not added (needs a resizable bubble Activity; out of scope).
- [x] T602 Inline reply (RemoteInput) → `groups.send` (room, client event id = inbox uid) / Bot Chat `session.activate|resume` + `prompt.submit` (client turn id).
- [x] T603 Approval notifications: Approve/Deny (+Always only when once is not offered), max 3 actions, same server call (`groups.approve` with `request_id`, `/v1/runs/{id}/approval`, live chat `resolveApproval`); "already answered" = success; answered elsewhere → in-place "Answered elsewhere" (only if still shown) + auto-dismiss.
- [x] T604 Live Update (API 36+): ProgressStyle segments per round member, tracker icon = working Bot face, chronometer, `setShortCriticalText`, Stop all, `setRequestPromotedOngoing`, `POST_PROMOTED_NOTIFICATIONS`, channel IMPORTANCE_DEFAULT, never colorized / group summary / custom views. <36: ongoing notification with determinate/indeterminate progress + large face.
- [x] T605 Round summary "Round done · a and b replied" (quiet), grouped per Bot/room (group key = conversation id). In-app read clearing: approvals clear when answered anywhere; message cards auto-cancel on tap.
- [x] T606 Settings copy for listener on/off + Live Updates system settings entry.
- [x] T607 `RoomWatcher` in the listener tick (`BotModeBackgroundMonitor`): active connection (last → default → first), incremental `groups.state` + `groups.log since_seq` only when `latest_seq` moved, level all/mentions/muted (muted = approvals only), dedupe via `NotificationEventLedger`, per-connection exponential backoff 1 → 15 min, 30 s cadence while a room works.

Action routing: notification/widget buttons → `HermesNotificationActionReceiver` (not exported; refuses when the app lock is on) → durable inbox → wakes every attached Flutter engine (`HermesApplication` registers the channel on the foreground-service engine). The UI drains all routes; the listener drains room/run/Bot Chat (live chat approvals need the attached `ActiveChat`). `NotificationActionRouter` dedupes by meaning for 2 min.

## Phase 7 — Widgets
- [x] T701 Bots widget (2x2 → 4x4 responsive grid of state faces, working line, needs-you badge, deep link to Bot Chat through the notification-open route).
- [x] T702 Needs-you widget (4x2, Approve/Deny via the same action inbox, "All clear").
- [x] T703 Quick ask (4x1/2x1: face + "Ask <Bot>…" + mic → voice draft).
- [x] Room widget (4x2): no configuration Activity — it shows the most relevant room (working, then needs-you, then latest activity) with member chips, last message and Stop all. A per-widget room picker can follow later.
- [x] Status widget (2x1): connection + working / needs-you count.
Coexistence: the original Hermes Console widgets keep their receivers, look and snapshot (dashboard, compact, controls), so placed widgets are never replaced; the five Bot Mode widgets are new receivers (`HermesBotsWidgetProvider`, `HermesNeedsYouWidgetProvider`, `HermesRoomWidgetProvider`, `HermesQuickAskWidgetProvider`, `HermesStatusWidgetProvider`) and new picker entries. In 1.2.14 they are disabled in release manifests (not in the picker; redesign in 1.2.15) and enabled only in the qa flavor. Snapshot `hermes_widget_botmode_v2` (schema 2) is published only by the listener; the widget demotes "working" after 12 min without a publish (one-shot expiry redraw, no polling).

Gaps at the end of this phase: device verification pending; generated widget previews (API 35) not added — static `previewLayout` only; no Kotlin JVM test setup (logic kept in Dart and covered there).

## Phase 8 — Upstream (text reviewed first; English)
- T801 G1 attachments in hosted rooms.
- T802 G2 member activity to WS clients.
- T803 G3 Desktop on hosted rooms.

## Phase 9 — Release
- T901 Full suite, independent review, device QA, PR.

## Independent review 070 — P1/P2 resolution

Source: independent review of spec 070 (0 P0 · 6 P1 · 11 P2). Every P1 has a RED→GREEN test in
`test/notifications/spec070_review_p1_test.dart` (each fix was also reverted as a
mutant and the matching test failed).

- **P1-1 Bot Chat inline reply.** `prompt.submit` sends `client_turn_id` only when
  `ConnectionManager.isTurnIdempotencySupported` (the main chat's gate) holds; the
  official gateway's `{status: "streaming"}` is acceptance. Timeouts / lost socket /
  unverifiable ack after sending → `AmbiguousDeliveryError` → "Sent · open Hermes to
  check", dedupe kept, never resent. A Bot Chat reply re-delivered after an executor
  died is not replayed (no verified turn id). Test uses a real `TuiGatewayClient`
  against official-shape frames.
- **P1-2 Actions without an executor.** Receiver: if no engine is attached it enqueues
  an expedited one-shot WorkManager job (`HermesActionDrainWorker`) that boots a
  headless `FlutterEngine` on `hermesNotificationActionDrain` (same router/ops as the
  app; bounded 3 × 90 s, no periodic work). If no engine can start, taps expire
  immediately into a persistent "Couldn't send · open to retry" card that opens the
  conversation; a one-shot sweep (TTL + 15 s) guarantees the same for any tap nobody
  executed. Failed/expired replies move to the encrypted composer draft
  (`ChatDraftStore`, `mob-bot-<profile>` / `mob-room-…`). Bot Chat approvals without an
  attached `ActiveChat` use `approval.respond {session_id: stored id, request_id}`
  (upstream durable-identity fallback, #91684); `resolved: 0` = already answered. All
  engines (UI, listener, headless) now drain every route.
- **P1-3 Lock-screen widgets.** Needs you, Room and Bots are `home_screen` only; Status
  and Quick ask keep `keyguard` (informational, no server actions). Widgets render
  `redactedForKeyguard()` (no command/message/worker text, no Approve/Deny/Stop) unless
  the host category is proven HOME_SCREEN (unknown = redacted). The receiver refuses
  widget taps on every API level while `isKeyguardLocked`. The snapshot honours
  `notif_hide_sensitive_content` (no command, last message or worker title).
- **P1-4 Live Update Stop.** `setAuthenticationRequired(true)` (API 31+; <31 the receiver
  already refuses while locked), `VISIBILITY_PRIVATE` with a public version
  ("Working…" / "New activity", no room/Bot names).
- **P1-5 Live Update expiry.** `setTimeoutAfter(90 s)` renewed by every re-post; the
  presenter tracks its tags and the monitor cancels them on connection change,
  listener stop (`close()`), rooms that leave `groups.list`, and after 2 min without a
  successful pass (gateway unreachable / backoff).
- **P1-6 Battery/network.** Base cadence 180 s again (60 s only for Cron/Kanban); 30 s
  only while a watched room works or has a pending approval. One pooled socket per
  tick for rooms + profiles + live list, released at the end. Empty `groups.list` →
  no room RPCs for 5 min, then 10 min (below the widget's 12-min staleness guard).

P2 status:
1. Persistent dedupe across drains/engines: done (`PrefsActionDedupeStore`, one router
   per isolate).
2. Inbox at-least-once: done (claim lease 3 min + `ackPendingActions` after the
   terminal outcome; reclaimed taps replay only on server-idempotent routes).
3. Room "Always": done (never offered or sent for hosted rooms).
4. Room log paging: done (per-tick page cap resumes from the reached cursor; never
   adopts `latest_seq` while `has_more`).
5. `ui_meta` CAS on old gateways: **skipped** — documented behaviour, writes only the
   `hermes-bots` key; degrading to read-only would regress Bot editing on gateways
   without `ui_meta_revisions`. Kept as known debt.
6. Widgets prefer `canonical_session` (resolved id), never the legacy pin or last
   session: done.
7. Bot Chat adopt-before-mint: done in `persistCanonicalBotChat` (a server canonical
   chat different from ours blocks titling/pinning before `session.title`).
8. App lock too strict: **skipped** — UX only; relaxing it needs a trusted
   "unlocked now" signal from the UI isolate, out of scope for a safe patch.
9. Reply text at rest: done (AES-GCM, Android Keystore key; v1 clear inbox dropped).
10. Read-only connections: done (no Approve/Deny/Reply/Stop in notifications, Live
    Update or widgets).
11. Minor: `BotModeWidgetExpiryScheduler.replace` per provider and the unused
    `run` route are **skipped** (cost is 5 cheap REPLACE enqueues per publish; `run`
    route is kept as a documented contract). Rich Bot Chat approval bypassing the
    delivery ledger: **skipped** (re-alert after dismiss is `onlyAlertOnce`-limited;
    needs a ledger design change).

Verification: `flutter analyze` clean; touched suites 128/128; full suite 6760 pass,
1 skipped, 1 failure (`new_session_android_resources_test` still pinned `keyguard` on
every widget — updated to the P1-3 contract, then 4/4 green); profile APK
(arm64) built, with the drain entrypoint and worker present.

Not verified on device (no device in this pass): headless engine boot from the
receiver, keyguard/hub host categories, Live Update promotion.
