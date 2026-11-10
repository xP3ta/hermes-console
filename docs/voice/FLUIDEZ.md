# Fluidez del modo voz: parámetros de tiempo y sensibilidad

Estado: auditoría de lectura del código. Los valores de esta tabla son los que Console
ya tenía (varios heredados de la configuración de Hermes Desktop, el servidor propio del proyecto);
ninguno se compara con otra app ni se toma de ella: cada valor se juzga por lo que hace en Console
y por lo que se pueda medir en el móvil, y los calibrados nuevos salen de nuestras mediciones. Ninguno de los valores de esta tabla se ha
cambiado en este corte (ver «Cambios»).

## Cómo medir (ya existe, no se ha tocado)

`VoiceTurnLatencyLog` (`conversation/voice_turn_latency_log.dart`) imprime una línea por turno:

    [hermes-voice-latency] turn=N endpoint_to_token_ms=… endpoint_to_audio_ms=… token_to_audio_ms=…
                           audio=stream|queue tool=yes|no audio_during_tool=yes|no

Solo existe en el sabor `qa` con `--dart-define=HERMES_VOICE_PERF_TRACE=true`
(`voice_latency_trace.dart:20`): en un APK normal no hay línea. Se lee con
`adb logcat | grep hermes-voice-latency`. `VoiceLatencyTrace` (Timeline, mismo sabor) añade los
puntos finos (`speechEndpoint`, `sttFinal`, `submitStarted`, `submitAccepted`, `firstAcceptedText`,
`ttsFirstFeed`, `pcmFirstAccepted`, `micReleased`). Lo que NO mide hoy: el hueco entre el final del
audio y la reapertura del micrófono (cola de 500 ms más el arranque del recorder). Para decidir el
punto 4 de la tabla hay que anotarlo a mano o añadir ese punto en un corte posterior.

Protocolo de medición: 20 turnos por configuración, mismo texto corto («qué hora es» y una pregunta
que use una herramienta), mismo servidor, altavoz y auriculares por separado. Comparar medianas y
el peor decil, no medias.

## Parámetros

| # | Parámetro | Valor | Dónde | Efecto | Estrategia candidata | Estado |
|---|-----------|-------|-------|--------|----------------------|--------|
| 1 | Silencio de fin de frase (STT por turnos) | 1250 ms; el perfil del servidor puede cambiarlo (`voice.silence`) | `stt_engine.dart:24` (`kVoiceTurnSilenceTimeout`), `voice_server_prefs.dart:12` | Se suma entero a `endpoint_to_token_ms`. Más corto: respuestas antes pero se corta a quien piensa en voz alta. | Mirar la distribución de pausas internas de frase en el móvil; si casi ninguna pasa de ~800 ms, bajar el valor por defecto o hacerlo adaptativo (más corto si el parcial ya termina en punto). | A afinar con medición en el móvil |
| 2 | Silencio inicial sin voz | 12 s | `stt_engine.dart:25` | Cuánto espera el micrófono abierto antes de reabrirse con «no te he oído». Solo afecta a turnos en que nadie habla. | Dejar. Contar cuántos «no te he oído» salen por sesión. | Sin cambio |
| 3 | Duración máxima de un turno | 60 s | `stt_engine.dart:26` | Techo de seguridad. | Dejar. | Sin cambio |
| 4 | Cola acústica tras la última frase | 500 ms fijos, solo si la respuesta terminó (`acousticTail`) | `local_voice_conversation_controller.dart:101` (`_playbackTailGuard`), uso en `_waitForPlaybackTail` | Espera fija entre que acaba el audio y se reabre el micrófono, para no captar el final del altavoz. Con auriculares sobra. | Saltarla (o acortarla) cuando la salida de audio sea auriculares o Bluetooth; mantenerla con altavoz. Requiere conocer la ruta de salida y medir eco con altavoz antes de tocarla. | A afinar con medición en el móvil |
| 5 | Fin de captura del monitor dúplex | 42 fotogramas de 30 ms (1,26 s); el perfil puede cambiarlo | `full_duplex_barge_in_monitor.dart:366`, `endpointSilence` | Cuánto espera tras una interrupción hablada antes de enviarla. Misma lógica que el punto 1. | Mismo estudio que el punto 1; deben moverse juntos. | A afinar con medición en el móvil |
| 6 | Calibración del ruido ambiente | 14 fotogramas (420 ms) | `full_duplex_barge_in_monitor.dart:362` | Tiempo hasta que el monitor puede detectar voz tras armarse. Corre en paralelo al envío, no retrasa el turno. | Dejar. | Sin cambio |
| 7 | Voto por mayoría para el inicio de voz | 8 de 10 fotogramas (300 ms) | `…monitor.dart:363-364` | Sensibilidad frente a ruidos breves: más estricto, menos falsos cortes y más lentitud al interrumpir. | Medir falsos disparos con el altavoz a volumen alto y la latencia de corte de la voz. | A afinar con medición en el móvil |
| 8 | Umbrales de energía | mínimo 0,075; durante reproducción 0,14; techo 0,37 (en unidades de nivel normalizado); multiplicador de ruido 3,5; ajustable con `voice.barge_in_threshold_multiplier` | `…monitor.dart:374-380` | Qué volumen cuenta como voz del usuario y no como eco. | Ya hay un mando del servidor; medir con altavoz y auriculares y proponer valores por ruta. | A afinar con medición en el móvil |
| 9 | Gracia tras reproducción / hueco de reproducción | 17 fotogramas (≈500 ms) / 34 (≈1 s) | `…monitor.dart:368-369` | Ignora el eco que sigue a cada audio. | Dejar hasta medir el punto 8. | A afinar con medición en el móvil |
| 10 | Cola de narración: cuándo empieza a hablar | Una frase completa estable (la última, sin puntuación final, se retiene); frases largas se parten a 160 caracteres; un encabezado inicial ≤ 96 caracteres espera a la primera frase | `streaming_narration_queue.dart` (`maxChunkChars`, `_stablePrefix`, `_coalesceOpeningHeadings`) | Con TTS del móvil o por cola, el primer audio sale al cerrarse la primera frase. Con `speak-stream` del servidor se envía texto cada 150 ms sin esperar frase. | No hay espera fija ni espera a la respuesta entera: empieza en la primera frase. Bajar 160 solo si se ven primeras frases largas sin punto en `token_to_audio_ms`. | Sin cambio; medir `token_to_audio_ms` |
| 11 | Cadencia de envío al `speak-stream` | 150 ms | `local_voice_conversation_controller.dart:93` | Agrupa los trozos de texto que se mandan al servidor de voz. | Dejar. | Sin cambio |
| 12 | Pre-calentado del reconocedor | Solo al poner el dedo en el botón de voz/dictado; solo si hubo voz en este móvil en los últimos 7 días, sin presión de memoria ni ahorro de batería | `chat_recognizer_prewarm.dart`, `voice_service.dart:1319` | Quita los segundos de carga del modelo del primer turno. | Comparar `sttStarted` del primer turno con y sin pre-calentado; revisar que la entrada desde Home y widgets llame también a `armOnMicPressDown` antes de entrar. | A afinar con medición en el móvil |
| 13 | Detector de voz local (`LocalVad`) | espera de fin 600 ms; 2 ventanas para confirmar inicio | `vad/local_vad.dart:80` | Hoy no está conectado a ningún camino de la app (solo tests): no afecta a ningún turno. | Si se conecta, no usar 600 ms sin medir contra el punto 1. | Sin efecto hoy |
| 14 | Espera del monitor a estar listo | 3 s | `…monitor.dart:69` | Techo para que el monitor abra su recorder; el envío no lo espera. | Dejar. | Sin cambio |

Parámetros nuevos de este corte (de cuidado, no de fluidez):

| Parámetro | Valor | Dónde | Efecto |
|-----------|-------|-------|--------|
| Asentamiento del cambio de ruta de audio | 600 ms | `LocalVoiceConversationController(routeChangeSettle:)` | Un auricular que se conecta emite varios eventos seguidos; se reabre el micrófono una sola vez cuando se calman. Medir si 600 ms deja al usuario sin micrófono perceptiblemente. |
| Enfriamiento de la reapertura de GPT-Live | 20 s | `GptLiveVoiceConversationController.routeReopenCooldown` | Si la ruta vuelve a cambiar antes de 20 s no se reabre otra vez (evita bucles con un enlace que parpadea); queda cerrada con el aviso de siempre. |

## Cambios hechos en este corte

Ninguno sobre los tiempos o umbrales de la tabla. Revisados uno a uno: no hay una espera fija que
sobre sin condición ni un arranque de voz que espere a la respuesta completa. Las dos candidatas
reales (puntos 1 y 4) cambian el comportamiento audible con eco o con pausas del usuario y no se
pueden justificar sin medición en el móvil.

Sí cambia la fluidez tras un error: el envío fallido ya no reabre el micrófono por sí solo
(el aviso se borraba al instante y el texto se perdía); ahora espera el reintento.

## Interrupción provisional reversible (barge-in): diseño, no implementado

Requisito de comportamiento: al detectar posible voz mientras habla la respuesta, primero solo se
PAUSA la salida; el turno se cancela únicamente si la voz se confirma con el criterio que Console ya
usa; si no se confirma (ruido), el audio se REANUDA sin perder lo dicho. Interruptor aparte,
apagado por defecto, junto al ajuste de barge-in (`VoiceSettings.bargeInEnabled`, apagado por
defecto, `voice_settings.dart:241`).

Qué hay hoy:

- El monitor (`full_duplex_barge_in_monitor.dart`) solo emite `onSpeechStart` cuando se cumple la
  mayoría de fotogramas (8 de 10). No hay una señal anterior de «posible voz».
- Ese `onSpeechStart` ya es irreversible: `_onFullDuplexSpeechStart` interrumpe el backend,
  invalida la reproducción y silencia la cola de narración.
- Solo el `speak-stream` del servidor se puede pausar y reanudar de forma fiable
  (`HermesSpeechStreamSession.pause()/resume()`, con compuerta de reanudación y sink propio). El TTS
  del móvil, el neuronal local y la ruta por frases solo tienen `stop`.

Por qué no se ha implementado en este corte: solo una de las rutas de salida tiene pausa; la
función quedaría con comportamiento distinto según la ruta. Además exige un estado nuevo en
`VoiceConversationRuntime` (un dueño «pausa provisional» con su propio token, para que ningún
resultado tardío de Pause/Resume pise a `Stop`, `Exit` o a otra interjección) y tocar la cadencia de
envío de texto al servidor (150 ms), que hoy se cancela al pausar.

Qué haría falta:

1. Monitor: dos callbacks opcionales, `onPossibleVoice` (primer fotograma por encima del umbral
   mientras suena audio) y `onPossibleVoiceCleared` (la ventana de 10 fotogramas termina sin
   mayoría). Sin números nuevos: se reutilizan la ventana y los umbrales actuales.
2. Runtime: estado `provisional` con token; `confirm` lleva al camino de hoy
   (`_onFullDuplexSpeechStart`); `clear` reanuda. Todo bajo `_bargeGeneration` y el token de
   reproducción para que un `clear` tardío no reanude lo que ya se canceló.
3. Controlador: en `provisional`, `session.pause()` más parar el envío de texto; en `clear`,
   `session.resume()`, `narration.resume()` y reactivar el envío. Para rutas sin pausa, no hacer nada
   (el comportamiento de hoy) y no ofrecer el interruptor.
4. Ajustes: un interruptor en Ajustes de voz, 9 idiomas, apagado por defecto.
5. Tests con fakes del monitor y del reproductor: pausa → confirma → cancela; pausa → ruido →
   reanuda sin perder texto; `clear` tardío tras `Exit`/`Stop` sin efecto; dos posibles voces
   seguidas.
6. Medición previa en el móvil: cuántas veces por minuto el monitor ve una «posible voz» que no
   se confirma (falsos positivos del primer fotograma), para saber cuántas pausas audibles
   introduciría.

## Instrumentación de medición propuesta

Eventos con nombre propio y estado actual en `VoiceLatencyTrace` (`VoiceLatencyPoint`) y
`VoiceTurnLatencyLog`:

| Evento | Estado |
|--------|--------|
| mic pedido | `turnStarted` al abrir la escucha (solo Timeline) |
| mic listo | `sttStarted` en el motor del sistema (al abrir la captura). Ojo: Whisper y la ruta de servidor emiten `sttStarted` al empezar a TRANSCRIBIR, no al abrir el mic: ambiguo |
| inicio de voz | solo `speechLastAboveThreshold` (la última muestra por encima del umbral, no la primera). Falta el primer inicio |
| fin de voz | `speechEndpoint` o `speechEndpointUnavailable` (el motor del sistema no lo da) |
| endpoint | `VoiceTurnLatencyLog.endpoint()` (inicio de `endpoint_to_*`) |
| STT final | `sttFinal`; `transcriptFinal()` en el log |
| envío | `submitStarted` y `submitAccepted` |
| primer token | `firstAcceptedText` / `backendTextAccepted`; `firstToken()` en el log |
| TTS pedido | `ttsFirstFeed` (speak-stream); `firstSynthesizableChunkUnavailable` cuando no hay pieza |
| primer audio recibido | `pcmFirstReceived` |
| primer audio audible | `pcmFirstAccepted` (el sink aceptó); lo audible está marcado `pcmAudibleUnavailable` (AudioTrack no da callback del primer avance) |
| reproducción terminada | no hay evento para el final natural (`audioStopped` solo en Stop/Exit) |
| listo para escuchar | no existe; lo más cercano es el `sttStarted` del turno siguiente |
| barge: pausa provisional / confirma o reanuda | no existen (la función no está) |
| barge: cancelación | `stopRequested` y `audioStopped` con escenario `bargeIn` |
| barge: STT de la interjección | `sttStarted` / `sttFinal` con escenario `bargeIn` |

Eventos propuestos, no añadidos: `micRequested`, `micReady`, `voiceOnsetFirst`, `playbackFinished`,
`listenReady`, `bargePausedProvisionally`, `bargeConfirmedOrResumed`. No se han añadido porque
`VoiceLatencyTrace` impone un orden causal entre puntos (`voice_latency_trace.dart`, comprobación de
prerrequisitos) y cada punto nuevo necesita su regla y su test de orden: no es un cambio pequeño
y sin riesgo. `playbackFinished` y `listenReady` darían, restados, el hueco real de los puntos 4 y 12 de
la tabla de parámetros; son los dos primeros a añadir en un corte propio.

## Parte C: comprobaciones de código

**1. Entrada a GPT-Live con comprobaciones locales. Confirmado y corregido.** La pantalla ejecutaba
`_maybeOfferNativeVoice` (consentimiento, sonda de capacidades y ruta de servidor) y `checkStt()`
(modelo Whisper/Sherpa descargado, permiso, motor) ANTES de que el coordinador eligiera GPT-Live.
Con el perfil en GPT-Live, un modelo local sin descargar o una ruta de servidor no disponible
bloqueaba la entrada con un diálogo que no tiene que ver con GPT-Live. Ahora el coordinador expone
`startsLiveFor` (el mismo dato en caché que usa `enter`) y la pantalla, cuando GPT-Live va a
arrancar, se salta la ruta de servidor y sustituye el chequeo por `voiceEntryPrecheck`, que solo
pide el permiso de micrófono (Android 14 lo exige antes del servicio de micrófono). Si el modo
todavía no se conoce, se mantiene el comportamiento anterior. Tests: `startsLiveFor` y
`voiceEntryPrecheck`.

**2. Presupuestos de tiempo anidados.**

- Confirmado y corregido: transcripción por el servidor Hermes. El motor corta a los
  `maxDuration + 45 s` (105 s), pero la petición HTTP interior tenía 180–600 s: al vencer el motor,
  la petición seguía viva hasta 10 minutos. Ahora la petición tiene 90 s
  (`kHermesServerTranscribeTimeout`) y es la que aborta primero. El motor deja de tener la
  holgura fija (`transcribeGrace`) para poder probarlo.
- Confirmado y corregido: el mensaje. Un tiempo agotado en la transcripción acababa en «No pude
  entender el micrófono». Ahora es `SttTimeoutError` y el usuario ve que la transcripción tardó
  demasiado, con Reintentar. Queda en el log `[VOICE-PERF] voice.stt.transcribe_timeout
  stage=transcription` (y `voice.barge.transcribe_timeout` para la interjección).
- Sin cambio, correcto: STT con proveedor directo (el `client.close()` en `finally` aborta la
  petición y el mensaje ya nombra al proveedor); TTS de respuesta (al vencer, el motor se recicla en
  `voice_service.dart`).
- No confirmado: Whisper local no se puede cancelar desde Dart (el cálculo en el aislado termina
  solo); solo se evita esperar a su resultado. El `timeout(90 s)` de la interjección de barge-in no
  cancela la petición interior del servidor (misma situación que la de arriba, pero con el límite
  de 90 s; no se ha tocado). El mensaje al usuario cuando vence el TTS en la ruta de frases no se
  ha rastreado hasta la pantalla.

**3. Primer PCM del `speak-stream`. Confirmado y corregido.** `open()` termina cuando el socket está
listo, no cuando llega el `start` ni el primer audio; después solo había un tope de 3 minutos
(`finishTimeout`), y solo tras enviar el cierre. Un socket abierto que nunca enviaba audio dejaba
la respuesta muda hasta 3 minutos. Ahora hay un tope de «sin primer audio» de 20 s
(`kSpeechStreamFirstAudioTimeout`), contado desde el último texto enviado mientras no ha llegado
audio; la primera muestra PCM lo desactiva y una pausa lo suspende. Al vencer cae por el camino de
reserva ya existente (resultado `fallback`, el POST narra el mismo texto). 20 s es un valor de
partida: a calibrar con `pcmFirstReceived` en el móvil.
