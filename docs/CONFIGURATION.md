# Configure a Hermes server

Console connects directly to the server configured by the user. XPeta
Lab does not proxy conversations or operate a conversation backend.

## Before you start

- Install Hermes Agent on the computer or server you want to reach (see the
  [Hermes Agent](https://github.com/NousResearch/hermes-agent) page).
- Console connects to the Hermes **Dashboard**. It does not need the Gateway,
  an `API_SERVER_KEY` or a pairing code.
- Prefer a private network such as Tailscale (recommended) or your home LAN,
  or HTTPS for remote access. Console only allows plain HTTP toward private
  addresses.
- Do not expose port 9119 to the public internet without TLS, authentication
  and a network policy.

## The way to connect

1. **Run the setup command on the computer that runs Hermes.** Paste it in
   Terminal (Linux, macOS), in PowerShell (Windows) or in the SSH window if
   Hermes is on a server:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh
   ```

   ```powershell
   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1)))
   ```

   It installs the official Hermes only if it is missing (it does not touch
   Telegram or the Gateway if Hermes is already there), leaves the Dashboard on
   behind a password at a private address (home network or Tailscale), starts
   it with the computer and, when it finishes, shows the address, the username,
   the password and a QR code. By default Hermes listens only on the computer
   itself (`127.0.0.1`, port 9119) and refuses to listen on the network without
   a sign-in; the command takes care of both. The password is saved as a hash,
   not in plain text.

   Forgot the password? Run the command below; it makes a new one and ends the
   old sessions. Console shows it under **Get access back**.

   ```sh
   curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh -s -- --new-access
   ```

   ```powershell
   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1))) -NewAccess
   ```

2. **Join the phone and the computer on one private network.** The command
   already picks a private address. Tailscale is the recommended option: install
   it on both devices and sign in to the same account. Do not open port 9119 on
   your router.

   Hermes itself serves plain HTTP. Over a home network, the Dashboard username
   and password therefore travel unencrypted, and Hermes counts private
   addresses as public: it treats a hostile device on the LAN as the threat.
   Prefer Tailscale (which encrypts the traffic) or HTTPS. Console asks you to
   consent before it sends a sign-in unencrypted over a private network.

   On a server or VPS with a public IP address, install Tailscale on the
   server and on the phone first, and then run the same command. Do not publish
   port 9119 to the internet. Use the address the setup shows in Console, not
   the MagicDNS name, because with a specific bind Hermes only accepts requests
   made to exactly that address.

3. **Check it in a browser.** On the phone, open
   `http://<computer-address>:9119`. The Dashboard sign-in page should appear.

4. **In Console**, choose **I already have Hermes** and scan the code. Or
   choose **Connect manually**, type the computer's address in
   **Computer address** and sign in with the Dashboard username and password
   the setup showed.
   Console reads the Dashboard at port 9119 of that address; if you moved it to
   another port, or it lives at a different address, open **Advanced** and set
   **Dashboard port** or **Separate Dashboard address**.

**Test connection**, in the connection's screen, checks the Dashboard and says
what does not answer.

Tips and limits:

- With `--host 0.0.0.0` Hermes accepts requests made to any name or address of
  the computer. If you instead bind it to one address (`--host <address>`),
  Hermes only accepts requests made to exactly that address, so use that same
  address in Console.
- The setup command starts the Dashboard with the computer and restarts it by
  itself. A Dashboard started by hand only works while its command is running
  and does not come back after a restart.
- Windows and WSL2: this page does not cover how to make a Dashboard that runs
  inside WSL2 reachable from the phone.

## Pairing links (older helpers)

A `hermes://pair` link, or the QR code that carries one, was made by the older
setup helper. Console still accepts it: it fills the same form with the address
and, when the link includes them (`dash_user`, `dash_pass`), the Dashboard
sign-in. The app shows what a link sets up before anything is saved. Hermes
itself prints no pairing code, and the Dashboard-only flow above needs none.

A pairing link contains reusable credentials. Treat it as a secret: scan it or
paste it only into Console, and never put it in a model prompt or
transcript, publish it, attach it to an issue, or include it in a screenshot.

## The fields of a connection

- **Computer address**: the address reachable from the phone, preferably over
  HTTPS or a private network.
- **Dashboard port** and **Separate Dashboard address** (under **Advanced**,
  optional): by default, port 9119 of the same host, or the same port when the
  address is HTTPS. The Dashboard carries live chat with profiles and Bot Chats,
  and the administrative features of the server.
- **Sign-in method** (Dashboard authentication): shown as **Saved sign-in**,
  **Session token** or **Username and password**, according to the real server
  configuration. You choose between **Session token** and **Username and
  password**; **Saved sign-in** appears once a sign-in is stored.

Credentials are stored through Android Keystore. Do not paste OpenAI,
OpenRouter, or other provider keys into the sign-in fields.

## Verify the connection

After saving the instance:

1. Open it and run the connection/capability check.
2. Confirm that the Dashboard responds and that the expected profile and model
   are shown.
3. Enable read-only mode when the phone must not make remote changes.
4. Configure App Lock before storing additional credentials or using
   administrative actions.

## Common failures

- **Connection refused**: the Dashboard is stopped, listens only on loopback
  (it was started without `--host 0.0.0.0`), or its port is blocked.
- **Timeout**: the phone has no route to the server; check Wi-Fi, VPN, or
  Tailscale.
- **Host not found**: check DNS or MagicDNS.
- **Invalid TLS**: use a trusted certificate or a private network; do not turn
  off device-wide security.
- **401/403**: the Dashboard username or password is wrong, or the Dashboard
  needs another kind of sign-in.
- **Dashboard password unknown**: it cannot be read back. Set a new one with
  the two `HERMES_DASHBOARD_BASIC_AUTH_*` lines above and restart the
  Dashboard.

## Coming from an older install

Console no longer uses the Mobile Bridge or the Gateway. What an older setup may
have left on the computer is harmless to leave, but you can remove it.

### Mobile Bridge

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

### Gateway opened to the network

The older setup helper started Hermes' Gateway (API server) on your network. It
saved an `API_SERVER_KEY` in the `.env` file (`~/.hermes/.env` on Linux and
macOS) and set the listening address and port (`API_SERVER_HOST`,
`API_SERVER_PORT`) in the settings of the service it created, not in `.env`.
The old manual guide asked for these lines in `.env` instead:

```
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0
API_SERVER_KEY=...
```

Console does not need any of it. Hermes only starts that API server when
`API_SERVER_KEY` holds a usable key (at least 16 characters), and it listens on
`API_SERVER_HOST` (default `127.0.0.1`) and port 8642. If you do not use the API
server for anything else, delete the `API_SERVER_KEY` line (and
`API_SERVER_ENABLED` and `API_SERVER_HOST` if you added them by hand) and
restart the Gateway, for example with `hermes gateway restart`. Without a usable
key Hermes does not start the API server, so an address left in the service
settings exposes nothing. The Gateway itself (the part that runs your messaging
platforms) is a separate thing and can keep running. The setup helper has an
option that undoes only this exposure (it keeps your `API_SERVER_KEY` unless you
add `--also-remove-api-key`); run it only when every phone uses Console 1.3:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh -s -- --retire-gateway-exposure
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1))) -RetireGatewayExposure
```

For data destinations and optional services, read the
[privacy policy](PRIVACY_POLICY.md).
