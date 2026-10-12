import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/conversation/full_duplex_barge_in_monitor.dart';
import 'package:hermes_android/core/services/voice/voice_latency_trace.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCaptureSource implements FullDuplexCaptureSource {
  final audio = StreamController<Uint8List>.broadcast();
  bool active = true;
  bool permission = true;
  int starts = 0;
  int stops = 0;
  int transcriptions = 0;
  bool playbackActive = false;
  Uint8List? lastWav;
  Completer<String>? heldTranscription;
  String transcript = 'interjection';
  FullDuplexPlaybackSafety safety = const FullDuplexPlaybackSafety(
    aecEnabled: false,
    privateOutput: false,
    playbackSafe: false,
  );

  @override
  bool get transcriptionAvailable => active;

  @override
  Future<bool> hasPermission() async => permission;

  /// What the next [start] answers instead of a stream.
  Object? startError;

  /// Holds [start] open, like Android while it configures the capture; a
  /// [stop] meanwhile makes it fail, as a superseded native request does.
  Completer<void>? startGate;
  bool _starting = false;

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    final error = startError;
    if (error != null) throw error;
    final gate = startGate;
    if (gate != null) {
      _starting = true;
      try {
        await gate.future;
      } finally {
        _starting = false;
      }
    }
    return audio.stream;
  }

  @override
  Future<void> setPlaybackActive(bool active) async {
    playbackActive = active;
  }

  @override
  Future<FullDuplexPlaybackSafety> playbackSafety() async => safety;

  @override
  Future<void> stop() async {
    stops++;
    final gate = startGate;
    if (_starting && gate != null && !gate.isCompleted) {
      gate.completeError(
        PlatformException(
          code: 'capture_configure_failed',
          message: 'Capture request was superseded',
        ),
      );
    }
  }

  @override
  Future<String> transcribe(Uint8List wavBytes) async {
    transcriptions++;
    lastWav = wavBytes;
    return heldTranscription?.future ?? transcript;
  }

  @override
  Future<void> dispose() async {
    if (!audio.isClosed) await audio.close();
  }
}

Uint8List _pcmFrame(int amplitude) {
  const samples = 480;
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return bytes;
}

Future<void> _emit(_FakeCaptureSource source, int amplitude, int frames) async {
  for (var i = 0; i < frames; i++) {
    source.audio.add(_pcmFrame(amplitude));
  }
  await _settle();
}

Future<void> _emitEnvelope(
  _FakeCaptureSource source,
  List<int> amplitudes,
) async {
  for (final amplitude in amplitudes) {
    source.audio.add(_pcmFrame(amplitude));
  }
  await _settle();
}

Future<void> _settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeMethod = MethodChannel('hermes/full_duplex_capture');
  const nativeEvents = EventChannel('hermes/full_duplex_capture_events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(nativeMethod, null);
    messenger.setMockStreamHandler(nativeEvents, null);
  });

  test('armed waits for RECORDSTATE_RECORDING ready ACK', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final voice = VoiceService(
      await SharedPreferences.getInstance(),
      SecureStorage(),
    );
    voice.enableNativeVoice(
      speak: (_) async => <String, Object?>{'ok': true},
      transcribe: (_, _) async => <String, Object?>{
        'ok': true,
        'transcript': 'continua',
      },
    );

    const generation = 71;
    final listenEntered = Completer<void>();
    MockStreamHandlerEventSink? nativeSink;
    messenger.setMockMethodCallHandler(nativeMethod, (call) async {
      return switch (call.method) {
        'hasPermission' => true,
        'start' => <String, Object?>{
          'generation': generation,
          'aecEnabled': true,
          'privateOutput': false,
          'playbackSafe': true,
        },
        'getPlaybackSafety' => <String, Object?>{
          'generation': generation,
          'aecEnabled': true,
          'privateOutput': false,
          'playbackSafe': true,
        },
        'stop' || 'dispose' || 'ack' || 'setPlaybackActive' => null,
        _ => throw MissingPluginException(call.method),
      };
    });
    messenger.setMockStreamHandler(
      nativeEvents,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          nativeSink = events;
          if (!listenEntered.isCompleted) listenEntered.complete();
        },
      ),
    );

    final monitor = FullDuplexBargeInMonitor(
      source: VoiceServiceFullDuplexCaptureSource(voice),
    );
    addTearDown(() async {
      await monitor.dispose();
      await voice.dispose();
    });

    final armed = monitor.arm(onSpeechStart: () {}, onTranscript: (_) async {});
    await listenEntered.future.timeout(const Duration(seconds: 1));
    await _settle();

    expect(
      monitor.armed,
      isFalse,
      reason: 'configurar AudioRecord no demuestra que ya este grabando',
    );

    nativeSink!.success(<String, Object?>{
      'type': 'ready',
      'generation': generation,
      'aecEnabled': true,
      'privateOutput': false,
      'playbackSafe': true,
    });
    expect(await armed.timeout(const Duration(seconds: 1)), isTrue);
    expect(monitor.armed, isTrue);
  });

  test('native ready ACK is emitted only after recording state is proven', () {
    final native = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesFullDuplexCaptureHandler.kt',
    ).readAsStringSync();
    final start = native.indexOf('current.recorder.startRecording()');
    final state = native.indexOf(
      'current.recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING',
      start,
    );
    final ready = native.indexOf('emitReady(current)', state);

    expect(start, greaterThanOrEqualTo(0));
    expect(state, greaterThan(start));
    expect(ready, greaterThan(state));
  });

  test('speaker AEC cannot authorize playback barge-in', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final voice = VoiceService(
      await SharedPreferences.getInstance(),
      SecureStorage(),
    );
    messenger.setMockMethodCallHandler(nativeMethod, (call) async {
      if (call.method == 'getPlaybackSafety') {
        return <String, Object?>{
          'aecEnabled': true,
          'noiseSuppressionEnabled': true,
          'privateOutput': false,
          // Reproduce the stale native verdict observed on the Pixel.
          'playbackSafe': true,
        };
      }
      throw MissingPluginException(call.method);
    });
    final source = VoiceServiceFullDuplexCaptureSource(voice);
    addTearDown(() async {
      await source.dispose();
      await voice.dispose();
    });

    final safety = await source.playbackSafety();

    expect(safety.aecEnabled, isTrue);
    expect(safety.noiseSuppressionEnabled, isTrue);
    expect(safety.privateOutput, isFalse);
    expect(safety.playbackSafe, isFalse);
  });

  test('native safety requires the exact private output route', () {
    final native = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesFullDuplexCaptureHandler.kt',
    ).readAsStringSync();

    expect(native, contains('"playbackSafe" to privateOutput'));
    expect(
      native,
      isNot(contains('"playbackSafe" to (aecLive || privateOutput)')),
    );
  });

  test('native start error before ready is propagated and torn down', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final voice = VoiceService(
      await SharedPreferences.getInstance(),
      SecureStorage(),
    );
    const generation = 72;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(nativeMethod, (call) async {
      calls.add(call);
      return switch (call.method) {
        'start' => <String, Object?>{'generation': generation},
        'stop' || 'dispose' => null,
        _ => throw MissingPluginException(call.method),
      };
    });
    messenger.setMockStreamHandler(
      nativeEvents,
      MockStreamHandler.inline(
        onListen: (_, events) {
          scheduleMicrotask(
            () => events.error(
              code: 'capture_start_failed',
              message: 'AudioRecord did not enter recording state',
              details: <String, Object?>{'generation': generation},
            ),
          );
        },
      ),
    );
    final source = VoiceServiceFullDuplexCaptureSource(voice);
    addTearDown(() async {
      await source.dispose();
      await voice.dispose();
    });

    await expectLater(
      source.start(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'capture_start_failed',
        ),
      ),
    );
    expect(calls.where((call) => call.method == 'stop'), isNotEmpty);
  });

  test('missing ready ACK times out and stops the same generation', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final voice = VoiceService(
      await SharedPreferences.getInstance(),
      SecureStorage(),
    );
    const generation = 73;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(nativeMethod, (call) async {
      calls.add(call);
      return switch (call.method) {
        'start' => <String, Object?>{'generation': generation},
        'stop' || 'dispose' => null,
        _ => throw MissingPluginException(call.method),
      };
    });
    messenger.setMockStreamHandler(
      nativeEvents,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    final source = VoiceServiceFullDuplexCaptureSource(
      voice,
      readyTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(() async {
      await source.dispose();
      await voice.dispose();
    });

    await expectLater(source.start(), throwsA(isA<TimeoutException>()));
    final stop = calls.lastWhere((call) => call.method == 'stop');
    expect((stop.arguments as Map)['generation'], generation);
  });

  test('stop cancels pending ready and ignores its stale event', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final voice = VoiceService(
      await SharedPreferences.getInstance(),
      SecureStorage(),
    );
    const generation = 74;
    final listenEntered = Completer<void>();
    final calls = <MethodCall>[];
    MockStreamHandlerEventSink? nativeSink;
    messenger.setMockMethodCallHandler(nativeMethod, (call) async {
      calls.add(call);
      return switch (call.method) {
        'start' => <String, Object?>{'generation': generation},
        'stop' || 'dispose' => null,
        _ => throw MissingPluginException(call.method),
      };
    });
    messenger.setMockStreamHandler(
      nativeEvents,
      MockStreamHandler.inline(
        onListen: (_, events) {
          nativeSink = events;
          if (!listenEntered.isCompleted) listenEntered.complete();
        },
      ),
    );
    final source = VoiceServiceFullDuplexCaptureSource(voice);
    addTearDown(() async {
      await source.dispose();
      await voice.dispose();
    });

    final starting = source.start();
    final cancelled = expectLater(starting, throwsA(anything));
    await listenEntered.future.timeout(const Duration(seconds: 1));
    await source.stop();
    nativeSink!.success(<String, Object?>{
      'type': 'ready',
      'generation': generation,
    });
    await cancelled;

    final stop = calls.lastWhere((call) => call.method == 'stop');
    expect((stop.arguments as Map)['generation'], generation);
  });

  test(
    'a compatible transcription engine and permission are required',
    () async {
      final source = _FakeCaptureSource()..active = false;
      final monitor = FullDuplexBargeInMonitor(source: source);

      expect(
        await monitor.arm(onSpeechStart: () {}, onTranscript: (_) async {}),
        isFalse,
      );
      expect(source.starts, 0);

      source.active = true;
      source.permission = false;
      expect(
        await monitor.arm(onSpeechStart: () {}, onTranscript: (_) async {}),
        isFalse,
      );
      expect(source.starts, 0);
      await monitor.dispose();
    },
  );

  test(
    'an unsafe Kotlin verdict disarms playback barge-in fail-closed',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: false,
          playbackSafe: false,
        ),
      );
      addTearDown(monitor.dispose);
      var starts = 0;
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (_) async {},
      );

      await _emit(source, 70, 20);
      expect(await monitor.setPlaybackActive(true), isFalse);

      // AEC vivo sigue siendo solo diagnóstico. Sin salida privada, el monitor
      // debe impedir el corte antes de que el eco llegue al guard de similitud.
      await _emit(source, 7381, 40);
      expect(starts, 0);
      expect(source.transcriptions, 0);
      expect(monitor.active, isFalse);
      expect(source.stops, greaterThanOrEqualTo(1));

      expect(await monitor.setPlaybackActive(false), isTrue);
      expect(source.playbackActive, isFalse);
    },
  );

  test(
    'exact 1365 RMS playback fixture stays below the Desktop gate',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: true,
          playbackSafe: true,
        ),
      );
      addTearDown(monitor.dispose);
      var starts = 0;
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (_) async {},
      );

      await _emit(source, 70, 20);
      expect(await monitor.setPlaybackActive(true), isTrue);

      // Fixture contractual sintético: incluso sostenido y una vez agotada la
      // gracia inicial, 1.365 RMS permanece por debajo del mínimo de playback
      // 1.505,28. La evidencia acústica del Pixel se valida por separado.
      await _emit(source, 1365, 40);

      expect(starts, 0);
      expect(source.transcriptions, 0);
      expect(monitor.armed, isTrue);
    },
  );

  test(
    'Desktop monitor detects speech during generation before playback',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(source: source);
      addTearDown(monitor.dispose);
      var starts = 0;
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (_) async {},
      );

      await _emit(source, 70, 20);
      await _emit(source, 1000, 10);

      expect(starts, 1);
    },
  );

  test(
    'Desktop generation gate captures sustained speech before playback',
    () async {
      final source = _FakeCaptureSource()
        ..heldTranscription = Completer<String>();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: false,
          privateOutput: true,
          playbackSafe: true,
        ),
      );
      var starts = 0;
      final transcripts = <String?>[];
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (text) async => transcripts.add(text),
      );

      // Desktop keeps the monitor live while the model generates. A 497 RMS
      // median produces a 1739.5 RMS dynamic trigger (497 * 3.5).
      await _emit(source, 497, 42);
      await _emit(source, 1835, 12);
      expect(starts, 1);
      expect(source.transcriptions, 0);
      expect(transcripts, isEmpty);

      await _emit(source, 1300, 4);
      // Igual que Desktop: el endpoint usa su umbral de voz propio y termina
      // tras 42 bloques (~1,26 s), sin reutilizar el suelo de calibración.
      await _emit(source, 600, 41);
      expect(source.transcriptions, 0);
      await _emit(source, 600, 1);
      expect(source.transcriptions, 1);
      expect(transcripts, isEmpty);

      source.heldTranscription!.complete('turno nuevo');
      await _settle();
      expect(transcripts, ['turno nuevo']);
      expect(source.lastWav, isNotNull);
      expect(String.fromCharCodes(source.lastWav!.take(4)), 'RIFF');
      expect(source.lastWav!.length, greaterThan(44 + (20 * 480 * 2)));
      await monitor.dispose();
    },
  );

  test(
    'late onset preserves roughly five seconds of PCM before detection',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: true,
          playbackSafe: true,
        ),
      );
      addTearDown(monitor.dispose);
      var starts = 0;
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (_) async {},
      );

      await _emit(source, 80, 20);
      await monitor.setPlaybackActive(true);
      await _emit(source, 120, 17); // playback grace
      // El ring PCM conserva cinco segundos aunque el onset llegue tarde.
      await _emit(source, 500, 150);
      await _emit(source, 1800, 10);
      expect(starts, 1);

      // Desktop termina al acumular ~1,25 s por debajo de 0.075 (~806 RMS).
      await _emit(source, 600, 42);
      expect(source.transcriptions, 1);

      final pcmFrames = (source.lastWav!.length - 44) ~/ (480 * 2);
      expect(
        pcmFrames,
        greaterThanOrEqualTo(209),
        reason: '166-167 bloques de pre-roll más el endpoint deben sobrevivir',
      );
    },
  );

  test('generation uses Desktop median floor and 3.5 multiplier', () async {
    final source = _FakeCaptureSource();
    final monitor = FullDuplexBargeInMonitor(
      source: source,
      playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
        aecEnabled: false,
        privateOutput: false,
        playbackSafe: false,
      ),
    );
    var starts = 0;
    final transcripts = <String?>[];
    await monitor.arm(
      onSpeechStart: () => starts++,
      onTranscript: (text) async => transcripts.add(text),
    );

    // 1700 queda bajo 497 * 3.5; 1835 lo supera de forma sostenida.
    await _emit(source, 497, 42);
    await _emit(source, 1700, 12);
    expect(starts, 0);
    expect(source.transcriptions, 0);

    await _emit(source, 1835, 10);
    expect(starts, 1);
    await _emit(source, 0, 42);

    expect(source.transcriptions, 1);
    expect(transcripts, ['interjection']);
    await monitor.dispose();
  });

  test(
    'full-duplex publica última voz, endpoint y comienzo STT en orden',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(source: source);
      addTearDown(monitor.dispose);
      final records = <VoiceLatencyRecord>[];
      var nowMicros = 1000;
      final trace = VoiceLatencyTrace.testing(
        runId: '1029384756abcdef',
        nowMicros: () => nowMicros,
        onRecord: records.add,
      );
      late VoiceLatencyTurn turn;

      await trace.runScoped(() async {
        await monitor.arm(
          onSpeechStart: () {
            turn = trace.beginTurn(
              route: VoiceLatencyRoute.phone,
              scenario: VoiceLatencyScenario.bargeIn,
              sttTopology: VoiceSttTopology.recordThenTranscribe,
              lastAboveAvailability: VoiceLatencyAvailability.measured,
            );
          },
          onSpeechAboveThreshold: () {
            nowMicros += 30000;
            turn.observeSpeechAboveThreshold();
          },
          onSpeechEndpoint: () {
            nowMicros += 1260000;
            turn.mark(VoiceLatencyPoint.speechEndpoint);
          },
          onTranscriptionStart: () {
            nowMicros += 1;
            turn.mark(VoiceLatencyPoint.sttStarted);
          },
          onTranscript: (_) async {},
        );

        await _emit(source, 80, 20);
        await _emit(source, 1800, 10);
        await _emit(source, 1800, 2);
        await _emit(source, 0, 42);
        await _settle();
      });

      final points = records.map((record) => record.point).toList();
      expect(
        points,
        containsAllInOrder(const <VoiceLatencyPoint>[
          VoiceLatencyPoint.speechLastAboveThreshold,
          VoiceLatencyPoint.speechEndpoint,
          VoiceLatencyPoint.sttStarted,
        ]),
      );
      expect(
        records.where(
          (record) =>
              record.point == VoiceLatencyPoint.speechLastAboveThreshold,
        ),
        hasLength(1),
      );
    },
  );

  test('a short near-field envelope cannot bypass Desktop majority', () async {
    final source = _FakeCaptureSource();
    final monitor = FullDuplexBargeInMonitor(
      source: source,
      playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
        aecEnabled: true,
        privateOutput: false,
        playbackSafe: false,
      ),
    );
    addTearDown(monitor.dispose);
    var starts = 0;
    await monitor.arm(
      onSpeechStart: () => starts++,
      onTranscript: (_) async {},
    );

    await _emit(source, 950, 20);
    await _emitEnvelope(source, <int>[
      1300,
      1700,
      2100,
      6698,
      2600,
      1800,
      1500,
      2200,
      1400,
      900,
    ]);

    expect(starts, 0);
  });

  test('a single low-gain peak is not sustained generation speech', () async {
    final source = _FakeCaptureSource();
    final monitor = FullDuplexBargeInMonitor(source: source);
    addTearDown(monitor.dispose);
    var starts = 0;
    await monitor.arm(
      onSpeechStart: () => starts++,
      onTranscript: (_) async {},
    );

    // En la repetición física, VOICE_COMMUNICATION dejó el ambiente en 200
    // RMS y la voz cercana sólo alcanzó 856 RMS antes del primer TTS.
    await _emit(source, 200, 20);
    await _emitEnvelope(source, <int>[
      210,
      360,
      430,
      520,
      856,
      710,
      620,
      470,
      410,
      300,
    ]);

    expect(starts, 0);
  });

  test(
    'playback holds the quiet floor instead of learning speaker bleed',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: true,
          playbackSafe: true,
        ),
      );
      addTearDown(monitor.dispose);
      var starts = 0;
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (_) async {},
      );

      // Desktop congela el suelo de 950 RMS durante playback: el trigger queda
      // en 3325 RMS y nunca se recalibra con el residuo del altavoz.
      await _emit(source, 950, 20);
      await monitor.setPlaybackActive(true);
      await _emit(source, 30, 20);
      await _emit(source, 3000, 10);
      expect(starts, 0);
      await _emit(source, 3500, 10);

      expect(starts, 1);
    },
  );

  test('an isolated Pixel-level spike is not treated as speech', () async {
    final source = _FakeCaptureSource();
    final monitor = FullDuplexBargeInMonitor(source: source);
    addTearDown(monitor.dispose);
    var starts = 0;
    await monitor.arm(
      onSpeechStart: () => starts++,
      onTranscript: (_) async {},
    );

    await _emit(source, 950, 20);
    await _emitEnvelope(source, <int>[
      950,
      950,
      950,
      6698,
      950,
      950,
      950,
      950,
      950,
      950,
    ]);

    expect(starts, 0);
  });

  test(
    'monitor remains live between playback chunks during the same turn',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: true,
          playbackSafe: true,
        ),
      );
      var starts = 0;
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (_) async {},
      );
      await _emit(source, 80, 42);

      await monitor.setPlaybackActive(true);
      await monitor.setPlaybackActive(false);
      await _emit(source, 80, 35);
      await _emit(source, 1800, 12);

      expect(starts, 1);
      expect(source.transcriptions, 0);
      await monitor.dispose();
    },
  );

  test('speaker playback rejects an enabled but unproven AEC', () async {
    final source = _FakeCaptureSource();
    final monitor = FullDuplexBargeInMonitor(
      source: source,
      playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
        aecEnabled: true,
        privateOutput: false,
        playbackSafe: false,
      ),
    );
    await monitor.setPlaybackActive(true);

    expect(
      await monitor.arm(onSpeechStart: () {}, onTranscript: (_) async {}),
      isFalse,
    );
    // The safety proof belongs to the newly-created recorder session, so the
    // source is configured once and immediately torn down before it can arm.
    expect(source.starts, 1);
    expect(source.stops, greaterThanOrEqualTo(1));
    expect(monitor.active, isFalse);
    await monitor.dispose();
  });

  test(
    'unsafe latch is not sticky: stopping playback re-probes the route',
    () async {
      final source = _FakeCaptureSource();
      var unsafe = true;
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => FullDuplexPlaybackSafety(
          aecEnabled: unsafe,
          privateOutput: false,
          playbackSafe: !unsafe,
        ),
      );
      addTearDown(monitor.dispose);

      expect(
        await monitor.arm(onSpeechStart: () {}, onTranscript: (_) async {}),
        isTrue,
      );
      expect(source.starts, 1);
      expect(await monitor.setPlaybackActive(true), isFalse);
      expect(source.playbackActive, isFalse);
      expect(monitor.playbackUnsafeLatched, isTrue);

      // Al parar la reproducción el latch se suelta: el siguiente arm vuelve a
      // sondear la ruta en vez de quedar desarmado hasta una nueva entrada.
      await monitor.setPlaybackActive(false);
      expect(monitor.playbackUnsafeLatched, isFalse);
      expect(
        await monitor.arm(onSpeechStart: () {}, onTranscript: (_) async {}),
        isTrue,
      );
      expect(source.starts, 2);

      // Una salida privada demostrada permite el barge-in en la misma sesión
      // sin esperar a otra entrada de voz.
      unsafe = false;
      expect(await monitor.setPlaybackActive(true), isTrue);
      expect(monitor.armed, isTrue);
    },
  );

  group('a speaker without echo cancellation', () {
    const speaker = FullDuplexPlaybackSafety(
      aecEnabled: false,
      privateOutput: false,
      playbackSafe: false,
    );

    Future<List<String>> logged(Future<void> Function() body) async {
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      try {
        await body();
      } finally {
        debugPrint = original;
      }
      return lines;
    }

    test('cancels the capture that was opening without an error', () async {
      final source = _FakeCaptureSource()..startGate = Completer<void>();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => speaker,
      );
      addTearDown(monitor.dispose);

      late bool armed;
      late bool playbackAccepted;
      final lines = await logged(() async {
        // As on the phone: Hermes starts talking while the monitor's
        // capture is still opening.
        final arming = monitor.arm(
          onSpeechStart: () {},
          onTranscript: (_) async {},
        );
        await _settle();
        expect(source.starts, 1);
        playbackAccepted = await monitor.setPlaybackActive(true);
        armed = await arming;
      });

      expect(playbackAccepted, isFalse);
      expect(armed, isFalse);
      expect(monitor.active, isFalse);
      expect(monitor.playbackUnsafeLatched, isTrue);
      // Expected and quiet: the cancelled start is not reported as a failure.
      expect(lines.where((line) => line.contains('arm_failed')), isEmpty);
      expect(lines.where((line) => line.contains('Exception')), isEmpty);
      expect(
        lines.where((line) => line.contains('voice.barge.arm cancelled')),
        hasLength(1),
      );
      expect(
        lines.where((line) => line.contains('barge.unsafe_playback_route')),
        hasLength(1),
      );

      // Once Hermes stops talking the route is probed again.
      await monitor.setPlaybackActive(false);
      expect(monitor.playbackUnsafeLatched, isFalse);
    });

    test("takes Android's refusal to open the capture as the same "
        'verdict', () async {
      final source = _FakeCaptureSource()
        ..startError = PlatformException(
          code: 'unsafe_playback_route',
          message: 'Playback has no proven echo cancellation',
        );
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => speaker,
      );
      addTearDown(monitor.dispose);

      late bool armed;
      final lines = await logged(() async {
        armed = await monitor.arm(
          onSpeechStart: () {},
          onTranscript: (_) async {},
        );
      });

      expect(armed, isFalse);
      expect(monitor.active, isFalse);
      expect(monitor.playbackUnsafeLatched, isTrue);
      expect(source.stops, greaterThanOrEqualTo(1));
      expect(lines.where((line) => line.contains('arm_failed')), isEmpty);
      expect(lines.where((line) => line.contains('Exception')), isEmpty);
      expect(
        lines.where((line) => line.contains('action=arm_refused')),
        hasLength(1),
      );
    });

    test('still reports a capture that really fails', () async {
      final source = _FakeCaptureSource()
        ..startError = PlatformException(code: 'capture_configure_failed');
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => speaker,
      );
      addTearDown(monitor.dispose);

      late bool armed;
      final lines = await logged(() async {
        armed = await monitor.arm(
          onSpeechStart: () {},
          onTranscript: (_) async {},
        );
      });

      expect(armed, isFalse);
      expect(
        lines.where((line) => line.contains('voice.barge.arm_failed')),
        hasLength(1),
      );
    });
  });

  test('unsafe verdict during playback disarms until playback stops', () async {
    final source = _FakeCaptureSource();
    final monitor = FullDuplexBargeInMonitor(
      source: source,
      playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
        aecEnabled: false,
        privateOutput: false,
        playbackSafe: false,
      ),
    );
    addTearDown(monitor.dispose);

    expect(
      await monitor.arm(onSpeechStart: () {}, onTranscript: (_) async {}),
      isTrue,
    );
    expect(await monitor.setPlaybackActive(true), isFalse);
    expect(monitor.playbackUnsafeLatched, isTrue);
    expect(monitor.active, isFalse);

    // Mientras la reproducción sigue activa el latch supone half-duplex; solo
    // su fin (o la frontera explícita del turno) rehabilita el re-sondeo.
    await monitor.setPlaybackActive(false);
    expect(monitor.playbackUnsafeLatched, isFalse);
  });

  test(
    'private output permits playback-phase onset after quiet calibration',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: false,
          privateOutput: true,
          playbackSafe: true,
        ),
      );
      var starts = 0;
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (_) async {},
      );
      await _emit(source, 70, 42);

      await monitor.setPlaybackActive(true);
      // 500 ms grace, then a 300 ms 80%-majority window.
      await _emit(source, 2600, 30);
      expect(starts, 1);
      await monitor.disarm();
      await monitor.dispose();
    },
  );

  test(
    'Desktop playback clamp rejects 900 RMS and accepts real speech',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: true,
          playbackSafe: true,
        ),
      );
      var starts = 0;
      await monitor.arm(
        onSpeechStart: () => starts++,
        onTranscript: (_) async {},
      );
      await _emit(source, 70, 42);

      await monitor.setPlaybackActive(true);
      // El clamp oficial equivale a ~1505 RMS en PCM16.
      await _emit(source, 120, 20);
      await _emit(source, 900, 10);
      expect(starts, 0);
      await _emit(source, 1800, 10);

      expect(starts, 1);
      await monitor.disarm();
      await monitor.dispose();
    },
  );

  test('sub-threshold AEC residue does not self-trigger', () async {
    final source = _FakeCaptureSource();
    final monitor = FullDuplexBargeInMonitor(
      source: source,
      playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
        aecEnabled: true,
        privateOutput: true,
        playbackSafe: true,
      ),
    );
    var starts = 0;
    await monitor.arm(
      onSpeechStart: () => starts++,
      onTranscript: (_) async {},
    );
    await _emit(source, 70, 42);

    await monitor.setPlaybackActive(true);
    await _emit(source, 500, 40);
    expect(starts, 0);

    await _emit(source, 1500, 10);
    expect(starts, 0);

    await _emit(source, 1600, 10);
    expect(starts, 1);
    await monitor.disarm();
    await monitor.dispose();
  });

  test(
    'silent generation cycle stays armed until controller disarms it',
    () async {
      final source = _FakeCaptureSource();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: false,
          privateOutput: true,
          playbackSafe: true,
        ),
      );
      final transcripts = <String?>[];
      await monitor.arm(
        onSpeechStart: () {},
        onTranscript: (text) async => transcripts.add(text),
      );

      await _emit(source, 60, 200);
      expect(monitor.armed, isTrue);
      expect(source.transcriptions, 0);
      expect(transcripts, isEmpty);
      await monitor.disarm();
      expect(monitor.active, isFalse);
      await monitor.dispose();
    },
  );

  group('anti-echo guard (upstream is_tts_echo parity)', () {
    test('similarityRatio matches difflib semantics', () {
      expect(FullDuplexBargeInMonitor.similarityRatio('abcd', 'abcd'), 1.0);
      expect(FullDuplexBargeInMonitor.similarityRatio('', ''), 1.0);
      expect(FullDuplexBargeInMonitor.similarityRatio('abcd', 'wxyz'), 0.0);
      // difflib.SequenceMatcher(None, 'abcd', 'abxd').ratio() == 0.75
      expect(FullDuplexBargeInMonitor.similarityRatio('abcd', 'abxd'), 0.75);
    });

    test('short transcripts are never echo-discarded', () {
      expect(
        FullDuplexBargeInMonitor.isTtsEcho('sí', 'sí sí sí, claro que sí'),
        isFalse,
      );
      expect(FullDuplexBargeInMonitor.isTtsEcho('corta', 'corta'), isFalse);
    });

    test('a verbatim barge-in of the spoken TTS is echo', () {
      const spoken = 'La respuesta corta es que el tren sale a las nueve.';
      expect(FullDuplexBargeInMonitor.isTtsEcho(spoken, spoken), isTrue);
    });

    test('the sliding window finds the transcript inside a longer tail', () {
      const spoken =
          'Primera frase narrada. El tren sale a las nueve desde la vía '
          'dos. Tercera frase con otro contenido.';
      const heard = 'el tren sale a las nueve desde la vía dos';
      expect(FullDuplexBargeInMonitor.isTtsEcho(heard, spoken), isTrue);
    });

    test('punctuation and case differences still count as echo', () {
      const spoken = 'El tren sale a las nueve, desde la vía dos.';
      const heard = 'el tren sale a las nueve desde la vía dos';
      expect(FullDuplexBargeInMonitor.isTtsEcho(heard, spoken), isTrue);
    });

    test('legitimate user speech over TTS is never discarded', () {
      const spoken =
          'El informe termina mañana y puedo enviarte el borrador esta '
          'tarde si quieres revisarlo con calma.';
      expect(
        FullDuplexBargeInMonitor.isTtsEcho(
          'para, mejor cuéntame otra cosa',
          spoken,
        ),
        isFalse,
      );
      expect(
        FullDuplexBargeInMonitor.isTtsEcho('espera un momento', spoken),
        isFalse,
      );
    });

    test('a partial overlap below the threshold is legitimate speech', () {
      const spoken =
          'El informe termina mañana y puedo enviarte el borrador esta '
          'tarde si quieres revisarlo con calma.';
      // Comparte una frase con el TTS, pero el usuario añade su orden.
      const heard =
          'el informe termina mañana pero prefiero que lo mandes el lunes '
          'por la mañana';
      expect(FullDuplexBargeInMonitor.isTtsEcho(heard, spoken), isFalse);
    });

    test('an empty spoken reference never discards', () {
      expect(
        FullDuplexBargeInMonitor.isTtsEcho('dime cualquier cosa', ''),
        isFalse,
      );
    });

    test('barge-in transcript matching the spoken TTS is dropped', () async {
      const spoken =
          'El tren sale a las nueve desde la vía dos de la estación '
          'central.';
      final source = _FakeCaptureSource()..transcript = spoken;
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: false,
          playbackSafe: true,
        ),
      );
      addTearDown(monitor.dispose);
      monitor.noteSpokenText(spoken);
      final transcripts = <String?>[];
      await monitor.arm(
        onSpeechStart: () {},
        onTranscript: (text) async => transcripts.add(text),
      );

      await _emit(source, 80, 42);
      await monitor.setPlaybackActive(true);
      await _emit(source, 120, 17); // playback grace
      await _emit(source, 1800, 12);
      await _emit(source, 600, 42);

      expect(source.transcriptions, 1);
      expect(transcripts, [null]);
      await monitor.dispose();
    });

    test('barge-in transcript of real user speech is delivered', () async {
      final source = _FakeCaptureSource()
        ..transcript = 'para un momento, tengo una pregunta';
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        playbackSafetyProbe: () async => const FullDuplexPlaybackSafety(
          aecEnabled: true,
          privateOutput: false,
          playbackSafe: true,
        ),
      );
      addTearDown(monitor.dispose);
      monitor.noteSpokenText(
        'El tren sale a las nueve desde la vía dos de la estación central.',
      );
      final transcripts = <String?>[];
      await monitor.arm(
        onSpeechStart: () {},
        onTranscript: (text) async => transcripts.add(text),
      );

      await _emit(source, 80, 42);
      await monitor.setPlaybackActive(true);
      await _emit(source, 120, 17);
      await _emit(source, 1800, 12);
      await _emit(source, 600, 42);

      expect(source.transcriptions, 1);
      expect(transcripts, ['para un momento, tengo una pregunta']);
      await monitor.dispose();
    });
  });
}
