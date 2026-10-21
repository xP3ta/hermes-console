# Project brief

## The problem

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is a self-hosted AI
agent (by Nous Research) with memory, scheduled jobs, skills and MCP servers.
Its official interfaces are not built for a phone, and the usual ways of
reaching it from one all give something up:

- **A messaging bot** needs a third-party account and a third party in the path.
- **A browser or PWA** has no integration with the operating system:
  notifications, widgets, share sheet, App Lock.
- **A remote shell** is a developer workflow, not an everyday one.
- **Desktop-first web UIs** are not designed for a small screen.

## The solution

Console is a native Android client (Flutter) that connects remotely to the
Dashboard of the user's own Hermes Agent:

- **Remote.** Hermes runs on a computer, homelab or VPS, not on the phone. The
  app never runs a model locally on behalf of Hermes.
- **Private.** No Console account, no backend and no telemetry operated by XPeta
  Lab. Optional third-party services are disclosed in the privacy policy.
- **Private-network first.** Works over Tailscale, a LAN or HTTPS without
  exposing unauthenticated services to the internet.
- **Minimal permissions.** Each permission is justified in
  [`PLAY_PERMISSIONS.md`](PLAY_PERMISSIONS.md); Google Play Services is not
  required.
- **Faithful to Hermes.** Behaviour follows Hermes Desktop and Hermes Agent as
  the protocol contract (see [`UPSTREAM_CONTRACT.md`](UPSTREAM_CONTRACT.md)).

## Who it is for

- Self-hosters running Hermes Agent at home or on a VPS.
- People who prefer a privacy-respecting phone setup (including degoogled
  Android) and private networks such as Tailscale.
- Developers who want a hackable, open Hermes client for Android.
- Users of the Nous Research / Hermes ecosystem.

## What it is not

- Not a general AI chat app.
- Not a clone of any cloud provider's interface.
- Not a Hermes runtime: it does not run Hermes on the phone.
- Not a service for paid cloud AI; it brings no model access of its own.
- Not a project with telemetry, tracking or analytics.

## Stack

- **App:** Flutter (Dart), Android 7.0+ (API 24).
- **Server side:** Hermes Agent's Dashboard (self-hosted).
- **Connectivity:** HTTPS, LAN or a private network such as Tailscale.
- **Security:** Android Keystore through `flutter_secure_storage`; see
  [`SECURITY_POLICY.md`](SECURITY_POLICY.md).
- **Origin:** started from a fork of
  [`rusty4444/hermes-android`](https://github.com/rusty4444/hermes-android) (MIT
  notice preserved in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)).
