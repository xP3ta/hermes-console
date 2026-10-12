import 'dart:async';
import 'dart:ui' show AppLifecycleState;

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/flavor.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/conversation/gpt_live_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/conversation/voice_conversation_coordinator.dart';
import 'package:hermes_android/core/services/voice/live/voice_chat_mode_store.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_api.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_engines.dart';
import 'support/in_memory_compression_restore_storage.dart';
import 'support/recording_desktop_gateway.dart';
import 'support/voice_live_fakes.dart';

// Owner decision: a GPT-Live conversation keeps running when the screen
// turns off or another app comes in front IF the user turned on "keep going
// with the screen locked", the same opt-in the chained conversation already
// followed. These tests run the real live engine under the real coordinator
// and drive them with the lifecycle steps `main.dart` sends.

const _left = 'Live voice session ended: you left the chat or the app';

class _Rig {
  _Rig() {
    chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'bg',
        label: 'Background',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'test',
      ),
      sessionId: 'bg-session',
      sessionTitle: 'Background',
      notifications: null,
      onTerminal: () {},
      desktopGateway: gateway,
      initialStoredSessionId: 'bg-session',
      storedMessageLoader: (_, _) async => const [],
    )..state = ChatPipelineState.idle;
    live = GptLiveVoiceConversationController(
      apiFactory: (_) => api,
      transportFactory: () {
        final next = FakeLiveRtcTransport();
        transports.add(next);
        return next;
      },
      audioEvents: () => const Stream.empty(),
      languageCode: () => 'en',
      // As wired in `main.dart`.
      continueWhenHidden: () => liveVoiceMayContinueHidden(
        continueWhenLocked: continueWhenLocked,
        microphoneServiceHeld: microphoneServiceHeld,
        viewAttached: state != AppLifecycleState.detached,
      ),
    );
    coordinator = VoiceConversationCoordinator(
      chained: chained,
      liveFactory: () => live,
      modes: modes,
      apiFactory: (_) => api,
      languageCode: () => 'en',
      visibleSession: visible,
      profileWatch: (_) => (changes: profileChanges, current: () => profile),
      appVisible: () =>
          state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive,
    );
    const status = VoiceLiveStatus(
      mode: VoiceLiveMode.gptLive,
      available: true,
    );
    api.status = status;
    modes.remember(VoiceChatModeStore.identity('bg', ''), status);
  }

  final modes = VoiceChatModeStore.memory();
  final chained = FakeVoiceEngine('chained');
  final gateway = RecordingDesktopGateway();
  final api = FakeVoiceLiveApi();
  final transports = <FakeLiveRtcTransport>[];
  final visible = ValueNotifier<String?>('bg-session');
  final profileChanges = ValueNotifier<int>(0);
  String profile = '';
  late final ActiveChat chat;
  late final GptLiveVoiceConversationController live;
  late final VoiceConversationCoordinator coordinator;

  /// The "keep going with the screen locked" voice option.
  bool continueWhenLocked = true;

  /// The voice foreground service (microphone type) is the one running. The
  /// app starts it for [serviceNeeded] while it is in front.
  bool microphoneServiceHeld = true;
  AppLifecycleState state = AppLifecycleState.resumed;

  FakeLiveRtcTransport get mic => transports.last;

  /// The condition `main.dart` starts and keeps the voice service on.
  bool get serviceNeeded => voiceRuntimeNeedsForeground(
    active: coordinator.audioLeaseRequired,
    continueWhenLocked: continueWhenLocked,
  );

  void enter(FakeAsync clock) {
    unawaited(coordinator.enter(chat: chat, model: 'model'));
    clock.flushMicrotasks();
  }

  /// What `HermesAppState.didChangeAppLifecycleState` does with voice.
  void lifecycle(
    AppLifecycleState next,
    FakeAsync clock, {
    bool appLocked = false,
  }) {
    state = next;
    if (next == AppLifecycleState.resumed) {
      if (!appLocked) unawaited(coordinator.resumeFullDuplexCaptureIfNeeded());
      coordinator.onAppResumed(appUnlocked: !appLocked);
    } else {
      unawaited(coordinator.suspendFullDuplexForAppBackground());
      if (next != AppLifecycleState.inactive &&
          coordinator.active &&
          (coordinator.requiresForegroundVisibility || !continueWhenLocked)) {
        unawaited(coordinator.onAppBackgrounded());
      }
    }
    clock.flushMicrotasks();
  }

  void screenOff(FakeAsync clock) {
    for (final step in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      lifecycle(step, clock);
    }
  }

  void screenOn(FakeAsync clock, {bool appLocked = false}) {
    for (final step in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      lifecycle(step, clock, appLocked: appLocked);
    }
  }

  void expectTalking() {
    expect(transports, hasLength(1));
    expect(mic.disposeCalls, 0);
    expect(mic.micOpen, isTrue);
    expect(mic.micEnabled, isTrue);
    expect(mic.sentTypes, isNot(contains('session.close')));
    expect(coordinator.active, isTrue);
    expect(coordinator.ownsChat(chat), isTrue);
    expect(coordinator.phase, VoicePhase.listening);
    expect(coordinator.userPaused, isFalse);
    expect(coordinator.note, isNull);
    expect(coordinator.audioLeaseRequired, isTrue);
    expect(chained.active, isFalse, reason: 'no hand-over to the other engine');
  }

  void expectEnded({String? note = _left}) {
    expect(mic.micOpen, isFalse);
    expect(mic.disposeCalls, 1);
    expect(coordinator.audioLeaseRequired, isFalse);
    expect(live.note, note);
  }

  void dispose(FakeAsync clock) {
    coordinator.dispose();
    chat.dispose();
    unawaited(gateway.close());
    visible.dispose();
    profileChanges.dispose();
    clock.flushMicrotasks();
    clock.elapse(const Duration(seconds: 16));
    clock.flushMicrotasks();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  void run(String name, void Function(_Rig rig, FakeAsync clock) body) {
    test(name, () {
      fakeAsync((clock) {
        final rig = _Rig();
        body(rig, clock);
        rig.dispose(clock);
      });
    });
  }

  group('with the lock-screen opt-in', () {
    run('screen off and on keeps the session, the engine and the microphone', (
      rig,
      clock,
    ) {
      rig.enter(clock);
      rig.expectTalking();
      rig.screenOff(clock);
      clock.elapse(const Duration(minutes: 20));
      rig.expectTalking();
      expect(rig.coordinator.requiresForegroundVisibility, isFalse);
      expect(rig.serviceNeeded, isTrue);
      // A request spoken with the screen off is a normal Hermes turn.
      rig.mic.emitEvent({
        'type': 'session.input_transcript.delta',
        'delta': 'qué tiempo hace',
      });
      rig.mic.emitEvent({
        'type': 'session.delegation.created',
        'delegation': {'id': 'screen-off'},
      });
      clock.flushMicrotasks();
      expect(rig.gateway.submits, hasLength(1));
      rig.screenOn(clock);
      expect(rig.transports, hasLength(1));
      expect(rig.mic.micOpen, isTrue);
      expect(rig.mic.micEnabled, isTrue);
      expect(rig.coordinator.userPaused, isFalse);
      expect(rig.coordinator.note, isNull);
    });

    run('another app in front, with the chat still on top, keeps it too', (
      rig,
      clock,
    ) {
      rig.enter(clock);
      for (final step in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        rig.lifecycle(step, clock);
        rig.expectTalking();
      }
    });

    run('the voice service is needed from the start of the session to the '
        'end of its teardown', (rig, clock) {
      expect(rig.serviceNeeded, isFalse);
      final answer = Completer<VoiceLiveSessionAnswer>();
      rig.api.createGate = answer;
      rig.enter(clock);
      expect(rig.coordinator.phase, VoicePhase.thinking);
      expect(
        rig.serviceNeeded,
        isTrue,
        reason: 'asked for while the app is still in front',
      );
      answer.complete(rig.api.answer);
      clock.flushMicrotasks();
      rig.expectTalking();
      expect(rig.serviceNeeded, isTrue);
      rig.screenOff(clock);
      expect(rig.serviceNeeded, isTrue);
      unawaited(rig.coordinator.exit());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 16));
      expect(rig.mic.micOpen, isFalse);
      expect(rig.serviceNeeded, isFalse);
    });

    run('without the microphone service running it ends as without the '
        'opt-in', (rig, clock) {
      rig.microphoneServiceHeld = false;
      rig.enter(clock);
      rig.screenOff(clock);
      rig.expectEnded();
    });

    run('a session still starting when the screen turns off is ended', (
      rig,
      clock,
    ) {
      rig.api.createGate = Completer<VoiceLiveSessionAnswer>();
      rig.enter(clock);
      rig.screenOff(clock);
      rig.expectEnded();
    });

    run('the app swiped away ends it', (rig, clock) {
      rig.enter(clock);
      rig.screenOff(clock);
      rig.expectTalking();
      rig.lifecycle(AppLifecycleState.detached, clock);
      rig.expectEnded();
    });

    run('leaving the chat ends it, also with the screen off', (rig, clock) {
      rig.enter(clock);
      rig.screenOff(clock);
      rig.visible.value = null;
      clock.flushMicrotasks();
      rig.expectEnded();
    });

    run('a profile switch ends it, also with the screen off', (rig, clock) {
      rig.enter(clock);
      rig.screenOff(clock);
      rig.profile = 'other';
      rig.profileChanges.value++;
      clock.flushMicrotasks();
      rig.expectEnded();
    });

    run('a lost connection ends it with its own reason, and the screen '
        'coming back does not rewrite it', (rig, clock) {
      rig.enter(clock);
      rig.screenOff(clock);
      rig.mic.emitChannelClose();
      clock.flushMicrotasks();
      const lost = 'Live voice session ended: connection lost';
      rig.expectEnded(note: lost);
      expect(rig.serviceNeeded, isFalse);
      rig.screenOn(clock);
      expect(rig.coordinator.note, lost);
      expect(rig.coordinator.phase, VoicePhase.idle);
      expect(rig.transports, hasLength(1));
    });

    for (final lockFirst in [true, false]) {
      run('the app lock engaging on return closes it '
          '(${lockFirst ? 'lock' : 'resume'} seen first)', (rig, clock) {
        rig.enter(clock);
        rig.screenOff(clock);
        rig.expectTalking();
        // The lock engages when the app comes back after its timeout; the
        // host then calls `suspendForPrivacy`.
        if (lockFirst) {
          unawaited(rig.coordinator.suspendForPrivacy());
          rig.screenOn(clock, appLocked: true);
        } else {
          rig.screenOn(clock);
          unawaited(rig.coordinator.suspendForPrivacy());
          clock.flushMicrotasks();
        }
        expect(rig.mic.micOpen, isFalse);
        expect(rig.mic.disposeCalls, 1);
        expect(rig.coordinator.phase, VoicePhase.idle);
        expect(rig.coordinator.note, isNull, reason: 'blank under the lock');
        rig.coordinator.retry();
        clock.flushMicrotasks();
        expect(rig.transports, hasLength(1));
        // Unlocked: nothing starts by itself, one Retry does.
        rig.coordinator.onAppResumed(appUnlocked: true);
        clock.flushMicrotasks();
        expect(rig.transports, hasLength(1));
        rig.coordinator.retry();
        clock.flushMicrotasks();
        expect(rig.transports, hasLength(2));
      });
    }

    run('nothing starts while hidden', (rig, clock) {
      rig.screenOff(clock);
      rig.enter(clock);
      expect(rig.transports, isEmpty);
      expect(rig.api.createCalls, isEmpty);
      expect(rig.coordinator.active, isFalse);
      expect(rig.serviceNeeded, isFalse);
      rig.screenOn(clock);
      expect(rig.transports, isEmpty, reason: 'coming back starts nothing');
      rig.enter(clock);
      rig.expectTalking();
    });

    run('a session that closed with the screen off is not reopened until '
        'one Retry in front', (rig, clock) {
      rig.enter(clock);
      rig.screenOff(clock);
      rig.mic.emitEvent({'type': 'session.closed'});
      clock.flushMicrotasks();
      rig.coordinator.retry();
      unawaited(rig.coordinator.resumeFromSystemControl());
      rig.coordinator.onOrbTap();
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 5));
      expect(rig.transports, hasLength(1));
      rig.screenOn(clock);
      expect(rig.transports, hasLength(1));
      expect(
        rig.coordinator.note,
        'Live voice session ended: the session closed',
      );
      rig.coordinator.retry();
      clock.flushMicrotasks();
      expect(rig.transports, hasLength(2));
      expect(rig.coordinator.phase, VoicePhase.listening);
    });
  });

  group('without the lock-screen opt-in (the default)', () {
    run('screen off ends it; back in the chat one Retry talks again', (
      rig,
      clock,
    ) {
      rig.continueWhenLocked = false;
      rig.enter(clock);
      expect(rig.coordinator.requiresForegroundVisibility, isTrue);
      expect(rig.serviceNeeded, isFalse);
      rig.screenOff(clock);
      rig.expectEnded();
      // Hidden: nothing of the conversation is shown.
      expect(rig.coordinator.phase, VoicePhase.idle);
      expect(rig.coordinator.note, isNull);
      clock.elapse(const Duration(minutes: 20));
      rig.screenOn(clock);
      // What the voice strip is built from: the conversation is still this
      // chat's, stopped, with the reason and a Retry.
      expect(rig.coordinator.active, isTrue);
      expect(rig.coordinator.ownsChat(rig.chat), isTrue);
      expect(rig.coordinator.phase, VoicePhase.idle);
      expect(rig.coordinator.note, _left);
      expect(rig.transports, hasLength(1), reason: 'nothing starts by itself');
      // The strip's Retry: the only tap.
      rig.coordinator.retry();
      clock.flushMicrotasks();
      expect(rig.transports, hasLength(2));
      expect(rig.mic.micOpen, isTrue);
      expect(rig.mic.micEnabled, isTrue);
      expect(rig.coordinator.phase, VoicePhase.listening);
      expect(rig.coordinator.note, isNull);
      expect(rig.coordinator.userPaused, isFalse);
    });

    run('losing focus alone ends it, as before', (rig, clock) {
      rig.continueWhenLocked = false;
      rig.enter(clock);
      rig.lifecycle(AppLifecycleState.inactive, clock);
      rig.expectEnded();
      rig.lifecycle(AppLifecycleState.resumed, clock);
      expect(rig.coordinator.note, _left);
      rig.coordinator.retry();
      clock.flushMicrotasks();
      expect(rig.transports, hasLength(2));
    });

    run('leaving the chat ends it', (rig, clock) {
      rig.continueWhenLocked = false;
      rig.enter(clock);
      rig.visible.value = 'another-chat';
      clock.flushMicrotasks();
      rig.expectEnded();
    });

    run('nothing starts while hidden', (rig, clock) {
      rig.continueWhenLocked = false;
      rig.screenOff(clock);
      rig.enter(clock);
      expect(rig.transports, isEmpty);
      expect(rig.coordinator.active, isFalse);
    });
  });
}
