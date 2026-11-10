import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/hermes_dictation_stream.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_hermes_server.dart';
import 'package:record/record.dart';

/// Live dictation over the recording, copied from Desktop
/// `use-voice-recorder.ts:118-238`: the live final when there is one, the
/// recording exactly as before otherwise. Fake recorder and sockets only.
class _FakeRecorder extends Fake implements AudioRecorder {
  final List<RecordConfig> fileStarts = [];
  final List<RecordConfig> streamStarts = [];
  StreamController<Uint8List>? audio;
  int stops = 0;
  bool disposed = false;

  void chunk(List<int> bytes) => audio!.add(Uint8List.fromList(bytes));

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    fileStarts.add(config);
    File(path).writeAsBytesSync(const [7, 7, 7]);
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    streamStarts.add(config);
    audio = StreamController<Uint8List>();
    return audio!.stream;
  }

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      const Stream<Amplitude>.empty();

  @override
  Future<String?> stop() async {
    stops++;
    final controller = audio;
    if (controller != null && !controller.isClosed) await controller.close();
    return null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeSocket implements HermesDictationSocket {
  final StreamController<dynamic> controller = StreamController<dynamic>();
  final List<Object> sent = [];
  int closes = 0;

  List<Map<String, dynamic>> get text => [
    for (final frame in sent)
      if (frame is String) Map<String, dynamic>.from(jsonDecode(frame) as Map),
  ];

  List<List<int>> get audio => [
    for (final frame in sent)
      if (frame is Uint8List) frame.toList(),
  ];

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get frames => controller.stream;

  @override
  void send(Object frame) {
    sent.add(frame);
    if (frame is String && frame.contains('"eos"')) {
      for (final reply in onEos) {
        emit(reply);
      }
    }
  }

  /// Frames the host answers `eos` with, in order.
  final List<Map<String, Object?>> onEos = [];

  @override
  Future<void> close() async {
    closes++;
  }

  void emit(Map<String, Object?> frame) => controller.add(jsonEncode(frame));
}

/// Opens live sessions over [socket]; [gate] holds the opening open until
/// the test releases it.
class _Opener {
  _Opener(this.socket);

  final _FakeSocket socket;
  Completer<void>? gate;
  int calls = 0;
  bool refuse = false;

  Future<HermesDictationStreamSession?> call({
    required int sampleRate,
    required void Function(String text) onPartial,
  }) async {
    calls++;
    final hold = gate;
    if (hold != null) await hold.future;
    if (refuse) return null;
    return HermesDictationStreamClient(
      dashboardBaseUrl: 'http://192.168.1.20:9119',
      auth: () async =>
          const DashboardWebSocketAuth(queryName: 'ticket', credential: 't'),
      connector: (_, _) => socket,
    ).open(sampleRate: sampleRate, onPartial: onPartial);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _FakeRecorder recorder;
  late _FakeSocket socket;
  late _Opener opener;
  late List<String> uploads;
  late Map<String, dynamic> relayAnswer;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hermes-live-stt');
    recorder = _FakeRecorder();
    socket = _FakeSocket();
    opener = _Opener(socket);
    uploads = [];
    relayAnswer = {'ok': true, 'transcript': ' por la grabación '};
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  HermesServerSttRuntime runtime({bool liveOffered = true}) =>
      HermesServerSttRuntime(
        transcribeRequest: (dataUrl, mimeType) async {
          uploads.add(dataUrl);
          return relayAnswer;
        },
        recorder: recorder,
        liveDictation: () => liveOffered ? opener.call : null,
      );

  Future<String> transcribe(HermesServerSttRuntime rt, String path) =>
      rt.transcribe(
        model: WhisperModel.tiny,
        audioPath: path,
        lang: 'es',
        threads: 2,
      );

  String clipPath() => '${dir.path}/take.wav';

  test('the live capture is the same acoustic preset as raw PCM', () {
    const live = kHermesServerLiveSttRecordConfig;
    const file = kHermesServerSttRecordConfig;
    expect(live.encoder, AudioEncoder.pcm16bits);
    expect(live.sampleRate, file.sampleRate);
    expect(live.numChannels, file.numChannels);
    expect(live.echoCancel, file.echoCancel);
    expect(live.noiseSuppress, file.noiseSuppress);
    expect(live.androidConfig.audioSource, file.androidConfig.audioSource);
  });

  test('without the live offer the capture is the file as before', () async {
    final rt = runtime(liveOffered: false);
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    expect(recorder.fileStarts, [kHermesServerSttRecordConfig]);
    expect(recorder.streamStarts, isEmpty);
    expect(opener.calls, 0);
  });

  test('the voice conversation never streams (Desktop)', () async {
    final rt = runtime();
    rt.prepareCapture(continuous: false, onPartial: (_) {});
    await rt.start(clipPath());
    expect(recorder.fileStarts, hasLength(1));
    expect(recorder.streamStarts, isEmpty);
    expect(opener.calls, 0);
  });

  test('a start without prepareCapture keeps the file capture', () async {
    final rt = runtime();
    await rt.start(clipPath());
    expect(recorder.fileStarts, hasLength(1));
    expect(opener.calls, 0);
  });

  test('chunks before the socket opens are buffered, then flushed in order, '
      'and all of them land in the recording', () async {
    final rt = runtime();
    opener.gate = Completer<void>();
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    expect(recorder.streamStarts, [kHermesServerLiveSttRecordConfig]);
    expect(recorder.fileStarts, isEmpty);

    recorder.chunk([1, 0]);
    recorder.chunk([2, 0]);
    await pumpEventQueue();
    expect(socket.sent, isEmpty);

    opener.gate!.complete();
    await pumpEventQueue();
    recorder.chunk([3, 0]);
    await pumpEventQueue();

    expect(socket.text.first, {'sample_rate': 16000});
    expect(socket.audio, [
      [1, 0],
      [2, 0],
      [3, 0],
    ]);

    final path = await rt.stop();
    expect(path, clipPath());
    final wav = File(path!).readAsBytesSync();
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    final header = ByteData.sublistView(wav);
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(40, Endian.little), 6);
    expect(wav.sublist(44), [1, 0, 2, 0, 3, 0]);
  });

  test('the pre-open buffer holds 64 chunks, as in Desktop', () async {
    final rt = runtime();
    opener.gate = Completer<void>();
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    for (var i = 0; i < 70; i++) {
      recorder.chunk([i, 0]);
    }
    await pumpEventQueue();
    opener.gate!.complete();
    await pumpEventQueue();

    expect(socket.audio, hasLength(64));
    expect(socket.audio.last, [63, 0]);
    // The recording keeps every chunk: the fallback loses nothing.
    final path = await rt.stop();
    expect(File(path!).readAsBytesSync().length, 44 + 140);
  });

  test('chunks dropped before the socket opened send the whole recording '
      '(REVIEW-R5-B #13)', () async {
    final rt = runtime();
    opener.gate = Completer<void>();
    socket.onEos.add({'type': 'final', 'transcript': 'sin el medio'});
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    for (var i = 0; i < 70; i++) {
      recorder.chunk([i, 0]);
    }
    await pumpEventQueue();
    opener.gate!.complete();
    await pumpEventQueue();
    final path = await rt.stop();

    expect(await transcribe(rt, path!), 'por la grabación');
    expect(uploads, hasLength(1));
    final wav = base64Decode(uploads.single.split(',').last);
    expect(wav.length, 44 + 140);
    expect(socket.closes, greaterThan(0));
  });

  test('a live final is the transcript and nothing is uploaded', () async {
    final rt = runtime();
    socket.onEos.add({'type': 'final', 'transcript': ' hola en directo '});
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    await pumpEventQueue();
    recorder.chunk([1, 0]);
    final path = await rt.stop();

    expect(await transcribe(rt, path!), 'hola en directo');
    expect(uploads, isEmpty);
    expect(socket.text.last, {'eos': true});
    expect(socket.closes, greaterThan(0));
  });

  test('an empty live final falls back to the recording', () async {
    final rt = runtime();
    socket.onEos.add({'type': 'final', 'transcript': ''});
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    await pumpEventQueue();
    recorder.chunk([5, 0]);
    final path = await rt.stop();

    expect(await transcribe(rt, path!), 'por la grabación');
    expect(uploads, hasLength(1));
    final wav = base64Decode(uploads.single.split(',').last);
    expect(wav.sublist(44), [5, 0]);
  });

  test('a host error falls back to the recording', () async {
    final rt = runtime();
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    await pumpEventQueue();
    socket.emit({'type': 'error', 'message': 'provider down'});
    await pumpEventQueue();
    recorder.chunk([5, 0]);
    final path = await rt.stop();

    expect(await transcribe(rt, path!), 'por la grabación');
    expect(uploads, hasLength(1));
  });

  test('no live session (refused) falls back to the recording', () async {
    final rt = runtime();
    opener.refuse = true;
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    recorder.chunk([5, 0]);
    final path = await rt.stop();

    expect(await transcribe(rt, path!), 'por la grabación');
    expect(uploads, hasLength(1));
    expect(socket.sent, isEmpty);
  });

  test('an opener that throws falls back to the recording', () async {
    final rt = HermesServerSttRuntime(
      transcribeRequest: (dataUrl, _) async {
        uploads.add(dataUrl);
        return relayAnswer;
      },
      recorder: recorder,
      liveDictation: () =>
          ({required sampleRate, required onPartial}) =>
              Future<HermesDictationStreamSession?>.error(StateError('x')),
    );
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    final path = await rt.stop();
    expect(await transcribe(rt, path!), 'por la grabación');
  });

  test('partials stop once the take is discarded', () async {
    final rt = runtime();
    final partials = <String>[];
    rt.prepareCapture(continuous: true, onPartial: partials.add);
    await rt.start(clipPath());
    await pumpEventQueue();
    socket.emit({'type': 'partial', 'text': 'hola'});
    await pumpEventQueue();
    expect(partials, ['hola']);

    rt.discardCapture(clipPath());
    socket.emit({'type': 'partial', 'text': 'tarde'});
    await pumpEventQueue();

    expect(partials, ['hola']);
    expect(socket.closes, greaterThan(0));
    expect(socket.text.any((frame) => frame.containsKey('eos')), isFalse);
  });

  test('discarding another path leaves the take alone', () async {
    final rt = runtime();
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    await pumpEventQueue();
    rt.discardCapture('${dir.path}/other.wav');
    expect(socket.closes, 0);
    rt.discardCapture(null);
    expect(socket.closes, greaterThan(0));
  });

  test('a take discarded while opening sends no audio', () async {
    final rt = runtime();
    opener.gate = Completer<void>();
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    recorder.chunk([1, 0]);
    rt.discardCapture(clipPath());
    opener.gate!.complete();
    await pumpEventQueue();

    expect(socket.audio, isEmpty);
    expect(socket.closes, greaterThan(0));
  });

  test('dispose closes a running take and the recorder', () async {
    final rt = runtime();
    rt.prepareCapture(continuous: true, onPartial: (_) {});
    await rt.start(clipPath());
    await pumpEventQueue();
    await rt.dispose();
    expect(socket.closes, greaterThan(0));
    expect(recorder.disposed, isTrue);
  });

  group('WhisperSttEngine with a live runtime', () {
    setUp(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(pathProvider, (_) async => dir.path);
      addTearDown(
        () => messenger.setMockMethodCallHandler(pathProvider, null),
      );
    });

    bool wavLeft() => dir.listSync().any((f) => f.path.endsWith('.wav'));

    WhisperSttEngine engine(HermesServerSttRuntime rt) => WhisperSttEngine(
      model: WhisperModel.tiny,
      runtime: rt,
      lang: 'es',
    );

    test('keeps recording-then-transcribing semantics for the UI', () async {
      final e = engine(runtime());
      addTearDown(e.dispose);
      // The stop budget (3 min) and the dictation flow stay the server ones.
      expect(e.supportsPartials, isFalse);
    });

    test('dictation: partials while speaking and after Stop, then the live '
        'final', () async {
      final rt = runtime();
      final e = engine(rt);
      addTearDown(e.dispose);
      final results = <SttResult>[];
      final done = Completer<void>();
      e.listen(continuous: true).listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      expect(recorder.streamStarts, hasLength(1));

      socket.emit({'type': 'partial', 'text': 'hola'});
      await pumpEventQueue();
      expect(results.map((r) => (r.text, r.isFinal)), [('hola', false)]);

      // The host still recognizes after Stop, then finalizes.
      socket.onEos
        ..add({'type': 'partial', 'text': 'hola mundo'})
        ..add({'type': 'final', 'transcript': 'Hola, mundo.'});
      await e.stop();
      await done.future;

      expect(results.map((r) => (r.text, r.isFinal)), [
        ('hola', false),
        ('hola mundo', false),
        ('Hola, mundo.', true),
      ]);
      expect(uploads, isEmpty);
      expect(wavLeft(), isFalse);
    });

    test('a failed live take ends with the recording', () async {
      final rt = runtime();
      final e = engine(rt);
      addTearDown(e.dispose);
      final results = <SttResult>[];
      final done = Completer<void>();
      e.listen(continuous: true).listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      recorder.chunk([4, 0]);
      socket.emit({'type': 'error', 'message': 'gone'});
      await pumpEventQueue();
      await e.stop();
      await done.future;

      expect(results.single.text, 'por la grabación');
      expect(results.single.isFinal, isTrue);
      expect(uploads, hasLength(1));
      expect(wavLeft(), isFalse);
    });

    test('dispose mid-dictation closes the live socket', () async {
      final rt = runtime();
      final e = engine(rt);
      final results = <SttResult>[];
      e.listen(continuous: true).listen(results.add);
      await pumpEventQueue();
      await e.dispose();
      socket.emit({'type': 'partial', 'text': 'tarde'});
      await pumpEventQueue();

      expect(socket.closes, greaterThan(0));
      expect(results, isEmpty);
      expect(uploads, isEmpty);
    });
  });
}
