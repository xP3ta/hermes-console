import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class SherpaSttWorkerConfig {
  final String tokensPath;
  final String encoderPath;
  final String decoderPath;
  final String joinerPath;
  final String sileroPath;
  final String language;
  final bool transducer;
  final int numThreads;

  const SherpaSttWorkerConfig({
    required this.tokensPath,
    required this.encoderPath,
    required this.decoderPath,
    required this.joinerPath,
    required this.sileroPath,
    required this.language,
    required this.transducer,
    required this.numThreads,
  });

  Map<String, Object?> toMessage() => {
    'tokensPath': tokensPath,
    'encoderPath': encoderPath,
    'decoderPath': decoderPath,
    'joinerPath': joinerPath,
    'sileroPath': sileroPath,
    'language': language,
    'transducer': transducer,
    'numThreads': numThreads,
  };
}

class SherpaSttWorkerUpdate {
  final int generation;
  final double level;
  final bool speechDetected;

  /// The utterance being heard has shown speech evidence ([SherpaSpeechGate]).
  final bool acousticSpeechEvidence;

  /// Text of the segments that held speech. Segments without evidence are
  /// never transcribed: they only count in [rejectedSegments].
  final List<String> segments;

  /// Segments the VAD closed since the last update that held no speech, with
  /// the longest of them and the loudest frame among them. Diagnostics only.
  final int rejectedSegments;
  final int rejectedMs;
  final double rejectedPeak;

  /// The gate's view of the room when this update was made.
  final double noiseFloor;
  final double trigger;
  final String? error;

  const SherpaSttWorkerUpdate({
    required this.generation,
    required this.level,
    required this.speechDetected,
    required this.acousticSpeechEvidence,
    required this.segments,
    this.rejectedSegments = 0,
    this.rejectedMs = 0,
    this.rejectedPeak = 0,
    this.noiseFloor = 0,
    this.trigger = SherpaSpeechGate.minimumTrigger,
    this.error,
  });
}

/// Evidence that what the VAD cut out of the microphone is somebody speaking.
///
/// Whisper writes text for any audio it is handed, so a segment the VAD cut out
/// of silence, a key press or a bump must not become a turn. Hermes Desktop
/// decides "speech was heard" from an absolute meter level (`silenceLevel`
/// 0.075 in `use-voice-conversation.ts`), and its talk-over monitor
/// (`voice-barge-in.ts`) from a windowed majority above a trigger relative to
/// the quiet floor. The absolute level belongs to Desktop's capture chain: the
/// browser applies automatic gain. An Android phone records for recognition
/// without gain control and several times quieter, so normal speech stayed
/// under it and the recognised text was thrown away.
///
/// What holds on any microphone is how far the sound stands out of THIS
/// session's quiet, for long enough:
/// - each 30 ms frame is compared with a trigger of [floorMultiplier] times
///   the noise floor: the median level of the frames the VAD called quiet,
///   trusted after 300 ms and adapting from then on;
/// - speech is a sustained run inside what the VAD calls speech,
///   [sustainedRequired] of [sustainedWindow] consecutive frames above the
///   trigger. A click or a key press is one frame.
///
/// The trigger never goes above Desktop's level, so nothing that passed
/// before is refused now, nor below [minimumTrigger], so the residue of a
/// noise suppressor never counts as sound.
///
/// Levels are Sherpa's `RMS x 4` of normalised PCM; Desktop's 0.075 is
/// exactly [desktopLevel] on that scale.
class SherpaSpeechGate {
  static const int sampleRate = 16000;
  static const int frameSamples = 480;
  static const int sustainedWindow = 5;
  static const int sustainedRequired = 4;
  static const int calibrationFrames = 10;
  static const int floorWindowFrames = 100;
  static const double floorMultiplier = 2;
  static const double minimumTrigger = 0.012;
  static const double desktopLevel = 0.0984375;

  final List<bool> _window = <bool>[];
  final List<double> _quiet = <double>[];
  Float32List _carry = Float32List(0);
  bool _hasEvidence = false;
  double? _floor;

  /// The current utterance has shown speech evidence.
  bool get hasEvidence => _hasEvidence;

  /// Enough quiet has been heard to trust [noiseFloor].
  bool get calibrated => _quiet.length >= calibrationFrames;

  /// Median level of the recent quiet frames; 0 until [calibrated].
  double get noiseFloor {
    if (!calibrated) return 0;
    final cached = _floor;
    if (cached != null) return cached;
    final sorted = [..._quiet]..sort();
    return _floor = sorted[sorted.length >> 1];
  }

  /// Level a frame has to reach to count as sound standing out of the quiet.
  double get trigger =>
      (noiseFloor * floorMultiplier).clamp(minimumTrigger, desktopLevel);

  /// A new utterance: its evidence starts over, the noise floor is kept.
  void resetUtterance() {
    _window.clear();
    _carry = Float32List(0);
    _hasEvidence = false;
  }

  /// A new session: nothing is known about the room any more.
  void reset() {
    resetUtterance();
    _quiet.clear();
    _floor = null;
  }

  /// Feeds live audio. Returns whether the utterance has speech evidence.
  bool accept(Float32List samples, {required bool speechDetected}) {
    if (samples.isEmpty) return _hasEvidence;
    final merged = _carry.isEmpty
        ? samples
        : (Float32List(_carry.length + samples.length)
            ..setRange(0, _carry.length, _carry)
            ..setRange(_carry.length, _carry.length + samples.length, samples));
    var offset = 0;
    while (merged.length - offset >= frameSamples) {
      acceptLevelFrame(
        sherpaFrameLevel(merged, offset, offset + frameSamples),
        speechDetected: speechDetected,
      );
      offset += frameSamples;
    }
    _carry = offset >= merged.length
        ? Float32List(0)
        : Float32List.fromList(Float32List.sublistView(merged, offset));
    return _hasEvidence;
  }

  /// One 30 ms frame of live audio at [level].
  bool acceptLevelFrame(double level, {required bool speechDetected}) {
    if (!speechDetected) {
      // Quiet is what the floor is made of. A burst the VAD does not call
      // speech cannot prepare the ground for text Whisper writes later.
      _quiet.add(level);
      if (_quiet.length > floorWindowFrames) _quiet.removeAt(0);
      _floor = null;
      _window.clear();
      return _hasEvidence;
    }
    if (_hasEvidence) return true;
    final above = level >= trigger;
    _window.add(above);
    if (_window.length > sustainedWindow) _window.removeAt(0);
    _hasEvidence = _sustained(_window, above);
    return _hasEvidence;
  }

  /// Whether a segment the VAD closed holds a sustained run above the
  /// trigger: the text Whisper writes for it is only kept if it does.
  bool segmentHasSpeech(Float32List samples) => levelsHaveSpeech([
    for (
      var offset = 0;
      samples.length - offset >= frameSamples;
      offset += frameSamples
    )
      sherpaFrameLevel(samples, offset, offset + frameSamples),
  ]);

  /// [segmentHasSpeech] for a segment given as its 30 ms frame levels.
  bool levelsHaveSpeech(Iterable<double> frameLevels) {
    final threshold = trigger;
    final window = <bool>[];
    for (final level in frameLevels) {
      final above = level >= threshold;
      window.add(above);
      if (window.length > sustainedWindow) window.removeAt(0);
      if (_sustained(window, above)) return true;
    }
    return false;
  }

  static bool _sustained(List<bool> window, bool lastAbove) =>
      window.length == sustainedWindow &&
      lastAbove &&
      window.where((value) => value).length >= sustainedRequired;
}

/// Sherpa's level of the samples in `[start, end)`: `RMS x 4`, at most 1.
double sherpaFrameLevel(Float32List samples, int start, int end) {
  if (end <= start) return 0;
  var sum = 0.0;
  for (var index = start; index < end; index++) {
    sum += samples[index] * samples[index];
  }
  return (math.sqrt(sum / (end - start)) * 4).clamp(0.0, 1.0);
}

abstract interface class SherpaSttWorker {
  Stream<SherpaSttWorkerUpdate> get updates;

  Future<void> prepare();

  void accept(Uint8List pcm16, {required int generation});

  Future<List<String>> flush({required int generation});

  Future<void> dispose();
}

typedef SherpaSttWorkerFactory =
    Future<SherpaSttWorker> Function(SherpaSttWorkerConfig config);

/// Where the one load of a recogniser went, in milliseconds: starting its
/// isolate, binding the native library, opening the recognition model and
/// opening the voice detector. Numbers only.
class SherpaSttLoadTiming {
  final int spawnMs;
  final int bindingsMs;
  final int recognizerMs;
  final int vadMs;

  const SherpaSttLoadTiming({
    required this.spawnMs,
    required this.bindingsMs,
    required this.recognizerMs,
    required this.vadMs,
  });

  @override
  String toString() =>
      'spawn_ms=$spawnMs bindings_ms=$bindingsMs '
      'recognizer_ms=$recognizerMs vad_ms=$vadMs';
}

/// A worker that can say where its load went.
abstract interface class SherpaSttLoadTimed {
  /// Null until the recogniser has been loaded.
  SherpaSttLoadTiming? get loadTiming;
}

class SherpaSttWorkerException implements Exception {
  final String message;

  const SherpaSttWorkerException(this.message);

  @override
  String toString() => 'SherpaSttWorkerException: $message';
}

/// Isolate propietario del recognizer y VAD de Sherpa.
///
/// Construir el modelo, alimentar el VAD y `decode()` son FFI síncronos. Al
/// ejecutarlos aquí, el isolate de Flutter puede pintar el estado de escucha,
/// responder a gestos y hacer scroll aunque el primer arranque tarde unos
/// segundos. Los paquetes PCM viajan como [TransferableTypedData].
class IsolateSherpaSttWorker implements SherpaSttWorker, SherpaSttLoadTimed {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final StreamSubscription<Object?> _subscription;
  final StreamController<SherpaSttWorkerUpdate> _updates;
  final Map<int, Completer<Map<Object?, Object?>>> _pending;
  final Completer<void> _workerStopped;
  final int _spawnMs;

  SherpaSttLoadTiming? _loadTiming;

  @override
  SherpaSttLoadTiming? get loadTiming => _loadTiming;

  int _nextRequest = 0;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  IsolateSherpaSttWorker._(
    this._isolate,
    this._commands,
    this._responses,
    this._subscription,
    this._updates,
    this._pending,
    this._workerStopped,
    this._spawnMs,
  );

  static Future<SherpaSttWorker> start(SherpaSttWorkerConfig config) =>
      startWith(config, _sherpaSttWorkerMain);

  /// [start] with the isolate's entry point given, so its protocol can be
  /// exercised without the native library.
  @visibleForTesting
  static Future<SherpaSttWorker> startWith(
    SherpaSttWorkerConfig config,
    void Function(Map<String, Object?> bootstrap) entryPoint,
  ) async {
    final spawning = Stopwatch()..start();
    final responses = ReceivePort('hermes_sherpa_stt_responses');
    final ready = Completer<SendPort>();
    final updates = StreamController<SherpaSttWorkerUpdate>.broadcast();
    final pending = <int, Completer<Map<Object?, Object?>>>{};
    final workerStopped = Completer<void>();

    late final StreamSubscription<Object?> subscription;
    subscription = responses.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! Map) return;
      final type = message['type'];
      if (type == 'disposed') {
        if (!workerStopped.isCompleted) workerStopped.complete();
        return;
      }
      if (type == 'update') {
        final generation = message['generation'];
        if (generation is! int || updates.isClosed) return;
        updates.add(
          SherpaSttWorkerUpdate(
            generation: generation,
            level: (message['level'] as num?)?.toDouble() ?? 0,
            speechDetected: message['speechDetected'] == true,
            acousticSpeechEvidence: message['acousticSpeechEvidence'] == true,
            segments: _stringList(message['segments']),
            rejectedSegments:
                (message['rejectedSegments'] as num?)?.toInt() ?? 0,
            rejectedMs: (message['rejectedMs'] as num?)?.toInt() ?? 0,
            rejectedPeak: (message['rejectedPeak'] as num?)?.toDouble() ?? 0,
            noiseFloor: (message['noiseFloor'] as num?)?.toDouble() ?? 0,
            trigger:
                (message['trigger'] as num?)?.toDouble() ??
                SherpaSpeechGate.minimumTrigger,
            error: message['error']?.toString(),
          ),
        );
        return;
      }
      final id = message['id'];
      if (id is! int) return;
      final completer = pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = message['error'];
      if (error != null) {
        completer.completeError(SherpaSttWorkerException(error.toString()));
      } else {
        completer.complete(Map<Object?, Object?>.from(message));
      }
    });

    final isolate = await Isolate.spawn<Map<String, Object?>>(
      entryPoint,
      {'replyTo': responses.sendPort, ...config.toMessage()},
      debugName: 'hermes-sherpa-stt',
      errorsAreFatal: true,
    );
    try {
      final commands = await ready.future.timeout(const Duration(seconds: 5));
      return IsolateSherpaSttWorker._(
        isolate,
        commands,
        responses,
        subscription,
        updates,
        pending,
        workerStopped,
        spawning.elapsedMilliseconds,
      );
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      await updates.close();
      responses.close();
      rethrow;
    }
  }

  @override
  Stream<SherpaSttWorkerUpdate> get updates => _updates.stream;

  Future<Map<Object?, Object?>> _request(
    String type, [
    Map<String, Object?> payload = const {},
  ]) {
    if (_disposed) {
      return Future.error(
        const SherpaSttWorkerException('Worker is already disposed.'),
      );
    }
    final id = ++_nextRequest;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = completer;
    _commands.send({'type': type, 'id': id, ...payload});
    return completer.future;
  }

  @override
  Future<void> prepare() async {
    final result = await _request('prepare');
    final load = result['load'];
    if (load is Map) {
      int ms(String phase) => (load[phase] as num?)?.toInt() ?? 0;
      _loadTiming = SherpaSttLoadTiming(
        spawnMs: _spawnMs,
        bindingsMs: ms('bindings'),
        recognizerMs: ms('recognizer'),
        vadMs: ms('vad'),
      );
    }
  }

  @override
  void accept(Uint8List pcm16, {required int generation}) {
    if (_disposed || pcm16.isEmpty) return;
    _commands.send({
      'type': 'audio',
      'generation': generation,
      'pcm': TransferableTypedData.fromList([pcm16]),
    });
  }

  @override
  Future<List<String>> flush({required int generation}) async {
    final result = await _request('flush', {'generation': generation});
    return _stringList(result['segments']);
  }

  @override
  Future<void> dispose() {
    final current = _disposeFuture;
    if (current != null) return current;
    _disposed = true;
    return _disposeFuture = _dispose();
  }

  /// How long a worker that was released inside the native library is given
  /// to come back and free its model before it is killed anyway.
  static const Duration _busyReleaseLimit = Duration(seconds: 60);

  Future<void> _dispose() async {
    _commands.send(const {'type': 'dispose'});
    // Asked and not answered yet: the worker is inside the native library,
    // opening the model or transcribing.
    final busy = _pending.isNotEmpty;
    var stopped = true;
    try {
      await _workerStopped.future.timeout(const Duration(milliseconds: 700));
    } on TimeoutException {
      stopped = false;
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const SherpaSttWorkerException('Worker disposed during inference.'),
        );
      }
    }
    _pending.clear();
    if (stopped || !busy) {
      if (!stopped) {
        debugPrint('[hermes-stt-worker] dispose timeout; killing worker');
      }
      await _closeIsolate();
      return;
    }
    // Killing it now would leave whatever that native call returns, a whole
    // model, in memory with nobody left to free it. The caller goes on; the
    // worker frees its model when the call comes back, and only one that
    // never does is killed.
    debugPrint('[hermes-stt-worker] dispose deferred: worker busy');
    unawaited(
      _workerStopped.future
          .timeout(
            _busyReleaseLimit,
            onTimeout: () => debugPrint(
              '[hermes-stt-worker] busy worker never came back; killing it',
            ),
          )
          .whenComplete(_closeIsolate),
    );
  }

  Future<void> _closeIsolate() async {
    _isolate.kill(priority: Isolate.immediate);
    await _subscription.cancel();
    await _updates.close();
    _responses.close();
  }
}

List<String> _stringList(Object? value) => value is List
    ? value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false)
    : const [];

void _sherpaSttWorkerMain(Map<String, Object?> bootstrap) {
  final replyTo = bootstrap['replyTo']! as SendPort;
  final commands = ReceivePort('hermes_sherpa_stt_commands');
  replyTo.send(commands.sendPort);

  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;
  final speechGate = SherpaSpeechGate();
  var rejectedSegments = 0;
  var rejectedMs = 0;
  var rejectedPeak = 0.0;
  var bindingsReady = false;
  // Where the load went, handed once to whoever asked for it.
  Map<String, int>? loadReport;
  int? activeGeneration;

  String safeError(Object error) {
    return 'Sherpa worker failed (${error.runtimeType}).';
  }

  void ensureEngine() {
    if (recognizer != null && vad != null) return;
    final clock = Stopwatch()..start();
    if (!bindingsReady) {
      sherpa.initBindings();
      bindingsReady = true;
    }
    final bindingsMs = clock.elapsedMilliseconds;
    final transducer = bootstrap['transducer'] == true;
    final modelConfig = transducer
        ? sherpa.OfflineModelConfig(
            transducer: sherpa.OfflineTransducerModelConfig(
              encoder: bootstrap['encoderPath']! as String,
              decoder: bootstrap['decoderPath']! as String,
              joiner: bootstrap['joinerPath']! as String,
            ),
            tokens: bootstrap['tokensPath']! as String,
            numThreads: bootstrap['numThreads']! as int,
            debug: false,
          )
        : sherpa.OfflineModelConfig(
            whisper: sherpa.OfflineWhisperModelConfig(
              encoder: bootstrap['encoderPath']! as String,
              decoder: bootstrap['decoderPath']! as String,
              language: bootstrap['language']! as String,
              task: 'transcribe',
            ),
            tokens: bootstrap['tokensPath']! as String,
            numThreads: bootstrap['numThreads']! as int,
            debug: false,
          );
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(model: modelConfig),
    );
    final recognizerMs = clock.elapsedMilliseconds - bindingsMs;
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: bootstrap['sileroPath']! as String,
          minSilenceDuration: 0.25,
          minSpeechDuration: 0.20,
          maxSpeechDuration: 12.0,
        ),
        sampleRate: 16000,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
    loadReport = {
      'bindings': bindingsMs,
      'recognizer': recognizerMs,
      'vad': clock.elapsedMilliseconds - bindingsMs - recognizerMs,
    };
  }

  String decode(Float32List samples) {
    if (samples.isEmpty) return '';
    final stream = recognizer!.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer!.decode(stream);
      return recognizer!.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  List<String> drainSegments() {
    final segments = <String>[];
    while (!(vad?.isEmpty() ?? true)) {
      final segment = vad!.front();
      vad!.pop();
      final samples = segment.samples;
      if (!speechGate.segmentHasSpeech(samples)) {
        // Not transcribed at all: no text can come out of what was not said.
        rejectedSegments++;
        rejectedMs = math.max(rejectedMs, samples.length * 1000 ~/ 16000);
        for (
          var offset = 0;
          samples.length - offset >= SherpaSpeechGate.frameSamples;
          offset += SherpaSpeechGate.frameSamples
        ) {
          rejectedPeak = math.max(
            rejectedPeak,
            sherpaFrameLevel(
              samples,
              offset,
              offset + SherpaSpeechGate.frameSamples,
            ),
          );
        }
        continue;
      }
      final text = decode(samples);
      if (text.isNotEmpty) segments.add(text);
    }
    return segments;
  }

  /// The gate's diagnostics for the next update; what was rejected is
  /// reported once.
  Map<String, Object?> takeGateReport() {
    final report = <String, Object?>{
      'rejectedSegments': rejectedSegments,
      'rejectedMs': rejectedMs,
      'rejectedPeak': rejectedPeak,
      'noiseFloor': speechGate.noiseFloor,
      'trigger': speechGate.trigger,
    };
    rejectedSegments = 0;
    rejectedMs = 0;
    rejectedPeak = 0;
    return report;
  }

  commands.listen((message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'dispose') {
      try {
        recognizer?.free();
      } catch (error) {
        debugPrint(
          '[hermes-stt-worker] recognizer free failed '
          '(${error.runtimeType})',
        );
      }
      try {
        vad?.free();
      } catch (error) {
        debugPrint(
          '[hermes-stt-worker] VAD free failed (${error.runtimeType})',
        );
      }
      recognizer = null;
      vad = null;
      replyTo.send(const {'type': 'disposed'});
      commands.close();
      return;
    }

    final id = message['id'];
    if (type == 'prepare' && id is int) {
      try {
        ensureEngine();
        vad!.reset();
        // The room does not change between two turns of one session: only
        // the utterance's own evidence starts over.
        speechGate.resetUtterance();
        activeGeneration = null;
        replyTo.send({'type': 'result', 'id': id, 'load': ?loadReport});
        loadReport = null;
      } catch (error) {
        replyTo.send({'type': 'result', 'id': id, 'error': safeError(error)});
      }
      return;
    }

    if (type == 'audio') {
      final generation = message['generation'];
      final transfer = message['pcm'];
      if (generation is! int || transfer is! TransferableTypedData) return;
      try {
        ensureEngine();
        if (activeGeneration != generation) {
          speechGate.resetUtterance();
          activeGeneration = generation;
        }
        final bytes = transfer.materialize().asUint8List();
        final samples = _pcm16ToFloat(bytes);
        vad!.acceptWaveform(samples);
        final speechDetected = vad!.isDetected();
        final acousticSpeechEvidence = speechGate.accept(
          samples,
          speechDetected: speechDetected,
        );
        final segments = drainSegments();
        replyTo.send({
          'type': 'update',
          'generation': generation,
          'level': sherpaFrameLevel(samples, 0, samples.length),
          'speechDetected': speechDetected,
          'acousticSpeechEvidence': acousticSpeechEvidence,
          'segments': segments,
          ...takeGateReport(),
        });
      } catch (error) {
        replyTo.send({
          'type': 'update',
          'generation': generation,
          'level': 0.0,
          'speechDetected': false,
          'acousticSpeechEvidence': false,
          'segments': const <String>[],
          'error': safeError(error),
        });
      }
      return;
    }

    if (type == 'flush' && id is int) {
      final generation = message['generation'];
      if (generation is! int) {
        replyTo.send({
          'type': 'result',
          'id': id,
          'error': 'Missing STT generation.',
        });
        return;
      }
      try {
        ensureEngine();
        vad!.flush();
        final segments = drainSegments();
        if (rejectedSegments > 0) {
          // The engine logs what the gate refused; the result only carries
          // the text that was kept.
          replyTo.send({
            'type': 'update',
            'generation': generation,
            'level': 0.0,
            'speechDetected': false,
            'acousticSpeechEvidence': speechGate.hasEvidence,
            'segments': const <String>[],
            ...takeGateReport(),
          });
        }
        replyTo.send({
          'type': 'result',
          'id': id,
          'generation': generation,
          'segments': segments,
        });
      } catch (error) {
        replyTo.send({'type': 'result', 'id': id, 'error': safeError(error)});
      }
    }
  });
}

Float32List _pcm16ToFloat(Uint8List bytes) {
  final count = bytes.length ~/ 2;
  final samples = Float32List(count);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < count; index++) {
    samples[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
  }
  return samples;
}
