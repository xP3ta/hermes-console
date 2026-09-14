// Motores de reconocimiento de voz (voz → texto).
//   • SystemSttEngine: reconocedor del sistema Android (speech_to_text).
//   • Whisper on-device: Fase B (whisper_ggml_plus + record). La interfaz queda
//     lista; hoy se cae a SystemSttEngine.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import 'voice_latency_trace.dart';

export 'package:whisper_ggml_plus/whisper_ggml_plus.dart' show WhisperModel;

/// Ritmo conversacional de Hermes Desktop. Los motores móviles que controlan
/// su propio endpointing comparten estos tiempos para que una pausa natural no
/// corte antes el turno y un monólogo largo tenga el mismo límite de seguridad.
const Duration kVoiceTurnSilenceTimeout = Duration(milliseconds: 1250);
const Duration kVoiceTurnIdleSilenceTimeout = Duration(seconds: 12);
const Duration kVoiceTurnMaxDuration = Duration(seconds: 60);

typedef VoiceTurnTimerFactory =
    Timer Function(Duration duration, void Function() callback);

Timer _defaultVoiceTurnTimer(Duration duration, void Function() callback) =>
    Timer(duration, callback);

/// Resultado parcial o final de la transcripción.
class SttResult {
  final String text;
  final bool isFinal;

  /// Metadatos opcionales del motor en el mensaje FINAL (spec 025 F2). Hoy
  /// solo lo rellena [ServerSttEngine] con lo que manda el servidor v1.1 en
  /// su `final` (`voiced_secs`/`avg_logprob`/`no_speech_prob`/`gate`, si
  /// llegan); antes se logueaban pero no salían de `stt_remote.dart`. Motores
  /// que no lo soporten lo dejan `null` — campo opcional, no rompe a nadie
  /// que ya lea `SttResult`.
  final Map<String, dynamic>? meta;

  const SttResult(this.text, this.isFinal, {this.meta});
}

abstract class SttEngine {
  /// ¿Está disponible el motor en este dispositivo? (permiso/soporte).
  Future<bool> available();

  /// Empieza a escuchar; emite parciales y un final. El stream se cierra al
  /// detener o al recibir el resultado final.
  ///
  /// [onSpeechEnd] se invoca cuando el motor decide por sí mismo que el usuario
  /// dejó de hablar (VAD) y empieza a procesar — útil para que la UI cambie de
  /// "escuchando" a "transcribiendo" sin esperar al resultado final. No se llama
  /// cuando el usuario para manualmente.
  /// [onCaptureReady] se invoca una sola vez, después de que el recorder o el
  /// reconocedor confirme su arranque para la operación vigente. Solicitar el
  /// stream no equivale a este ACK y una operación cancelada no debe emitirlo.
  /// [continuous]: dictado controlado por el usuario. Cuando es true el motor NO
  /// cierra el turno por silencio (las pausas naturales no lo cortan); solo para
  /// con stop() manual o por el tope de seguridad [maxDuration]. Default false:
  /// modo conversación de voz, que sí auto-cierra por silencio para turnos ágiles.
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  });

  /// Detiene la escucha.
  Future<void> stop();

  /// Libera recursos nativos (grabador, etc.).
  Future<void> dispose() async {}

  /// ¿Hay reconocimiento de voz disponible en el dispositivo?
  bool get supportsPartials;
}

/// Motor local capaz de transcribir un WAV ya capturado por el recorder
/// full-duplex. No abre un segundo micrófono ni cambia el origen del audio.
abstract interface class CapturedWavSttEngine {
  Future<String> transcribeCapturedWav(Uint8List wavBytes);
}

/// Listas de preferencia de locales del reconocedor del sistema por idioma de
/// voz efectivo (spec 031). La de 'es' DEBE mantenerse byte a byte como la
/// histórica: un test la ancla (regresión cero en español). Idioma desconocido
/// cae a la de 'es'.
const Map<String, List<String>> kSystemSttLocalePrefs = {
  'es': ['es_ES', 'es_US', 'es_MX', 'es_419', 'es_CO', 'es_AR', 'es-ES', 'es'],
  'en': ['en_US', 'en_GB', 'en_AU', 'en_IN', 'en-US', 'en'],
};

/// Frontera inyectable con los plugins usados por [SystemSttEngine]. Mantiene
/// las carreras de arranque testeables sin necesitar micrófono ni recognizer.
abstract class SystemSttRuntime {
  Future<bool> hasPermission();

  Future<bool> initialize({required void Function(String message) onError});

  Future<List<String>> locales();

  Future<String?> systemLocale();

  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required String? localeId,
    required bool continuous,
  });

  Future<void> stop();

  Future<void> cancel();

  Future<void> dispose();
}

class _PluginSystemSttRuntime implements SystemSttRuntime {
  final SpeechToText _speech = SpeechToText();
  final AudioRecorder _permissions = AudioRecorder();

  @override
  Future<bool> hasPermission() => _permissions.hasPermission();

  @override
  Future<bool> initialize({required void Function(String message) onError}) =>
      _speech.initialize(
        onError: (error) => onError(error.errorMsg),
        onStatus: (_) {},
      );

  @override
  Future<List<String>> locales() async =>
      (await _speech.locales()).map((locale) => locale.localeId).toList();

  @override
  Future<String?> systemLocale() async =>
      (await _speech.systemLocale())?.localeId;

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required String? localeId,
    required bool continuous,
  }) => _speech.listen(
    onResult: (result) => onResult(result.recognizedWords, result.finalResult),
    listenOptions: SpeechListenOptions(
      partialResults: true,
      cancelOnError: true,
      localeId: localeId,
      pauseFor: continuous
          ? const Duration(seconds: 30)
          : kVoiceTurnSilenceTimeout,
      listenFor: kVoiceTurnMaxDuration,
    ),
  );

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();

  @override
  Future<void> dispose() => _permissions.dispose();
}

class _SystemListenOperation {
  _SystemListenOperation(this.generation, this.controller, this.latencyTurn);

  final int generation;
  final StreamController<SttResult> controller;
  final VoiceLatencyTurn? latencyTurn;
  bool cancelled = false;
  bool heardSpeech = false;
  bool started = false;
}

/// Reconocedor del sistema (Android SpeechRecognizer). Da parciales en vivo.
/// Privacidad: según el dispositivo puede usar Google (nube) — divulgado.
class SystemSttEngine implements SttEngine {
  /// Idioma de voz efectivo ('es'|'en') con el que se resuelve el locale del
  /// reconocedor (spec 031). Inmutable por instancia: VoiceService recicla el
  /// motor cuando el idioma de la app cambia (contrato I3).
  final String lang;

  final Duration idleSilenceTimeout;

  SystemSttEngine({
    this.lang = 'es',
    this.idleSilenceTimeout = kVoiceTurnIdleSilenceTimeout,
    SystemSttRuntime? runtime,
    VoiceTurnTimerFactory? timerFactory,
  }) : _runtime = runtime ?? _PluginSystemSttRuntime(),
       _timerFactory = timerFactory ?? _defaultVoiceTurnTimer;

  final SystemSttRuntime _runtime;
  final VoiceTurnTimerFactory _timerFactory;
  Timer? _idleSilenceTimer;
  bool _initialized = false;
  int _generation = 0;
  _SystemListenOperation? _operation;
  Future<void> _startupTail = Future<void>.value();
  Future<void> _stopTail = Future<void>.value();
  bool _disposed = false;
  Future<void>? _disposeFuture;

  /// Última causa de fallo de inicialización. Antes se tragaba en `onError`, así
  /// que el usuario no veía nada cuando el reconocedor no arrancaba.
  String? lastError;

  /// ¿El usuario concedió el permiso de micrófono? Lo consulta [VoiceService.checkStt]
  /// para distinguir "permiso denegado" de "sin reconocedor de voz" y mostrar el
  /// mensaje correcto en la UI.
  bool micGranted = false;

  /// Locale resuelto para el reconocedor (null = usar el del sistema). Se
  /// calcula tras inicializar a partir de los locales REALMENTE disponibles en
  /// el dispositivo. Antes se forzaba `es_ES`: si el móvil tenía otro español
  /// (es_MX/es_US/es_419) o no tenía descargado ese pack concreto, el
  /// reconocedor fallaba con "Failed to get language pack of required locale" y
  /// el dictado no funcionaba (bug real en móviles con español latino).
  String? _resolvedLocale;
  bool _localeResolved = false;

  @override
  bool get supportsPartials => true;

  /// Elige el mejor locale disponible del idioma de voz efectivo [lang]; si no
  /// hay ninguno, cae al del sistema; si tampoco, null (deja que el
  /// reconocedor use su predeterminado).
  bool _isCurrent(_SystemListenOperation operation) =>
      !_disposed &&
      !operation.cancelled &&
      identical(_operation, operation) &&
      operation.generation == _generation;

  void _cancelIdleSilenceTimer() {
    _idleSilenceTimer?.cancel();
    _idleSilenceTimer = null;
  }

  void _armIdleSilenceTimer(_SystemListenOperation operation) {
    _cancelIdleSilenceTimer();
    if (!_isCurrent(operation) || operation.heardSpeech) return;
    _idleSilenceTimer = _timerFactory(idleSilenceTimeout, () {
      _idleSilenceTimer = null;
      if (!_isCurrent(operation) || operation.heardSpeech) return;
      // El timeout inicial significa que no hubo habla. No lo proyectamos
      // como fin de frase: la UI debe rearmar la escucha sin mostrar una
      // transcripcion inexistente.
      unawaited(stop());
    });
  }

  Future<void> _resolveLocale([_SystemListenOperation? operation]) async {
    if (_localeResolved) return;
    try {
      final ids = await _runtime.locales();
      if (operation != null && !_isCurrent(operation)) return;
      String? pick;
      for (final p
          in kSystemSttLocalePrefs[lang] ?? kSystemSttLocalePrefs['es']!) {
        if (ids.contains(p)) {
          pick = p;
          break;
        }
      }
      pick ??= ids
          .where((id) => id.toLowerCase().startsWith(lang))
          .cast<String?>()
          .firstWhere((_) => true, orElse: () => null);
      if (pick == null) {
        pick = await _runtime.systemLocale();
        if (operation != null && !_isCurrent(operation)) return;
      }
      _resolvedLocale = pick;
      _localeResolved = true;
    } catch (error) {
      if (operation != null && !_isCurrent(operation)) return;
      debugPrint('[stt] locale resolution unavailable (${error.runtimeType})');
      _resolvedLocale = null;
      _localeResolved = true;
    }
  }

  Future<bool> _prepare(_SystemListenOperation? operation) async {
    bool current() => operation == null || _isCurrent(operation);

    lastError = null;
    try {
      micGranted = await _runtime.hasPermission();
    } catch (_) {
      if (!current()) return false;
      micGranted = false;
      lastError = 'Could not request microphone permission.';
      return false;
    }
    if (!current()) return false;
    if (!micGranted) {
      lastError = 'Microphone permission denied.';
      return false;
    }
    _initialized = await _runtime.initialize(
      onError: (_) {
        if (current()) lastError = 'System speech recognizer failed.';
      },
    );
    if (!current()) return false;
    if (!_initialized) {
      lastError ??= 'System speech recognizer did not respond.';
      return false;
    }
    await _resolveLocale(operation);
    return current() && _initialized;
  }

  @override
  Future<bool> available() =>
      _disposed ? Future<bool>.value(false) : _prepare(null);

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    _cancelIdleSilenceTimer();
    final previous = _operation;
    if (previous != null) {
      previous.cancelled = true;
      if (!previous.controller.isClosed) unawaited(previous.controller.close());
    }
    final controller = StreamController<SttResult>();
    final operation = _SystemListenOperation(
      ++_generation,
      controller,
      VoiceLatencyTrace.current.currentTurn,
    );
    _operation = operation;
    final stopBeforeStart = _stopTail;
    Future<void> start() async {
      await stopBeforeStart;
      try {
        if (_disposed) {
          await controller.close();
          return;
        }
        if (!_initialized && !await _prepare(operation)) {
          if (_isCurrent(operation)) {
            controller.addError(
              Exception('Speech recognition not available on this device.'),
            );
            await controller.close();
          }
          return;
        }
        if (!_isCurrent(operation)) return;
        final effectiveLocale = _localeResolved ? _resolvedLocale : localeId;
        await _runtime.listen(
          onResult: (text, isFinal) {
            if (!_isCurrent(operation) || controller.isClosed) return;
            if (text.trim().isNotEmpty) {
              operation.heardSpeech = true;
              _cancelIdleSilenceTimer();
            }
            if (isFinal) {
              // speech_to_text does not expose the last voiced sample or an
              // end-of-speech callback through this adapter. Mark the segment
              // unavailable instead of treating a final transcript as VAD.
              operation.latencyTurn?.mark(
                VoiceLatencyPoint.speechEndpointUnavailable,
              );
              operation.latencyTurn?.mark(VoiceLatencyPoint.sttFinal);
            }
            controller.add(SttResult(text, isFinal));
            if (isFinal) {
              _cancelIdleSilenceTimer();
              _operation = null;
              unawaited(controller.close());
            }
          },
          localeId: effectiveLocale,
          continuous: continuous,
        );
        if (!_isCurrent(operation)) return;
        operation.latencyTurn?.mark(VoiceLatencyPoint.sttStarted);
        operation.started = true;
        onCaptureReady?.call();
        if (!continuous) {
          _armIdleSilenceTimer(operation);
        }
      } catch (_) {
        if (_isCurrent(operation) && !controller.isClosed) {
          controller.addError(Exception('Speech recognition failed.'));
          await controller.close();
        }
      }
    }

    _startupTail = _startupTail.then((_) => start(), onError: (_) => start());
    return controller.stream;
  }

  @override
  Future<void> stop() {
    _cancelIdleSilenceTimer();
    final operation = _operation;
    _operation = null;
    _generation++;
    if (operation != null) {
      if (operation.started) {
        operation.latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
      }
      operation.cancelled = true;
      if (!operation.controller.isClosed) {
        unawaited(operation.controller.close());
      }
    }
    final previousStop = _stopTail;
    final result = () async {
      await previousStop;
      await _runtime.stop();
    }();
    _stopTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> dispose() async {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    _cancelIdleSilenceTimer();
    final operation = _operation;
    _operation = null;
    _generation++;
    if (operation != null) {
      operation.cancelled = true;
      if (!operation.controller.isClosed) {
        unawaited(operation.controller.close());
      }
    }
    _disposeFuture = () async {
      await _stopTail;
      await _startupTail;
      await _runtime.cancel();
      await _runtime.dispose();
    }();
    return _disposeFuture!;
  }
}

/// Frontera inyectable con grabación y Whisper para probar arranques tardíos.
abstract class WhisperSttRuntime {
  Future<bool> hasPermission();

  Future<bool> modelReady(WhisperModel model);

  Future<String> createAudioPath();

  Future<void> start(String path);

  Stream<Amplitude> onAmplitudeChanged(Duration interval);

  Future<String?> stop();

  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  });

  Future<void> dispose();
}

class _PluginWhisperSttRuntime implements WhisperSttRuntime {
  final AudioRecorder _recorder = AudioRecorder();
  final WhisperController _whisper = WhisperController();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<bool> modelReady(WhisperModel model) async =>
      File(await _whisper.getPath(model)).existsSync();

  @override
  Future<String> createAudioPath() async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/dictation_${DateTime.now().millisecondsSinceEpoch}.wav';
  }

  @override
  Future<void> start(String path) => _recorder.start(
    const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
    ),
    path: path,
  );

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      _recorder.onAmplitudeChanged(interval);

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) async {
    final result = await _whisper.transcribe(
      model: model,
      audioPath: audioPath,
      lang: lang,
      withTimestamps: false,
      threads: threads,
    );
    return result?.transcription.text.trim() ?? '';
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

class _WhisperListenOperation {
  _WhisperListenOperation(this.generation, this.controller, this.latencyTurn);

  final int generation;
  final StreamController<SttResult> controller;
  final VoiceLatencyTurn? latencyTurn;
  bool cancelled = false;
  bool started = false;
}

/// Whisper on-device (whisper.cpp). Graba a WAV 16 kHz mono y transcribe al
/// detener — 100% privado, sin nube. Sin parciales (resultado al parar).
/// Requiere el modelo descargado (ver VoiceService.downloadWhisperModel).
///
/// VAD (detección de fin de habla): si [vadEnabled], monitoriza la amplitud del
/// micrófono y para de grabar solo tras [silenceTimeout] de silencio sostenido
/// (por debajo de [silenceThresholdDb]), una vez que ha oído voz. Así el usuario
/// no tiene que pulsar para terminar. El nivel normalizado (0..1) se reporta por
/// [onLevel] para feedback visual (el orbe que late con la voz).
class WhisperSttEngine implements SttEngine {
  final WhisperModel model;

  /// Parar solo al detectar silencio (true) o exigir un toque (false).
  final bool vadEnabled;

  /// Umbral de silencio en dBFS: por debajo de esto se cuenta como silencio.
  final double silenceThresholdDb;

  /// Suelo absoluto opcional de inicio de voz en dBFS. Cuando es `null`, el
  /// motor conserva el onset relativo histórico para Android heterogéneo.
  final double? speechOnsetDb;

  /// Silencio sostenido necesario para auto-parar.
  final Duration silenceTimeout;

  /// Tope de seguridad: para de grabar pase lo que pase tras este tiempo.
  final Duration maxDuration;

  /// Cierra una captura conversacional que nunca llegó a oír voz.
  final Duration idleSilenceTimeout;

  /// Descarta un cierre automático sin onset en conversación.
  ///
  /// Se activa únicamente para el STT remoto de Hermes: un timeout de escucha
  /// en silencio no debe subir un WAV ambiental que el servidor pueda convertir
  /// en una alucinación. Un Stop explícito y el dictado continuo conservan su
  /// cierre manual aunque el VAD no haya confirmado el onset.
  final bool discardAutomaticTurnWithoutSpeechOnset;

  /// Reporta el nivel de micrófono normalizado (0 silencio … 1 fuerte).
  final void Function(double level)? onLevel;

  /// Idioma en el que whisper.cpp decodifica ('es'|'en', spec 031). Antes
  /// estaba fijado a 'es': dictar en inglés salía mal transcrito. Inmutable
  /// por instancia: VoiceService recicla el motor si el idioma cambia.
  final String lang;

  final WhisperSttRuntime _runtime;
  final VoiceTurnTimerFactory _timerFactory;

  StreamController<SttResult>? _controller;
  String? _audioPath;
  int _generation = 0;
  _WhisperListenOperation? _operation;
  Future<void> _startupTail = Future<void>.value();
  Future<void> _stopTail = Future<void>.value();
  bool _disposed = false;
  Future<void>? _disposeFuture;

  // Estado del VAD.
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _idleSilenceTimer;
  bool _heardSpeech = false;
  DateTime? _silenceSince;
  DateTime? _startedAt;
  DateTime? _lastVadDebugAt;
  double? _noiseFloorDb;
  final List<double> _noiseFloorSamples = <double>[];
  int _speechOnsetSamples = 0;
  bool _stopping = false;
  bool _discardCurrentAutomaticStop = false;
  bool _continuous = false;
  void Function()? _onSpeechEnd;

  WhisperSttEngine({
    this.model = WhisperModel.base,
    this.vadEnabled = true,
    this.silenceThresholdDb = -40,
    this.speechOnsetDb,
    this.silenceTimeout = kVoiceTurnSilenceTimeout,
    this.maxDuration = kVoiceTurnMaxDuration,
    this.idleSilenceTimeout = kVoiceTurnIdleSilenceTimeout,
    this.discardAutomaticTurnWithoutSpeechOnset = false,
    this.onLevel,
    this.lang = 'es',
    WhisperSttRuntime? runtime,
    VoiceTurnTimerFactory? timerFactory,
  }) : _runtime = runtime ?? _PluginWhisperSttRuntime(),
       _timerFactory = timerFactory ?? _defaultVoiceTurnTimer;

  @override
  bool get supportsPartials => false;

  /// Hilos para Whisper: todos los núcleos disponibles, acotado a [2, 8]. Más
  /// hilos que núcleos no acelera y compite con el resto de la app.
  static int get _threads => Platform.numberOfProcessors.clamp(2, 8);

  @override
  Future<bool> available() async {
    if (_disposed) return false;
    final hasMic = await _runtime.hasPermission();
    if (_disposed) return false;
    final modelReady = await _runtime.modelReady(model);
    return hasMic && modelReady;
  }

  bool _isCurrent(_WhisperListenOperation operation) =>
      !_disposed &&
      !operation.cancelled &&
      identical(_operation, operation) &&
      operation.generation == _generation;

  void _cancelIdleSilenceTimer() {
    _idleSilenceTimer?.cancel();
    _idleSilenceTimer = null;
  }

  void _armIdleSilenceTimer(_WhisperListenOperation operation) {
    _cancelIdleSilenceTimer();
    if (!_isCurrent(operation) || _continuous || _heardSpeech) {
      return;
    }
    _idleSilenceTimer = _timerFactory(idleSilenceTimeout, () {
      _idleSilenceTimer = null;
      if (!_isCurrent(operation) || _continuous || _heardSpeech) {
        return;
      }
      _autoStop(notifySpeechEnd: false);
    });
  }

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    _cancelIdleSilenceTimer();
    final previous = _operation;
    if (previous != null) {
      previous.cancelled = true;
      if (!previous.controller.isClosed) unawaited(previous.controller.close());
    }
    final controller = StreamController<SttResult>();
    final operation = _WhisperListenOperation(
      ++_generation,
      controller,
      VoiceLatencyTrace.current.currentTurn,
    );
    _operation = operation;
    _controller = controller;
    _onSpeechEnd = onSpeechEnd;
    _continuous = continuous;
    _heardSpeech = false;
    _silenceSince = null;
    _lastVadDebugAt = null;
    _noiseFloorDb = null;
    _noiseFloorSamples.clear();
    _speechOnsetSamples = 0;
    _stopping = false;
    _discardCurrentAutomaticStop = false;
    final stopBeforeStart = _stopTail;
    _startupTail = _startupTail.then(
      (_) async {
        await stopBeforeStart;
        await _startOperation(operation, onCaptureReady);
      },
      onError: (_) async {
        await stopBeforeStart;
        await _startOperation(operation, onCaptureReady);
      },
    );
    return controller.stream;
  }

  Future<void> _startOperation(
    _WhisperListenOperation operation,
    void Function()? onCaptureReady,
  ) async {
    final controller = operation.controller;
    String? path;
    try {
      if (!_isCurrent(operation)) {
        if (!controller.isClosed) await controller.close();
        return;
      }
      if (!await _runtime.hasPermission()) {
        if (_isCurrent(operation)) {
          controller.addError(Exception('No microphone permission.'));
          await controller.close();
        }
        return;
      }
      if (!_isCurrent(operation)) return;
      if (!await _runtime.modelReady(model)) {
        if (_isCurrent(operation)) {
          controller.addError(
            Exception('Download the Whisper model in Settings › Voice.'),
          );
          await controller.close();
        }
        return;
      }
      if (!_isCurrent(operation)) return;
      path = await _runtime.createAudioPath();
      if (!_isCurrent(operation)) {
        _deleteAudioFile(path);
        return;
      }
      _audioPath = path;
      await _runtime.start(path);
      if (!_isCurrent(operation)) {
        String? recordedPath;
        try {
          recordedPath = await _runtime.stop();
        } catch (_) {}
        _deleteAudioFile(recordedPath ?? path);
        return;
      }
      operation.started = true;
      onCaptureReady?.call();
      _startedAt = DateTime.now();
      _startVad(operation);
      _armIdleSilenceTimer(operation);
    } catch (_) {
      _deleteAudioFile(path);
      if (_isCurrent(operation) && !controller.isClosed) {
        controller.addError(Exception('Could not record audio.'));
        await controller.close();
      }
    } finally {
      if (!_isCurrent(operation) && !controller.isClosed) {
        await controller.close();
      }
    }
  }

  /// Convierte dBFS (≈ -60 silencio … 0 máximo) a un nivel 0..1 para la UI.
  static double _normalize(double db) => ((db + 60) / 60).clamp(0.0, 1.0);

  // `record` entrega alrededor de -160 dB mientras Android todavía no tiene
  // una lectura real. No es un suelo de ruido: usarlo como baseline convierte
  // la primera muestra ambiental en una falsa detección de voz y el VAD deja
  // de encontrar el final de frase.
  static bool _isUsableVadSample(double db) => db.isFinite && db > -120;

  // Tres lecturas filtran los transitorios breves que introduce el
  // procesamiento VOICE_RECOGNITION sin añadir latencia al clip: el WAV ya se
  // está grabando desde antes de calibrar/detectar. En conversación se muestrea
  // cada 100 ms para conservar el umbral sostenido cercano a Desktop.
  static const int _vadCalibrationSampleTarget = 3;
  static const int _vadOnsetSampleTarget = 3;

  void _markSpeechStarted(_WhisperListenOperation operation, DateTime now) {
    _cancelIdleSilenceTimer();
    _heardSpeech = true;
    _speechOnsetSamples = 0;
    _silenceSince = null;
    operation.latencyTurn?.observeSpeechAboveThreshold();
  }

  /// Monitoriza la amplitud y dispara el auto-stop por silencio. Siempre reporta
  /// el nivel (para el orbe), aunque el VAD esté desactivado.
  void _startVad(_WhisperListenOperation operation) {
    _ampSub?.cancel();
    // La conversación necesita tres votos en una ventana corta, alineada con
    // los ~300 ms sostenidos de Desktop: a 100 ms también reconoce «sí/no» sin
    // esperar el idle. Dictado continuo/manual conserva 200 ms y sus wakeups.
    final amplitudeInterval = vadEnabled && !_continuous
        ? const Duration(milliseconds: 100)
        : const Duration(milliseconds: 200);
    _ampSub = _runtime.onAmplitudeChanged(amplitudeInterval).listen((amp) {
      if (!_isCurrent(operation)) return;
      final db = amp.current;
      onLevel?.call(_normalize(db));
      final now = DateTime.now();
      if (kDebugMode &&
          vadEnabled &&
          (_lastVadDebugAt == null ||
              now.difference(_lastVadDebugAt!) >= const Duration(seconds: 1))) {
        _lastVadDebugAt = now;
        debugPrint(
          '[voice-vad] current=${db.toStringAsFixed(1)} '
          'max=${amp.max.toStringAsFixed(1)} '
          'floor=${_noiseFloorDb?.toStringAsFixed(1)} heard=$_heardSpeech',
        );
      }
      // Tope de seguridad: nunca grabar indefinidamente.
      if (vadEnabled &&
          _startedAt != null &&
          now.difference(_startedAt!) >= maxDuration) {
        _autoStop();
        return;
      }
      if (!_isUsableVadSample(db)) return;
      final noiseFloor = _noiseFloorDb;
      if (!_heardSpeech) {
        // Dictado continuo y VAD manual conservan el onset inmediato: no
        // auto-cierran el clip y el usuario sigue siendo dueño de Stop. La
        // confirmación sostenida solo protege los turnos conversacionales,
        // donde un falso positivo provoca endpoint + transcripción + rearme.
        final requiresSustainedOnset = vadEnabled && !_continuous;
        if (noiseFloor == null) {
          // Si el usuario ya estaba hablando al abrir el recorder, no debemos
          // aprender su voz como ruido. Conserva el fallback absoluto que
          // cubre los picos altos medidos en el Pixel físico; en conversación
          // también debe sostenerse para no aceptar un transitorio aislado.
          if (db >= (speechOnsetDb ?? -8)) {
            if (!requiresSustainedOnset ||
                ++_speechOnsetSamples >= _vadOnsetSampleTarget) {
              _markSpeechStarted(operation, now);
            }
            return;
          }
          _speechOnsetSamples = 0;
          if (!requiresSustainedOnset) {
            _noiseFloorDb = db;
            return;
          }
          _noiseFloorSamples.add(db);
          if (_noiseFloorSamples.length >= _vadCalibrationSampleTarget) {
            final ordered = List<double>.of(_noiseFloorSamples)..sort();
            _noiseFloorDb = ordered[ordered.length ~/ 2];
          }
          return;
        }
        // `record` no entrega la misma escala absoluta en todos los Android.
        // En el Pixel físico el ambiente ronda -23 dB (por encima del antiguo
        // onset -30) y la voz sube hasta ~0. Calibramos el fondo al abrir el
        // recorder y exigimos una subida relativa clara y sostenida. El
        // fallback de -8 dB cubre al usuario que empieza antes de calibrar.
        final clearsAbsoluteFloor =
            speechOnsetDb == null || db >= speechOnsetDb!;
        if (db >= -8 || (clearsAbsoluteFloor && db - noiseFloor >= 8)) {
          if (!requiresSustainedOnset ||
              ++_speechOnsetSamples >= _vadOnsetSampleTarget) {
            _markSpeechStarted(operation, now);
          }
          return;
        }
        _speechOnsetSamples = 0;
        // Sigue lentamente una habitación que se vuelve más ruidosa, pero
        // baja rápido si aparece una muestra más limpia. Así una subida de
        // voz no arrastra el baseline antes de poder detectarla.
        final weight = db < noiseFloor ? 0.35 : 0.05;
        _noiseFloorDb = noiseFloor + ((db - noiseFloor) * weight);
        return;
      }
      final releaseDb = (_noiseFloorDb ?? silenceThresholdDb) + 8;
      if (db > releaseDb && db >= silenceThresholdDb) {
        operation.latencyTurn?.observeSpeechAboveThreshold();
      }
      if (!vadEnabled) {
        // Desactivar el corte por silencio no desactiva el endpoint idle de la
        // conversación. Seguimos detectando solo el primer onset para cancelar
        // sus 12 s; después manda el usuario con Stop.
        return;
      }
      if (_continuous) {
        // Dictado continuo: las pausas NO cierran el turno. Manda el usuario
        // (botón parar) o el tope de seguridad. Así el micro no desaparece a
        // mitad de frase ni reabre/recorta captando colas de ruido.
        return;
      }
      if (db <= releaseDb || db < silenceThresholdDb) {
        // Volver cerca del baseline cuenta como silencio sostenido. La banda
        // relativa de 8 dB absorbe la variación real del ruido del Pixel
        // (-25,7 al calibrar; -20 a -23 después de hablar) sin acercarse a los
        // picos de voz medidos (-12 a -7,6 dB).
        if (_heardSpeech) {
          _silenceSince ??= now;
          if (now.difference(_silenceSince!) >= silenceTimeout) {
            _autoStop();
          }
        }
      } else {
        // Sigue habiendo energía claramente por encima del ruido de fondo.
        _silenceSince = null;
      }
    }, onError: (_) {});
  }

  /// Auto-parada por VAD: avisa a la UI solo cuando realmente hubo habla.
  void _autoStop({bool notifySpeechEnd = true}) {
    if (_stopping) return;
    _cancelIdleSilenceTimer();
    _stopping = true;
    _discardCurrentAutomaticStop =
        discardAutomaticTurnWithoutSpeechOnset && !_continuous && !_heardSpeech;
    if (notifySpeechEnd) {
      _operation?.latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
      _onSpeechEnd?.call();
    }
    unawaited(stop());
  }

  void _deleteAudioFile(String? path) {
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (error) {
      debugPrint('[stt] temporary WAV cleanup failed (${error.runtimeType})');
    }
    if (_audioPath == path) _audioPath = null;
  }

  @override
  Future<void> stop() {
    _cancelIdleSilenceTimer();
    final operation = _operation;
    final controller = operation?.controller ?? _controller;
    final wasStarted = operation?.started ?? false;
    final discardAutomaticStop = _discardCurrentAutomaticStop;
    final latencyTurn = operation?.latencyTurn;
    if (wasStarted) {
      latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
    }
    if (operation != null) operation.cancelled = true;
    _operation = null;
    _generation++;
    _controller = null;
    final previousStop = _stopTail;
    final result = () async {
      await previousStop;
      await _stopOperation(
        controller,
        wasStarted: wasStarted,
        discardAutomaticStop: discardAutomaticStop,
        latencyTurn: latencyTurn,
      );
    }();
    _stopTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _stopOperation(
    StreamController<SttResult>? controller, {
    required bool wasStarted,
    required bool discardAutomaticStop,
    required VoiceLatencyTurn? latencyTurn,
  }) async {
    await _ampSub?.cancel();
    _ampSub = null;
    onLevel?.call(0);
    if (controller == null || controller.isClosed) {
      String? path;
      try {
        path = await _runtime.stop();
      } catch (_) {}
      _deleteAudioFile(path ?? _audioPath);
      return;
    }
    if (!wasStarted) {
      unawaited(controller.close());
      String? path;
      try {
        path = await _runtime.stop();
      } catch (_) {}
      _deleteAudioFile(path ?? _audioPath);
      return;
    }
    String? path;
    try {
      path = await _runtime.stop() ?? _audioPath;
      if (discardAutomaticStop) {
        if (!controller.isClosed) await controller.close();
        return;
      }
      if (_disposed || _operation != null) {
        if (!controller.isClosed) await controller.close();
        return;
      }
      // Si no llegó a grabarse nada (toque muy rápido), cerramos el stream con
      // un final vacío en vez de dejar el turno colgado para siempre.
      if (path == null || !File(path).existsSync()) {
        controller.add(const SttResult('', true));
        unawaited(controller.close());
        return;
      }
      // Aceleramos la transcripción: (1) sin marcas de tiempo (no las usamos en
      // dictado y calcularlas es trabajo extra), (2) todos los núcleos del
      // dispositivo. Y un TIMEOUT de seguridad: si el modelo se atasca (típico
      // con `base` en CPU floja), fallamos con un error claro en vez de dejar la
      // UI colgada para siempre en "transcribiendo".
      final budget = maxDuration + const Duration(seconds: 45);
      latencyTurn?.mark(VoiceLatencyPoint.sttStarted);
      final text = await _runtime
          .transcribe(
            model: model,
            audioPath: path,
            lang: lang,
            threads: _threads,
          )
          .timeout(budget);
      if (!_disposed && _operation == null && !controller.isClosed) {
        latencyTurn?.mark(VoiceLatencyPoint.sttFinal);
        controller.add(SttResult(text, true));
      }
      await controller.close();
    } catch (_) {
      if (!controller.isClosed) {
        controller.addError(Exception('Transcription failed.'));
        await controller.close();
      }
    } finally {
      _deleteAudioFile(path ?? _audioPath);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    _cancelIdleSilenceTimer();
    final operation = _operation;
    final wasStarted = operation?.started ?? false;
    _operation = null;
    _generation++;
    if (operation != null) {
      operation.cancelled = true;
      if (!operation.controller.isClosed) {
        unawaited(operation.controller.close());
      }
    }
    _disposeFuture = () async {
      await _stopTail;
      await _startupTail;
      if (wasStarted) {
        String? path;
        try {
          path = await _runtime.stop();
        } catch (error) {
          debugPrint('[stt] recorder cleanup failed (${error.runtimeType})');
        } finally {
          _deleteAudioFile(path ?? _audioPath);
        }
      }
      await _ampSub?.cancel();
      _ampSub = null;
      final controller = _controller;
      _controller = null;
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
      await _runtime.dispose();
    }();
    return _disposeFuture!;
  }
}
