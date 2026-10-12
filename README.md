<p align="center">
  <a href="https://hermes.xpetalab.dev"><img src="assets/branding/console_banner.png" width="100%" alt="Console, the Android app for your self-hosted Hermes Agent" /></a>
</p>

<p align="center">
  Your self-hosted Hermes Agent, native on Android.
  <br><br>
  <a href="https://play.google.com/store/apps/details?id=dev.xpetalab.hermesconsole"><img align="middle" height="52" alt="Get it on Google Play" src="docs/badges/google-play-en.png"></a>
  <a href="https://github.com/xP3ta/hermes-console/releases/latest"><img align="middle" height="52" alt="Get it on GitHub" src="docs/badges/get-it-on-github.png"></a>
  <a href="https://hermes.xpetalab.dev/obtainium/"><img align="middle" height="52" alt="Get it on Obtainium" src="docs/badges/obtainium.png"></a>
  <a href="https://hermes.xpetalab.dev"><img align="middle" height="52" alt="Visit the website" src="docs/badges/visit-website-en.png"></a>
  <br><br>
  English · <a href="README_ES.md">Español</a>
</p>

<p align="center">
  <img src="docs/screenshots/1.2.15/home.png" width="23%" alt="Console Home: a board with what is happening now, chats, bots, rooms, cron jobs and tasks" />
  <img src="docs/screenshots/1.2.15/chat-live.png" width="23%" alt="A chat while Hermes works, with its thinking, tools and tasks in the conversation" />
  <img src="docs/screenshots/1.2.15/voice.png" width="23%" alt="A voice conversation inside the chat" />
  <img src="docs/screenshots/1.2.15/bots.png" width="23%" alt="Bot Mode: the profiles of a Hermes server, each with its own face" />
</p>

## What it is

Console is an independent Android app for [Hermes Agent](https://github.com/NousResearch/hermes-agent), the agent you run on your own computer or server. It talks straight to Hermes' own Gateway and Dashboard, with no Console account and no server of ours in between.

## Connect

Run it where Hermes lives, scan the code it shows. Needs Console 1.2.15 or newer.

```sh
# Linux, macOS
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh
```

```powershell
# Windows, WSL2 (Windows PowerShell 5.1+, as administrator)
irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1 | iex
```

<details>
<summary>Coming from an older install?</summary>

<br>

Console 1.2.15 no longer uses the Mobile Bridge. Once every phone is on 1.2.15 or newer, one line removes the bridge from the computer and nothing else:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh -s -- --retire-bridge
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1))) -RetireBridge
```

</details>

## What you can do

- A chat that shows the work: reasoning, tools and tasks, in plain words
- Voice conversations inside the chat
- Bots and rooms, one identity per Hermes profile
- Cron jobs and tasks, on a board or a list
- Models, with real provider removal
- An SSH terminal, SFTP and inline file viewers

<details>
<summary>More screens</summary>

<br>

<p align="center">
  <img src="docs/screenshots/1.2.15/room.png" width="23%" alt="A bot room with several profiles replying" />
  <img src="docs/screenshots/1.2.15/tasks-board.png" width="23%" alt="The Tasks board" />
  <img src="docs/screenshots/1.2.15/tasks-list.png" width="23%" alt="The Tasks list" />
  <img src="docs/screenshots/1.2.15/cron.png" width="23%" alt="Scheduled Cron jobs" />
  <img src="docs/screenshots/1.2.15/models.png" width="23%" alt="The Models screen" />
  <img src="docs/screenshots/1.2.15/tools.png" width="23%" alt="The Tools hub" />
  <img src="docs/screenshots/1.2.15/terminal.png" width="23%" alt="The SSH terminal" />
  <img src="docs/screenshots/1.2.15/documents.png" width="23%" alt="An inline document viewer" />
  <img src="docs/screenshots/1.2.15/profile-editor.png" width="23%" alt="The profile editor" />
  <img src="docs/screenshots/1.2.15/first-run.png" width="23%" alt="The first-run opening screen" />
  <img src="docs/screenshots/1.2.15/first-run-code.png" width="23%" alt="The first-run screen scanning a setup code" />
  <img src="docs/screenshots/1.2.15/home-light.png" width="23%" alt="Console Home in the light theme" />
  <img src="docs/screenshots/1.2.15/chat-light.png" width="23%" alt="A chat in the light theme" />
</p>

</details>

## Private by design

- Self-hosted: no account, no telemetry, no advertising
- Credentials stay on the phone, in the Android Keystore
- Plain HTTP only on private networks; HTTPS everywhere else

## Support the project

Console is free and built in my spare time. If it is useful to you, a coffee helps keep it going.

<p align="center">
  <a href="https://ko-fi.com/xpeta"><img height="40" alt="Support me on Ko-fi" src="https://storage.ko-fi.com/cdn/kofi3.png?v=6"></a>
</p>

<p align="center">
  <a href="docs/README.md">Docs</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="SECURITY.md">Security</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="https://ko-fi.com/xpeta">Support</a> · <a href="LICENSE">GPL-3.0</a>
  <br>
  <sub>Independent project by XPeta Lab, not affiliated with Nous Research.<br>Google Play and the Google Play logo are trademarks of Google LLC.</sub>
</p>
