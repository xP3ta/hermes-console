import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_dictation.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records-then-transcribes runtime shaped like the Hermes server dictation:
/// each clip is uploaded on stop and its transcript arrives only when the
/// test completes that clip's server response.
class _DelayedServerSttRuntime implements WhisperSttRuntime {
  _DelayedServerSttRuntime(this.directory);

  final Directory directory;
  final List<Completer<String>> responses = <Completer<String>>[];
  int startCalls = 0;
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
  Future<void> start(String path) async {
    startCalls++;
  }

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
    return response.future;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets(
    'a slow server transcription after stop reaches the room composer and a '
    'second start cannot discard it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      final audioDir = Directory.systemTemp.createTempSync('dp1215_room_');
      addTearDown(() => audioDir.deleteSync(recursive: true));
      final runtime = _DelayedServerSttRuntime(audioDir);
      voice.debugSttFactory = () =>
          WhisperSttEngine(vadEnabled: false, runtime: runtime);
      final dictation = VoiceRoomDictation(
        voice: voice,
        connection: SavedConnection(
          id: 'room-conn',
          label: 'Room',
          host: '127.0.0.1',
          port: 8642,
          apiKey: '',
        ),
        profile: 'default',
      );
      addTearDown(dictation.dispose);
      final texts = <String>[];
      final failures = <RoomDictationFailure>[];

      Future<void> start() => dictation.start(
        currentText: 'Previo',
        onText: texts.add,
        onFailure: failures.add,
      );

      await start();
      await tester.pump(const Duration(milliseconds: 50));
      expect(runtime.startCalls, 1);
      expect(dictation.recording, isTrue);
      await tester.pump(const Duration(seconds: 10));

      unawaited(dictation.stop());
      await tester.pump();
      // Cancelling the amplitude subscription completes on the root zone:
      // let one real turn of the event loop run so the clip gets uploaded.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
      expect(runtime.responses, hasLength(1));

      // The overloaded server keeps the transcript for over a minute. The
      // composer must keep showing the transcribing state the whole time.
      for (var waited = 0; waited < 70; waited += 7) {
        await tester.pump(const Duration(seconds: 7));
        expect(dictation.recording, isTrue);
        expect(dictation.transcribing, isTrue);
      }
      expect(texts, isEmpty);

      // A second start while transcribing opens no new recording.
      await start();
      await tester.pump(const Duration(milliseconds: 50));
      expect(runtime.startCalls, 1);

      runtime.responses.single.complete('primer dictado largo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(texts, ['Previo primer dictado largo']);
      expect(failures, isEmpty);
      expect(dictation.recording, isFalse);
      expect(dictation.transcribing, isFalse);
      // Let the voice service's idle model release run out.
      await tester.pump(const Duration(minutes: 2));
    },
  );
}
