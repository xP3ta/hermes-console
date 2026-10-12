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

Console es una app independiente de Android para [Hermes Agent](https://github.com/NousResearch/hermes-agent), el agente que ejecutas en tu propio ordenador o servidor. Habla directamente con el Gateway y el Dashboard del propio Hermes, sin cuenta de Console ni un servidor nuestro por medio.

## Conecta

Ejecútalo donde vive Hermes y escanea el código que muestra. Requiere Console 1.2.15 o posterior.

```sh
# Linux, macOS
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh
```

```powershell
# Windows, WSL2 (Windows PowerShell 5.1+, como administrador)
irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1 | iex
```

<details>
<summary>¿Vienes de una instalación anterior?</summary>

<br>

Console 1.2.15 ya no usa el Mobile Bridge. Cuando todos tus móviles tengan la 1.2.15 o posterior, una línea quita el bridge del ordenador y nada más:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh -s -- --retire-bridge
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1))) -RetireBridge
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
