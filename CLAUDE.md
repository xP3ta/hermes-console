# Hermes Console — working notes for Claude

Flutter/Android client for a self-hosted Hermes Gateway. Chat with streaming,
voice, SSH/SFTP, Kanban, cron and on-device model management.

This file is the navigation map. Read it before searching the tree — it will
usually save you from opening a 10,000-line file to find a 40-line method.

## Read this first

**`docs/ARCHITECTURE.md` is aspirational, not current.** It describes a
`lib/features/<feature>/{data,domain,presentation}` layout that does not exist.
The real layout is `lib/core/{screens,services,widgets,models,utils,theme}`.
Use the map below; treat that doc as a design sketch.

Comments and doc comments across the codebase are largely in Spanish. User-facing
strings are English (see **i18n** below). Match the surrounding language when you
edit a file — do not mass-translate comments.

## Layout

```
lib/
  main.dart                     app bootstrap, routing, global lifecycle
  core/
    screens/    65 files 75k    one file per screen
    services/   82 files 42k    all I/O, state and protocol logic
      notifications/            foreground service + local notifications
      voice/                    STT, TTS, full-duplex conversation
      agent_runtime/            Termux-hosted local agent + install scripts
    widgets/    56 files 25k    shared UI components
    models/     39 files 14k    plain data types, JSON in/out
    utils/      20 files  4k    pure functions (parsing, classification)
    theme/      11 files  5k    theme presets and tokens
    companion/                  cosmetic pet system (Petdex format)
  l10n/                         *.arb sources + generated Strings class
```

## Where things live

| Task | Start here |
|---|---|
| Chat UI, bubbles, composer | `core/screens/chat_screen*.dart` (see below) |
| Turn lifecycle, streaming, recovery | `core/services/active_chat_*.dart` (see below) |
| Gateway WebSocket / JSON-RPC | `core/services/tui_gateway_client.dart` |
| REST client, SSE runs, auth | `core/services/connection_manager.dart` |
| Foreground service, notifications | `core/services/notifications/background_listener.dart` |
| Error → user-facing category | `core/utils/chat_error.dart` |
| Session list / titles | `core/screens/session_list_screen.dart`, `core/models/session.dart` |
| Local agent install (Termux) | `core/services/agent_runtime/agent_runtime.dart` |

## The two big files

Both are split with Dart `part` files. Part files share the library's private
scope, so a private member is visible across all parts of the same library —
but **imports live only in the main file**, and `// ignore_for_file:` does *not*
cross part boundaries (each part needs its own).

`core/screens/chat_screen.dart` (~11k) — `_ChatScreenState` only:

| Part | Contents |
|---|---|
| `chat_screen_render_model.dart` | render plan, slices, list-entry projection |
| `chat_screen_messages.dart` | user/assistant bubbles, error bubbles, empty states |
| `chat_screen_composer.dart` | text controllers, slash/mention palettes, send button |
| `chat_screen_attachments.dart` | attachment parsing, limits, image surfaces |
| `chat_screen_markdown.dart` | `AssistantMarkdownView`, code blocks, link previews |
| `chat_screen_scroll.dart` | streaming viewport lock/physics, scroll affordances |
| `chat_screen_chrome.dart` | app bar variants |

`core/services/active_chat_service.dart` (~11.5k) — `ActiveChat` only:

| Part | Contents |
|---|---|
| `active_chat_registry.dart` | `ActiveChatService`, the singleton chat registry |
| `active_chat_turn_delivery.dart` | `ActiveTurnDelivery` — did the turn cross the wire? |
| `active_chat_cancellation.dart` | durable Stop tombstones and their store |
| `active_chat_types.dart` | `ChatPipelineState`, `ActiveChatEvent`, small value types |

`ActiveChat` and `_ChatScreenState` are each still ~10k lines in one class; a
class body cannot be split across files in Dart. `_ChatScreenState` has `// ──`
region banners; `ActiveChat` has 189 methods and none, so navigate it by name:

| Concern | Grep for |
|---|---|
| Send paths (in fallback order) | `_startRemoteAgentTurn`, `_startDesktopTurn`, `_startRestFallbackWithAttachments`, `_startRemoteRun` |
| Public entry points | `Future<bool> send(`, `Future<void> steer(`, `Future<void> cancel(`, `Future<void> loadMessages(` |
| Inbound events | `_onDesktopEvent`, `_onRunEvent` |
| Reconnect / recovery | `_recoverDesktopTurn`, `_recoverTurnFromTranscript`, `_scheduleDesktopTurnRecovery`, `recoverTurnIfTransportLost` |
| Transcript hydration | `loadMessages`, `_loadStoredMessagesTail`, `loadEarlierMessages` |
| Stop / cancellation | `_cancelCurrent`, `_cancelDurably`, `_persistLatestUserCancellation` |
| Terminal states | `_failRun`, `_completeRun`, `_drainOrTerminal` |
| Queued follow-ups | `_drainQueue`, `_queueTextTurn` |

## Invariants that break silently

These have no compile-time guard. Breaking one produces a green build and a
broken app.

1. **`chat_error.dart` matches on message text.** `classifyChatError` decides
   which recovery UI a failure gets by substring-matching the strings emitted in
   `active_chat_service.dart` (`_humanizeBridgeError`, `_failRun`,
   `_armFirstTokenTimer`). Change one of those strings and you must update the
   needles. Order matters: the cold-start check runs before the generic local
   check, so a "took too long" message must not fall through. Spanish needles
   are kept deliberately — transcripts saved by older builds still contain them.

2. **Never await the foreground lease on the send path.**
   `_acquireActiveTurnForeground()` starts an Android foreground service; that
   is a trip to the OS. It is deliberately fired without `await` from
   `onForegroundKeepAlive` so `prompt.submit` is not delayed. Awaiting it adds
   latency to every turn and pushes integration tests into timeouts.

3. **Release channel separation** (see `AGENTS.md`, which governs). Flavors are
   `full` (GitHub/Obtainium), `play` (Play only), `qa` (internal, never public).
   Never publish a `play`/`qa`/`debug` artifact to a GitHub Release.

4. **`pubspec.lock` is enforced.** CI runs `flutter pub get --enforce-lockfile`.
   Running plain `flutter pub get` locally can rewrite it — revert it unless the
   dependency change is intentional.

5. **SBOMs are checked in.** CI runs `./tool/sbom/generate.sh` then
   `git diff --exit-code -- sbom`. Regenerate and commit when dependencies move.

6. **Launcher/splash assets are digest-pinned.** Changing any icon PNG requires
   updating `assets/branding/android-launcher-splash.sha256` and the tables in
   `ASSET_PROVENANCE.md`. Verify with
   `sha256sum -c assets/branding/android-launcher-splash.sha256`.

7. **Bilingual copy is not a translation bug.** Several surfaces pick language
   at runtime and legitimately contain Spanish: `NotifL10n._(es, en)`,
   `_text(es, en)` helpers, `_KanbanDetailCopy`/`_Kanban020Copy` (`spanish ? …`),
   and `…Copy.es` / `…Copy.en` const structs. Leave those alone. Also leave
   Spanish parser keys (`semantic_markdown.dart` heading and callout labels) and
   Spanish placeholder-title matchers (`session.dart`, `active_chat_service.dart`).

## i18n

`lib/l10n/app_en.arb` and `app_es.arb` generate the `Strings` class via
`gen-l10n` (`l10n.yaml`, `generate: true` in pubspec). `app_es.arb` is the
template. Prefer `Strings.of(context).<key>` for new user-facing text in
widgets. Services have no `BuildContext` and use plain English literals; that is
the established pattern there, not an oversight.

## Commands

```bash
flutter pub get
flutter analyze lib                     # must be clean
flutter test                            # ~4200 tests, ~8 min
flutter test test/chat_screen_test.dart # single file
./tool/sbom/generate.sh                 # regenerate checked-in SBOMs
```

**Known-failing:** the four `assistant_markdown_golden_test.dart` goldens fail
on any Flutter other than the pinned **3.44.1** (font rasterization differs).
They fail on clean `main` too. Everything else must pass.

## CI

- `.github/workflows/pr-quality.yml` — analyze + test on PRs and pushes to `main`.
- `.github/workflows/build-apk.yml` — builds signed `full` APKs. Triggers **only**
  on a `v*` tag or manual `workflow_dispatch`; it does not build on merge to
  `main`. Requires the `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD` and
  `KEY_ALIAS` secrets and hard-fails without them.

As of the last check neither workflow had ever executed, which suggests Actions
is disabled for the repository. Verify before relying on CI as a safety net.

## Conventions

- Path-specific `git add` only. Never `git add -A` (see `AGENTS.md`).
- Match the surrounding comment language when editing an existing file.
- Prefer moving code with `part` files over changing visibility: it keeps
  private access intact and needs no call-site edits.
