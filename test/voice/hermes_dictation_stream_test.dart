import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/hermes_dictation_stream.dart';

/// Desktop `lib/voice-stream.ts` over `/api/audio/transcribe-stream`
/// (`hermes_cli/web_routers/audio.py:516-590`), with fake sockets only.
class _FakeDictationSocket implements HermesDictationSocket {
  _FakeDictationSocket({bool ready = true}) {
    if (ready) readyCompleter.complete();
  }

  final StreamController<dynamic> controller = StreamController<dynamic>();
  final Completer<void> readyCompleter = Completer<void>();
  final List<Object> sent = [];
  int closes = 0;

  /// The upgrade fails with this as soon as [ready] is read.
  Object? readyError;

  bool get closed => closes > 0;

  List<Map<String, dynamic>> get textFrames => [
    for (final frame in sent)
      if (frame is String) Map<String, dynamic>.from(jsonDecode(frame) as Map),
  ];

  List<Uint8List> get audioFrames => [
    for (final frame in sent)
      if (frame is Uint8List) frame,
  ];

  @override
  Future<void> get ready {
    final error = readyError;
    return error == null ? readyCompleter.future : Future<void>.error(error);
  }

  @override
  Stream<dynamic> get frames => controller.stream;

  @override
  void send(Object frame) => sent.add(frame);

  @override
  Future<void> close() async {
    closes++;
  }

  void emit(Map<String, Object?> frame) => controller.add(jsonEncode(frame));
}

const _ticket = DashboardWebSocketAuth(
  queryName: 'ticket',
  credential: 'ws-ticket',
);

HermesDictationStreamClient _client(
  _FakeDictationSocket? socket, {
  String? profile,
  String base = 'http://192.168.1.20:9119',
  List<Uri>? uris,
  Future<DashboardWebSocketAuth> Function()? auth,
}) => HermesDictationStreamClient(
  dashboardBaseUrl: base,
  profile: profile,
  auth: auth ?? () async => _ticket,
  connector: (uri, headers) {
    uris?.add(uri);
    return socket!;
  },
);

void main() {
  test('builds the Desktop route with the Dashboard ticket and profile', () {
    final client = _client(
      null,
      base: 'https://hermes.example/dash/',
      profile: 'work',
    );
    final uri = client.buildUri(_ticket);
    expect(uri.scheme, 'wss');
    expect(uri.path, '/dash/api/audio/transcribe-stream');
    expect(uri.queryParameters, {'ticket': 'ws-ticket', 'profile': 'work'});

    final plain = _client(null, profile: 'default').buildUri(_ticket);
    expect(plain.scheme, 'ws');
    expect(plain.queryParameters.containsKey('profile'), isFalse);
  });

  test('announces the rate first, then forwards PCM in order', () async {
    final socket = _FakeDictationSocket();
    final session = await _client(socket).open(sampleRate: 16000);

    expect(session, isNotNull);
    expect(socket.textFrames, [
      {'sample_rate': 16000},
    ]);
    session!.pushAudio(Uint8List.fromList([1, 2]));
    session.pushAudio(Uint8List(0));
    session.pushAudio(Uint8List.fromList([3, 4]));
    expect(socket.audioFrames, [
      [1, 2],
      [3, 4],
    ]);
    session.cancel();
  });

  test('partials reach the caller and stop resolves the final', () async {
    final socket = _FakeDictationSocket();
    final partials = <String>[];
    final session = (await _client(
      socket,
    ).open(sampleRate: 16000, onPartial: partials.add))!;

    socket.emit({'type': 'partial', 'text': 'hola'});
    socket.emit({'type': 'partial', 'text': 'hola qué tal'});
    await pumpEventQueue();
    expect(partials, ['hola', 'hola qué tal']);

    final transcript = session.stop();
    await pumpEventQueue();
    expect(socket.textFrames.last, {'eos': true});
    socket.emit({
      'type': 'final',
      'transcript': '  hola, ¿qué tal?  ',
      'provider': 'openai',
    });

    expect(await transcript, 'hola, ¿qué tal?');
    expect(socket.closed, isTrue);
    expect(session.settled, isTrue);
  });

  test('an empty final resolves to the empty string', () async {
    final socket = _FakeDictationSocket();
    final session = (await _client(socket).open(sampleRate: 16000))!;
    final transcript = session.stop();
    socket.emit({'type': 'final', 'transcript': '   '});
    expect(await transcript, '');
  });

  test('the host error frame rejects stop and stops the partials', () async {
    final socket = _FakeDictationSocket();
    final partials = <String>[];
    final session = (await _client(
      socket,
    ).open(sampleRate: 16000, onPartial: partials.add))!;
    final transcript = session.stop();
    socket.emit({'type': 'error', 'message': 'provider said no'});
    socket.emit({'type': 'partial', 'text': 'late'});

    await expectLater(
      transcript,
      throwsA(isA<HermesDictationStreamException>()),
    );
    await pumpEventQueue();
    expect(partials, isEmpty);
    expect(socket.closed, isTrue);
  });

  test('no live STT for the provider: the take is already settled', () async {
    final socket = _FakeDictationSocket();
    final session = (await _client(socket).open(sampleRate: 16000))!;
    // audio.py:548-552 answers this right after the upgrade.
    socket.emit({
      'type': 'error',
      'message': 'no live STT for the configured provider',
    });
    await pumpEventQueue();

    session.pushAudio(Uint8List.fromList([9]));
    expect(socket.audioFrames, isEmpty);
    await expectLater(session.stop(), throwsA(anything));
    // stop() on a settled take sends nothing.
    expect(socket.textFrames, [
      {'sample_rate': 16000},
    ]);
  });

  test('a socket that closes without a final rejects stop', () async {
    final socket = _FakeDictationSocket();
    final session = (await _client(socket).open(sampleRate: 16000))!;
    final transcript = session.stop();
    await socket.controller.close();
    await expectLater(
      transcript,
      throwsA(isA<HermesDictationStreamException>()),
    );
  });

  test('a socket error rejects stop', () async {
    final socket = _FakeDictationSocket();
    final session = (await _client(socket).open(sampleRate: 16000))!;
    final transcript = session.stop();
    socket.controller.addError(StateError('drop'));
    await expectLater(
      transcript,
      throwsA(isA<HermesDictationStreamException>()),
    );
  });

  test('malformed and binary frames are ignored', () async {
    final socket = _FakeDictationSocket();
    final partials = <String>[];
    final session = (await _client(
      socket,
    ).open(sampleRate: 16000, onPartial: partials.add))!;
    socket.controller
      ..add('not json')
      ..add(jsonEncode([1, 2]))
      ..add(Uint8List.fromList([1]))
      ..add(jsonEncode({'type': 'partial', 'text': 7}));
    await pumpEventQueue();
    expect(partials, isEmpty);
    expect(session.settled, isFalse);
    session.cancel();
  });

  test('cancel closes without eos and drops what arrives later', () async {
    final socket = _FakeDictationSocket();
    final partials = <String>[];
    final session = (await _client(
      socket,
    ).open(sampleRate: 16000, onPartial: partials.add))!;

    session.cancel();
    session.cancel();
    socket.emit({'type': 'partial', 'text': 'late'});
    await pumpEventQueue();

    expect(socket.closes, 1);
    expect(partials, isEmpty);
    expect(socket.textFrames.any((frame) => frame.containsKey('eos')), isFalse);
    await expectLater(session.stop(), throwsA(anything));
  });

  test('a socket that does not open in 5 s resolves to null (Desktop)', () {
    expect(
      HermesDictationStreamClient.defaultOpenTimeout,
      const Duration(seconds: 5),
    );
    fakeAsync((async) {
      final socket = _FakeDictationSocket(ready: false);
      HermesDictationStreamSession? session;
      var done = false;
      unawaited(
        _client(socket).open(sampleRate: 16000).then((value) {
          session = value;
          done = true;
        }),
      );
      async.elapse(const Duration(milliseconds: 4999));
      expect(done, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(done, isTrue);
      expect(session, isNull);
      expect(socket.closed, isTrue);
      expect(socket.sent, isEmpty);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a refused upgrade resolves to null', () async {
    final socket = _FakeDictationSocket(ready: false)
      ..readyError = StateError('HTTP status code: 404');
    expect(await _client(socket).open(sampleRate: 16000), isNull);
    expect(socket.closed, isTrue);
  });

  test('a failed auth opens no socket', () async {
    final uris = <Uri>[];
    final session = await _client(
      _FakeDictationSocket(),
      uris: uris,
      auth: () async => throw const DashboardWebSocketAuthException(
        DashboardWebSocketAuthFailureCode.unavailable,
      ),
    ).open(sampleRate: 16000);
    expect(session, isNull);
    expect(uris, isEmpty);
  });

  test('a host that never finalizes falls back after the window', () {
    expect(
      HermesDictationStreamClient.defaultFinalTimeout,
      const Duration(seconds: 25),
    );
    fakeAsync((async) {
      final socket = _FakeDictationSocket();
      HermesDictationStreamSession? session;
      unawaited(
        _client(
          socket,
        ).open(sampleRate: 16000).then((value) => session = value),
      );
      async.flushMicrotasks();
      Object? failure;
      unawaited(
        session!.stop().then<void>(
          (_) {},
          onError: (Object error) {
            failure = error;
          },
        ),
      );
      async.elapse(const Duration(seconds: 24));
      expect(failure, isNull);
      async.elapse(const Duration(seconds: 1));
      expect(failure, isA<TimeoutException>());
      expect(socket.closed, isTrue);
      expect(async.pendingTimers, isEmpty);
    });
  });

  group('stt.streaming from /api/config (is_truthy_value)', () {
    bool enabled(Object? value) => hermesLiveDictationEnabledInConfig({
      'stt': {'streaming': value},
    });

    test('truthy values', () {
      for (final value in [true, 'true', ' Yes ', 'on', '1', 1, 2.5]) {
        expect(enabled(value), isTrue, reason: '$value');
      }
    });

    test('falsy values and missing keys', () {
      for (final value in [false, 'false', 'no', 'off', '0', '', 0, null]) {
        expect(enabled(value), isFalse, reason: '$value');
      }
      expect(hermesLiveDictationEnabledInConfig(null), isFalse);
      expect(hermesLiveDictationEnabledInConfig({'stt': 'x'}), isFalse);
      expect(hermesLiveDictationEnabledInConfig(<String, Object?>{}), isFalse);
    });
  });

  test('the gate verdict is held for 60 s and per key', () {
    var now = DateTime.utc(2026, 10, 26, 12);
    HermesLiveDictationGateCache.resetForTesting(now: () => now);
    addTearDown(HermesLiveDictationGateCache.resetForTesting);

    expect(HermesLiveDictationGateCache.read('a'), isNull);
    HermesLiveDictationGateCache.store('a', false);
    HermesLiveDictationGateCache.store('b', true);
    expect(HermesLiveDictationGateCache.read('a'), isFalse);
    expect(HermesLiveDictationGateCache.read('b'), isTrue);

    now = now.add(const Duration(seconds: 59));
    expect(HermesLiveDictationGateCache.read('b'), isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(HermesLiveDictationGateCache.read('b'), isNull);
    expect(HermesLiveDictationGateCache.read('a'), isNull);
  });
}
