# Privacy Policy — Hermes Console

> **DRAFT of proposed changes for the owner's review. This is not the deployed
> policy.** The date below is deliberately unchanged; the owner decides the
> final wording, the date and the declaration made to Google Play.

**Last updated:** 2026-10-12

**Release scope:** `1.2.15 (9540)`. This file is the canonical policy for the
current source. The deployed Spanish and English pages must match this revision
and identify the same date; a responding URL alone is not release evidence.

Hermes Console (the app is called Console on your device) is a client app that
connects to a Hermes Agent server that **you host and control**. This policy
explains exactly what the app accesses and why.
Public pages are hosted in
[Spanish](https://hermes.xpetalab.dev/privacy) and
[English](https://hermes.xpetalab.dev/en/privacy).

## The short version

- **The developer does not collect or receive your personal data.**
- **No developer-operated analytics, advertising, accounts, or tracking.**
- Your conversations and attachments travel to the server **you configure**.
  Optional voice and catalog features can contact the providers described below.
  They never pass through developer-operated servers — we don't operate any.
- Credentials (Dashboard username and password or session token, SSH
  credentials, API tokens) are stored **encrypted on your device** (Android
  Keystore / secure storage) and leave it only to authenticate with the
  server or optional provider you choose.

## Data the app accesses on your device

| Capability | When | Purpose | Leaves the device? |
|---|---|---|---|
| Microphone | When you start dictation or voice conversation mode. Continuing a conversation outside the app is a separate choice and is off by default | Convert speech to text or continue a voice conversation you started | Processing depends on the speech engine you choose: on this device, by Android's speech provider, or by the speech server you configure. Background capture always has a persistent notification with controls |
| Camera | Only while scanning a QR or taking a chat attachment | Read a connection QR, or capture a photo you choose to send | QR frames and decoded content stay on-device in the open-source ZXing scanner. A captured attachment is sent to your configured server when you send it |
| Photos and documents | Only after you choose an attachment | Add selected content to a conversation | Sent to your configured server when you send the message |
| Notifications | App-generated, local | Show agent events and controls for voice or Read Aloud you explicitly keep active | No |
| Local storage / Keystore | Always | Store your connection settings and encrypted credentials | No |
| Network (internet/LAN) | When you connect or use an optional online feature | Talk to the Dashboard of your Hermes server and fetch optional catalog/model content | See “Optional external services” below |

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
- Voice served by your Hermes: when you choose the Hermes server for speech, the
  text to be spoken or the audio to be transcribed goes to your server, which
  uses the speech providers configured there. Console no longer sends speech
  to speech services of its own.
- GPT-Live voice (off by default, available only when your server enables it):
  the phone starts a real-time audio session with the voice provider your server
  uses, through a session your Hermes server creates, and audio then flows
  between the phone and that provider under the provider's terms. The provider
  key stays on your server.
- Android system speech recognition: microphone audio; depending on your device,
  Android may process it through its configured online speech provider.
- Skills catalog search: the search phrase goes to your configured Hermes
  server, which looks it up in the skill sources it is set up with (skills.sh,
  GitHub and others) under their terms. Console does not contact those
  sources itself.
- Rich embeds in chat (YouTube, Vimeo, Spotify, X, Instagram, TikTok,
  Pinterest, maps): off for every type by default. If you turn a type on, or
  allow one when asked, opening that embed loads a page from the service in a
  sandboxed web view, so that service sees your IP address and browser. The
  choice is stored on the device only.
- SSH and SFTP: if you add an SSH host, Console connects directly to the host
  you enter; the host, user and credentials you save stay on the device.
- Signing in with your account: if your Dashboard uses an account sign-in,
  Console opens the system browser on the sign-in page and stores the resulting
  token only in secure storage.
- QR scanning (for a pairing code made by an older setup helper) uses the
  open-source ZXing library and runs entirely on-device.
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
