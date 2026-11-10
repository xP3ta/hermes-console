# Google Play — Data Safety form guide

> El propietario decide qué se declara a Google; esta guía describe el código
> de `1.4.0 (9812)`.

Cómo rellenar el formulario "Seguridad de los datos" en Play Console, coherente
con `PRIVACY_POLICY.md` y con el comportamiento real de la app. Responde campo a
campo.

**Revisado 2026-11-10 (1.4.0, build 9812)**: se añade el navegador integrado
como flujo hacia terceros; los avisos con la app cerrada siguen sin Firebase ni relay: la
escucha opt-in de 1.3.1 (continua), el servicio del turno (≤30 min, activo por
defecto) y la comprobación acotada (≤10 min) del final de ese turno. Repetir la comprobación de este
formulario sobre el AAB firmado final.

**Revisado 2026-09-03 (candidata 1.2.10, voz manual, lectura, notificaciones
locales y aclaración de IA de terceros)**: la
versión anterior de esta guía declaraba "no se comparten
datos con terceros" sin matices. Eso era incompleto: hay flujos funcionales y
opt-in hacia terceros que deben declararse. Omitirlos es una infracción de
política detectable por el revisor.

**Actualizado 2026-10-12 (1.2.15)**: la app ya no permite configurar servicios de
voz propios (ElevenLabs, endpoint compatible con OpenAI, STT/TTS personalizados)
desde el móvil; la voz va por el servidor Hermes o por el propio móvil. Se añade
el flujo opt-in de GPT-Live. Repetir la comprobación de este formulario sobre el
AAB firmado final.

## Flujos hacia terceros

| Dato | Tercero | Cuándo |
|---|---|---|
| Mensajes, transcripciones y adjuntos | Instancia Hermes elegida por el usuario y los proveedores de modelo/herramientas que configure su operador | Al enviar un turno. Es la función principal; XPeta Lab no recibe los datos ni decide los proveedores del servidor |
| Audio de una conversación GPT-Live | Proveedor de voz en tiempo real que usa el servidor Hermes del usuario (sesión WebRTC creada por ese servidor) | Solo si el servidor lo activa y el usuario activa y empieza GPT-Live (apagado por defecto). La clave del proveedor está en el servidor, no en el móvil |
| Audio de dictado o conversación | Reconocedor de voz del sistema o servidor STT configurado por el usuario | Solo con esos motores. Sherpa/Whisper procesan en el dispositivo. La continuidad bloqueada está apagada por defecto y exige opt-in independiente |
| Texto de búsqueda de skills | El servidor Hermes del usuario, que lo consulta en las fuentes de skills que tenga configuradas (skills.sh, GitHub, otras); la app no contacta con ellas | Solo al buscar en el catálogo de skills |
| Contenido incrustado en el chat (YouTube, Vimeo, Spotify, X, Instagram, TikTok, Pinterest, mapas) | Ese servicio, desde un WebView aislado: ve la IP y el navegador del móvil. Apagado por defecto para cada tipo; consentimiento solo en el dispositivo | Solo si el usuario activa o permite ese tipo |
| Navegador integrado (Workspace y enlaces web del chat) | El sitio web que el usuario abre o escribe, o que el agente le muestra: carga la página directamente desde su servidor, que ve la IP y el navegador del móvil y puede guardar cookies en el WebView. Solo `http`/`https`, sin canal de la página hacia la app, sin historial propio ni envío a XPeta Lab. Si el agente lee una página que abrió, su texto va al servidor Hermes del usuario como resultado de la herramienta | Solo cuando el usuario abre una página (o acepta «Ver» una que propone el agente) |
| Host y credenciales SSH | El host SSH que el usuario escribe (conexión directa) | Solo si el usuario añade un host SSH y abre terminal o SFTP |

Además, las fotos, imágenes y documentos que el usuario adjunta se envían al
servidor Hermes que él mismo configura. No llegan al desarrollador, pero deben
declararse en el formulario porque salen del dispositivo para la funcionalidad
principal de la app.

(La descarga de mascotas desde `assets.petdex.dev` y de modelos de voz desde
huggingface.co/GitHub son GET puros: no envían datos del usuario.)

## Resumen para el formulario

- **¿La app recopila o comparte datos de usuario?** → La app **no envía datos al
  desarrollador** (no operamos servidores; el destino principal es el servidor
  self-hosted del usuario). PERO, en términos de Play, la respuesta segura es:
  **Sí**. La app transmite mensajes al Hermes y a la IA que configure el
  usuario, y puede compartir texto/audio con servicios de voz opt-in y
  búsquedas con skills.sh. El escáner ZXing es local y no comparte datos.

## Sección por sección

### Data collection and security
- **Does your app collect or share any of the required user data types?**
  - Respuesta: **Sí** (ver flujos opt-in). El desarrollador no recopila ni
    recibe nada; la compartición es opcional, con servicios que el usuario
    configura con sus propias credenciales.
- **Is all of the user data encrypted in transit?** → **No** en el selector
  binario de Play. HTTPS/TLS es obligatorio hacia terceros públicos y recomendado
  hacia Hermes, pero HTTP/WS se permite para el servidor propio del usuario
  únicamente en LAN/Tailscale/loopback. La app bloquea cleartext público. No
  marcar “Sí” mientras exista esa ruta privada sin TLS.
- **Account deletion** → No aplicable: Hermes Console no crea cuentas. Los datos
  locales se eliminan desde la app cuando existe el control correspondiente,
  borrando el almacenamiento Android o desinstalando. Las conversaciones se
  pueden borrar contra la instancia compatible; para el resto de datos del
  servidor y terceros aplican los controles del operador/proveedor.

### Data types — marcar
- **Location**: No.
- **Personal info** (name, email, etc.): No.
- **Financial info**: No.
- **Messages**: Sí — transmitidos a la instancia Hermes elegida y a los
  proveedores de modelo/herramientas configurados por su operador para prestar
  la función principal. Si el usuario elige TTS en la nube, el texto de la
  respuesta también llega a ese proveedor. Purpose: App functionality. No para
  ads/analytics.
- **Audio**: Micrófono para dictado y conversación iniciados por el usuario. Con
  motor "Sistema" o STT remoto, el audio puede procesarlo el proveedor del
  dispositivo o el servidor elegido; con motores on-device no sale del teléfono.
  La continuidad de una conversación fuera de la app está apagada por defecto,
  exige un opt-in separado y mantiene una notificación persistente.
- **Photos and videos**: Sí, fotos/imágenes elegidas o capturadas como adjunto;
  envío opcional iniciado por el usuario a su servidor. Purpose: App functionality.
- **Files and docs**: Sí, documentos elegidos como adjunto; envío opcional
  iniciado por el usuario a su servidor. Purpose: App functionality.
- **App interactions**: la búsqueda del catálogo de skills se envía al servidor
  Hermes del usuario, que la consulta en sus fuentes (sin identificadores de
  usuario).
- **App info and performance / Diagnostics**: No por el escáner QR. ZXing se
  ejecuta localmente y no envía métricas. Revalidar el AAB final por si otra
  dependencia futura introduce un SDK de diagnóstico.
- **Contacts, Calendar, Device IDs**: No.
- **Web browsing history**: No. El navegador integrado no guarda ni envía
  historial de navegación a nadie (la página sí la sirve el sitio que el
  usuario visita, ver la tabla de flujos). Confirmar con el propietario si se
  prefiere declararlo como compartición con terceros.

### Purposes (audio/mensajes/búsqueda)
- Purpose: **App functionality** exclusivamente.
- **Not** used for analytics, advertising, personalization, or tracking.

### Security practices
- Datos cifrados en tránsito: parcial (ver arriba; TLS hacia terceros).
- Datos cifrados en reposo: credenciales en Android Keystore / secure storage.
- Sin SDK publicitario, Firebase/FCM ni analítica operada por XPeta Lab. El escáner QR
  ZXing no incluye telemetría ni servicios de Google.
- `allowBackup=false`: nada viaja a la copia de seguridad de Google.
- La cola local de turnos y el estado de las notificaciones permanecen solo en
  el dispositivo. No añaden ningún destino de red ni cambian las respuestas del
  formulario de Play.

## Aviso destacado y consentimiento de voz

Antes del primer inicio del modo conversación, un diálogo dentro del flujo
normal explica qué datos se procesan, que el destino depende del motor y del
Hermes configurados, y ofrece dos acciones afirmativas: solo con la app abierta
o continuar con pantalla bloqueada. Cerrar, tocar atrás o cancelar no acepta ni
arranca el micrófono. La segunda opción mantiene una notificación visible. La
preferencia puede desactivarse después en Ajustes → Voz; el modo conversación
también tiene un toggle independiente que no desactiva STT/TTS del chat.

Esto cubre la aclaración de Google Play del 15-07-2026: las integraciones de IA
de terceros siguen sujetas a uso limitado, divulgación y consentimiento. Antes
de enviar, hacer coincidir literalmente este documento, la política pública y
las respuestas guardadas en Play Console.

## Notas
- No hay cuenta ni identificadores de usuario.
- No hay recolección para publicidad ni analítica (no existe telemetría).
- Destinos de red: el Dashboard del servidor Hermes y proveedores de IA que configura el usuario + los flujos opt-in
  de la tabla + descargas de Petdex/Hugging Face/GitHub sin contenido del usuario (la app ya no usa el Gateway, solo el Dashboard).
  Si se añade un motor/servicio nuevo con red propia, actualizar esta guía y el
  formulario ANTES del release.
- Avisos con la app cerrada: la escucha opt-in de 1.3.1 (continua, apagada por
  defecto), el servicio del turno (hasta 30 min mientras corre un turno que el
  usuario lanzó; activo por defecto, desactivable) y la comprobación acotada
  (≤10 min, WorkManager) que avisa de su final, estas dos sin opt-in y ninguna
  bajo App Lock; siempre por la propia conexión del usuario con su servidor. La app no usa Firebase, relay de
  avisos ni otro servicio de terceros para las notificaciones.
