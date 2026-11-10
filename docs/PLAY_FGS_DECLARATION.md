# Declaración FGS (Foreground Service) para Play Console

**Tipos declarados**: `dataSync`, `remoteMessaging`, `microphone` y
`mediaPlayback`, repartidos entre tres servicios no exportados. El servicio
Flutter (notificación ID 256) mantiene la escucha opt-in
(`remoteMessaging` en API ≥35, `dataSync` en API ≤34), Voz, Read Aloud y
SSH/SFTP `dataSync` en API ≤34. `HermesExternalDataSyncService` (notificación
ID 257) mantiene únicamente SSH/SFTP `dataSync` en API ≥35.
`HermesTurnKeepAliveService` (notificación ID 258, 1.4.0) mantiene `dataSync`
solo mientras corre un turno que el usuario lanzó y la app acaba de pasar a
segundo plano. Con la app cerrada solo sondea el servidor propio del usuario la
escucha opt-in (la de 1.3.1, restaurada en 1.4.0), apagada hasta que el usuario
la activa (ver «Escucha opt-in» más abajo). La app no usa Firebase, relay de
push ni otro servicio de terceros para los avisos.

**Revisado**: 2026-11-10 para el candidato `1.4.0 (9812)`. Los tipos y los
cinco permisos FGS (`FOREGROUND_SERVICE`, `_DATA_SYNC`, `_REMOTE_MESSAGING`,
`_MICROPHONE`, `_MEDIA_PLAYBACK`) coinciden con el manifest versionado
(`android/app/src/main/AndroidManifest.xml`) y con
`tool/release/full_release_policy.json`; el AAB firmado, su manifest fusionado
y las demostraciones grabadas todavía están pendientes. Copiar o adaptar en
Play Console → Contenido de la aplicación → Permisos de servicios en primer
plano solo después de cerrar esos gates. Google exige declarar cada tipo,
describir el efecto de un aplazamiento/interrupción y aportar un vídeo que
muestre cómo lo activa el usuario. Los cuatro vídeos continúan pendientes de
generación y aprobación.

## `dataSync`

### Texto ES

> Hermes Console es un cliente para el agente de IA autoalojado del usuario. El
> tipo `dataSync` mantiene visibles las transferencias SFTP o sesiones SSH
> iniciadas por el usuario. En Android 15 o posterior usa un servicio nativo
> efímero separado; en Android 14 o anterior, el servicio Flutter compartido.
> Una notificación persistente indica el trabajo y permite detenerlo. Se libera
> al terminar la operación. Este tipo no sondea el servidor, salvo la escucha
> opt-in que el usuario activa en Ajustes y que en Android 14 o anterior usa
> también `dataSync` (ver «Escucha opt-in»); solo esa escucha se re-arma tras
> reiniciar o actualizar, y solo si el usuario la había activado. No se envían
> datos a un backend de XPeta Lab.

### English text

> Hermes Console is a client for the user's self-hosted AI agent. Its `dataSync`
> type keeps user-started SFTP transfers or SSH sessions visible. On Android 15
> or later it uses a separate ephemeral native service; on Android 14 or
> earlier, the shared Flutter service. A persistent notification describes the
> work and provides a direct Stop action. It is released when the work ends.
> This type does not poll the server, except for the opt-in listening the user
> turns on in Settings, which on Android 14 or earlier also uses `dataSync` (see
> the opt-in listening section); only that listening is re-armed after a reboot
> or an update, and only if the user had turned it on. No data is sent to an
> XPeta Lab backend.

- **Caso sugerido en Play**: Network transfer — upload or download /
  server-side processing initiated by the user.
- **Si se aplaza**: una transferencia/sesión deja de mantenerse al salir de la
  app; en Android ≤14 también se retrasan los avisos de la escucha opt-in hasta
  reanudarla.
- **Si se interrumpe**: la app reconcilia el estado al volver; una transferencia
  o sesión interactiva puede necesitar reanudación manual.
- **Por qué no basta WorkManager/UIDT**: SSH es una sesión interactiva con estado
  y respuesta en directo; no es una copia diferible aislada. Para nuevas
  transferencias puras debe reevaluarse UIDT.

### Turno en curso (`HermesTurnKeepAliveService`, 1.4.0)

Referencia: Hermes Desktop retiene recursos solo mientras un turno trabaja
(`apps/desktop/electron/power-save.ts`, `DEFAULT_KEEP_AWAKE_MODE =
'while-working'`; `electron/stream-throttle.ts`, ventanas ocultas sin
throttling mientras hay turno y 5 s después). En Android el equivalente es un
servicio en primer plano acotado al turno.

> Console is a client for the user's own Hermes agent server. When the user
> sends a request and leaves the app while the agent is still working, a short
> foreground service keeps the app's existing network connection to the user's
> server open so the agent's output (progress, tool results, final reply) keeps
> downloading and the ongoing "Hermes is working" notification stays accurate.
> It starts only while a turn is running, only right after the user leaves the
> app, never at boot, never restarts itself, runs no background polling
> listener (it only asks the server once in a while whether that turn is still
> running), stops within seconds of the turn ending, when the user returns to
> the app, when the user taps Stop, or after 30 minutes at most. It can be turned off in Settings › Notifications. SSH/SFTP transfers
> the user starts use the same type (existing declaration).

- **Si se aplaza/interrumpe**: la respuesta deja de llegar con la app oculta;
  la fila en curso se mantiene con el último estado real y la comprobación
  acotada en segundo plano (WorkManager, ≤10 min) y, si está activada, la
  escucha opt-in avisan del final;
  al volver, la app relee el turno.
- **Notificación**: resumen de grupo silencioso del canal «en curso»; con una
  fila viva de chat SystemUI muestra una sola tarjeta (la fila, con Parar).
- **Ajuste**: «Mantener conexión mientras trabaja en segundo plano», activado
  por defecto como el `while-working` de Desktop. Con App Lock no arranca.
- **Plan B si Play no acepta `dataSync`**: `specialUse` con
  `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` (el texto se prepara aparte, fuera del
  repositorio, si hace falta).
- **Vídeo**: enviar un turno largo, pulsar Inicio, enseñar la tarjeta que avanza
  sin abrir la app, el fin del turno y la desaparición del servicio; apagar el
  ajuste y repetir.

## `remoteMessaging`

Uso: la escucha opt-in «Escuchar en segundo plano» (Ajustes › Notificaciones),
apagada por defecto. Servicio Flutter (notificación 256): `remoteMessaging` en
API ≥35 y `dataSync` en API ≤34. Qué hace de verdad: consulta cada 30 s (con
salas activas) a 3 min (en reposo) solo el servidor Hermes del propio usuario y
muestra avisos locales de resultados de Cron, cambios de Kanban y avisos de
salas (`lib/core/services/notifications/background_listener.dart`,
`listenerIdleIntervalMs`). No sondea sesiones ni aprobaciones de chat: eso
depende de las conexiones de la app abierta. No hay servidor de XPeta Lab en el
camino.

### Texto ES

> Hermes Console es un cliente del servidor del agente Hermes del propio
> usuario. Cuando el usuario activa «Escuchar en segundo plano» en Ajustes >
> Notificaciones (apagado por defecto), un servicio en primer plano con
> notificación fija y botón Parar consulta solo el servidor del usuario, cada
> 30 s a 3 min, para que resultados de tareas programadas, cambios del tablero
> de tareas y avisos de salas lleguen como notificaciones locales con la app
> cerrada. En Android 15 o posterior usa `remoteMessaging`; en Android 14 o
> anterior, `dataSync`. Se reanuda tras reiniciar o actualizar solo si el
> usuario lo había activado. Los avisos ocultan el contenido por defecto y no
> llevan contenido con App Lock. No se envían datos a ningún servidor de XPeta
> Lab ni se requiere Google Play Services.

### English text

> Hermes Console is a client for the user's own Hermes agent server. When the
> user turns on "Listen in background" in Settings > Notifications (off by
> default), a foreground service with an ongoing notification and a Stop action
> checks only the user's own server, every 30 seconds to 3 minutes, so
> scheduled-job results, task-board changes and room notices reach the user as
> local notifications while the app is closed. It runs as `remoteMessaging` on
> Android 15 or later and as `dataSync` on Android 14 or earlier. It resumes
> after a reboot or an app update only if the user had turned it on. Alerts hide
> their content by default and carry none when App Lock is on. No data is sent
> to any XPeta Lab server and Google Play Services are not required.

- **Caso sugerido en Play**: el más cercano de la lista de Play (en 1.3.1 se
  usó «Relay text communication to another device»). Que el encaje sea
  aceptado por Play no está verificado; el texto describe solo lo que el código
  hace (avisos de Cron/Kanban/salas desde el servidor propio, no continuidad de
  chat).
- **Si se aplaza/interrumpe**: los avisos de Cron, Kanban y salas no llegan con
  la app cerrada hasta que el usuario la reabre o reanuda la escucha; los
  resultados siguen en el servidor.
- **Control y minimización**: opt-in separado, apagado por defecto, notificación
  fija con Parar, parada desde Ajustes, intervalo adaptativo, sin contenido en
  los avisos con App Lock. `HermesAutomationRebootReceiver` la re-arma tras
  reinicio/actualización solo si estaba activada y, si no, sanea el estado y
  para el servicio.
- **Efecto visible**: en Android 15 o posterior, con un turno en segundo plano y
  la escucha encendida hay dos tarjetas fijas (escucha y turno).
- **Vídeo**: activar «Escuchar en segundo plano» y mostrar la notificación
  fija; cerrar la app (quitarla de recientes); provocar en el servidor un
  resultado de Cron o un cambio de Kanban; mostrar el aviso local, abrir la app
  desde él y pulsar Parar en la notificación. No basar el vídeo en una
  respuesta de chat. Variante Android 14 (`dataSync`) si hay dispositivo.

## `microphone`

### Texto ES

> Hermes Console usa `microphone` para continuar una conversación de voz que el
> usuario inicia expresamente dentro de la app. El servicio solo arranca desde
> una Activity visible, después de conceder el permiso y aceptar el aviso de
> voz. Continuar al abandonar o bloquear la app requiere una elección separada,
> apagada por defecto. Android muestra una notificación persistente con controles
> para pausar, continuar, abrir y terminar. Terminar libera el micrófono. Nunca
> se inicia desde un reinicio ni desde un receiver y la conversación no se
> restaura tras process death. La app no almacena el audio ni opera un backend
> propio.

### English text

> Hermes Console uses `microphone` to continue a voice conversation explicitly
> started by the user inside the app. The service only starts from a visible
> Activity after permission is granted and the voice disclosure is accepted.
> Continuing after leaving or locking the app requires a separate choice that is
> off by default. Android shows a persistent notification with controls to pause,
> continue, open, and end. End releases the microphone. It never starts from
> reboot or a background receiver, and the conversation is not restored after
> process death. The app does not store audio or operate its own backend.

- **Caso sugerido en Play**: Background audio access — a user-started voice
  conversation without storing the recording.
- **Si se aplaza**: la voz se pausa al salir; chat, dictado manual y el resto de
  la app siguen disponibles.
- **Si se interrumpe**: se libera el recorder. La conversación queda pausada y
  puede continuarse desde la notificación/app o terminarse.
- **Controles y minimización**: opt-in separado, una notificación LOW,
  Pausar/Continuar/Abrir/Terminar y prioridad que entrega el único micrófono a
  conversación o dictado.
- **Interrupción hablada**: si el usuario activa además esa preferencia, una
  sesión ya iniciada puede aceptar otro turno o «cállate» fuera de la app. Falla
  cerrado durante playback por altavoz, conserva la interrupción durante
  generación o con una salida privada confirmada y nunca arma escucha en reposo.

## `mediaPlayback`

### Texto ES

> ReadAloud reproduce una respuesta únicamente después de que el usuario pulse
> Leer o active voluntariamente la lectura automática. El servicio
> `mediaPlayback` permite que esa reproducción iniciada continúe al bloquear o
> abandonar la app. La notificación no contiene el texto de la conversación y
> ofrece Pausar/Reanudar/Terminar. Terminar libera el audio; no hay reproducción
> restaurada tras reinicio o process death. El mismo tipo protege las respuestas
> de una conversación de voz iniciada por el usuario. No existe un backend de
> audio de XPeta Lab.

### English text

> Read Aloud plays a response only after the user taps Read or voluntarily
> enables automatic reading. The `mediaPlayback` service lets that user-started
> playback continue after locking or leaving the app. Its notification contains
> no conversation text and provides Pause/Resume/End controls. End releases
> audio, and playback is not restored after reboot or process death. The same
> type protects replies in a user-started voice conversation. No XPeta Lab audio
> backend is involved.

- **Caso sugerido en Play**: Media playback — user-requested spoken content.
- **Si se aplaza**: ReadAloud y las respuestas de Voz solo pueden continuar con
  la app visible.
- **Si se interrumpe**: la reproducción se detiene y puede reanudarse desde la
  última frase, sin repetir la respuesta completa.

## Vídeos requeridos

Play solicita un enlace de vídeo para **cada tipo**. Preparar cuatro vídeos públicos
o no listados, sin tokens, IPs, nombres reales ni conversaciones sensibles.

### `remoteMessaging` (30–45 s)

Guion en la sección `remoteMessaging` (escucha opt-in).

### `dataSync` (≤30 s)

1. Iniciar una transferencia SFTP demo de unos 15 s.
2. Ir al launcher y mostrar la notificación persistente y Stop.
3. Volver y enseñar la transferencia completada, o pulsar Stop y mostrar su retirada.

### `microphone` (30–45 s)

1. En Ajustes → Voz, mostrar el modo conversación y aceptar explícitamente su
   divulgación y continuidad fuera de la app.
2. Iniciar Voz desde un chat, ir al launcher y mostrar una sola notificación y
   el indicador de micrófono.
3. Hablar y oír una respuesta. Solo con una salida privada físicamente
   confirmada, activar «Interrumpir hablando», decir «cállate» durante playback
   y mostrar que termina y libera el micrófono. Sin ese hardware, usar
   `Parar y hablar` y registrar el caso hablado como `UNAVAILABLE`.
4. Tocar la notificación para abrir el chat propietario y enseñar que, sin el
   opt-in de continuidad, abandonar o bloquear la app pausa el micrófono.

### `mediaPlayback` (≤30 s)

1. Pulsar Leer sobre una respuesta demo.
2. Ir al launcher y mostrar la notificación sin contenido de conversación.
3. Pulsar Pausar, Reanudar y Terminar; comprobar que el audio se detiene.

Para el servicio de turno (1.4.0), el vídeo de `dataSync` puede incluir además
el guion de «Turno en curso». Guardar una copia local fuera de Git y pegar las
cuatro URLs en Play Console. No usar vídeos de versiones anteriores a 1.4.0.

## Verificación técnica obligatoria

- Manifest: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`,
  `FOREGROUND_SERVICE_REMOTE_MESSAGING`, `FOREGROUND_SERVICE_MICROPHONE` y
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK`. El servicio Flutter declara
  `dataSync|remoteMessaging|microphone|mediaPlayback`; `HermesExternalDataSyncService`
  y `HermesTurnKeepAliveService` declaran solo `dataSync`. Se comprueba sobre
  el AAB elegido con `bundletool dump manifest` y
  `tool/release/check_manifest_policy.py`: los tres servicios y sus tipos, y los
  cinco permisos, tienen que ser exactamente los de
  `tool/release/full_release_policy.json`.
- `RECORD_AUDIO` se concede antes de crear el FGS `microphone`; la conversación
  se inicia desde una Activity visible, nunca desde background o
  `BOOT_COMPLETED`.
- `RECEIVE_BOOT_COMPLETED` solo re-arma la escucha opt-in (1.3.1): el receptor
  propio `HermesAutomationRebootReceiver` sanea el estado y, si el usuario no la
  activó, para el servicio. El permiso y el receptor de `flutter_foreground_task`
  se retiran del manifest fusionado. Voz, Read Aloud y SSH/SFTP nunca se
  restauran tras boot, actualización ni process death.
- **Escucha opt-in (restaurada en 1.4.0, igual que 1.3.1):** el servicio Flutter
  (notificación 256) usa `remoteMessaging` en API ≥35 y `dataSync` en API ≤34,
  solo tras activar Ajustes > Notificaciones > «Escuchar en segundo plano»;
  sondea el servidor propio del usuario cada 30 s–3 min para Cron, Kanban y
  salas. Su declaración y su vídeo son los de la sección `remoteMessaging`.
- Los tipos se adquieren según el trabajo efectivo: el servicio Flutter usa
  `microphone|mediaPlayback` para Voz, solo `mediaPlayback` para Read Aloud y
  `dataSync` para SSH/SFTP en API ≤34. En API ≥35, SSH/SFTP adquiere el
  servicio nativo `dataSync` separado. Los leases de audio no consumen esa
  cuota.
- Al terminar Voz, el servicio Flutter se detiene o se reinicia con el tipo de
  red exacto que siga teniendo demanda. No altera el servicio nativo SSH/SFTP.
- Una notificación persistente y precisa permanece durante todo el acceso; no
  se usa `USE_FULL_SCREEN_INTENT`.
- Android 15+ limita `dataSync` a seis horas acumuladas en segundo plano por cada
  24 horas y prohíbe iniciarlo desde `BOOT_COMPLETED`.
  `HermesExternalDataSyncService` implementa `Service.onTimeout` y detiene solo
  el trabajo externo; la cuota es un gate propio de SSH/SFTP.

## Fuentes oficiales revisadas

- Google Play, anuncio de políticas del 15-07-2026: aclaración de que las
  integraciones de IA de terceros están sujetas a uso limitado, divulgación y
  consentimiento: <https://support.google.com/googleplay/android-developer/answer/17134731>
- Declaración de tipos FGS y requisitos de vídeo:
  <https://support.google.com/googleplay/android-developer/answer/13392821>
- Requisitos Android del tipo `microphone` (`RECORD_AUDIO`, inicio visible y no
  boot): <https://developer.android.com/develop/background-work/services/fgs/service-types#microphone>
- Política de datos de usuario y aviso destacado:
  <https://support.google.com/googleplay/android-developer/answer/10144311>
