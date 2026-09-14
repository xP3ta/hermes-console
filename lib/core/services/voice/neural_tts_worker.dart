import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class NeuralTtsWorkerConfig {
  final String modelPath;
  final String tokensPath;
  final String dataDirPath;
  final String outputDir;

  const NeuralTtsWorkerConfig({
    required this.modelPath,
    required this.tokensPath,
    required this.dataDirPath,
    required this.outputDir,
  });

  Map<String, Object?> toMessage() => {
    'modelPath': modelPath,
    'tokensPath': tokensPath,
    'dataDirPath': dataDirPath,
    'outputDir': outputDir,
  };
}

class NeuralTtsWorkerAudio {
  final Float32List samples;
  final int sampleRate;
  final String? wavePath;
  final int sampleCount;
  final bool audible;

  NeuralTtsWorkerAudio({
    required this.samples,
    required this.sampleRate,
    this.wavePath,
    int? sampleCount,
    bool? audible,
  }) : sampleCount = sampleCount ?? samples.length,
       audible = audible ?? _hasAudibleSamples(samples);
}

abstract interface class NeuralTtsWorker {
  Future<NeuralTtsWorkerAudio> synthesize(String text, double speed);

  Future<void> dispose();
}

typedef NeuralTtsWorkerFactory =
    Future<NeuralTtsWorker> Function(NeuralTtsWorkerConfig config);

class NeuralTtsWorkerException implements Exception {
  final String message;
  const NeuralTtsWorkerException(this.message);

  @override
  String toString() => 'NeuralTtsWorkerException: $message';
}

/// Isolate persistente y propietario único de `OfflineTts`.
///
/// `generate()` es FFI síncrono: ejecutarlo aquí evita bloquear frames, scroll
/// y gestos. Cancelar en el isolate principal no intenta interrumpir esa llamada
/// nativa; invalida el job y evita que su audio llegue a reproducción.
class IsolateNeuralTtsWorker implements NeuralTtsWorker {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<NeuralTtsWorkerAudio>> _pending;
  final Completer<void> _workerStopped;
  int _nextJob = 0;
  bool _disposed = false;

  IsolateNeuralTtsWorker._(
    this._isolate,
    this._commands,
    this._responses,
    this._subscription,
    this._pending,
    this._workerStopped,
  );

  static Future<NeuralTtsWorker> start(NeuralTtsWorkerConfig config) async {
    final responses = ReceivePort('hermes_neural_tts_responses');
    final ready = Completer<SendPort>();
    final pending = <int, Completer<NeuralTtsWorkerAudio>>{};
    final workerStopped = Completer<void>();

    late final StreamSubscription<Object?> subscription;
    subscription = responses.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! Map) return;
      if (message['type'] == 'disposed') {
        if (!workerStopped.isCompleted) workerStopped.complete();
        return;
      }
      final id = message['id'];
      if (id is! int) return;
      final completer = pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = message['error'];
      if (error != null) {
        completer.completeError(
          const NeuralTtsWorkerException('Neural TTS worker failed.'),
        );
        return;
      }
      final sampleRate = message['sampleRate'];
      if (sampleRate is! int) {
        completer.completeError(
          const NeuralTtsWorkerException('Invalid audio result from worker.'),
        );
        return;
      }
      final wavePath = message['wavePath'];
      final sampleCount = message['sampleCount'];
      final audible = message['audible'];
      if (wavePath is String && sampleCount is int && audible is bool) {
        completer.complete(
          NeuralTtsWorkerAudio(
            samples: Float32List(0),
            sampleRate: sampleRate,
            wavePath: wavePath.isEmpty ? null : wavePath,
            sampleCount: sampleCount,
            audible: audible,
          ),
        );
        return;
      }

      // Compatibilidad con workers inyectados/anteriores que devuelven PCM.
      final transfer = message['samples'];
      if (transfer is TransferableTypedData) {
        final bytes = transfer.materialize().asUint8List();
        completer.complete(
          NeuralTtsWorkerAudio(
            samples: Float32List.view(
              bytes.buffer,
              bytes.offsetInBytes,
              bytes.lengthInBytes ~/ Float32List.bytesPerElement,
            ),
            sampleRate: sampleRate,
          ),
        );
        return;
      }
      completer.completeError(
        const NeuralTtsWorkerException('Invalid audio result from worker.'),
      );
    });

    final isolate = await Isolate.spawn<Map<String, Object?>>(
      _neuralTtsWorkerMain,
      {'replyTo': responses.sendPort, ...config.toMessage()},
      debugName: 'hermes-neural-tts',
      errorsAreFatal: true,
    );
    try {
      final commands = await ready.future.timeout(const Duration(seconds: 5));
      return IsolateNeuralTtsWorker._(
        isolate,
        commands,
        responses,
        subscription,
        pending,
        workerStopped,
      );
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      responses.close();
      rethrow;
    }
  }

  @override
  Future<NeuralTtsWorkerAudio> synthesize(String text, double speed) {
    if (_disposed) {
      return Future.error(
        const NeuralTtsWorkerException('Worker is already disposed.'),
      );
    }
    final id = ++_nextJob;
    final completer = Completer<NeuralTtsWorkerAudio>();
    _pending[id] = completer;
    _commands.send({
      'type': 'synthesize',
      'id': id,
      'text': text,
      'speed': speed,
    });
    return completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _commands.send(const {'type': 'dispose'});
    // Si no hay inferencia bloqueando, OfflineTts se libera en su isolate y lo
    // confirma. Si generate sigue dentro de FFI, la app espera solo una ventana
    // acotada y mata el isolate propietario sin bloquear la UI.
    try {
      await _workerStopped.future.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      debugPrint('[hermes-tts-worker] dispose timeout; killing worker');
    }
    _isolate.kill(priority: Isolate.immediate);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const NeuralTtsWorkerException('Worker disposed during synthesis.'),
        );
      }
    }
    _pending.clear();
    await _subscription.cancel();
    _responses.close();
  }
}

void _neuralTtsWorkerMain(Map<String, Object?> bootstrap) {
  final replyTo = bootstrap['replyTo']! as SendPort;
  final commands = ReceivePort('hermes_neural_tts_commands');
  replyTo.send(commands.sendPort);

  sherpa.OfflineTts? tts;
  var bindingsReady = false;

  void ensureTts(void Function(String stage) setStage) {
    if (tts != null) return;
    if (!bindingsReady) {
      setStage('bindings');
      sherpa.initBindings();
      bindingsReady = true;
    }
    setStage('model');
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: bootstrap['modelPath']! as String,
          tokens: bootstrap['tokensPath']! as String,
          dataDir: bootstrap['dataDirPath']! as String,
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
      maxNumSenetences: 1,
    );
    tts = sherpa.OfflineTts(config);
  }

  commands.listen((message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'dispose') {
      try {
        tts?.free();
      } catch (error) {
        debugPrint('[hermes-tts-worker] free failed (${error.runtimeType})');
      }
      tts = null;
      replyTo.send(const {'type': 'disposed'});
      commands.close();
      return;
    }
    if (type != 'synthesize') return;
    final id = message['id'];
    if (id is! int) return;
    var stage = 'request';
    try {
      ensureTts((value) => stage = value);
      stage = 'generate';
      final audio = tts!.generate(
        text: message['text']! as String,
        sid: 0,
        speed: (message['speed']! as num).toDouble(),
      );
      final audible = _hasAudibleSamples(audio.samples);
      var wavePath = '';
      if (audible) {
        stage = 'wave';
        final outputDir = bootstrap['outputDir']! as String;
        Directory(outputDir).createSync(recursive: true);
        wavePath =
            '$outputDir/hermes_tts_'
            '${DateTime.now().microsecondsSinceEpoch}_$id.wav';
        final written = sherpa.writeWave(
          filename: wavePath,
          samples: audio.samples,
          sampleRate: audio.sampleRate,
        );
        if (!written) wavePath = '';
      }
      stage = 'transfer';
      replyTo.send({
        'id': id,
        'sampleRate': audio.sampleRate,
        'sampleCount': audio.samples.length,
        'audible': audible,
        'wavePath': wavePath,
      });
    } catch (error) {
      debugPrint(
        '[hermes-tts-worker] failed stage=$stage '
        'type=${error.runtimeType}',
      );
      replyTo.send({
        'id': id,
        'error': true,
        'stage': stage,
        'errorType': error.runtimeType.toString(),
      });
    }
  });
}

bool _hasAudibleSamples(List<double> samples) {
  for (final sample in samples) {
    if (sample > 0.003 || sample < -0.003) return true;
  }
  return false;
}
