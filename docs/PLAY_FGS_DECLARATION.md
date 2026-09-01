# Declaración FGS (Foreground Service) para Play Console

**Tipos declarados**: `dataSync`, `remoteMessaging`, `microphone` y
`mediaPlayback`, repartidos entre dos servicios no exportados. El servicio
Flutter (notificación ID 256) mantiene `remoteMessaging`, Voz, Read Aloud y el
fallback `dataSync` de API ≤34. `HermesExternalDataSyncService` (notificación
ID 257) mantiene únicamente SSH/SFTP `dataSync` en API ≥35.

**Revisado**: 2026-09-01 para el candidato fuente `1.2.9`. Los tipos
coinciden con el manifest versionado, pero el AAB firmado, su manifest fusionado
y la demostración física todavía están pendientes. Copiar o adaptar en Play
Console → Contenido de la aplicación → Permisos de servicios en primer plano
solo después de cerrar esos gates. Google exige declarar cada tipo, describir el
efecto de un aplazamiento/interrupción y aportar un vídeo que muestre cómo lo
activa el usuario. Los cuatro vídeos continúan pendientes de generación y
aprobación.

## `dataSync`

### Texto ES

> Hermes Console es un cliente para el agente de IA autoalojado del usuario. El
> tipo `dataSync` mantiene dos clases de red visibles: transferencias SFTP o
> sesiones SSH iniciadas por el usuario y, únicamente en Android 14 o anterior,
> el fallback compatible de «Escuchar en segundo plano». En Android 15 o
> posterior, SSH/SFTP usa un servicio nativo efímero separado y la escucha usa
> `remoteMessaging`; así el timeout de una transferencia no puede derribar la
> escucha permanente. Una notificación persistente indica el trabajo y permite
> detenerlo. SSH/SFTP se libera al terminar; la escucha dura hasta que el
> usuario la desactiva. No se envían datos a un backend de XPeta Lab.

### English text

> Hermes Console is a client for the user's self-hosted AI agent. Its `dataSync`
> type keeps two visible network cases active: user-started SFTP transfers or
> SSH sessions and, only on Android 14 or earlier, the compatible fallback for
> “Listen in background.” On Android 15 or later, SSH/SFTP uses a separate
> ephemeral native service while listening uses `remoteMessaging`, so a
> transfer timeout cannot stop permanent listening. A persistent notification
> describes the work and provides a direct Stop action. SSH/SFTP is released
> when work ends; listening lasts until the user turns it off. No data is sent
> to an XPeta Lab backend.

- **Caso sugerido en Play**: Network transfer — upload or download /
  server-side processing initiated by the user.
- **Si se aplaza**: una transferencia/sesión deja de mantenerse al salir de la
  app; en Android ≤14 también se retrasan las respuestas y automatizaciones
  hasta reanudar la escucha.
- **Si se interrumpe**: la app reconcilia el estado al volver; una transferencia
  o sesión interactiva puede necesitar reanudación manual.
- **Por qué no basta WorkManager/UIDT**: SSH es una sesión interactiva con estado
  y respuesta en directo; no es una copia diferible aislada. Para nuevas
  transferencias puras debe reevaluarse UIDT.

## `remoteMessaging`

### Texto ES

> En Android 15 o posterior, Hermes Console usa `remoteMessaging` para mantener
> la continuidad de chat entre el agente de IA autoalojado/cliente Desktop del
> usuario y su móvil. El usuario activa expresamente «Escuchar en segundo
> plano»; la misma conexión puede avisar de runs, Cron y Kanban como efectos
> secundarios. La escucha dura hasta que se desactiva y una notificación
> persistente incluye Parar. No se envían datos a un backend de XPeta Lab ni se
> requiere Google Play Services.

### English text

> On Android 15 or later, Hermes Console uses `remoteMessaging` to maintain chat
> continuity between the user's self-hosted AI agent/Desktop client and their
> phone. The user explicitly enables “Listen in background”; the same connection
> can surface run, Cron, and Kanban updates as secondary outcomes. Listening
> lasts until the user turns it off, and a persistent notification includes a
> Stop action. No data is sent to an XPeta Lab backend and Google Play Services
> are not required.

- **Caso sugerido en Play**: Relay text communication to another device.
- **Si se aplaza/interrumpe**: las respuestas y automatizaciones siguen en el
  agente, pero el móvil no puede avisar a tiempo hasta que se reanude la escucha.
- **Control y minimización**: opt-in separado, canal LOW, intervalo adaptativo,
  sin wake-lock/Wi-Fi-lock continuo y parada directa desde ajustes/notificación.

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

### `dataSync` (≤30 s)

1. Iniciar una transferencia SFTP demo de unos 15 s.
2. Ir al launcher y mostrar la notificación persistente y Stop.
3. Volver y enseñar la transferencia completada, o pulsar Stop y mostrar su retirada.

### `remoteMessaging` (30–45 s)

1. Activar «Escuchar en segundo plano» y mostrar la notificación persistente.
2. Ir al launcher y completar una respuesta de chat desde el agente/Desktop.
3. Mostrar el aviso recibido, abrir el mismo chat en Console y pulsar Parar para
   demostrar continuidad entre dispositivos y control del usuario. Cron/Kanban
   pueden aparecer como resultado secundario, no como justificación principal.

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

Guardar una copia local fuera de Git y pegar las cuatro URLs en Play Console. No
usar un vídeo antiguo que solo muestre `dataSync`.

## Verificación técnica obligatoria

- Manifest: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`,
  `FOREGROUND_SERVICE_REMOTE_MESSAGING`, `FOREGROUND_SERVICE_MICROPHONE` y
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK`. El servicio Flutter declara
  `dataSync|remoteMessaging|microphone|mediaPlayback`; el servicio nativo
  separado declara solo `dataSync`.
- `RECORD_AUDIO` se concede antes de crear el FGS `microphone`; la conversación
  se inicia desde una Activity visible, nunca desde background o
  `BOOT_COMPLETED`.
- `RECEIVE_BOOT_COMPLETED` restaura únicamente la automatización si el opt-in
  sigue activo: `remoteMessaging` en API ≥35 y el fallback `dataSync` en API
  ≤34. Nunca restaura SSH/SFTP, micrófono ni reproducción.
- Los tipos se adquieren según el trabajo efectivo: el servicio Flutter usa
  `microphone|mediaPlayback` para Voz, solo `mediaPlayback` para Read Aloud,
  `remoteMessaging` para la escucha en API ≥35 y `dataSync` para la escucha y
  SSH/SFTP en API ≤34. En API ≥35, SSH/SFTP adquiere el servicio nativo
  `dataSync` separado. Los leases de audio no consumen esa cuota.
- Al terminar Voz, el servicio Flutter se detiene o se reinicia con el tipo de
  red exacto que siga teniendo demanda. No altera el servicio nativo SSH/SFTP.
- Una notificación persistente y precisa permanece durante todo el acceso; no
  se usa `USE_FULL_SCREEN_INTENT`.
- Android 15+ limita `dataSync` a seis horas acumuladas en segundo plano por cada
  24 horas y prohíbe iniciarlo desde `BOOT_COMPLETED`; por eso la escucha usa
  `remoteMessaging` allí. `HermesExternalDataSyncService` implementa
  `Service.onTimeout` y detiene solo el trabajo externo; la cuota sigue siendo
  un gate propio de SSH/SFTP y no alcanza al listener permanente.

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
