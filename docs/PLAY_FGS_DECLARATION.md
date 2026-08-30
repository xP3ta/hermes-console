# Declaración FGS (Foreground Service) para Play Console

**Tipos declarados**: `dataSync`, `microphone` y `mediaPlayback` sobre el único
servicio no exportado de `flutter_foreground_task`.

**Revisado**: 2026-08-30 para el candidato fuente `1.2.8 (4943)`. Los tipos
coinciden con el manifest versionado, pero el AAB firmado, su manifest fusionado
y la demostración física todavía están pendientes. Copiar o adaptar en Play
Console → Contenido de la aplicación → Permisos de servicios en primer plano
solo después de cerrar esos gates. Google exige declarar cada tipo, describir el
efecto de un aplazamiento/interrupción y aportar un vídeo que muestre cómo lo
activa el usuario. Los tres vídeos continúan pendientes de generación y
aprobación.

## `dataSync`

### Texto ES

> Hermes Console es un cliente para el agente de IA autoalojado del usuario. El
> servicio `dataSync` mantiene trabajo de red visible e iniciado por el usuario:
> una transferencia SFTP o una sesión SSH activa. Una notificación persistente
> indica que Hermes sigue activo y permite detenerlo. El servicio se libera al
> terminar el trabajo y no envía datos a un backend de XPeta Lab. La vigilancia
> de runs, Cron, Kanban y aprobaciones está desactivada en 1.2.8.

### English text

> Hermes Console is a client for the user's self-hosted AI agent. Its `dataSync`
> foreground service keeps user-visible network work active after leaving the
> app: a user-started SFTP transfer or active SSH session. A persistent
> notification states that Hermes is active and provides a direct Stop action.
> The service is released when work ends and sends no data to an XPeta Lab
> backend. Run, Cron, Kanban, and approval monitoring is disabled in 1.2.8.

- **Caso sugerido en Play**: Network transfer — upload or download /
  server-side processing initiated by the user.
- **Si se aplaza**: la transferencia o sesión deja de mantenerse al salir de la
  app y el usuario puede perder progreso visible o tener que reanudar.
- **Si se interrumpe**: la app reconcilia el estado al volver; una transferencia
  o sesión interactiva puede necesitar reanudación manual.
- **Por qué no basta WorkManager/UIDT**: SSH es una sesión interactiva con estado
  y respuesta en directo; no es una copia diferible aislada. Para nuevas
  transferencias puras debe reevaluarse UIDT.

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

Play solicita un enlace de vídeo para **cada tipo**. Preparar tres vídeos públicos
o no listados, sin tokens, IPs, nombres reales ni conversaciones sensibles.

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

Guardar una copia local fuera de Git y pegar las tres URLs en Play Console. No
usar un vídeo antiguo que solo muestre `dataSync`.

## Verificación técnica obligatoria

- Manifest: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`,
  `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` y
  `foregroundServiceType="dataSync|microphone|mediaPlayback"`.
- `RECORD_AUDIO` se concede antes de crear el FGS `microphone`; la conversación
  se inicia desde una Activity visible, nunca desde background o
  `BOOT_COMPLETED`.
- `RECEIVE_BOOT_COMPLETED` no está presente: tras boot no se restauran
  automatizaciones, SSH/SFTP, micrófono ni reproducción.
- Los tipos se adquieren según el trabajo efectivo: Voz usa
  `microphone|mediaPlayback`, ReadAloud usa solo `mediaPlayback` y el modo sin
  audio usa `dataSync`. Los leases de audio no consumen la cuota limitada de
  `dataSync`.
- Al terminar voz, el único servicio se detiene o se reinicia solo como
  `dataSync` si queda otro trabajo legítimo.
- Una notificación persistente y precisa permanece durante todo el acceso; no
  se usa `USE_FULL_SCREEN_INTENT`.
- Android 15+ limita `dataSync` a seis horas acumuladas en segundo plano por cada
  24 horas; el plugin implementa `Service.onTimeout`. Esa cuota no se mezcla con
  el FGS `microphone`, pero continúa siendo un gate propio del trabajo de red.

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
