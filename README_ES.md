<p align="center">
  <a href="https://hermes.xpetalab.dev"><img src="assets/branding/console_banner.png" width="100%" alt="Console, la app de Android para tu Hermes Agent autoalojado" /></a>
</p>

<p align="center">
  Tu Hermes Agent autoalojado, nativo en Android.
  <br><br>
  <a href="https://play.google.com/store/apps/details?id=dev.xpetalab.hermesconsole"><img align="middle" height="45" alt="Disponible en Google Play" src="docs/badges/google-play-es.png"></a>
  <a href="https://github.com/xP3ta/hermes-console/releases/latest"><img align="middle" height="52" alt="Descárgala en GitHub" src="docs/badges/get-it-on-github.png"></a>
  <a href="https://hermes.xpetalab.dev/obtainium/"><img align="middle" height="52" alt="Descárgala con Obtainium" src="docs/badges/obtainium.png"></a>
  <a href="https://hermes.xpetalab.dev"><img align="middle" height="52" alt="Visita la web" src="docs/badges/visit-website-es.png"></a>
  <br><br>
  <a href="README.md">English</a> · Español
</p>

<p align="center">
  <img src="docs/screenshots/1.2.15/home.png" width="23%" alt="Inicio de Console: un tablero con lo que pasa ahora, chats, bots, salas, tareas programadas y tareas" />
  <img src="docs/screenshots/1.2.15/chat-live.png" width="23%" alt="Un chat mientras Hermes trabaja, con su razonamiento, herramientas y tareas dentro de la conversación" />
  <img src="docs/screenshots/1.2.15/voice.png" width="23%" alt="Una conversación de voz dentro del chat" />
  <img src="docs/screenshots/1.2.15/bots.png" width="23%" alt="Modo Bot: los perfiles de un servidor Hermes, cada uno con su propia cara" />
</p>

## Qué es

Console es una app independiente de Android para [Hermes Agent](https://github.com/NousResearch/hermes-agent), el agente que ejecutas en tu propio ordenador o servidor. Habla directamente con el Dashboard que trae Hermes, sin cuenta de Console ni un servidor nuestro por medio.

## Conecta

Console habla con el **Dashboard** que trae Hermes. No necesitas código de emparejado, ni el Gateway, ni una clave de API: un comando en el ordenador y escanear un código.

**1. Abre Console.** La pantalla de bienvenida tiene dos opciones: **Ya tengo Hermes** abre la cámara, con el comando de abajo para obtener el código, y **Aún no tengo Hermes** abre la ayuda **Instala Hermes**. **Conectar a mano** (dirección, usuario, contraseña) también está ahí. Console no busca en tu wifi.

**2. En el ordenador donde vive Hermes**, pega un comando en Terminal (Linux, macOS) o PowerShell (Windows), o en la ventana SSH si Hermes está en un servidor:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1)))
```

Instala el Hermes oficial solo si falta (si Hermes ya está, no lo toca, ni Telegram ni el Gateway), deja el Dashboard encendido tras una contraseña en una dirección privada (tu red de casa o Tailscale) y lo arranca con el ordenador. Al terminar muestra la dirección, el usuario, la contraseña y un código QR.

**3. Escanea el código en Console** y ya estás conectado. Sin cámara, elige **Conectar a mano** y escribe los tres datos.

**¿Hermes en un servidor de internet?** Instala [Tailscale](https://tailscale.com) en el servidor y en el móvil y pega el mismo comando. No expongas nunca el puerto 9119 a internet sin TLS, autenticación y una política de red.

**¿Olvidaste la contraseña?** Ejecuta el comando de abajo: crea una nueva y cierra las sesiones de la anterior. Console lo muestra en **Recuperar el acceso**.

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh -s -- --new-access
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1))) -NewAccess
```

**Pruébalo antes en el navegador.** En el móvil, abre `http://<dirección-del-ordenador>:9119`. Si aparece la pantalla de acceso del Dashboard, la red está bien y Console también podrá conectar.

**¿Actualizas desde una versión que solo usaba el Gateway?** Console 1.3.0 habla solo con el Dashboard, así que Console te lo dice y te lleva a la misma página guiada. Pega el comando en el ordenador y escanea el código: tu conexión actual se actualiza (no se crea una segunda) y tus chats y ajustes del móvil se conservan. El Gateway no se toca: Open WebUI, las tareas programadas (cron) y Telegram que lo usan no se ven afectados.

<details>
<summary>Avanzado: dejar el Dashboard siempre encendido</summary>

<br>

El comando de instalación de arriba ya arranca el Dashboard con el ordenador y lo reinicia solo (`systemd --user` en Linux, `launchd` en macOS). Si lanzaste el Dashboard a mano con `hermes dashboard`, solo funciona mientras ese comando siga en marcha y no vuelve tras reiniciar.

</details>

<details>
<summary>¿Vienes de una instalación anterior?</summary>

<br>

Console ya no usa el Mobile Bridge ni el Gateway. Si instalaste con un script anterior, tu ordenador puede seguir ejecutando cosas que Console no necesita. Nada se rompe si las dejas, pero puedes quitarlas.

**Mobile Bridge.** Cuando todos tus móviles tengan Console 1.2.15 o posterior, una línea quita el bridge del ordenador y nada más:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh -s -- --retire-bridge
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1))) -RetireBridge
```

**Gateway abierto en la red.** El script anterior guardó una `API_SERVER_KEY` en el archivo `.env` de Hermes (`~/.hermes/.env`) y fijó la dirección de escucha del Gateway en los ajustes del servicio que creó, lo que abre el puerto 8642 a tu red. (La guía manual antigua pedía `API_SERVER_ENABLED`, `API_SERVER_HOST` y `API_SERVER_KEY` en `.env`.) Si no usas el servidor de API de Hermes para nada más, puedes cerrarlo: borra la línea `API_SERVER_KEY` (y las otras dos si las pusiste a mano) y reinicia el Gateway, por ejemplo con `hermes gateway restart`. Sin una clave válida Hermes no arranca su servidor de API. El Gateway en sí puede seguir encendido para lo demás que uses con él. El script de instalación tiene una opción que deshace solo esa exposición (conserva tu `API_SERVER_KEY` salvo que añadas `--also-remove-api-key`); ejecútala solo cuando todos tus móviles usen Console 1.3:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.sh | sh -s -- --retire-gateway-exposure
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1))) -RetireGatewayExposure
```

</details>

## Qué puedes hacer

- Un chat que muestra el trabajo: razonamiento, herramientas y tareas, con palabras normales
- Conversaciones de voz dentro del chat
- Bots y salas, una identidad por perfil de Hermes
- Tareas programadas (Cron) y tareas, en tablero o en lista
- Modelos, con eliminación real de proveedores
- Terminal SSH, SFTP y visores de archivos integrados

<details>
<summary>Más pantallas</summary>

<br>

<p align="center">
  <img src="docs/screenshots/1.2.15/room.png" width="23%" alt="Una sala de bots con varios perfiles respondiendo" />
  <img src="docs/screenshots/1.2.15/tasks-board.png" width="23%" alt="El tablero de Tareas" />
  <img src="docs/screenshots/1.2.15/tasks-list.png" width="23%" alt="La lista de Tareas" />
  <img src="docs/screenshots/1.2.15/cron.png" width="23%" alt="Tareas programadas de Cron" />
  <img src="docs/screenshots/1.2.15/models.png" width="23%" alt="La pantalla de Modelos" />
  <img src="docs/screenshots/1.2.15/tools.png" width="23%" alt="El centro de Herramientas" />
  <img src="docs/screenshots/1.2.15/terminal.png" width="23%" alt="El terminal SSH" />
  <img src="docs/screenshots/1.2.15/documents.png" width="23%" alt="Un visor de documentos integrado" />
  <img src="docs/screenshots/1.2.15/profile-editor.png" width="23%" alt="El editor de perfiles" />
  <img src="docs/screenshots/1.2.15/first-run.png" width="23%" alt="La pantalla de apertura del primer arranque" />
  <img src="docs/screenshots/1.2.15/first-run-code.png" width="23%" alt="La pantalla de primer arranque escaneando un código de instalación" />
  <img src="docs/screenshots/1.2.15/home-light.png" width="23%" alt="Inicio de Console con el tema claro" />
  <img src="docs/screenshots/1.2.15/chat-light.png" width="23%" alt="Un chat con el tema claro" />
</p>

</details>

## Privada por diseño

- Autoalojada: sin cuenta, sin telemetría, sin publicidad
- Las credenciales se quedan en el móvil, en el Keystore de Android
- HTTP sin cifrar solo en redes privadas; HTTPS en cualquier otro caso

## Apoya el proyecto

Console es gratuita y la hago en mi tiempo libre. Si te resulta útil, un café ayuda a que siga adelante.

<p align="center">
  <a href="https://ko-fi.com/xpeta"><img height="40" alt="Invítame a un café en Ko-fi" src="https://storage.ko-fi.com/cdn/kofi3.png?v=6"></a>
</p>

<p align="center">
  <a href="docs/README.md">Documentación</a> · <a href="CHANGELOG.md">Cambios</a> · <a href="SECURITY.md">Seguridad</a> · <a href="CONTRIBUTING.md">Contribuir</a> · <a href="https://ko-fi.com/xpeta">Apoyar</a> · <a href="LICENSE">GPL-3.0</a>
  <br>
  <sub>Proyecto independiente de XPeta Lab, sin relación con Nous Research.<br>Google Play y el logotipo de Google Play son marcas comerciales de Google LLC.</sub>
</p>
