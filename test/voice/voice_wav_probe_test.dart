import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/neural_tts_worker.dart';

class Worker implements NeuralTtsWorker {
  Worker(this.dir, {this.holdIndex});
  final Directory dir;
  final int? holdIndex;
  final requested = Completer<void>();
  final release = Completer<void>();
  final waves = <File>[];
  int requests = 0;
  @override
  Future<NeuralTtsWorkerAudio> synthesize(String text, double speed) async {
    final index = requests++;
    if (index == holdIndex) {
      requested.complete();
      await release.future;
    }
    final f = File('${dir.path}/wave_$index.wav');
    f.writeAsBytesSync([82, 73, 70, 70]);
    waves.add(f);
    return NeuralTtsWorkerAudio(
      samples: Float32List.fromList([.2, -.2]),
      sampleRate: 16000,
      wavePath: f.path,
    );
  }

  @override
  Future<void> dispose() async {}
}

class Player implements TtsAudioPlayback {
  Player({this.autoComplete = true, this.fail = false});
  final bool autoComplete, fail;
  final events = StreamController<void>.broadcast();
  final started = Completer<void>();
  final seen = <bool>[];
  @override
  Stream<void> get onComplete => events.stream;
  @override
  Future<void> playFile(String path) async {
    seen.add(File(path).existsSync());
    if (!started.isCompleted) started.complete();
    if (!seen.last) throw StateError('PLAYBACK_WAV_MISSING');
    if (fail) throw StateError('PLAYBACK_FAILURE');
    if (autoComplete) scheduleMicrotask(() => events.add(null));
  }

  @override
  Future<void> playBytes(Uint8List b, {required String mimeType}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

Future<void> drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('adversarial-voice-wav-');
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  OnDeviceNeuralTtsEngine create(Worker w, Player p) => OnDeviceNeuralTtsEngine(
    modelPath: 'unused',
    tokensPath: 'unused',
    dataDirPath: 'unused',
    playback: p,
    playbackFactory: Player.new,
    debugWorkerFactory: (_) async => w,
  );
  test(
    'adversarial identical consecutive chunks retain the shared playback claim',
    () async {
      final w = Worker(dir);
      final p = Player();
      final e = create(w, p);
      addTearDown(e.dispose);
      final sentence = '${'A' * 241}.';
      Object? error;
      try {
        await e.speak('$sentence $sentence');
      } catch (x) {
        error = x;
      }
      expect(
        p.seen,
        [true, true],
        reason:
            'prefetch and playback share one synthesis but both must retain the file',
      );
      expect(error, isNull);
    },
  );
  test(
    'adversarial late cancelled prefetch has no owner and must be deleted',
    () async {
      final w = Worker(dir, holdIndex: 1);
      final p = Player(autoComplete: false);
      final e = create(w, p);
      addTearDown(e.dispose);
      final speaking = e.speak('${'A' * 241}. Second private sentence.');
      await w.requested.future;
      await p.started.future;
      await e.stop();
      await speaking;
      w.release.complete();
      await drain();
      expect(
        w.waves.where((f) => f.existsSync()),
        isEmpty,
        reason:
            'cancelled prefetch has no playback or new same-phrase claimant',
      );
    },
  );
  test('adversarial single completed wave is removed', () async {
    final w = Worker(dir);
    final p = Player();
    final e = create(w, p);
    addTearDown(e.dispose);
    await e.speak('private single');
    await drain();
    expect(p.seen, [true]);
    expect(w.waves.single.existsSync(), isFalse);
  });
  test('adversarial late prefetch after playback failure is removed', () async {
    final w = Worker(dir, holdIndex: 1);
    final p = Player(fail: true);
    final e = create(w, p);
    addTearDown(e.dispose);
    await expectLater(
      e.speak('${'A' * 241}. Second private sentence.'),
      throwsStateError,
    );
    w.release.complete();
    await drain();
    expect(w.waves, hasLength(2));
    expect(w.waves.where((f) => f.existsSync()), isEmpty);
  });
  test(
    'adversarial cancelled first inference may be reused by new same phrase owner',
    () async {
      final w = Worker(dir, holdIndex: 0);
      final p = Player();
      final e = create(w, p);
      addTearDown(e.dispose);
      final a = e.speak('same private phrase');
      await w.requested.future;
      await e.stop();
      await a;
      final b = e.speak('same private phrase');
      w.release.complete();
      await b;
      await drain();
      expect(w.requests, 1);
      expect(w.waves.single.existsSync(), isFalse);
    },
  );
  test('adversarial dispose cleans late cancelled prefetch', () async {
    final w = Worker(dir, holdIndex: 1);
    final p = Player(autoComplete: false);
    final e = create(w, p);
    addTearDown(e.dispose);
    final a = e.speak('${'A' * 241}. Second private sentence.');
    await w.requested.future;
    await e.dispose();
    await a;
    w.release.complete();
    await drain();
    expect(w.waves.where((f) => f.existsSync()), isEmpty);
  });
}
