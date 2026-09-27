# Spec 070 — Bot Mode, rich notifications and widgets

Status: Implemented in Hermes Console 1.2.14.

## Product decision

Bot Mode in Hermes Console is the Android surface of the **same** Hermes Bot Mode
the user runs in Hermes Desktop: same Bots, same Bot Chats, same rooms, same
approvals, same state — like ChatGPT desktop and mobile. It must feel native,
alive and professional: one glance tells who is working, on what, and what needs
the user; every running thing can be inspected, stopped or changed.

Console never invents shared state. Anything two surfaces must agree on comes
from the Hermes server (`profiles.list`, `session.*`, `groups.*`, `ui_meta`).
Console does not modify Hermes Agent; where the server lacks a capability,
Console degrades visibly and the gap is filed upstream (§ Upstream gaps).

References (visual/UX only, nothing copied): Grok Bot (xAI) for simplicity,
living bot faces, contact-list roster and one-tap approval cards; Hermex for the
dark, single-accent, clean-row visual language; Hermes Desktop Bot Mode for
functionality and semantics (authoritative).

## Sources of truth

| Concept | Authority | Console must not |
|---|---|---|
| Bot identity, avatar, model, provider | `profiles.list` / `profiles.configure` | cache as truth |
| Bot Chat (canonical) | `profiles.list.canonical_session`; `session.list{title:'Bot Chat'}` | use legacy `ui_meta['hermes-bots'].chat` pin |
| Row preview / time | `canonical_session.preview`, max(`canonical_session`, `worker_session`).`last_active` | derive from local history |
| "Working" | `worker_session` (≤150 s), live session status, room `driver_status` | infer from "wrote in last 90 s" |
| Rooms | hosted `groups.*` (`shared-state.db`) | keep a Console-only room store |
| Desktop-only rooms | `ui_meta['hermes-bots-groups']` projection | write to it |
| Room approvals | `groups.state.driver_status.pending_actions` + `groups.approve` | answer anything not listed there |
| Sections, pins, hidden Bots | `ui_meta` (per Bot) as Desktop does | store in SharedPreferences only |
| Attention / "needs you" | pending approvals/clarify, `@user` mentions, failed turns | Console-only unread counters |

## Screens

### S1 — Bots (roster)
- Header: title, search (round), overflow menu with **New Bot / New room**. No
  floating action button; layout respects the Console dock.
- Filter segment: All · Bots · Rooms.
- Pinned Bots: large animated faces, name below.
- **Needs you** section first (approvals, clarify, `@user`, failures), then
  user sections (from `ui_meta`), then everything else by recency.
- Bot row: animated face with a single state signal (idle / thinking / working /
  attention); name; time; line 2 = "Working · <worker title>" in accent when
  working, otherwise the canonical preview. No presence dot, no unread dot.
- Room row: stacked member faces; name; time; "You:/@handle: preview";
  **needs you** badge; "Desktop" label and read-only if not hosted.
- Long-press: pin, section, hide, open profile.

### S2 — Bot Chat
- Unchanged behaviour (it already works). Header shows the Bot's face, name and
  model; composer placeholder "Message <Bot>"; replies attributed to the Bot,
  never "Hermes".

### S3 — Room
Rooms get their **own group-chat design**, distinct from the 1:1 chat (product
decision): a multi-speaker conversation where who-said-what and who-is-working
is obvious at a glance. Only the building blocks are shared with the main chat
(Markdown renderer, selection, code/table blocks, composer), so content quality
is identical; layout and chrome are group-specific.

Group layout
- Messages grouped by consecutive speaker: face + coloured name + time on the
  first message of a run; following messages from the same speaker attach
  without repeating the header (like Slack/Discord/Telegram groups).
- Each Bot has a stable identity colour (same as roster/Desktop avatar) used for
  the name, a thin accent rail on its messages and its mention chips.
- User messages right-aligned bubbles; Bot messages full-width cards with
  subtle surface so long Markdown (code, tables) has room.
- Thread replies shown as a compact "↳ n replies · last by @x" under the root,
  opening a thread sheet.
- Day separators and "new since you left" divider.
- Round boundaries visible but quiet (thin divider "Round 2") when the room runs
  multiple rounds.

Markdown quality bar (P0): the shared `ChatMarkdownBody` with the same
rendering as the main chat — headings, lists, nested lists, block quotes, inline
code, fenced code with language label + copy, horizontal-scroll tables, links,
images, task lists; no raw Markdown characters visible; long messages never
clipped or scrolled internally; selection works across the message.

- Header: back, member faces + name + "N of M available", overflow (members,
  rename, stop, disband, settings).
- **Round panel** (replaces a one-line status): collapsed = one line
  "Round N · 1 working · 1 queued" + Stop all; expanded = one row per member
  with face, name, what it is doing and a state chip: Working (elapsed),
  Needs you (the approval/clarify text), Queued, Passed, Replied, Failed
  (retry). Source: room log turn.* events + `driver_status` counts and
  `pending_actions`. Per-member tool detail waits for gap G2; until then
  "Replying to your message · 2:14".
- **Overflow menu** uses Console's own floating surface/sheet style
  (`showHermesFloatingSurface`), not a new visual language: Members (list with
  state, add/remove, compress member history), Threads, Room files
  (download), Activity, Notifications (all / mentions / muted), Settings
  (name, picture, stop-word detection), Disband (destructive, confirmed).
- No coloured side rail on message cards: speaker colour only on face and name.
- **Status line** (single row, always truthful): "<member> is working…" /
  "Room is working…" when the member is unknown / "Needs your approval" /
  "Blocked — retry" / "Last activity 3 min ago". Tap → Activity sheet. Stop is
  available whenever `driver_status.working`.
- Transcript uses the **main chat renderer**: Markdown (code, tables, lists,
  links), speaker face + name in their colour + time, `@mentions` as accent
  text, copy, "Reply to @handle", reply in thread. Selecting text never scrolls
  inside the message.
- Member passes and failures are **not** inline: a single "N passed · Activity ›"
  line after a round.
- Inline cards: approval (once / session / always / deny, only the choices the
  server offers), clarify, retry failed turn.
- Attachments rendered as cards with **download / open / share**; images as
  thumbnails with full-screen viewer.
- Composer: **the same Console composer** as the main chat (attach +, dictation
  mic, send/stop); no Bot Mode toggle; `@` opens the member palette.

### S4 — Bot profile
- Hero face (animated), name, handle, role.
- Shortcuts: Chat · Rooms (n) · Routines (n).
- **Now**: what it is doing (worker session title, live session status, rooms
  where it is working), with Stop where the server allows it.
- Model & reasoning: editable (`model.options` → `profiles.configure`).
- Profile: SOUL, skills & tools, memory, machine.

### S5 — Downloads everywhere
- Any file or image in a normal chat, Bot Chat or room can be downloaded, opened
  with another app or shared. Verify the current normal-chat path and fix gaps.

## Motion (living Bots)
- Every face animates by state: idle (slow breath + random blink), thinking
  (look-around / scan), working (bounce/pulse ring), attention (nudge), speaking
  (while a reply streams). Entrance animation on first appearance.
- Reuse `HermesBotFace` motion states and `BotAvatarMotion`; one ticker per
  visible face; paused off-screen, in background and with reduced motion.
- Budget: roster with 20 animated faces keeps 60 fps on a current Pixel-class phone
  (profile build, no jank frames > 16 ms in steady state).

## Notifications (rich, interactive)
Goal: notifications that inform and let the user act without opening the app.

- **Conversation notifications** (Android `MessagingStyle`): each Bot is a
  `Person` with its face as icon; rooms are group conversations with each
  member as sender. Conversation shortcuts per Bot/room so they appear in the
  Conversations section, support bubbles and per-conversation priority.
- **Inline reply** (`RemoteInput`) to a Bot or room from the notification.
- **Approval notifications**: command/tool preview + buttons (Once, Deny, and
  Always when offered). Answered from the notification through the same server
  call as in-app; the card disappears everywhere once answered.
- **Live Updates** (Android 16+ `ProgressStyle`, promoted ongoing
  notification): while a Bot/room works — who, what step, elapsed time,
  subagents/processes count, Stop action. Falls back to an ongoing
  notification with progress on older Android.
- **Completion summary**: "<Bot> finished · <first line>" with Open / Reply.
- Grouped per Bot/room; dismissing in one surface (in-app read) clears it.
- **Room notifications** (none exist today; the listener only polls
  `/v1/runs`): the listener also watches rooms incrementally
  (`groups.state` + `groups.log since_seq`) and notifies, per the room's
  notification setting:
  - approval / clarify needed (actionable: Once / Deny / Open);
  - `@user` mention or a member escalating to the user (inline reply);
  - round finished with a short summary of who replied;
  - member failed / room blocked (Retry / Open);
  - Live Update while the room works: current round, who is working, Stop all.
  Room messages use MessagingStyle as a group conversation with each Bot as
  sender. Muted rooms only surface approvals.
- Delivery uses the existing foreground listener (no FCM). When the listener is
  off, only in-app state is shown; Settings explains why.

### Notification design bar ("Apple / Grok Bot quality")
Android renders notifications with system templates, so quality comes from
using the richest templates correctly, not from custom RemoteViews (Live
Updates forbid them). Rules:
- Every Bot/room notification is a **conversation** (MessagingStyle + Person
  with the Bot face rendered as a crisp circular bitmap, conversation
  shortcut, `setShortcutId`, category MESSAGE): shows in the Conversations
  section, on the lock screen with the face, supports bubbles.
- Copy is short and human: title = Bot or room, text = what happened in one
  line ("Needs your OK to run `gh pr ready 51`", "Round done · builder and
  review replied"). Never raw JSON, IDs or Markdown symbols (strip to plain).
- Actions are verbs, max 3, most likely first: Approve · Deny · Open;
  Reply (RemoteInput with smart replies off for approvals); Stop.
- Approval notifications are time-sensitive (high importance, heads-up),
  update in place when answered elsewhere and then auto-dismiss with a short
  "Approved from Desktop" confirmation.
- Live Update (API 36+): ProgressStyle with segments per round member, tracker
  icon = working Bot face, status-bar chip "builder · 2:14", `setWhen` +
  chronometer for elapsed, Stop action; demoted to a normal ongoing progress
  notification below API 36. Ends as a regular summary notification.
- Grouping: one group per Bot/room with a summary; silent updates for
  progress, sound only for approvals, `@user` and failures.
- Lock screen: sensitive content respects Android's "hide sensitive" setting
  (public version shows "<Bot> needs you" without the command).
- Animation: Android does not animate notification contents; motion lives in
  the tracker icon updates, the status-bar chip timer and in-app/widget faces.

## Home-screen and lock-screen widgets (Glance) — full redesign
Existing Console widgets (compact, control, new session) are replaced by a
coherent family with the Bot Mode visual language (dark surface, one accent,
Bot faces, generous radius, Material You dynamic colour optional):
- **Bots** (2×2 → 4×4): pinned/active Bots grid with state faces
  (idle/working/needs-you frames), "working on…" line, needs-you badge; tap →
  Bot Chat/room.
- **Needs you** (4×2): stacked pending approvals with Approve/Deny buttons
  (Glance actions → same server call through the listener), empty state
  "All clear".
- **Room** (4×2): chosen room, current round members with chips, last
  message, Stop.
- **Quick ask** (4×1 / 2×1): Bot face + "Ask <Bot>…" + mic → opens composer
  or dictation directly.
- **Status** (2×1): connection + working count, replaces the old compact one.
Rules: responsive layouts (SizeMode.Responsive with 3 breakpoints), previews
(`previewLayout` + generated previews API 35+), rounded corners from the
system (`system_app_widget_background_radius`), no stale "working" beyond the
proved window, state updates from the listener only (no polling from the
widget), and lock-screen/hub placement where the OS allows widget hosting
(`widgetCategory="keyguard|home_screen"`; availability depends on device and
Android version — verified, not assumed).

## Home-screen widgets (Glance)
- **Bots widget** (resizable): pinned/active Bots with state faces (static
  frames), "working on…" line, needs-you badge; tap → Bot Chat or room.
- **Needs-you widget**: pending approvals with Once/Deny buttons.
- **Quick ask**: pick a Bot and dictate/type (opens composer).
- Widgets update from the listener; never show stale "working" beyond the
  server-proved window.

## User stories and acceptance

### US1 — See who works (P0)
- Roster and room show the same working/needs-you state Desktop shows, within
  one refresh interval, from server data only.
- A Bot is "working" only with server evidence; never from local timers.

### US2 — Talk in rooms like a pro (P0)
- Markdown renders identically to main chat (golden tests of the shared widget).
- Tapping/selecting a message never scrolls it internally.
- Attach photo/file, send, and the room shows an attachment card that every
  member can read (see gap G1 for how).
- Every attachment in any chat can be downloaded/opened/shared.

### US3 — Stay in control (P0)
- Stop a working room/member; answer approvals in-app and from notification;
  retry a failed member turn; change a Bot's model.
- Each action is the server call Desktop uses; result reflected in Desktop.

### US4 — Same state as Desktop (P0)
- Rooms created in Desktop appear in Console (hosted: full; Desktop-only
  projection: read-only with label).
- Sections, pins and hidden Bots made in Desktop appear in Console and vice
  versa (`ui_meta`).
- Bot Chat opened from Console is the same session Desktop opens.

### US5 — Alive and beautiful (P1)
- Animated faces per § Motion within the performance budget; reduced motion
  respected.
- Visual review on a physical device before merge.

### US6 — Rich notifications (P1)
- MessagingStyle with Bot faces, inline reply, approval actions, Live Update
  with Stop, grouped per conversation; verified on a physical Android 16/17 device.

### US7 — Widgets (P2)
- Bots and Needs-you widgets functional on a physical device's home screen.

## Upstream gaps (file as issues/PRs in English on NousResearch/hermes-agent)
- **G1 Attachments in hosted rooms.** `groups.send` payload is `{text, thread_id}`
  only. Interim (same-gateway rooms): upload the file with Console's existing
  attachment upload to the server workspace and append a reference suffix, as
  Desktop does for its member turns; render the suffix as a card. Cross-gateway
  rooms: attach disabled with an explanation.
- **G2 Live per-member activity to clients.** `on_room_member_activity` reaches
  plugins only. Interim: `driver_status` + `turn.started/settled` + room
  activity; "Room is working…" when the member is unknown.
- **G3 Desktop still orchestrates rooms client-side.** Ask Desktop to use hosted
  `groups.*` (server already supports adoption via `Group: <room_id>`). Interim:
  Desktop-only rooms read-only in Console.
- **G4 Push without a foreground listener.** Out of scope; documented.

## Non-goals
- No changes to Hermes Agent or Desktop in this spec.
- No new Console-only persistence for shared concepts.
- No FCM/Google push.

## Definition of done
- All P0/P1 acceptance met on a physical Android 16/17 device with a real
  Hermes + Desktop.
- `flutter analyze` clean; full suite green; new behaviour covered by tests
  (RED→GREEN per root cause); performance budget measured.
- Independent review with no open P0/P1.
- Maintainer sign-off after on-device review of screenshots and a short screen
  recording.
