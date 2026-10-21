# Architecture

Console is a Flutter app for Android that connects to a self-hosted Hermes
Agent. This page is a map of the repository, not a specification: Hermes' own
Dashboard is the protocol contract, and
[`UPSTREAM_CONTRACT.md`](UPSTREAM_CONTRACT.md) lists exactly what the app
depends on.

## Big picture

```
[Console - Flutter app on Android]
        |
   HTTPS, or a private network (LAN / Tailscale)
        |
[Hermes Agent - your computer or server]
   '- Dashboard  :9119  admin API and the /api/ws JSON-RPC channel,
                        behind a sign-in when it listens on the network
```

There is no Console backend. The phone talks only to the Hermes servers the
user adds (and to optional downloads such as pets and voice models, which carry
no conversation data). Nothing else is required: no Google Play Services, no
push service.

## Repository layout

```text
lib/
  main.dart            App start, routing, cold-start cache and prewarm
  l10n/                English and Spanish strings (ARB)
  core/
    services/          Clients and engines: connection manager, the JSON-RPC
                       client for /api/ws, chat, notifications, voice, SSH/SFTP,
                       launcher-widget publishers, secure storage
    models/            Typed models of Hermes' payloads (parsed defensively)
    screens/           Full screens: chat, models, cron, tasks, settings, ...
    home/              The Home board and its widgets
    bots/              Bot Mode: profiles, rooms, state and UI
    companion/         Pets: Petdex catalogue, rendering, the app pet
    capabilities/      The Capabilities hub: skills, plugins, MCP, connectors
    shell/             Dock, floating pet and route watching
    design/ theme/     The shared design system and themes
    widgets/           Reusable widgets (composer, chat blocks, ...)
android/               Android integration: flavors, widgets, foreground
                       services, notifications, manifest
test/                  Unit, widget and contract suites
tool/                  Release, SBOM, QA and contract tooling
docs/                  This documentation
```

## Flavors

One reviewed source builds three flavors (see
[`RELEASE_DISTRIBUTION.md`](RELEASE_DISTRIBUTION.md)): `play` (Google Play),
`full` (GitHub Releases and Obtainium) and `qa` (emulator testing, a separate
package). A flavor is a distribution lane, not a feature switch.

## Connections and secrets

- A saved connection is the computer's address plus the Dashboard sign-in
  (older saved connections may still hold a Gateway key). Keys and sign-ins
  live in the Android Keystore through `flutter_secure_storage`; addresses and
  labels are not secret.
- Plain HTTP is allowed only toward loopback, private networks, Tailscale and
  local names; HTTP to a public address is blocked before any request. See
  [`SECURITY_POLICY.md`](SECURITY_POLICY.md).
- Drafts and a cache of recent chats are kept on the device; the authoritative history is
  the server's.

## Principles

- **Fail soft.** A missing server capability shows an honest "not available";
  it never crashes and never invents an endpoint.
- **Fast first paint.** The app shows cached state at once and refreshes in the
  background.
- **No telemetry.** No analytics or advertising SDKs.
