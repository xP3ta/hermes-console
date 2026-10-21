# Google Play listing — Hermes Console

Listing text and assets for `1.3.0` (build number to be assigned; the
1.2.15 texts are kept in [`release/1.2.15/`](release/1.2.15/)). Default language: **English
(United States)**, followed by the Spanish (Spain) translation. The listing is
not authorised for submission until the signed AAB, the deployed privacy policy,
Data Safety, the foreground-service videos, the screenshots and the emulator QA
below are verified on the exact artifact. The graphic assets keep their own gate
at the end of this document.

> Changing the default language of the listing from Spanish to English is done
> in Play Console by the owner (Store presence → Main store listing → Manage
> translations); nothing in the repository can do it.

## Identity

- **Title** (maximum 30): `Hermes Console by XPeta Lab` (27)
- **App or game**: App
- **Suggested category**: Productivity
- **Price**: Free
- **Contains ads**: No
- **Contact e-mail**: hola@xpetalab.dev
- **Website**: https://hermes.xpetalab.dev
- **Privacy policy**: https://hermes.xpetalab.dev/en/privacy (English) and
  https://hermes.xpetalab.dev/privacy (Spanish)
- **Package**: `dev.xpetalab.hermesconsole`

The launcher name of the app is "Console"; the registered store title keeps
"Hermes Console" because that is the name the listing and package already have.

## English (United States) — default

### Short description (maximum 80)

Private Android client for your self-hosted Hermes Agent.

### Full description (maximum 4000)

Console is a private Android app for your own self-hosted Hermes Agent. Chat with
your agent, see what it is doing, talk to it, and run your bots, scheduled jobs
and tasks from your phone.

It talks straight to the Dashboard of the Hermes you run. There is no Console
account and no server of ours in between.

CONNECT IN A FEW STEPS
On the computer where Hermes lives, paste one command in Terminal or PowerShell
(or in the SSH window for a server). It installs the official Hermes only if it
is missing, leaves the Dashboard on behind a password on a private address (your
home network or Tailscale) and shows a QR code. Open Console, choose I already
have Hermes and scan it. Connect manually is there too. The step-by-step guide
is in the project README on GitHub (xP3ta/hermes-console).

WHAT YOU GET
• A chat that shows the work: reasoning, tools and tasks appear in the
  conversation in plain words, like Hermes Desktop, with streaming Markdown and
  copyable code blocks.
• Voice: talk inside the chat, dictate a message, hear replies read aloud. Speech
  can run on the phone or on your Hermes server.
• A Home board of widgets for what is happening now, chats, bots, rooms, scheduled
  jobs and tasks.
• Bots and rooms: every Hermes profile has its own identity, and several can talk
  in a room with @mentions.
• Cron jobs and a task board or list, with a mute switch for each one.
• Models, skills, tools, MCP servers and memory, edited from the phone.
• SSH terminal and SFTP, inline viewers for PDFs, images and Markdown, and the
  files Hermes generates.
• Approvals for the agent's actions, answerable from the notification.
• Live notification for a running turn, with Stop.
• Launcher widgets that resize.
• Attachments with visible progress.
• Several Hermes connections, a read-only mode and an optional App Lock with your
  device's biometrics.
• Light and dark themes, adjustable text size, English and Spanish.

PRIVATE BY DESIGN
• No ads, no analytics SDK, no Console account.
• Credentials are kept in the Android Keystore.
• Plain HTTP is accepted only for private networks; HTTPS everywhere else. Plain
  HTTP is not encrypted, so prefer Tailscale or HTTPS.

Console is a client, not an AI service, and it does not host your conversations.
You need a compatible Hermes Agent that you run. Your messages and attachments go
to that server, which may pass them to the model providers you configured there.
Some optional features (downloading pets or voice models, GPT-Live voice when your
server enables it) contact the services involved; Console explains those flows.

Console is an independent, unofficial app. It is not affiliated with, sponsored by
or maintained by Nous Research or the authors of Hermes Agent.

## Español (España)

### Descripción breve (máximo 80)

Cliente Android privado para tu Hermes Agent autoalojado.

### Descripción completa (máximo 4000)

Console es una app de Android privada para tu propio Hermes Agent autoalojado.
Conversa con tu agente, mira qué está haciendo, háblale y gestiona desde el móvil
tus bots, tareas programadas y tareas.

Habla directamente con el Dashboard del Hermes que ejecutas tú. No hay cuenta de
Console ni un servidor nuestro por medio.

CONECTA EN POCOS PASOS
En el ordenador donde vive Hermes, pega un comando en la Terminal o PowerShell
(o en la ventana SSH si es un servidor). Instala el Hermes oficial solo si
falta, deja el Dashboard encendido con contraseña en una dirección privada (tu
red de casa o Tailscale) y muestra un código QR. Abre Console, elige Ya tengo
Hermes y escanéalo. También puedes elegir Conectar a mano. La guía paso a paso
está en el README del proyecto en GitHub (xP3ta/hermes-console).

QUÉ OBTIENES
• Un chat que muestra el trabajo: el razonamiento, las herramientas y las tareas
  aparecen en la conversación con palabras normales, como en Hermes Desktop, con
  Markdown en streaming y bloques de código copiables.
• Voz: habla dentro del chat, dicta un mensaje, escucha las respuestas en voz
  alta. La voz puede funcionar en el móvil o en tu servidor Hermes.
• Un tablero de Inicio con widgets de lo que pasa ahora, chats, bots, salas,
  tareas programadas y tareas.
• Bots y salas: cada perfil de Hermes tiene su propia identidad, y varios pueden
  conversar en una sala con @menciones.
• Tareas programadas de Cron y un tablero o lista de tareas, con un interruptor
  para silenciar cada una.
• Modelos, skills, herramientas, servidores MCP y memoria, editados desde el móvil.
• Terminal SSH y SFTP, visores integrados de PDF, imágenes y Markdown, y los
  archivos que genera Hermes.
• Aprobaciones de las acciones del agente, que puedes responder desde la
  notificación.
• Notificación en vivo de un turno en marcha, con Parar.
• Widgets del escritorio que cambian de tamaño.
• Adjuntos con progreso visible.
• Varias conexiones a Hermes, modo de solo lectura y un App Lock opcional con la
  biometría del dispositivo.
• Temas claro y oscuro, tamaño de texto ajustable, inglés y español.

PRIVADA POR DISEÑO
• Sin anuncios, sin SDK de analítica, sin cuenta de Console.
• Las credenciales se guardan en el Keystore de Android.
• El HTTP sin cifrar solo se acepta en redes privadas; HTTPS en cualquier otro
  caso. El HTTP no va cifrado, así que mejor Tailscale o HTTPS.

Console es un cliente, no un servicio de IA, y no aloja tus conversaciones.
Necesitas un Hermes Agent compatible que ejecutes tú. Tus mensajes y adjuntos van
a ese servidor, que puede pasarlos a los proveedores de modelos que hayas
configurado allí. Algunas funciones opcionales (descargar mascotas o modelos de
voz, voz GPT-Live cuando tu servidor la activa) contactan con los servicios
implicados; Console explica esos flujos.

Console es una aplicación independiente y no oficial. No está afiliada,
patrocinada ni mantenida por Nous Research ni por los autores de Hermes Agent.

## What's new — `1.3.0`

The same texts are kept as files in [`release/1.3.0/`](release/1.3.0/). Every
statement below is taken from the commits between the previous release and this
one; nothing promises automatic setup, discovery or Cloud.

### English (United States), maximum 500 characters

```text
Console now talks only to the Hermes Dashboard: no Gateway, API key or pairing code. Choose "I already have Hermes" or "I don't have Hermes yet", run one command on your computer and scan the code. Only had the Gateway? Console guides you and updates your connection; your chats stay. Steadier after network cuts. New chats and named-profile images and files work again. Thanks to Rafael Telles, Luke Manning and oeyhaga for their fixes.
```

### Español (España), máximo 500 caracteres

```text
Console ahora habla solo con el Dashboard de Hermes: sin Gateway, clave de API ni código de emparejado. Elige «Ya tengo Hermes» o «Aún no tengo Hermes», ejecuta un comando en tu ordenador y escanea el código. ¿Solo tenías el Gateway? Console te guía y actualiza tu conexión; tus chats se conservan. Más estable tras cortes de red. Los chats nuevos y las imágenes y archivos de perfiles con nombre vuelven a funcionar. Gracias a Rafael Telles, Luke Manning y oeyhaga por sus arreglos.
```

## Graphic assets

- **App icon**: the one already published and approved on Google Play
  (`assets/icon/`).
- **Feature graphic** (1024 x 500): `docs/store/feature-graphic.png`.
- **Phone screenshots**: eight, in this order, from the 1.2.15 set in
  `docs/screenshots/1.2.15/`:

  | # | File | Shows |
  |---|---|---|
  | 1 | `home.png` | The Home board |
  | 2 | `chat-live.png` | A chat while Hermes works |
  | 3 | `voice.png` | A voice conversation in the chat |
  | 4 | `bots.png` | Bot Mode |
  | 5 | `tasks-board.png` | The Tasks board |
  | 6 | `models.png` | Models |
  | 7 | `terminal.png` | The SSH terminal |
  | 8 | `chat.png` | A finished answer with a table and code |

- Captions and any text overlay are English first; Spanish listings reuse the
  same images.
- The promotional video is optional. If used, host it on YouTube as public or
  unlisted, without ads or age restriction.

Do not reuse historical captures or media with data from a real instance. Every
image passes the privacy and full-resolution review in
[`screenshots/README.md`](screenshots/README.md), and the owner approves it for
this surface before upload.

## Gates before submission

- [ ] Signed `play` AAB selected, with merged manifest and effective permissions
  checked on that exact bundle ([`PLAY_PERMISSIONS.md`](PLAY_PERMISSIONS.md)).
- [ ] Privacy policy deployed in Spanish and English at the URLs above and matching
  [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md).
- [ ] Data Safety completed as in [`PLAY_DATA_SAFETY.md`](PLAY_DATA_SAFETY.md).
- [ ] Foreground-service declarations and videos as in
  [`PLAY_FGS_DECLARATION.md`](PLAY_FGS_DECLARATION.md).
- [ ] Screenshots and feature graphic reviewed and approved.
- [ ] Emulator and Desktop end-to-end QA recorded for the exact artifact.
- [ ] Listing text above matches what the app does on that artifact.
