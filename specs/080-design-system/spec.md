# Spec 080 — One design system for all of Hermes Console

Status: Implemented (steps 1–5) in Hermes Console 1.2.14, together with
spec 070.

## Product decision

Console is judged by its weakest screen. Every surface must reach the quality
of the Bot profile screen (`lib/core/bots/ui/profile/bot_profile_screen.dart`):
one scroll per page, soft borderless groups of 52 dp rows, quiet uppercase
section headers, inline status text, one primary action, generous spacing.
Consistency beats novelty: the same problem is solved with the same component
everywhere.

Decisions:
- Cron detail and the schedule builder follow the approved mockups. The
  option picker's *content* (search, grouped options, check) is approved, but
  **modals stay floating**, never bottom sheets (keeps
  `test/no_bottom_sheet_contract_test.dart`).
- Review the design of the whole app so everything is coherent, not only the
  screens that triggered this spec.

Evidence: a design audit of every route (inventory, per-screen grades A–D,
file:line findings) sets the migration order below.

## Tokens (`lib/core/design/tokens.dart`)
- Spacing 4-pt: 4, 8, 12, 16, 20, 24, 32; page horizontal 18; section top 22 /
  bottom 8; row 14×10, row min 52, tap target 48.
- Radii: control 12, group 16, floating surface 22, dialog 22, tag 999.
- Type (6 steps, explicit colour): display 22/w700/-0.3, title 17/w600,
  body 14.5/w500, text 14/w400/h1.45, support 12.5/w400, caption 11.5/w700/+0.6
  uppercase.
- Titles never use the accent colour (theme `titleColor → textPrimary`).
- Status colours: neutral textSecondary, active accentText, ok success, warn
  warning, error error.
- Overscroll/`AlwaysScrollableScrollPhysics` only on page-level scrollables;
  inner blocks never bounce.

## Components (`lib/core/design/`, barrel `hermes_design.dart`)
| Component | Rule |
|---|---|
| `HermesPage` | App bar with one-line title (title style, left) + one `ListView` page scroll. Never `title: Column`. |
| `HermesDetailScaffold` | Action-first header (display title, `HermesStatusText`, short reason, one primary CTA, discreet freshness) + sections; title moves into the app bar on scroll (Bot profile pattern). |
| `HermesTextBlock` | Read-only text with **no own scroll**; collapsed to N lines with "Show all" expanding inline; mono variant; Copy. Huge text → "Open" → `HermesLogPage`. |
| `HermesLogPage` | Full page, mono, single scroll, Copy/Share. |
| `HermesListGroup` / `HermesListRow` / `HermesSectionHeader` | Exact values of the Bot profile `_Card` / `_Line` / `_Header`. Bot profile is refactored to use them (golden test proves pixel parity). |
| `HermesStatusText` | 6 px dot + support label in status colour + optional "· meta". No box. |
| `HermesTag` | Only for decision-changing states (Read-only, Failed, Needs you): tinted fill, radius 999, no border, max one per row. |
| `HermesToggleRow`, `HermesSelectRow` | Row + Switch; row + value + chevron opening a floating option surface. |
| `HermesSegmentedControl` | Existing; 2–4 inline options. |
| `showHermesFloatingSurface` (redesigned) | The ONE modal container: floating, rounded 22, content-sized (max 70% height), anchored to its origin when an origin rect is given (popover) else centred; scrim; IME/dock aware; drag/tap-out to dismiss; variants: option list (check, grouped, search when > 8), action list (icons, destructive last in red), short form. Never full-screen for pickers. |
| `showHermesMenu` | Popover anchored to its button (generalised dock-anchored popover), 48 dp rows, ≤ 6 actions. |
| `showHermesDialog` | Confirm/decide only (existing confirm shell: radius 22, title 17 w600, message 14, 48 dp pill buttons, destructive red). No long text, no forms. |
| `showHermesModelPicker` | One model picker (floating, search, provider groups, check, "Default"). Replaces 7 implementations. |
| `HermesScheduleBuilder` | Mode segment (Every day / Days / Interval / Month), day chips L–D, hour via Android time picker (themed), interval presets, day-of-month, live human summary + next run, cron expression only under "Advanced" with validation; bidirectional cron ↔ model parser. Used by cron, Bot routines, blueprints. |
| `HermesEmptyState`, `HermesNotice` | Unified empty state; one-line page notice with 48 dp close, no box. |
| `HermesActivityRow` | Flat transcript row for delegated work (subagents), opens a floating list, then a detail page with Stop. Replaces pill + completion cards. |

Contract tests (allow-lists that must shrink to zero): no `AlertDialog(`,
`showDialog(`, `DropdownButton`, `PopupMenuButton`, `HermesPill(`, literal
`Radius.circular` or `fontSize` outside `lib/core/design`; no vertical
`Scrollable` nested in another vertical `Scrollable` on detail routes; no
bottom sheets (existing).

## Functional fixes bundled (P0)
- Cron/kanban per-item notification mute is ignored by the real listener
  path (`deliverDiscoveryBatch`, background_listener.dart ~1771/1895) → honour
  it; expose as visible **"Notify me when it finishes"** and **"Only if it
  fails"** toggles on create, edit and detail.
- Kanban: notify on `done` (opt-in per task, default follows global setting).
- Cron form shows 09:00 regardless of the real schedule (`_describeCron`,
  `_presetFor`, cron_screen.dart ~2084-2156) → replaced by the builder's parser.
- In-app (foreground) notice for cron/kanban completion when the app is open.

## Screens (migration order)
1. Tokens + theme (titles, scroll physics) — app-wide.
2. Notification fixes above + tests.
3. Base components; Bot profile refactored onto them (golden).
4. Floating modal system: redesigned floating surface, menu, dialog, model
   picker; contract tests.
5. Cron: detail page, schedule builder, notification toggles, inline status
   (no "PROGRAMADA" box); Bot routine sheet and blueprints use the builder.
6. Kanban/Tasks: detail page, new-task form with select rows and floating
   pickers, priority segmented, editorial groups, log page, done notification.
7. Subagents: `HermesActivityRow` + floating list + detail page.
8. Remaining bubble-scroll details: skills, memory, session details, runs /
   task center, local instance logs, memory draft / soul diffs, read-only
   config.yaml.
9. Sweep the 93 `AlertDialog`s by file.
10. Remaining C/D screens (voice settings, local install, local instance
    control, ollama, instance edit, models, runs, session detail, onboarding)
    and every other screen reviewed against the reference: groups, rows,
    inline status, one-line titles.
11. Delete deprecated primitives (`HermesPill`, `HermesBadge`, `HermesGroup`,
    `HermesNavRow`, `HermesListSection`, `HermesPanel`, `AccentCard`,
    `CalloutCard`) when usage reaches zero.

## Implementation status (steps 1–5)
- Done: tokens + textPrimary titles + page-only overscroll; per-item Cron
  (all / only failures / off) and Kanban (mute, opt-in done) preferences
  honoured by `BackgroundAutomationDiscovery` (the real listener path), with
  an in-app notice for completions while the UI is in front; base components
  in `lib/core/design/`; Bot profile on the primitives (golden parity);
  `showHermesSurface` / options / menu / dialog / model picker; shrink-only
  contract tests; Cron detail page, editor page and `HermesScheduleBuilder`
  (bidirectional `HermesSchedule` parser); Bot routine sheet on the builder;
  blueprint time fields use the themed time picker.
- Model pickers still outside the shared one: chat (`chat_screen.dart`,
  phase 7/9). Mission Control has none of its own.
- Legacy `showHermesFloatingSurface` keeps a 0.88 cap for the forms/details
  that still live in surfaces until steps 6–8 turn them into pages.

## Definition of done
- Every route graded ≥ B+ against the reference in a final on-device review
  (physical Android 16/17 phone) with screenshots per screen, EN and ES.
- Contract tests green with empty allow-lists (or explicit, justified
  exceptions listed here).
- 360×800 and 390×844, text scale 1.3 and 2.0, no layout exceptions, 48 dp
  targets.
- `flutter analyze` clean, full suite green, independent review with no open
  P0/P1, maintainer sign-off on device.
