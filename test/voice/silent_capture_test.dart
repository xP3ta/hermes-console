import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_hermes_server.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:record/record.dart';

/// Backlog 1.4.x item 7: a take that is shorter than 0.3 s or has no energy
/// (a car or headset microphone that delivers nothing) is never sent in
/// silence; the user is told nothing can be heard.
class _Runtime implements WhisperSttRuntime {
  _Runtime(this.dir);

  final Directory dir;
  final amplitude = StreamController<Amplitude>.broadcast();
  int transcriptions = 0;

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
  Future<String?> stop() async => null;

  @override
  Future<String> transcribe({
    required WhisperModel model,
    required String audioPath,
    required String lang,
    required int threads,
  }) async {
    transcriptions++;
    return 'hola';
  }

  @override
  Future<void> dispose() async {
    if (!amplitude.isClosed) await amplitude.close();
  }
}

/// A live dictation runtime whose server already sent words back.
class _LiveRuntime extends _Runtime implements LiveCaptureSttRuntime {
  _LiveRuntime(super.dir);

  void Function(String text)? _onPartial;

  @override
  void prepareCapture({
    required bool continuous,
    required void Function(String text) onPartial,
  }) {
    _onPartial = onPartial;
  }

  void partial(String text) => _onPartial?.call(text);

  @override
  void discardCapture(String? audioPath) {}
}

class _NeverTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => true;

  @override
  int get tick => 0;
}

void main() {
  late Directory dir;
  late _Runtime runtime;
  late DateTime now;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('silent-capture');
    runtime = _Runtime(dir);
    now = DateTime.utc(2026, 10, 27, 10);
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  WhisperSttEngine engine({bool reject = true}) {
    final e = WhisperSttEngine(
      model: WhisperModel.tiny,
      runtime: runtime,
      vadEnabled: false,
      rejectSilentCapture: reject,
      clock: () => now,
      timerFactory: (_, _) => _NeverTimer(),
    );
    addTearDown(e.dispose);
    return e;
  }

  Future<({List<SttResult> results, Object? error})> take(
    WhisperSttEngine e, {
    required Duration length,
    List<double> levels = const [],
    void Function()? whileRecording,
  }) async {
    final results = <SttResult>[];
    Object? error;
    final done = Completer<void>();
    e.listen(continuous: true).listen(
      results.add,
      onError: (Object failure) => error = failure,
      onDone: done.complete,
    );
    await pumpEventQueue();
    for (final db in levels) {
      runtime.amplitude.add(Amplitude(current: db, max: db));
      await pumpEventQueue();
    }
    whileRecording?.call();
    await pumpEventQueue();
    now = now.add(length);
    await e.stop();
    await done.future;
    return (results: results, error: error);
  }

  test('a take with no energy is not sent and says why', () async {
    final outcome = await take(
      engine(),
      length: const Duration(seconds: 2),
      levels: const [-160, -160, -160],
    );
    expect(outcome.error, isA<SttNoAudioError>());
    expect(outcome.error, isA<SttUserFacingError>());
    expect(outcome.results, isEmpty);
    expect(runtime.transcriptions, 0);
  });

  test('a take with no level reading at all is not sent', () async {
    final outcome = await take(engine(), length: const Duration(seconds: 2));
    expect(outcome.error, isA<SttNoAudioError>());
    expect(runtime.transcriptions, 0);
  });

  test('a take shorter than 0.3 s is not sent', () async {
    final outcome = await take(
      engine(),
      length: const Duration(milliseconds: 200),
      levels: const [-30],
    );
    expect(outcome.error, isA<SttNoAudioError>());
    expect(runtime.transcriptions, 0);
  });

  test('a quiet but live microphone is sent as before', () async {
    final outcome = await take(
      engine(),
      length: const Duration(seconds: 2),
      levels: const [-62, -55, -58],
    );
    expect(outcome.error, isNull);
    expect(outcome.results.single.text, 'hola');
    expect(runtime.transcriptions, 1);
  });

  test('a live take that returned words is sent, meter or not', () async {
    final live = _LiveRuntime(dir);
    runtime = live;
    final outcome = await take(
      engine(),
      length: const Duration(seconds: 2),
      whileRecording: () => live.partial('hola'),
    );
    expect(outcome.error, isNull);
    expect(outcome.results.map((r) => r.text), contains('hola'));
    expect(runtime.transcriptions, 1);
  });

  test('engines that do not opt in keep sending every take', () async {
    final outcome = await take(
      engine(reject: false),
      length: const Duration(milliseconds: 100),
    );
    expect(outcome.error, isNull);
    expect(runtime.transcriptions, 1);
  });

  test('the Hermes server engine opts in', () async {
    final e = buildHermesServerSttEngine(
      transcribeRequest: (_, _) async => {'ok': true, 'transcript': ''},
      lang: 'es',
    );
    expect(e.rejectSilentCapture, isTrue);
    await e.dispose();
  });

  test('every voice language says nothing can be heard', () {
    for (final language in voiceLanguages.values) {
      expect(
        language.messages['noAudioHeard'],
        isNotNull,
        reason: language.code,
      );
    }
  });
}
