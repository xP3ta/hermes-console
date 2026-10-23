import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakePlayback implements TtsAudioPlayback {
  _FakePlayback({this.autoComplete = false, this.playRelease});

  final bool autoComplete;
  final Completer<void>? playRelease;
  final _completions = StreamController<void>.broadcast();
  final _playEvents = StreamController<int>.broadcast();
  int playCount = 0;
  int stopCount = 0;
  bool disposed = false;

  @override
  Stream<void> get onComplete => _completions.stream;

  @override
  Future<void> playBytes(Uint8List bytes, {required String mimeType}) async {
    await _played();
  }

  @override
  Future<void> playFile(String path) async {
    await _played();
  }

  Future<void> _played() async {
    playCount++;
    _playEvents.add(playCount);
    final release = playRelease;
    if (release != null) await release.future;
    if (autoComplete) scheduleMicrotask(complete);
  }

  void complete() => _completions.add(null);

  void completeError(Object error) => _completions.addError(error);

  Future<void> waitForPlayCount(int expected) async {
    if (playCount >= expected) return;
    await _playEvents.stream
        .firstWhere((count) => count >= expected)
        .timeout(const Duration(seconds: 1));
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  Future<void> close() async {
    await _completions.close();
    await _playEvents.close();
  }
}

class _FakeDeviceTtsPlatform implements DeviceTtsPlatform {
  final languagesRequested = Completer<void>();
  final languagesResponse = Completer<dynamic>();
  int speakCount = 0;
  String? requestedLocale;
  int stopCount = 0;

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> getLanguages() {
    if (!languagesRequested.isCompleted) languagesRequested.complete();
    return languagesResponse.future;
  }

  @override
  Future<dynamic> setEngine(String engine) async => 1;

  @override
  Future<dynamic> setLanguage(String language) async {
    requestedLocale = language;
    return 1;
  }

  @override
  Future<dynamic> speak(String text) async {
    speakCount++;
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    stopCount++;
    return 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('system TTS resolves all nine language records before speaking', () async {
    for (final locale in ['es-ES', 'en-US', 'pt-BR', 'de-DE', 'fr-FR', 'it-IT', 'ja-JP', 'ko-KR', 'zh-CN']) {
      final platform = _FakeDeviceTtsPlatform()
        ..languagesResponse.complete(['es-ES', 'en-US', locale]);
      final engine = DeviceTtsEngine(lang: locale, platform: platform);
      try {
        await engine.speak('test');
        expect(platform.requestedLocale, locale);
        expect(platform.speakCount, 1);
      } finally {
        await engine.dispose();
      }
    }
  });

  test(
    'ElevenLabs ignora la respuesta HTTP que llega después de stop',
    () async {
      final requested = Completer<void>();
      final release = Completer<void>();
      final playback = _FakePlayback(autoComplete: true);
      final replacement = _FakePlayback(autoComplete: true);
      final client = MockClient((_) async {
        requested.complete();
        await release.future;
        return http.Response.bytes([1, 2, 3], 200);
      });
      final engine = ElevenLabsTtsEngine(
        apiKey: 'key',
        voiceId: 'voice',
        modelId: 'model',
        client: client,
        playback: playback,
        playbackFactory: () => replacement,
      );
      addTearDown(() async {
        await engine.dispose();
        await playback.close();
        await replacement.close();
      });

      final speaking = engine.speak('texto antiguo');
      await requested.future;
      await engine.stop();
      release.complete();
      await speaking.timeout(const Duration(seconds: 1));

      expect(playback.playCount, 0);
    },
  );

  test('OpenAI/Kokoro no resucita el speak viejo tras stop → speak', () async {
    final oldRequested = Completer<void>();
    final releaseOld = Completer<void>();
    final initialPlayback = _FakePlayback();
    final freshPlayback = _FakePlayback();
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['input'] == 'antiguo') {
        oldRequested.complete();
        await releaseOld.future;
      }
      return http.Response.bytes([1, 2, 3], 200);
    });
    final engine = OpenAiStreamingTtsEngine(
      baseUrl: 'http://192.168.1.20:8880/v1',
      voice: 'voice',
      model: 'model',
      client: client,
      playback: initialPlayback,
      playbackFactory: () => freshPlayback,
    );
    addTearDown(() async {
      await engine.dispose();
      await initialPlayback.close();
      await freshPlayback.close();
    });

    final oldSpeak = engine.speak('antiguo');
    await oldRequested.future;
    await engine.stop();
    final newSpeak = engine.speak('nuevo');
    await freshPlayback.waitForPlayCount(1);
    releaseOld.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    try {
      expect(initialPlayback.playCount + freshPlayback.playCount, 1);
    } finally {
      freshPlayback.complete();
      await Future.wait([
        oldSpeak,
        newSpeak,
      ]).timeout(const Duration(seconds: 1));
    }
  });

  test('REST personalizado ignora trabajo HTTP después de dispose', () async {
    final requested = Completer<void>();
    final release = Completer<void>();
    final playback = _FakePlayback(autoComplete: true);
    final replacement = _FakePlayback(autoComplete: true);
    final client = MockClient((_) async {
      requested.complete();
      await release.future;
      return http.Response.bytes(
        [1, 2, 3],
        200,
        headers: const {'content-type': 'audio/mpeg'},
      );
    });
    final engine = CustomHttpTtsEngine(
      url: 'https://tts.example.com/speak',
      bodyTemplate: '{"text":"{{text}}"}',
      client: client,
      playback: playback,
      playbackFactory: () => replacement,
    );
    addTearDown(() async {
      await playback.close();
      await replacement.close();
    });

    final speaking = engine.speak('texto antiguo');
    await requested.future;
    await engine.dispose();
    release.complete();
    await speaking.timeout(const Duration(seconds: 1));

    expect(playback.playCount, 0);
  });

  test(
    'REST personalizado no resucita el request viejo tras stop → speak',
    () async {
      final oldRequested = Completer<void>();
      final releaseOld = Completer<void>();
      final initialPlayback = _FakePlayback();
      final freshPlayback = _FakePlayback();
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['text'] == 'antiguo') {
          oldRequested.complete();
          await releaseOld.future;
        }
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: const {'content-type': 'audio/mpeg'},
        );
      });
      final engine = CustomHttpTtsEngine(
        url: 'https://tts.example.com/speak',
        bodyTemplate: '{"text":"{{text}}"}',
        client: client,
        playback: initialPlayback,
        playbackFactory: () => freshPlayback,
      );
      addTearDown(() async {
        await engine.dispose();
        await initialPlayback.close();
        await freshPlayback.close();
      });

      final oldSpeak = engine.speak('antiguo');
      await oldRequested.future;
      await engine.stop();
      final newSpeak = engine.speak('nuevo');
      await freshPlayback.waitForPlayCount(1);
      releaseOld.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      try {
        expect(initialPlayback.playCount + freshPlayback.playCount, 1);
      } finally {
        freshPlayback.complete();
        await Future.wait([
          oldSpeak,
          newSpeak,
        ]).timeout(const Duration(seconds: 1));
      }
    },
  );

  test('TTS neuronal no resucita síntesis vieja tras stop → speak', () async {
    final oldRequested = Completer<void>();
    final releaseOld = Completer<void>();
    final initialPlayback = _FakePlayback();
    final freshPlayback = _FakePlayback();
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: initialPlayback,
      playbackFactory: () => freshPlayback,
      debugSynthesizer: (text, _) async {
        if (text == 'antiguo') {
          oldRequested.complete();
          await releaseOld.future;
        }
        return NeuralTtsAudio(
          samples: Float32List.fromList([0.2, -0.2]),
          sampleRate: 16000,
        );
      },
      debugWaveWriter: (_, sequence) async => '/tmp/fake-$sequence.wav',
    );
    addTearDown(() async {
      await engine.dispose();
      await initialPlayback.close();
      await freshPlayback.close();
    });

    final oldSpeak = engine.speak('antiguo');
    await oldRequested.future;
    await engine.stop();
    final newSpeak = engine.speak('nuevo');
    await freshPlayback.waitForPlayCount(1);
    releaseOld.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    try {
      expect(initialPlayback.playCount + freshPlayback.playCount, 1);
    } finally {
      freshPlayback.complete();
      await Future.wait([
        oldSpeak,
        newSpeak,
      ]).timeout(const Duration(seconds: 1));
    }
  });

  test(
    'TTS del sistema no habla si stop ocurre durante inicialización',
    () async {
      final platform = _FakeDeviceTtsPlatform();
      final engine = DeviceTtsEngine(platform: platform);

      final speaking = engine.speak('texto antiguo');
      await platform.languagesRequested.future;
      await engine.stop();
      platform.languagesResponse.complete(['es-ES']);
      await speaking.timeout(const Duration(seconds: 1));

      expect(platform.speakCount, 0);
    },
  );

  test('ElevenLabs aísla el play viejo bloqueado del turno nuevo', () async {
    final oldRelease = Completer<void>();
    final oldPlayback = _FakePlayback(playRelease: oldRelease);
    final newPlayback = _FakePlayback();
    final engine = ElevenLabsTtsEngine(
      apiKey: 'key',
      voiceId: 'voice',
      modelId: 'model',
      client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
      playback: oldPlayback,
      playbackFactory: () => newPlayback,
    );
    addTearDown(() async {
      if (!oldRelease.isCompleted) oldRelease.complete();
      await engine.dispose();
      await oldPlayback.close();
      await newPlayback.close();
    });

    final oldSpeak = engine.speak('antiguo');
    await oldPlayback.waitForPlayCount(1);
    await engine.stop();
    var newDone = false;
    final newSpeak = engine.speak('nuevo').whenComplete(() => newDone = true);
    await newPlayback.waitForPlayCount(1);

    await oldSpeak.timeout(const Duration(seconds: 1));
    oldRelease.complete();
    oldPlayback.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(newDone, isFalse);
    expect(oldPlayback.disposed, isTrue);
    expect(newPlayback.disposed, isFalse);

    newPlayback.complete();
    await newSpeak.timeout(const Duration(seconds: 1));
  });

  test('REST aísla el play viejo bloqueado del turno nuevo', () async {
    final oldRelease = Completer<void>();
    final oldPlayback = _FakePlayback(playRelease: oldRelease);
    final newPlayback = _FakePlayback();
    final engine = CustomHttpTtsEngine(
      url: 'https://tts.example.com/speak',
      bodyTemplate: '{"text":"{{text}}"}',
      client: MockClient(
        (_) async => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: const {'content-type': 'audio/mpeg'},
        ),
      ),
      playback: oldPlayback,
      playbackFactory: () => newPlayback,
    );
    addTearDown(() async {
      if (!oldRelease.isCompleted) oldRelease.complete();
      await engine.dispose();
      await oldPlayback.close();
      await newPlayback.close();
    });

    final oldSpeak = engine.speak('antiguo');
    await oldPlayback.waitForPlayCount(1);
    await engine.stop();
    var newDone = false;
    final newSpeak = engine.speak('nuevo').whenComplete(() => newDone = true);
    await newPlayback.waitForPlayCount(1);

    await oldSpeak.timeout(const Duration(seconds: 1));
    oldRelease.complete();
    oldPlayback.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(newDone, isFalse);
    expect(oldPlayback.disposed, isTrue);
    expect(newPlayback.disposed, isFalse);

    newPlayback.complete();
    await newSpeak.timeout(const Duration(seconds: 1));
  });

  test('TTS neuronal aísla el play viejo bloqueado del turno nuevo', () async {
    final oldRelease = Completer<void>();
    final oldPlayback = _FakePlayback(playRelease: oldRelease);
    final newPlayback = _FakePlayback();
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: oldPlayback,
      playbackFactory: () => newPlayback,
      debugSynthesizer: (_, _) async => NeuralTtsAudio(
        samples: Float32List.fromList([0.2, -0.2]),
        sampleRate: 16000,
      ),
      debugWaveWriter: (_, sequence) async => '/tmp/fake-$sequence.wav',
    );
    addTearDown(() async {
      if (!oldRelease.isCompleted) oldRelease.complete();
      await engine.dispose();
      await oldPlayback.close();
      await newPlayback.close();
    });

    final oldSpeak = engine.speak('antiguo');
    await oldPlayback.waitForPlayCount(1);
    await engine.stop();
    var newDone = false;
    final newSpeak = engine.speak('nuevo').whenComplete(() => newDone = true);
    await newPlayback.waitForPlayCount(1);

    await oldSpeak.timeout(const Duration(seconds: 1));
    oldRelease.complete();
    oldPlayback.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(newDone, isFalse);
    expect(oldPlayback.disposed, isTrue);
    expect(newPlayback.disposed, isFalse);

    newPlayback.complete();
    await newSpeak.timeout(const Duration(seconds: 1));
  });

  test('TTS neuronal vuelve a sintetizar la misma frase tras stop', () async {
    final oldPlayback = _FakePlayback();
    final resumedPlayback = _FakePlayback();
    var synthesisCount = 0;
    final engine = OnDeviceNeuralTtsEngine(
      modelPath: 'unused.onnx',
      tokensPath: 'unused.tokens',
      dataDirPath: 'unused-data',
      playback: oldPlayback,
      playbackFactory: () => resumedPlayback,
      debugSynthesizer: (_, _) async {
        synthesisCount++;
        return NeuralTtsAudio(
          samples: Float32List.fromList([0.2, -0.2]),
          sampleRate: 16000,
        );
      },
      debugWaveWriter: (_, sequence) async => '/tmp/fake-$sequence.wav',
    );
    addTearDown(() async {
      await engine.dispose();
      await oldPlayback.close();
      await resumedPlayback.close();
    });

    final first = engine.speak('la misma frase');
    await oldPlayback.waitForPlayCount(1);
    await engine.stop();
    await first.timeout(const Duration(seconds: 1));

    final resumed = engine.speak('la misma frase');
    await resumedPlayback.waitForPlayCount(1);
    expect(synthesisCount, 2);

    resumedPlayback.complete();
    await resumed.timeout(const Duration(seconds: 1));
  });

  test('un error de onComplete se propaga al fallback del llamador', () async {
    final playback = _FakePlayback();
    final engine = CustomHttpTtsEngine(
      url: 'https://tts.example.com/speak',
      bodyTemplate: '{"text":"{{text}}"}',
      client: MockClient(
        (_) async => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: const {'content-type': 'audio/mpeg'},
        ),
      ),
      playback: playback,
      playbackFactory: _FakePlayback.new,
    );
    addTearDown(() async {
      await engine.dispose();
      await playback.close();
    });

    final speaking = engine.speak('texto');
    await playback.waitForPlayCount(1);
    playback.completeError(StateError('decoder failed'));

    await expectLater(
      speaking,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'decoder failed',
        ),
      ),
    );
  });

  test(
    'timeout de A rota el player y completion tardío no completa B',
    () async {
      final timedOutPlayback = _FakePlayback();
      final freshPlayback = _FakePlayback();
      final engine = OnDeviceNeuralTtsEngine(
        modelPath: 'unused.onnx',
        tokensPath: 'unused.tokens',
        dataDirPath: 'unused-data',
        playback: timedOutPlayback,
        playbackFactory: () => freshPlayback,
        debugSynthesizer: (_, _) async => NeuralTtsAudio(
          samples: Float32List.fromList([0.2, -0.2]),
          sampleRate: 16000,
        ),
        debugWaveWriter: (_, sequence) async => '/tmp/fake-$sequence.wav',
      );
      addTearDown(() async {
        await engine.dispose();
        await timedOutPlayback.close();
        await freshPlayback.close();
      });

      await engine.speak('A').timeout(const Duration(seconds: 1));
      expect(timedOutPlayback.disposed, isTrue);

      var bDone = false;
      final speakingB = engine.speak('B').whenComplete(() => bDone = true);
      await freshPlayback.waitForPlayCount(1);
      timedOutPlayback.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bDone, isFalse);
      expect(freshPlayback.disposed, isFalse);
      freshPlayback.complete();
      await speakingB.timeout(const Duration(seconds: 1));
    },
  );

  test('un playback inyectado exige factory explícita para rotar', () async {
    final playback = _FakePlayback();
    addTearDown(playback.close);

    expect(
      () => ElevenLabsTtsEngine(
        apiKey: 'key',
        voiceId: 'voice',
        modelId: 'model',
        client: MockClient((_) async => http.Response('', 200)),
        playback: playback,
      ),
      throwsArgumentError,
    );
  });
}
