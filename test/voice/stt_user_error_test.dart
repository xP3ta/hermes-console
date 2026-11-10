import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_client_direct.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:record/record.dart';

/// REVIEW-R5-B #12: the voice provider's rejection must reach the user, as
/// Desktop does (`notifyError(error, …)` with the provider's text), instead
/// of a generic "Transcription failed".
class _Runtime implements WhisperSttRuntime {
  _Runtime(this.dir, this.failure);

  final Directory dir;
  final Object failure;

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
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      const Stream<Amplitude>.empty();

  @override
  Future<String?> stop() async => null;

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) async => throw failure;

  @override
  Future<void> dispose() async {}
}

/// A recognizer whose transcription never answers.
class _HangingRuntime extends _Runtime {
  _HangingRuntime(Directory dir) : super(dir, StateError('unused'));

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) => Completer<String>().future;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stt-user-error');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<Object?> failureOf(Object thrown) async {
    final engine = WhisperSttEngine(
      model: WhisperModel.tiny,
      runtime: _Runtime(dir, thrown),
      vadEnabled: false,
    );
    addTearDown(engine.dispose);
    Object? error;
    final done = Completer<void>();
    engine
        .listen(continuous: true)
        .listen(
          (_) {},
          onError: (Object e) => error = e,
          onDone: done.complete,
        );
    await pumpEventQueue();
    await engine.stop();
    await done.future;
    return error;
  }

  test('the provider rejection goes through unchanged', () async {
    const rejection = VoiceDirectProviderException(
      'STT failed (401): invalid key',
      statusCode: 401,
    );
    expect(await failureOf(rejection), same(rejection));
    expect(rejection, isA<SttUserFacingError>());
  });

  test('anything else is still the generic failure', () async {
    final error = await failureOf(StateError('internal detail'));
    expect(error, isA<Exception>());
    expect(error.toString(), isNot(contains('internal detail')));
  });

  test('a transcription that times out says so', () async {
    final error = await failureOf(TimeoutException('inner'));
    expect(error, isA<SttTimeoutError>());
    expect(error, isA<SttUserFacingError>());
  });

  test('a transcription that never answers is cut at its own budget', () async {
    final engine = WhisperSttEngine(
      model: WhisperModel.tiny,
      runtime: _HangingRuntime(dir),
      vadEnabled: false,
      maxDuration: const Duration(milliseconds: 20),
      transcribeGrace: const Duration(milliseconds: 40),
    );
    addTearDown(engine.dispose);
    Object? error;
    final done = Completer<void>();
    engine
        .listen(continuous: true)
        .listen(
          (_) {},
          onError: (Object e) => error = e,
          onDone: done.complete,
        );
    await pumpEventQueue();
    await engine.stop();
    await done.future.timeout(const Duration(seconds: 3));
    expect(error, isA<SttTimeoutError>());
  });

  test('every voice language words the provider reply', () {
    for (final language in voiceLanguages.values) {
      final note = language.message('providerError', {'detail': 'X-401'});
      expect(note, contains('X-401'), reason: language.code);
      expect(note, isNot(contains('{detail}')), reason: language.code);
    }
  });
}
