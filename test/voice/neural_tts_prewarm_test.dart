import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/neural_tts_worker.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';

/// Spec 048 / US2+US3 — precarga del motor neuronal
/// (contracts/engine-prewarm.md): `prewarm()` paga el arranque del worker
/// durante la espera del agente y `prewarm(texto)` deja la primera frase
/// sintetizada en el caché sin reproducir nada.
class _CountingWorker implements NeuralTtsWorker {
  _CountingWorker(this.onSynth);

  final void Function(String text) onSynth;
  int disposeCalls = 0;

  @override
  Future<NeuralTtsWorkerAudio> synthesize(String text, double speed) async {
    onSynth(text);
    return NeuralTtsWorkerAudio(
      samples: Float32List.fromList([0.2, -0.2, 0.2]),
      sampleRate: 16000,
    );
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _WaveWritingWorker implements NeuralTtsWorker {
  _WaveWritingWorker(this.directory);

  final Directory directory;
  final List<File> waves = <File>[];

  @override
  Future<NeuralTtsWorkerAudio> synthesize(String text, double speed) async {
    final wave = File('${directory.path}/hermes_tts_${waves.length}.wav');
    wave.writeAsBytesSync(<int>[82, 73, 70, 70], flush: true);
    waves.add(wave);
    return NeuralTtsWorkerAudio(
      samples: Float32List.fromList(<double>[0.2, -0.2, 0.2]),
      sampleRate: 16000,
      wavePath: wave.path,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _DelayedWaveWorker extends _WaveWritingWorker {
  _DelayedWaveWorker(super.directory);

  final firstRequested = Completer<void>();
  final releaseFirst = Completer<void>();
  int requests = 0;

  @override
  Future<NeuralTtsWorkerAudio> synthesize(String text, double speed) async {
    final request = requests++;
    if (request == 0) {
      firstRequested.complete();
      await releaseFirst.future;
    }
    return super.synthesize(text, speed);
  }
}

class _Playback implements TtsAudioPlayback {
  _Playback({this.playRelease});

  final Completer<void>? playRelease;
  final _completions = StreamController<void>.broadcast();
  final played = Completer<void>();
  int playCount = 0;

  @override
  Stream<void> get onComplete => _completions.stream;

  @override
  Future<void> playBytes(Uint8List bytes, {required String mimeType}) async {
    playCount++;
    scheduleMicrotask(() => _completions.add(null));
  }

  @override
  Future<void> playFile(String path) async {
    playCount++;
    if (!played.isCompleted) played.complete();
    final release = playRelease;
    if (release != null) await release.future;
    scheduleMicrotask(() => _completions.add(null));
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _FailingPlayback extends _Playback {
  @override
  Future<void> playFile(String path) async {
    throw StateError('decoder unavailable');
  }
}

class _CompletionFailingPlayback extends _Playback {
  @override
  Future<void> playFile(String path) async {
    playCount++;
    if (!played.isCompleted) played.complete();
    scheduleMicrotask(
      () => _completions.addError(StateError('completion unavailable')),
    );
  }
}

void main() {
  test('dispose elimina todos los WAV de prewarm reemplazados', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hermes-tts-owner-',
    );
    final worker = _WaveWritingWorker(directory);
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: _Playback(),
      playbackFactory: _Playback.new,
      debugWorkerFactory: (_) async => worker,
    );
    addTearDown(() async {
      await engine.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    await engine.prewarm('Primera privada.');
    await engine.prewarm('Segunda privada.');
    expect(worker.waves, hasLength(2));

    await engine.dispose();

    expect(
      worker.waves.where((wave) => wave.existsSync()),
      isEmpty,
      reason: 'ningún audio conversacional puede sobrevivir al owner',
    );
  });

  test('prewarm A tardío se limpia sin borrar el WAV B vigente', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hermes-tts-late-owner-',
    );
    final worker = _DelayedWaveWorker(directory);
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: _Playback(),
      playbackFactory: _Playback.new,
      debugWorkerFactory: (_) async => worker,
    );
    addTearDown(() async {
      if (!worker.releaseFirst.isCompleted) worker.releaseFirst.complete();
      await engine.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final prewarmA = engine.prewarm('Primera privada.');
    await worker.firstRequested.future;
    await engine.prewarm('Segunda privada.');
    expect(worker.waves, hasLength(1));
    final waveB = worker.waves.single;

    worker.releaseFirst.complete();
    await prewarmA;
    await Future<void>.value();

    expect(worker.waves, hasLength(2));
    final waveA = worker.waves.last;
    expect(waveA.existsSync(), isFalse);
    expect(waveB.existsSync(), isTrue);
  });

  test(
    'reemplazar prewarm no borra el WAV que sigue reproduciéndose',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hermes-tts-playback-owner-',
      );
      final worker = _WaveWritingWorker(directory);
      final playRelease = Completer<void>();
      final playback = _Playback(playRelease: playRelease);
      final engine = OnDeviceNeuralTtsEngine(
        modelPath: 'unused.onnx',
        tokensPath: 'unused.tokens',
        dataDirPath: 'unused-data',
        playback: playback,
        playbackFactory: _Playback.new,
        debugWorkerFactory: (_) async => worker,
      );
      addTearDown(() async {
        if (!playRelease.isCompleted) playRelease.complete();
        await engine.dispose();
        if (directory.existsSync()) await directory.delete(recursive: true);
      });

      await engine.prewarm('Primera privada.');
      final speaking = engine.speak('Primera privada.');
      await playback.played.future;
      await engine.prewarm('Segunda privada.');

      expect(worker.waves, hasLength(2));
      expect(
        worker.waves.first.existsSync(),
        isTrue,
        reason: 'el owner de playback mantiene el WAV hasta onComplete',
      );

      playRelease.complete();
      await speaking;
      expect(worker.waves.first.existsSync(), isFalse);
      expect(worker.waves.last.existsSync(), isTrue);

      await engine.dispose();
      expect(worker.waves.last.existsSync(), isFalse);
    },
  );

  test('fallo de playFile limpia el WAV actual y el prefetch propio', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hermes-tts-play-error-',
    );
    final worker = _WaveWritingWorker(directory);
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: _FailingPlayback(),
      playbackFactory: _Playback.new,
      debugWorkerFactory: (_) async => worker,
    );
    addTearDown(() async {
      await engine.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final firstSentence = '${'A' * 241}.';

    await expectLater(
      engine.speak('$firstSentence Segunda privada.'),
      throwsStateError,
    );
    expect(worker.waves, hasLength(2), reason: 'el segundo WAV es el prefetch');

    await engine.dispose();
    expect(
      worker.waves.where((wave) => wave.existsSync()),
      isEmpty,
      reason: 'el error no puede abandonar audio actual ni prefetched',
    );
  });

  test('error de onComplete elimina el WAV antes de propagar fallo', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hermes-tts-completion-error-',
    );
    final waves = <File>[];
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: _CompletionFailingPlayback(),
      playbackFactory: _Playback.new,
      debugSynthesizer: (_, _) async => NeuralTtsAudio(
        samples: Float32List.fromList(<double>[0.2, -0.2, 0.2]),
        sampleRate: 16000,
      ),
      debugWaveWriter: (_, sequence) async {
        final wave = File('${directory.path}/writer_$sequence.wav');
        wave.writeAsBytesSync(<int>[82, 73, 70, 70], flush: true);
        waves.add(wave);
        return wave.path;
      },
    );
    addTearDown(() async {
      await engine.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    await expectLater(engine.speak('Audio privado.'), throwsStateError);
    expect(waves, hasLength(1));
    expect(waves.single.existsSync(), isFalse);
  });

  test('prewarm arranca el worker una vez y speak lo reutiliza', () async {
    var factoryCalls = 0;
    final synthesized = <String>[];
    final playback = _Playback();
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: playback,
      playbackFactory: () => _Playback(),
      debugWorkerFactory: (config) async {
        factoryCalls++;
        return _CountingWorker(synthesized.add);
      },
      debugWaveWriter: (audio, sequence) async =>
          '/tmp/hermes-pw-$sequence.wav',
    );
    addTearDown(engine.dispose);

    await engine.prewarm();
    expect(factoryCalls, 1);
    expect(playback.playCount, 0, reason: 'prewarm jamás reproduce audio');

    await engine.speak('Hola mundo.');
    expect(factoryCalls, 1, reason: 'speak reutiliza el worker precargado');
    expect(playback.playCount, greaterThan(0));
  });

  test('prewarm tras dispose no arranca ningún worker', () async {
    var factoryCalls = 0;
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: _Playback(),
      playbackFactory: _Playback.new,
      debugWorkerFactory: (config) async {
        factoryCalls++;
        return _CountingWorker((_) {});
      },
    );

    await engine.dispose();
    await engine.prewarm();

    expect(factoryCalls, 0);
  });

  test('prewarm con texto sintetiza al caché y speak lo consume', () async {
    var factoryCalls = 0;
    final synthesized = <String>[];
    final playback = _Playback();
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: playback,
      playbackFactory: () => _Playback(),
      debugWorkerFactory: (config) async {
        factoryCalls++;
        return _CountingWorker(synthesized.add);
      },
      debugWaveWriter: (audio, sequence) async =>
          '/tmp/hermes-pw-$sequence.wav',
    );
    addTearDown(engine.dispose);

    // `_sentences` agrupa frases cortas en un bloque ≤240 chars: el primer
    // elemento (y clave de caché) es ese bloque completo.
    await engine.prewarm('Primera frase. Segunda frase.');
    expect(factoryCalls, 1);
    expect(synthesized, ['Primera frase. Segunda frase.']);
    expect(playback.playCount, 0);

    await engine.speak('Primera frase. Segunda frase.');
    expect(synthesized, [
      'Primera frase. Segunda frase.',
    ], reason: 'speak consume el caché: cero síntesis duplicada');
    expect(playback.playCount, 1);
  });
}
