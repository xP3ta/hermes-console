import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/conversation/full_duplex_barge_in_monitor.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_server_prefs.dart';
import 'package:record/record.dart';

/// The profile's barge-in sensitivity and silence hold reach the Desktop
/// ports that use them: the barge-in monitor (`voice-barge-in.ts:82-88`,
/// `:354`) and the clip loop (`use-voice-conversation.ts:391`).
class _Source implements FullDuplexCaptureSource {
  final audio = StreamController<Uint8List>.broadcast();
  int transcriptions = 0;

  @override
  bool get transcriptionAvailable => true;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start() async => audio.stream;

  @override
  Future<void> setPlaybackActive(bool active) async {}

  @override
  Future<FullDuplexPlaybackSafety> playbackSafety() async =>
      const FullDuplexPlaybackSafety(
        aecEnabled: false,
        privateOutput: false,
        playbackSafe: false,
      );

  @override
  Future<void> stop() async {}

  @override
  Future<String> transcribe(Uint8List wavBytes) async {
    transcriptions++;
    return 'interjection';
  }

  @override
  Future<void> dispose() async {
    if (!audio.isClosed) await audio.close();
  }
}

Uint8List _frame(int amplitude) {
  const samples = 480;
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return bytes;
}

Future<void> _emit(_Source source, int amplitude, int frames) async {
  for (var i = 0; i < frames; i++) {
    source.audio.add(_frame(amplitude));
  }
  await pumpEventQueue();
}

class _NeverTimer implements Timer {
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

class _Runtime implements WhisperSttRuntime {
  _Runtime(this.dir);

  final Directory dir;
  final amplitude = StreamController<Amplitude>.broadcast();
  int stops = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> modelReady(WhisperModel model) async => true;

  @override
  Future<String> createAudioPath() async => '${dir.path}/turn.wav';

  @override
  Future<void> start(String path) async {
    File(path).writeAsBytesSync(const [1, 2, 3, 4]);
  }

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => amplitude.stream;

  @override
  Future<String?> stop() async {
    stops++;
    return null;
  }

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) async => 'hola';

  @override
  Future<void> dispose() async {
    if (!amplitude.isClosed) await amplitude.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('barge-in monitor', () {
    Future<(FullDuplexBargeInMonitor, _Source, List<int>)> armed({
      double? multiplier,
      Duration? silence,
    }) async {
      final source = _Source();
      final monitor = FullDuplexBargeInMonitor(
        source: source,
        thresholdMultiplier: () => multiplier,
        endpointSilence: silence == null ? null : () => silence,
      );
      addTearDown(monitor.dispose);
      final starts = <int>[0];
      await monitor.arm(
        onSpeechStart: () => starts[0]++,
        onTranscript: (_) async {},
      );
      // Quiet floor 497 RMS, as in the Desktop-floor test of the monitor.
      await _emit(source, 497, 42);
      return (monitor, source, starts);
    }

    test('no multiplier keeps Desktop 3.5 x floor', () async {
      final (_, source, starts) = await armed();
      await _emit(source, 1000, 12);
      expect(starts.single, 0);
    });

    test('a lower multiplier makes it more sensitive (1.5 / 3)', () async {
      // 497 * 3.5 * 0.5 = 870 < 1000.
      final (_, source, starts) = await armed(multiplier: 1.5);
      await _emit(source, 1000, 12);
      expect(starts.single, 1);
    });

    test('a higher multiplier makes it less sensitive (6 / 3)', () async {
      // 1835 triggers at the default; 497 * 3.5 * 2 = 3479 does not.
      final (_, source, starts) = await armed(multiplier: 6);
      await _emit(source, 1835, 12);
      expect(starts.single, 0);
    });

    test('the default endpoint stays 42 frames (1.26 s)', () async {
      final (_, source, starts) = await armed();
      await _emit(source, 1835, 12);
      expect(starts.single, 1);
      await _emit(source, 0, 42);
      expect(source.transcriptions, 1);
    });

    test('voice.silence_duration of 2 s waits 67 frames', () async {
      final (_, source, starts) = await armed(
        silence: const Duration(seconds: 2),
      );
      await _emit(source, 1835, 12);
      expect(starts.single, 1);
      await _emit(source, 0, 66);
      expect(source.transcriptions, 0);
      await _emit(source, 0, 1);
      expect(source.transcriptions, 1);
    });

    test('Desktop 1.25 s from the prefs equals the built-in endpoint', () {
      expect((kDesktopVoiceSilence.inMicroseconds / 30000).ceil(), 42);
    });
  });

  group('clip loop silence hold', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('voice-silence');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    Future<(WhisperSttEngine, _Runtime, List<SttResult>)> speak({
      Duration Function()? silenceTimeoutOf,
    }) async {
      final runtime = _Runtime(dir);
      final engine = WhisperSttEngine(
        model: WhisperModel.tiny,
        runtime: runtime,
        silenceTimeoutOf: silenceTimeoutOf,
        timerFactory: (_, _) => _NeverTimer(),
      );
      addTearDown(engine.dispose);
      final results = <SttResult>[];
      engine.listen().listen(results.add);
      await pumpEventQueue();
      // Calibrate at -50 dB, three sustained samples of speech, then one
      // quiet sample.
      for (final db in [-50.0, -50.0, -50.0, -10.0, -10.0, -10.0, -50.0]) {
        runtime.amplitude.add(Amplitude(current: db, max: db));
        await pumpEventQueue();
      }
      await pumpEventQueue();
      return (engine, runtime, results);
    }

    test('without a profile value the 1.25 s hold is not over', () async {
      final (_, runtime, results) = await speak();
      expect(runtime.stops, 0);
      expect(results, isEmpty);
    });

    test('the profile value is read on each sample', () async {
      final (_, runtime, results) = await speak(
        silenceTimeoutOf: () => Duration.zero,
      );
      expect(runtime.stops, greaterThan(0));
      expect(results.single.text, 'hola');
      expect(results.single.isFinal, isTrue);
    });
  });
}
