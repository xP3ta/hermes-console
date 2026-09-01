# Google Play — Permissions justification

Justificación de cada permiso para la revisión de Google Play. Esta tabla apunta
al candidato fuente `1.2.9` y se reconcilió el 2026-09-01 con sus manifests
versionados. El AAB firmado definitivo todavía no se ha generado ni inspeccionado
con bundletool, por lo que no se registra aquí ningún hash o permiso efectivo
como si ya existiera. Antes de copiar el texto a Play Console hay que repetir la
comprobación sobre el AAB exacto seleccionado, confirmar SDK 24/36 y demostrar
que los permisos exclusivos de la variante completa no están presentes.

## Permisos del build de Play (flavor `play`)

| Permiso | Para qué | Justificación |
|---|---|---|
| `INTERNET` | Conectar al servidor Hermes del usuario | Funcionalidad central |
| `RECORD_AUDIO` | Dictado y modo conversación | Solo empieza tras una acción del usuario y su divulgación. Continuar una conversación fuera de la app requiere opt-in separado y notificación persistente; la app no guarda el audio |
| `CAMERA` | Escanear un QR de conexión o tomar una foto adjunta | Solo se abre tras una acción del usuario. ZXing procesa los frames del QR íntegramente en el dispositivo; una foto capturada se envía únicamente al servidor configurado cuando el usuario manda el mensaje. Sin captura en background |
| `POST_NOTIFICATIONS` | Respuestas, automatizaciones y controles de Voz/lectura | Avisos privados de respuestas, runs, Cron y transiciones Kanban con opt-in; controles persistentes del audio iniciado por el usuario; sin push de terceros |
| `VIBRATE` | Feedback de notificaciones | Complementa las notificaciones |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` | Mantener red visible en 2º plano | Tipo `dataSync`: mantiene SSH/SFTP explícito (servicio nativo separado en API ≥35) y, solo en Android ≤14, el fallback Flutter de escucha opt-in. SSH/SFTP termina con la operación; la escucha termina al apagarla |
| `FOREGROUND_SERVICE_REMOTE_MESSAGING` | Mantener la continuidad opt-in de chat en Android ≥15 | Tipo `remoteMessaging`: conserva el transporte de mensajes entre el agente/Desktop autoalojado y el móvil; runs, Cron y Kanban son avisos secundarios. Muestra notificación persistente y evita usar la cuota finita `dataSync` en Android ≥15 |
| `FOREGROUND_SERVICE_MICROPHONE` | Continuar una conversación de voz fuera de la app | Tipo `microphone`: solo se arranca desde una Activity visible, después de `RECORD_AUDIO` y del opt-in correspondiente. Muestra controles persistentes y nunca arranca desde boot/receiver. Tras process death no restaura la conversación |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Continuar lectura TTS y respuestas de Voz | Tipo `mediaPlayback`: protege audio solicitado por el usuario; la notificación no incluye contenido de conversación y no se restaura desde boot/process death |
| `WRITE_EXTERNAL_STORAGE` (solo Android ≤9) | Guardar una imagen generada cuando el usuario pulsa “Guardar” | Limitado con `maxSdkVersion=28`; Android moderno no lo recibe |
| `WAKE_LOCK` | Mantener una operación iniciada por el usuario mientras el FGS está activo | Añadido por `flutter_foreground_task`; no se mantiene sin trabajo/opt-in |
| `ACCESS_NETWORK_STATE` | Adaptar componentes de red al estado de conectividad | Permiso normal añadido por dependencias Android |
| `USE_BIOMETRIC` | App Lock opcional con biometría del dispositivo | Delega la verificación en Android mediante `local_auth`; Hermes Console no accede a plantillas ni datos biométricos |
| `USE_FINGERPRINT` | Compatibilidad biométrica en Android antiguos | Alias legado de `local_auth`; la app no accede a datos biométricos |
| `RECEIVE_BOOT_COMPLETED` | Restaurar la escucha persistente elegida por el usuario | Restaura solo automatización: `remoteMessaging` en API ≥35 o el fallback `dataSync` en API ≤34. Nunca inicia micrófono, reproducción, SSH ni SFTP desde boot |
| `dev.xpetalab.hermesconsole.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | Restringir receivers dinámicos internos | Permiso `signature` generado por AndroidX para que solo código firmado como la app pueda dirigirse a receivers no exportados; no es un permiso de usuario ni concede acceso a datos del dispositivo |

### Foreground services — declaración para Play Console

- **Tipo `dataSync`:** mantiene SSH/SFTP iniciado por el usuario —en un servicio
  nativo efímero separado en API ≥35— y, en API ≤34, el fallback Flutter de
  escucha persistente. Ofrece notificación y parada directa.
- **Tipo `remoteMessaging`:** en API ≥35 mantiene la continuidad de chat entre
  el agente/Desktop autoalojado y Console; runs, Cron y Kanban son avisos
  secundarios. Requiere opt-in, notificación persistente y parada directa.
- **Tipo `microphone`:** mantiene una conversación iniciada por el usuario tras
  el opt-in de continuidad. Terminar libera el micrófono y degrada el servicio.
- **Tipo `mediaPlayback`:** mantiene ReadAloud, las respuestas de una
  conversación de voz y sus controles para pausar/reanudar o terminar el audio.
- Los cuatro tipos, su impacto al aplazarse/interrumpirse y sus vídeos se detallan
  en `PLAY_FGS_DECLARATION.md`.

## Permisos EXCLUSIVOS de la variante completa (`full`) — NO en Play

Estos permisos viven en `src/full/AndroidManifest.xml` y **no se incluyen** en el
AAB de Play:

| Permiso | Para qué |
|---|---|
| `com.termux.permission.RUN_COMMAND` | Lanzar/instalar el agente local en Termux (solo en la variante de descarga directa) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Evitar que Doze mate los procesos del agente local; se solicita solo al configurar una instancia local (opt-in) |

Y las `queries` de `com.termux` / `org.fdroid.fdroid` / `market`, también
exclusivas de la variante completa.

## Permisos sensibles/restringidos — estado
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: **eliminado del build de Play** (era el
  de mayor riesgo de objeción). Solo en la variante completa, opt-in.
- `RECEIVE_BOOT_COMPLETED`: restaura únicamente el listener autorizado, como
  `remoteMessaging` en API ≥35 o `dataSync` en API ≤34. SSH/SFTP, micrófono y
  reproducción no se restauran tras boot.
- No se usa `QUERY_ALL_PACKAGES` (solo queries específicas y necesarias).
- No se declara `USE_FULL_SCREEN_INTENT`; la voz usa una notificación normal,
  nunca invade la pantalla de bloqueo con una Activity.
- `READ_PHONE_STATE` y `READ_EXTERNAL_STORAGE` se eliminan explícitamente en el
  manifest principal como defensa frente a cualquier aporte transitivo. Android
  <=9 puede enumerar lectura como consecuencia histórica de
  `WRITE_EXTERNAL_STORAGE maxSdkVersion=28`; Hermes no enumera ni importa
  almacenamiento general y los adjuntos usan SAF/Photo Picker. El resultado
  efectivo debe confirmarse sobre el AAB firmado final.
- Cámara y micrófono se declaran con `uses-feature required=false`: Play no
  debe filtrar tablets o Chromebooks donde esas funciones opcionales no estén
  disponibles.

## Evidencia pendiente antes de Play

- Manifest fusionado y permisos efectivos del AAB firmado finalmente elegido.
- Flujo físico de permiso y ciclo de vida de cámara con un QR real leído por
  ZXing, incluyendo denegación y el fallback de pegar enlace.
- Los cuatro vídeos FGS y la QA física detallada en
  [`PLAY_FGS_DECLARATION.md`](PLAY_FGS_DECLARATION.md).
- Coincidencia entre esta tabla, Data Safety, la política desplegada y el
  artefacto que finalmente se seleccione en Play Console.
