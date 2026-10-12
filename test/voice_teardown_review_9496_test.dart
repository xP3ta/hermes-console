import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hermes_android/core/services/voice/live/flutter_webrtc_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/conversation/gpt_live_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/conversation/voice_conversation_coordinator.dart';
import 'package:hermes_android/core/services/voice/live/voice_chat_mode_store.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_api.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/services/voice/live/live_rtc_transport.dart';

import 'support/fake_voice_engines.dart';
import 'support/in_memory_compression_restore_storage.dart';
import 'support/recording_desktop_gateway.dart';
import 'support/voice_live_fakes.dart';

class _Channel implements RTCDataChannel {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Peer implements RTCPeerConnection {
  int attempts = 0;
  bool fail = true;
  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit init,
  ) async => _Channel();
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {
    attempts++;
    if (fail) throw StateError('native disposal failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SlowPeer extends _Peer {
  final channelGate = Completer<RTCDataChannel>();
  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit init,
  ) => channelGate.future;
}

class _PendingDispose extends FakeLiveRtcTransport {
  final gate = Completer<void>();
  int attempts = 0;
  bool fail = false;
  @override
  Future<void> dispose() async {
    attempts++;
    await gate.future;
    if (fail) throw StateError('disposal failed');
    await super.dispose();
  }
}

class _Rig {
  _Rig() {
    chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'review',
        label: 'Review',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'test',
      ),
      sessionId: 'review-session',
      sessionTitle: 'Review',
      notifications: null,
      onTerminal: () {},
      desktopGateway: gateway,
      initialStoredSessionId: 'review-session',
      storedMessageLoader: (_, _) async => const [],
    )..state = ChatPipelineState.idle;
    live = GptLiveVoiceConversationController(
      apiFactory: (_) => api,
      transportFactory: () {
        final next = transports.isEmpty ? first : FakeLiveRtcTransport();
        transports.add(next);
        return next;
      },
      audioEvents: () => const Stream.empty(),
      languageCode: () => 'en',
    );
    coordinator = VoiceConversationCoordinator(
      chained: chained,
      liveFactory: () => live,
      modes: modes,
      apiFactory: (_) => api,
      languageCode: () => 'en',
    );
    enabled = true;
  }
  final modes = VoiceChatModeStore.memory();

  /// Whether the server's profile is set to GPT-Live and can start it.
  set enabled(bool live) {
    final status = VoiceLiveStatus(
      mode: live ? VoiceLiveMode.gptLive : VoiceLiveMode.chained,
      available: true,
    );
    api.status = status;
    modes.remember(VoiceChatModeStore.identity('review', ''), status);
  }

  final chained = FakeVoiceEngine('chained');
  final gateway = RecordingDesktopGateway();
  final first = _PendingDispose();
  final api = FakeVoiceLiveApi();
  final transports = <FakeLiveRtcTransport>[];
  late final ActiveChat chat;
  late final GptLiveVoiceConversationController live;
  late final VoiceConversationCoordinator coordinator;
  void enter(FakeAsync clock) {
    unawaited(coordinator.enter(chat: chat, model: 'model'));
    clock.flushMicrotasks();
  }

  void dispose(FakeAsync clock) {
    if (!first.gate.isCompleted) first.gate.complete();
    coordinator.dispose();
    chat.dispose();
    unawaited(gateway.close());
    clock.flushMicrotasks();
    clock.elapse(const Duration(seconds: 16));
    clock.flushMicrotasks();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test(
    'late startup result cannot retire or adopt a replacement generation',
    () {
      fakeAsync((clock) {
        final rig = _Rig();
        final answer = Completer<VoiceLiveSessionAnswer>();
        rig.api.createGate = answer;
        rig.enter(clock);
        unawaited(rig.coordinator.suspendForPrivacy());
        clock.flushMicrotasks();
        expect(rig.coordinator.audioLeaseRequired, isTrue);
        rig.first.gate.complete();
        clock.flushMicrotasks();
        rig.api.createGate = null;
        rig.coordinator.onAppResumed(appUnlocked: true);
        rig.coordinator.retry();
        clock.flushMicrotasks();
        expect(rig.transports, hasLength(2));
        expect(rig.coordinator.phase, VoicePhase.listening);
        answer.complete(rig.api.answer);
        clock.flushMicrotasks();
        expect(rig.first.remoteAnswer, isNull);
        expect(rig.transports.last.micOpen, isTrue);
        expect(rig.coordinator.phase, VoicePhase.listening);
        expect(rig.coordinator.audioLeaseRequired, isTrue);
        expect(rig.api.createCalls, hasLength(2));
        rig.dispose(clock);
      });
    },
  );

  test(
    'privacy retirement preserves accepted chat work and scrubs private voice',
    () {
      fakeAsync((clock) {
        final rig = _Rig();
        rig.enter(clock);
        rig.first.emitEvent({
          'type': 'session.input_transcript.delta',
          'delta': 'private review marker',
        });
        rig.first.emitEvent({
          'type': 'session.delegation.created',
          'delegation': {'id': 'delegation'},
        });
        clock.flushMicrotasks();
        rig.gateway.emit('message.start');
        clock.flushMicrotasks();
        expect(rig.gateway.submits, hasLength(1));
        expect(rig.chat.isStreaming, isTrue);
        unawaited(rig.coordinator.suspendForPrivacy());
        clock.flushMicrotasks();
        expect(rig.coordinator.partialTranscript, isEmpty);
        expect(rig.coordinator.userTranscript, isEmpty);
        expect(rig.coordinator.assistantResponse, isEmpty);
        expect(rig.coordinator.audioLeaseRequired, isTrue);
        expect(
          rig.gateway.calls.where((c) => c['call'] == 'interrupt'),
          isEmpty,
        );
        expect(rig.chat.isStreaming, isTrue);
        rig.first.gate.complete();
        clock.flushMicrotasks();
        rig.coordinator.onAppResumed(appUnlocked: true);
        clock.flushMicrotasks();
        expect(rig.gateway.submits, hasLength(1));
        expect(rig.transports, hasLength(1));
        rig.dispose(clock);
      });
    },
  );

  test('failed teardown cannot hand audio to the chained sibling on entry', () {
    fakeAsync((clock) {
      final rig = _Rig();
      rig.enter(clock);
      rig.first.fail = true;
      rig.first.emitEvent({'type': 'session.closed'});
      rig.first.gate.complete();
      clock.flushMicrotasks();
      final other = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: rig.chat.connection,
        sessionId: 'other',
        sessionTitle: 'Other',
        notifications: null,
        onTerminal: () {},
        desktopGateway: RecordingDesktopGateway(),
        initialStoredSessionId: 'other',
        storedMessageLoader: (_, _) async => const [],
      )..state = ChatPipelineState.idle;
      rig.enabled = false;
      unawaited(rig.coordinator.enter(chat: other, model: 'model'));
      clock.flushMicrotasks();
      expect(rig.chained.active, isFalse);
      expect(rig.coordinator.audioLeaseRequired, isTrue);
      rig.first.fail = false;
      rig.coordinator.retry();
      clock.flushMicrotasks();
      unawaited(rig.coordinator.enter(chat: other, model: 'model'));
      clock.flushMicrotasks();
      expect(rig.chained.active, isTrue);
      other.dispose();
      rig.dispose(clock);
    });
  });

  test(
    'native channel acquisition remains owned until late cleanup settles',
    () {
      fakeAsync((clock) {
        final peer = _SlowPeer()..fail = false;
        final transport = FlutterWebRtcTransport(
          peerFactory: (_) async => peer,
        );
        unawaited(transport.createEventsChannel('events'));
        clock.flushMicrotasks();
        bool disposed = false;
        unawaited(transport.dispose().then((_) => disposed = true));
        clock.flushMicrotasks();
        expect(disposed, isFalse);
        peer.channelGate.complete(_Channel());
        clock.flushMicrotasks();
        expect(disposed, isTrue);
        expect(transport.channelOpen, isFalse);
      });
    },
  );

  test(
    'native disposal failure is surfaced and cleanup can be retried',
    () async {
      final peer = _Peer();
      final transport = FlutterWebRtcTransport(peerFactory: (_) async => peer);
      await transport.createEventsChannel('events');
      await expectLater(transport.dispose(), throwsStateError);
      expect(peer.attempts, 1);
      peer.fail = false;
      await transport.dispose();
      expect(peer.attempts, 2);
    },
  );

  test(
    'cached real live engine unlocks after privacy exit for explicit entry',
    () {
      fakeAsync((clock) {
        final rig = _Rig();
        rig.enter(clock);
        expect(rig.api.createCalls, hasLength(1));
        unawaited(rig.coordinator.suspendForPrivacy());
        clock.flushMicrotasks();
        rig.first.gate.complete();
        clock.flushMicrotasks();
        unawaited(rig.coordinator.exit());
        clock.flushMicrotasks();
        rig.coordinator.onAppResumed(appUnlocked: false);
        rig.enter(clock);
        expect(rig.api.createCalls, hasLength(1));
        rig.coordinator.onAppResumed(appUnlocked: true);
        clock.flushMicrotasks();
        expect(
          rig.api.createCalls,
          hasLength(1),
          reason: 'unlock never starts audio',
        );
        rig.enter(clock);
        expect(rig.api.createCalls, hasLength(2));
        rig.dispose(clock);
      });
    },
  );

  for (final route in [
    'connection',
    'channel',
    'start',
    'permission',
    'api',
    'privacy',
    'background',
    'audio',
    'route',
    'profile',
    'exit',
    'timeout',
    'dispose',
  ]) {
    test('$route retains the physical lease until disposal finishes', () {
      fakeAsync((clock) {
        final rig = _Rig();
        if (route == 'start') {
          rig.first.openMicrophoneError = StateError('start');
        }
        if (route == 'permission') {
          rig.first.openMicrophoneError = const LiveMicrophoneDeniedException();
        }
        if (route == 'api') rig.api.createError = StateError('create');
        rig.enter(clock);
        switch (route) {
          case 'connection':
            rig.first.emitState(LiveRtcConnectionState.disconnected);
          case 'channel':
            rig.first.emitChannelClose();
          case 'privacy':
            unawaited(rig.coordinator.suspendForPrivacy());
          case 'background':
            unawaited(rig.coordinator.onAppBackgrounded());
          case 'audio':
            unawaited(rig.live.endSession(LiveSessionEnd.audioInterrupted));
          case 'route':
            unawaited(rig.live.endSession(LiveSessionEnd.routeLeave));
          case 'profile':
            unawaited(rig.live.endSession(LiveSessionEnd.profileSwitch));
          case 'exit':
            unawaited(rig.coordinator.exit());
            rig.first.emitEvent({'type': 'session.closed'});
          case 'timeout':
            unawaited(rig.coordinator.exit());
            clock.elapse(const Duration(seconds: 15));
          case 'dispose':
            rig.coordinator.dispose();
            rig.first.emitEvent({'type': 'session.closed'});
          case 'start':
          case 'permission':
          case 'api':
            break;
        }
        clock.flushMicrotasks();
        expect(rig.live.audioLeaseRequired, isTrue);
        expect(rig.coordinator.audioLeaseRequired, isTrue);
        expect(rig.first.attempts, 1);
        rig.live.retry();
        rig.enter(clock);
        expect(rig.transports, hasLength(1));
        rig.first.gate.complete();
        clock.flushMicrotasks();
        expect(rig.live.audioLeaseRequired, isFalse);
        expect(rig.first.attempts, 1);
        expect(rig.transports, hasLength(1));
        if (route != 'dispose') {
          rig.coordinator.onAppResumed(appUnlocked: true);
          if (route == 'api') rig.api.createError = null;
          if (route == 'exit' || route == 'timeout') {
            rig.enter(clock);
          } else {
            rig.coordinator.retry();
            clock.flushMicrotasks();
          }
          expect(rig.transports, hasLength(2));
          expect(
            rig.gateway.calls.where((c) => c['call'] == 'interrupt'),
            isEmpty,
          );
        }
        rig.dispose(clock);
      });
    });
  }

  for (final failureRoute in [
    'closed',
    'start',
    'connection',
    'privacy',
    'exit',
    'dispose',
  ]) {
    test(
      '$failureRoute failed disposal keeps lease until explicit cleanup retry succeeds',
      () {
        fakeAsync((clock) {
          final rig = _Rig();
          if (failureRoute == 'start') {
            rig.first.openMicrophoneError = StateError('start');
          }
          rig.first.fail = true;
          rig.enter(clock);
          switch (failureRoute) {
            case 'closed':
              rig.first.emitEvent({'type': 'session.closed'});
            case 'connection':
              rig.first.emitState(LiveRtcConnectionState.failed);
            case 'privacy':
              unawaited(rig.coordinator.suspendForPrivacy());
            case 'exit':
              unawaited(rig.coordinator.exit());
              rig.first.emitEvent({'type': 'session.closed'});
            case 'dispose':
              rig.coordinator.dispose();
              rig.first.emitEvent({'type': 'session.closed'});
            case 'start':
              break;
          }
          clock.flushMicrotasks();
          rig.first.gate.complete();
          clock.flushMicrotasks();
          expect(rig.live.audioLeaseRequired, isTrue);
          expect(rig.transports, hasLength(1));
          rig.first.fail = false;
          rig.coordinator.retry();
          clock.flushMicrotasks();
          expect(rig.first.attempts, 2);
          expect(rig.live.audioLeaseRequired, isFalse);
          expect(
            rig.transports,
            hasLength(1),
            reason: 'cleanup retry is not session retry',
          );
          rig.coordinator.onAppResumed(appUnlocked: true);
          if (failureRoute == 'exit') {
            rig.enter(clock);
          } else {
            rig.coordinator.retry();
            clock.flushMicrotasks();
          }
          expect(rig.transports, hasLength(failureRoute == 'dispose' ? 1 : 2));
          rig.dispose(clock);
        });
      },
    );
  }

  test(
    'session.closed retains lease and rejects retry until RTC disposal ends',
    () {
      fakeAsync((clock) {
        final rig = _Rig();
        rig.enter(clock);
        rig.first.emitEvent({'type': 'session.closed'});
        clock.flushMicrotasks();
        expect(rig.live.audioLeaseRequired, isTrue);
        expect(rig.coordinator.audioLeaseRequired, isTrue);
        rig.coordinator.retry();
        clock.flushMicrotasks();
        expect(rig.transports, hasLength(1));
        rig.first.gate.complete();
        clock.flushMicrotasks();
        expect(rig.live.audioLeaseRequired, isFalse);
        expect(
          rig.transports,
          hasLength(1),
          reason: 'teardown never auto-retries',
        );
        rig.coordinator.retry();
        clock.flushMicrotasks();
        expect(rig.transports, hasLength(2));
        rig.dispose(clock);
      });
    },
  );
}
