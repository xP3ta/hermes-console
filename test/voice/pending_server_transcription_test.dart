import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records-then-transcribes runtime shaped like the Hermes server dictation:
/// each clip is uploaded on stop and its transcript arrives only when the
/// test completes that clip's server response.
class _DelayedServerSttRuntime implements WhisperSttRuntime {
  _DelayedServerSttRuntime(this.directory);

  final Directory directory;
  final List<Completer<String>> responses = <Completer<String>>[];
  final Completer<void> uploaded = Completer<void>();
  int _clips = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> modelReady(WhisperModel model) async => true;

  @override
  Future<String> createAudioPath() async {
    final file = File('${directory.path}/clip_${_clips++}.wav')
      ..writeAsBytesSync(const <int>[0, 1, 2, 3]);
    return file.path;
  }

  @override
  Future<void> start(String path) async {}

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      Stream<Amplitude>.periodic(
        interval,
        (_) => Amplitude(current: -20, max: -10),
      );

  @override
  Future<String?> stop() async => null;

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) {
    final response = Completer<String>();
    responses.add(response);
    if (!uploaded.isCompleted) uploaded.complete();
    return response.future;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets(
    'a new dictation check does not discard a server transcription that is '
    'still on its way',
    (tester) => tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(
        prefs,
        SecureStorage(),
        initialSettings: VoiceSettings.load(
          prefs,
        ).copyWith(sttEngine: SttEngineKind.hermesServer),
      );
      final audioDir = Directory.systemTemp.createTempSync('dp1215_voice_');
      addTearDown(() => audioDir.deleteSync(recursive: true));
      final runtimes = <_DelayedServerSttRuntime>[];
      voice.debugSttFactory = () {
        final runtime = _DelayedServerSttRuntime(audioDir);
        runtimes.add(runtime);
        return WhisperSttEngine(vadEnabled: false, runtime: runtime);
      };

      expect((await voice.checkStt(forComposerDictation: true)).ready, isTrue);
      final finals = <String>[];
      final done = Completer<void>();
      voice
          .startDictation(continuous: true, forComposerDictation: true)
          .listen(
            (result) {
              if (result.isFinal) finals.add(result.text);
            },
            onError: (Object _) {},
            onDone: done.complete,
          );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      unawaited(voice.stopDictation());
      await runtimes.first.uploaded.future.timeout(const Duration(seconds: 5));

      // The user taps the mic again while the first clip is transcribing:
      // the new check rebuilds the server engine.
      expect((await voice.checkStt(forComposerDictation: true)).ready, isTrue);
      expect(runtimes, hasLength(2));

      runtimes.first.responses.single.complete('primer dictado largo');
      await done.future.timeout(const Duration(seconds: 5));
      expect(finals, ['primer dictado largo']);
      await voice.dispose();
    }),
  );
  testWidgets(
    'rebinding Hermes server dictation keeps the pending transcript and its '
    'Dashboard client until the final arrives',
    (tester) => tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(
        prefs,
        SecureStorage(),
        initialSettings: VoiceSettings.load(
          prefs,
        ).copyWith(sttEngine: SttEngineKind.hermesServer),
      );
      final audioDir = Directory.systemTemp.createTempSync('dp1215_voice_');
      addTearDown(() => audioDir.deleteSync(recursive: true));
      final runtimes = <_DelayedServerSttRuntime>[];
      voice.debugSttFactory = () {
        final runtime = _DelayedServerSttRuntime(audioDir);
        runtimes.add(runtime);
        return WhisperSttEngine(vadEnabled: false, runtime: runtime);
      };
      final owner = Object();
      var clientsClosed = 0;
      final preparation = voice.beginHermesServerDictationPreparation(
        owner: owner,
      );
      expect(
        voice.enableHermesServerDictation(
          owner: owner,
          preparation: preparation,
          transcribe: (_, _) async => const {'ok': true},
          onDispose: () => clientsClosed++,
        ),
        isTrue,
      );

      expect((await voice.checkStt(forComposerDictation: true)).ready, isTrue);
      final finals = <String>[];
      final done = Completer<void>();
      voice
          .startDictation(continuous: true, forComposerDictation: true)
          .listen(
            (result) {
              if (result.isFinal) finals.add(result.text);
            },
            onError: (Object _) {},
            onDone: done.complete,
          );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      unawaited(voice.stopDictation());
      await runtimes.first.uploaded.future.timeout(const Duration(seconds: 5));

      // Tapping the mic again starts a new Hermes server preparation, which
      // retires the previous binding.
      voice.beginHermesServerDictationPreparation(owner: owner);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(clientsClosed, 0);

      runtimes.first.responses.single.complete('primer dictado largo');
      await done.future.timeout(const Duration(seconds: 5));
      expect(finals, ['primer dictado largo']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(clientsClosed, 1);
      await voice.dispose();
    }),
  );
}
