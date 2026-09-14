<p align="center">
  <a href="https://hermes.xpetalab.dev">
    <img src="../assets/icon/play_store_512.png" width="132" alt="Logo de Hermes Console" />
  </a>
</p>

<h1 align="center">Hermes Console</h1>

<p align="center">
  Una consola Android privada para el Hermes Agent autoalojado que tú controlas.
</p>

<p align="center">
  <a href="https://hermes.xpetalab.dev">Web</a> ·
  <a href="https://play.google.com/store/apps/details?id=dev.xpetalab.hermesconsole">Google Play</a> ·
  <a href="#obtainium">Obtainium</a> ·
  <a href="../LICENSE">GPL-3.0-only</a> ·
  <a href="../README.md">English</a>
</p>

Hermes Console es un cliente Flutter independiente para
[Hermes Agent](https://github.com/NousResearch/hermes-agent). Lleva el chat,
los Bots, las aprobaciones, las herramientas operativas y Voz a Android sin
interponer una cuenta de XPeta Lab ni un servicio de analítica entre tu móvil y
tu servidor.

> Hermes Console es un cliente, no un proveedor de IA. Necesitas una instancia
> Hermes Agent compatible y el acceso a modelos que esa instancia requiera.

## Funciones principales

| Área | Experiencia en Android |
|---|---|
| Conversaciones | Streaming, Markdown y código, adjuntos, imágenes generadas, sesiones y modelos. |
| Bots | Perfiles, identidades Blobatar, menciones, salas, tareas y actividad separados del chat normal. |
| Operaciones | Runs y aprobaciones, Cron, Kanban, skills, memoria, modelos, artefactos y administración por capacidades. |
| Voz | Dictado y modo conversación dedicado, con ruta en el móvil o en tu servidor Hermes. |
| Android | App Lock, instancias de solo lectura, notificaciones, widgets, compartir, emparejado QR y diagnóstico. |
| Privacidad | Sin telemetría de XPeta Lab, sin publicidad y con credenciales protegidas por Android Keystore. |

La aplicación toma Hermes Desktop y Hermes Agent como contrato técnico. Solo
muestra una función cuando el servidor conectado publica la capacidad real que
necesita.

## Instalación

### Google Play

[Instala el paquete de producción desde Google Play](https://play.google.com/store/apps/details?id=dev.xpetalab.hermesconsole).
Su identificador es `dev.xpetalab.hermesconsole` y las versiones de Play usan
Play App Signing.

### Obtainium

Cuando exista la primera release firmada en GitHub:

1. Instala [Obtainium](https://github.com/ImranR98/Obtainium).
2. Pulsa **Añadir app**.
3. Pega `https://github.com/xP3ta/hermes-console`.
4. Comprueba que detecta **GitHub Releases** y revisa la firma del APK antes de
   instalar.

Obtainium y Google Play son canales alternativos del mismo paquete. No cambies
entre firmas sin revisar antes las notas de migración publicadas.

### APK directo

Instala únicamente APK de producción adjuntos a una
[release oficial](https://github.com/xP3ta/hermes-console/releases). Verifica
versión, SHA-256 y certificado. Los builds `qa`, `debug` y `profile` son solo
para pruebas internas.

## Conectar tu servidor

1. Instala y configura
   [Hermes Agent](https://github.com/NousResearch/hermes-agent) en un servidor
   que controles.
2. Hazlo accesible desde Android mediante HTTPS, LAN o una red privada como
   [Tailscale](https://tailscale.com).
3. Abre Hermes Console y elige **Conectar servidor**.
4. Escanea el QR/enlace de emparejado o introduce manualmente Gateway y el
   Dashboard opcional.
5. Ejecuta el diagnóstico de capacidades antes de guardar la instancia.

El token del Gateway no es una clave de proveedor de modelos. Los QR y enlaces
de emparejado pueden contener acceso privado: no los publiques ni los adjuntes
a una incidencia. Consulta la [guía completa](CONFIGURATION.md).

## Voz sin defaults personales ocultos

El dictado y el modo Voz son funciones distintas:

- **En este móvil** usa STT/TTS privado tras descargar explícitamente los
  modelos. Una vez preparado no requiere servicios de Google.
- **Servidor Hermes** se activa voluntariamente por identidad y perfil. El
  audio viaja a tu propio Dashboard y usa los proveedores configurados allí.

La app no fija globalmente ningún proveedor de pago, modelo personal, idioma o
dirección de servidor. Una ruta elegida falla de forma visible en lugar de
enviar audio silenciosamente por otra.

## Compilar desde fuente

Necesitas Flutter 3.47.x, el Dart incluido, Java 17 y Android SDK 36.

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --flavor full \
  --dart-define=HERMES_FLAVOR=full \
  --dart-define=HERMES_LOCAL_AGENT=true
```

El APK debug no es distribuible. Los builds release fallan a propósito si no
existe una configuración de firma externa al repositorio.

## Privacidad, seguridad y licencia

No hay publicidad, analítica ni proxy de conversaciones operado por XPeta Lab.
Las credenciales se guardan mediante Android Keystore y los destinos remotos
son los que configura el usuario. Para vulnerabilidades, usa
[SECURITY.md](../SECURITY.md) y nunca publiques credenciales o conversaciones.

El código original de Hermes Console usa
[GNU GPL versión 3.0 solamente](../LICENSE) (`GPL-3.0-only`). El código upstream
y los componentes de terceros conservan sus avisos en [NOTICE](../NOTICE) y
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

Hermes Console está mantenido por [XPeta Lab](https://hermes.xpetalab.dev) como
proyecto independiente. Es compatible con Hermes Agent, pero no está afiliado,
patrocinado ni respaldado por Nous Research.
