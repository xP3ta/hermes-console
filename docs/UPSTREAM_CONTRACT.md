# Contract with upstream (Hermes Agent / Nous Research)

Console is a **client** of a third-party, self-hosted agent (Hermes, by Nous
Research). It therefore inevitably follows Hermes: if Nous changes its API,
ports or protocol, the app must be updated. This document lists **exactly what
depends on upstream and where to change it**, so that maintenance is a one-line
change and not a treasure hunt.

Design principle: **fail soft, never crash.** Every dependency on upstream
degrades to an honest state ("not available", "needs X") instead of crashing. A
feature is shown only when the connected server offers what it needs; Console
does not invent endpoints. The adaptation and its limits are described in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

Sources of truth for the contract (do not invent endpoints): Hermes Agent's own
source and the behaviour of a live Hermes server. Console talks to the Dashboard
of Hermes itself and to nothing else; the Mobile Bridge was retired in 1.2.15
(section 4) and the Gateway is no longer used (section 3).

---

## 1. Ports and endpoints

| What | Default | Where in the code |
|---|---|---|
| Gateway (API server, Bearer `API_SERVER_KEY`) | `:8642` | Not used by the app (section 3); the port field of `SavedConnection` only remains for older saved connections |
| Dashboard / admin API | `:9119` | `SavedConnection` (`dashboardPort`) |

If Hermes changes a default port, update the constants in `SavedConnection` and
the connection screen (`instance_edit_screen.dart`). The setup helper
([xP3ta/hermes-setup](https://github.com/xP3ta/hermes-setup)) uses the same
defaults and lets them be moved. The official command that opens the Dashboard
to the network is `hermes dashboard --host 0.0.0.0`; on a non-loopback bind
Hermes always requires a Dashboard sign-in.

## 2. Dashboard (what the app uses)

`ConnectionManager` and the typed clients around it. Authentication, in the order
the app prefers: a cookie session after the Dashboard login, a session token
scraped from the Dashboard HTML (`window.__HERMES_SESSION_TOKEN__`) and sent as
`X-Hermes-Session-Token`, or Basic Auth, according to what the server really
accepts.

- **Chat and live state:** the WebSocket `/api/ws` carrying JSON-RPC 2.0, the
  same channel Hermes Desktop uses (`TuiGatewayClient`, sessions, history,
  approvals, profiles, rooms, Kanban and voice methods). Unknown
  methods degrade silently.
- **REST endpoints used:** `/api/status`, `/api/profiles` (and `/{name}/soul`),
  `/api/sessions`, `/api/model/info|options|set`, `/api/cron/jobs`, `/api/logs`,
  `/api/config`, `/api/env`, `/api/mcp/servers`, `/api/plugins` and the voice
  endpoints under `/api/audio/*` (including `voice-live` for GPT-Live). Most are
  scoped by profile with `?profile=`.
- If an endpoint changes shape or name, it is centralised in
  `connection_manager.dart` (look for `apiGet`/`apiPost`) and in the typed
  clients of `lib/core/services/`.

The main model is **not isolated per profile**: `POST /api/model/set?profile=X`
changes the model of the running gateway (there is a single gateway). The app
asks for confirmation first. That is Hermes' semantics, not an app bug.

## 3. Gateway (retired from the app)

The app no longer calls the Gateway REST API (`/v1/runs`, `/v1/models`,
`/v1/capabilities`, `/v1/skills`, `/v1/toolsets`, `/health` on the Gateway
port). Chat, history, approvals and every other read go through the Dashboard.
The only Gateway requests left are three liveness lines for a saved connection
that has no Dashboard; a CI test
(`test/u6_gateway_retirement/gateway_gate_test.dart`) pins that list. No
`API_SERVER_KEY` is asked for when adding a connection.

## 4. Mobile Bridge (retired in 1.2.15)

The app no longer talks to the Mobile Bridge (`:9131`). Skills, SOUL, memory,
cron and Dashboard access go through Hermes' own Gateway and Dashboard. The app
has no bridge client, provisioning or update, and no request goes to `/bridge/*`
(guarded by retirement tests).

What remains of an earlier install:

- On the phone, the Keystore secrets `bridge_url_<id>` / `bridge_token_<id>` and
  the `bridge_auto_update` preference are deleted on the first launch after
  updating (`LegacyBridgeRetirement`), after probing each instance's Dashboard
  once.
- On the server, the bridge service keeps running until its owner stops it: the
  Linux user unit `hermes-bridge.service`, the macOS LaunchAgent
  `dev.xpetalab.hermes-console.bridge`, or the Windows tasks
  `HermesConsole-MobileBridge` and `HermesConsole-Restart-MobileBridge`. The
  app shows how to remove it (the setup helper's `--retire-bridge` /
  `-RetireBridge` line); it does not remove it itself.

The Dashboard should run as a **service** (systemd user unit, LaunchAgent or
Scheduled Task), not as a manual process, or `hermes update` will take it down.
Hermes ships no service for the Dashboard itself; the published setup command
(`hermes-dashboard-setup`) creates one (systemd user unit, launchd job or
Scheduled Task).

## 5. Setup helper

The app ships no setup scripts. `HermesSetupCommands`
(`lib/core/services/hermes_setup_commands.dart`) holds the helper's four lines
per system (set up, show the code again, a new Dashboard sign-in, retire the
bridge); a test pins them so the app and the helper cannot drift apart. If the
helper's URL or arguments change, change them there. The pairing link
(`hermes://pair`) is the format of the older helper: it carries the address and
a key and, when known, the Dashboard sign-in (`dash_user`, `dash_pass`); the app
shows what a link sets up before saving anything. The Dashboard-only flow needs
no helper and no link: see [server configuration](CONFIGURATION.md).

## 6. On-device neural voice (TTS, models from GitHub releases)

The voice that reads replies can be neural and fully on-device (no cloud, no key)
through `sherpa_onnx` and a Piper/VITS model downloaded at runtime.

| What | Value | Where |
|---|---|---|
| Voice catalogue | id/url/dirName/onnxFile | `kNeuralVoices` in `tts_model_manager.dart` |
| Model source | the sherpa-onnx `tts-models` release (`.tar.bz2`) | `_ttsRelease` |
| Synthesis engine | `OnDeviceNeuralTtsEngine` | `tts_engine.dart` |

Each voice is one `.tar.bz2` with `<voice>.onnx`, `tokens.txt` and
`espeak-ng-data/`. It is downloaded with progress to disk and extracted in an
isolate. **Fail soft:** if the chosen voice is not downloaded, the app falls back
to the system voice (`DeviceTtsEngine`). To add a voice, add an entry to
`kNeuralVoices` and check that the URL exists in the release and that
`dirName`/`onnxFile` match the archive. The native libraries come from the
plugin and add roughly 30 MB per ABI, so publish as an AAB / split-per-ABI APKs,
never a universal APK.

---

## Checklist: "Hermes changed something, what do I touch?"

- A Dashboard endpoint -> `connection_manager.dart` and the typed client that
  uses it.
- A JSON-RPC method of `/api/ws` -> `tui_gateway_client.dart`.
- A port -> `SavedConnection` and `instance_edit_screen.dart` (9119 Dashboard;
  8642 is the retired Gateway).
- The helper's lines -> `hermes_setup_commands.dart` (and its test).
- The shape of a payload -> the matching `*.fromJson` (parse defensively).
