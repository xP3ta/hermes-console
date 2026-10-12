# Installation

Console requires Android 7.0 (API 24) or newer. It does not include Hermes Agent
or an AI service: before connecting it, you need a Hermes server that you
control. Do not install or share a `qa`, `debug` or `profile` APK; those are
internal test builds, not distribution artifacts, and the QA flavor uses a
different package name.

## Requirements

- Android 7.0 (API 24) or newer.
- A Hermes Agent you run, with its **Gateway** (default port 8642, with an
  `API_SERVER_KEY`) and **Dashboard** (default port 9119) reachable from the
  phone. The setup helper prepares both.
- There is no fixed minimum Hermes version: a feature appears when your server
  offers what it needs, and older servers simply show less. A few things, such
  as per-session settings, need a recent Hermes (0.19 or newer).
- Console 1.2.15 or newer to use the current setup helper.

More in [server configuration](CONFIGURATION.md) and the
[upstream contract](UPSTREAM_CONTRACT.md).

## Official installation channels

### Google Play

Install the app from its
[Google Play listing](https://play.google.com/store/apps/details?id=dev.xpetalab.hermesconsole)
(titled "Hermes Console by XPeta Lab"). The package is
`dev.xpetalab.hermesconsole` and Play builds use Play App Signing. Installing a
build with ADB does not validate the update path delivered by Google Play.

### Obtainium

Install [Obtainium](https://github.com/ImranR98/Obtainium), choose **Add App**
and paste `https://github.com/xP3ta/hermes-console` (or use the
[Add to Obtainium](https://hermes.xpetalab.dev/obtainium/) button). Confirm that
it detects GitHub Releases and verify the published signature before switching
from another update channel.

### Direct APK

Only install a production APK attached to an official
[GitHub Release](https://github.com/xP3ta/hermes-console/releases). Releases carry
the signed `full` build as one APK per CPU architecture; most phones need
`arm64-v8a`. Before installing, verify the published version, signing
certificate and SHA-256 digest.

The `play` and `full` variants share the same package and cannot coexist. The
`qa` variant has a separate package for internal testing and must never be
presented as the public APK.

### Troubleshooting: "App not installed"

Google Play builds are re-signed by Play App Signing, while GitHub/Obtainium
builds are signed with the project's own key. Android only updates an app with a
build signed by the same key, so installing a GitHub APK over a Play install (or
the reverse) fails with **App not installed** (sometimes "package conflicts with
an existing package").

To switch channel:

1. Check the current channel in **Settings → About → Updates**.
2. Export or note anything you need (connections can be re-paired).
3. Uninstall Console.
4. Install it from the other channel.

Stay on one channel afterwards; updates then install normally.

## Build from source

Requirements for the current tree:

- Flutter 3.47.x and the Dart SDK bundled with it.
- Java 17.
- Android SDK 36.

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --flavor full --dart-define=HERMES_FLAVOR=full
```

The debug output is for development only. Release builds require a signing key
kept outside this repository and all gates in
[Release and distribution](RELEASE_DISTRIBUTION.md). Never commit keystores,
`key.properties`, tokens, or generated APK/AAB files.

## First launch

1. Open Console. The first screen offers one action, **Scan code**.
2. On the computer where Hermes lives, run the setup helper's one line (see the
   [README](../README.md#connect)); it shows a code. Scan it,
   or paste its `hermes://pair` link. If you cannot, choose **I don't have a code** for the
   numbered recipe, or add the connection by hand as described in
   [server configuration](CONFIGURATION.md).
3. Console says in plain words what it is about to connect, then checks the
   address, the chat key and the Dashboard sign-in before saving anything.
4. Grant camera access only on the scan screen (pasting the code works without
   it) and microphone access only when you use voice. Notifications are asked for
   once, after the first connection is saved, never on opening the app.

A pairing code or link carries access details. Treat it as a secret: do not share
it, include it in an issue, or expose it in screenshots or media.

Coming from a Mobile Bridge install? See "Coming from a Mobile Bridge install" in
[server configuration](CONFIGURATION.md).
