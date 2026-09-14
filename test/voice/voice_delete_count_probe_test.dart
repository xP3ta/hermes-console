import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';

class CountedFile implements File {
  CountedFile(this.real);
  final File real;
  int existsChecks = 0, unlinks = 0;
  @override
  bool existsSync() {
    existsChecks++;
    return real.existsSync();
  }

  @override
  void deleteSync({bool recursive = false}) {
    unlinks++;
    real.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Playback implements TtsAudioPlayback {
  final stream = StreamController<void>.broadcast();
  @override
  Stream<void> get onComplete => stream.stream;
  @override
  Future<void> playFile(String path) async {
    scheduleMicrotask(() => stream.add(null));
  }

  @override
  Future<void> playBytes(Uint8List bytes, {required String mimeType}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('adversarial count cleanup attempts on one worker WAV', () async {
    final dir = await Directory.systemTemp.createTemp(
      'adversarial-delete-count-',
    );
    final f = File('${dir.path}/owned.wav')..writeAsBytesSync([82, 73, 70, 70]);
    final tracked = CountedFile(f);
    final e = OnDeviceNeuralTtsEngine(
      modelPath: 'unused',
      tokensPath: 'unused',
      dataDirPath: 'unused',
      playback: Playback(),
      playbackFactory: Playback.new,
      debugSynthesizer: (_, _) async => NeuralTtsAudio(
        samples: Float32List.fromList([.2]),
        sampleRate: 16000,
        wavePath: f.path,
      ),
      debugWaveWriter: (audio, seq) async => audio.wavePath,
    );
    try {
      await IOOverrides.runZoned(
        () async {
          await e.speak('private');
          await Future<void>.delayed(Duration.zero);
        },
        createFile: (path) {
          if (path != f.path) throw StateError('unexpected path');
          return tracked;
        },
      );
      expect(tracked.unlinks, 1);
      expect(
        tracked.existsChecks,
        1,
        reason:
            'cleanup must have one owning path, not finally plus retirement',
      );
    } finally {
      await e.dispose();
      await dir.delete(recursive: true);
    }
  });
}
