# Política de Seguridad — Console

## Principios

1. **Privacidad por defecto**: sin backend, tracking ni analytics de XPeta Lab;
   servicios externos, integraciones de IA y métricas de SDK divulgados en
   Privacidad/Data Safety
2. **Seguridad por defecto**: HTTPS + Tailscale, nunca HTTP público
3. **Mínimos privilegios**: solo los permisos Android estrictamente necesarios
4. **Sin secretos en código**: API keys, tokens y contraseñas nunca en el repo

---

## Red y conectividad

### Reglas de conexión

- **Tailscale preferido**: conectar vía red Tailscale privada siempre que sea posible
- **LAN directa**: aceptable en red de confianza local
- **HTTPS con cert propio**: aceptable con trust anchor configurado en la app
- **HTTP sobre internet público**: **PROHIBIDO**. Solo permitido en LAN/Tailscale

### usesCleartextTraffic

El manifest principal mantiene `usesCleartextTraffic="false"`. Android no
permite expresar excepciones CIDR en `network_security_config`, por lo que el
release habilita el transporte cleartext a nivel de plataforma para poder usar
IPs arbitrarias de LAN/Tailscale, pero **todos los clientes de red de la app**
aplican antes `TransportPrivacy.requireAllowed`:

- HTTPS/WSS: permitido.
- HTTP/WS: permitido solo para loopback, RFC1918, Tailscale/CGNAT, MagicDNS y
  nombres locales.
- HTTP/WS público: bloqueado en runtime; no basta con aceptar un aviso.

La frontera se aplica también a los caminos auxiliares que podrían saltarse el
cliente principal: diagnóstico Gateway/Dashboard, historial cron, panel y
gestor de estado, el sondeo único de retirada del Mobile Bridge,
vigilancia/aprobaciones en segundo plano y proveedores configurables de STT/TTS/OlliteRT/OpenAI-compatible.
Una entrada persistida antigua o corrupta se descarta antes de leer credenciales.
LAN, Tailscale, loopback y HTTPS/WSS permanecen compatibles.

El TTS REST personalizado aplica la misma frontera a su URL completa: HTTPS en
internet o HTTP únicamente en LAN/Tailscale/loopback. La cabecera de
autenticación se construye en memoria y nunca se incluye en mensajes de error.

Esta doble capa conserva el caso self-hosted privado sin permitir que una
conexión pública en claro transmita claves, prompts o archivos.

### No exponer el Gateway públicamente

- El Gateway de Hermes NO debe tener puerto público en internet sin autenticación
- Si se usa VPS, poner Hermes detrás de un reverse proxy con TLS y autenticación
- La app no facilita ni guía hacia exposición pública

---

## Almacenamiento de secretos

### API Key

**Estado actual**: almacenada mediante `flutter_secure_storage` y Android
Keystore; la caché en memoria no se persiste.

**Requerimiento permanente**:
- La API key no debe aparecer en logs, crashes, o backups
- No usar `android:allowBackup="true"` (ya está en false — mantener así)

### Qué va en qué almacenamiento

| Dato                    | Almacenamiento     | Razón                          |
|-------------------------|--------------------|--------------------------------|
| API Key                 | flutter_secure_storage | Secreto — Keystore            |
| Acceso al Dashboard     | flutter_secure_storage | Secreto por instancia — Keystore |
| Claves/token de STT/TTS remoto | flutter_secure_storage | Secreto — Keystore      |
| URL del Gateway         | SharedPreferences  | No es secreto                  |
| URL/plantilla TTS REST  | SharedPreferences  | Configuración no secreta       |
| Label de conexión       | SharedPreferences  | No es secreto                  |
| Historial de chat       | SQLite local       | No sale del dispositivo        |
| Preferencias de tema    | SharedPreferences  | No es secreto                  |

### MCP, OAuth y webhooks administrados desde Android

- Los valores de entorno y tokens Bearer introducidos al dar de alta un MCP
  solo viven en los controladores del formulario y en el body del único
  `POST /api/mcp/servers`. La app no los guarda en preferencias, base local ni
  logs; Hermes los persiste en el servidor mediante su contrato oficial.
- Android no edita MCP con `PUT /api/mcp/servers`: ese endpoint reemplaza el
  mapa completo y una lectura previa contiene secretos redactados, por lo que
  podría borrar credenciales que el móvil no conoce.
- El identificador de un flujo OAuth permanece únicamente en la superficie
  visible. El navegador se abre por acción del usuario; el polling usa backoff
  acotado, se pausa al perder foreground y se cancela al cerrar la superficie.
- El secreto HMAC de un webhook se muestra solo en el recibo de creación. Se
  puede copiar explícitamente al portapapeles, pero no se conserva al cerrar el
  recibo y nunca se rehidrata desde `GET /api/webhooks`.
- Todas las mutaciones MCP/webhook respetan modo solo lectura y pasan por App
  Lock antes de llegar al Dashboard. Los errores mostrados son categorías
  locales; no se imprime el detalle remoto, payload, URL de OAuth ni secreto.
- A2A es solo un indicador leído de `/api/messaging/platforms`. La app no
  implementa el transporte A2A, no enumera peers y no almacena su configuración.

### Actualización automática de componentes

- La actualización automática es solo la de Hermes, con una única
  autorización opt-in. Se conserva una autorización anterior, pero nunca se
  activa si el usuario no la había habilitado.
- Con App Lock activo o una conexión en modo solo lectura no se inicia una
  mutación automática. La actualización manual sigue requiriendo la conexión y
  credenciales ya autorizadas por el usuario.
- El Mobile Bridge se retiró en 1.2.15. La app no lo instala, no lo actualiza
  ni le envía ninguna petición. En el primer arranque tras actualizar sondea
  una vez el Dashboard de cada instancia (`/api/status` y el inicio de sesión
  que la app ya hace, con las credenciales guardadas), borra del Keystore los
  secretos `bridge_url_<id>` / `bridge_token_<id>` y la preferencia
  `bridge_auto_update`, y avisa una sola vez si a una instancia le falta el
  acceso al Dashboard. El servicio que quede en el servidor lo para el
  propietario; la app solo enseña cómo.

---

## Permisos Android

### Permitidos y justificados

| Permiso              | Justificación                                  |
|----------------------|-----------------------------------------------|
| INTERNET             | Conexión al Gateway (imprescindible)           |
| ACCESS_NETWORK_STATE | Reintento inmediato al recuperar conectividad  |
| POST_NOTIFICATIONS   | Notificaciones locales de respuestas, aprobaciones y tareas (sin push de terceros) |
| POST_PROMOTED_NOTIFICATIONS | Live Updates de Android 16 para un turno en marcha |
| RECORD_AUDIO         | Dictado y conversación iniciados por el usuario |
| MODIFY_AUDIO_SETTINGS | Audio mode of the opt-in GPT-Live WebRTC session (flutter_webrtc); normal permission |
| CHANGE_NETWORK_STATE | Network handling of the same WebRTC session; normal permission |
| BLUETOOTH (`maxSdkVersion` 30) | Lets GPT-Live call audio follow a Bluetooth headset on Android 11 and older; added by the call-audio library under flutter_webrtc, normal install-time permission, no scanning or pairing; `android.hardware.bluetooth` stays optional |
| CAMERA | Scanning a connection QR code or taking an attachment photo, only after a user action |
| VIBRATE | Notification feedback |
| USE_BIOMETRIC | Optional App Lock; verification is delegated to Android |
| WRITE_EXTERNAL_STORAGE (`maxSdkVersion` 28) | Saving a generated image on Android 9 and older, only when the user taps Save |
| WAKE_LOCK, USE_FINGERPRINT | Added by flutter_foreground_task and local_auth; not held without work, no biometric data |
| FOREGROUND_SERVICE_MICROPHONE | Continuidad de Voz con opt-in y notificación |
| FOREGROUND_SERVICE_MEDIA_PLAYBACK | TTS y respuestas de Voz solicitados |
| FOREGROUND_SERVICE_DATA_SYNC | SSH/SFTP y fallback de escucha opt-in en API ≤34 |
| FOREGROUND_SERVICE_REMOTE_MESSAGING | Escucha persistente opt-in en API ≥35 |
| RECEIVE_BOOT_COMPLETED | Restaurar solo esa escucha si seguía activa; nunca audio ni SSH/SFTP |

### NO añadir sin revisión explícita

- `READ_EXTERNAL_STORAGE` — no se declara ni se usa para adjuntos: SAF/Photo
  Picker entregan acceso puntual. Se elimina si una dependencia legacy intenta
  declararlo. En Android <=9 la plataforma lo concede de forma implícita junto
  al `WRITE_EXTERNAL_STORAGE maxSdkVersion=28` usado solo para exportar una
  imagen; `apkanalyzer` refleja esa compatibilidad efectiva, ausente en 10+.
- `READ_PHONE_STATE` — no se usa y se elimina explícitamente si una dependencia
  legacy intenta implicarlo.
- `WRITE_EXTERNAL_STORAGE` — únicamente con `maxSdkVersion=28` para guardar
  una imagen por acción expresa en Android 9 o anterior; nunca para adjuntos.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `com.termux.permission.RUN_COMMAND`,
  `QUERY_ALL_PACKAGES` y cualquier `<queries><package>` — retirados con la
  instancia local en 1.2.15; `tool/release/full_release_policy.json` los
  prohíbe en todos los flavors
- `ACCESS_FINE_LOCATION` — no tiene sentido en esta app
- Ningún permiso de datos de contactos, SMS, o sensores

### Conversación por voz y segundo plano

- La lectura manual/automática adquiere `mediaPlayback` en el servicio Flutter
  compartido antes del primer audio. Su notificación solo dice
  “Leyendo respuesta”/“Lectura en pausa”: nunca incluye conversación, URL,
  herramienta, error ni texto sintetizado.
- Pausar, reanudar y terminar ReadAloud no llaman a STT ni abren el micrófono.
  La conversación de voz conserva prioridad y sus controles propios. Al quedar
  idle se degrada al tipo de red que conserve demanda (`remoteMessaging` para
  escucha opt-in en API ≥35; `dataSync` para esa escucha en API ≤34 o para
  SSH/SFTP); tras process death no se promete reanudación del audio.
- El modo conversación es opcional e independiente del STT/TTS del chat.
- La elección `En este móvil`/`Servidor Hermes` se guarda por identidad del
  Dashboard y se aplica al iniciar Voz manualmente. En la investigación interna
  QA se reutiliza la misma elección sin ampliar el consentimiento. El origen de
  apertura nunca cambia el motor. La
  configuración local permanece en el dispositivo y la configuración de voz
  del servidor sigue siendo canónica en Hermes Agent. La selección usa una
  clave versionada distinta del consentimiento: una aceptación guardada por
  una versión anterior no selecciona el servidor y, sin elección nueva
  explícita, el modo efectivo es siempre `En este móvil`.
- Una conversación que usa voz de servidor conserva un único cliente Dashboard
  autenticado para STT, TTS y tickets del stream. Sus cookies solo viven en
  memoria, rotan con las respuestas oficiales y el cliente se cierra al
  terminar, reemplazar o cerrar la sesión. Así se evitan relogins por frase y
  el rate-limit sin persistir ni registrar credenciales o cookies.
- Antes del primer uso se muestra un aviso destacado. Cancelar, pulsar atrás o
  cerrar no guarda consentimiento ni activa el micrófono.
- Por defecto una conversación iniciada manualmente pausa micrófono y TTS al
  dejar el primer plano. Su continuidad usa el servicio Flutter compartido con tipos
  `microphone|mediaPlayback`, iniciado desde una Activity visible después de
  `RECORD_AUDIO`, con notificación persistente y controles para
  Pausar/Continuar/Abrir/Terminar. Nunca arranca desde boot ni desde un receiver
  y no se restaura tras morir el proceso.
- Sin el opt-in de continuidad, la captura full-duplex de una conversación
  manual se desarma al abandonar el foreground. Con «Seguir con la pantalla
  bloqueada» y «Interrumpir hablando» activos puede conservarse bajo el mismo
  FGS para aceptar un turno o una orden exacta como «cállate». App Lock,
  Pausar/Terminar y una ruta de audio no segura siguen siendo suspensiones duras;
  ningún evento tardío puede reabrir el recorder tras esas fronteras.
- Cuando está elegido `En este móvil` y el STT es Sherpa, el barge-in entrega el
  WAV ya capturado al mismo worker local; no abre otro recorder, no persiste PCM
  y no llama a `/api/audio/transcribe`. Con `Servidor Hermes`, ese WAV solo sale
  del dispositivo si coinciden selección explícita y consentimiento aceptado.
- Durante TTS solo se mantiene barge-in si el `routedDevice` del `AudioTrack`
  que reproduce ese PCM confirma una salida privada (auricular, cable,
  Bluetooth o hearing aid). No basta con que haya un dispositivo conectado;
  ruta desconocida, altavoz o cambio a una salida no privada fallan cerrado
  antes del primer write o durante la reproducción. La captura durante
  generación sigue activa porque todavía no existe eco del TTS. Esta
  comprobación no enumera Bluetooth ni añade permisos.
- `AcousticEchoCanceler` se solicita best-effort en la sesión real del recorder,
  pero `hasControl && enabled` solo describe el estado administrativo del
  efecto: Android no expone su atenuación ni confirma que el HAL use el
  `AudioTrack` de Hermes como referencia far-end. Por tanto AEC se conserva como
  diagnóstico y nunca autoriza por sí solo barge-in con el altavoz.
- La captura solicita `NoiseSuppressor` best-effort en esa misma sesión, en
  paridad con `noiseSuppression:true` de Hermes Desktop. NS reduce ruido pero no
  demuestra cancelación de eco: si falta o pierde control, la captura puede
  continuar durante generación, pero playback sigue exigiendo una salida
  privada confirmada.
- Esa garantía de ruta se limita al `AudioTrack` PCM controlado por la app. En
  los fallbacks `audioplayers`/`flutter_tts`, donde la ruta real no se puede
  demostrar del mismo modo, el barge-in se desactiva durante playback.
- Desactivar «Modo conversación» termina una sesión activa, pero no cambia el
  dictado del compositor, la lectura de burbujas ni la lectura automática.
### Share Sheet Android

- La Activity acepta únicamente `ACTION_SEND` de texto/imagen y
  `ACTION_SEND_MULTIPLE` de imágenes. No añade permisos de almacenamiento.
- Los `content://` se copian al caché privado de la app mientras la autorización
  temporal del proveedor sigue vigente. Los nombres se sanean, el texto se
  limita a 65 536 caracteres y se admiten como máximo 10 URI, 8 MB por fichero
  y 24 MB por lote.
- La cola pendiente se guarda cifrada con `flutter_secure_storage`; no se
  escriben texto, nombres ni rutas en logs.
- La recepción nunca envía contenido al agente. Primero se guarda un borrador
  local revisable y solo después se confirma la entrada de la bandeja.
- Las URI revocadas, vacías o que superan los límites se descartan. La app
  informa del rechazo sin conservar el contenido externo.

---

## Tokens y autenticación

### Transmisión del token

**Problema actual**: el token se pasa como query parameter en la URL del WebSocket: `?token=...`  
Esto puede ser logueado por proxies, firewalls y herramientas de debug.

**Requerimiento** (PR 2):
- Mover el token al header `Authorization: Bearer <token>` cuando el protocolo lo permita
- Si WebSocket no soporta headers personalizados en Flutter, documentar el riesgo y aplicar mitigaciones (TLS obligatorio)

### En logs

- **NUNCA** loguear la API key completa
- Si se loguea para debug, redactar: `API key: ***...${key.substring(key.length - 4)}`
- Eliminar todos los `print()` y `debugPrint()` con datos sensibles antes del release

### Chat JSON-RPC y steering

- El chat remoto prefiere `/api/ws`, el mismo WebSocket JSON-RPC de Hermes
  Desktop. No instala ni parchea código en la instancia.
- En Dashboards con login, la app obtiene mediante la sesión autenticada un
  ticket WebSocket de un solo uso y 30 s de TTL. En instalaciones heredadas usa
  el token de sesión que ya exige el Dashboard.
- Tickets, tokens, URL completa y texto nunca se escriben en logs ni se
  persisten fuera del Keystore/caché en memoria existente.
- La app nunca crea ni rota credenciales del servidor. El acceso al Dashboard
  lo escribe el usuario, o llega en un enlace de emparejado que lo traiga
  (`dash_user`, `dash_pass`); en ambos casos se guarda en Keystore, no se
  registra ni se muestra, y se descarta sin enviarse si el formulario se
  apunta a otro servidor.
- `session.redirect` y `session.steer` permanecen como primitivas del cliente de
  Gateway para compatibilidad y superficies explícitamente autorizadas, cercadas
  por propiedad exclusiva de la sesión. El Chat y la Voz ordinarios de `1.2.10`
  no las invocan: todo texto recibido durante un turno activo queda como
  siguiente turno FIFO.
- Los adjuntos también permanecen locales hasta ese siguiente turno normal.
- Si el Dashboard no expone `/api/ws`, el fallback `/v1/runs` no intenta
  steering por un endpoint añadido ni interrumpe el run silenciosamente.
- Bot Chat tampoco ofrece write/redirect/steer en `1.2.10` (issue #11).

### Borrado de tareas programadas

- El borrado desde un informe usa el Dashboard
  (`DELETE /api/cron/jobs/{id}?profile=`), la misma ruta que Desktop, con la
  sesión ya autorizada de esa instancia. El ID se valida contra una allowlist
  estricta antes de construir ningún cliente. No se cambia ni se expone la
  contraseña del Dashboard.
- La conversación cron se elimina únicamente después de confirmar que la
  programación se detuvo. Las continuaciones compactadas se borran de hojas a
  raíz para que ninguna sesión hija reaparezca como conversación principal.

## Terceros y dependencias

### Visibilidad de paquetes Android

- No se solicita `QUERY_ALL_PACKAGES`.
- El manifest limita la visibilidad de voz a servicios que declaran las
  acciones estándar `android.speech.RecognitionService` (STT) y
  `android.intent.action.TTS_SERVICE` (síntesis). Esto permite usar motores
  locales como Graphene Speech Services sin enumerar el resto de aplicaciones
  instaladas ni añadir permisos nuevos.

### Dependencias actuales con implicaciones de privacidad

| Paquete              | Implicación                                             | Acción |
|----------------------|---------------------------------------------------------|--------|
| qr_code_scanner_plus / ZXing | QR íntegramente on-device; sin servicios de Google ni telemetría | BSD-2-Clause + Apache-2.0 verificadas |
| sherpa_onnx / whisper_ggml_plus | STT/TTS local mediante modelos descargables; sin enviar conversación | Verificar hashes/origen de modelos |
| flutter_foreground_task | Mantiene mensajería remota, Voz, lectura y el fallback dataSync de API ≤34 mediante una notificación Android local | Declarar sus cuatro tipos FGS en Play; SSH/SFTP API ≥35 usa el servicio nativo separado |
| package_info_plus    | Lee metadatos del paquete (versión, etc.) — sin red    | OK |

### No añadir sin auditoría previa

- No añadir SDKs de analytics (Firebase Analytics, Mixpanel, etc.)
- No añadir SDKs de crash reporting que envíen a terceros (Crashlytics, Sentry cloud)
- No añadir SDKs de publicidad

---

## Código y repositorio

- **No secretos en el repo**: API keys, tokens, keystores, contraseñas
- `.gitignore` debe incluir: `key.properties`, `*.jks`, `*.keystore`, `.env`, `google-services.json`
- Los keystores de release se gestionan fuera del repo
- No añadir archivos de configuración con endpoints de producción hardcodeados

## Privacidad en pantalla

- El usuario puede activar `FLAG_SECURE` para bloquear capturas, grabación de
  pantalla y la miniatura de Android Recientes. La preferencia se aplica también
  en el siguiente arranque.
- El usuario puede ocultar el contenido sensible de las notificaciones. En ese
  modo se muestran título/cuerpo genéricos y se retiran las acciones rápidas de
  aprobación; abrir la app sigue llevando al destino correcto.
- Estas preferencias no son secretos y se guardan en SharedPreferences.

---

## Release y distribución

- Las entregas de Google Play usan la upload key de XPeta Lab y Play App
  Signing. Keystore, credenciales y copias de seguridad permanecen fuera del
  repo.
- La variante `full` de descarga directa usa firma de release; nunca se
  distribuyen APK debug ni la variante `qa`.
- El contrato ejecutable `tool/release/release_contract.json` separa los canales:
  el AAB `playRelease` y toda su evidencia son **Play-private**; GitHub/Obtainium
  aceptan únicamente los tres APK `fullRelease` firmados y los metadatos de la
  allowlist pública cerrada. Logs, fixtures, capturas, mappings, credenciales,
  keystores y diagnósticos internos quedan fuera de ambos sets publicables.
- Package ID, versión, SHA-256 y certificado de firma se miden de nuevo sobre
  cada artefacto. Los sidecars no son autoridad y un hash no sustituye la
  identidad de firma.
- Dos clones limpios, con caches separados y el `pubspec.lock` autoritativo
  fijado por SHA-256, generan dos observaciones independientes. Antes de promover
  la salida, el propio paso de build emite un manifiesto canónico que fija
  fuente, inputs, comando, rutas/hashes pre-build del toolchain (que deben
  permanecer iguales tras ambos replicas) y nombres/tamaños/hashes de los
  artefactos; binding y staging fallan si reciben otros bytes. Es una
  vinculación causal local, no provenance criptográfica frente al reemplazo
  conjunto del builder, herramientas, artefactos y manifiesto. Los APK directos
  a byte entre esas dos ejecuciones, pero esto no se declara reproducibilidad
  general mientras Gradle, Maven y Android SDK no estén íntegramente fijados por
  contenido.
- La provenance pública eventual es DSSE/in-toto/SLSA keyless. Primero se valida
  firma e identidad OIDC con `gh attestation verify` contra repositorio,
  workflow, tag y commit exactos; después se aplica la policy estructural al
  mismo bundle. El validador estructural no es un verificador criptográfico y un
  JSON sin firma no es provenance.
- La identidad de provenance usa certificados efímeros de GitHub Actions; no
  introduce claves privadas ni secretos persistentes de attestación. Solo se
  obtiene durante la publicación expresamente autorizada.
- El repositorio es público: los artifacts de GitHub Actions no son un canal
  privado. El workflow es únicamente de verificación y nunca construye, recibe
  ni sube APK/AAB firmados. Build, comparación y staging permanecen juntos en el
  filesystem privado/local controlado por el propietario.
- Antes de cada entrega Play deben reconciliarse política de privacidad, Data
  Safety, destinos de IA/voz y declaraciones de servicios en primer plano.
- Ningún AAB, APK, push, attestación externa o publicación se realiza sin
  autorización explícita del propietario. Los helpers locales no crean una
  GitHub Release ni realizan un upload a Play Console.

El contrato operativo y la allowlist exacta están documentados en
[`RELEASE_DISTRIBUTION.md`](RELEASE_DISTRIBUTION.md).

---

## Respuesta ante incidentes

Si se descubre un secreto filtrado en el repo:
1. Rotar el secreto inmediatamente (generar nueva API key en Hermes)
2. Eliminar el secreto del historial git (`git filter-branch` o BFG)
3. Registrar en privado lo que pasó y cómo se corrigió, y avisar a quien corresponda ([SECURITY.md](../SECURITY.md))
