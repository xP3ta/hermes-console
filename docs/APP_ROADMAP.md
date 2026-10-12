# Roadmap

Console follows the public contracts exposed by Hermes Agent and adapts
them to Android without inventing server APIs.

## Current priorities

- Keep text chat stable while expanding structured image and artifact support.
- Finish physical-device validation of streaming Voice, interruption and audio
  routing.
- Keep Bots rooms, mentions and task workflows aligned with Hermes Desktop.
- Improve accessibility, large-text layouts and Android navigation.
- Maintain reproducible GPL-compatible builds and dependency inventories.

## Planned

- Broader automated integration coverage against supported Hermes Agent
  versions.
- Continued Google Play policy and target-SDK maintenance.
- Contributor documentation for adding server capabilities without coupling
  the app to a private deployment.

## Non-goals

- Telemetry, advertising or analytics SDKs.
- Bundled paid model services.
- Invented compatibility endpoints that Hermes Agent does not expose.
- Publishing private QA builds, credentials or deployment topology.

Roadmap items are intentions, not compatibility guarantees. Proposed protocol
changes should include an upstream contract reference and tests.
