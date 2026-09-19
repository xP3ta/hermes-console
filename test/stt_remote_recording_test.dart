import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_remote.dart';
import 'package:record/record.dart';

class _Recorder implements ServerSttRecorder {
  final audio = StreamController<Uint8List>();
  bool disposed = false;
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async =>
      audio.stream;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(audio.close());
  }
}

class _Session implements ServerSttSession {
  final incoming = StreamController<dynamic>();
  final sent = <Object>[];
  bool closed = false;
  bool ready = true;
  @override
  dynamic get firstMessage => ready ? '{"type":"ready"}' : null;
  @override
  Stream<dynamic> get messages => incoming.stream;
  @override
  void add(Object data) {
    if (closed) throw StateError('Closed');
    sent.add(data);
  }

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }

  void finalText(String text) {
    incoming.add(jsonEncode({'type': 'final', 'text': text}));
    unawaited(incoming.close());
  }
}

Future<void> _tick() async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  test(
    'three recordings each use fresh resources and exactly one final',
    () async {
      final sessions = <_Session>[];
      final recorders = <_Recorder>[];
      final engine = ServerSttEngine(
        baseUrl: 'wss://speech.invalid',
        enableGhostGate: false,
        recorderFactory: () {
          final r = _Recorder();
          recorders.add(r);
          return r;
        },
        connector: (_) async {
          final s = _Session();
          sessions.add(s);
          return s;
        },
      );
      addTearDown(engine.dispose);
      for (var i = 0; i < 3; i++) {
        final ready = Completer<void>();
        final result = engine.listen(onCaptureReady: ready.complete).toList();
        await ready.future;
        recorders.last.audio.add(Uint8List.fromList([0, 100]));
        await _tick();
        await engine.stop();
        await engine.stop();
        sessions.last.finalText('Recording $i');
        expect((await result).map((r) => r.text), ['Recording $i']);
        expect(recorders.last.disposed, isTrue);
        expect(sessions.last.closed, isTrue);
        expect(
          sessions.last.sent.where((e) => e == '{"type":"eof"}'),
          hasLength(1),
        );
      }
      expect(sessions, hasLength(3));
    },
  );

  test(
    'close after audio before final reports an error, never empty success',
    () async {
      final recorder = _Recorder();
      final session = _Session();
      final engine = ServerSttEngine(
        baseUrl: 'wss://speech.invalid',
        recorderFactory: () => recorder,
        connector: (_) async => session,
      );
      addTearDown(engine.dispose);
      final ready = Completer<void>();
      final results = <SttResult>[];
      final errors = <Object>[];
      final done = Completer<void>();
      engine
          .listen(onCaptureReady: ready.complete)
          .listen(results.add, onError: errors.add, onDone: done.complete);
      await ready.future;
      recorder.audio.add(Uint8List.fromList([0, 100]));
      await _tick();
      await session.incoming.close();
      await done.future;
      expect(results, isEmpty);
      expect(errors, hasLength(1));
    },
  );

  test(
    'connection closed before ready retries once without recording early',
    () async {
      final sessions = <_Session>[];
      final recorders = <_Recorder>[];
      final engine = ServerSttEngine(
        baseUrl: 'wss://speech.invalid',
        enableGhostGate: false,
        recorderFactory: () {
          final r = _Recorder();
          recorders.add(r);
          return r;
        },
        connector: (_) async {
          final s = _Session()..ready = sessions.isNotEmpty;
          sessions.add(s);
          if (!s.ready) scheduleMicrotask(() => unawaited(s.incoming.close()));
          return s;
        },
      );
      addTearDown(engine.dispose);
      final ready = Completer<void>();
      final result = engine.listen(onCaptureReady: ready.complete).toList();
      await ready.future;
      expect(sessions, hasLength(2));
      sessions.last.finalText('Retried');
      expect((await result).single.text, 'Retried');
    },
  );
  test('two pre-audio connection closures exhaust exactly one retry', () async {
    final sessions = <_Session>[];
    final engine = ServerSttEngine(
      baseUrl: 'wss://speech.invalid',
      recorderFactory: _Recorder.new,
      connector: (_) async {
        final session = _Session()..ready = false;
        sessions.add(session);
        scheduleMicrotask(() => unawaited(session.incoming.close()));
        return session;
      },
    );
    addTearDown(engine.dispose);
    final results = <SttResult>[];
    final errors = <Object>[];
    final done = Completer<void>();
    engine.listen().listen(
      results.add,
      onError: errors.add,
      onDone: done.complete,
    );
    await done.future;
    expect(sessions, hasLength(2));
    expect(errors, hasLength(1));
    expect(results, isEmpty);
  });
}
