# Configure a Hermes server

Console connects directly to the server configured by the user. XPeta
Lab does not proxy conversations or operate a conversation backend.

## Before you start

- Install Hermes Agent and make its Gateway reachable from Android.
- Prefer HTTPS for remote access or a private network such as Tailscale/LAN.
- Do not expose the Gateway or the Dashboard directly to the public internet
  without TLS, authentication, and an appropriate network policy.
- Have the Gateway `API_SERVER_KEY` available. It is not a model-provider API
  key.

## The quick way: the setup helper

On the computer that runs Hermes, run one line (Linux, macOS and other Unix):

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh
```

or, in Windows PowerShell 5.1+ opened as administrator (also for WSL2, from
outside WSL):

```powershell
irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1 | iex
```

It installs Hermes if it is missing, starts the Gateway and the Dashboard as
background services, makes sure both have a key and a sign-in, checks them
through the address the phone will use, and shows a code to scan. Console 1.2.15
or newer is needed. The helper's other lines (show the code again, make a new
Dashboard sign-in, remove an old bridge) are in
[its README](https://github.com/xP3ta/hermes-setup).

## What the server needs

Console talks to two services of Hermes itself. Both are prepared on the
computer that runs Hermes; none of it can be done from the phone. If you prefer
not to use the helper, or it cannot run on your system, set them up by hand. In
the app, the help behind **I don't have a code** shows the same lines ready to copy.

1. **The Dashboard, with a username and password.** Add to the Hermes `.env`
   file (`~/.hermes/.env` on Linux and macOS):

   ```
   HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
   HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=your-new-password
   ```

   and start it open to your network:

   ```
   hermes dashboard --no-open --host 0.0.0.0 --port 9119
   ```

2. **The Gateway, with its key.** Make a long key (`openssl rand -hex 32`;
   Hermes refuses a short one), add to the same `.env` file:

   ```
   API_SERVER_ENABLED=true
   API_SERVER_HOST=0.0.0.0
   API_SERVER_KEY=paste-the-key-here
   ```

   and start it with `hermes gateway`.

3. **On the phone**, choose **Connect server**, enter the computer's address
   and the Gateway key, and sign in to the Dashboard.

**Check connection**, in the connection's screen, probes the Gateway and the
Dashboard and says which of the two does not answer. Hermes itself prints no
pairing code.

## Pairing links

A `hermes://pair` link, or the QR code that carries one, fills the same form:
the Gateway address and key and, when the link includes them (`dash_user`,
`dash_pass`), the Dashboard sign-in. The app shows which of the two a link
sets up before anything is saved.

A pairing link contains reusable credentials. Treat it as a secret: scan it or
paste it only into Console, and never put it in a model prompt or
transcript, publish it, attach it to an issue, or include it in a screenshot.

## The fields of a connection

- **Gateway URL**: the address reachable from the phone, preferably over HTTPS.
- **Gateway token**: the `API_SERVER_KEY` for this Hermes instance.
- **Dashboard/Admin URL**: optional (by default, port 9119 of the same host,
  or the Gateway's own origin when that is HTTPS); the Dashboard carries live
  chat with profiles and Bot Chats, and the administrative features of the
  server.
- **Dashboard authentication**: automatic, session token, or Basic Auth,
  according to the real server configuration.

Credentials are stored through Android Keystore. Do not reuse sample tokens or
paste OpenAI, OpenRouter, or other provider keys into the Gateway token field.

## Verify the connection

After saving the instance:

1. Open it and run the connection/capability check.
2. Confirm that Gateway responds and that the expected profile and model are
   shown.
3. Verify the Gateway and the Dashboard separately.
4. Enable read-only mode when the phone must not make remote changes.
5. Configure App Lock before storing additional credentials or using
   administrative actions.

## Common failures

- **Connection refused**: Gateway is stopped, listens only on loopback, or its
  port is blocked.
- **Timeout**: the phone has no route to the server; check Wi-Fi, VPN, or
  Tailscale.
- **Host not found**: check DNS or MagicDNS.
- **Invalid TLS**: use a trusted certificate or a private network; do not turn
  off device-wide security.
- **401/403**: the `API_SERVER_KEY` does not match, or Dashboard requires its
  own authentication.
- **Dashboard password unknown**: it cannot be read back. Set a new one with
  the two `HERMES_DASHBOARD_BASIC_AUTH_*` lines above and restart the
  Dashboard.

## Coming from a Mobile Bridge install

Up to 1.2.14 the app could talk to Hermes through a Mobile Bridge helper on
port 9131. It no longer does: on the first launch after updating, the app
checks each connection's Dashboard once, deletes the bridge secrets it kept in
Android Keystore, and tells you if a connection still needs its Dashboard
sign-in. The helper keeps running on the server until you stop it; the app
shows the lines that stop and remove only the bridge (the Linux user unit
`hermes-bridge.service`, the macOS LaunchAgent
`dev.xpetalab.hermes-console.bridge`, the Windows tasks
`HermesConsole-MobileBridge` and `HermesConsole-Restart-MobileBridge`).

Once every phone is on Console 1.2.15 or newer, the setup helper removes the
bridge, and nothing else, with one line. Running it twice, or on a computer that
never had a bridge, changes nothing:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh -s -- --retire-bridge
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1))) -RetireBridge
```

For data destinations and optional services, read the
[privacy policy](PRIVACY_POLICY.md).
