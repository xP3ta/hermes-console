# Harness Perfetto de voz (qaProfile)

Este harness captura rendimiento de `dev.xpetalab.hermesconsole.qa` sin
instalar APK, reiniciar el Pixel, forzar la parada de la app ni alterar los
baselines globales del dispositivo. No ejecuta `batterystats reset`, `gfxinfo
reset`, `battery unplug` ni recoge logcat. La traza contiene eventos de
planificacion, frames, contadores de recursos y los nombres/argumentos opacos de
la instrumentacion `hermes.voice.*`; no solicita transcript, texto, audio PCM,
sesion, modelo, URL, token o cookie.

La traza es evidencia **local y confidencial**, no un artefacto anonimo ni
publicable. `process_stats`, `sched`, Binder y las fuentes globales de energia o
wakelocks pueden incluir nombres, PID e hilos de Hermes, Android y otras apps
activas durante la ventana. No adjuntar `trace.pftrace`, metadata o CSV fuera
del entorno de QA sin una revision de privacidad separada.

El serial físico no se versiona. Debe pasarse con `--serial` o
`HERMES_QA_SERIAL`; el package no es parametrizable para evitar medir otra app.

## Fuentes cerradas

El doctor descubre las fuentes reales exclusivamente con:

```bash
adb -s "$HERMES_QA_SERIAL" shell perfetto --query --long
```

Nunca usa `--query-raw`, porque esa salida protobuf exigiría decodificacion.

Requeridas para abrir el gate de captura:

- `linux.ftrace`
- `linux.process_stats`
- `android.surfaceflinger.frametimeline`
- `android.cpu_per_uid`
- `track_event`

Suplementarias, reportadas como disponibles o PENDING según el Pixel/kernel:

- `android.surfaceflinger.frame`
- `android.app_wakelocks`
- `android.kernel_wakelocks`
- `android.power`
- `linux.sysfs_power`

El template solicita exactamente esas diez fuentes. No solicita
`android.ui.jank` standalone: `android.surfaceflinger.frametimeline` es la
fuente canonica de frames/jank.

## Trace processor oficial y fijado

`trace_processor.lock` fija el prebuilt oficial de Google Perfetto `v57.2`
para Linux x86_64 mediante tag/commit, ruta LUCI exacta, tamano y SHA-256. El
bootstrap `tools/trace_processor` contenido en ese tag queda registrado solo
como dato de procedencia y declara todavia `v56.1`; por tanto no se usa como
autoridad del binario `v57.2`. El instalador descarga la ruta LUCI fijada,
verifica tamano+hash+version/commit antes de aceptarla y escribe solo dentro de
`tool/qa/perfetto/.tools`; no usa la cache global de Perfetto en `~/.local` ni
modifica `PATH`.

```bash
./tool/qa/perfetto/install_trace_processor.sh
./tool/qa/perfetto/install_trace_processor.sh --verify-only
```

`--verify-only` no usa red, no crea `.tools` y no cambia permisos: exige que el
binario ya exista, sea ejecutable y coincida. El binario queda ignorado por Git,
mientras el lock y el instalador si forman parte del harness reproducible. Ruta
fijada en este host:

```text
tool/qa/perfetto/.tools/trace_processor_shell-v57.2-linux-amd64
```

## Secuencia exacta

Ejecutar desde la raiz de `hermes-android`.

1. Comprobar dispositivo, package, allowlist y fuentes sin mutar el Pixel:

```bash
./tool/qa/perfetto/doctor.sh --serial "$HERMES_QA_SERIAL"
```

2. Con la app completamente detenida, solicitar un arranque opt-in de la
   candidata qaProfile con el puente Dart/systrace. El script falla si detecta
   un proceso existente y nunca lo mata o reinicia:

El recibo explicito queda ligado al PID lanzado y sera obligatorio para la
captura:

```bash
./tool/qa/perfetto/launch_trace_opt_in.sh \
  --serial "$HERMES_QA_SERIAL" \
  --receipt "$PWD/build/qa/perfetto/voice-server-normal/launch_receipt.txt"
```

El comando de Activity usado incluye literalmente `--ez trace-systrace true`.
Antes de iniciarla, el launcher resuelve el componente MAIN/LAUNCHER real con
Package Manager, exige que pertenezca al package QA y usa `am start -n`. No usa
el selector implicito `am start -p`, incompatible con Android 17. Su aceptacion
no es prueba de instrumentacion; solo la traza posterior puede demostrarla.

3. Iniciar una captura acotada en un directorio elegido explicitamente y
   realizar durante esos 90 segundos el escenario fisico indicado (ruta Phone
   o Server, turno normal, barge-in, Stop o Exit):

```bash
./tool/qa/perfetto/capture.sh \
  --serial "$HERMES_QA_SERIAL" \
  --apk "$PWD/build/app/outputs/flutter-apk/app-qa-profile.apk" \
  --launch-receipt "$PWD/build/qa/perfetto/voice-server-normal/launch_receipt.txt" \
  --route server \
  --scenario normal \
  --duration-seconds 90 \
  --output-dir "$PWD/build/qa/perfetto/voice-server-normal"
```

La captura transmite Perfetto directamente a `trace.pftrace`; no crea ni borra
un fichero remoto. El directorio contiene el config renderizado, informe del
doctor, stderr, metadatos con SHA-256 y verificacion. Se rehusa sobrescribir
cualquiera de esos ficheros.

El transporte usa `adb shell -T` con stdin cerrado y stdout binario. No usa
`adb exec-out`: en adb 37/Android 17 esa variante puede no entregar el config y
dejar Perfetto esperando en `n_tty_read`. Un watchdog host de duracion solicitada
mas 30 segundos termina el transporte si el trace remoto no cierra; el valor
exacto queda registrado en `metadata.txt`.

4. Si la maquina no tenia `trace_processor_shell`, la captura termina con
   estado 2 y diagnostico PENDING, conservando la traza. Instalar/verificar el
   prebuilt fijado y ejecutar:

```bash
./tool/qa/perfetto/verify_trace.sh \
  --trace "$PWD/build/qa/perfetto/voice-server-normal/trace.pftrace" \
  --metadata "$PWD/build/qa/perfetto/voice-server-normal/metadata.txt" \
  --trace-processor \
    "$PWD/tool/qa/perfetto/.tools/trace_processor_shell-v57.2-linux-amd64"
```

El verificador falla si no encuentra al menos un slice `hermes.voice.turn`, su
`hermes.voice.turn_started` y al menos dos puntos `hermes.voice.*` distintos.
Un OK aqui solo valida presencia de instrumentacion; no convierte en PASS la
latencia, temperatura, bateria, audio, barge-in ni la QA fisica.

5. Generar CSV reproducibles con identidad package/UID/PID, p50/p95/p99 de
   voz, FrameTimeline/jank, CPU sched/UID, RSS/PSS/swap, power y wakelocks:

```bash
./tool/qa/perfetto/analyze_trace.sh \
  --capture-dir "$PWD/build/qa/perfetto/voice-server-normal" \
  --output-dir "$PWD/build/qa/perfetto/voice-server-normal/metrics" \
  --trace-processor \
    "$PWD/tool/qa/perfetto/.tools/trace_processor_shell-v57.2-linux-amd64"
```

Cada metrica devuelve `sample_count` y `available`. Si no hay evidencia, sus
valores permanecen `NULL`: nunca se convierten en un cero aparente. Power y
wakelocks de kernel son contexto global limitado a la ventana de voz, no
atribucion causal a Hermes.

Analyzer y verificador rechazan un ejecutable indicado por argumento, variable
de entorno o ruta local si no coincide exactamente con tamano, SHA-256,
version y commit del lock. El SHA-256 de `trace.pftrace` debe coincidir ademas
con `metadata.txt`; una traza intercambiada nunca puede producir PASS.

El CSV de voz separa tres clases de evidencia:

- percentiles offline de cada punto `hermes.voice.*`;
- segmentos causales calculados solo cuando ambos extremos existen en el mismo
  `run_id`/turno y mantienen orden monotono;
- summaries acotados por turno `suffix_append_latency` y
  `pcm_accept_latency`, con `count`, `dropped`, `p50/p95/p99/max` tal como los
  publica la instrumentacion.

Tambien conserva `stt_topology` y `last_above` con columnas de disponibilidad.
Una topologia, un extremo de segmento o un summary ausente queda PENDING; no se
mezclan los percentiles de summaries de distintos turnos porque no pueden
recombinarse exactamente sin sus muestras originales.

6. La observacion post-Exit de diez minutos se ejecuta en otra terminal y no
   alarga ni bloquea la captura Perfetto (que sigue limitada a 300 s):

```bash
./tool/qa/perfetto/post_exit_observe.sh \
  --serial "$HERMES_QA_SERIAL" \
  --capture-metadata "$PWD/build/qa/perfetto/voice-server-exit/metadata.txt" \
  --output-dir "$PWD/build/qa/perfetto/voice-server-exit/post-exit"
```

Debe iniciarse al ejecutar Exit. Toma 11 muestras read-only, de 0 a 600 s. Ata
RSS/swap, PSS de `dumpsys meminfo` y CPU de `/proc/PID/stat` al PID/starttime de
la captura; la CPU usa el `CLK_TCK` del propio Pixel y el intervalo real entre
muestras. Registra ademas AppOps de micro, FGS, bateria/charge counter, USB,
thermal status y maximos skin y CPU/SoC con columnas de disponibilidad. No usa
logcat, no resetea contadores y no inicia, detiene ni reinicia la app.

Produce `post_exit_summary.txt` con CPU media ponderada, PSS/RSS/swap y un
resumen de las ultimas seis muestras (cinco ciclos, aproximadamente cinco
minutos), incluida pendiente de PSS y delta termico. Los gates CPU, PSS y
consumo siguen marcados `PENDING`: este script no recibe ni fabrica la baseline
idle pre-voz con la misma cadencia ni una ventana unplugged equivalente. Por
tanto su mera ejecucion no cierra T061.

## Limites deliberados

- No hay lanzamiento automatico dentro de `capture.sh`: se separa el opt-in de
  la medicion para evitar reinicios invisibles.
- No se ejecuta una captura si falta una fuente requerida. Las fuentes de
  energia suplementarias ausentes permanecen PENDING en el informe.
- La configuracion esta pensada para una build `qaProfile` compilada con
  `HERMES_VOICE_PERF_TRACE=true`; el verificador detecta una build o un arranque
  sin eventos, pero no puede corregirlos.
- Sin una traza con samples y un `trace_processor_shell` compatible, T042C
  permanece PENDING aunque los scripts y SQL superen validacion estatica.
- El lock incluido es deliberadamente `linux-amd64`; otro host debe incorporar
  y revisar una entrada oficial distinta, no reutilizar este binario.
- Las trazas y CSV permanecen locales/confidenciales por contener contexto de
  procesos e hilos del sistema, aunque no recojan contenido conversacional.
- No se infiere causalidad termica solo de Perfetto. Temperatura, carga USB,
  ambiente y una observacion posterior a Exit deben registrarse por separado.
- PSS, sensores skin/CPU-SoC y charge counter pueden no estar expuestos por una
  build concreta de Android. En ese caso se conserva `available=0`/`NA`; no se
  sustituye por RSS, temperatura de bateria o cero.
- El APK local queda fijado por nombre, tamano y SHA-256; tambien se registran
  fingerprint, version instalada, UID y PID. Esto no demuestra por si solo que
  el APK local sea byte a byte el instalado: esa igualdad sigue siendo un gate
  de instalacion/release separado.

## Chat en streaming (F0 de la auditoría de fluidez)

`chat_stream_metrics.sql` lee los eventos `hermes.chat.stream.*` de
`lib/core/services/chat_stream_trace.dart`:
`flush` (el servicio publica), `reveal` (la pantalla revela más),
`tail_build` (se reconstruye la cola viva), `turn_end` (fin del turno: lo que
aparece de golpe) y `highlight` (resaltado de código). Solo los emite una build
`qa` con `--dart-define=HERMES_CHAT_STREAM_TRACE=true`; llevan solo números de
caracteres, nunca texto. Se usa con la misma captura que la voz, sustituyendo
`@TARGET_PID@`, y el jank del mismo tramo sale de `frame_process_metrics.sql`.
El escenario debe ser una respuesta grabada sin datos reales (servidor de
fixtures o backend de e2e).
