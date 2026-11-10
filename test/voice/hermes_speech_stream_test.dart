import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/hermes_pcm_stream.dart';
import 'package:hermes_android/core/services/voice/hermes_speech_stream.dart';
import 'package:hermes_android/core/services/voice/voice_latency_trace.dart';

class _FakeSpeechSocket implements HermesSpeechSocket {
  _FakeSpeechSocket({bool ready = true}) {
    if (ready) readyCompleter.complete();
  }

  final StreamController<dynamic> controller = StreamController<dynamic>();
  final List<Map<String, dynamic>> sent = [];
  final Completer<void> readyCompleter = Completer<void>();
  bool closed = false;
  Object? nextSendError;

  @override
  Stream<dynamic> get frames => controller.stream;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  void send(String frame) {
    final error = nextSendError;
    nextSendError = null;
    if (error != null) throw error;
    sent.add(Map<String, dynamic>.from(jsonDecode(frame) as Map));
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  Future<void> emit(dynamic frame) async {
    controller.add(frame);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> fail(Object error) async {
    controller.addError(error);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakePcmSink implements HermesPcmStreamSink {
  @override
  final int generation = 1;

  final List<HermesPcmFormat> formats = [];
  final List<Uint8List> writes = [];
  Completer<void>? blockNextWrite;
  Object? nextWriteError;
  void Function()? onWriteEntered;
  int pauses = 0;
  int resumes = 0;
  bool finished = false;
  bool stopped = false;
  Future<void> _tail = Future<void>.value();

  Future<void> _serial(Future<void> Function() operation) {
    final current = _tail.then<void>((_) async {
      if (stopped) return;
      await operation();
    });
    _tail = current.then<void>((_) {}, onError: (_, _) {});
    return current;
  }

  @override
  Future<void> configure(HermesPcmFormat format) async {
    formats.add(format);
  }

  @override
  Future<void> write(Uint8List pcm16le) => _serial(() async {
    onWriteEntered?.call();
    final error = nextWriteError;
    nextWriteError = null;
    if (error != null) throw error;
    writes.add(Uint8List.fromList(pcm16le));
    final blocker = blockNextWrite;
    blockNextWrite = null;
    if (blocker != null) await blocker.future;
  });

  @override
  Future<void> pause() => _serial(() async {
    pauses++;
  });

  @override
  Future<void> resume() => _serial(() async {
    resumes++;
  });

  @override
  Future<void> finish() => _serial(() async {
    finished = true;
  });

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

class _DrainPcmSink extends _FakePcmSink {
  final Completer<void> finishEntered = Completer<void>();
  final Completer<void> releaseFinish = Completer<void>();

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {
    resumes++;
  }

  @override
  Future<void> finish() async {
    finished = true;
    finishEntered.complete();
    await releaseFinish.future;
  }
}

class _PauseBeforeMethodChannelWriteSink implements HermesPcmStreamSink {
  _PauseBeforeMethodChannelWriteSink(this.delegate);

  final MethodChannelHermesPcmStreamSink delegate;
  Future<void> Function()? pauseBeforeFirstWrite;
  bool _armed = true;

  @override
  int get generation => delegate.generation;

  @override
  Future<void> configure(HermesPcmFormat format) => delegate.configure(format);

  @override
  Future<void> write(Uint8List pcm16le) async {
    if (_armed) {
      _armed = false;
      await pauseBeforeFirstWrite?.call();
    }
    await delegate.write(pcm16le);
  }

  @override
  Future<void> pause() => delegate.pause();

  @override
  Future<void> resume() => delegate.resume();

  @override
  Future<void> finish() => delegate.finish();

  @override
  Future<void> stop() => delegate.stop();
}

Future<HermesSpeechStreamSession> _open(
  _FakeSpeechSocket socket,
  _FakePcmSink sink, {
  void Function()? onPcmAccepted,
  VoiceLatencyTurn? latencyTurn,
}) async {
  final session = HermesSpeechStreamSession(
    socket: socket,
    sink: sink,
    finishTimeout: const Duration(seconds: 2),
    onPcmAccepted: onPcmAccepted,
    latencyTurn: latencyTurn,
  );
  await session.open();
  return session;
}

VoiceLatencyTurn _serverLatencyTurn(List<VoiceLatencyRecord> records) {
  var nowMicros = 1000;
  final trace = VoiceLatencyTrace.testing(
    runId: '0123456789abcdef',
    nowMicros: () => nowMicros += 100,
    onRecord: records.add,
  );
  final turn = trace.beginTurn(
    route: VoiceLatencyRoute.server,
    scenario: VoiceLatencyScenario.normal,
  );
  for (final point in const <VoiceLatencyPoint>[
    VoiceLatencyPoint.submitStarted,
    VoiceLatencyPoint.submitAccepted,
    VoiceLatencyPoint.backendTextAccepted,
    VoiceLatencyPoint.firstRawSpeechSuffix,
    VoiceLatencyPoint.ttsFirstFeed,
  ]) {
    expect(
      turn.mark(point),
      isTrue,
      reason: 'El fixture debe respetar la cadena causal previa al PCM',
    );
  }
  return turn;
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for speech-stream state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('first PCM is written before end and finish drains once', () async {
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink();
    final session = await _open(socket, sink);

    await session.append('Hola ');
    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );
    await socket.emit(Uint8List.fromList([1, 0, 2, 0]));

    expect(await session.firstPcm, isTrue);
    expect(sink.writes, hasLength(1));
    expect(sink.finished, isFalse);

    final done = session.finish();
    expect(socket.sent.any((frame) => frame['done'] == true), isTrue);
    await socket.emit(jsonEncode({'type': 'end'}));

    expect(await done, HermesSpeechStreamOutcome.played);
    expect(sink.finished, isTrue);
    expect(socket.closed, isTrue);
  });

  test(
    'Pause y Resume alcanzan el mismo sink durante el drenaje final',
    () async {
      final socket = _FakeSpeechSocket();
      final sink = _DrainPcmSink();
      final session = await _open(socket, sink);
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(Uint8List.fromList([1, 0, 2, 0]));

      final done = session.finish();
      final endDelivery = socket.emit(jsonEncode({'type': 'end'}));
      await sink.finishEntered.future.timeout(const Duration(seconds: 1));

      await session.pause().timeout(const Duration(seconds: 1));
      expect(sink.pauses, 1);
      expect(session.paused, isTrue);

      await session.resume().timeout(const Duration(seconds: 1));
      expect(sink.resumes, 1);
      expect(session.paused, isFalse);

      sink.releaseFinish.complete();
      await endDelivery.timeout(const Duration(seconds: 1));
      expect(await done, HermesSpeechStreamOutcome.played);
      expect(sink.stopped, isFalse);
    },
  );

  test(
    'un fallo síncrono al enviar texto degrada antes del primer PCM',
    () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final session = await _open(socket, sink);
      socket.nextSendError = StateError('socket closed');

      await expectLater(session.append('Hola '), completes);

      expect(
        await session.done.timeout(const Duration(seconds: 1)),
        HermesSpeechStreamOutcome.fallback,
      );
      expect(session.state, HermesSpeechStreamState.failedBeforeAudio);
      expect(sink.stopped, isTrue);
    },
  );

  test('un fallo síncrono al terminar no deja el stream colgado', () async {
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink();
    final session = await _open(socket, sink);
    socket.nextSendError = StateError('socket closed');

    expect(
      await session.finish().timeout(const Duration(seconds: 1)),
      HermesSpeechStreamOutcome.fallback,
    );
    expect(session.state, HermesSpeechStreamState.failedBeforeAudio);
    expect(sink.stopped, isTrue);
  });

  test('un fallo síncrono al terminar tras PCM queda como parcial', () async {
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink();
    final session = await _open(socket, sink);
    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );
    await socket.emit(Uint8List.fromList([1, 0, 2, 0]));
    expect(await session.firstPcm, isTrue);
    socket.nextSendError = StateError('socket closed');

    expect(
      await session.finish().timeout(const Duration(seconds: 1)),
      HermesSpeechStreamOutcome.partial,
    );
    expect(session.state, HermesSpeechStreamState.failedAfterAudio);
    expect(sink.stopped, isTrue);
  });

  test('start temprano aún permite vallar el primer write PCM', () async {
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink();
    final session = await _open(socket, sink);

    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );
    expect(session.state, HermesSpeechStreamState.streaming);
    expect(sink.formats, hasLength(1));

    final fence = Completer<void>();
    session.setPlaybackFence(() => fence.future);
    await session.append('Hola ');
    unawaited(socket.emit(Uint8List.fromList([1, 0, 2, 0])));
    await Future<void>.delayed(Duration.zero);
    expect(sink.writes, isEmpty);

    fence.complete();
    await session.firstPcm;
    expect(sink.writes, hasLength(1));
    await session.cancel();
  });

  test('cancelar durante la valla impide cualquier write tardío', () async {
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink();
    final session = await _open(socket, sink);
    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );

    final fence = Completer<void>();
    session.setPlaybackFence(() => fence.future);
    unawaited(socket.emit(Uint8List.fromList([1, 0, 2, 0])));
    await Future<void>.delayed(Duration.zero);
    await session.cancel();
    fence.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(sink.writes, isEmpty);
    expect(await session.done, HermesSpeechStreamOutcome.cancelled);
  });

  test(
    'official fallback before PCM is conclusive and does not play',
    () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final session = await _open(socket, sink);

      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      await socket.emit(jsonEncode({'type': 'fallback'}));

      expect(await session.done, HermesSpeechStreamOutcome.fallback);
      expect(
        session.fallbackKind,
        HermesSpeechStreamFallbackKind.providerUnsupported,
      );
      expect(sink.writes, isEmpty);
    },
  );

  test('transport failure falls back only before the first PCM', () async {
    final beforeSocket = _FakeSpeechSocket();
    final before = await _open(beforeSocket, _FakePcmSink());
    await beforeSocket.fail(StateError('offline'));
    expect(await before.done, HermesSpeechStreamOutcome.fallback);

    final afterSocket = _FakeSpeechSocket();
    final afterSink = _FakePcmSink();
    final after = await _open(afterSocket, afterSink);
    await afterSocket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );
    await afterSocket.emit(Uint8List.fromList([1, 0]));
    await afterSocket.fail(StateError('dropped'));

    expect(await after.done, HermesSpeechStreamOutcome.partial);
    expect(after.receivedPcm, isTrue);
    expect(afterSink.stopped, isTrue);
  });

  test(
    'zero accepted bytes on first native write still use POST fallback',
    () async {
      final socket = _FakeSpeechSocket();
      final latencyRecords = <VoiceLatencyRecord>[];
      final latencyTurn = _serverLatencyTurn(latencyRecords);
      var receivedWasVisibleBeforeWrite = false;
      final sink = _FakePcmSink()
        ..onWriteEntered = () {
          receivedWasVisibleBeforeWrite = latencyRecords.any(
            (record) => record.point == VoiceLatencyPoint.pcmFirstReceived,
          );
        }
        ..nextWriteError = const HermesPcmWriteException(
          acceptedBytes: 0,
          mayHavePlayed: false,
          cause: 'focus lost',
        );
      final session = await _open(socket, sink, latencyTurn: latencyTurn);
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );

      await socket.emit(Uint8List.fromList([1, 0, 2, 0]));

      expect(await session.done, HermesSpeechStreamOutcome.fallback);
      expect(await session.firstPcm, isFalse);
      expect(await session.firstPcmPossiblyWritten, isFalse);
      expect(await session.firstPcmReceived, isTrue);
      expect(await session.firstPcmAccepted, isFalse);
      expect(session.receivedPcm, isFalse);
      expect(session.pcmConfirmed, isFalse);
      expect(session.state, HermesSpeechStreamState.failedBeforeAudio);
      expect(sink.stopped, isTrue);
      expect(receivedWasVisibleBeforeWrite, isTrue);
      expect(
        latencyRecords.map((record) => record.point),
        contains(VoiceLatencyPoint.pcmFirstReceived),
      );
      expect(
        latencyRecords.map((record) => record.point),
        isNot(contains(VoiceLatencyPoint.pcmFirstAccepted)),
      );
      expect(
        latencyRecords.map((record) => record.point),
        isNot(contains(VoiceLatencyPoint.pcmAudibleUnavailable)),
      );
      latencyTurn.finish();
      expect(
        latencyRecords.map((record) => record.point),
        isNot(contains(VoiceLatencyPoint.pcmAcceptLatency)),
        reason: 'un write que acepta 0 bytes no aporta una muestra PCM valida',
      );
    },
  );

  test(
    'a partially accepted first native write never replays the turn',
    () async {
      final socket = _FakeSpeechSocket();
      final latencyRecords = <VoiceLatencyRecord>[];
      final latencyTurn = _serverLatencyTurn(latencyRecords);
      var acceptedWasAbsentWhenWriteEntered = false;
      final sink = _FakePcmSink()
        ..onWriteEntered = () {
          acceptedWasAbsentWhenWriteEntered = !latencyRecords.any(
            (record) => record.point == VoiceLatencyPoint.pcmFirstAccepted,
          );
        }
        ..nextWriteError = const HermesPcmWriteException(
          acceptedBytes: 2,
          mayHavePlayed: true,
          cause: 'partial native write',
        );
      var acceptedCallbacks = 0;
      final session = await _open(
        socket,
        sink,
        onPcmAccepted: () => acceptedCallbacks += 1,
        latencyTurn: latencyTurn,
      );
      final firstPcmOrder = <String>[];
      unawaited(
        session.firstPcmReceived.then((_) => firstPcmOrder.add('received')),
      );
      unawaited(
        session.firstPcmAccepted.then((_) => firstPcmOrder.add('accepted')),
      );
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );

      await socket.emit(Uint8List.fromList([1, 0, 2, 0]));

      expect(await session.done, HermesSpeechStreamOutcome.partial);
      expect(await session.firstPcm, isTrue);
      expect(await session.firstPcmReceived, isTrue);
      expect(await session.firstPcmAccepted, isTrue);
      expect(session.receivedPcm, isTrue);
      expect(session.pcmConfirmed, isTrue);
      expect(acceptedCallbacks, 1);
      expect(firstPcmOrder, orderedEquals(['received', 'accepted']));
      expect(acceptedWasAbsentWhenWriteEntered, isTrue);
      expect(
        latencyRecords.map((record) => record.point),
        containsAllInOrder(const <VoiceLatencyPoint>[
          VoiceLatencyPoint.pcmFirstReceived,
          VoiceLatencyPoint.pcmFirstAccepted,
          VoiceLatencyPoint.pcmAudibleUnavailable,
        ]),
      );
      latencyTurn.finish();
      final pcmSummary = latencyRecords.singleWhere(
        (record) => record.point == VoiceLatencyPoint.pcmAcceptLatency,
      );
      expect(pcmSummary.arguments, containsPair('count', 1));
      expect(pcmSummary.arguments, containsPair('dropped', 0));
      expect(session.state, HermesSpeechStreamState.failedAfterAudio);
      expect(sink.stopped, isTrue);
    },
  );

  test('an untyped write failure remains conservatively partial', () async {
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink()
      ..nextWriteError = StateError('unknown sink failure');
    final session = await _open(socket, sink);
    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );

    await socket.emit(Uint8List.fromList([1, 0]));

    expect(await session.done, HermesSpeechStreamOutcome.partial);
    expect(await session.firstPcmReceived, isTrue);
    expect(await session.firstPcmAccepted, isFalse);
    expect(session.receivedPcm, isTrue);
    expect(session.pcmConfirmed, isFalse);
  });

  test('an untyped write failure never records PCM evidence', () async {
    HermesSpeechStreamEvidence.debugClear();
    addTearDown(HermesSpeechStreamEvidence.debugClear);
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink()
      ..nextWriteError = StateError('unknown sink failure');
    final client = HermesSpeechStreamClient(
      dashboardBaseUrl: 'https://hermes.example',
      auth: () async => const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'single-use-ticket',
      ),
      sinkFactory: () => sink,
      connector: (_, _) => socket,
    );
    final session = await client.open();
    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );

    await socket.emit(Uint8List.fromList([1, 0]));

    expect(await session.done, HermesSpeechStreamOutcome.partial);
    expect(session.receivedPcm, isTrue, reason: 'el turno no debe repetirse');
    expect(session.pcmConfirmed, isFalse);
    expect(
      HermesSpeechStreamEvidence.pcmObserved('https://hermes.example'),
      isFalse,
    );
  });

  test(
    'odd provider chunks carry one byte without corrupting sample order',
    () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final session = await _open(socket, sink);
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );

      await socket.emit(Uint8List.fromList([1, 0, 2]));
      await socket.emit(Uint8List.fromList([0, 3, 0]));
      final done = session.finish();
      await socket.emit(jsonEncode({'type': 'end'}));

      expect(await done, HermesSpeechStreamOutcome.played);
      expect(sink.writes.map((bytes) => bytes.toList()), [
        [1, 0],
        [2, 0, 3, 0],
      ]);
    },
  );

  test('socket frame consumption respects sink backpressure', () async {
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink();
    final blocker = Completer<void>();
    sink.blockNextWrite = blocker;
    final session = await _open(socket, sink);
    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );

    socket.controller.add(Uint8List.fromList([1, 0]));
    socket.controller.add(Uint8List.fromList([2, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(sink.writes, hasLength(1));
    var firstPcmReceivedResolved = false;
    unawaited(
      session.firstPcmReceived.then((_) {
        firstPcmReceivedResolved = true;
      }),
    );
    var firstPcmResolved = false;
    unawaited(
      session.firstPcm.then((_) {
        firstPcmResolved = true;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(firstPcmReceivedResolved, isTrue);
    expect(firstPcmResolved, isFalse);

    blocker.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(sink.writes, hasLength(2));
    expect(await session.firstPcm, isTrue);

    await session.cancel();
  });

  test(
    'Pause deja como máximo un frame en vuelo y backpressures el socket',
    () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final blocker = Completer<void>();
      sink.blockNextWrite = blocker;
      final session = await _open(socket, sink);
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );

      final frames = <Uint8List>[
        Uint8List.fromList([1, 0]),
        Uint8List.fromList([2, 0]),
        Uint8List.fromList([3, 0]),
      ];
      for (final frame in frames) {
        socket.controller.add(frame);
      }
      await _waitFor(() => sink.writes.length == 1);

      final pause = session.pause();
      await Future<void>.delayed(Duration.zero);
      expect(sink.pauses, 0, reason: 'Pause waits for the in-flight write');
      blocker.complete();
      await pause.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(sink.writes, hasLength(1));
      expect(sink.pauses, 1);
      await session.resume();
      await _waitFor(() => sink.writes.length == frames.length);

      expect(sink.resumes, 1);
      expect(sink.writes.map((bytes) => bytes.toList()), [
        [1, 0],
        [2, 0],
        [3, 0],
      ]);
      await session.cancel();
    },
  );

  test(
    'Pause durante write y Resume inmediato drenan el frame exacto sin deadlock',
    () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final blocker = Completer<void>();
      sink.blockNextWrite = blocker;
      final session = await _open(socket, sink);
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      final payload = Uint8List.fromList(
        List<int>.generate(
          HermesSpeechStreamSession.playbackWriteChunkBytes * 2 + 2,
          (index) => index & 0xff,
        ),
      );
      socket.controller.add(payload);
      await _waitFor(() => sink.writes.length == 1);

      final pause = session.pause();
      final resume = session.resume();
      blocker.complete();
      await Future.wait([pause, resume]).timeout(const Duration(seconds: 1));
      await _waitFor(() => sink.writes.length == 3);

      expect(sink.pauses, 1);
      expect(sink.resumes, 1);
      expect(sink.writes.expand((bytes) => bytes), payload);
      await session.cancel();
    },
  );

  test(
    'Pause entre el gate y write conserva un solo bloque PCM en vuelo',
    () async {
      const channel = MethodChannel('test/hermes_speech_pause_write_race');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      final writeEntered = Completer<void>();
      final releaseWrite = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'write') {
          if (!writeEntered.isCompleted) writeEntered.complete();
          await releaseWrite.future;
          final pcm = (call.arguments as Map)['pcm'] as Uint8List;
          return <String, Object>{
            'acceptedBytes': pcm.length,
            'mayHavePlayed': true,
          };
        }
        if (call.method == 'resume' && !releaseWrite.isCompleted) {
          releaseWrite.complete();
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      });

      final socket = _FakeSpeechSocket();
      final sink = _PauseBeforeMethodChannelWriteSink(
        MethodChannelHermesPcmStreamSink(channel: channel, generation: 422),
      );
      final session = HermesSpeechStreamSession(
        socket: socket,
        sink: sink,
        finishTimeout: const Duration(seconds: 2),
      );
      sink.pauseBeforeFirstWrite = session.pause;
      await session.open();
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );

      // El wrapper se ejecuta después del gate de _handlePcm y fuerza Pause
      // justo antes de delegar al MethodChannel concreto.
      socket.controller.add(Uint8List.fromList([1, 0, 2, 0]));

      final firstTerminalEvent = await Future.any<String>([
        writeEntered.future.then((_) => 'write'),
        session.done.then((_) => 'settled'),
      ]).timeout(const Duration(seconds: 1));
      expect(
        firstTerminalEvent,
        'write',
        reason:
            'Pause no debe convertir el bloque ya en vuelo en protocol fail',
      );
      expect(session.paused, isTrue);
      expect(calls.where((method) => method == 'write'), hasLength(1));

      await session.resume().timeout(const Duration(seconds: 1));
      expect(
        await session.firstPcm.timeout(const Duration(seconds: 1)),
        isTrue,
      );
      expect(calls.where((method) => method == 'write'), hasLength(1));

      final done = session.finish();
      await socket.emit(jsonEncode({'type': 'end'}));
      expect(await done, HermesSpeechStreamOutcome.played);
      expect(calls.where((method) => method == 'stop'), isEmpty);
    },
  );

  test(
    'cancel durante Pause y write bloqueado libera gates, Stop y done',
    () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final blocker = Completer<void>();
      sink.blockNextWrite = blocker;
      final session = await _open(socket, sink);
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      socket.controller.add(Uint8List.fromList([1, 0]));
      await _waitFor(() => sink.writes.length == 1);
      final pause = session.pause();
      final pendingAppend = session.append('cola que no debe enviarse');

      await session.cancel().timeout(const Duration(seconds: 1));
      await pendingAppend.timeout(const Duration(seconds: 1));

      expect(await session.done, HermesSpeechStreamOutcome.cancelled);
      expect(socket.sent.any((frame) => frame['stop'] == true), isTrue);
      expect(
        socket.sent.any(
          (frame) => frame['text'] == 'cola que no debe enviarse',
        ),
        isFalse,
      );
      expect(sink.stopped, isTrue);
      expect(session.receivedPcm, isFalse);

      blocker.complete();
      await pause.timeout(const Duration(seconds: 1));
    },
  );

  test('cancel sends stop and invalidates the sink immediately', () async {
    final socket = _FakeSpeechSocket();
    final sink = _FakePcmSink();
    final session = await _open(socket, sink);
    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );

    await session.cancel();

    expect(await session.done, HermesSpeechStreamOutcome.cancelled);
    expect(socket.sent.any((frame) => frame['stop'] == true), isTrue);
    expect(sink.stopped, isTrue);
  });

  test('client URI preserves base query, auth and effective profile', () {
    final client = HermesSpeechStreamClient(
      dashboardBaseUrl: 'https://hermes.example/base/?tenant=one',
      auth: () async => const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'secret-ticket',
        headers: {'Authorization': 'Basic redacted'},
      ),
      profile: 'research',
      sinkFactory: _FakePcmSink.new,
    );

    final uri = client.buildUri(
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'secret-ticket',
      ),
    );

    expect(uri.scheme, 'wss');
    expect(uri.path, '/base/api/audio/speak-stream');
    expect(uri.queryParameters['tenant'], 'one');
    expect(uri.queryParameters['ticket'], 'secret-ticket');
    expect(uri.queryParameters['profile'], 'research');
  });

  test('client forwards Basic Auth headers to the WebSocket upgrade', () async {
    final socket = _FakeSpeechSocket();
    Uri? connectedUri;
    Map<String, dynamic>? connectedHeaders;
    final client = HermesSpeechStreamClient(
      dashboardBaseUrl: 'https://hermes.example',
      auth: () async => const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'single-use-ticket',
        headers: {'Authorization': 'Basic redacted'},
      ),
      sinkFactory: _FakePcmSink.new,
      connector: (uri, headers) {
        connectedUri = uri;
        connectedHeaders = Map<String, dynamic>.from(headers);
        return socket;
      },
    );

    final session = await client.open();

    expect(connectedUri?.queryParameters['ticket'], 'single-use-ticket');
    expect(connectedHeaders, {'Authorization': 'Basic redacted'});
    await session.cancel();
  });

  test('records PCM evidence only after AudioTrack accepts a frame', () async {
    HermesSpeechStreamEvidence.debugClear();
    addTearDown(HermesSpeechStreamEvidence.debugClear);
    final socket = _FakeSpeechSocket();
    final client = HermesSpeechStreamClient(
      dashboardBaseUrl: 'https://hermes.example',
      auth: () async => const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'single-use-ticket',
      ),
      profile: 'research',
      ttsConfigurationSignature: 'tts-A',
      sinkFactory: _FakePcmSink.new,
      connector: (uri, headers) => socket,
    );

    final session = await client.open();
    expect(
      HermesSpeechStreamEvidence.pcmObserved(
        'https://hermes.example',
        profile: 'research',
        ttsConfigurationSignature: 'tts-A',
      ),
      isFalse,
    );
    await socket.emit(
      jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
    );
    expect(
      HermesSpeechStreamEvidence.pcmObserved(
        'https://hermes.example',
        profile: 'research',
        ttsConfigurationSignature: 'tts-A',
      ),
      isFalse,
    );

    await socket.emit(Uint8List.fromList([1, 0, 2, 0]));

    expect(await session.firstPcm, isTrue);
    expect(session.pcmConfirmed, isTrue);
    expect(
      HermesSpeechStreamEvidence.pcmObserved(
        'https://hermes.example',
        profile: 'research',
        ttsConfigurationSignature: 'tts-A',
      ),
      isTrue,
    );
    expect(
      HermesSpeechStreamEvidence.pcmObserved(
        'https://hermes.example',
        profile: 'research',
        ttsConfigurationSignature: 'tts-B',
      ),
      isFalse,
      reason: 'la evidencia de otra configuración TTS no se reutiliza',
    );
    expect(
      HermesSpeechStreamEvidence.pcmObserved('https://hermes.example'),
      isFalse,
      reason: 'la evidencia de otro perfil no se mezcla',
    );
    await session.cancel();
  });

  test(
    'invalid control or PCM before start never reaches AudioTrack',
    () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final session = await _open(socket, sink);

      await socket.emit(Uint8List.fromList([1, 0]));

      expect(await session.done, HermesSpeechStreamOutcome.fallback);
      expect(session.state, HermesSpeechStreamState.failedBeforeAudio);
      expect(sink.writes, isEmpty);
      expect(sink.stopped, isTrue);
    },
  );

  test('client timeout cancels the unopened socket and native sink', () async {
    final socket = _FakeSpeechSocket(ready: false);
    final sink = _FakePcmSink();
    final client = HermesSpeechStreamClient(
      dashboardBaseUrl: 'https://hermes.example',
      auth: () async => const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'redacted',
      ),
      sinkFactory: () => sink,
      connector: (_, _) => socket,
      connectTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      client.open(),
      throwsA(
        isA<HermesSpeechStreamOpenException>().having(
          (error) => error.endpointUnavailable,
          'endpointUnavailable',
          isFalse,
        ),
      ),
    );

    expect(socket.closed, isTrue);
    expect(sink.stopped, isTrue);
    expect(socket.sent.any((frame) => frame['stop'] == true), isTrue);
  });

  test('only conclusive upgrade statuses disable the endpoint', () {
    for (final status in [404, 405, 426]) {
      final error = HermesSpeechStreamOpenException(
        StateError('HTTP status code: $status'),
      );
      expect(error.endpointUnavailable, isTrue, reason: 'HTTP $status');
    }

    for (final cause in [
      StateError('HTTP status code: 401'),
      StateError('HTTP status code: 403'),
      StateError('Connection timed out'),
      StateError('Network unreachable'),
    ]) {
      expect(
        HermesSpeechStreamOpenException(cause).endpointUnavailable,
        isFalse,
        reason: '$cause',
      );
    }
  });
  group('first audio cap', () {
    Future<HermesSpeechStreamSession> openWithCap(
      _FakeSpeechSocket socket,
      _FakePcmSink sink,
    ) async {
      final session = HermesSpeechStreamSession(
        socket: socket,
        sink: sink,
        finishTimeout: const Duration(seconds: 30),
        firstAudioTimeout: const Duration(milliseconds: 60),
      );
      await session.open();
      await socket.emit(
        jsonEncode({'type': 'start', 'sample_rate': 24000, 'channels': 1}),
      );
      return session;
    }

    test('an open socket that never sends audio falls back', () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final session = await openWithCap(socket, sink);

      expect(await session.append('Hola, ¿qué tal?'), isTrue);
      final outcome = await session.done.timeout(const Duration(seconds: 2));

      expect(outcome, HermesSpeechStreamOutcome.fallback);
      expect(session.fallbackKind, HermesSpeechStreamFallbackKind.transport);
      expect(sink.stopped, isTrue);
      expect(socket.closed, isTrue);
    });

    test('the first audio disarms it', () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final session = await openWithCap(socket, sink);

      await session.append('Hola.');
      await socket.emit(Uint8List(8));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(session.receivedPcm, isTrue);
      expect(session.fallbackKind, isNull);
      await session.cancel();
    });

    test('without text sent there is nothing to wait for', () async {
      final socket = _FakeSpeechSocket();
      final sink = _FakePcmSink();
      final session = await openWithCap(socket, sink);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(session.fallbackKind, isNull);
      await session.cancel();
    });
  });
}
