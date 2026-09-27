# Plan 070 — Bot Mode, rich notifications and widgets

Built on top of 1.2.14 (PR #51). Independent review at each phase gate. Each
phase ends with analyze + touched suites green and a check on a physical
Android device.

## Architecture

```
lib/core/bots/                      (new feature module)
  data/
    bot_mode_repository.dart        profiles.list + session.* + groups.* + ui_meta
    room_log_cursor.dart            incremental groups.log (since_seq, backoff)
    desktop_room_projection.dart    read-only ui_meta['hermes-bots-groups'] v3
  state/
    bot_presence.dart               idle/thinking/working/attention from server evidence
    room_status.dart                driver_status -> single status line model
    attention.dart                  needs-you aggregation (approvals, @user, failures)
  ui/
    roster_screen.dart              S1
    room_screen.dart                S3
    bot_profile_screen.dart         S4
    widgets/ bot_face_live.dart, room_status_line.dart, approval_card.dart,
             activity_sheet.dart, attachment_card_actions.dart
lib/core/widgets/chat/              (extracted from chat_screen.dart, shared)
  chat_markdown_body.dart           main-chat Markdown renderer
  chat_message_frame.dart           avatar/name/time/actions frame
  console_composer.dart             the one composer (attach, dictation, send/stop)
lib/core/services/notifications/
  conversation_notifications.dart   MessagingStyle + Person + shortcuts + RemoteInput
  live_update_notifications.dart    ProgressStyle / ongoing fallback
android/.../                        Glance widgets: BotsWidget, NeedsYouWidget
```

Rules
- One pooled gateway client per connection (`SharedGatewayPool`) for all Bot
  Mode reads/writes; no ephemeral sockets; proper close frames.
- Polling: room log incremental every 3 s while visible and working, backoff to
  15 s idle, paused in background; roster every 30 s visible.
- Extraction first, behaviour-preserving: main chat golden/widget tests must be
  unchanged before any Bot Mode UI uses the shared widgets.
- Native Android pieces (MessagingStyle, shortcuts, ProgressStyle, Glance) via
  platform channel in Kotlin where flutter_local_notifications lacks support.

## Phases

| # | Phase | Output | Gate |
|---|---|---|---|
| 0 | Spec approval | this spec/plan/tasks | maintainer sign-off |
| 1 | Shared chat pieces | markdown body, message frame, composer extracted; main chat identical | chat suites green, review |
| 2 | Data layer & sync | repository, incremental log, presence, attention, Desktop projection, ui_meta sections/pins, pooled sockets | unit tests vs contract fixtures; #46 socket count measured |
| 3 | Room screen | S3 complete incl. approvals, retry, stop, activity, attachments (G1 interim), downloads | widget tests; device QA with a real room |
| 4 | Roster + profile + motion | S1, S4, living faces, perf budget | perf trace on device; visual review |
| 5 | Downloads everywhere | S5 in normal chat + Bot Chat | tests + device |
| 6 | Rich notifications | MessagingStyle, inline reply, approvals, Live Update, grouping | device QA (Android 16/17) |
| 7 | Widgets | Bots + Needs-you Glance widgets | device home screen QA |
| 8 | Upstream | English issues/PRs for G1–G3 (text reviewed before posting) | links |
| 9 | Release | full suite, review, device QA, PR | maintainer sign-off |

All phases ship in Hermes Console 1.2.14, on top of PR #51 (reconnection, activity pill and chat fixes).

## Risks
- `chat_screen.dart` is ~20k lines: extraction regressions → golden tests first.
- Animation cost on long rosters → single ticker per visible face, measured.
- Notification actions must be idempotent (approval answered twice from app and
  notification) → rely on server `request_id` and treat "already answered" as success.
- G1 interim leaks paths into room text → reference suffix format documented;
  removed once upstream adds attachments.
