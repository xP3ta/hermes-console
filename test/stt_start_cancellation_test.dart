import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_remote.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:hermes_android/core/services/voice/voice_latency_trace.dart';
import 'package:record/record.dart';

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() predicate) async {
  while (!predicate()) {
    await _flush();
  }
}

class _ManualVoiceTurnTimer implements Timer {
  _ManualVoiceTurnTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}

class _ManualVoiceTurnTimers {
  final List<_ManualVoiceTurnTimer> created = [];

  Timer create(Duration duration, void Function() callback) {
    final timer = _ManualVoiceTurnTimer(duration, callback);
    created.add(timer);
    return timer;
  }
}

class _FakeSystemRuntime implements SystemSttRuntime {
  Future<bool> permission = Future<bool>.value(true);
  Future<bool> initialization = Future<bool>.value(true);
  Future<List<String>> localeList = Future<List<String>>.value(const ['es_ES']);
  Future<void> listening = Future<void>.value();
  Future<void> stopping = Future<void>.value();

  int permissionCalls = 0;
  int initializeCalls = 0;
  int localesCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  int stopAfterDisposeCalls = 0;
  bool disposed = false;
  void Function(String text, bool isFinal)? onResult;

  @override
  Future<bool> hasPermission() {
    permissionCalls++;
    return permission;
  }

  @override
  Future<bool> initialize({required void Function(String message) onError}) {
    initializeCalls++;
    return initialization;
  }

  @override
  Future<List<String>> locales() {
    localesCalls++;
    return localeList;
  }

  @override
  Future<String?> systemLocale() async => 'es_ES';

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required String? localeId,
    required bool continuous,
  }) {
    listenCalls++;
    this.onResult = onResult;
    return listening;
  }

  @override
  Future<void> stop() {
    stopCalls++;
    if (disposed) stopAfterDisposeCalls++;
    return stopping;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
  }
}

class _FakeWhisperRuntime implements WhisperSttRuntime {
  Future<bool> permission = Future<bool>.value(true);
  Future<bool> ready = Future<bool>.value(true);
  Future<String> path = Future<String>.value('/tmp/fake-whisper.wav');
  Future<void> starting = Future<void>.value();
  Future<String?> stopping = Future<String?>.value(null);
  Future<String> transcription = Future<String>.value('');
  Object? transcribeError;
  StreamController<Amplitude> amplitudes =
      StreamController<Amplitude>.broadcast();

  int permissionCalls = 0;
  int readyCalls = 0;
  int pathCalls = 0;
  int startCalls = 0;
  int amplitudeCalls = 0;
  final List<Duration> amplitudeIntervals = <Duration>[];
  int stopCalls = 0;
  int transcribeCalls = 0;
  int disposeCalls = 0;
  int stopAfterDisposeCalls = 0;
  bool disposed = false;

  @override
  Future<bool> hasPermission() {
    permissionCalls++;
    return permission;
  }

  @override
  Future<bool> modelReady(WhisperModel model) {
    readyCalls++;
    return ready;
  }

  @override
  Future<String> createAudioPath() {
    pathCalls++;
    return path;
  }

  @override
  Future<void> start(String path) {
    startCalls++;
    return starting;
  }

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) {
    amplitudeCalls++;
    amplitudeIntervals.add(interval);
    return amplitudes.stream;
  }

  @override
  Future<String?> stop() {
    stopCalls++;
    if (disposed) stopAfterDisposeCalls++;
    return stopping;
  }

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) {
    transcribeCalls++;
    final error = transcribeError;
    return error == null
        ? transcription
        : Future<String>.sync(() => throw error);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
  }
}

class _FakeServerRecorder implements ServerSttRecorder {
  Future<bool> permission = Future<bool>.value(true);
  Future<Stream<Uint8List>> starting = Future<Stream<Uint8List>>.value(
    const Stream<Uint8List>.empty(),
  );
  Future<void> stopping = Future<void>.value();
  int permissionCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  int stopAfterDisposeCalls = 0;
  bool disposed = false;

  @override
  Future<bool> hasPermission() {
    permissionCalls++;
    return permission;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) {
    startCalls++;
    return starting;
  }

  @override
  Future<void> stop() {
    stopCalls++;
    if (disposed) stopAfterDisposeCalls++;
    return stopping;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
  }
}

class _FakeServerSession implements ServerSttSession {
  _FakeServerSession({void Function()? onCancel})
    : incoming = StreamController<dynamic>(onCancel: onCancel);

  final StreamController<dynamic> incoming;
  Future<void> closing = Future<void>.value();
  int closeCalls = 0;
  final List<Object> sent = [];

  @override
  dynamic get firstMessage => '{"type":"ready"}';

  @override
  Stream<dynamic> get messages => incoming.stream;

  @override
  void add(Object data) => sent.add(data);

  @override
  Future<void> close() {
    closeCalls++;
    return closing;
  }
}

class _FakeSherpaRuntime implements SherpaSttRuntime {
  Future<bool> permission = Future<bool>.value(true);
  Future<bool> ready = Future<bool>.value(true);
  Future<void> preparing = Future<void>.value();
  Future<Stream<Uint8List>> starting = Future<Stream<Uint8List>>.value(
    const Stream<Uint8List>.empty(),
  );
  Future<void> stopping = Future<void>.value();

  int permissionCalls = 0;
  int readyCalls = 0;
  int prepareCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  int stopAfterDisposeCalls = 0;
  bool disposed = false;

  @override
  Future<bool> hasPermission() {
    permissionCalls++;
    return permission;
  }

  @override
  Future<bool> modelReady() {
    readyCalls++;
    return ready;
  }

  @override
  Future<void> prepare() {
    prepareCalls++;
    return preparing;
  }

  @override
  Future<Stream<Uint8List>> startStream() {
    startCalls++;
    return starting;
  }

  @override
  Future<void> stop() {
    stopCalls++;
    if (disposed) stopAfterDisposeCalls++;
    return stopping;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SystemSttEngine startup cancellation', () {
    test(
      'System declara streaming y endpoint unavailable sin fingir umbral',
      () async {
        final records = <VoiceLatencyRecord>[];
        var nowMicros = 1000;
        final trace = VoiceLatencyTrace.testing(
          runId: '0123456789abcdef',
          nowMicros: () => nowMicros += 100,
          onRecord: records.add,
        );
        trace.beginTurn(
          route: VoiceLatencyRoute.phone,
          scenario: VoiceLatencyScenario.normal,
          sttTopology: VoiceSttTopology.streaming,
          lastAboveAvailability: VoiceLatencyAvailability.unavailable,
        );
        final runtime = _FakeSystemRuntime();
        final engine = SystemSttEngine(runtime: runtime);

        await trace.runScoped(() async {
          final done = engine.listen().drain<void>();
          await _waitUntil(() => runtime.listenCalls == 1);
          runtime.onResult?.call('contenido que no debe trazarse', true);
          await done.timeout(const Duration(seconds: 1));
        });

        expect(
          records.map((record) => record.point),
          containsAllInOrder(const <VoiceLatencyPoint>[
            VoiceLatencyPoint.sttStarted,
            VoiceLatencyPoint.speechEndpointUnavailable,
            VoiceLatencyPoint.sttFinal,
          ]),
        );
        expect(
          records.map((record) => record.point),
          isNot(
            anyOf(
              contains(VoiceLatencyPoint.speechLastAboveThreshold),
              contains(VoiceLatencyPoint.speechEndpoint),
            ),
          ),
        );
        expect(
          records.expand((record) => record.arguments.values),
          isNot(contains('contenido que no debe trazarse')),
        );
        await engine.dispose();
      },
    );

    test('cierra a los 12 s sin proyectar fin de habla inexistente', () async {
      final timers = _ManualVoiceTurnTimers();
      final runtime = _FakeSystemRuntime();
      var speechEnds = 0;
      final engine = SystemSttEngine(
        runtime: runtime,
        idleSilenceTimeout: kVoiceTurnIdleSilenceTimeout,
        timerFactory: timers.create,
      );
      final done = engine.listen(onSpeechEnd: () => speechEnds++).drain<void>();
      await _waitUntil(
        () => runtime.listenCalls == 1 && timers.created.isNotEmpty,
      );

      expect(timers.created.single.duration, kVoiceTurnIdleSilenceTimeout);
      timers.created.single.fire();

      await _waitUntil(() => runtime.stopCalls == 1);
      await done.timeout(const Duration(seconds: 1));
      expect(speechEnds, 0);
      await engine.dispose();
    });

    test(
      'la primera voz cancela el idle y dictado continuo no lo arma',
      () async {
        final timers = _ManualVoiceTurnTimers();
        final runtime = _FakeSystemRuntime();
        final engine = SystemSttEngine(
          runtime: runtime,
          timerFactory: timers.create,
        );
        final firstDone = engine.listen().drain<void>();
        await _waitUntil(
          () => runtime.listenCalls == 1 && timers.created.isNotEmpty,
        );

        runtime.onResult?.call('hola', false);
        await _flush();
        expect(timers.created.single.isActive, isFalse);
        timers.created.single.fire();
        expect(runtime.stopCalls, 0);
        runtime.onResult?.call('hola', true);
        await firstDone.timeout(const Duration(seconds: 1));

        final continuousDone = engine.listen(continuous: true).drain<void>();
        await _waitUntil(() => runtime.listenCalls == 2);
        expect(timers.created, hasLength(1));
        await engine.stop();
        await continuousDone.timeout(const Duration(seconds: 1));
        await engine.dispose();
      },
    );

    test(
      'stop during permission prevents initialization and listening',
      () async {
        final permission = Completer<bool>();
        final runtime = _FakeSystemRuntime()..permission = permission.future;
        final engine = SystemSttEngine(runtime: runtime);
        final done = engine.listen().drain<void>();
        await _flush();

        await engine.stop();
        permission.complete(true);
        await done.timeout(const Duration(seconds: 1));

        expect(runtime.initializeCalls, 0);
        expect(runtime.listenCalls, 0);
        await engine.dispose();
      },
    );

    test(
      'dispose during initialization prevents locale and microphone',
      () async {
        final initialization = Completer<bool>();
        final runtime = _FakeSystemRuntime()
          ..initialization = initialization.future;
        final engine = SystemSttEngine(runtime: runtime);
        final done = engine.listen().drain<void>();
        await _flush();

        var disposeCompleted = false;
        final disposing = engine.dispose().then((_) => disposeCompleted = true);
        final disposingAgain = engine.dispose();
        await _flush();
        expect(disposeCompleted, isFalse);
        initialization.complete(true);
        await disposing;
        await disposingAgain;
        await done.timeout(const Duration(seconds: 1));

        expect(runtime.localesCalls, 0);
        expect(runtime.listenCalls, 0);
        expect(runtime.disposeCalls, 1);
        expect(runtime.stopAfterDisposeCalls, 0);
      },
    );

    test('stop during platform listen ignores late callbacks', () async {
      final listening = Completer<void>();
      final runtime = _FakeSystemRuntime()..listening = listening.future;
      final engine = SystemSttEngine(runtime: runtime);
      final values = <SttResult>[];
      final done = engine.listen().listen(values.add).asFuture<void>();
      while (runtime.listenCalls == 0) {
        await _flush();
      }

      await engine.stop();
      runtime.onResult?.call('late result', true);
      listening.complete();
      await done.timeout(const Duration(seconds: 1));

      expect(values, isEmpty);
      await engine.dispose();
    });

    test('listen B waits for a non-awaited stop of A', () async {
      final stopGate = Completer<void>();
      final runtime = _FakeSystemRuntime()..stopping = stopGate.future;
      final engine = SystemSttEngine(runtime: runtime);
      final firstDone = engine.listen().drain<void>();
      await _waitUntil(() => runtime.listenCalls == 1);

      final stopping = engine.stop();
      final secondDone = engine.listen().drain<void>();
      await _flush();
      final startedBeforeStop = runtime.listenCalls > 1;

      stopGate.complete();
      await stopping;
      await _waitUntil(() => runtime.listenCalls == 2);
      runtime.onResult?.call('second', true);
      await firstDone.timeout(const Duration(seconds: 1));
      await secondDone.timeout(const Duration(seconds: 1));
      expect(startedBeforeStop, isFalse);
      await engine.dispose();
    });
  });

  group('WhisperSttEngine startup cancellation', () {
    test('traza endpoint antes de comenzar ASR y final después', () async {
      final file = File(
        '${Directory.systemTemp.path}/hermes-stt-trace-'
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      )..writeAsBytesSync(const [1, 2, 3]);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      final runtime = _FakeWhisperRuntime()
        ..path = Future<String>.value(file.path)
        ..stopping = Future<String?>.value(file.path)
        ..transcription = Future<String>.value('texto privado');
      final records = <VoiceLatencyRecord>[];
      var nowMicros = 1000;
      final trace = VoiceLatencyTrace.testing(
        runId: '0123456789abcdef',
        nowMicros: () => nowMicros += 100,
        onRecord: records.add,
      );
      trace.beginTurn(
        route: VoiceLatencyRoute.phone,
        scenario: VoiceLatencyScenario.normal,
        sttTopology: VoiceSttTopology.recordThenTranscribe,
        lastAboveAvailability: VoiceLatencyAvailability.measured,
      );
      final engine = WhisperSttEngine(
        runtime: runtime,
        silenceTimeout: Duration.zero,
      );

      await trace.runScoped(() async {
        final done = engine.listen().drain<void>();
        await _waitUntil(() => runtime.amplitudeCalls == 1);
        runtime.amplitudes.add(Amplitude(current: -23, max: -23));
        runtime.amplitudes.add(Amplitude(current: -24, max: -23));
        runtime.amplitudes.add(Amplitude(current: -23, max: -23));
        runtime.amplitudes.add(Amplitude(current: -7, max: -7));
        runtime.amplitudes.add(Amplitude(current: -6, max: -6));
        runtime.amplitudes.add(Amplitude(current: -7, max: -6));
        runtime.amplitudes.add(Amplitude(current: -23, max: -6));
        await done.timeout(const Duration(seconds: 1));
      });

      expect(
        records.map((record) => record.point),
        containsAllInOrder(const <VoiceLatencyPoint>[
          VoiceLatencyPoint.speechLastAboveThreshold,
          VoiceLatencyPoint.speechEndpoint,
          VoiceLatencyPoint.sttStarted,
          VoiceLatencyPoint.sttFinal,
        ]),
      );
      expect(
        records.expand((record) => record.arguments.values),
        isNot(contains('texto privado')),
      );
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test(
      'Hermes Server no transcribe un timeout sin onset confirmado',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/hermes-stt-silence-'
          '${DateTime.now().microsecondsSinceEpoch}.wav',
        )..writeAsBytesSync(const [1, 2, 3]);
        addTearDown(() {
          if (file.existsSync()) file.deleteSync();
        });
        final timers = _ManualVoiceTurnTimers();
        final runtime = _FakeWhisperRuntime()
          ..path = Future<String>.value(file.path)
          ..stopping = Future<String?>.value(file.path)
          ..transcription = Future<String>.value('alucinación');
        final results = <SttResult>[];
        final engine = WhisperSttEngine(
          runtime: runtime,
          discardAutomaticTurnWithoutSpeechOnset: true,
          timerFactory: timers.create,
        );
        final done = engine.listen().listen(results.add).asFuture<void>();
        await _waitUntil(
          () => runtime.amplitudeCalls == 1 && timers.created.isNotEmpty,
        );

        timers.created.single.fire();

        await done.timeout(const Duration(seconds: 1));
        expect(runtime.stopCalls, 1);
        expect(runtime.transcribeCalls, 0);
        expect(results, isEmpty);
        await _waitUntil(() => !file.existsSync());
        expect(file.existsSync(), isFalse);
        await engine.dispose();
        await runtime.amplitudes.close();
      },
    );

    test('Hermes Server sí transcribe una voz con onset normal', () async {
      final file = File(
        '${Directory.systemTemp.path}/hermes-stt-speech-'
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      )..writeAsBytesSync(const [1, 2, 3]);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      final runtime = _FakeWhisperRuntime()
        ..path = Future<String>.value(file.path)
        ..stopping = Future<String?>.value(file.path)
        ..transcription = Future<String>.value('voz normal');
      final results = <SttResult>[];
      final engine = WhisperSttEngine(
        runtime: runtime,
        discardAutomaticTurnWithoutSpeechOnset: true,
        silenceTimeout: Duration.zero,
      );
      final done = engine.listen().listen(results.add).asFuture<void>();
      await _waitUntil(() => runtime.amplitudeCalls == 1);

      runtime.amplitudes.add(Amplitude(current: -23, max: -23));
      runtime.amplitudes.add(Amplitude(current: -24, max: -23));
      runtime.amplitudes.add(Amplitude(current: -23, max: -23));
      runtime.amplitudes.add(Amplitude(current: -7, max: -7));
      runtime.amplitudes.add(Amplitude(current: -6, max: -6));
      runtime.amplitudes.add(Amplitude(current: -7, max: -6));
      runtime.amplitudes.add(Amplitude(current: -23, max: -6));

      await done.timeout(const Duration(seconds: 1));
      expect(runtime.transcribeCalls, 1);
      expect(results, hasLength(1));
      expect(results.single.text, 'voz normal');
      expect(results.single.isFinal, isTrue);
      await _waitUntil(() => !file.existsSync());
      expect(file.existsSync(), isFalse);
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test('cierra a los 12 s sin proyectar fin de habla inexistente', () async {
      final timers = _ManualVoiceTurnTimers();
      final runtime = _FakeWhisperRuntime();
      var speechEnds = 0;
      final engine = WhisperSttEngine(
        runtime: runtime,
        idleSilenceTimeout: kVoiceTurnIdleSilenceTimeout,
        timerFactory: timers.create,
      );
      final done = engine.listen(onSpeechEnd: () => speechEnds++).drain<void>();
      await _waitUntil(
        () => runtime.amplitudeCalls == 1 && timers.created.isNotEmpty,
      );

      expect(timers.created.single.duration, kVoiceTurnIdleSilenceTimeout);
      timers.created.single.fire();

      await _waitUntil(() => runtime.stopCalls == 1);
      await done.timeout(const Duration(seconds: 1));
      expect(speechEnds, 0);
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test('VAD desactivado conserva el idle sin fingir fin de habla', () async {
      final timers = _ManualVoiceTurnTimers();
      final runtime = _FakeWhisperRuntime();
      var speechEnds = 0;
      final engine = WhisperSttEngine(
        runtime: runtime,
        vadEnabled: false,
        timerFactory: timers.create,
      );
      final done = engine.listen(onSpeechEnd: () => speechEnds++).drain<void>();
      await _waitUntil(() => runtime.amplitudeCalls == 1);

      expect(timers.created, hasLength(1));
      expect(timers.created.single.duration, kVoiceTurnIdleSilenceTimeout);
      expect(
        runtime.amplitudeIntervals.single,
        const Duration(milliseconds: 200),
      );
      timers.created.single.fire();

      await _waitUntil(() => runtime.stopCalls == 1);
      await done.timeout(const Duration(seconds: 1));
      expect(speechEnds, 0);
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test(
      'VAD desactivado cancela el idle al oír voz pero no corta por silencio',
      () async {
        final timers = _ManualVoiceTurnTimers();
        final runtime = _FakeWhisperRuntime();
        final engine = WhisperSttEngine(
          runtime: runtime,
          vadEnabled: false,
          silenceTimeout: Duration.zero,
          timerFactory: timers.create,
        );
        final done = engine.listen().drain<void>();
        await _waitUntil(() => runtime.amplitudeCalls == 1);

        expect(timers.created, hasLength(1));
        runtime.amplitudes.add(Amplitude(current: -23, max: -23));
        runtime.amplitudes.add(Amplitude(current: -7, max: -7));
        await _flush();

        expect(timers.created.single.isActive, isFalse);
        runtime.amplitudes.add(Amplitude(current: -23, max: -7));
        await _flush();
        expect(runtime.stopCalls, 0);

        await engine.stop();
        await done.timeout(const Duration(seconds: 1));
        await engine.dispose();
        await runtime.amplitudes.close();
      },
    );

    test('tres muestras cortas detectan voz sin esperar el idle', () async {
      final timers = _ManualVoiceTurnTimers();
      final runtime = _FakeWhisperRuntime();
      final engine = WhisperSttEngine(
        runtime: runtime,
        timerFactory: timers.create,
      );
      final done = engine.listen().drain<void>();
      await _waitUntil(
        () => runtime.amplitudeCalls == 1 && timers.created.isNotEmpty,
      );

      runtime.amplitudes.add(Amplitude(current: -7, max: -7));
      runtime.amplitudes.add(Amplitude(current: -6, max: -6));
      runtime.amplitudes.add(Amplitude(current: -7, max: -6));
      await _flush();
      expect(
        runtime.amplitudeIntervals.single,
        const Duration(milliseconds: 100),
      );
      expect(timers.created.single.isActive, isFalse);
      timers.created.single.fire();
      expect(runtime.stopCalls, 0);

      await engine.stop();
      await done.timeout(const Duration(seconds: 1));
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test(
      'VAD ignores a single processed-audio spike after calibration',
      () async {
        final runtime = _FakeWhisperRuntime();
        final engine = WhisperSttEngine(
          runtime: runtime,
          silenceTimeout: const Duration(milliseconds: 20),
        );
        final done = engine.listen().drain<void>();
        await _waitUntil(() => runtime.amplitudeCalls == 1);

        // VOICE_RECOGNITION + noise suppression can briefly jump by >8 dB
        // without speech. One transient must not turn the following room tone
        // into an endpoint and churn the recorder.
        runtime.amplitudes.add(Amplitude(current: -25, max: -25));
        runtime.amplitudes.add(Amplitude(current: -24, max: -24));
        runtime.amplitudes.add(Amplitude(current: -25, max: -24));
        runtime.amplitudes.add(Amplitude(current: -16, max: -16));
        runtime.amplitudes.add(Amplitude(current: -23, max: -16));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        runtime.amplitudes.add(Amplitude(current: -23, max: -16));
        await _flush();

        expect(runtime.stopCalls, 0);

        await engine.stop();
        await done.timeout(const Duration(seconds: 1));
        await engine.dispose();
        await runtime.amplitudes.close();
      },
    );

    test(
      'VAD rejects sustained Pixel room noise after a very low startup floor',
      () async {
        final runtime = _FakeWhisperRuntime();
        var speechEnds = 0;
        final engine = WhisperSttEngine(
          runtime: runtime,
          speechOnsetDb: -18,
          silenceTimeout: const Duration(milliseconds: 20),
        );
        final done = engine
            .listen(onSpeechEnd: () => speechEnds++)
            .drain<void>();
        await _waitUntil(() => runtime.amplitudeCalls == 1);

        // Muestras físicas del Pixel: un arranque limpio rondó -51.5 dBFS y
        // el ambiente estable subió después hasta -43.3 dBFS.
        // La subida relativa supera 8 dB, pero sigue sin ser voz real.
        runtime.amplitudes.add(Amplitude(current: -52, max: -52));
        runtime.amplitudes.add(Amplitude(current: -51, max: -51));
        runtime.amplitudes.add(Amplitude(current: -51.5, max: -51));
        runtime.amplitudes.add(Amplitude(current: -43.3, max: -43.3));
        runtime.amplitudes.add(Amplitude(current: -42.8, max: -42.8));
        runtime.amplitudes.add(Amplitude(current: -43.1, max: -42.8));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // Si el ambiente anterior se hubiera aceptado como voz, estas lecturas
        // limpias completarían el endpoint y delatarían el falso positivo.
        runtime.amplitudes.add(Amplitude(current: -52, max: -42.8));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        runtime.amplitudes.add(Amplitude(current: -52, max: -42.8));
        await _flush();
        expect(runtime.stopCalls, 0);
        expect(speechEnds, 0);

        runtime.amplitudes.add(Amplitude(current: -12, max: -12));
        runtime.amplitudes.add(Amplitude(current: -11, max: -11));
        runtime.amplitudes.add(Amplitude(current: -12, max: -11));
        runtime.amplitudes.add(Amplitude(current: -43.3, max: -11));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        runtime.amplitudes.add(Amplitude(current: -43.3, max: -11));

        await _waitUntil(() => runtime.stopCalls == 1);
        await done.timeout(const Duration(seconds: 1));
        expect(speechEnds, 1);

        await engine.dispose();
        await runtime.amplitudes.close();
      },
    );

    test(
      'VAD accepts immediate speech above the configured absolute floor',
      () async {
        final timers = _ManualVoiceTurnTimers();
        final runtime = _FakeWhisperRuntime();
        final engine = WhisperSttEngine(
          runtime: runtime,
          speechOnsetDb: -18,
          silenceTimeout: const Duration(milliseconds: 20),
          timerFactory: timers.create,
        );
        final done = engine.listen().drain<void>();
        await _waitUntil(
          () => runtime.amplitudeCalls == 1 && timers.created.isNotEmpty,
        );

        runtime.amplitudes.add(Amplitude(current: -15, max: -15));
        runtime.amplitudes.add(Amplitude(current: -14, max: -14));
        runtime.amplitudes.add(Amplitude(current: -15, max: -14));
        await _flush();
        expect(timers.created.single.isActive, isFalse);

        runtime.amplitudes.add(Amplitude(current: -43, max: -14));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        runtime.amplitudes.add(Amplitude(current: -43, max: -14));
        await _waitUntil(() => runtime.stopCalls == 1);
        await done.timeout(const Duration(seconds: 1));

        await engine.dispose();
        await runtime.amplitudes.close();
      },
    );

    test(
      'VAD calibrates a high Pixel noise floor and closes after speech',
      () async {
        final runtime = _FakeWhisperRuntime();
        var speechEnds = 0;
        final engine = WhisperSttEngine(
          runtime: runtime,
          silenceTimeout: const Duration(milliseconds: 20),
        );
        final done = engine
            .listen(onSpeechEnd: () => speechEnds++)
            .drain<void>();
        await _waitUntil(() => runtime.amplitudeCalls == 1);

        // El Pixel físico reportó ~-23 dB en silencio: el VAD absoluto
        // antiguo lo consideraba voz porque superaba speechOnsetDb=-30.
        runtime.amplitudes.add(Amplitude(current: -25.7, max: -25.7));
        runtime.amplitudes.add(Amplitude(current: -22, max: -22));
        runtime.amplitudes.add(Amplitude(current: -24, max: -22));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(runtime.stopCalls, 0);

        runtime.amplitudes.add(Amplitude(current: -7.6, max: -7.6));
        runtime.amplitudes.add(Amplitude(current: -8, max: -7.6));
        runtime.amplitudes.add(Amplitude(current: -7, max: -7));
        runtime.amplitudes.add(Amplitude(current: -20.3, max: -7.6));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        runtime.amplitudes.add(Amplitude(current: -20.3, max: -7.6));

        await _waitUntil(() => runtime.stopCalls == 1);
        await done.timeout(const Duration(seconds: 1));
        expect(runtime.stopCalls, 1);
        expect(speechEnds, 1);

        await engine.dispose();
        await runtime.amplitudes.close();
      },
    );

    test(
      'VAD ignores the Android -160 dB sentinel before ambient, speech and silence',
      () async {
        final runtime = _FakeWhisperRuntime();
        var speechEnds = 0;
        final engine = WhisperSttEngine(
          runtime: runtime,
          silenceTimeout: const Duration(milliseconds: 20),
        );
        final done = engine
            .listen(onSpeechEnd: () => speechEnds++)
            .drain<void>();
        await _waitUntil(() => runtime.amplitudeCalls == 1);

        // `record` puede emitir este sentinel al arrancar. La siguiente muestra
        // ambiental no debe parecer una subida de 137 dB ni activar voz falsa.
        runtime.amplitudes.add(Amplitude(current: -160, max: -160));
        runtime.amplitudes.add(Amplitude(current: -23, max: -23));
        runtime.amplitudes.add(Amplitude(current: -24, max: -23));
        runtime.amplitudes.add(Amplitude(current: -23, max: -23));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(runtime.stopCalls, 0);

        runtime.amplitudes.add(Amplitude(current: -7.6, max: -7.6));
        runtime.amplitudes.add(Amplitude(current: -8, max: -7.6));
        runtime.amplitudes.add(Amplitude(current: -7, max: -7));
        runtime.amplitudes.add(Amplitude(current: -23, max: -7.6));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        runtime.amplitudes.add(Amplitude(current: -23, max: -7.6));

        await _waitUntil(() => runtime.stopCalls == 1);
        await done.timeout(const Duration(seconds: 1));
        expect(speechEnds, 1);

        await engine.dispose();
        await runtime.amplitudes.close();
      },
    );

    test('stop during model check never creates a recording path', () async {
      final ready = Completer<bool>();
      final runtime = _FakeWhisperRuntime()..ready = ready.future;
      final engine = WhisperSttEngine(runtime: runtime);
      final done = engine.listen().drain<void>();
      while (runtime.readyCalls == 0) {
        await _flush();
      }

      await engine.stop();
      ready.complete(true);
      await done.timeout(const Duration(seconds: 1));

      expect(runtime.pathCalls, 0);
      expect(runtime.startCalls, 0);
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test(
      'dispose during recorder start prevents VAD and is idempotent',
      () async {
        final starting = Completer<void>();
        final runtime = _FakeWhisperRuntime()..starting = starting.future;
        final engine = WhisperSttEngine(runtime: runtime);
        final done = engine.listen().drain<void>();
        while (runtime.startCalls == 0) {
          await _flush();
        }

        var disposeCompleted = false;
        final disposing = engine.dispose().then((_) => disposeCompleted = true);
        final disposingAgain = engine.dispose();
        await _flush();
        expect(disposeCompleted, isFalse);
        starting.complete();
        await disposing;
        await disposingAgain;
        await done.timeout(const Duration(seconds: 1));

        expect(runtime.amplitudeCalls, 0);
        expect(runtime.disposeCalls, 1);
        expect(runtime.stopAfterDisposeCalls, 0);
        await runtime.amplitudes.close();
      },
    );

    test(
      'dispose during active recording stops runtime and removes its WAV',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/hermes-stt-dispose-'
          '${DateTime.now().microsecondsSinceEpoch}.wav',
        )..writeAsBytesSync(const [1, 2, 3]);
        addTearDown(() {
          if (file.existsSync()) file.deleteSync();
        });
        final stopping = Completer<String?>();
        final runtime = _FakeWhisperRuntime()
          ..path = Future<String>.value(file.path)
          ..stopping = stopping.future;
        final engine = WhisperSttEngine(runtime: runtime);
        final done = engine.listen().drain<void>();
        await _waitUntil(() => runtime.amplitudeCalls == 1);

        var disposeCompleted = false;
        final disposing = engine.dispose().then((_) => disposeCompleted = true);
        await _waitUntil(() => runtime.stopCalls == 1);

        expect(disposeCompleted, isFalse);
        expect(runtime.disposeCalls, 0);
        stopping.complete(file.path);
        await disposing.timeout(const Duration(seconds: 1));
        await done.timeout(const Duration(seconds: 1));

        expect(runtime.stopAfterDisposeCalls, 0);
        expect(runtime.disposeCalls, 1);
        expect(file.existsSync(), isFalse);
        await runtime.amplitudes.close();
      },
    );

    test('a new listen waits out and supersedes a cancelled start', () async {
      final firstStart = Completer<void>();
      final runtime = _FakeWhisperRuntime()..starting = firstStart.future;
      final engine = WhisperSttEngine(runtime: runtime);
      final firstDone = engine.listen().drain<void>();
      while (runtime.startCalls == 0) {
        await _flush();
      }

      await engine.stop();
      runtime.starting = Future<void>.value();
      final second = engine.listen();
      firstStart.complete();
      await firstDone.timeout(const Duration(seconds: 1));
      while (runtime.startCalls < 2) {
        await _flush();
      }

      expect(runtime.amplitudeCalls, 1);
      await engine.stop();
      await second.drain<void>().timeout(const Duration(seconds: 1));
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test('listen B waits for a non-awaited stop of A', () async {
      final stopGate = Completer<String?>();
      final runtime = _FakeWhisperRuntime()..stopping = stopGate.future;
      final engine = WhisperSttEngine(runtime: runtime);
      final firstDone = engine.listen().drain<void>();
      await _waitUntil(() => runtime.amplitudeCalls == 1);

      final stopping = engine.stop();
      final secondDone = engine.listen().drain<void>();
      await _flush();
      final startedBeforeStop = runtime.startCalls > 1;

      stopGate.complete(null);
      await stopping;
      await _waitUntil(() => runtime.startCalls == 2);
      runtime.stopping = Future<String?>.value(null);
      await engine.stop();
      await firstDone.timeout(const Duration(seconds: 1));
      await secondDone.timeout(const Duration(seconds: 1));
      expect(startedBeforeStop, isFalse);
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test('cancelled startup removes its temporary WAV', () async {
      final file = File(
        '${Directory.systemTemp.path}/hermes-stt-cancel-'
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      )..writeAsBytesSync(const [1, 2, 3]);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      final starting = Completer<void>();
      final runtime = _FakeWhisperRuntime()
        ..path = Future<String>.value(file.path)
        ..starting = starting.future;
      final engine = WhisperSttEngine(runtime: runtime);
      final done = engine.listen().drain<void>();
      await _waitUntil(() => runtime.startCalls == 1);

      await engine.stop();
      starting.complete();
      await done.timeout(const Duration(seconds: 1));

      expect(file.existsSync(), isFalse);
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test('transcription error removes its temporary WAV', () async {
      final file = File(
        '${Directory.systemTemp.path}/hermes-stt-error-'
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      )..writeAsBytesSync(const [1, 2, 3]);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      final runtime = _FakeWhisperRuntime()
        ..path = Future<String>.value(file.path)
        ..stopping = Future<String?>.value(file.path)
        ..transcribeError = StateError('decode failed');
      final errors = <Object>[];
      final done = Completer<void>();
      final engine = WhisperSttEngine(runtime: runtime);
      engine.listen().listen(
        (_) {},
        onError: (Object error) => errors.add(error),
        onDone: done.complete,
      );
      await _waitUntil(() => runtime.amplitudeCalls == 1);

      await engine.stop();
      await done.future.timeout(const Duration(seconds: 1));

      expect(errors, isNotEmpty);
      expect(file.existsSync(), isFalse);
      await engine.dispose();
      await runtime.amplitudes.close();
    });

    test('transcription timeout removes its temporary WAV', () async {
      final file = File(
        '${Directory.systemTemp.path}/hermes-stt-timeout-'
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      )..writeAsBytesSync(const [1, 2, 3]);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      final runtime = _FakeWhisperRuntime()
        ..path = Future<String>.value(file.path)
        ..stopping = Future<String?>.value(file.path)
        ..transcription = Completer<String>().future;
      final errors = <Object>[];
      final done = Completer<void>();
      final engine = WhisperSttEngine(
        runtime: runtime,
        maxDuration: const Duration(seconds: -45),
      );
      engine.listen().listen(
        (_) {},
        onError: (Object error) => errors.add(error),
        onDone: done.complete,
      );
      await _waitUntil(() => runtime.amplitudeCalls == 1);

      await engine.stop();
      await done.future.timeout(const Duration(seconds: 1));

      expect(errors, isNotEmpty);
      expect(file.existsSync(), isFalse);
      await engine.dispose();
      await runtime.amplitudes.close();
    });
  });

  group('ServerSttEngine startup cancellation', () {
    test(
      'traza inicio streaming, solo PCM voiced y endpoint antes del final',
      () async {
        final records = <VoiceLatencyRecord>[];
        var nowMicros = 1000;
        final trace = VoiceLatencyTrace.testing(
          runId: '0123456789abcdef',
          nowMicros: () => ++nowMicros,
          onRecord: records.add,
        );
        final audio = StreamController<Uint8List>.broadcast();
        final recorder = _FakeServerRecorder()
          ..starting = Future<Stream<Uint8List>>.value(audio.stream);
        final session = _FakeServerSession();
        late ServerSttEngine engine;
        late Future<List<SttResult>> results;

        await trace.runScoped(() async {
          trace.beginTurn(
            route: VoiceLatencyRoute.server,
            scenario: VoiceLatencyScenario.normal,
            sttTopology: VoiceSttTopology.streaming,
            lastAboveAvailability: VoiceLatencyAvailability.measured,
          );
          engine = ServerSttEngine(
            baseUrl: 'ws://127.0.0.1:9123',
            enableGhostGate: false,
            recorderFactory: () => recorder,
            connector: (_) async => session,
          );
          results = engine.listen().toList();
          await _waitUntil(() => recorder.startCalls == 1);
          await _flush();

          engine.muteToServer = true;
          audio.add(Uint8List.fromList(const [0, 16, 0, 16]));
          await _flush();
          engine.muteToServer = false;
          audio.add(Uint8List.fromList(const [1, 0, 1, 0]));
          audio.add(Uint8List.fromList(const [0, 16, 0, 16]));
          await _flush();

          session.incoming.add('{"type":"endpoint"}');
          session.incoming.add('{"type":"final","text":"hola"}');
          await results.timeout(const Duration(seconds: 1));
        });

        expect(
          session.sent.whereType<Uint8List>().map((bytes) => bytes.toList()),
          [
            [1, 0, 1, 0],
            [0, 16, 0, 16],
          ],
        );
        expect(
          records.map((record) => record.point),
          containsAllInOrder(const <VoiceLatencyPoint>[
            VoiceLatencyPoint.sttStarted,
            VoiceLatencyPoint.speechLastAboveThreshold,
            VoiceLatencyPoint.speechEndpoint,
            VoiceLatencyPoint.sttFinal,
          ]),
        );
        await engine.dispose();
        await audio.close();
        await session.incoming.close();
      },
    );

    test(
      'endpoint local conserva el inicio streaming y el final directo',
      () async {
        final records = <VoiceLatencyRecord>[];
        var nowMicros = 1000;
        final trace = VoiceLatencyTrace.testing(
          runId: '0123456789abcdef',
          nowMicros: () => ++nowMicros,
          onRecord: records.add,
        );
        final audio = StreamController<Uint8List>.broadcast();
        final recorder = _FakeServerRecorder()
          ..starting = Future<Stream<Uint8List>>.value(audio.stream);
        final session = _FakeServerSession();
        late ServerSttEngine engine;
        late Future<List<SttResult>> results;

        await trace.runScoped(() async {
          trace.beginTurn(
            route: VoiceLatencyRoute.server,
            scenario: VoiceLatencyScenario.normal,
            sttTopology: VoiceSttTopology.streaming,
            lastAboveAvailability: VoiceLatencyAvailability.measured,
          );
          engine = ServerSttEngine(
            baseUrl: 'ws://127.0.0.1:9123',
            enableGhostGate: false,
            ignoreServerEndpoint: true,
            recorderFactory: () => recorder,
            connector: (_) async => session,
          );
          results = engine.listen().toList();
          await _waitUntil(() => recorder.startCalls == 1);
          await engine.endTurn();
          session.incoming.add('{"type":"final","text":"hola"}');
          await results.timeout(const Duration(seconds: 1));
        });

        final points = records.map((record) => record.point).toList();
        expect(
          points,
          containsAllInOrder(const <VoiceLatencyPoint>[
            VoiceLatencyPoint.sttStarted,
            VoiceLatencyPoint.speechEndpoint,
            VoiceLatencyPoint.sttFinal,
          ]),
        );
        expect(
          points,
          isNot(contains(VoiceLatencyPoint.speechEndpointUnavailable)),
        );
        await engine.dispose();
        await audio.close();
        await session.incoming.close();
      },
    );

    test('PCM silenciado o bajo el gate nunca publica lastAbove', () async {
      final records = <VoiceLatencyRecord>[];
      var nowMicros = 1000;
      final trace = VoiceLatencyTrace.testing(
        runId: '0123456789abcdef',
        nowMicros: () => ++nowMicros,
        onRecord: records.add,
      );
      final audio = StreamController<Uint8List>.broadcast();
      final recorder = _FakeServerRecorder()
        ..starting = Future<Stream<Uint8List>>.value(audio.stream);
      final session = _FakeServerSession();
      late ServerSttEngine engine;
      late Future<List<SttResult>> results;

      await trace.runScoped(() async {
        trace.beginTurn(
          route: VoiceLatencyRoute.server,
          scenario: VoiceLatencyScenario.normal,
        );
        engine = ServerSttEngine(
          baseUrl: 'ws://127.0.0.1:9123',
          enableGhostGate: false,
          recorderFactory: () => recorder,
          connector: (_) async => session,
        );
        results = engine.listen().toList();
        await _waitUntil(() => recorder.startCalls == 1);
        await _flush();

        engine.muteToServer = true;
        audio.add(Uint8List.fromList(const [0, 16, 0, 16]));
        await _flush();
        engine.muteToServer = false;
        audio.add(Uint8List.fromList(const [1, 0, 1, 0]));
        await _flush();

        session.incoming.add('{"type":"endpoint"}');
        session.incoming.add('{"type":"final","text":"hola"}');
        await results.timeout(const Duration(seconds: 1));
      });

      expect(
        records.map((record) => record.point),
        isNot(contains(VoiceLatencyPoint.speechLastAboveThreshold)),
      );
      expect(session.sent.whereType<Uint8List>(), hasLength(1));
      await engine.dispose();
      await audio.close();
      await session.incoming.close();
    });

    test(
      'final streaming sin endpoint conserva inicio y declara unavailable',
      () async {
        final records = <VoiceLatencyRecord>[];
        var nowMicros = 1000;
        final trace = VoiceLatencyTrace.testing(
          runId: '0123456789abcdef',
          nowMicros: () => ++nowMicros,
          onRecord: records.add,
        );
        final recorder = _FakeServerRecorder();
        final session = _FakeServerSession();
        late ServerSttEngine engine;
        late Future<List<SttResult>> results;

        await trace.runScoped(() async {
          trace.beginTurn(
            route: VoiceLatencyRoute.server,
            scenario: VoiceLatencyScenario.normal,
            sttTopology: VoiceSttTopology.streaming,
            lastAboveAvailability: VoiceLatencyAvailability.measured,
          );
          engine = ServerSttEngine(
            baseUrl: 'ws://127.0.0.1:9123',
            enableGhostGate: false,
            recorderFactory: () => recorder,
            connector: (_) async => session,
          );
          results = engine.listen().toList();
          await _waitUntil(() => recorder.startCalls == 1);
          session.incoming.add('{"type":"final","text":"hola"}');
          await results.timeout(const Duration(seconds: 1));
        });

        final points = records.map((record) => record.point).toList();
        expect(
          points,
          containsAllInOrder(const <VoiceLatencyPoint>[
            VoiceLatencyPoint.sttStarted,
            VoiceLatencyPoint.speechEndpointUnavailable,
            VoiceLatencyPoint.sttFinal,
          ]),
        );
        expect(points, isNot(contains(VoiceLatencyPoint.speechEndpoint)));
        await engine.dispose();
        await session.incoming.close();
      },
    );

    test('stop during permission prevents WebSocket creation', () async {
      final permission = Completer<bool>();
      final recorder = _FakeServerRecorder()..permission = permission.future;
      var connectCalls = 0;
      final engine = ServerSttEngine(
        baseUrl: 'ws://127.0.0.1:9123',
        recorderFactory: () => recorder,
        connector: (_) async {
          connectCalls++;
          return _FakeServerSession();
        },
      );
      final done = engine.listen().drain<void>();
      await _flush();

      await engine.stop();
      permission.complete(true);
      await done.timeout(const Duration(seconds: 1));

      expect(connectCalls, 0);
      expect(recorder.startCalls, 0);
      await engine.dispose();
    });

    test(
      'dispose during connect closes the late socket before microphone',
      () async {
        final connection = Completer<ServerSttSession>();
        final recorder = _FakeServerRecorder();
        final session = _FakeServerSession();
        final engine = ServerSttEngine(
          baseUrl: 'ws://127.0.0.1:9123',
          recorderFactory: () => recorder,
          connector: (_) => connection.future,
        );
        final done = engine.listen().drain<void>();
        while (recorder.permissionCalls == 0) {
          await _flush();
        }
        await _flush();

        var disposeCompleted = false;
        final disposing = engine.dispose().then((_) => disposeCompleted = true);
        await _flush();
        expect(disposeCompleted, isFalse);
        connection.complete(session);
        await disposing;
        await done.timeout(const Duration(seconds: 1));

        expect(session.closeCalls, 1);
        expect(recorder.startCalls, 0);
        expect(recorder.stopAfterDisposeCalls, 0);
      },
    );

    test('stop during recorder start never subscribes to late audio', () async {
      final audio = StreamController<Uint8List>.broadcast(
        onListen: () => throw StateError('stale audio was subscribed'),
      );
      final starting = Completer<Stream<Uint8List>>();
      final recorder = _FakeServerRecorder()..starting = starting.future;
      final session = _FakeServerSession();
      final engine = ServerSttEngine(
        baseUrl: 'ws://127.0.0.1:9123',
        recorderFactory: () => recorder,
        connector: (_) async => session,
      );
      final done = engine.listen().drain<void>();
      while (recorder.startCalls == 0) {
        await _flush();
      }

      await engine.stop();
      starting.complete(audio.stream);
      await done.timeout(const Duration(seconds: 1));

      expect(recorder.stopCalls, greaterThanOrEqualTo(1));
      await engine.dispose();
      await audio.close();
      await session.incoming.close();
    });

    test(
      'stale A completion never cancels the WebSocket subscription of B',
      () async {
        final firstStart = Completer<Stream<Uint8List>>();
        final firstRecorder = _FakeServerRecorder()
          ..starting = firstStart.future;
        final secondRecorder = _FakeServerRecorder();
        var bCancelCalls = 0;
        final sessions = <_FakeServerSession>[
          _FakeServerSession(),
          _FakeServerSession(onCancel: () => bCancelCalls++),
        ];
        var recorderIndex = 0;
        var sessionIndex = 0;
        final engine = ServerSttEngine(
          baseUrl: 'ws://127.0.0.1:9123',
          recorderFactory: () =>
              [firstRecorder, secondRecorder][recorderIndex++],
          connector: (_) async => sessions[sessionIndex++],
        );
        final firstDone = engine.listen().drain<void>();
        await _waitUntil(() => firstRecorder.startCalls == 1);

        final values = <SttResult>[];
        final secondDone = engine.listen().listen(values.add).asFuture<void>();
        await _flush();
        expect(secondRecorder.startCalls, 0);
        firstStart.complete(const Stream<Uint8List>.empty());
        await _waitUntil(() => secondRecorder.startCalls == 1);
        await _flush();
        sessions[1].incoming.add('{"type":"partial","text":"alive"}');
        await _flush();

        expect(bCancelCalls, 0);
        expect(values.map((value) => value.text), contains('alive'));
        await engine.dispose();
        await firstDone.timeout(const Duration(seconds: 1));
        await secondDone.timeout(const Duration(seconds: 1));
        await sessions[0].incoming.close();
        await sessions[1].incoming.close();
      },
    );

    test('listen B waits for a non-awaited stop of A', () async {
      final stopGate = Completer<void>();
      final firstRecorder = _FakeServerRecorder()..stopping = stopGate.future;
      final secondRecorder = _FakeServerRecorder();
      final sessions = <_FakeServerSession>[
        _FakeServerSession(),
        _FakeServerSession(),
      ];
      var recorderIndex = 0;
      var sessionIndex = 0;
      final engine = ServerSttEngine(
        baseUrl: 'ws://127.0.0.1:9123',
        recorderFactory: () => [firstRecorder, secondRecorder][recorderIndex++],
        connector: (_) async => sessions[sessionIndex++],
      );
      final firstDone = engine.listen().drain<void>();
      await _waitUntil(() => firstRecorder.startCalls == 1);

      final stopping = engine.stop();
      final secondDone = engine.listen().drain<void>();
      await _flush();
      final startedBeforeStop = secondRecorder.permissionCalls > 0;

      stopGate.complete();
      await stopping;
      await _waitUntil(() => secondRecorder.startCalls == 1);
      await engine.dispose();
      await firstDone.timeout(const Duration(seconds: 1));
      await secondDone.timeout(const Duration(seconds: 1));
      expect(startedBeforeStop, isFalse);
      await sessions[0].incoming.close();
      await sessions[1].incoming.close();
    });
  });

  group('SherpaSttEngine startup cancellation', () {
    SherpaSttEngine engineFor(_FakeSherpaRuntime runtime) => SherpaSttEngine(
      model: sherpaModelByKind(SherpaModelKind.whisperBase),
      runtime: runtime,
    );

    test('stop during model readiness prevents native preparation', () async {
      final ready = Completer<bool>();
      final runtime = _FakeSherpaRuntime()..ready = ready.future;
      final engine = engineFor(runtime);
      final done = engine.listen().drain<void>();
      while (runtime.readyCalls == 0) {
        await _flush();
      }

      await engine.stop();
      ready.complete(true);
      await done.timeout(const Duration(seconds: 1));

      expect(runtime.prepareCalls, 0);
      expect(runtime.startCalls, 0);
      await engine.dispose();
    });

    test(
      'dispose during native preparation closes the early recorder',
      () async {
        final preparing = Completer<void>();
        final runtime = _FakeSherpaRuntime()..preparing = preparing.future;
        final engine = engineFor(runtime);
        final done = engine.listen().drain<void>();
        while (runtime.prepareCalls == 0) {
          await _flush();
        }

        var disposeCompleted = false;
        final disposing = engine.dispose().then((_) => disposeCompleted = true);
        final disposingAgain = engine.dispose();
        await _flush();
        expect(disposeCompleted, isFalse);
        preparing.complete();
        await disposing;
        await disposingAgain;
        await done.timeout(const Duration(seconds: 1));

        expect(runtime.startCalls, 1);
        expect(runtime.disposeCalls, 1);
        expect(runtime.stopAfterDisposeCalls, 0);
      },
    );

    test('stop during recorder start rejects the late audio stream', () async {
      final audio = StreamController<Uint8List>.broadcast(
        onListen: () => throw StateError('stale Sherpa audio was subscribed'),
      );
      final starting = Completer<Stream<Uint8List>>();
      final runtime = _FakeSherpaRuntime()..starting = starting.future;
      final engine = engineFor(runtime);
      final done = engine.listen().drain<void>();
      while (runtime.startCalls == 0) {
        await _flush();
      }

      await engine.stop();
      starting.complete(audio.stream);
      await done.timeout(const Duration(seconds: 1));

      expect(runtime.stopCalls, greaterThanOrEqualTo(1));
      await engine.dispose();
      await audio.close();
    });

    test('listen B waits for a non-awaited stop of A', () async {
      final stopGate = Completer<void>();
      final runtime = _FakeSherpaRuntime()..stopping = stopGate.future;
      final engine = engineFor(runtime);
      final firstDone = engine.listen().drain<void>();
      await _waitUntil(() => runtime.startCalls == 1);

      final stopping = engine.stop();
      final secondDone = engine.listen().drain<void>();
      await _flush();
      final startedBeforeStop = runtime.startCalls > 1;

      stopGate.complete();
      await stopping;
      await _waitUntil(() => runtime.startCalls == 2);
      runtime.stopping = Future<void>.value();
      await engine.stop();
      await firstDone.timeout(const Duration(seconds: 1));
      await secondDone.timeout(const Duration(seconds: 1));
      expect(startedBeforeStop, isFalse);
      await engine.dispose();
    });
  });
}
