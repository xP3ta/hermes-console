import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
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
  final bool acousticSpeechEvidence;
  final List<String> segments;
  final String? error;

  const SherpaSttWorkerUpdate({
    required this.generation,
    required this.level,
    required this.speechDetected,
    required this.acousticSpeechEvidence,
    required this.segments,
    this.error,
  });
}

/// Gate acustico previo al texto de Whisper. Usa las mismas ventanas de
/// Hermes Desktop para que un pico aislado no convierta ruido en un turno:
/// frames de 30 ms, 300 ms de ventana y mayoria minima del 80 %.
///
/// Sherpa publica `RMS PCM normalizado * 4`; el nivel WebAudio `0.075` de
/// Desktop equivale exactamente a `0.0984375` en esa escala.
class SherpaDesktopSpeechGate {
  static const int sampleRate = 16000;
  static const int frameSamples = 480;
  static const int majorityWindow = 10;
  static const int majorityRequired = 8;
  static const double levelThreshold = 0.0984375;

  final List<bool> _window = <bool>[];
  Float32List _carry = Float32List(0);
  bool _hasEvidence = false;

  bool get hasEvidence => _hasEvidence;

  void reset() {
    _window.clear();
    _carry = Float32List(0);
    _hasEvidence = false;
  }

  bool accept(Float32List samples, {required bool speechDetected}) {
    if (_hasEvidence) return true;
    if (!speechDetected) {
      // Un pico que Silero clasifica como no-voz no puede prearmar el texto
      // que Whisper produzca mas tarde dentro del mismo ciclo de 12 segundos.
      _window.clear();
      _carry = Float32List(0);
      return false;
    }
    if (samples.isEmpty) return false;
    final merged = _carry.isEmpty
        ? samples
        : (Float32List(_carry.length + samples.length)
            ..setRange(0, _carry.length, _carry)
            ..setRange(_carry.length, _carry.length + samples.length, samples));
    var offset = 0;
    while (merged.length - offset >= frameSamples && !_hasEvidence) {
      final frame = Float32List.sublistView(
        merged,
        offset,
        offset + frameSamples,
      );
      acceptLevelFrame(_rms(frame));
      offset += frameSamples;
    }
    _carry = offset >= merged.length
        ? Float32List(0)
        : Float32List.fromList(Float32List.sublistView(merged, offset));
    return _hasEvidence;
  }

  bool acceptLevelFrame(double level) {
    if (_hasEvidence) return true;
    final above = level >= levelThreshold;
    _window.add(above);
    if (_window.length > majorityWindow) _window.removeAt(0);
    _hasEvidence =
        _window.length == majorityWindow &&
        above &&
        _window.where((value) => value).length >= majorityRequired;
    return _hasEvidence;
  }
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
class IsolateSherpaSttWorker implements SherpaSttWorker {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final StreamSubscription<Object?> _subscription;
  final StreamController<SherpaSttWorkerUpdate> _updates;
  final Map<int, Completer<Map<Object?, Object?>>> _pending;
  final Completer<void> _workerStopped;

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
  );

  static Future<SherpaSttWorker> start(SherpaSttWorkerConfig config) async {
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
      _sherpaSttWorkerMain,
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
    await _request('prepare');
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

  Future<void> _dispose() async {
    _commands.send(const {'type': 'dispose'});
    try {
      await _workerStopped.future.timeout(const Duration(milliseconds: 700));
    } on TimeoutException {
      debugPrint('[hermes-stt-worker] dispose timeout; killing worker');
    }
    _isolate.kill(priority: Isolate.immediate);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const SherpaSttWorkerException('Worker disposed during inference.'),
        );
      }
    }
    _pending.clear();
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
  final acousticSpeechGate = SherpaDesktopSpeechGate();
  var bindingsReady = false;
  int? activeGeneration;

  String safeError(Object error) {
    return 'Sherpa worker failed (${error.runtimeType}).';
  }

  void ensureEngine() {
    if (recognizer != null && vad != null) return;
    if (!bindingsReady) {
      sherpa.initBindings();
      bindingsReady = true;
    }
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
      final text = decode(segment.samples);
      if (text.isNotEmpty) segments.add(text);
    }
    return segments;
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
        acousticSpeechGate.reset();
        activeGeneration = null;
        replyTo.send({'type': 'result', 'id': id});
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
          acousticSpeechGate.reset();
          activeGeneration = generation;
        }
        final bytes = transfer.materialize().asUint8List();
        final samples = _pcm16ToFloat(bytes);
        vad!.acceptWaveform(samples);
        final speechDetected = vad!.isDetected();
        final acousticSpeechEvidence = acousticSpeechGate.accept(
          samples,
          speechDetected: speechDetected,
        );
        replyTo.send({
          'type': 'update',
          'generation': generation,
          'level': _rms(samples),
          'speechDetected': speechDetected,
          'acousticSpeechEvidence': acousticSpeechEvidence,
          'segments': drainSegments(),
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
        replyTo.send({
          'type': 'result',
          'id': id,
          'generation': generation,
          'segments': drainSegments(),
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

double _rms(Float32List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final sample in samples) {
    sum += sample * sample;
  }
  return (math.sqrt(sum / samples.length) * 4).clamp(0.0, 1.0);
}
