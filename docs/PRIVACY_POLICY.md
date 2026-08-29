# Privacy Policy — Hermes Console

**Last updated:** 2026-08-23

**Release scope:** `1.2.7 (915)`. This file is the canonical policy for the
candidate source. Before distribution, the deployed Spanish and English pages
must match this revision and identify the same date. Deployment verification,
the final signed AAB review and physical permission-flow QA are still pending;
a responding URL alone is not release evidence.

Hermes Console is a client app that connects to a Hermes Agent server that **you
host and control**. This policy explains exactly what the app accesses and why.
Public pages are hosted in
[Spanish](https://hermes.xpetalab.dev/privacy) and
[English](https://hermes.xpetalab.dev/en/privacy). Until the pending deployment
is verified, those pages must not be treated as release-current merely because
their URLs respond.

## The short version

- **The developer does not collect or receive your personal data.**
- **No developer-operated analytics, advertising, accounts, or tracking.**
- Your conversations and attachments travel to the server **you configure**.
  Optional voice and catalog features can contact the providers described below.
  They never pass through developer-operated servers — we don't operate any.
- Credentials (API tokens, passwords) are stored **encrypted on your device**
  (Android Keystore / secure storage) and leave it only to authenticate with the
  server or optional provider you choose.

## Data the app accesses on your device

| Capability | When | Purpose | Leaves the device? |
|---|---|---|---|
| Microphone | When you start dictation or voice conversation mode. Continuing a conversation outside the app is a separate choice and is off by default | Convert speech to text or continue a voice conversation you started | Processing depends on the speech engine you choose: on this device, by Android's speech provider, or by the speech server you configure. Background capture always has a persistent notification with controls |
| Camera | Only while scanning a QR or taking a chat attachment | Read a connection QR, or capture a photo you choose to send | QR frames and decoded content stay on-device in the open-source ZXing scanner. A captured attachment is sent to your configured server when you send it |
| Photos and documents | Only after you choose an attachment | Add selected content to a conversation | Sent to your configured server when you send the message |
| Notifications | App-generated, local | Show agent events and controls for voice or Read Aloud you explicitly keep active | No |
| Local storage / Keystore | Always | Store your connection settings and encrypted credentials | No |
| Network (internet/LAN) | When you connect or use an optional online feature | Talk to your Hermes server and fetch optional catalog/model content | See “Optional external services” below |

## Data we collect

**The developer receives none.** XPeta Lab operates no app backend and receives
no conversations, files, credentials, telemetry, or crash reports. There is no
Hermes Console account or advertising identifier.

## Optional external services

The app does not sell data and the developer never receives it. If you explicitly
enable or use one of these features, data is sent directly to the relevant
service under that provider's terms:

- Your messages, transcribed speech and attachments go to the self-hosted
  Hermes instance you select. Hermes is a third-party AI integration from the
  app's perspective and may itself send conversation content to the model,
  tool or search providers configured by that server's operator. Hermes Console
  cannot select or inspect those server-side providers. Review the privacy
  terms and configuration of your instance before connecting.
- Cloud text-to-speech (ElevenLabs or an OpenAI-compatible endpoint): the text
  to be spoken, using the API key and provider you configure.
- Android system speech recognition: microphone audio; depending on your device,
  Android may process it through its configured online speech provider.
- skills.sh search: the search phrase, proxied through your configured Hermes
  server, when you search the skills catalog.
- QR scanning uses the open-source ZXing library and runs entirely on-device.
  Camera frames, QR contents, decoded results and scanner metrics are not sent
  to XPeta Lab, Google or any other service.

Petdex assets and optional speech/AI models are downloaded from Petdex,
Hugging Face, or GitHub. These downloads do not contain conversation content,
attachments, or credentials.

## Security

- Credentials are stored using the Android Keystore / encrypted secure storage.
- HTTPS is supported and recommended for remote connections; the app warns when
  a connection is not encrypted.
- The app does not back up its data to cloud backup services.
- Camera capture only runs after a user action and never in the background.
- Microphone capture only starts from an explicit user action. Continuing a
  conversation after leaving the app is off by default and requires an
  affirmative choice. Android shows a persistent notification from which you
  can pause, continue, open, or end voice. Voice conversations and playback are
  never restored after reboot or process death and audio never starts from boot
  or a background receiver.
- If “Interrupt by speaking” is also enabled, that active voice conversation may
  keep listening while Hermes speaks so the user can interrupt or end it. This
  only runs on an echo-safe audio route and stops with the conversation, its
  notification controls, App Lock, or removal of the background opt-in.

## Retention and deletion

XPeta Lab does not receive or retain app data. Connection settings, drafts,
queued-turn recovery state, privacy-minimized notification delivery state,
downloaded voice models and credentials remain on your device until you remove
them in the app, clear the app's Android storage, or uninstall it. Notification
delivery state contains technical identifiers, statuses and cursors, not chat
text, notification previews or credentials. Credentials are stored in Android
Keystore-backed secure storage.

Conversations and attachments stored by the Hermes server follow the retention
settings of the server you configured. Where supported, deleting a conversation
in Hermes Console sends that deletion request to your server. You can also
manage or delete server data directly as its operator. Data sent to optional
Android, speech, TTS, model or tool providers is governed by those providers'
retention policies. Hermes Console does not create a developer-operated account.

## Children

The app is not directed at children. XPeta Lab does not knowingly collect
personal data from children or any other user.

## Changes

Updates to this policy will be posted at the URL above with a new date.

## Contact

Questions about privacy: **hola@xpetalab.dev**
