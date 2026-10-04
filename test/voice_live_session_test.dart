import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/live/live_rtc_transport.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_api.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_session.dart';

import 'support/voice_live_fakes.dart';

class _Harness {
  _Harness({List<Map<String, dynamic>> history = const []}) {
    transport = FakeLiveRtcTransport(log: log);
    api = FakeVoiceLiveApi(log: log);
    session = VoiceLiveSession(
      transport: transport,
      api: api,
      profile: 'ops',
      history: history,
      onDelegation: (id, context) =>
          delegations.add((id: id, context: context)),
      onClosed: (reason, seconds) =>
          closed.add((reason: reason, seconds: seconds)),
      onNotice: notices.add,
      onTranscript: transcripts.add,
    );
  }

  final List<String> log = [];
  late final FakeLiveRtcTransport transport;
  late final FakeVoiceLiveApi api;
  late final VoiceLiveSession session;
  final delegations = <({String id, List<VoiceLiveFragment> context})>[];
  final closed = <({String reason, int? seconds})>[];
  final notices = <String>[];
  final transcripts = <VoiceLiveFragment>[];

  /// Runs start() to completion under the fake clock.
  void start(FakeAsync async) {
    unawaited(session.start());
    async.flushMicrotasks();
  }
}

Map<String, dynamic> _delta(String type, String text, {int? start, int? end}) =>
    {'type': type, 'delta': text, 'start_ms': ?start, 'end_ms': ?end};

void main() {
  test('start order: channel before offer, POST after ICE, answer last', () {
    fakeAsync((async) {
      final h = _Harness();
      h.start(async);
      expect(h.log, [
        'openMicrophone',
        'addMicrophoneTrack',
        'createEventsChannel:oai-events',
        'createOffer',
        'setLocalDescription',
        'waitForIce',
        'createSession',
        'setRemoteAnswer',
      ]);
      expect(h.transport.remoteAnswer, 'v=0\r\nanswer\r\n');
      expect(h.session.sessionId, 'sess_1');
    });
  });

  test(
    'sends localDescription.sdp byte-exact with the profile and history',
    () {
      fakeAsync((async) {
        final history = [
          {'type': 'message', 'role': 'user', 'content': <Object>[]},
        ];
        final h = _Harness(history: history);
        h.start(async);
        final call = h.api.createCalls.single;
        expect(call.sdp, h.transport.localSdp);
        expect(call.sdp.endsWith('\r\n'), isTrue);
        expect(call.profile, 'ops');
        expect(call.history, history);
      });
    },
  );

  test('waits up to 10 s for ICE then continues (timeout is not an error)', () {
    fakeAsync((async) {
      final h = _Harness();
      h.transport.iceGathering = Completer<void>();
      h.start(async);
      async.elapse(const Duration(seconds: 9, milliseconds: 900));
      expect(h.api.createCalls, isEmpty);
      async.elapse(const Duration(milliseconds: 200));
      expect(h.api.createCalls, hasLength(1));
      expect(h.log.last, 'setRemoteAnswer');
    });
  });

  test('ICE completing early skips the wait', () {
    fakeAsync((async) {
      final h = _Harness();
      h.transport.iceGathering = Completer<void>();
      h.start(async);
      expect(h.api.createCalls, isEmpty);
      h.transport.iceGathering.complete();
      async.flushMicrotasks();
      expect(h.api.createCalls, hasLength(1));
    });
  });

  test('connection failed while gathering ICE aborts start and tears down', () {
    fakeAsync((async) {
      final h = _Harness();
      h.transport.iceGathering = Completer<void>();
      Object? error;
      unawaited(h.session.start().catchError((Object e) => error = e));
      async.flushMicrotasks();
      h.transport.emitState(LiveRtcConnectionState.failed);
      async.flushMicrotasks();
      expect(error, isA<VoiceLiveStartException>());
      expect(h.api.createCalls, isEmpty);
      expect(h.transport.disposeCalls, 1);
      expect(h.closed, isEmpty, reason: 'start failures are reported by throw');
    });
  });

  test('a failing POST tears down and rethrows', () {
    fakeAsync((async) {
      final h = _Harness();
      h.api.createError = const VoiceLiveSessionException(
        statusCode: 503,
        detail: 'no key',
      );
      Object? error;
      unawaited(h.session.start().catchError((Object e) => error = e));
      async.flushMicrotasks();
      expect(error, isA<VoiceLiveSessionException>());
      expect(h.transport.disposeCalls, 1);
      expect(h.log, isNot(contains('setRemoteAnswer')));
    });
  });

  test('microphone failure tears down before any request', () {
    fakeAsync((async) {
      final h = _Harness();
      h.transport.openMicrophoneError = StateError('denied');
      Object? error;
      unawaited(h.session.start().catchError((Object e) => error = e));
      async.flushMicrotasks();
      expect(error, isA<StateError>());
      expect(h.api.createCalls, isEmpty);
      expect(h.transport.disposeCalls, 1);
    });
  });

  group('events', () {
    test('session.started marks started and adopts the session id', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        expect(h.session.started, isFalse);
        h.transport.emitEvent({
          'type': 'session.started',
          'session': {'id': 'sess_live'},
        });
        expect(h.session.started, isTrue);
        expect(h.session.sessionId, 'sess_live');
      });
    });

    test('transcript deltas become fragments with default timings', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitEvent(
          _delta('session.input_transcript.delta', 'hola', start: 5, end: 9),
        );
        h.transport.emitEvent(
          _delta('session.output_transcript.delta', 'dime'),
        );
        expect(
          h.transcripts.map((f) => (f.speaker, f.text, f.startMs, f.endMs)),
          [
            (VoiceLiveSpeaker.user, 'hola', 5, 9),
            (VoiceLiveSpeaker.assistant, 'dime', 0, 0),
          ],
        );
      });
    });

    test('transcript buffer above 2000 trims to the newest 1500', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        for (var i = 0; i < 2000; i++) {
          h.transport.emitEvent(
            _delta('session.input_transcript.delta', 'w$i', start: i, end: i),
          );
        }
        expect(h.session.transcriptLength, 2000);
        h.transport.emitEvent(
          _delta(
            'session.input_transcript.delta',
            'w2000',
            start: 2000,
            end: 2000,
          ),
        );
        expect(h.session.transcriptLength, 1500);
      });
    });

    test('delegation context: last 80 fragments within 5 minutes', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitEvent(
          _delta(
            'session.input_transcript.delta',
            'viejo',
            start: 0,
            end: 1000,
          ),
        );
        for (var i = 0; i < 100; i++) {
          h.transport.emitEvent(
            _delta(
              'session.input_transcript.delta',
              'n$i',
              start: 400000 + i,
              end: 400000 + i,
            ),
          );
        }
        h.transport.emitEvent({
          'type': 'session.delegation.created',
          'delegation': {'id': 'del_1'},
        });
        final context = h.delegations.single.context;
        expect(context, hasLength(80));
        expect(context.first.text, 'n20');
        expect(context.last.text, 'n99');
        expect(context.any((f) => f.text == 'viejo'), isFalse);
      });
    });

    test('delegation.created needs an id and sets the active delegation', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitEvent({'type': 'session.delegation.created'});
        h.transport.emitEvent({
          'type': 'session.delegation.created',
          'delegation': <String, dynamic>{},
        });
        expect(h.delegations, isEmpty);
        h.transport.emitEvent({
          'type': 'session.delegation.created',
          'delegation': {'id': 'del_7'},
        });
        expect(h.delegations.map((d) => d.id), ['del_7']);
        expect(h.session.activeDelegationId, 'del_7');
      });
    });

    test('context_injection_incomplete is ignored; other errors notify', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitEvent({
          'type': 'error',
          'error': {'code': 'context_injection_incomplete', 'message': 'late'},
        });
        expect(h.notices, isEmpty);
        h.transport.emitEvent({
          'type': 'error',
          'error': {'code': 'rate_limit', 'message': 'slow down'},
        });
        expect(h.notices, ['slow down']);
        expect(h.closed, isEmpty);
      });
    });

    test('invalid JSON and unknown events are ignored', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitRaw('{not json');
        h.transport.emitRaw('[1,2]');
        h.transport.emitEvent({'type': 'session.mystery'});
        expect(h.closed, isEmpty);
        expect(h.notices, isEmpty);
        expect(h.session.transcriptLength, 0);
      });
    });

    test('session.closed finishes with reason and usage seconds', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitEvent({
          'type': 'session.closed',
          'reason': 'idle_timeout',
          'usage': {'seconds': 42},
        });
        expect(h.closed, [(reason: 'idle_timeout', seconds: 42)]);
        expect(h.transport.disposeCalls, 1);
      });
    });

    test('session.closed without reason reports closed', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitEvent({'type': 'session.closed'});
        expect(h.closed, [(reason: 'closed', seconds: null)]);
      });
    });
  });

  group('connection loss', () {
    for (final state in [
      LiveRtcConnectionState.failed,
      LiveRtcConnectionState.disconnected,
    ]) {
      test('$state finishes with connection_lost', () {
        fakeAsync((async) {
          final h = _Harness();
          h.start(async);
          h.transport.emitState(state);
          expect(h.closed, [(reason: 'connection_lost', seconds: null)]);
          expect(h.transport.disposeCalls, 1);
        });
      });
    }

    test('data channel close finishes with connection_lost', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitChannelClose();
        expect(h.closed, [(reason: 'connection_lost', seconds: null)]);
      });
    });
  });

  group('close', () {
    test('sends session.close and finishes after the 15 s timeout', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        unawaited(h.session.close());
        async.flushMicrotasks();
        expect(h.transport.sentTypes, ['session.close']);
        async.elapse(const Duration(seconds: 14, milliseconds: 900));
        expect(h.closed, isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(h.closed, [(reason: 'close_requested', seconds: null)]);
        expect(h.transport.disposeCalls, 1);
      });
    });

    test('session.closed before the timeout wins and cancels it', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        unawaited(h.session.close());
        async.flushMicrotasks();
        h.transport.emitEvent({
          'type': 'session.closed',
          'reason': 'close_requested',
          'usage': {'seconds': 3},
        });
        async.elapse(const Duration(seconds: 30));
        expect(h.closed, [(reason: 'close_requested', seconds: 3)]);
      });
    });

    test('closes the channel unsent: finishes immediately', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.channelOpen = false;
        unawaited(h.session.close());
        async.flushMicrotasks();
        expect(h.closed, [(reason: 'close_requested', seconds: null)]);
        expect(h.transport.disposeCalls, 1);
      });
    });

    test('finishes exactly once however many signals arrive', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        unawaited(h.session.close());
        async.flushMicrotasks();
        h.transport.emitEvent({'type': 'session.closed'});
        h.transport.emitChannelClose();
        h.transport.emitState(LiveRtcConnectionState.failed);
        unawaited(h.session.close());
        async.elapse(const Duration(seconds: 60));
        expect(h.closed, hasLength(1));
        expect(h.transport.disposeCalls, 1);
      });
    });

    test('events after finish are ignored', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.emitEvent({'type': 'session.closed'});
        h.transport.emitEvent({
          'type': 'session.delegation.created',
          'delegation': {'id': 'late'},
        });
        expect(h.delegations, isEmpty);
        expect(h.session.think('late', 'x'), isFalse);
      });
    });

    test('close during the POST: late answer is not applied', () {
      fakeAsync((async) {
        final h = _Harness();
        final gate = Completer<VoiceLiveSessionAnswer>();
        h.api.createGate = gate;
        h.start(async);
        // Before the answer is applied the data channel is not open yet.
        h.transport.channelOpen = false;
        unawaited(h.session.close());
        async.flushMicrotasks();
        expect(h.transport.disposeCalls, 1);
        gate.complete(h.api.answer);
        async.flushMicrotasks();
        expect(h.log, isNot(contains('setRemoteAnswer')));
        expect(h.transport.disposeCalls, 1);
      });
    });
  });

  group('client events', () {
    test('thinking, commentary, instructions carry ids and delegation', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        expect(
          h.session.think('del_1', 'Hermes is working: web. Not done yet.'),
          isTrue,
        );
        expect(h.session.commentary('del_1', 'Hola.'), isTrue);
        expect(h.session.instruct('Respond now.'), isTrue);
        final think = h.transport.sent[0];
        final say = h.transport.sent[1];
        final instr = h.transport.sent[2];
        expect(think['type'], 'session.thinking.append');
        expect(think['delegation_id'], 'del_1');
        expect(think['content'], 'Hermes is working: web. Not done yet.');
        expect((think['event_id'] as String).startsWith('think_'), isTrue);
        expect(say['type'], 'session.commentary.append');
        expect(say['delegation_id'], 'del_1');
        expect((say['event_id'] as String).startsWith('say_'), isTrue);
        expect(instr['type'], 'session.instructions.append');
        expect(instr['delegation_id'], isNull);
        expect((instr['event_id'] as String).startsWith('instr_'), isTrue);
        expect(
          h.transport.sent.map((e) => e['event_id']).toSet(),
          hasLength(3),
        );
      });
    });

    test('thinking and instructions are clamped to 1400 characters', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.session.think(null, 'a' * 3000);
        h.session.instruct('b' * 3000);
        expect((h.transport.sent[0]['content'] as String).length, 1400);
        expect((h.transport.sent[1]['content'] as String).length, 1400);
      });
    });

    test('nothing is sent while the channel is not open', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.channelOpen = false;
        expect(h.session.think('d', 'x'), isFalse);
        expect(h.session.commentary('d', 'x'), isFalse);
        expect(h.session.instruct('x'), isFalse);
        expect(h.transport.sent, isEmpty);
      });
    });

    test('mute sends the event and disables the track; unmute reverses', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.session.setMuted(true);
        expect(h.transport.micEnabled, isFalse);
        expect(h.transport.sentTypes, ['session.input_audio.mute']);
        h.session.setMuted(false);
        expect(h.transport.micEnabled, isTrue);
        expect(h.transport.sentTypes.last, 'session.input_audio.unmute');
        expect(
          (h.transport.sent.first['event_id'] as String).startsWith('mute_'),
          isTrue,
        );
      });
    });

    test('mute disables the local track even if the channel is closed', () {
      fakeAsync((async) {
        final h = _Harness();
        h.start(async);
        h.transport.channelOpen = false;
        h.session.setMuted(true);
        expect(h.transport.micEnabled, isFalse);
        expect(h.transport.sent, isEmpty);
      });
    });
  });
}
