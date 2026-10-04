import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/conversation/gpt_live_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/live/live_audio_environment.dart';
import 'package:hermes_android/core/services/voice/live/live_rtc_transport.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_api.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/recording_desktop_gateway.dart';
import 'support/voice_live_fakes.dart';

SavedConnection _connection() => SavedConnection(
  id: 'live-conn',
  label: 'Live test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

class _Rig {
  _Rig() {
    chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: _connection(),
      sessionId: 'session-live',
      sessionTitle: 'Live',
      notifications: null,
      onTerminal: () {},
      desktopGateway: desktop,
      initialStoredSessionId: 'session-live',
      // The empty terminal of a silent turn waits for the stored transcript.
      storedMessageLoader: (_, _) async => const [],
    )..state = ChatPipelineState.idle;
    controller = GptLiveVoiceConversationController(
      apiFactory: (_) {
        if (apiFails) throw StateError('no transport');
        return api;
      },
      transportFactory: () {
        if (transportFails) throw StateError('no webrtc');
        transportsCreated++;
        // A transport is never reused after dispose: the first session gets
        // [transport], every later one a fresh fake.
        final next = transportsCreated == 1
            ? transport
            : FakeLiveRtcTransport(log: log);
        transports.add(next);
        return next;
      },
      audioEvents: () => audio.stream,
      languageCode: () => 'en',
    );
  }

  final desktop = RecordingDesktopGateway();
  final audio = StreamController<LiveAudioEvent>.broadcast(sync: true);
  final log = <String>[];
  late final transport = FakeLiveRtcTransport(log: log);
  late final api = FakeVoiceLiveApi(log: log);
  late final ActiveChat chat;
  late final GptLiveVoiceConversationController controller;
  int transportsCreated = 0;
  final transports = <FakeLiveRtcTransport>[];
  bool apiFails = false;
  bool transportFails = false;
  int notifications = 0;

  Future<void> enter(FakeAsync async, {String profile = 'ops'}) async {
    controller.addListener(() => notifications++);
    unawaited(
      controller.enter(chat: chat, model: 'hermes-agent', profile: profile),
    );
    async.flushMicrotasks();
  }

  /// The voice model answers between two utterances, as it does live; without
  /// it consecutive user deltas are one utterance.
  void voiceReplies() => transport.emitEvent({
    'type': 'session.output_transcript.delta',
    'delta': 'Claro.',
  });

  void delegate(String id, {String said = 'abre el calendario'}) {
    transport.emitEvent({
      'type': 'session.input_transcript.delta',
      'delta': said,
      'start_ms': 0,
      'end_ms': 10,
    });
    transport.emitEvent({
      'type': 'session.delegation.created',
      'delegation': {'id': id},
    });
  }

  List<Map<String, dynamic>> get appended => transport.sent
      .where(
        (e) =>
            e['type'] == 'session.commentary.append' ||
            e['type'] == 'session.thinking.append',
      )
      .toList(growable: false);

  Future<void> dispose() async {
    controller.dispose();
    chat.dispose();
    await desktop.close();
    await audio.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test('enter opens exactly one session with profile and chat history', () {
    fakeAsync((async) {
      final rig = _Rig();
      // Seed one finished typed turn so the history has two messages.
      unawaited(
        rig.chat.send(
          fullText: 'hola',
          model: 'hermes-agent',
          history: const [],
        ),
      );
      async.flushMicrotasks();
      rig.desktop.emit('message.start');
      rig.desktop.emit('message.complete', {'text': 'dime'});
      async.flushMicrotasks();
      rig.enter(async);
      expect(rig.transportsCreated, 1);
      expect(rig.api.createCalls, hasLength(1));
      final call = rig.api.createCalls.single;
      expect(call.profile, 'ops');
      expect(call.history.map((m) => m['role']), ['user', 'assistant']);
      expect(rig.controller.active, isTrue);
      expect(rig.controller.phase, VoicePhase.listening);
      expect(rig.controller.ownsChat(rig.chat), isTrue);
      expect(rig.controller.whisper, isFalse);
    });
  });

  group('delegation', () {
    test('one delegation → one submit with surface and voice_context', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.delegate('del_1');
        async.flushMicrotasks();
        expect(rig.desktop.submits, [
          {
            'call': 'submit',
            'text': 'abre el calendario',
            'surface': 'voice-live',
            'voice_context': 'User: abre el calendario',
          },
        ]);
        // The user bubble shows only what the user said.
        final users = rig.chat.messages.where((m) => m['role'] == 'user');
        expect(users.map((m) => m['content']), ['abre el calendario']);
      });
    });

    test('a duplicate delivery of the same id still submits once', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.delegate('del_1');
        async.flushMicrotasks();
        rig.transport.emitEvent({
          'type': 'session.delegation.created',
          'delegation': {'id': 'del_1'},
        });
        async.flushMicrotasks();
        expect(rig.desktop.submits, hasLength(1));
      });
    });

    test('a stop phrase ends the conversation without a turn', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.delegate('del_stop', said: 'stop talking');
        async.flushMicrotasks();
        expect(rig.desktop.submits, isEmpty);
        expect(rig.controller.active, isFalse);
      });
    });

    test('busy chat is interrupted before the new delegation is submitted', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.delegate('del_1');
        async.flushMicrotasks();
        rig.desktop.emit('message.start');
        async.flushMicrotasks();
        expect(rig.chat.isStreaming, isTrue);
        rig.voiceReplies();
        rig.delegate('del_2', said: 'y ahora lo de mañana');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        final order = rig.desktop.calls
            .map(
              (c) => c['call'] == 'submit' ? 'submit:${c['text']}' : c['call'],
            )
            .toList();
        expect(order, [
          'submit:abre el calendario',
          'interrupt',
          'submit:y ahora lo de mañana',
        ]);
      });
    });
  });

  group('feeding Hermes back to the voice', () {
    test('one thinking append per distinct tool name', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.delegate('del_1');
        async.flushMicrotasks();
        rig.desktop.emit('message.start');
        rig.desktop.emit('tool.start', {'name': 'web_search', 'tool_id': 'a'});
        rig.desktop.emit('tool.progress', {
          'name': 'web_search',
          'tool_id': 'a',
        });
        rig.desktop.emit('tool.progress', {
          'name': 'web_search',
          'tool_id': 'a',
        });
        rig.desktop.emit('tool.complete', {
          'name': 'web_search',
          'tool_id': 'a',
        });
        rig.desktop.emit('tool.start', {'name': 'read_file', 'tool_id': 'b'});
        async.flushMicrotasks();
        final thinking = rig.transport.sent
            .where((e) => e['type'] == 'session.thinking.append')
            .toList();
        expect(thinking.map((e) => e['content']), [
          'Hermes is working: web_search. Not done yet.',
          'Hermes is working: read_file. Not done yet.',
        ]);
        expect(thinking.every((e) => e['delegation_id'] == 'del_1'), isTrue);
        expect(rig.controller.phase, VoicePhase.toolCall);
        expect(rig.controller.activeTool, 'read_file');
      });
    });

    test('streams completed sentences, then the tail on settle', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.delegate('del_1');
        async.flushMicrotasks();
        rig.desktop.emit('message.start');
        rig.desktop.emit('message.delta', {'text': 'Primera frase. Segun'});
        async.flushMicrotasks();
        var say = rig.transport.sent
            .where((e) => e['type'] == 'session.commentary.append')
            .toList();
        expect(say.map((e) => e['content']), ['Primera frase.']);
        rig.desktop.emit('message.delta', {'text': 'da frase. Y la cola'});
        // The chat publishes streamed text on a short flush timer.
        async.elapse(const Duration(milliseconds: 200));
        say = rig.transport.sent
            .where((e) => e['type'] == 'session.commentary.append')
            .toList();
        expect(say.map((e) => e['content']), [
          'Primera frase.',
          'Segunda frase.',
        ]);
        rig.desktop.emit('message.complete', {
          'text': 'Primera frase. Segunda frase. Y la cola',
        });
        async.elapse(const Duration(milliseconds: 200));
        say = rig.transport.sent
            .where((e) => e['type'] == 'session.commentary.append')
            .toList();
        expect(say.map((e) => e['content']), [
          'Primera frase.',
          'Segunda frase.',
          'Y la cola',
        ]);
        expect(say.every((e) => e['delegation_id'] == 'del_1'), isTrue);
        // Delegation cleared: nothing more is appended for it.
        final before = rig.transport.sent.length;
        rig.desktop.emit('tool.start', {'name': 'late_tool'});
        async.flushMicrotasks();
        expect(rig.transport.sent.length, before);
      });
    });

    test(
      'reply chunks of an old delegation are not appended after a new one',
      () {
        fakeAsync((async) {
          final rig = _Rig();
          rig.enter(async);
          rig.delegate('del_old');
          async.flushMicrotasks();
          rig.desktop.emit('message.start');
          rig.desktop.emit('message.delta', {'text': 'Vieja uno. Vieja dos. '});
          async.flushMicrotasks();
          rig.voiceReplies();
          rig.delegate('del_new', said: 'otra cosa');
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 1));
          rig.desktop.emit('message.start');
          rig.desktop.emit('message.delta', {'text': 'Nueva uno. '});
          async.flushMicrotasks();
          final say = rig.transport.sent
              .where((e) => e['type'] == 'session.commentary.append')
              .toList();
          expect(
            say
                .where((e) => e['delegation_id'] == 'del_old')
                .map((e) => e['content']),
            ['Vieja uno.', 'Vieja dos.'],
            reason: 'only what was appended before the new delegation',
          );
          expect(
            say
                .where((e) => e['delegation_id'] == 'del_new')
                .map((e) => e['content']),
            ['Nueva uno.'],
          );
        });
      },
    );

    test(
      'no reply, idle chat, after the 15 s grace: finished without result',
      () {
        fakeAsync((async) {
          final rig = _Rig();
          rig.desktop.completeInterrupts = false;
          rig.enter(async);
          rig.delegate('del_1');
          async.flushMicrotasks();
          // The gateway accepted the prompt but the turn never started.
          rig.chat.state = ChatPipelineState.idle;
          async.elapse(const Duration(seconds: 14, milliseconds: 900));
          expect(
            rig.transport.sent.where(
              (e) => e['type'] == 'session.thinking.append',
            ),
            isEmpty,
          );
          async.elapse(const Duration(milliseconds: 200));
          final thinking = rig.transport.sent
              .where((e) => e['type'] == 'session.thinking.append')
              .toList();
          expect(thinking.map((e) => e['content']), [
            'Hermes finished that request without a spoken result.',
          ]);
        });
      },
    );

    test('a turn that ended silently is closed out by the 15 s grace', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.delegate('del_1');
        async.flushMicrotasks();
        rig.desktop.emit('message.start');
        rig.desktop.emit('message.complete', {'text': ''});
        async.elapse(const Duration(seconds: 14));
        expect(
          rig.transport.sent.where(
            (e) => e['type'] == 'session.thinking.append',
          ),
          isEmpty,
        );
        async.elapse(const Duration(seconds: 2));
        expect(
          rig.transport.sent
              .where((e) => e['type'] == 'session.thinking.append')
              .map((e) => e['content']),
          ['Hermes finished that request without a spoken result.'],
        );
      });
    });
  });

  group('submit failure', () {
    test('speaks an apology for the delegation and clears it', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.chat.dispose();
        rig.delegate('del_1');
        async.flushMicrotasks();
        final say = rig.transport.sent
            .where((e) => e['type'] == 'session.commentary.append')
            .toList();
        expect(
          say.single['content'],
          'Sorry, I could not reach Hermes for that request.',
        );
        expect(say.single['delegation_id'], 'del_1');
        expect(rig.controller.phase, VoicePhase.listening);
      });
    });
  });

  group('controls', () {
    test('orb tap and stopAndTalk nudge the voice model to answer', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.controller.onOrbTap();
        rig.controller.stopAndTalk();
        final instr = rig.transport.sent
            .where((e) => e['type'] == 'session.instructions.append')
            .toList();
        expect(instr, hasLength(2));
        expect(
          instr.first['content'],
          'The user has finished speaking. Respond now to what they said.',
        );
      });
    });

    test('pause mutes and play unmutes', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.controller.pauseConversation();
        expect(rig.controller.userPaused, isTrue);
        expect(rig.transport.micEnabled, isFalse);
        expect(rig.transport.sentTypes, contains('session.input_audio.mute'));
        rig.controller.playConversation();
        expect(rig.controller.userPaused, isFalse);
        expect(rig.transport.micEnabled, isTrue);
      });
    });

    test(
      'cancelBackend interrupts the Hermes turn and clears the delegation',
      () {
        fakeAsync((async) {
          final rig = _Rig();
          rig.enter(async);
          rig.delegate('del_1');
          async.flushMicrotasks();
          rig.desktop.emit('message.start');
          async.flushMicrotasks();
          rig.controller.cancelBackend();
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 1));
          expect(
            rig.desktop.calls.map((c) => c['call']),
            contains('interrupt'),
          );
          final before = rig.transport.sent.length;
          rig.desktop.emit('message.delta', {'text': 'Tarde. Muy tarde. '});
          async.flushMicrotasks();
          expect(
            rig.transport.sent
                .skip(before)
                .where((e) => e['type'] == 'session.commentary.append'),
            isEmpty,
          );
        });
      },
    );

    test('user transcript follows the last user utterance', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.transport.emitEvent({
          'type': 'session.input_transcript.delta',
          'delta': 'hola ',
        });
        rig.transport.emitEvent({
          'type': 'session.input_transcript.delta',
          'delta': 'mundo',
        });
        expect(rig.controller.partialTranscript, 'hola mundo');
        rig.transport.emitEvent({
          'type': 'session.output_transcript.delta',
          'delta': 'ok',
        });
        expect(rig.controller.userTranscript, 'hola mundo');
      });
    });

    test(
      'a bare stop utterance ends the conversation after 1.5 s of quiet',
      () {
        fakeAsync((async) {
          final rig = _Rig();
          rig.enter(async);
          rig.transport.emitEvent({
            'type': 'session.input_transcript.delta',
            'delta': 'stop',
          });
          async.elapse(const Duration(milliseconds: 1400));
          expect(rig.controller.active, isTrue);
          async.elapse(const Duration(milliseconds: 200));
          expect(rig.controller.active, isFalse);
        });
      },
    );

    test('speech after a stop-like word restarts the quiet window', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.transport.emitEvent({
          'type': 'session.input_transcript.delta',
          'delta': 'stop',
        });
        async.elapse(const Duration(milliseconds: 1000));
        rig.transport.emitEvent({
          'type': 'session.input_transcript.delta',
          'delta': ' and explain why the sky is blue',
        });
        async.elapse(const Duration(seconds: 3));
        expect(rig.controller.active, isTrue);
      });
    });
  });

  group('start races and failures', () {
    test(
      'exit() while start awaits the POST: the late answer opens nothing',
      () {
        fakeAsync((async) {
          final rig = _Rig();
          final gate = Completer<VoiceLiveSessionAnswer>();
          rig.api.createGate = gate;
          rig.enter(async);
          expect(rig.controller.phase, VoicePhase.thinking);
          // Before the answer is applied the data channel is not open yet.
          rig.transport.channelOpen = false;
          unawaited(rig.controller.exit());
          async.flushMicrotasks();
          expect(rig.controller.active, isFalse);
          gate.complete(rig.api.answer);
          async.flushMicrotasks();
          expect(rig.transportsCreated, 1);
          expect(rig.log, isNot(contains('setRemoteAnswer')));
          expect(rig.transport.disposeCalls, 1);
          expect(rig.controller.active, isFalse);
        });
      },
    );

    test('quick enter, exit, enter opens a second session only after exit', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        unawaited(rig.controller.exit());
        async.flushMicrotasks();
        expect(rig.controller.active, isFalse);
        expect(rig.transportsCreated, 1);
        // Entering again opens exactly one fresh session.
        unawaited(rig.controller.enter(chat: rig.chat, model: 'hermes-agent'));
        async.flushMicrotasks();
        expect(rig.controller.active, isTrue);
        expect(rig.transportsCreated, 2);
        expect(rig.api.createCalls, hasLength(2));
        // One answer per session, each on its own transport.
        expect(rig.log.where((e) => e == 'setRemoteAnswer'), hasLength(2));
        expect(rig.transports, hasLength(2));
        expect(identical(rig.transports[0], rig.transports[1]), isFalse);
        expect(rig.transports[0].remoteAnswer, isNotNull);
        expect(rig.transports[1].remoteAnswer, isNotNull);
      });
    });

    test('a server failure shows the could-not-start note and a retry', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.api.createError = const VoiceLiveSessionException(
          statusCode: 503,
          detail: 'no OpenAI API key',
        );
        rig.enter(async);
        expect(rig.controller.phase, VoicePhase.idle);
        expect(
          rig.controller.note,
          'Could not start GPT-Live: no OpenAI API key',
        );
        expect(rig.transport.disposeCalls, 1);
        // Retry opens a fresh session, once.
        rig.api.createError = null;
        rig.transport.channelOpen = true;
        expect(rig.transportsCreated, 1);
        rig.controller.retry();
        async.flushMicrotasks();
        expect(rig.transportsCreated, 2);
        expect(rig.api.createCalls, hasLength(2));
        expect(rig.log.where((e) => e == 'setRemoteAnswer'), hasLength(1));
        // The retry runs on a new transport; the failed one stays disposed.
        expect(rig.transports, hasLength(2));
        expect(identical(rig.transports[0], rig.transports[1]), isFalse);
        expect(rig.transports[0].remoteAnswer, isNull);
        expect(rig.transports[1].remoteAnswer, isNotNull);
        expect(rig.transports[0].disposeCalls, 1);
        expect(rig.transports[1].disposeCalls, 0);
        expect(rig.controller.note, isNull);
        // A second retry while the session is live opens nothing.
        rig.controller.retry();
        async.flushMicrotasks();
        expect(rig.transportsCreated, 2);
        expect(rig.api.createCalls, hasLength(2));
      });
    });

    test(
      'an api client that cannot be built shows the could-not-start note',
      () {
        fakeAsync((async) {
          final rig = _Rig();
          rig.apiFails = true;
          rig.enter(async);
          expect(rig.controller.note, 'Could not start GPT-Live');
          expect(rig.controller.phase, VoicePhase.idle);
          expect(rig.transportsCreated, 0);
        });
      },
    );

    test('a transport that cannot be built releases the api and can retry', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.transportFails = true;
        rig.enter(async);
        expect(rig.controller.note, 'Could not start GPT-Live');
        expect(rig.controller.phase, VoicePhase.idle);
        expect(rig.api.closeCalls, 1, reason: 'the api client is released');
        expect(rig.api.createCalls, isEmpty);
        // The start state is cleared: a retry starts a normal session.
        rig.transportFails = false;
        rig.controller.retry();
        async.flushMicrotasks();
        expect(rig.transportsCreated, 1);
        expect(rig.api.createCalls, hasLength(1));
        expect(rig.controller.note, isNull);
      });
    });

    test('a denied microphone reports the existing STT permission check', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.transport.openMicrophoneError =
            const LiveMicrophoneDeniedException();
        final checks = <SttCheck>[];
        rig.controller.unavailable.listen(checks.add);
        rig.enter(async);
        expect(checks.map((c) => c.status), [SttStatus.needsMicPermission]);
        expect(rig.api.createCalls, isEmpty);
        expect(rig.controller.phase, VoicePhase.idle);
      });
    });

    test('server close surfaces one notice and stops the session', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.transport.emitEvent({
          'type': 'session.closed',
          'reason': 'idle_timeout',
          'usage': {'seconds': 61},
        });
        expect(rig.controller.phase, VoicePhase.idle);
        expect(
          rig.controller.note,
          'Live voice session ended: idle_timeout (61s)',
        );
        expect(rig.transport.disposeCalls, 1);
        expect(rig.chat.isStreaming, isFalse);
      });
    });

    test('connection lost uses the localized reason', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.transport.emitState(LiveRtcConnectionState.disconnected);
        expect(
          rig.controller.note,
          'Live voice session ended: connection lost',
        );
      });
    });
  });

  group('teardown', () {
    test('exit closes the session once, with session.close then dispose', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        unawaited(rig.controller.exit());
        async.flushMicrotasks();
        expect(rig.transport.sentTypes, ['session.close']);
        async.elapse(const Duration(seconds: 15));
        expect(rig.transport.disposeCalls, 1);
        expect(rig.transport.micEnabled, isFalse);
        expect(rig.controller.active, isFalse);
        expect(rig.transportsCreated, 1);
      });
    });

    test('events arriving after exit are ignored', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        unawaited(rig.controller.exit());
        async.flushMicrotasks();
        // The vendor close is pending: the channel still delivers.
        rig.delegate('late');
        async.flushMicrotasks();
        expect(rig.desktop.submits, isEmpty);
        expect(rig.controller.activeTool, isNull);
      });
    });

    test('no notifyListeners after dispose', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.controller.dispose();
        rig.delegate('late');
        rig.transport.emitEvent({'type': 'session.closed'});
        rig.desktop.emit('message.delta', {'text': 'x. '});
        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        expect(rig.notifications, greaterThan(0));
      });
    });

    for (final reason in LiveSessionEnd.values) {
      test('endSession(${reason.name}) tears down and does not reconnect', () {
        fakeAsync((async) {
          final rig = _Rig();
          rig.enter(async);
          unawaited(rig.controller.endSession(reason));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 15));
          expect(rig.transport.disposeCalls, 1);
          expect(rig.transport.micOpen, isFalse);
          expect(rig.controller.phase, VoicePhase.idle);
          expect(
            rig.controller.active,
            isTrue,
            reason: 'the stage stays to explain what happened',
          );
          expect(rig.controller.note, startsWith('Live voice session ended'));
          async.elapse(const Duration(minutes: 5));
          expect(rig.transportsCreated, 1);
          expect(rig.api.createCalls, hasLength(1));
        });
      });
    }

    for (final event in LiveAudioEvent.values) {
      test('${event.name} tears the session down', () {
        fakeAsync((async) {
          final rig = _Rig();
          rig.enter(async);
          rig.audio.add(event);
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 15));
          expect(rig.transport.disposeCalls, 1);
          expect(rig.transport.micOpen, isFalse);
          expect(
            rig.controller.note,
            'Live voice session ended: audio was interrupted',
          );
          async.elapse(const Duration(minutes: 5));
          expect(rig.transportsCreated, 1);
        });
      });
    }

    test('audio events outside a session do nothing', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.audio.add(LiveAudioEvent.routeChanged);
        async.flushMicrotasks();
        expect(rig.transportsCreated, 0);
      });
    });

    test('retry after a teardown opens one fresh session', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.enter(async);
        rig.transport.emitEvent({'type': 'session.closed'});
        expect(rig.controller.phase, VoicePhase.idle);
        // A fresh transport is needed for the second session.
        rig.controller.retry();
        async.flushMicrotasks();
        expect(rig.transportsCreated, 2);
        expect(rig.api.createCalls, hasLength(2));
      });
    });
  });
}
