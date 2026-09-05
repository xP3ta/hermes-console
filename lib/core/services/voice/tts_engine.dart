// Motores de síntesis de voz (texto → voz).
//   • DeviceTtsEngine: flutter_tts (voz del sistema, on-device, privado).
//   • OnDeviceNeuralTtsEngine: sherpa-onnx + modelo Piper (voz neuronal local,
//     privada, sin nube ni clave).
//   • ElevenLabsTtsEngine: API HTTP de ElevenLabs (voz neuronal, nube, tu key).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

import '../../utils/transport_privacy.dart';
import 'package:path_provider/path_provider.dart';

import 'neural_tts_worker.dart';

abstract class TtsEngine {
  /// Lee [text] en voz alta. Lanza con mensaje claro si no se pudo.
  Future<void> speak(String text);

  /// Detiene la reproducción.
  Future<void> stop();

  Future<void> dispose();
}

/// Capacidad opcional (spec 048/US2-US3): motores cuyo arranque o primera
/// síntesis es caro pueden precalentarse durante esperas muertas (la espera
/// de red del agente, la reproducción de la frase anterior). `prewarm()` sin
/// texto prepara el motor; con texto deja además la PRIMERA frase sintetizada
/// en caché. Nunca reproduce audio y es best-effort: sus errores no deben
/// propagarse al pipeline de habla.
abstract class PrewarmableTts {
  Future<void> prewarm([String? text]);
}

class _TtsOperation {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Identidad cancelable de una única lectura. Empezar otra lectura invalida la
/// anterior; `stop` y `dispose` despiertan además cualquier espera de playback.
class _TtsOperationGate {
  _TtsOperation? _active;
  bool _disposed = false;

  _TtsOperation begin() {
    _active?.cancel();
    final operation = _TtsOperation();
    if (_disposed) {
      operation.cancel();
    } else {
      _active = operation;
    }
    return operation;
  }

  bool isCurrent(_TtsOperation operation) =>
      !_disposed && identical(_active, operation);

  bool get hasActive => !_disposed && _active != null;

  void finish(_TtsOperation operation) {
    if (identical(_active, operation)) _active = null;
  }

  void cancel() {
    _active?.cancel();
    _active = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}

/// Reproduce y espera un completion sin dejar una suscripción antigua viva si
/// gana stop/dispose/timeout. Devuelve false cuando la operación fue cancelada.
Future<_TtsPlaybackOutcome> _playAndWait({
  required TtsAudioPlayback playback,
  required _TtsOperationGate operations,
  required _TtsOperation operation,
  required Future<void> Function() play,
  required Duration timeout,
}) async {
  if (!operations.isCurrent(operation)) return _TtsPlaybackOutcome.cancelled;
  final outcome = Completer<_TtsPlaybackOutcome>();
  Object? completionError;
  StackTrace? completionStack;
  Timer? safetyTimer;
  late final StreamSubscription<void> subscription;
  subscription = playback.onComplete.listen(
    (_) {
      if (!outcome.isCompleted) {
        outcome.complete(_TtsPlaybackOutcome.completed);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      completionError = error;
      completionStack = stackTrace;
      if (!outcome.isCompleted) outcome.complete(_TtsPlaybackOutcome.failed);
    },
  );
  try {
    Object? playError;
    StackTrace? playStack;
    final playSettled = Future<void>.sync(play).then<bool>(
      (_) => true,
      onError: (Object error, StackTrace stackTrace) {
        playError = error;
        playStack = stackTrace;
        return true;
      },
    );
    final cancelledWhileStarting = await Future.any<bool>([
      playSettled.then((_) => false),
      operation.cancelled.then((_) => true),
    ]);
    if (cancelledWhileStarting) {
      // El plugin puede terminar `play` más tarde; observar ese Future evita un
      // error asíncrono suelto, pero nunca vuelve a unirlo a esta operación.
      playSettled.ignore();
      return _TtsPlaybackOutcome.cancelled;
    }
    if (playError != null) {
      Error.throwWithStackTrace(playError!, playStack ?? StackTrace.current);
    }
    if (!operations.isCurrent(operation)) {
      return _TtsPlaybackOutcome.cancelled;
    }
    safetyTimer = Timer(timeout, () {
      if (!outcome.isCompleted) outcome.complete(_TtsPlaybackOutcome.timedOut);
    });
    operation.cancelled.then((_) {
      if (!outcome.isCompleted) outcome.complete(_TtsPlaybackOutcome.cancelled);
    });
    final result = await outcome.future;
    if (result == _TtsPlaybackOutcome.failed) {
      Error.throwWithStackTrace(
        completionError!,
        completionStack ?? StackTrace.current,
      );
    }
    return operations.isCurrent(operation)
        ? result
        : _TtsPlaybackOutcome.cancelled;
  } finally {
    safetyTimer?.cancel();
    await subscription.cancel();
  }
}

enum _TtsPlaybackOutcome { completed, cancelled, timedOut, failed }

Future<void> _retireTtsPlayback(TtsAudioPlayback playback) async {
  try {
    await playback.stop().timeout(const Duration(seconds: 2));
  } catch (error) {
    debugPrint('[hermes-tts] no se pudo detener el player retirado: $error');
  }
  try {
    await playback.dispose().timeout(const Duration(seconds: 2));
  } catch (error) {
    debugPrint('[hermes-tts] no se pudo liberar el player retirado: $error');
  }
}

/// Frontera mínima de reproducción compartida por los motores TTS que producen
/// audio. Permite controlar `play`, `stop` y completion en tests sin depender
/// del plugin nativo.
abstract interface class TtsAudioPlayback {
  Stream<void> get onComplete;

  Future<void> playBytes(Uint8List bytes, {required String mimeType});

  Future<void> playFile(String path);

  Future<void> stop();

  Future<void> dispose();
}

/// Crea un reproductor independiente. Cada invocación debe devolver una
/// instancia nueva; los motores lo usan para aislar operaciones canceladas o
/// vencidas. Si se inyecta [TtsAudioPlayback], esta factory también es
/// obligatoria: nunca se cae silenciosamente al plugin nativo durante tests.
typedef TtsAudioPlaybackFactory = TtsAudioPlayback Function();

TtsAudioPlaybackFactory _resolveTtsPlaybackFactory(
  TtsAudioPlayback? playback,
  TtsAudioPlaybackFactory? playbackFactory,
) {
  if (playback != null && playbackFactory == null) {
    throw ArgumentError(
      'playbackFactory is required when playback is injected; '
          'it must return a fresh player for cancellation and timeout recovery',
      'playbackFactory',
    );
  }
  return playbackFactory ?? _AudioPlayerTtsPlayback.new;
}

class _AudioPlayerTtsPlayback implements TtsAudioPlayback {
  final AudioPlayer _player;

  _AudioPlayerTtsPlayback([AudioPlayer? player])
    : _player = player ?? AudioPlayer();

  @override
  Stream<void> get onComplete => _player.onPlayerComplete.map((_) {});

  @override
  Future<void> playBytes(Uint8List bytes, {required String mimeType}) =>
      _player.play(BytesSource(bytes, mimeType: mimeType));

  @override
  Future<void> playFile(String path) => _player.play(DeviceFileSource(path));

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

/// Frontera del plugin TTS del sistema, inyectable para reproducir carreras de
/// inicialización y parada sin un servicio Android real.
abstract interface class DeviceTtsPlatform {
  Future<dynamic> setEngine(String engine);

  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion);

  Future<dynamic> getLanguages();

  Future<dynamic> setLanguage(String language);

  Future<dynamic> speak(String text);

  Future<dynamic> stop();
}

class _FlutterDeviceTtsPlatform implements DeviceTtsPlatform {
  final FlutterTts _tts;

  _FlutterDeviceTtsPlatform([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  @override
  Future<dynamic> setEngine(String engine) => _tts.setEngine(engine);

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) =>
      _tts.awaitSpeakCompletion(awaitCompletion);

  @override
  Future<dynamic> getLanguages() async => _tts.getLanguages;

  @override
  Future<dynamic> setLanguage(String language) => _tts.setLanguage(language);

  @override
  Future<dynamic> speak(String text) => _tts.speak(text);

  @override
  Future<dynamic> stop() => _tts.stop();
}

enum TtsUserError {
  invalidKokoroAddress,
  invalidKokoroPort,
  kokoroUnavailable,
  kokoroNoVoices,
  invalidAudio,
  invalidCustomConfiguration,
  customResponseMissingAudio,
  customHttpFailure,
}

/// Error TTS estable que la UI traduce mediante ARB.
///
/// Extiende [FormatException] para conservar compatibilidad con consumidores
/// que ya distinguen respuestas/formato inválidos, sin acoplar el servicio a un
/// idioma concreto.
class TtsUserException extends FormatException {
  final TtsUserError code;
  final int? statusCode;

  const TtsUserException(this.code, {this.statusCode})
    : super('tts_user_error');
}

/// Listas de preferencia de voces del sistema por idioma de voz efectivo
/// (spec 031). La de 'es' y su fallback DEBEN mantenerse byte a byte como los
/// históricos: un test los ancla (regresión cero en español). Idioma
/// desconocido cae a los de 'es'.
const Map<String, List<String>> kDeviceTtsLangPrefs = {
  'es': ['es-ES', 'es-US', 'es-MX', 'es-419', 'es-CO', 'es-AR'],
  'en': ['en-US', 'en-GB', 'en-AU', 'en-IN'],
};

/// Fallback de [DeviceTtsEngine] cuando el dispositivo no lista idiomas o no
/// tiene ninguno del idioma efectivo (el plugin cae a la voz por defecto si
/// el idioma pedido no existe).
const Map<String, String> kDeviceTtsFallback = {'es': 'es-ES', 'en': 'en-US'};

/// Voz del sistema (on-device). Privada y gratuita.
class DeviceTtsEngine implements TtsEngine {
  /// Idioma de voz efectivo ('es'|'en') con el que se elige la voz (spec 031).
  /// Inmutable por instancia: VoiceService recicla el motor si el idioma de la
  /// app cambia (contrato I3).
  final String lang;

  DeviceTtsEngine({this.lang = 'es', DeviceTtsPlatform? platform})
    : _tts = platform ?? _FlutterDeviceTtsPlatform();

  final DeviceTtsPlatform _tts;
  final _operations = _TtsOperationGate();
  bool _init = false;
  Future<void>? _initializing;

  Future<void> _initialize() async {
    if (_init) return;
    // Android puede listar motores instalados pero no tener ninguno elegido
    // como predeterminado (GrapheneOS recién configurado). En ese estado el
    // constructor nativo falla con status -1. Seleccionar el motor descubierto
    // reinicializa TextToSpeech contra un servicio concreto y recuperable.
    if (Platform.isAndroid) {
      final engine = await systemTtsEngine();
      if (engine != null) await _tts.setEngine(engine);
    }
    await _tts.awaitSpeakCompletion(true);
    // Elige la mejor voz DISPONIBLE del idioma efectivo; si no hay ninguna,
    // deja la voz por defecto del sistema. Forzar un locale concreto fallaba
    // en móviles que solo tienen otra variante (es-US/es-MX) — mismo problema
    // que tenía el STT con el locale hardcodeado.
    try {
      final raw = await _tts.getLanguages();
      final langs = (raw is List)
          ? raw.map((e) => e.toString()).toList()
          : <String>[];
      String? pick;
      for (final p in kDeviceTtsLangPrefs[lang] ?? kDeviceTtsLangPrefs['es']!) {
        if (langs.contains(p)) {
          pick = p;
          break;
        }
      }
      pick ??= langs
          .where((l) => l.toLowerCase().startsWith(lang))
          .cast<String?>()
          .firstWhere((_) => true, orElse: () => null);
      // Si no hay lista (algunas ROMs) o no hay voz del idioma, intenta el
      // fallback igual: el plugin cae a la voz por defecto si no existe.
      await _tts.setLanguage(pick ?? kDeviceTtsFallback[lang] ?? 'es-ES');
    } catch (e) {
      debugPrint('[hermes-tts] excepción silenciada (se ignora sin más): $e');
    }
    _init = true;
  }

  Future<void> _ensure() {
    if (_init) return Future.value();
    final pending = _initializing;
    if (pending != null) return pending;
    late final Future<void> initializing;
    initializing = _initialize().whenComplete(() {
      if (identical(_initializing, initializing)) _initializing = null;
    });
    _initializing = initializing;
    return initializing;
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    final operation = _operations.begin();
    try {
      await _ensure();
      if (!_operations.isCurrent(operation)) return;
      await _tts.stop();
      if (!_operations.isCurrent(operation)) return;
      await _tts.speak(text);
    } catch (_) {
      if (!_operations.isCurrent(operation)) return;
      rethrow;
    } finally {
      _operations.finish(operation);
    }
  }

  @override
  Future<void> stop() {
    _operations.cancel();
    return _tts.stop();
  }

  @override
  Future<void> dispose() {
    _operations.dispose();
    return _tts.stop();
  }
}

/// Motor de voz que NO hace nada (sin sonido y sin error). Se usa como sustituto
/// del TTS del sistema cuando NO hay motor TTS instalado (p.ej. GrapheneOS sin
/// servicios de Google). En esos móviles, instanciar y usar flutter_tts provoca
/// una RECURSIÓN INFINITA en `android.speech.tts.TextToSpeech` (init falla →
/// reintenta → init falla…) que revienta la pila con un StackOverflow en el hilo
/// principal de Android y TIRA LA APP — y NO se puede capturar desde Dart. Un
/// fallback mudo es infinitamente mejor que un crash.
class SilentTtsEngine implements TtsEngine {
  @override
  Future<void> speak(String text) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

String? _systemTtsEngineCache;
Future<String?>? _systemTtsDiscoveryInFlight;

@visibleForTesting
String? selectSystemTtsEngine(
  Iterable<String> installed,
  String? defaultEngine,
) {
  final engines = installed
      .map((engine) => engine.trim())
      .where((engine) => engine.isNotEmpty)
      .toList();
  if (engines.isEmpty) return null;
  final preferred = defaultEngine?.trim() ?? '';
  return engines.contains(preferred) ? preferred : engines.first;
}

/// Motor TTS utilizable, prefiriendo el predeterminado del sistema cuando está
/// configurado y cayendo al primero instalado cuando Android devuelve `null`.
Future<String?> systemTtsEngine() async {
  final cached = _systemTtsEngineCache;
  if (cached != null) return cached;
  final pending = _systemTtsDiscoveryInFlight;
  if (pending != null) return pending;

  Future<String?> discover() async {
    final tts = FlutterTts();
    try {
      final raw = await tts.getEngines;
      final engines = raw is List
          ? raw
                .map((engine) => engine.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList()
          : <String>[];
      String? defaultEngine;
      if (Platform.isAndroid && engines.isNotEmpty) {
        defaultEngine = (await tts.getDefaultEngine)?.toString();
      }
      final discovered = selectSystemTtsEngine(engines, defaultEngine);
      if (discovered != null) _systemTtsEngineCache = discovered;
      return discovered;
    } catch (e) {
      debugPrint('[hermes-tts] no se pudo descubrir un motor del sistema: $e');
      return null;
    }
  }

  late final Future<String?> discovery;
  discovery = discover().whenComplete(() {
    if (identical(_systemTtsDiscoveryInFlight, discovery)) {
      _systemTtsDiscoveryInFlight = null;
    }
  });
  _systemTtsDiscoveryInFlight = discovery;
  return discovery;
}

@visibleForTesting
void resetSystemTtsDiscoveryForTesting() {
  _systemTtsEngineCache = null;
  _systemTtsDiscoveryInFlight = null;
}

/// ¿Hay un motor TTS del sistema instalado? `getEngines` es SEGURO: lee la lista
/// de motores del PackageManager y NO inicializa un TextToSpeech nuevo (no
/// dispara la recursión). En móviles sin TTS (GrapheneOS) devuelve lista vacía.
/// Los aciertos se cachean; una ausencia se vuelve a consultar para detectar un
/// motor instalado o activado mientras la app sigue abierta.
Future<bool> systemTtsAvailable() async {
  return await systemTtsEngine() != null;
}

/// Devuelve el TTS del sistema si hay motor instalado, o un motor MUDO si no lo
/// hay (evita el crash de flutter_tts). Único punto por el que debe crearse el
/// TTS del sistema en la app. [lang] es el idioma de voz efectivo (spec 031).
Future<TtsEngine> systemTtsOrSilent({String lang = 'es'}) async =>
    await systemTtsAvailable()
    ? DeviceTtsEngine(lang: lang)
    : SilentTtsEngine();

@visibleForTesting
class NeuralTtsAudio {
  final Float32List samples;
  final int sampleRate;
  final String? wavePath;
  final int sampleCount;
  final bool audible;

  NeuralTtsAudio({
    required this.samples,
    required this.sampleRate,
    this.wavePath,
    int? sampleCount,
    bool? audible,
  }) : sampleCount = sampleCount ?? samples.length,
       audible = audible ?? OnDeviceNeuralTtsEngine._hasAudibleSignal(samples);
}

typedef NeuralTtsSynthesizer =
    Future<NeuralTtsAudio> Function(String text, double speed);
typedef NeuralTtsWaveWriter =
    Future<String?> Function(NeuralTtsAudio audio, int sequence);

/// Voz neuronal **on-device** (sherpa-onnx + modelo Piper/VITS). Privada: la
/// síntesis ocurre 100% en el móvil, sin nube ni clave. Requiere un modelo ya
/// descargado (ver [TtsModelManager]). Genera audio por frases y lo reproduce en
/// secuencia para que cada bloque sea corto y se pueda cortar.
/// POST autenticado a `/api/audio/speak` del Dashboard. Respuesta esperada:
/// `{"ok": true, "data_url": "data:<mime>;base64,…", "mime_type": "…"}`.
typedef HermesSpeakRequest = Future<Map<String, dynamic>> Function(String text);

class _HermesPreparedAudio {
  final Uint8List bytes;
  final String mimeType;

  const _HermesPreparedAudio(this.bytes, this.mimeType);
}

/// TTS del modo nativo Desktop (spec 048/US5): la síntesis la hace la cadena
/// TTS del PROPIO servidor Hermes —las mismas voces que Desktop— y aquí solo
/// se decodifica el data URL y se reproduce. Sus errores se propagan tal cual
/// para que la cadena de fallback existente (`speakOrFallback`) hable la
/// locución con los motores locales.
class HermesServerTtsEngine implements TtsEngine, PrewarmableTts {
  HermesServerTtsEngine({
    required this.synthesize,
    TtsAudioPlayback? playback,
    TtsAudioPlaybackFactory? playbackFactory,
  }) : _player =
           playback ?? _resolveTtsPlaybackFactory(null, playbackFactory)(),
       _playbackFactory = _resolveTtsPlaybackFactory(playback, playbackFactory);

  final HermesSpeakRequest synthesize;
  TtsAudioPlayback _player;
  final TtsAudioPlaybackFactory _playbackFactory;
  final _operations = _TtsOperationGate();
  bool _disposed = false;
  // Dos lotes son suficientes para el pipeline N/N+1: el controlador puede
  // reservar N+1 inmediatamente después de encolar N, antes de que el drenador
  // asíncrono llegue a `speak(N)` y reclame su audio ya preparado. Una sola
  // entrada expulsaba N y duplicaba la petición Edge TTS en ese pequeño hueco.
  static const int _maxPreparedBatches = 2;
  final Map<String, Future<_HermesPreparedAudio>> _preparedAudio = {};

  static final RegExp _dataUrlPattern = RegExp(
    r'^data:([^;]+);base64,(.*)$',
    dotAll: true,
  );

  @override
  Future<void> speak(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    final replacesActivePlayback = _operations.hasActive;
    final operation = _operations.begin();
    try {
      if (replacesActivePlayback) await _rotatePlayback();
      if (!_operations.isCurrent(operation)) return;
      final playback = _player;
      await playback.stop();
      if (!_operations.isCurrent(operation)) return;

      _HermesPreparedAudio? audio;
      final prepared = _takePrepared(normalized);
      if (prepared != null) {
        Object? preparedError;
        final cancelled = await Future.any<bool>([
          prepared.then(
            (value) {
              audio = value;
              return false;
            },
            onError: (Object error, StackTrace _) {
              // La precarga es best-effort. Speak reintenta una vez por el
              // camino normal para que un fallo transitorio no fuerce fallback.
              preparedError = error;
              return false;
            },
          ),
          operation.cancelled.then((_) => true),
        ]);
        if (cancelled || !_operations.isCurrent(operation)) return;
        if (preparedError != null) audio = null;
      }

      if (audio == null) {
        Object? requestError;
        StackTrace? requestStack;
        final cancelled = await Future.any<bool>([
          _requestAudio(normalized).then(
            (value) {
              audio = value;
              return false;
            },
            onError: (Object error, StackTrace stackTrace) {
              requestError = error;
              requestStack = stackTrace;
              return false;
            },
          ),
          operation.cancelled.then((_) => true),
        ]);
        if (cancelled || !_operations.isCurrent(operation)) return;
        if (requestError != null) {
          Error.throwWithStackTrace(
            requestError!,
            requestStack ?? StackTrace.current,
          );
        }
      }
      final ready = audio!;
      final outcome = await _playAndWait(
        playback: playback,
        operations: _operations,
        operation: operation,
        play: () => playback.playBytes(ready.bytes, mimeType: ready.mimeType),
        // La duración real del audio comprimido no se conoce: tope generoso
        // proporcional al texto para detectar un reproductor colgado.
        timeout: Duration(
          milliseconds: (text.length * 200).clamp(15000, 180000),
        ),
      );
      if (outcome == _TtsPlaybackOutcome.timedOut &&
          _operations.isCurrent(operation)) {
        await _rotatePlayback();
      }
    } finally {
      _operations.finish(operation);
    }
  }

  @override
  Future<void> prewarm([String? text]) async {
    final normalized = text?.trim() ?? '';
    if (_disposed || normalized.isEmpty) return;
    var request = _preparedAudio[normalized];
    if (request == null) {
      request = _requestAudio(normalized);
      _preparedAudio[normalized] = request;
      while (_preparedAudio.length > _maxPreparedBatches) {
        _preparedAudio.remove(_preparedAudio.keys.first);
      }
    }
    try {
      await request;
    } catch (_) {
      if (identical(_preparedAudio[normalized], request)) {
        _preparedAudio.remove(normalized);
      }
      // Best-effort by contract: speak will use the normal fallback path.
    }
  }

  Future<_HermesPreparedAudio> _requestAudio(String text) async {
    final map = await synthesize(text);
    final raw = (map['data_url'] ?? '').toString().trim();
    final match = _dataUrlPattern.firstMatch(raw);
    if (map['ok'] != true || match == null) {
      final detail = map['detail'] ?? map['error'] ?? 'sin data_url';
      throw Exception('The server returned no audio ($detail).');
    }
    final mime = (map['mime_type'] ?? match.group(1) ?? 'audio/mpeg')
        .toString();
    final bytes = base64Decode(
      (match.group(2) ?? '').replaceAll(RegExp(r'\s+'), ''),
    );
    if (bytes.isEmpty) {
      throw Exception('The server returned empty audio.');
    }
    return _HermesPreparedAudio(bytes, mime);
  }

  Future<_HermesPreparedAudio>? _takePrepared(String text) {
    return _preparedAudio.remove(text);
  }

  void _clearPrepared() => _preparedAudio.clear();

  Future<void> _rotatePlayback() async {
    final previous = _player;
    _player = _playbackFactory();
    await _retireTtsPlayback(previous);
  }

  @override
  Future<void> stop() async {
    _clearPrepared();
    final retiresPlayback = _operations.hasActive;
    _operations.cancel();
    if (retiresPlayback) {
      await _rotatePlayback();
    } else {
      await _player.stop();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _clearPrepared();
    _operations.dispose();
    await _retireTtsPlayback(_player);
  }
}

class OnDeviceNeuralTtsEngine implements TtsEngine, PrewarmableTts {
  final String modelPath;
  final String tokensPath;
  final String dataDirPath;
  final double speed;

  OnDeviceNeuralTtsEngine({
    required this.modelPath,
    required this.tokensPath,
    required this.dataDirPath,
    this.speed = 1.0,
    TtsAudioPlayback? playback,
    TtsAudioPlaybackFactory? playbackFactory,
    this.debugSynthesizer,
    this.debugWaveWriter,
    this.debugWorkerFactory,
  }) : _player =
           playback ?? _resolveTtsPlaybackFactory(null, playbackFactory)(),
       _playbackFactory = _resolveTtsPlaybackFactory(playback, playbackFactory),
       assert(
         debugSynthesizer == null || debugWaveWriter != null,
         'a debug synthesizer requires a debug wave writer',
       );

  TtsAudioPlayback _player;
  final TtsAudioPlaybackFactory _playbackFactory;
  @visibleForTesting
  final NeuralTtsSynthesizer? debugSynthesizer;
  @visibleForTesting
  final NeuralTtsWaveWriter? debugWaveWriter;
  @visibleForTesting
  final NeuralTtsWorkerFactory? debugWorkerFactory;
  NeuralTtsWorker? _worker;
  Future<NeuralTtsWorker>? _workerStarting;
  final _operations = _TtsOperationGate();
  int _wavSeq = 0;
  String? _cachedSynthesisKey;
  Future<NeuralTtsAudio>? _cachedSynthesis;
  bool _disposed = false;

  Future<NeuralTtsWorker> _ensureWorker() async {
    if (_disposed) {
      throw StateError('On-device TTS engine is already disposed.');
    }
    if (_worker != null) return _worker!;
    if (_workerStarting != null) return _workerStarting!;
    if (debugWorkerFactory == null &&
        (!File(modelPath).existsSync() || !File(tokensPath).existsSync())) {
      throw Exception('Voice model is not downloaded.');
    }
    final outputDir = debugWorkerFactory == null
        ? (await getTemporaryDirectory()).path
        : Directory.systemTemp.path;
    if (_disposed) {
      throw StateError('On-device TTS engine is already disposed.');
    }
    final config = NeuralTtsWorkerConfig(
      modelPath: modelPath,
      tokensPath: tokensPath,
      dataDirPath: dataDirPath,
      outputDir: outputDir,
    );
    final starting = (debugWorkerFactory ?? IsolateNeuralTtsWorker.start)(
      config,
    );
    _workerStarting = starting;
    try {
      final worker = await starting;
      if (_disposed) {
        await worker.dispose();
        throw StateError('On-device TTS engine was disposed while starting.');
      }
      return _worker = worker;
    } finally {
      _workerStarting = null;
    }
  }

  Future<NeuralTtsAudio> _synthesizeSentence(String sentence) async {
    final injected = debugSynthesizer;
    if (injected != null) return injected(sentence, speed);
    final worker = await _ensureWorker();
    final audio = await worker.synthesize(sentence, speed);
    return NeuralTtsAudio(
      samples: audio.samples,
      sampleRate: audio.sampleRate,
      wavePath: audio.wavePath,
      sampleCount: audio.sampleCount,
      audible: audio.audible,
    );
  }

  Future<NeuralTtsAudio> _cachedSynthesize(String sentence) {
    final key = '$speed\u0000$sentence';
    if (_cachedSynthesisKey == key && _cachedSynthesis != null) {
      return _cachedSynthesis!;
    }
    final synthesis = _synthesizeSentence(sentence);
    _cachedSynthesisKey = key;
    _cachedSynthesis = synthesis;
    return synthesis;
  }

  Future<NeuralTtsAudio?> _synthesizeCancellable(
    String sentence,
    _TtsOperation operation,
  ) async {
    final synthesis = _cachedSynthesize(sentence);
    Object? synthesisError;
    StackTrace? synthesisStack;
    final cancelled = await Future.any<bool>([
      synthesis.then(
        (_) => false,
        onError: (Object error, StackTrace stackTrace) {
          synthesisError = error;
          synthesisStack = stackTrace;
          return false;
        },
      ),
      operation.cancelled.then((_) => true),
    ]);
    if (cancelled) {
      synthesis.ignore();
      return null;
    }
    if (synthesisError != null) {
      Error.throwWithStackTrace(
        synthesisError!,
        synthesisStack ?? StackTrace.current,
      );
    }
    return synthesis;
  }

  void _clearCachedSynthesis(String sentence) {
    final key = '$speed\u0000$sentence';
    if (_cachedSynthesisKey != key) return;
    _cachedSynthesisKey = null;
    _cachedSynthesis = null;
  }

  Future<String?> _writeWave(NeuralTtsAudio audio) async {
    final sequence = _wavSeq++;
    final injected = debugWaveWriter;
    if (injected != null) return injected(audio, sequence);
    return audio.wavePath;
  }

  /// Precalienta el motor sin reproducir nada (spec 048/US2-US3): arranca el
  /// worker (isolate + bindings + modelo, el coste real medido en la línea
  /// base) y, si llega [text], deja su primera frase sintetizada en el caché
  /// que `speak()` consumirá. Best-effort: tras dispose es un no-op y un fallo
  /// de síntesis desaloja el caché para no envenenar el speak posterior.
  @override
  Future<void> prewarm([String? text]) async {
    if (_disposed) return;
    try {
      await _ensureWorker();
      if (text == null) return;
      final sentences = _sentences(text);
      if (sentences.isEmpty || _disposed) return;
      final sentence = sentences.first;
      try {
        await _cachedSynthesize(sentence);
      } catch (_) {
        _clearCachedSynthesis(sentence);
      }
    } catch (e) {
      debugPrint('[hermes-tts] prewarm silenciado: $e');
    }
  }

  /// Trocea por frases para que cada generación (síncrona) sea breve y se pueda
  /// interrumpir entre bloques. Corte solo en fin de frase real (no en `;:,` ni
  /// en las aperturas `¿¡`), para no fragmentar la prosodia.
  static List<String> _sentences(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return const [];
    final parts = clean.split(RegExp(r'(?<=[.!?…\n])\s+'));
    final out = <String>[];
    final buf = StringBuffer();
    for (final p in parts) {
      if (buf.isNotEmpty && buf.length + p.length > 240) {
        out.add(buf.toString());
        buf.clear();
      }
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(p);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    final replacesActivePlayback = _operations.hasActive;
    final operation = _operations.begin();
    var producedAudio = false;
    try {
      if (replacesActivePlayback) await _rotatePlayback();
      if (!_operations.isCurrent(operation)) return;
      var playback = _player;
      await playback.stop();
      if (!_operations.isCurrent(operation)) return;
      final sentences = _sentences(text);
      Future<NeuralTtsAudio?>? prefetched;
      for (var index = 0; index < sentences.length; index++) {
        final sentence = sentences[index];
        if (!_operations.isCurrent(operation)) break;
        final pending = prefetched;
        prefetched = null;
        final audio =
            await (pending ?? _synthesizeCancellable(sentence, operation));
        if (audio == null) break;
        if (!_operations.isCurrent(operation)) break;
        // Salta si no hay muestras O si son SILENCIO (pico ~0): algunas voces con
        // espeak-ng-data incompleto generan un búfer NO vacío pero mudo. Tratarlo
        // como "sin audio" hace que, si NINGUNA frase suena, caigamos al TTS del
        // sistema (throw de abajo) en vez de reproducir silencio.
        if (!audio.audible) continue;
        final path = await _writeWave(audio);
        if (!_operations.isCurrent(operation)) {
          if (path != null) _deleteWave(path);
          break;
        }
        if (path == null) continue;
        if (index + 1 < sentences.length && _operations.isCurrent(operation)) {
          // El worker queda libre en cuanto termina la frase actual. Prepara
          // la siguiente mientras el reproductor está hablando para evitar el
          // hueco síntesis → reproducción que se percibía como voz cortada.
          final next = _synthesizeCancellable(sentences[index + 1], operation);
          next.ignore();
          prefetched = next;
        }
        final ms = audio.sampleRate > 0
            ? (audio.sampleCount * 1000 / audio.sampleRate).ceil()
            : 8000;
        final playbackOutcome = await _playAndWait(
          playback: playback,
          operations: _operations,
          operation: operation,
          play: () => playback.playFile(path),
          timeout: Duration(milliseconds: ms + 400),
        );
        _deleteWave(path);
        _clearCachedSynthesis(sentence);
        if (playbackOutcome == _TtsPlaybackOutcome.cancelled) break;
        producedAudio = true;
        if (playbackOutcome == _TtsPlaybackOutcome.timedOut) {
          if (!_operations.isCurrent(operation)) break;
          await _rotatePlayback();
          if (!_operations.isCurrent(operation)) break;
          playback = _player;
        }
      }
      // La voz on-device está cargada pero no sonó NADA con texto no vacío. Solo
      // una operación todavía vigente puede activar el fallback.
      if (_operations.isCurrent(operation) && !producedAudio) {
        debugPrint(
          '[hermes-tts] voz neural sin audio audible '
          '(modelo/espeak-ng-data incompleto) → fallback al TTS del sistema',
        );
        throw Exception(
          'On-device TTS produced no audio (voice model may be incomplete).',
        );
      }
    } catch (_) {
      if (!_operations.isCurrent(operation)) return;
      rethrow;
    } finally {
      _operations.finish(operation);
    }
  }

  void _deleteWave(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      debugPrint('[hermes-tts] excepción silenciada (se ignora sin más): $e');
    }
  }

  /// ¿Las muestras tienen señal audible (no son puro silencio)? Las muestras de
  /// sherpa son float en [-1, 1]; el habla real alcanza picos altos, así que un
  /// umbral mínimo distingue "mudo" de "voz". Sin esto, un búfer no vacío pero
  /// silencioso se daría por reproducido y nunca caería al TTS del sistema.
  static bool _hasAudibleSignal(List<double> samples) {
    for (final s in samples) {
      if (s > 0.003 || s < -0.003) return true;
    }
    return false;
  }

  @override
  Future<void> stop() async {
    final retiresPlayback = _operations.hasActive;
    _operations.cancel();
    if (retiresPlayback) {
      await _rotatePlayback();
    } else {
      await _player.stop();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _operations.dispose();
    await _retireTtsPlayback(_player);
    final cached = _cachedSynthesis;
    if (cached != null) {
      unawaited(
        cached.then<void>((audio) {
          final path = audio.wavePath;
          if (path != null) _deleteWave(path);
        }, onError: (Object _, StackTrace _) {}),
      );
    }
    _cachedSynthesis = null;
    _cachedSynthesisKey = null;
    final worker = _worker;
    _worker = null;
    if (worker != null) {
      await worker.dispose();
      return;
    }
    final starting = _workerStarting;
    if (starting != null) {
      // El puerto del isolate suele estar listo inmediatamente. Si un factory
      // inyectado se atasca, no bloqueamos la UI: el worker tardío se autolibera.
      try {
        final lateWorker = await starting.timeout(
          const Duration(milliseconds: 600),
        );
        await lateWorker.dispose();
      } on TimeoutException {
        unawaited(
          starting.then<void>(
            (lateWorker) => lateWorker.dispose(),
            onError: (Object _, StackTrace _) {},
          ),
        );
      } catch (_) {
        // El arranque ya falló: no queda un modelo que liberar.
      }
    }
  }

  Future<void> _rotatePlayback() async {
    final previous = _player;
    final replacement = _playbackFactory();
    if (identical(previous, replacement)) {
      throw ArgumentError('playbackFactory must return a fresh player');
    }
    _player = replacement;
    await _retireTtsPlayback(previous);
  }
}

/// Voz neuronal de ElevenLabs. Requiere API key (Keystore). Envía el texto a la
/// nube de ElevenLabs — opt-in, divulgado en Ajustes.
class ElevenLabsTtsEngine implements TtsEngine {
  final String apiKey;
  final String voiceId;
  final String modelId;
  final http.Client _http;
  TtsAudioPlayback _player;
  final TtsAudioPlaybackFactory _playbackFactory;
  final _operations = _TtsOperationGate();

  ElevenLabsTtsEngine({
    required this.apiKey,
    required this.voiceId,
    required this.modelId,
    http.Client? client,
    TtsAudioPlayback? playback,
    TtsAudioPlaybackFactory? playbackFactory,
  }) : _http = client ?? http.Client(),
       _player =
           playback ?? _resolveTtsPlaybackFactory(null, playbackFactory)(),
       _playbackFactory = _resolveTtsPlaybackFactory(playback, playbackFactory);

  /// ElevenLabs corta por longitud según el modelo; truncamos por seguridad.
  static const int _maxChars = 5000;

  /// Construye la petición (separado para poder testearlo).
  static ({Uri uri, Map<String, String> headers, String body}) buildRequest({
    required String apiKey,
    required String voiceId,
    required String text,
    required String modelId,
  }) {
    final clipped = text.length > _maxChars
        ? text.substring(0, _maxChars)
        : text;
    return (
      uri: Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$voiceId'),
      headers: {
        'xi-api-key': apiKey,
        'Content-Type': 'application/json',
        'Accept': 'audio/mpeg',
      },
      body: jsonEncode({'text': clipped, 'model_id': modelId}),
    );
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (apiKey.isEmpty) {
      throw Exception(
        'ElevenLabs key missing (configure it in Settings › Voice).',
      );
    }
    final replacesActivePlayback = _operations.hasActive;
    final operation = _operations.begin();
    try {
      if (replacesActivePlayback) await _rotatePlayback();
      if (!_operations.isCurrent(operation)) return;
      final playback = _player;
      await playback.stop();
      if (!_operations.isCurrent(operation)) return;
      final req = buildRequest(
        apiKey: apiKey,
        voiceId: voiceId,
        text: text,
        modelId: modelId,
      );
      final res = await _http
          .post(req.uri, headers: req.headers, body: req.body)
          .timeout(const Duration(seconds: 30));
      if (!_operations.isCurrent(operation)) return;
      if (res.statusCode == 401) {
        throw Exception('ElevenLabs rejected the key (401).');
      }
      if (res.statusCode == 429) {
        throw Exception('ElevenLabs quota exceeded (429).');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('ElevenLabs HTTP ${res.statusCode}.');
      }
      final playbackOutcome = await _playAndWait(
        playback: playback,
        operations: _operations,
        operation: operation,
        play: () => playback.playBytes(res.bodyBytes, mimeType: 'audio/mpeg'),
        timeout: const Duration(seconds: 30),
      );
      if (playbackOutcome == _TtsPlaybackOutcome.timedOut &&
          _operations.isCurrent(operation)) {
        await _rotatePlayback();
      }
    } catch (_) {
      if (!_operations.isCurrent(operation)) return;
      rethrow;
    } finally {
      _operations.finish(operation);
    }
  }

  @override
  Future<void> stop() async {
    final retiresPlayback = _operations.hasActive;
    _operations.cancel();
    if (retiresPlayback) {
      await _rotatePlayback();
    } else {
      await _player.stop();
    }
  }

  @override
  Future<void> dispose() async {
    _operations.dispose();
    await _retireTtsPlayback(_player);
    _http.close();
  }

  Future<void> _rotatePlayback() async {
    final previous = _player;
    final replacement = _playbackFactory();
    if (identical(previous, replacement)) {
      throw ArgumentError('playbackFactory must return a fresh player');
    }
    _player = replacement;
    await _retireTtsPlayback(previous);
  }
}

/// TTS por **streaming** con formato OpenAI (`POST {base}/audio/speech`). Una sola
/// implementación que sirve para:
///   • Servidor autoalojado (Kokoro-FastAPI en tu red): gratis, privado, el audio
///     no sale de la LAN/Tailscale. Voz `em_santa` (Papá Noel español), etc.
///   • Nube (OpenAI, Deepgram… con formato OpenAI) con tu propia key.
/// Solo cambia la URL base (y la key si la nube la pide). Trocea por frases y
/// reproduce cada una EN CUANTO llega su audio, así la "boca" arranca con la
/// primera frase mientras el modelo aún genera el resto → sensación fluida.
class KokoroTtsDiscovery {
  final String baseUrl;
  final List<String> voices;

  const KokoroTtsDiscovery({required this.baseUrl, required this.voices});
}

/// Asistente puro para convertir "dirección + puerto" en la API estable de
/// Kokoro-FastAPI y descubrir las voces que anuncia el propio servidor.
class KokoroTtsSetup {
  const KokoroTtsSetup._();

  static String normalizeBaseUrl({
    required String address,
    String port = '8880',
  }) {
    var raw = address.trim();
    if (raw.isEmpty) {
      throw const TtsUserException(TtsUserError.invalidKokoroAddress);
    }
    if (!raw.contains('://')) raw = 'http://$raw';
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty) {
      throw const TtsUserException(TtsUserError.invalidKokoroAddress);
    }
    if (parsed.scheme != 'http' && parsed.scheme != 'https') {
      throw const TtsUserException(TtsUserError.invalidKokoroAddress);
    }
    final typedPort = port.trim();
    final selectedPort = typedPort.isEmpty
        ? (parsed.hasPort ? parsed.port : 8880)
        : int.tryParse(typedPort);
    if (selectedPort == null || selectedPort < 1 || selectedPort > 65535) {
      throw const TtsUserException(TtsUserError.invalidKokoroPort);
    }
    final normalized = Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: selectedPort,
      path: '/v1',
    ).toString().replaceAll(RegExp(r'/+$'), '');
    try {
      return TransportPrivacy.requireAllowed(normalized);
    } on ArgumentError {
      throw const TtsUserException(TtsUserError.invalidKokoroAddress);
    }
  }

  static Future<KokoroTtsDiscovery> discover({
    required String address,
    String port = '8880',
    String apiKey = '',
    http.Client? client,
  }) async {
    final baseUrl = normalizeBaseUrl(address: address, port: port);
    final ownClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(
            Uri.parse('$baseUrl/audio/voices'),
            headers: {
              'Accept': 'application/json',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TtsUserException(
          TtsUserError.kokoroUnavailable,
          statusCode: response.statusCode,
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final rawVoices = decoded is Map<String, dynamic>
          ? decoded['voices']
          : null;
      if (rawVoices is! List) {
        throw const TtsUserException(TtsUserError.kokoroNoVoices);
      }
      final voices = <String>[];
      for (final item in rawVoices) {
        final id = switch (item) {
          String value => value.trim(),
          Map value => (value['id'] ?? '').toString().trim(),
          _ => '',
        };
        if (id.isNotEmpty && !voices.contains(id)) voices.add(id);
      }
      if (voices.isEmpty) {
        throw const TtsUserException(TtsUserError.kokoroNoVoices);
      }
      return KokoroTtsDiscovery(baseUrl: baseUrl, voices: voices);
    } finally {
      if (ownClient) httpClient.close();
    }
  }
}

class OpenAiStreamingTtsEngine implements TtsEngine {
  /// Base de la API, p.ej. `http://192.168.1.10:8880/v1` (Kokoro) o
  /// `https://api.openai.com/v1` (nube). Se le añade `/audio/speech`.
  final String baseUrl;

  /// Token Bearer. Vacío para un Kokoro local sin auth.
  final String apiKey;
  final String voice;
  final String model;

  /// Velocidad de habla (Kokoro/OpenAI: 0.25–4.0). Un pelín por debajo de 1.0
  /// hace la voz más pausada y natural —se oye que "respira" y marca las comas—
  /// en vez de leer de carrerilla. 1.0 = velocidad nominal.
  final double speed;
  final http.Client _http;
  TtsAudioPlayback _player;
  final TtsAudioPlaybackFactory _playbackFactory;
  final _operations = _TtsOperationGate();
  // Tras un stop() (pausa o corte manual) el AudioPlayer reutilizado puede dejar
  // de emitir `onPlayerComplete` o de sonar (estado degradado conocido del
  // plugin al encadenar stop/play). Marcamos para arrancar el SIGUIENTE turno
  // con un player fresco: es justo el caso "tras varias veces se queda hablando
  // sin sonido / ya no responde con voz". Entre frases del mismo turno se
  // reutiliza (gapless); solo se renueva cuando hubo un corte.
  bool _needFreshPlayer = false;

  OpenAiStreamingTtsEngine({
    required String baseUrl,
    required this.voice,
    required this.model,
    this.apiKey = '',
    this.speed = 0.9,
    http.Client? client,
    TtsAudioPlayback? playback,
    TtsAudioPlaybackFactory? playbackFactory,
  }) : baseUrl = TransportPrivacy.requireAllowed(baseUrl.trim()),
       _http = client ?? http.Client(),
       _playbackFactory = _resolveTtsPlaybackFactory(playback, playbackFactory),
       _player =
           playback ?? _resolveTtsPlaybackFactory(null, playbackFactory)();

  static const int _maxChars = 4000;

  /// Endpoint normalizado: base sin barra(s) final(es) + `/audio/speech`.
  Uri get endpoint {
    final b = TransportPrivacy.requireAllowed(
      baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
    );
    return Uri.parse('$b/audio/speech');
  }

  /// Trocea por frases para empezar a hablar antes y poder cortar entre bloques.
  /// Cada bloque es una petición independiente. Cortamos SOLO en fin de frase
  /// real (`. ! ? …` y saltos de línea): partir también en `;` `:` `,` —y peor,
  /// en las aperturas `¿` `¡`— fragmentaba el texto en trozos minúsculos con
  /// pausas en mitad de la idea, que es lo que hacía sonar la voz "trabada".
  /// Las frases cortas se fusionan hasta ~240 chars para no disparar una
  /// petición por cada cláusula breve (menos cortes = prosodia más natural).
  static List<String> _sentences(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return const [];
    final parts = clean.split(RegExp(r'(?<=[.!?…\n])\s+'));
    final out = <String>[];
    final buf = StringBuffer();
    for (final p in parts) {
      if (buf.isNotEmpty && buf.length + p.length > 240) {
        out.add(buf.toString());
        buf.clear();
      }
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(p);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// Cuerpo de la petición (separado para poder testearlo sin red).
  static ({Uri uri, Map<String, String> headers, String body}) buildRequest({
    required String baseUrl,
    required String voice,
    required String model,
    required String text,
    String apiKey = '',
    double speed = 1.0,
  }) {
    final clipped = text.length > _maxChars
        ? text.substring(0, _maxChars)
        : text;
    final b = TransportPrivacy.requireAllowed(
      baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
    );
    return (
      uri: Uri.parse('$b/audio/speech'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'audio/wav',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      },
      // WAV: lo soportan OpenAI, Kokoro-FastAPI y un shim propio (soundfile), sin
      // depender de un encoder mp3 en el servidor. En LAN/Tailscale el tamaño
      // extra es irrelevante; para nube con datos móviles se podría pasar a mp3.
      // `speed` lo respetan tanto OpenAI como Kokoro-FastAPI.
      body: jsonEncode({
        'model': model,
        'input': clipped,
        'voice': voice,
        'response_format': 'wav',
        'speed': speed,
      }),
    );
  }

  /// Duración real (ms) de un WAV PCM a partir de su cabecera. Recorre los
  /// sub-chunks (`fmt `/`data`) para sacar sampleRate, canales, bits y el tamaño
  /// de datos. Devuelve null si no parsea (no es WAV PCM o está truncado). Esto
  /// sustituye al timeout FIJO de 30 s por frase: con la duración real, cada
  /// frase avanza justo cuando su audio termina aunque `onPlayerComplete` se
  /// pierda (lo que ocurre al reutilizar el AudioPlayer con stop/play repetidos),
  /// evitando que la cola de voz se quede colgada en "hablando" sin sonido.
  static int? _wavDurationMs(Uint8List b) {
    if (b.length < 44) return null;
    bool tag(int o, String s) {
      if (o + s.length > b.length) return false;
      for (var i = 0; i < s.length; i++) {
        if (b[o + i] != s.codeUnitAt(i)) return false;
      }
      return true;
    }

    if (!tag(0, 'RIFF') || !tag(8, 'WAVE')) return null;
    int u16(int o) => b[o] | (b[o + 1] << 8);
    int u32(int o) =>
        b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
    var sampleRate = 0, channels = 0, bits = 0, dataSize = 0;
    var p = 12;
    while (p + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(p, p + 4));
      final sz = u32(p + 4);
      if (id == 'fmt ' && p + 8 + 16 <= b.length) {
        channels = u16(p + 8 + 2);
        sampleRate = u32(p + 8 + 4);
        bits = u16(p + 8 + 14);
      } else if (id == 'data') {
        final avail = b.length - (p + 8);
        dataSize = (sz <= 0 || sz > avail) ? avail : sz;
        break;
      }
      if (sz <= 0) break;
      p += 8 + sz + (sz & 1); // sub-chunks alineados a 2 bytes
    }
    if (sampleRate <= 0 || channels <= 0 || bits <= 0 || dataSize <= 0) {
      return null;
    }
    final bytesPerSec = sampleRate * channels * (bits ~/ 8);
    if (bytesPerSec <= 0) return null;
    return (dataSize * 1000 / bytesPerSec).ceil();
  }

  /// Genera el audio de UNA frase (sin reproducir). Separado para poder
  /// adelantar la siguiente petición mientras suena la actual.
  Future<Uint8List?> _synthesize(String sentence) async {
    final req = buildRequest(
      baseUrl: baseUrl,
      voice: voice,
      model: model,
      text: sentence,
      apiKey: apiKey,
      speed: speed,
    );
    final res = await _http
        .post(req.uri, headers: req.headers, body: req.body)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode == 401) {
      throw Exception('Streaming TTS rejected the key (401).');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Streaming TTS HTTP ${res.statusCode}.');
    }
    return res.bodyBytes.isEmpty ? null : res.bodyBytes;
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (baseUrl.trim().isEmpty) {
      throw Exception(
        'Streaming TTS URL missing (configure it in Settings › Voice).',
      );
    }
    final operation = _operations.begin();
    Future<Uint8List?>? next;
    try {
      await _freshPlayerIfNeeded();
      if (!_operations.isCurrent(operation)) return;
      var playback = _player;
      await playback.stop();
      if (!_operations.isCurrent(operation)) return;
      final sentences = _sentences(text);
      if (sentences.isEmpty) return;

      // Pipeline con prefetch de una frase: la generación siguiente avanza
      // mientras suena la actual, pero sigue perteneciendo a esta operación.
      next = _synthesize(sentences.first);
      for (var i = 0; i < sentences.length; i++) {
        Uint8List? audio;
        try {
          audio = await next;
        } catch (e) {
          if (!_operations.isCurrent(operation)) return;
          // La primera frase admite un único reintento transitorio.
          if (i == 0) {
            try {
              audio = await _synthesize(sentences.first);
              if (!_operations.isCurrent(operation)) return;
            } catch (e) {
              if (!_operations.isCurrent(operation)) return;
              debugPrint('[hermes-tts] excepción silenciada (se relanza): $e');
              rethrow;
            }
          } else {
            break;
          }
        }
        if (!_operations.isCurrent(operation)) break;
        if (i + 1 < sentences.length) {
          next = _synthesize(sentences[i + 1]);
        }
        if (audio == null) continue;
        await playback.stop();
        if (!_operations.isCurrent(operation)) break;
        final ms = _wavDurationMs(audio);
        final safety = ms != null
            ? Duration(milliseconds: ms + 400)
            : const Duration(seconds: 30);
        final playbackOutcome = await _playAndWait(
          playback: playback,
          operations: _operations,
          operation: operation,
          play: () => playback.playBytes(audio!, mimeType: 'audio/wav'),
          timeout: safety,
        );
        if (playbackOutcome == _TtsPlaybackOutcome.cancelled) break;
        if (playbackOutcome == _TtsPlaybackOutcome.timedOut) {
          if (!_operations.isCurrent(operation)) break;
          await _rotatePlayback();
          if (!_operations.isCurrent(operation)) break;
          playback = _player;
        }
        if (i + 1 < sentences.length) {
          await Future.any<void>([
            Future<void>.delayed(const Duration(milliseconds: 240)),
            operation.cancelled,
          ]);
          if (!_operations.isCurrent(operation)) break;
        }
      }
    } catch (_) {
      if (!_operations.isCurrent(operation)) return;
      rethrow;
    } finally {
      // Un prefetch ya enviado no se puede abortar sin cerrar el cliente
      // compartido, pero su resultado queda observado y nunca muta playback.
      next?.ignore();
      _operations.finish(operation);
    }
  }

  /// Si el turno anterior terminó con un corte (stop), renueva el AudioPlayer
  /// antes de hablar: evita el arrastre de estado (eventos `onPlayerComplete`
  /// perdidos o reproducción muda) que el plugin sufre al encadenar stop/play.
  Future<void> _freshPlayerIfNeeded() async {
    if (!_needFreshPlayer) return;
    _needFreshPlayer = false;
    await _rotatePlayback();
  }

  Future<void> _rotatePlayback() async {
    final previous = _player;
    final replacement = _playbackFactory();
    if (identical(previous, replacement)) {
      throw ArgumentError('playbackFactory must return a fresh player');
    }
    _player = replacement;
    await _retireTtsPlayback(previous);
  }

  @override
  Future<void> stop() async {
    _operations.cancel();
    _needFreshPlayer = true; // el próximo turno arranca con player limpio
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    _operations.dispose();
    await _player.dispose();
    _http.close();
  }
}

/// Motor genérico para APIs TTS HTTP/REST que reciben JSON. La plantilla se
/// decodifica ANTES de sustituir marcadores, por lo que comillas y saltos del
/// texto nunca pueden romper el JSON ni inyectar campos adicionales.
class CustomHttpTtsEngine implements TtsEngine {
  final String url;
  final String voice;
  final String model;
  final String bodyTemplate;
  final String authHeaderName;
  final String authHeaderPrefix;
  final String authSecret;
  final bool autoDetectResponse;
  final bool responseIsJsonBase64;
  final String base64Path;
  final String mimeType;
  final http.Client _http;
  TtsAudioPlayback _player;
  final TtsAudioPlaybackFactory _playbackFactory;
  final _operations = _TtsOperationGate();

  CustomHttpTtsEngine({
    required String url,
    required this.bodyTemplate,
    this.voice = '',
    this.model = '',
    this.authHeaderName = '',
    this.authHeaderPrefix = '',
    this.authSecret = '',
    this.autoDetectResponse = false,
    this.responseIsJsonBase64 = false,
    this.base64Path = 'audio',
    this.mimeType = 'audio/mpeg',
    http.Client? client,
    TtsAudioPlayback? playback,
    TtsAudioPlaybackFactory? playbackFactory,
  }) : url = _validateUrl(url),
       _http = client ?? http.Client(),
       _player =
           playback ?? _resolveTtsPlaybackFactory(null, playbackFactory)(),
       _playbackFactory = _resolveTtsPlaybackFactory(playback, playbackFactory);

  static String _validateUrl(String value) {
    final String allowed;
    try {
      allowed = TransportPrivacy.requireAllowed(value.trim());
    } on FormatException {
      throw const TtsUserException(TtsUserError.invalidCustomConfiguration);
    }
    final uri = Uri.tryParse(allowed);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const TtsUserException(TtsUserError.invalidCustomConfiguration);
    }
    return allowed;
  }

  static const int _maxChars = 5000;

  static dynamic _expandTemplate(
    dynamic value, {
    required String text,
    required String voice,
    required String model,
  }) {
    if (value is String) {
      return value
          .replaceAll('{{text}}', text)
          .replaceAll('{{voice}}', voice)
          .replaceAll('{{model}}', model);
    }
    if (value is List) {
      return value
          .map(
            (item) =>
                _expandTemplate(item, text: text, voice: voice, model: model),
          )
          .toList();
    }
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(
          key,
          _expandTemplate(item, text: text, voice: voice, model: model),
        ),
      );
    }
    return value;
  }

  static ({Uri uri, Map<String, String> headers, String body}) buildRequest({
    required String url,
    required String bodyTemplate,
    required String text,
    String voice = '',
    String model = '',
    String authHeaderName = '',
    String authHeaderPrefix = '',
    String authSecret = '',
    String mimeType = 'audio/mpeg',
  }) {
    final clipped = text.length > _maxChars
        ? text.substring(0, _maxChars)
        : text;
    dynamic template;
    try {
      template = jsonDecode(bodyTemplate);
    } on FormatException {
      throw const TtsUserException(TtsUserError.invalidCustomConfiguration);
    }
    if (template is! Map && template is! List) {
      throw const TtsUserException(TtsUserError.invalidCustomConfiguration);
    }
    final header = authHeaderName.trim();
    if (header.isNotEmpty &&
        !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(header)) {
      throw const TtsUserException(TtsUserError.invalidCustomConfiguration);
    }
    final expanded = _expandTemplate(
      template,
      text: clipped,
      voice: voice,
      model: model,
    );
    final prefix = authHeaderPrefix.trim();
    final authValue = prefix.isEmpty ? authSecret : '$prefix $authSecret';
    return (
      uri: Uri.parse(_validateUrl(url)),
      headers: {
        'Content-Type': 'application/json',
        if (mimeType.trim().isNotEmpty) 'Accept': mimeType.trim(),
        if (header.isNotEmpty && authSecret.isNotEmpty) header: authValue,
      },
      body: jsonEncode(expanded),
    );
  }

  static dynamic _valueAtPath(dynamic root, String path) {
    dynamic current = root;
    for (final segment in path.split('.').where((item) => item.isNotEmpty)) {
      if (current is Map) {
        if (!current.containsKey(segment)) return null;
        current = current[segment];
      } else if (current is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) return null;
        current = current[index];
      } else {
        return null;
      }
    }
    return current;
  }

  static ({Uint8List bytes, String mimeType}) decodeResponse({
    required Uint8List bodyBytes,
    required Map<String, String> headers,
    required bool responseIsJsonBase64,
    bool autoDetect = false,
    String base64Path = 'audio',
    String configuredMimeType = 'audio/mpeg',
  }) {
    var resolvedMime = configuredMimeType.trim();
    final fromHeader = headers['content-type'] ?? headers['Content-Type'];
    final responseMime = fromHeader?.split(';').first.trim().toLowerCase();
    final declaresAudio = responseMime?.startsWith('audio/') == true;
    final shouldTryJson =
        responseIsJsonBase64 ||
        (autoDetect &&
            !declaresAudio &&
            (responseMime == 'application/json' || _looksLikeJson(bodyBytes)));
    if (!shouldTryJson) {
      if (fromHeader != null && fromHeader.trim().isNotEmpty) {
        resolvedMime = fromHeader.split(';').first.trim();
      }
      if (bodyBytes.isEmpty) {
        throw const TtsUserException(TtsUserError.customResponseMissingAudio);
      }
      return (bytes: bodyBytes, mimeType: resolvedMime);
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bodyBytes));
    } on FormatException {
      if (autoDetect && !responseIsJsonBase64) {
        if (bodyBytes.isEmpty) {
          throw const TtsUserException(TtsUserError.customResponseMissingAudio);
        }
        return (bytes: bodyBytes, mimeType: resolvedMime);
      }
      throw const TtsUserException(TtsUserError.customResponseMissingAudio);
    }
    dynamic value = _valueAtPath(decoded, base64Path.trim());
    if (autoDetect && (value is! String || value.trim().isEmpty)) {
      for (final path in const [
        'audio',
        'data.audio',
        'audioContent',
        'audio_content',
        'data_url',
        'data.data_url',
      ]) {
        final candidate = _valueAtPath(decoded, path);
        if (candidate is String && candidate.trim().isNotEmpty) {
          value = candidate;
          break;
        }
      }
    }
    if (value is! String || value.trim().isEmpty) {
      throw const TtsUserException(TtsUserError.customResponseMissingAudio);
    }
    var encoded = value.trim();
    final dataUri = RegExp(
      r'^data:([^;]+);base64,(.*)$',
      dotAll: true,
    ).firstMatch(encoded);
    if (dataUri != null) {
      resolvedMime = dataUri.group(1) ?? resolvedMime;
      encoded = dataUri.group(2) ?? '';
    }
    try {
      final bytes = base64Decode(encoded.replaceAll(RegExp(r'\s+'), ''));
      if (bytes.isEmpty) {
        throw const TtsUserException(TtsUserError.customResponseMissingAudio);
      }
      return (bytes: bytes, mimeType: resolvedMime);
    } on TtsUserException {
      rethrow;
    } on FormatException {
      throw const TtsUserException(TtsUserError.customResponseMissingAudio);
    }
  }

  static bool _looksLikeJson(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d) {
        continue;
      }
      return byte == 0x7b || byte == 0x5b;
    }
    return false;
  }

  static List<String> _chunks(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return const [];
    final parts = clean.split(RegExp(r'(?<=[.!?…\n])\s+'));
    final chunks = <String>[];
    final buffer = StringBuffer();
    for (final part in parts) {
      if (buffer.isNotEmpty && buffer.length + part.length > 300) {
        chunks.add(buffer.toString());
        buffer.clear();
      }
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(part);
    }
    if (buffer.isNotEmpty) chunks.add(buffer.toString());
    return chunks;
  }

  Future<({Uint8List bytes, String mimeType})> _synthesize(String text) async {
    final request = buildRequest(
      url: url,
      bodyTemplate: bodyTemplate,
      text: text,
      voice: voice,
      model: model,
      authHeaderName: authHeaderName,
      authHeaderPrefix: authHeaderPrefix,
      authSecret: authSecret,
      mimeType: mimeType,
    );
    final response = await _http
        .post(request.uri, headers: request.headers, body: request.body)
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TtsUserException(
        TtsUserError.customHttpFailure,
        statusCode: response.statusCode,
      );
    }
    return decodeResponse(
      bodyBytes: response.bodyBytes,
      headers: response.headers,
      responseIsJsonBase64: responseIsJsonBase64,
      autoDetect: autoDetectResponse,
      base64Path: base64Path,
      configuredMimeType: mimeType,
    );
  }

  @override
  Future<void> speak(String text) async {
    final replacesActivePlayback = _operations.hasActive;
    final operation = _operations.begin();
    try {
      if (replacesActivePlayback) await _rotatePlayback();
      if (!_operations.isCurrent(operation)) return;
      var playback = _player;
      await playback.stop();
      if (!_operations.isCurrent(operation)) return;
      for (final chunk in _chunks(text)) {
        if (!_operations.isCurrent(operation)) break;
        final audio = await _synthesize(chunk);
        if (!_operations.isCurrent(operation)) break;
        await playback.stop();
        if (!_operations.isCurrent(operation)) break;
        final playbackOutcome = await _playAndWait(
          playback: playback,
          operations: _operations,
          operation: operation,
          play: () => playback.playBytes(audio.bytes, mimeType: audio.mimeType),
          timeout: const Duration(seconds: 60),
        );
        if (playbackOutcome == _TtsPlaybackOutcome.cancelled) break;
        if (playbackOutcome == _TtsPlaybackOutcome.timedOut) {
          if (!_operations.isCurrent(operation)) break;
          await _rotatePlayback();
          if (!_operations.isCurrent(operation)) break;
          playback = _player;
        }
      }
    } catch (_) {
      if (!_operations.isCurrent(operation)) return;
      rethrow;
    } finally {
      _operations.finish(operation);
    }
  }

  @override
  Future<void> stop() async {
    final retiresPlayback = _operations.hasActive;
    _operations.cancel();
    if (retiresPlayback) {
      await _rotatePlayback();
    } else {
      await _player.stop();
    }
  }

  @override
  Future<void> dispose() async {
    _operations.dispose();
    await _retireTtsPlayback(_player);
    _http.close();
  }

  Future<void> _rotatePlayback() async {
    final previous = _player;
    final replacement = _playbackFactory();
    if (identical(previous, replacement)) {
      throw ArgumentError('playbackFactory must return a fresh player');
    }
    _player = replacement;
    await _retireTtsPlayback(previous);
  }
}
