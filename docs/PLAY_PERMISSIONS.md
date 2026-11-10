# Google Play — Permissions justification

Justification of each permission for Google Play review. The table is the
merged manifest policy of `1.4.0 (9812)`: the app's own
`android/app/src/main/AndroidManifest.xml` (shared by the `play` and `full`
flavors; `android/app/src/full/AndroidManifest.xml` declares nothing extra) plus
what its dependencies add. It is enforced as an exact set by
`tool/release/full_release_policy.json` (APKs: `inspect_public_apk.py`; any
manifest text, AAB included: `check_manifest_policy.py`) and by
`test/release_policy_truth_test.py`. The table is the current source and policy
(21 entries: 20 permissions plus the signature permission of AndroidX), no
package queries and the foreground services listed below. It has not been
checked against the final signed AAB: no hash is recorded here. Before copying
any text into Play Console, repeat the check on the exact AAB selected:
`java -jar bundletool.jar dump manifest --bundle=<aab> > manifest.xml` and then
`python3 tool/release/check_manifest_policy.py --manifest manifest.xml --pubspec pubspec.yaml`.

## Permissions of the Play build

| Permission | Used for | Justification |
|---|---|---|
| `INTERNET` | Connecting to the user's own Hermes server | Core function |
| `ACCESS_NETWORK_STATE` | Adapting network components to connectivity | Normal permission added by Android dependencies and declared in the manifest; used for an immediate retry when connectivity returns |
| `RECORD_AUDIO` | Dictation and voice conversation | Starts only after a user action and its disclosure. Continuing a conversation outside the app needs a separate opt-in and a persistent notification; the app does not store the audio |
| `CAMERA` | Scanning a connection QR code or taking an attachment photo | Opened only after a user action. ZXing processes the QR frames entirely on the device; a captured photo goes only to the configured server when the user sends the message. No background capture |
| `POST_NOTIFICATIONS` | Replies, approvals, questions and voice/read-aloud controls | Local notifications raised by the app while it is open and, with the app closed, by the opt-in background listening (off by default; continuous), by the turn service (on by default, up to 30 min while a turn the user started runs) and by a bounded check (up to 10 min) that announces when that turn ends, all over the user's own connection to their server and none under App Lock for the last two; persistent controls for audio the user started. Console uses no Firebase or third-party service for notifications. Asked for once, after the first connection is saved |
| `POST_PROMOTED_NOTIFICATIONS` | Android 16 Live Updates | Lets a turn or a room that is working appear as a live update (status-bar chip, lock screen) with its progress. Normal permission without a dialog; the lock-screen version never names a chat or a tool |
| `MODIFY_AUDIO_SETTINGS` | Audio mode and routing of the opt-in GPT-Live voice session | Normal permission used by `flutter_webrtc` to set the communication audio mode while a live session the user started is running. Off by default; no audio leaves the device unless the user enables GPT-Live and starts a session |
| `CHANGE_NETWORK_STATE` | Network handling of the same WebRTC session | Normal permission declared by the WebRTC stack; used only while a GPT-Live session is open |
| `BLUETOOTH` (Android 11 and older) | Letting the audio of a GPT-Live call follow a Bluetooth headset | Normal install-time permission, limited to `maxSdkVersion=30` and added by the call-audio library under `flutter_webrtc` (Twilio AudioSwitch). No dialog, and modern Android does not receive it. Used only while a GPT-Live session the user started is running, and only to see which headset is already connected: no scanning, pairing or device list. Console requests neither `BLUETOOTH_CONNECT` nor `BLUETOOTH_SCAN`, so that library cannot manage Bluetooth headsets on Android 12 and newer. `android.hardware.bluetooth` is declared `required=false`, so no device is filtered out |
| `VIBRATE` | Notification feedback | Complements notifications |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` | Keeping explicit SSH/SFTP work visible in the background, and the connection of a running turn after the user leaves the app | Type `dataSync`: keeps SSH/SFTP the user started (a separate native service on API >= 35, the shared Flutter service on Android <= 14). Ends with the operation or with the Stop action of its notification. Since 1.4.0 a separate native service also keeps the existing connection to the user's server while a turn runs and the app was just left (stops with the turn, on return, or after 30 min; setting on by default; never with App Lock). The only continuous background polling is the opt-in listening (next row); a separate bounded check of at most 10 min, with no opt-in, reads the chat to announce the end of that turn, which on Android <= 14 also runs as `dataSync` |
| `FOREGROUND_SERVICE_REMOTE_MESSAGING` | Keeping the opt-in background listening on Android 15+ | Type `remoteMessaging`, same as 1.3.1: keeps the user's own connection to their Hermes server so Cron, Kanban and room notices arrive with the app closed. Off until the user switches on Settings > Notifications > "Listen in background"; shows a persistent notification and avoids the finite dataSync budget of Android 15. On Android <= 14 the same listening uses `dataSync` |
| `RECEIVE_BOOT_COMPLETED` | Restoring the listening the user chose | Re-arms only the opt-in listening after boot or an update (`remoteMessaging` on API >= 35, `dataSync` on API <= 34). Never starts microphone, playback, SSH or SFTP, and does nothing if the user did not opt in |
| `FOREGROUND_SERVICE_MICROPHONE` | Continuing a voice conversation outside the app | Type `microphone`: started only from a visible Activity, after `RECORD_AUDIO` and the matching opt-in. Shows persistent controls and never starts from boot or a receiver. The conversation is not restored after process death |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Continuing read-aloud and voice replies | Type `mediaPlayback`: protects audio the user asked for; the notification carries no conversation content and is not restored from boot or process death |
| `USE_BIOMETRIC` | Optional App Lock with device biometrics | Verification is delegated to Android through `local_auth`; Console never accesses biometric templates or data |
| `WRITE_EXTERNAL_STORAGE` (Android 9 and older) | Saving a generated image when the user taps "Save" | Limited with `maxSdkVersion=28`; modern Android does not receive it |
| `WAKE_LOCK` | Keeping a user-started operation alive while its foreground service runs | Added by `flutter_foreground_task`; the app configures the service without wake or Wi-Fi locks and nothing runs without work |
| `USE_FINGERPRINT` | Biometric compatibility on old Android | Legacy alias added by `local_auth`; the app does not access biometric data |
| `dev.xpetalab.hermesconsole.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | Restricting internal dynamic receivers | `signature` permission generated by AndroidX so that only code signed like the app can address non-exported receivers; not a user permission and grants no access to device data |

### Foreground services — declaration for Play Console

- **Type `dataSync`:** keeps user-started SSH/SFTP (an ephemeral native service on
  API >= 35, the shared Flutter service on API <= 34). Offers a notification and
  a direct stop. Since 1.4.0 `HermesTurnKeepAliveService` keeps the connection
  of a running turn while the app is in the background, bounded to that turn
  (30 min cap), like Hermes Desktop's keep-awake «while working»; it never
  polls. With the app closed the server is read by: that turn service (its
  socket), a WorkManager check of at most 10 minutes (`HermesLiveTurnCheckWorker`,
  one bounded read of the chat to announce the end of the turn, no opt-in, not
  under App Lock) and the user's opt-in listening (below), the only continuous
  poll.
- **Type `remoteMessaging` (API >= 35; `dataSync` on API <= 34):** the opt-in
  background listening of 1.3.1, kept in 1.4.0. It polls
  the user's own server every 30 s to 3 min for Cron, Kanban and room events,
  starts only after the user switches it on, shows a persistent notification and
  carries no notice content while App Lock is on. Same declaration as 1.3.1.
- **Type `microphone`:** keeps a user-started conversation after the continuity
  opt-in. Ending it releases the microphone and downgrades the service.
- **Type `mediaPlayback`:** keeps read-aloud, the replies of a voice conversation
  and their controls to pause/resume or end the audio.
- The four types, the impact of being deferred or interrupted, and their videos
  are detailed in [`PLAY_FGS_DECLARATION.md`](PLAY_FGS_DECLARATION.md).

## Sensitive and restricted permissions — status

- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: not declared in any flavor.
- No flavor contains the retired on-device agent's `com.termux.permission.RUN_COMMAND`
  or any `<queries><package>` entry; the release policy forbids the permission and
  requires an empty package-query list.
- `RECEIVE_BOOT_COMPLETED`: used only to re-arm the opt-in listening (see the
  table). The copy `flutter_foreground_task` adds and its boot receiver are
  stripped; the app's own `HermesAutomationRebootReceiver` sanitises the state
  first and does nothing without the opt-in.
- `QUERY_ALL_PACKAGES` is not used. The `queries` block declares only the speech
  recognition service, the text-to-speech service, `PROCESS_TEXT` and `http`
  links, so that the system speech engines and links resolve on Android 11+.
- `USE_FULL_SCREEN_INTENT` is not declared; voice uses a normal notification and
  never takes over the lock screen with an Activity.
- `READ_PHONE_STATE` and `READ_EXTERNAL_STORAGE` are removed explicitly in the main
  manifest as a defense against transitive additions. Android <= 9 may list read
  access as a historical consequence of `WRITE_EXTERNAL_STORAGE maxSdkVersion=28`;
  Console does not enumerate or import general storage, and attachments use the
  system file picker and Photo Picker. A dependency may also re-add
  `READ_EXTERNAL_STORAGE` limited with `maxSdkVersion=28` (seen in a QA APK of
  the 1.4.0 candidate, not in the source manifest); the release policy forbids
  that permission, so the manifest check on the final signed AAB must pass or
  the entry be removed. The effective result must be confirmed on the final
  signed AAB.
- Camera and microphone are declared with `uses-feature required=false`, so Play
  does not filter tablets or Chromebooks where those optional features are
  missing.
- The app declares no SMS, call-log, contacts, location or accounts permissions.

## Evidence pending before Play

- Merged manifest and effective permissions of the exact signed AAB (the command
  at the top of this document).
- Emulator end-to-end run of the camera permission and lifecycle with a test QR
  image read by ZXing, including denial and the paste-the-code fallback.
- The four foreground-service videos (`dataSync`, `remoteMessaging`, `microphone`, `mediaPlayback`) and the emulator QA described in
  [`PLAY_FGS_DECLARATION.md`](PLAY_FGS_DECLARATION.md).
- Agreement between this table, Data Safety, the deployed privacy policy and the
  artifact finally selected in Play Console.
