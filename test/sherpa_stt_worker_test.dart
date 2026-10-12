import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/sherpa_stt_worker.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';
import 'package:hermes_android/core/services/voice/voice_latency_trace.dart';
import 'package:record/record.dart';

class _FakeManager extends SherpaSttModelManager {
  @override
  Future<String> tokensPath(SherpaSttModel model) async => '/model/tokens.txt';

  @override
  Future<String> encoderPath(SherpaSttModel model) async =>
      '/model/encoder.onnx';

  @override
  Future<String> decoderPath(SherpaSttModel model) async =>
      '/model/decoder.onnx';

  @override
  Future<String> joinerPath(SherpaSttModel model) async => '/model/joiner.onnx';

  @override
  Future<String> sileroPath() async => '/model/silero.onnx';
}

void _expectDesktopSpeechCaptureConfig() {
  expect(kSherpaSttRecordConfig.encoder, AudioEncoder.pcm16bits);
  expect(kSherpaSttRecordConfig.sampleRate, 16000);
  expect(kSherpaSttRecordConfig.numChannels, 1);
  expect(kSherpaSttRecordConfig.echoCancel, isTrue);
  expect(kSherpaSttRecordConfig.noiseSuppress, isTrue);
  expect(
    kSherpaSttRecordConfig.androidConfig.audioSource,
    AndroidAudioSource.voiceRecognition,
  );
}

class _FakeRuntime implements SherpaSttRuntime {
  final StreamController<Uint8List> audio =
      StreamController<Uint8List>.broadcast();

  int prepareCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  Completer<void>? startGate;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> modelReady() async => true;

  @override
  Future<void> prepare() async {
    prepareCalls++;
  }

  @override
  Future<Stream<Uint8List>> startStream() async {
    startCalls++;
    await startGate?.future;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _FakeWorker implements SherpaSttWorker {
  final StreamController<SherpaSttWorkerUpdate> updatesController =
      StreamController<SherpaSttWorkerUpdate>.broadcast();
  Completer<void>? prepareGate;
  Completer<void>? flushGate;
  List<String> flushSegments = const [];
  List<String> acceptSegments = const [];

  /// The real gate, fed like the isolate feeds it.
  final SherpaSpeechGate gate = SherpaSpeechGate();

  final List<int> acceptedGenerations = [];
  final List<int> acceptedLengths = [];
  final List<int> flushGenerations = [];
  int prepareCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<SherpaSttWorkerUpdate> get updates => updatesController.stream;

  @override
  Future<void> prepare() async {
    prepareCalls++;
    await prepareGate?.future;
  }

  @override
  void accept(Uint8List pcm16, {required int generation}) {
    acceptedGenerations.add(generation);
    acceptedLengths.add(pcm16.length);
    if (acceptSegments.isNotEmpty) {
      emit(generation: generation, segments: acceptSegments);
    }
  }

  @override
  Future<List<String>> flush({required int generation}) async {
    flushGenerations.add(generation);
    await flushGate?.future;
    return flushSegments;
  }

  /// One chunk of [frames] 30 ms frames at [level]. [segments] is the text
  /// Whisper would write for a segment made of those frames: as in the
  /// isolate, it is only "transcribed" when the gate finds speech in it.
  void emit({
    required int generation,
    double level = 0.5,
    bool speechDetected = true,
    int frames = SherpaSpeechGate.sustainedWindow,
    List<String> segments = const [],
  }) {
    final evidence = gate.accept(
      _steady(level, frames),
      speechDetected: speechDetected,
    );
    final kept =
        segments.isEmpty || gate.levelsHaveSpeech(List.filled(frames, level));
    updatesController.add(
      SherpaSttWorkerUpdate(
        generation: generation,
        level: level,
        speechDetected: speechDetected,
        acousticSpeechEvidence: evidence,
        segments: kept ? segments : const [],
        rejectedSegments: kept ? 0 : segments.length,
        rejectedMs: kept ? 0 : frames * 30,
        rejectedPeak: kept ? 0 : level,
        noiseFloor: gate.noiseFloor,
        trigger: gate.trigger,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (!updatesController.isClosed) await updatesController.close();
  }
}

/// The worker isolate's protocol without the native library. `numThreads` is
/// how long "opening the model" keeps it inside one call, and `tokensPath` a
/// file where it leaves what it did last.
void _fakeWorkerIsolate(Map<String, Object?> bootstrap) {
  final replyTo = bootstrap['replyTo']! as SendPort;
  final state = File(bootstrap['tokensPath']! as String);
  final commands = ReceivePort();
  replyTo.send(commands.sendPort);
  commands.listen((message) {
    if (message is! Map) return;
    switch (message['type']) {
      case 'prepare':
        sleep(Duration(milliseconds: bootstrap['numThreads']! as int));
        state.writeAsStringSync('loaded');
        replyTo.send({
          'type': 'result',
          'id': message['id'],
          'load': const {'bindings': 3, 'recognizer': 40, 'vad': 5},
        });
      case 'dispose':
        state.writeAsStringSync('freed');
        replyTo.send(const {'type': 'disposed'});
        commands.close();
    }
  });
}

/// [samples] PCM16 samples of a steady signal at [amplitude] of full scale.
Uint8List _pcm16Steady(double amplitude, int samples) {
  final data = ByteData(samples * 2);
  for (var index = 0; index < samples; index++) {
    data.setInt16(index * 2, (amplitude * 32768).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// [frames] 30 ms frames of a steady signal whose Sherpa level is [level].
Float32List _steady(double level, int frames) =>
    Float32List(SherpaSpeechGate.frameSamples * frames)
      ..fillRange(0, SherpaSpeechGate.frameSamples * frames, level / 4);

/// A gate that has heard [frames] quiet frames at [floor].
SherpaSpeechGate _gateInRoom(double floor, {int frames = 20}) {
  final gate = SherpaSpeechGate();
  for (var index = 0; index < frames; index++) {
    gate.acceptLevelFrame(floor, speechDetected: false);
  }
  return gate;
}

/// A second of a spoken sentence whose loudest frame is [peak]: syllables
/// rise and fall, with the dips between words that an absolute level missed.
List<double> _sentence(double peak) => [
  for (var syllable = 0; syllable < 4; syllable++)
    for (final part in const [0.3, 0.7, 1.0, 0.85, 0.6, 0.35, 0.15, 0.1])
      peak * part,
];

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

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

Uint8List _pcm16Wav(Uint8List pcm) {
  final wav = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(wav);

  void tag(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      wav[offset + index] = value.codeUnitAt(index);
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  wav.setRange(44, wav.length, pcm);
  return wav;
}

SherpaSttEngine _engine(
  _FakeRuntime runtime,
  _FakeWorker worker, {
  void Function(SherpaSttWorkerConfig config)? onConfig,
  VoiceTurnTimerFactory? timerFactory,
}) => SherpaSttEngine(
  model: sherpaModelByKind(SherpaModelKind.whisperBase),
  manager: _FakeManager(),
  runtime: runtime,
  timerFactory: timerFactory,
  workerFactory: (config) async {
    onConfig?.call(config);
    return worker;
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dictado local captura habla con el preset acústico de Desktop', () {
    _expectDesktopSpeechCaptureConfig();
  });

  group('speech gate', () {
    // What the owner's Pixel logged on 2026-10-12: sentences the recogniser
    // understood, loudest chunk at these levels, in a quiet room. Desktop's
    // absolute level threw four of the five away.
    const pixelPeaks = [0.080, 0.084, 0.106, 0.170, 0.183];
    const quietRoom = 0.006;

    test('a sentence spoken to a phone is speech at every logged level', () {
      for (final peak in pixelPeaks) {
        final gate = _gateInRoom(quietRoom);
        expect(gate.trigger, lessThan(0.03), reason: 'peak $peak');
        final sentence = _sentence(peak);

        // As the segment the VAD closes...
        expect(gate.levelsHaveSpeech(sentence), isTrue, reason: 'peak $peak');
        // ...and live, so the turn can end on the silence that follows.
        for (final level in sentence) {
          gate.acceptLevelFrame(level, speechDetected: true);
        }
        expect(gate.hasEvidence, isTrue, reason: 'peak $peak');
      }
    });

    test('the quietest logged sentence is speech in a room that is not '
        'quiet', () {
      // A fan, a street behind the window: the floor is three times higher
      // and the sentence only peaks 12 dB above it.
      final gate = _gateInRoom(0.02);
      final sentence = _sentence(pixelPeaks.first);

      expect(gate.levelsHaveSpeech(sentence), isTrue);
      for (final level in sentence) {
        gate.acceptLevelFrame(level, speechDetected: true);
      }
      expect(gate.hasEvidence, isTrue);
      // The room's own noise, taken for a word by the VAD, still is not.
      expect(gate.levelsHaveSpeech(List.filled(40, 0.03)), isFalse);
    });

    test('the same sentence as PCM is speech too', () {
      final gate = _gateInRoom(quietRoom);
      final sentence = _sentence(pixelPeaks.first);
      final pcm = Float32List(SherpaSpeechGate.frameSamples * sentence.length);
      for (var frame = 0; frame < sentence.length; frame++) {
        pcm.fillRange(
          frame * SherpaSpeechGate.frameSamples,
          (frame + 1) * SherpaSpeechGate.frameSamples,
          sentence[frame] / 4,
        );
      }
      expect(gate.segmentHasSpeech(pcm), isTrue);
    });

    test('silence is not speech, whatever the VAD says', () {
      final gate = _gateInRoom(quietRoom);
      // The VAD cut a segment out of the room's own hiss.
      final hiss = [
        for (var frame = 0; frame < 40; frame++)
          quietRoom * (0.6 + frame % 3 * 0.4),
      ];
      expect(gate.levelsHaveSpeech(hiss), isFalse);
      for (final level in hiss) {
        gate.acceptLevelFrame(level, speechDetected: true);
      }
      expect(gate.hasEvidence, isFalse);

      // Digital silence in a room that is not known yet.
      final fresh = SherpaSpeechGate();
      expect(fresh.calibrated, isFalse);
      expect(fresh.levelsHaveSpeech(List.filled(40, 0.004)), isFalse);
    });

    test('a breath is not speech', () {
      final gate = _gateInRoom(quietRoom);
      // The VAD does not call it speech: it only joins the room's noise.
      for (var frame = 0; frame < 20; frame++) {
        gate.acceptLevelFrame(0.03, speechDetected: false);
      }
      expect(gate.hasEvidence, isFalse);
      // A breath the VAD does mistake for a word, too faint to stand out.
      expect(gate.levelsHaveSpeech(List.filled(12, 0.01)), isFalse);
    });

    test('key presses are not speech', () {
      final gate = _gateInRoom(quietRoom);
      // Loud, but one frame each: nothing is sustained.
      final typing = [
        for (var frame = 0; frame < 60; frame++)
          frame % 4 == 0 ? 0.25 : quietRoom,
      ];
      expect(gate.levelsHaveSpeech(typing), isFalse);
      for (final level in typing) {
        gate.acceptLevelFrame(level, speechDetected: true);
      }
      expect(gate.hasEvidence, isFalse);

      // Two keys in a row are still not a word.
      expect(
        gate.levelsHaveSpeech([
          for (var frame = 0; frame < 60; frame++)
            frame % 6 < 2 ? 0.25 : quietRoom,
        ]),
        isFalse,
      );
    });

    test('a burst the VAD does not call speech arms nothing', () {
      final gate = _gateInRoom(quietRoom);
      expect(gate.accept(_steady(0.32, 10), speechDetected: false), isFalse);
      expect(gate.hasEvidence, isFalse);

      expect(gate.accept(_steady(0.008, 3), speechDetected: true), isFalse);
      expect(gate.hasEvidence, isFalse);
    });

    test('speech needs four of five frames, and dips do not reset it', () {
      const loud = 0.1;
      final gate = _gateInRoom(quietRoom);
      for (final level in <double>[loud, loud, loud]) {
        expect(gate.acceptLevelFrame(level, speechDetected: true), isFalse);
      }
      // A dip inside the word...
      expect(gate.acceptLevelFrame(quietRoom, speechDetected: true), isFalse);
      // ...and the fourth frame above closes the run.
      expect(gate.acceptLevelFrame(loud, speechDetected: true), isTrue);
      // Evidence stays for the utterance, through the pauses between words.
      expect(gate.acceptLevelFrame(quietRoom, speechDetected: false), isTrue);
    });

    test('30 ms frames survive PCM chunks that do not line up', () {
      final gate = _gateInRoom(quietRoom);
      final samples = _steady(0.12, SherpaSpeechGate.sustainedWindow);

      expect(
        gate.accept(
          Float32List.sublistView(samples, 0, 1000),
          speechDetected: true,
        ),
        isFalse,
      );
      expect(
        gate.accept(
          Float32List.sublistView(samples, 1000),
          speechDetected: true,
        ),
        isTrue,
      );
    });

    test('the trigger follows the room, within its bounds', () {
      final unknown = SherpaSpeechGate();
      expect(unknown.noiseFloor, 0);
      expect(unknown.trigger, SherpaSpeechGate.minimumTrigger);

      // A suppressor's residue never counts as sound.
      expect(_gateInRoom(0.001).trigger, SherpaSpeechGate.minimumTrigger);
      expect(_gateInRoom(0.01).trigger, closeTo(0.02, 1e-9));
      // Never stricter than the level Desktop uses.
      expect(_gateInRoom(0.08).trigger, SherpaSpeechGate.desktopLevel);

      // It keeps adapting: the room gets noisier, then the floor moves.
      final gate = _gateInRoom(0.004, frames: 100);
      expect(gate.noiseFloor, closeTo(0.004, 1e-9));
      for (var frame = 0; frame < 40; frame++) {
        gate.acceptLevelFrame(0.02, speechDetected: false);
      }
      expect(gate.noiseFloor, closeTo(0.004, 1e-9));
      for (var frame = 0; frame < 20; frame++) {
        gate.acceptLevelFrame(0.02, speechDetected: false);
      }
      expect(gate.noiseFloor, closeTo(0.02, 1e-9));
    });

    test('whatever passed the old rule passes in any room', () {
      const high = SherpaSpeechGate.desktopLevel + 0.01;
      const low = SherpaSpeechGate.desktopLevel - 0.01;
      // Desktop's majority: 8 of the last 10 frames at its level.
      const old = [high, high, low, high, high, high, low, high, high, high];
      for (final room in <double>[0, 0.002, 0.02, 0.09]) {
        final gate = room == 0 ? SherpaSpeechGate() : _gateInRoom(room);
        expect(gate.levelsHaveSpeech(old), isTrue, reason: 'room $room');
      }
    });

    test('a new utterance keeps the room and drops the evidence', () {
      final gate = _gateInRoom(0.01);
      for (var frame = 0; frame < 5; frame++) {
        gate.acceptLevelFrame(0.2, speechDetected: true);
      }
      expect(gate.hasEvidence, isTrue);

      gate.resetUtterance();
      expect(gate.hasEvidence, isFalse);
      expect(gate.noiseFloor, closeTo(0.01, 1e-9));

      gate.reset();
      expect(gate.calibrated, isFalse);
      expect(gate.trigger, SherpaSpeechGate.minimumTrigger);
    });
  });

  test('publica capture ready solo después del ACK de startStream', () async {
    final runtime = _FakeRuntime()..startGate = Completer<void>();
    final worker = _FakeWorker();
    final engine = _engine(runtime, worker);
    var readyCalls = 0;

    final done = engine
        .listen(onCaptureReady: () => readyCalls++)
        .drain<void>();
    await _waitFor(() => runtime.startCalls == 1);
    expect(readyCalls, 0);

    runtime.startGate!.complete();
    await _waitFor(() => readyCalls == 1);

    await engine.stop();
    await done.timeout(const Duration(seconds: 1));
    await engine.dispose();
    await runtime.audio.close();
  });

  test('solo dice que escucha cuando el reconocedor está cargado, y lo dicho '
      'mientras tanto no se pierde', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker()..prepareGate = Completer<void>();
    final timers = _ManualVoiceTurnTimers();
    final engine = _engine(runtime, worker, timerFactory: timers.create);
    var captureReady = 0;
    final subscription = engine
        .listen(onCaptureReady: () => captureReady++)
        .listen((_) {});

    await _waitFor(() => worker.prepareCalls == 1);
    // The microphone is open and the user is already talking...
    runtime.audio.add(Uint8List(640));
    runtime.audio.add(Uint8List(320));
    await Future<void>.delayed(Duration.zero);
    // ...but nobody is listening yet: no "listening", no countdown to a
    // first word that could not be heard anyway.
    expect(runtime.startCalls, 1);
    expect(captureReady, 0);
    expect(timers.created, isEmpty);

    worker.prepareGate!.complete();
    await _waitFor(() => captureReady == 1);
    // What was said meanwhile reached the recogniser, in order.
    expect(worker.acceptedLengths, [640, 320]);
    expect(timers.created, hasLength(1));

    await subscription.cancel();
    await engine.dispose();
    await runtime.audio.close();
  });

  test('aparcar suelta el micro sin transcribir y deja el reconocedor '
      'cargado para el siguiente arranque', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker()..flushSegments = const ['no debe salir'];
    var workersBuilt = 0;
    final engine = SherpaSttEngine(
      model: sherpaModelByKind(SherpaModelKind.whisperBase),
      manager: _FakeManager(),
      runtime: runtime,
      workerFactory: (_) async {
        workersBuilt++;
        return worker;
      },
    );
    final results = <SttResult>[];
    final done = Completer<void>();
    engine.listen().listen(results.add, onDone: done.complete);
    await _waitFor(() => worker.prepareCalls == 1);
    runtime.audio.add(Uint8List(640));
    await _waitFor(() => worker.acceptedGenerations.isNotEmpty);

    await engine.park();
    await done.future;

    expect(runtime.stopCalls, 1, reason: 'the microphone is released');
    expect(worker.flushGenerations, isEmpty, reason: 'nothing is transcribed');
    expect(results, isEmpty);
    expect(worker.disposeCalls, 0, reason: 'the recogniser stays loaded');
    expect(runtime.disposeCalls, 0);

    // The next start reuses it: no second load.
    var captureReady = 0;
    final again = engine
        .listen(onCaptureReady: () => captureReady++)
        .listen((_) {});
    await _waitFor(() => captureReady == 1);
    expect(workersBuilt, 1);
    expect(worker.prepareCalls, 2);

    await again.cancel();
    await engine.dispose();
    expect(worker.disposeCalls, 1, reason: 'released for good with the engine');
    await runtime.audio.close();
  });

  test(
    'precalentar carga el reconocedor una vez y antes de abrir el micro',
    () async {
      final runtime = _FakeRuntime();
      final worker = _FakeWorker();
      var workersBuilt = 0;
      final engine = SherpaSttEngine(
        model: sherpaModelByKind(SherpaModelKind.whisperBase),
        manager: _FakeManager(),
        runtime: runtime,
        workerFactory: (_) async {
          workersBuilt++;
          return worker;
        },
      );

      await Future.wait([engine.prewarm(), engine.prewarm()]);
      await engine.prewarm();
      expect(workersBuilt, 1);
      expect(worker.prepareCalls, 1);
      expect(
        runtime.startCalls,
        0,
        reason: 'warming never opens the microphone',
      );

      var captureReady = 0;
      final subscription = engine
          .listen(onCaptureReady: () => captureReady++)
          .listen((_) {});
      await _waitFor(() => captureReady == 1);
      expect(workersBuilt, 1);
      // While a capture runs, warming leaves its recogniser alone.
      await engine.prewarm();
      expect(worker.prepareCalls, 2);

      await subscription.cancel();
      await engine.dispose();
      await engine.prewarm();
      expect(workersBuilt, 1);
      await runtime.audio.close();
    },
  );

  test('cierra a los 12 s sin proyectar fin de habla inexistente', () async {
    final timers = _ManualVoiceTurnTimers();
    final runtime = _FakeRuntime();
    final worker = _FakeWorker();
    var speechEnds = 0;
    final engine = _engine(runtime, worker, timerFactory: timers.create);
    final done = engine.listen(onSpeechEnd: () => speechEnds++).drain<void>();
    await _waitFor(() => runtime.startCalls == 1 && timers.created.isNotEmpty);

    expect(timers.created.single.duration, kVoiceTurnIdleSilenceTimeout);
    timers.created.single.fire();

    await _waitFor(() => runtime.stopCalls == 1);
    await done.timeout(const Duration(seconds: 1));
    expect(speechEnds, 0);

    await engine.dispose();
    await runtime.audio.close();
  });

  test('la primera detección de voz cancela el idle', () async {
    final timers = _ManualVoiceTurnTimers();
    final runtime = _FakeRuntime();
    final worker = _FakeWorker();
    final engine = _engine(runtime, worker, timerFactory: timers.create);
    final done = engine.listen().drain<void>();
    await _waitFor(
      () =>
          runtime.startCalls == 1 &&
          worker.prepareCalls == 1 &&
          timers.created.isNotEmpty,
    );

    worker.emit(generation: 1, speechDetected: true);
    await Future<void>.delayed(Duration.zero);
    expect(timers.created.single.isActive, isFalse);
    timers.created.single.fire();
    expect(runtime.stopCalls, 0);

    await engine.stop();
    await done.timeout(const Duration(seconds: 1));
    await engine.dispose();
    await runtime.audio.close();
  });

  test('Sherpa traza última voz, endpoint, STT y final causalmente', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker()..flushSegments = const ['turno'];
    final records = <VoiceLatencyRecord>[];
    var nowMicros = 1000;
    final trace = VoiceLatencyTrace.testing(
      runId: 'abcdef0123456789',
      nowMicros: () => nowMicros += 100,
      onRecord: records.add,
    );
    trace.beginTurn(
      route: VoiceLatencyRoute.phone,
      scenario: VoiceLatencyScenario.normal,
      sttTopology: VoiceSttTopology.recordThenTranscribe,
      lastAboveAvailability: VoiceLatencyAvailability.measured,
    );
    final engine = SherpaSttEngine(
      model: sherpaModelByKind(SherpaModelKind.whisperBase),
      manager: _FakeManager(),
      runtime: runtime,
      silenceTimeout: Duration.zero,
      workerFactory: (_) async => worker,
    );

    await trace.runScoped(() async {
      final done = engine.listen().drain<void>();
      await _waitFor(() => runtime.startCalls == 1 && worker.prepareCalls == 1);
      worker.emit(generation: 1, speechDetected: true);
      worker.emit(generation: 1, speechDetected: false);
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
    await engine.dispose();
    await runtime.audio.close();
  });

  test(
    'transcribe el WAV full-duplex local sin abrir otro micrófono',
    () async {
      final runtime = _FakeRuntime();
      final worker = _FakeWorker()..flushSegments = const ['Cállate'];
      final engine = _engine(runtime, worker);
      final pcm = Uint8List.fromList(const [1, 0, 2, 0, 3, 0, 4, 0]);

      expect(await engine.transcribeCapturedWav(_pcm16Wav(pcm)), 'Cállate');
      expect(runtime.startCalls, 0);
      expect(runtime.stopCalls, 0);
      expect(worker.prepareCalls, 1);
      expect(worker.acceptedGenerations, hasLength(1));
      expect(worker.acceptedLengths, [pcm.length]);
      expect(worker.flushGenerations, worker.acceptedGenerations);

      await engine.dispose();
      await runtime.audio.close();
    },
  );

  test(
    'conserva segmentos emitidos al aceptar antes del flush final',
    () async {
      final runtime = _FakeRuntime();
      final worker = _FakeWorker()
        ..acceptSegments = const ['Busca las tareas pendientes']
        ..flushSegments = const ['y dime qué queda por publicar'];
      final engine = _engine(runtime, worker);
      final pcm = Uint8List.fromList(const [1, 0, 2, 0, 3, 0, 4, 0]);

      expect(
        await engine.transcribeCapturedWav(_pcm16Wav(pcm)),
        'Busca las tareas pendientes y dime qué queda por publicar',
      );

      await engine.dispose();
      await runtime.audio.close();
    },
  );

  test('rechaza WAV incompatible antes de crear el worker', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker();
    final engine = _engine(runtime, worker);

    await expectLater(
      engine.transcribeCapturedWav(Uint8List.fromList(const [1, 2, 3])),
      throwsFormatException,
    );
    expect(worker.prepareCalls, 0);
    expect(runtime.startCalls, 0);

    await engine.dispose();
    await runtime.audio.close();
  });

  test(
    'abre el micro mientras prepara el worker sin bloquear Flutter',
    () async {
      final runtime = _FakeRuntime();
      final worker = _FakeWorker()..prepareGate = Completer<void>();
      SherpaSttWorkerConfig? config;
      final engine = _engine(
        runtime,
        worker,
        onConfig: (value) => config = value,
      );
      final done = engine.listen().drain<void>();

      await _waitFor(() => worker.prepareCalls == 1);
      var eventLoopAdvanced = false;
      scheduleMicrotask(() => eventLoopAdvanced = true);
      await Future<void>.delayed(Duration.zero);

      expect(eventLoopAdvanced, isTrue);
      expect(runtime.startCalls, 1);
      expect(config?.language, 'es');
      expect(config?.encoderPath, '/model/encoder.onnx');

      runtime.audio.add(Uint8List.fromList(const [0, 0]));
      await _waitFor(() => worker.acceptedGenerations.isNotEmpty);

      worker.prepareGate!.complete();
      await engine.stop();
      await done;
      await engine.dispose();
      await runtime.audio.close();
    },
  );

  test('conserva el PCM recibido antes de que exista el worker', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker();
    final workerGate = Completer<SherpaSttWorker>();
    final engine = SherpaSttEngine(
      model: sherpaModelByKind(SherpaModelKind.whisperBase),
      manager: _FakeManager(),
      runtime: runtime,
      workerFactory: (_) => workerGate.future,
    );
    final done = engine.listen().drain<void>();

    await _waitFor(() => runtime.startCalls == 1);
    runtime.audio.add(Uint8List.fromList(const [1, 0, 2, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(worker.acceptedGenerations, isEmpty);

    workerGate.complete(worker);
    await _waitFor(() => worker.acceptedGenerations.length == 1);

    await engine.stop();
    await done;
    await engine.dispose();
    await runtime.audio.close();
  });

  test('stop durante arranque drena el PCM antes de cerrar el final', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker()
      ..flushSegments = const ['frase conservada']
      ..flushGate = Completer<void>();
    final workerGate = Completer<SherpaSttWorker>();
    final engine = SherpaSttEngine(
      model: sherpaModelByKind(SherpaModelKind.whisperBase),
      manager: _FakeManager(),
      runtime: runtime,
      workerFactory: (_) => workerGate.future,
    );
    final resultsFuture = engine.listen().toList();

    await _waitFor(() => runtime.startCalls == 1);
    runtime.audio.add(Uint8List.fromList(const [1, 0, 2, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(worker.acceptedGenerations, isEmpty);

    var stopCompleted = false;
    final stopping = engine.stop().whenComplete(() => stopCompleted = true);
    await Future<void>.delayed(Duration.zero);
    final completedBeforeWorker = stopCompleted;

    workerGate.complete(worker);
    await _waitFor(
      () =>
          worker.acceptedGenerations.isNotEmpty &&
          worker.flushGenerations.isNotEmpty,
    );
    worker.emit(
      generation: worker.acceptedGenerations.single,
      level: 0.5,
      speechDetected: true,
    );
    await Future<void>.delayed(Duration.zero);
    worker.flushGate!.complete();
    await stopping;
    final results = await resultsFuture;

    expect(completedBeforeWorker, isFalse);
    expect(worker.acceptedGenerations, hasLength(1));
    expect(results.last.text, 'frase conservada');
    expect(results.last.isFinal, isTrue);

    await engine.dispose();
    await runtime.audio.close();
  });

  test('no descarta dictados largos mientras arranca el worker', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker();
    final workerGate = Completer<SherpaSttWorker>();
    final engine = SherpaSttEngine(
      model: sherpaModelByKind(SherpaModelKind.whisperBase),
      manager: _FakeManager(),
      runtime: runtime,
      workerFactory: (_) => workerGate.future,
    );
    final done = engine.listen().drain<void>();

    await _waitFor(() => runtime.startCalls == 1);
    runtime.audio.add(Uint8List(16000 * 2 * 16));
    await Future<void>.delayed(Duration.zero);
    expect(worker.acceptedGenerations, isEmpty);

    workerGate.complete(worker);
    await _waitFor(() => worker.acceptedGenerations.length == 1);

    await engine.stop();
    await done;
    await engine.dispose();
    await runtime.audio.close();
  });

  test('stop conserva updates del worker que ya estaban en tránsito', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker()..flushGate = Completer<void>();
    final engine = _engine(runtime, worker);
    final results = <SttResult>[];
    final done = Completer<void>();
    engine.listen().listen(results.add, onDone: done.complete);

    await _waitFor(() => runtime.startCalls == 1);
    runtime.audio.add(Uint8List.fromList(const [0, 0]));
    await _waitFor(() => worker.acceptedGenerations.isNotEmpty);
    final generation = worker.acceptedGenerations.single;

    final stopping = engine.stop();
    await _waitFor(() => worker.flushGenerations.isNotEmpty);
    worker.emit(generation: generation, segments: const ['último segmento']);
    await Future<void>.delayed(Duration.zero);
    worker.flushGate!.complete();

    await stopping;
    await done.future;
    expect(results.last.text, 'último segmento');
    expect(results.last.isFinal, isTrue);

    await engine.dispose();
    await runtime.audio.close();
  });

  test(
    'filtra ruido Whisper por segmento sin borrar el dictado válido',
    () async {
      final runtime = _FakeRuntime();
      final worker = _FakeWorker();
      final engine = _engine(runtime, worker);
      final results = <SttResult>[];
      final done = Completer<void>();
      engine.listen().listen(results.add, onDone: done.complete);

      await _waitFor(() => runtime.startCalls == 1);
      runtime.audio.add(Uint8List.fromList(const [0, 0]));
      await _waitFor(() => worker.acceptedGenerations.isNotEmpty);
      final generation = worker.acceptedGenerations.single;
      worker.emit(
        generation: generation,
        segments: const [
          'abre las noticias',
          'Gracias',
          'Adiós',
          'Thanks for watching',
        ],
      );
      await _waitFor(() => results.isNotEmpty);

      expect(results.single.text, 'abre las noticias Gracias Adiós');
      await engine.stop();
      await done.future;
      expect(results.last.text, 'abre las noticias Gracias Adiós');
      expect(results.last.isFinal, isTrue);

      await engine.dispose();
      await runtime.audio.close();
    },
  );

  test('una frase dicha al teléfono llega aunque no alcance el nivel de '
      'Desktop', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker();
    final engine = _engine(runtime, worker);
    final results = <SttResult>[];
    final done = Completer<void>();
    engine.listen().listen(results.add, onDone: done.complete);

    await _waitFor(() => runtime.startCalls == 1);
    runtime.audio.add(Uint8List.fromList(const [0, 0]));
    await _waitFor(() => worker.acceptedGenerations.isNotEmpty);
    final generation = worker.acceptedGenerations.single;

    // A quiet room, then a sentence whose loudest chunk is the weakest the
    // Pixel logged (0.080): under Desktop's 0.098 from start to end.
    worker.emit(
      generation: generation,
      level: 0.006,
      speechDetected: false,
      frames: 20,
    );
    worker.emit(
      generation: generation,
      level: 0.08,
      frames: 12,
      segments: const ['cuánto disco queda libre'],
    );
    await _waitFor(() => results.isNotEmpty);
    expect(results.single.text, 'cuánto disco queda libre');
    expect(results.single.isFinal, isFalse);

    await engine.stop();
    await done.future;
    expect(results.last.text, 'cuánto disco queda libre');
    expect(results.last.isFinal, isTrue);

    await engine.dispose();
    await runtime.audio.close();
  });

  test('el dictado del compositor recibe lo dicho al nivel de un '
      'teléfono', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker();
    final engine = _engine(runtime, worker);
    final results = <SttResult>[];
    final done = Completer<void>();
    // The composer's microphone: the same engine, the user decides the end.
    engine.listen(continuous: true).listen(results.add, onDone: done.complete);

    await _waitFor(() => runtime.startCalls == 1);
    runtime.audio.add(Uint8List.fromList(const [0, 0]));
    await _waitFor(() => worker.acceptedGenerations.isNotEmpty);
    final generation = worker.acceptedGenerations.single;

    worker.emit(
      generation: generation,
      level: 0.006,
      speechDetected: false,
      frames: 20,
    );
    worker.emit(
      generation: generation,
      level: 0.084,
      frames: 12,
      segments: const ['primera frase'],
    );
    // Thinking between two sentences ends nothing while dictating.
    worker.emit(
      generation: generation,
      level: 0.006,
      speechDetected: false,
      frames: 60,
    );
    worker.emit(
      generation: generation,
      level: 0.106,
      frames: 12,
      segments: const ['segunda frase'],
    );
    await _waitFor(() => results.length == 2);
    expect(results.last.text, 'primera frase segunda frase');
    expect(results.last.isFinal, isFalse);
    expect(runtime.stopCalls, 0);
    expect(done.isCompleted, isFalse);

    await engine.stop();
    await done.future;
    expect(results.last.text, 'primera frase segunda frase');
    expect(results.last.isFinal, isTrue);

    await engine.dispose();
    await runtime.audio.close();
  });

  test('lo que Whisper escribiría sobre silencio no llega nunca', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker();
    final engine = _engine(runtime, worker);
    final results = <SttResult>[];
    final done = Completer<void>();
    engine.listen().listen(results.add, onDone: done.complete);

    await _waitFor(() => runtime.startCalls == 1);
    runtime.audio.add(Uint8List.fromList(const [0, 0]));
    await _waitFor(() => worker.acceptedGenerations.isNotEmpty);
    final generation = worker.acceptedGenerations.single;

    worker.emit(
      generation: generation,
      level: 0.006,
      speechDetected: false,
      frames: 20,
    );
    // The VAD cuts a segment out of the room's hiss: the phrase Whisper is
    // known to invent there is not even transcribed.
    worker.emit(
      generation: generation,
      level: 0.008,
      frames: 12,
      segments: const ['Gracias por ver el video'],
    );
    // And if it were said out loud, the text filter still drops it.
    worker.emit(
      generation: generation,
      level: 0.2,
      frames: 12,
      segments: const ['Gracias por ver el video'],
    );
    await Future<void>.delayed(Duration.zero);
    expect(results, isEmpty);

    await engine.stop();
    await done.future;
    expect(results, hasLength(1));
    expect(results.single.text, isEmpty);
    expect(results.single.isFinal, isTrue);

    await engine.dispose();
    await runtime.audio.close();
  });

  test(
    'solo aplica updates de la generación activa y flush conserva orden',
    () async {
      final runtime = _FakeRuntime();
      final worker = _FakeWorker();
      final levels = <double>[];
      final engine = SherpaSttEngine(
        model: sherpaModelByKind(SherpaModelKind.whisperBase),
        manager: _FakeManager(),
        runtime: runtime,
        workerFactory: (_) async => worker,
        onLevel: levels.add,
      );

      final firstResults = <SttResult>[];
      final firstDone = Completer<void>();
      engine.listen().listen(firstResults.add, onDone: firstDone.complete);
      await _waitFor(() => runtime.startCalls == 1);

      runtime.audio.add(Uint8List.fromList(const [0, 0]));
      await _waitFor(() => worker.acceptedGenerations.isNotEmpty);
      final firstGeneration = worker.acceptedGenerations.single;
      worker.emit(
        generation: firstGeneration + 100,
        segments: const ['resultado obsoleto'],
      );
      worker.emit(generation: firstGeneration, segments: const ['hola']);
      await _waitFor(() => firstResults.isNotEmpty);

      expect(firstResults.single.text, 'hola');
      expect(firstResults.single.isFinal, isFalse);
      expect(levels, isNotEmpty);

      worker.flushSegments = const ['final'];
      await engine.stop();
      await firstDone.future;
      expect(worker.flushGenerations, [firstGeneration]);
      expect(firstResults.last.text, 'hola final');
      expect(firstResults.last.isFinal, isTrue);

      worker.flushSegments = const [];
      final secondResults = <SttResult>[];
      final secondDone = Completer<void>();
      engine.listen().listen(secondResults.add, onDone: secondDone.complete);
      await _waitFor(() => runtime.startCalls == 2);
      runtime.audio.add(Uint8List.fromList(const [0, 0]));
      await _waitFor(() => worker.acceptedGenerations.length == 2);
      final secondGeneration = worker.acceptedGenerations.last;
      expect(secondGeneration, isNot(firstGeneration));

      worker.emit(generation: firstGeneration, segments: const ['tarde']);
      worker.emit(generation: secondGeneration, segments: const ['nuevo']);
      await _waitFor(() => secondResults.isNotEmpty);
      expect(secondResults.single.text, 'nuevo');

      await engine.stop();
      await secondDone.future;
      await Future.wait([engine.dispose(), engine.dispose()]);
      expect(worker.prepareCalls, 2);
      expect(worker.disposeCalls, 1);
      expect(runtime.disposeCalls, 1);
      await runtime.audio.close();
    },
  );

  test('while the recogniser loads, what the microphone captures already '
      'moves the level', () async {
    final runtime = _FakeRuntime();
    final worker = _FakeWorker()..prepareGate = Completer<void>();
    final levels = <double>[];
    final engine = SherpaSttEngine(
      model: sherpaModelByKind(SherpaModelKind.whisperBase),
      manager: _FakeManager(),
      runtime: runtime,
      onLevel: levels.add,
      workerFactory: (_) async => worker,
    );
    var captureReady = 0;
    final subscription = engine
        .listen(onCaptureReady: () => captureReady++)
        .listen((_) {});
    await _waitFor(() => worker.prepareCalls == 1);

    // Quiet, then a voice at a tenth of full scale.
    runtime.audio.add(Uint8List(640));
    runtime.audio.add(_pcm16Steady(0.1, 320));
    await Future<void>.delayed(Duration.zero);

    expect(captureReady, 0, reason: 'still not listening');
    expect(levels, hasLength(2));
    expect(levels.first, 0);
    expect(levels.last, closeTo(0.4, 0.01), reason: 'RMS x 4, as the worker');

    worker.prepareGate!.complete();
    await _waitFor(() => captureReady == 1);
    // It was true: that audio was kept, and reached the recogniser.
    expect(worker.acceptedLengths, [640, 640]);

    // Listening now, the level is the recogniser's own again.
    runtime.audio.add(_pcm16Steady(0.2, 320));
    await Future<void>.delayed(Duration.zero);
    expect(worker.acceptedLengths, hasLength(3));
    expect(levels, hasLength(2));

    await subscription.cancel();
    await engine.dispose();
    await runtime.audio.close();
  });

  test('the model directory is asked of the platform once, not once per '
      'file', () async {
    final support = Directory.systemTemp.createTempSync('sherpa-models-');
    addTearDown(() => support.deleteSync(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    var asked = 0;
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      asked++;
      return support.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    final manager = SherpaSttModelManager();
    final model = sherpaModelByKind(SherpaModelKind.whisperBase);
    final base = '${support.path}/stt_sherpa_models';
    for (final file in [
      '${model.dirName}/${model.encoder}',
      '${model.dirName}/${model.decoder}',
      '${model.dirName}/${model.tokens}',
      'silero_vad.onnx',
    ]) {
      File('$base/$file').createSync(recursive: true);
    }

    // What one start asks: is the model there, then where each file is.
    expect(await manager.isReady(model), isTrue);
    final paths = [
      await manager.tokensPath(model),
      await manager.encoderPath(model),
      await manager.decoderPath(model),
      await manager.sileroPath(),
    ];

    expect(paths.every((path) => path.startsWith(base)), isTrue);
    expect(asked, 1, reason: 'it was eight platform round trips');
  });

  group('the worker isolate', () {
    late Directory scratch;
    setUp(() => scratch = Directory.systemTemp.createTempSync('sherpa-wk-'));
    tearDown(() => scratch.deleteSync(recursive: true));

    File state() => File('${scratch.path}/state');

    Future<SherpaSttWorker> start({required int loadMs}) =>
        IsolateSherpaSttWorker.startWith(
          SherpaSttWorkerConfig(
            tokensPath: state().path,
            encoderPath: '',
            decoderPath: '',
            joinerPath: '',
            sileroPath: '',
            language: 'es',
            transducer: false,
            numThreads: loadMs,
          ),
          _fakeWorkerIsolate,
        );

    test('says where its load went, once it has loaded', () async {
      final worker = await start(loadMs: 0);
      final timed = worker as SherpaSttLoadTimed;
      expect(timed.loadTiming, isNull);

      await worker.prepare();

      final timing = timed.loadTiming!;
      expect(timing.spawnMs, greaterThanOrEqualTo(0));
      expect(
        '$timing',
        'spawn_ms=${timing.spawnMs} bindings_ms=3 recognizer_ms=40 vad_ms=5',
      );
      await worker.dispose();
      expect(state().readAsStringSync(), 'freed');
    });

    test('released while it opens its model, it is not killed inside the '
        'call: it comes back and frees the model', () async {
      final worker = await start(loadMs: 1500);
      final loading = worker.prepare().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await worker.dispose();

      // Whoever released it is not held for the rest of the load...
      expect(await loading, isA<SherpaSttWorkerException>());
      // ...and the model that load returns is freed, not left in memory.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline) &&
          !(state().existsSync() && state().readAsStringSync() == 'freed')) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(state().readAsStringSync(), 'freed');
    });
  });

  test(
    'el worker real se puede liberar varias veces antes de cargar modelos',
    () async {
      final worker = await IsolateSherpaSttWorker.start(
        const SherpaSttWorkerConfig(
          tokensPath: '/unused/tokens.txt',
          encoderPath: '/unused/encoder.onnx',
          decoderPath: '/unused/decoder.onnx',
          joinerPath: '',
          sileroPath: '/unused/silero.onnx',
          language: 'es',
          transducer: false,
          numThreads: 2,
        ),
      );

      final first = worker.dispose();
      final second = worker.dispose();
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
      await expectLater(worker.dispose(), completes);
      await expectLater(
        worker.prepare(),
        throwsA(isA<SherpaSttWorkerException>()),
      );
    },
  );
}
