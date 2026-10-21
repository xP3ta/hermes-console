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

Console is an independent Android app for [Hermes Agent](https://github.com/NousResearch/hermes-agent), the agent you run on your own computer or server. It talks straight to the Dashboard that comes with Hermes, with no Console account and no server of ours in between.

## Connect

Console talks to the **Dashboard** that comes with Hermes. You do not need a pairing code, the Gateway or an API key: one command on the computer, then scan a code.

**1. Open Console.** The welcome screen has two options: **I already have Hermes** opens the camera, with the command below it to get the code, and **I don't have Hermes yet** opens the **Install Hermes** help. **Connect manually** (address, username, password) is there too. Console does not search your Wi-Fi.

**2. On the computer where Hermes lives**, paste one command in Terminal (Linux, macOS) or PowerShell (Windows), or in the SSH window if Hermes is on a server:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1)))
```

It installs the official Hermes only if it is missing (if Hermes is already there, it does not touch it, nor Telegram or the Gateway), leaves the Dashboard on behind a password at a private address (your home network or Tailscale) and starts it with the computer. When it finishes it shows the address, the username, the password and a QR code.

**3. Scan the code in Console** and you are connected. Without a camera, choose **Connect manually** and type the three details.

**Hermes on a server on the internet?** Install [Tailscale](https://tailscale.com) on the server and on the phone, then paste the same command. Never expose port 9119 to the public internet without TLS, authentication and a network policy.

**Forgot the password?** Run the command below; it makes a new one and ends the old sessions. Console shows it under **Get access back**.

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh -s -- --new-access
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1))) -NewAccess
```

**Check it in a browser first.** On the phone, open `http://<computer-address>:9119`. If the Dashboard sign-in page appears, the network is fine and Console can connect too.

**Updating from a version that only used the Gateway?** Console 1.3.0 talks only to the Dashboard, so Console tells you and takes you to the same guided page. Paste the command on the computer and scan the code: your existing connection is updated (no second one is created) and your chats and settings on the phone are kept. The Gateway is not touched: Open WebUI, cron jobs and Telegram that use it are not affected.

<details>
<summary>Advanced: keep the Dashboard always on</summary>

<br>

The setup command above already starts the Dashboard with the computer and restarts it by itself (`systemd --user` on Linux, `launchd` on macOS). If you started the Dashboard by hand with `hermes dashboard`, it only works while that command runs and does not come back after a restart.

</details>

<details>
<summary>Coming from an older install?</summary>

<br>

Console no longer uses the Mobile Bridge or the Gateway. If you set up with an older setup helper, your computer may still run things Console does not need. Nothing breaks if you leave them, but you can remove them.

**Mobile Bridge.** Once every phone is on Console 1.2.15 or newer, one line removes the bridge from the computer and nothing else:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh -s -- --retire-bridge
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1))) -RetireBridge
```

**Gateway on the network.** The older helper saved an `API_SERVER_KEY` in Hermes' `.env` file (`~/.hermes/.env`) and set the Gateway's listening address in the settings of the service it created, which opens port 8642 to your network. (The old manual guide asked for `API_SERVER_ENABLED`, `API_SERVER_HOST` and `API_SERVER_KEY` in `.env`.) If you do not use Hermes' API server for anything else, you can close it: delete the `API_SERVER_KEY` line (and the other two if you added them by hand) and restart the Gateway, for example with `hermes gateway restart`. Without a usable key Hermes does not start its API server. The Gateway itself can keep running for anything else you use it for. The setup helper has an option that undoes only this exposure (it keeps your `API_SERVER_KEY` unless you add `--also-remove-api-key`), so run it only when every phone uses Console 1.3:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh -s -- --retire-gateway-exposure
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1))) -RetireGatewayExposure
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
