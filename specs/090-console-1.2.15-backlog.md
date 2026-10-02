# Hermes Console 1.2.15 — backlog (owner-approved scope notes)

## 0. How 1.2.15 is built: the Console team
From 1.2.15 on, the owner wants the work done by the Hermes Console bot team, driven and
followed from Console itself (dogfooding Bot Mode on the phone), instead of the lead agent alone.
- Team (Hermes profiles, room "Hermes Console Devs"): Astra = console-lead (tech lead, turns
  reports into verifiable contracts, decides scope), Forja = console-builder (implementation,
  RED→GREEN), Argos = console-review (independent review of frozen candidates), Radar =
  console-radar (read-only triage of issues/PRs/CI, local model).
- Flow per item: owner (or Radar) raises it in the room → Astra writes the contract + acceptance
  in the spec → Forja implements on a branch with tests → Argos reviews → Pixel QA → PR.
- The owner follows and steers from Console: room round panel, live notifications, subagent
  live transcript + steer, approvals from the shade; Desktop stays in sync.
- Preconditions to fix first:
  - Bot-to-bot DMs are broken upstream (`message_agent` runner: "No module named 'ruamel'",
    NousResearch/hermes-agent #122490, fix PRs #123070 / #122945 open). Until merged and the
    server updated, coordinate only through the hosted room, not DMs.
  - Update the owner's Hermes (~800 commits behind) in a quiet window, with backup, from Console
    (validates the update-tracking fix from 1.2.14).
  - Cost: Forja on Opus, Astra/Argos on Sonnet, Radar local — keep heavy work in few long turns.
- Keep all public output in English; never publish owner data (clean_snapshot.sh + term scan).

## 0.1 Fixes before 1.2.15 features
- **Orphaned composer drafts** (`fix/draft-orphan`): after a send is accepted, no draft of that
  turn may survive — even if the user leaves the chat before the ACK or the process dies. The
  draft is linked to the turn's `clientTurnId` once the outbox write is durable and is retired
  by that exact identity on ACK or on restore when the turn has left the outbox. Drafts of
  sends that were NOT accepted keep surviving close/process death. Fixes the duplicated
  draft row next to the real session and sent text reappearing in the composer.
- **Home lineage duplication** (`fix/home-lineage-dup`): investigated and closed without code.
  The server already projects compression chains to one row; the duplicate reported by the
  owner was the orphaned `mob-…` draft above.

## 1. Headline: Bot Desktop live view and takeover ("Pantalla")
Owner request (2026-09-27): watch live what a bot/subagent does on the host (browser, desktop)
and take control from the phone — fluid, no lag, no battery/network drain. Same model as Hermes
Desktop.

Upstream contract (already present on the owner's server, tui_gateway/methods_display.py +
tools/bot_desktop/*):
- `display.status` (runtime + lease), `display.start` / `display.stop` (Xvnc + Xfce per profile).
- `display.thumbnail` → one JPEG data URL (null while stopped; suppressed while a human holds the lease).
- `display.observe` → single-use 30 s ticket redeemed on sibling WebSocket `/api/display/ws`
  (raw RFB stream; watch-only unless holding the lease).
- `display.lease.acquire` / `display.lease.release` = Take over / Hand back; lease broadcast as
  global `display.lease` event; `computer_use` refuses to act while a human holds it.
- `display.install` (+ masked sudo request, streamed log, done event) installs host packages.
- Desktop reference: apps/desktop/src/plugins/hermes-bots/screen-*.ts(x).
- Owner's server: code present, Xvnc/Xfce NOT installed, no bot display running yet.

Plan: thumbnail (poll only while visible) → full-screen live viewer (RFB, view-only default,
pinch-zoom, landscape, incremental updates) → take over / hand back (touch→pointer, keyboard,
red border, agent pauses, lease synced with Desktop) → install flow. Spec, mockup, Pixel QA.

## 2. Visual overhaul (mockups first, owner picks direction)
Mockups in progress (private, scratch/mocks-1215): widgets A (Grok dark glass) vs B (Material You
tinted), notifications, every key screen, local models.
- Widgets: redo the Bot Mode family to Grok quality with each bot's CONFIGURED face; the current
  1.2.14 widgets are not good enough.
- Keep and redesign the original "Hermes Console" widget (instance/connection, model, session,
  New chat / Voice / Continue) as its own widget — do not replace it with Bot Mode widgets.
- Widget configuration activity (on place / long-press → Configure): Bots widget auto vs pinned
  bot/room, which bots and order, ticker on/off; Room widget room picker; Hermes Console widget
  instance, rows (model, session, metrics) and actions; style A/B/auto; transparency.
- Rest of spec 080 step 10: voice settings, local install/onboarding, local instance control,
  Ollama, instance edit, models, task center; ~28 remaining custom dialogs.
- Kanban "new task" form as a full page.

## 3. Local models like Hermes Desktop
Desktop now auto-detects the local llama.cpp runtime and manages local models through server REST
`/api/local-models/*` (status, hardware, catalog, runtime install, quickstart, download
pause/resume, activate/eject/delete, Hugging Face search + download, sideload, jobs). The owner's
server already exposes these routes. Console today only merges /v1/models with Ollama tags.
Plan in scratch/local-models-plan.md → a "Modelos locales" screen at parity (jobs polled only
while visible, confirm download size, metered-network hint, never auto-download).

## 4. Capabilities and subagents follow-ups
- Capabilities hub: add MCP server and connect accounts from the hub; `/skills` in chat should
  open the hub.
- Subagent in-transcript row is hidden (visible path: pill → panel → detail) — decide.

## 5. Before merging 1.2.14 (not 1.2.15, noted here so it is not lost)
- The 1.2.14 PRs replace the original "Hermes Console" widget with Bot Mode widgets (reused
  receivers). Restore the original widget unchanged in 1.2.14 before merge.
- Hide the new Bot Mode widgets from the picker in 1.2.14 (code stays; redesigned in 1.2.15).
- Notification polish from the approved mockups goes into 1.2.14: Live Update actions
  "Parar ronda" + "Abrir sala", expanded per-member state rows, lock-screen grouping in one
  row of faces.

## 6. Local agent in Termux — MOVED TO 1.2.16 (owner decision: 1.2.15 focuses on stability)
(full/GitHub flavor only — never in the Play flavor)
Goal: install and uninstall Hermes on the phone in Termux, fully guided and easy for anyone:
one-tap official Termux download, permission step, automatic Hermes setup via RUN_COMMAND with
visible numbered steps and progress, auto-connect when done, clean uninstall. End-to-end QA on a
disposable test device (never on the owner's Pixel install). Play policy: no downloading or
installing executable code from the Play build — keep the feature and its permissions out of
`play` (already the case via src/full manifest and kLocalAgentEnabled).

## 7. Home screen companion and dock (from the mockup review)
- Dock: a clean, interactive, premium navigation bar that moves you around fast and fluidly.
  KEEP a "+" (create) action but NOT as a big central button that eats the dock — a compact
  item integrated in the bar (same size/weight as destinations or a small accent pill at one
  end). Smooth, clean motion: sliding active indicator, springy press feedback, and a pleasing
  shared-axis/fade-through page transition between destinations; dark glass with backdrop blur,
  top hairline light, accent active icon, soft shadow. Keep current interactivity/gestures.
- Owner's sprite on Home "accompanies without getting in the way": mock 3 options (hero in the
  greeting reacting to Hermes state / small companion peeking above the dock / discreet header
  sprite that animates on news) and let the owner choose.
- Always render the CONFIGURED bot sprites/faces, never invented ones.
- Mockup fixes: local models belong to the SERVER (not "this phone"); remove "Pixel 9" sample
  data; Termux onboarding options only in the full flavor.

## 8. Input polish
- The typing cursor effect the owner likes in the clarify (interactive prompt) input must be the
  one used in EVERY text input of the app (composer, forms, search, dialogs). Confirm with the
  owner on the device which effect exactly (caret style/blink/animation) before implementing, then
  make it a shared input decoration/theme so all inputs match.

## 9. Voice
- Keep the current voice-mode screen look (owner likes it).
- Redesign voice SETTINGS as in the approved mockup (test orb on top, mode segmented Pulsar /
  Conversación / Manos libres, Escuchar and Hablar groups, speed slider in-row).
- Composer dictation visualizer: bars must react to the live voice level (today they stay flat);
  nicer bars in the style of Grok's voice input (rounded, smoothly animated, amplitude-driven,
  60 fps, respects reduced motion).

## 10. Capabilities deep-dive (priority)
- Review thoroughly how far Console can go with MCP servers, plugins, connectors, skills and
  toolsets (and new plugin types for Console itself): add MCP server and connect accounts from
  the hub, plugin catalog install/enable/update, per-bot "who uses it", `/skills` opens the hub.
  Research doc first (what the server exposes, what Desktop does, what's new upstream), then spec.
