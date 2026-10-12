import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/conversation/gpt_live_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/conversation/voice_conversation_coordinator.dart';
import 'package:hermes_android/core/services/voice/live/voice_chat_mode_store.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_api.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart'
    show SttEngineKind;

import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_engines.dart';
import 'support/in_memory_compression_restore_storage.dart';
import 'support/voice_live_fakes.dart';

SavedConnection _connection() => SavedConnection(
  id: 'coord-conn',
  label: 'Coordinator test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

ActiveChat _chat(String id) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _connection(),
  sessionId: id,
  sessionTitle: id,
  notifications: null,
  onTerminal: () {},
  initialStoredSessionId: id,
);

class _Rig {
  _Rig() {
    coordinator = VoiceConversationCoordinator(
      chained: chained,
      liveFactory: () {
        liveCreated++;
        return live;
      },
      modes: modes,
      apiFactory: (_) {
        if (apiFails) throw StateError('no transport');
        return api;
      },
      languageCode: () => 'en',
      visibleSession: visible,
      profileWatch: (_) => (changes: profileChanges, current: () => profile),
      appVisible: () => appVisible,
    );
  }

  /// The app is on screen (in front, or in front without focus).
  bool appVisible = true;

  final chained = FakeVoiceEngine('chained');
  final live = FakeVoiceEngine('live');
  final api = FakeVoiceLiveApi();
  final visible = ValueNotifier<String?>('chat-1');
  final profileChanges = ValueNotifier<int>(0);
  late final VoiceConversationCoordinator coordinator;
  final chat = _chat('chat-1');
  final chat2 = _chat('chat-2');
  final modes = VoiceChatModeStore.memory();

  /// What the server answers, and is already known to answer, for the
  /// profiles the rig enters with. Until this is called the mode is unknown.
  void known(VoiceLiveMode mode, {bool available = true}) {
    final status = VoiceLiveStatus(mode: mode, available: available);
    api.status = status;
    for (final profile in const ['ops', 'other']) {
      modes.remember(
        VoiceChatModeStore.identity('coord-conn', profile),
        status,
      );
    }
  }

  /// The profile is set to GPT-Live and it can start, or to chained.
  set optIn(bool live) =>
      known(live ? VoiceLiveMode.gptLive : VoiceLiveMode.chained);
  bool apiFails = false;
  String profile = 'ops';
  int liveCreated = 0;

  Future<void> enter({String profile = 'ops'}) =>
      coordinator.enter(chat: chat, model: 'hermes-agent', profile: profile);

  /// One absence (screen off, another app in front) as `main.dart` reports
  /// it: every step away from the front suspends capture, and the hidden ones
  /// also ask the conversation to stop when the coordinator requires the
  /// foreground or the user did not opt in to continue with the screen locked.
  Future<void> hideApp({required bool continueWhenLocked}) async {
    for (final hidden in [false, true, true]) {
      if (hidden) appVisible = false;
      await coordinator.suspendFullDuplexForAppBackground();
      if (hidden &&
          coordinator.active &&
          (coordinator.requiresForegroundVisibility || !continueWhenLocked)) {
        await coordinator.onAppBackgrounded();
      }
    }
  }

  /// The app is in front again, unlocked.
  void showApp() {
    appVisible = true;
    coordinator.onAppResumed(appUnlocked: true);
  }

  void dispose() {
    coordinator.dispose();
    chat.dispose();
    chat2.dispose();
    visible.dispose();
    profileChanges.dispose();
  }
}

void main() {
  late _Rig rig;
  setUp(() => rig = _Rig());
  tearDown(() => rig.dispose());

  test('background during status probe prevents any engine entry', () async {
    final gate = Completer<VoiceLiveStatus?>();
    rig.api.statusGate = gate;
    final entry = rig.enter();
    await rig.coordinator.onAppBackgrounded();
    gate.complete(
      const VoiceLiveStatus(mode: VoiceLiveMode.gptLive, available: true),
    );
    await entry;
    expect(rig.live.calls, isEmpty);
    expect(rig.chained.calls, isEmpty);
    rig.coordinator.retry();
    await Future<void>.delayed(Duration.zero);
    expect(rig.api.statusCalls, 1);
  });

  test('route leave and return cannot revive a pending status probe', () async {
    final gate = Completer<VoiceLiveStatus?>();
    rig.api.statusGate = gate;
    final entry = rig.enter();
    rig.visible.value = 'other';
    rig.visible.value = 'chat-1';
    gate.complete(
      const VoiceLiveStatus(mode: VoiceLiveMode.gptLive, available: true),
    );
    await entry;
    expect(rig.live.calls, isEmpty);
    expect(rig.chained.calls, isEmpty);
  });

  test('a first probe that fails starts the normal conversation', () async {
    rig.api.statusError = const VoiceLiveStatusException(
      VoiceLiveStatusFailure.transient,
    );
    await rig.enter();
    expect(rig.chained.calls, ['enter']);
    expect(rig.liveCreated, 0);
    expect(rig.coordinator.note, isNull);
    expect(rig.coordinator.ownsChat(rig.chat), isTrue);
    // Nothing was learned, so the next start asks again.
    expect(
      rig.modes.read(VoiceChatModeStore.identity('coord-conn', 'ops')),
      isNull,
    );
    await rig.coordinator.exit();
    rig.api.statusError = null;
    rig.api.status = const VoiceLiveStatus(
      mode: VoiceLiveMode.gptLive,
      available: true,
    );
    await rig.enter();
    expect(rig.api.statusCalls, 2);
    expect(rig.live.calls, ['enter']);
  });

  test(
    'locked public projection stays neutral even after late engine changes',
    () async {
      await rig.enter();
      await rig.coordinator.suspendForPrivacy();
      rig.chained.partialTranscript = 'private-user';
      rig.chained.assistantResponse = 'private-answer';
      rig.chained.activeTool = 'private-step';
      rig.chained.note = 'private-error';
      rig.chained.phase = VoicePhase.toolCall;
      rig.chained.emitChange();
      expect(rig.coordinator.userTranscript, isEmpty);
      expect(rig.coordinator.assistantResponse, isEmpty);
      expect(rig.coordinator.activeTool, isNull);
      expect(rig.coordinator.note, isNull);
      expect(rig.coordinator.phase, VoicePhase.idle);
    },
  );

  test('hidden owner cannot explicitly retry a live session', () async {
    rig.optIn = true;
    await rig.enter();
    rig.visible.value = 'other';
    rig.coordinator.retry();
    expect(rig.live.calls, isNot(contains('retry')));
  });

  test(
    'privacy at the engine admission notification prevents microphone start',
    () async {
      rig.optIn = true;
      var revoked = false;
      rig.coordinator.addListener(() {
        if (!revoked && rig.liveCreated == 1 && rig.live.calls.isEmpty) {
          revoked = true;
          unawaited(rig.coordinator.suspendForPrivacy());
        }
      });
      await rig.enter();
      expect(rig.live.calls, isNot(contains('enter')));
    },
  );

  group('engine choice', () {
    String identity(String profile) =>
        VoiceChatModeStore.identity('coord-conn', profile);

    for (final (mode, available, live) in const [
      (VoiceLiveMode.gptLive, true, true),
      (VoiceLiveMode.gptLive, false, false),
      (VoiceLiveMode.chained, true, false),
      (VoiceLiveMode.chained, false, false),
    ]) {
      test('known ${mode.name}, available $available: '
          '${live ? 'GPT-Live' : 'chained'}', () async {
        rig.known(mode, available: available);
        await rig.enter();
        expect(rig.live.calls, live ? ['enter'] : isEmpty);
        expect(rig.chained.calls, live ? isEmpty : ['enter']);
        expect(rig.liveCreated, live ? 1 : 0);
        expect(rig.coordinator.active, isTrue);
        expect(
          rig.coordinator.requiresForegroundVisibility,
          live,
          reason:
              'GPT-Live needs the foreground unless its engine says the '
              'open session may continue hidden',
        );
      });
    }

    test('a server set to chained never starts GPT-Live, even with an old '
        'local opt-in stored', () async {
      SharedPreferences.setMockInitialValues({
        'voice_gpt_live_enabled_v1': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final modes = VoiceChatModeStore(prefs)
        ..remember(
          identity('ops'),
          const VoiceLiveStatus(mode: VoiceLiveMode.chained, available: true),
        );
      final chained = FakeVoiceEngine('chained');
      var liveCreated = 0;
      final coordinator = VoiceConversationCoordinator(
        chained: chained,
        liveFactory: () {
          liveCreated++;
          return FakeVoiceEngine('live');
        },
        modes: modes,
        apiFactory: (_) => rig.api,
        languageCode: () => 'en',
      );
      addTearDown(coordinator.dispose);
      await coordinator.enter(
        chat: rig.chat,
        model: 'hermes-agent',
        profile: 'ops',
      );
      expect(chained.calls, ['enter']);
      expect(liveCreated, 0);
      expect(coordinator.requiresForegroundVisibility, isFalse);
    });

    test(
      'a known mode decides at once and is refreshed in the background',
      () async {
        rig.known(VoiceLiveMode.chained);
        // The server has since been switched to GPT-Live, and answers slowly.
        final gate = Completer<VoiceLiveStatus?>();
        rig.api.statusGate = gate;
        await rig.enter();
        expect(rig.chained.calls, ['enter'], reason: 'no wait for the status');
        expect(rig.coordinator.phase, isNot(VoicePhase.thinking));
        expect(rig.api.statusCalls, 1);
        expect(rig.api.statusProfiles, ['ops']);
        gate.complete(
          const VoiceLiveStatus(mode: VoiceLiveMode.gptLive, available: true),
        );
        await Future<void>.delayed(Duration.zero);
        expect(rig.api.closeCalls, 1, reason: 'the refresh client is released');
        expect(rig.modes.read(identity('ops'))!.startsLive, isTrue);
        // The running conversation keeps its engine; the next one follows.
        expect(rig.live.calls, isEmpty);
        await rig.coordinator.exit();
        rig.api.statusGate = null;
        rig.api.status = const VoiceLiveStatus(
          mode: VoiceLiveMode.gptLive,
          available: true,
        );
        await rig.enter();
        expect(rig.live.calls, ['enter']);
      },
    );

    test('unknown mode: one probe for the profile, then GPT-Live if the '
        'server says so', () async {
      rig.api.status = const VoiceLiveStatus(
        mode: VoiceLiveMode.gptLive,
        available: true,
      );
      await rig.enter(profile: 'ops');
      expect(rig.live.calls, ['enter']);
      expect(rig.chained.calls, isEmpty);
      expect(rig.api.statusProfiles, ['ops']);
      expect(rig.api.closeCalls, 1, reason: 'the probe client is released');
      expect(rig.modes.read(identity('ops'))!.startsLive, isTrue);
      expect(rig.modes.read(identity('other')), isNull);
    });

    test('unknown mode with a slow status starts normal within the short '
        'probe', () {
      fakeAsync((async) {
        rig.api.statusGate = Completer<VoiceLiveStatus?>();
        unawaited(rig.enter());
        async.flushMicrotasks();
        expect(rig.coordinator.phase, VoicePhase.thinking);
        expect(rig.chained.calls, isEmpty);
        async.elapse(
          VoiceConversationCoordinator.unknownModeProbe -
              const Duration(milliseconds: 1),
        );
        expect(rig.chained.calls, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(rig.chained.calls, ['enter']);
        expect(rig.liveCreated, 0);
        expect(rig.api.statusCalls, 1);
        expect(rig.modes.read(identity('ops')), isNull);
        expect(
          VoiceConversationCoordinator.unknownModeProbe,
          lessThanOrEqualTo(const Duration(milliseconds: 1500)),
        );
      });
    });

    test(
      'the mode decides: available but set to chained stays chained',
      () async {
        rig.api.status = const VoiceLiveStatus(
          mode: VoiceLiveMode.chained,
          available: true,
        );
        await rig.enter();
        expect(rig.chained.calls, ['enter']);
        expect(rig.liveCreated, 0);
        expect(rig.coordinator.note, isNull);
      },
    );

    test('gpt-live that cannot start: chained and one notice', () async {
      rig.api.status = const VoiceLiveStatus(
        mode: VoiceLiveMode.gptLive,
        available: false,
        reason: 'no OpenAI API key',
      );
      await rig.enter();
      expect(rig.chained.calls, ['enter']);
      expect(rig.liveCreated, 0);
      // Localised, without the server's own English.
      expect(
        rig.coordinator.note,
        'GPT-Live unavailable. Using turn-based voice.',
      );
    });

    test(
      'a server without the feature runs chained without a notice',
      () async {
        rig.api.status = null;
        await rig.enter();
        expect(rig.chained.calls, ['enter']);
        expect(rig.coordinator.note, isNull);
        expect(
          rig.modes.read(identity('ops')),
          const VoiceChatMode(mode: VoiceLiveMode.chained, available: false),
        );
      },
    );

    test('a failing status read falls back instead of failing enter', () async {
      rig.api.statusError = StateError('offline');
      await rig.enter();
      expect(rig.chained.calls, ['enter']);
      expect(rig.api.closeCalls, 1);
    });

    test('an api client that cannot be built falls back too', () async {
      rig.apiFails = true;
      await rig.enter();
      expect(rig.chained.calls, ['enter']);
      expect(rig.liveCreated, 0);
    });

    test('the chained engine own note wins over the fallback notice', () async {
      rig.known(VoiceLiveMode.gptLive, available: false);
      await rig.enter();
      rig.chained.note = 'No te he oído';
      expect(rig.coordinator.note, 'No te he oído');
    });

    test(
      'flipping the opt-in mid-conversation keeps the running engine',
      () async {
        rig.optIn = true;
        await rig.enter();
        expect(rig.live.calls, ['enter']);
        rig.optIn = false;
        await rig.coordinator.pauseFromSystemControl();
        expect(rig.live.calls, ['enter', 'pauseFromSystemControl']);
        expect(rig.chained.calls, isEmpty);
        await rig.coordinator.exit();
        await rig.enter();
        expect(rig.chained.calls, ['enter'], reason: 'next entry re-decides');
      },
    );

    test('entering the same chat again is a no-op', () async {
      rig.optIn = true;
      await rig.enter();
      await rig.enter();
      expect(rig.live.calls, ['enter']);
      expect(rig.api.statusCalls, 1);
    });

    for (final aResolvesFirst in [true, false]) {
      test(
        'enter for another chat while the first status read is pending: '
        'only the second owns an engine '
        '(${aResolvesFirst ? 'A resolves first' : 'B resolves first'})',
        () async {
          const available = VoiceLiveStatus(
            mode: VoiceLiveMode.gptLive,
            available: true,
          );
          final gateA = Completer<VoiceLiveStatus?>();
          final gateB = Completer<VoiceLiveStatus?>();
          rig.api.statusGateQueue.addAll([gateA, gateB]);
          final enteringA = rig.coordinator.enter(
            chat: rig.chat,
            model: 'hermes-agent',
            profile: 'ops',
          );
          final enteringB = rig.coordinator.enter(
            chat: rig.chat2,
            model: 'hermes-agent',
            profile: 'other',
          );
          expect(rig.api.statusProfiles, ['ops', 'other']);
          // The user moved to chat B, the chat of the second entry.
          rig.visible.value = 'chat-2';
          if (aResolvesFirst) {
            gateA.complete(available);
            gateB.complete(available);
          } else {
            gateB.complete(available);
            gateA.complete(available);
          }
          await enteringA;
          await enteringB;
          expect(rig.live.calls, ['enter']);
          expect(rig.live.enteredProfile, 'other');
          expect(rig.chained.calls, isEmpty);
          expect(rig.coordinator.ownerChat, same(rig.chat2));
          expect(rig.coordinator.ownsChat(rig.chat), isFalse);
          expect(rig.coordinator.ownsChat(rig.chat2), isTrue);
        },
      );
    }

    test('same chat entered again with another profile while the status read '
        'is pending: the stale probe opens nothing', () async {
      const available = VoiceLiveStatus(
        mode: VoiceLiveMode.gptLive,
        available: true,
      );
      final gateOps = Completer<VoiceLiveStatus?>();
      final gateOther = Completer<VoiceLiveStatus?>();
      rig.api.statusGateQueue.addAll([gateOps, gateOther]);
      final first = rig.enter(profile: 'ops');
      final second = rig.enter(profile: 'other');
      expect(rig.api.statusProfiles, ['ops', 'other']);
      gateOps.complete(available);
      gateOther.complete(available);
      await first;
      await second;
      expect(rig.live.calls, ['enter']);
      expect(rig.live.enteredProfile, 'other');
      expect(rig.chained.calls, isEmpty);
    });

    test(
      'same chat and profile entered twice while pending reads once',
      () async {
        final gate = Completer<VoiceLiveStatus?>();
        rig.api.statusGateQueue.add(gate);
        final first = rig.enter(profile: 'ops');
        final second = rig.enter(profile: 'ops');
        gate.complete(
          const VoiceLiveStatus(mode: VoiceLiveMode.gptLive, available: true),
        );
        await first;
        await second;
        expect(rig.api.statusCalls, 1);
        expect(rig.live.calls, ['enter']);
      },
    );

    for (final hidden in <String?>[null, 'some-other-chat']) {
      test('leaving the chat route during the status read opens no live '
          'session (visible: $hidden)', () async {
        final gate = Completer<VoiceLiveStatus?>();
        rig.api.statusGateQueue.add(gate);
        final entering = rig.enter();
        rig.visible.value = hidden;
        gate.complete(
          const VoiceLiveStatus(mode: VoiceLiveMode.gptLive, available: true),
        );
        await entering;
        expect(rig.live.calls, isEmpty);
        expect(rig.chained.calls, isEmpty);
        expect(rig.coordinator.active, isFalse);
      });
    }

    test('exit during the status read opens nothing', () async {
      final gate = Completer<VoiceLiveStatus?>();
      rig.api.statusGate = gate;
      final entering = rig.enter();
      expect(rig.coordinator.active, isTrue);
      expect(rig.coordinator.phase, VoicePhase.thinking);
      await rig.coordinator.exit();
      expect(rig.coordinator.active, isFalse);
      gate.complete(
        const VoiceLiveStatus(mode: VoiceLiveMode.gptLive, available: true),
      );
      await entering;
      expect(rig.live.calls, isEmpty);
      expect(rig.chained.calls, isEmpty);
      expect(rig.coordinator.active, isFalse);
    });
  });

  group('delegation to the running engine', () {
    test('lifecycle calls reach the chained engine only', () async {
      await rig.enter();
      rig.chained.audioLeaseRequired = true;
      rig.chained.sessionId = 'server-1';
      await rig.coordinator.suspendForPrivacy();
      await rig.coordinator.resumeFullDuplexCaptureIfNeeded();
      await rig.coordinator.suspendFullDuplexForAppBackground();
      await rig.coordinator.onAppBackgrounded();
      rig.coordinator.onAppResumed(appUnlocked: true);
      await rig.coordinator.pauseFromSystemControl();
      await rig.coordinator.resumeFromSystemControl();
      expect(rig.chained.calls, [
        'enter',
        'suspendForPrivacy',
        'resumeFullDuplexCaptureIfNeeded',
        'suspendFullDuplexForAppBackground',
        'onAppBackgrounded',
        'onAppResumed:true',
        'pauseFromSystemControl',
        'resumeFromSystemControl',
      ]);
      expect(rig.live.calls, isEmpty);
      expect(rig.coordinator.audioLeaseRequired, isTrue);
      expect(rig.coordinator.sessionId, 'server-1');
    });

    test('lifecycle calls reach the live engine only', () async {
      rig.optIn = true;
      await rig.enter();
      await rig.coordinator.suspendForPrivacy();
      await rig.coordinator.onAppBackgrounded();
      expect(rig.live.calls, [
        'enter',
        'suspendForPrivacy',
        'onAppBackgrounded',
      ]);
      expect(rig.chained.calls, isEmpty);
    });

    test('controls and state come from the running engine', () async {
      rig.optIn = true;
      await rig.enter();
      rig.live
        ..phase = VoicePhase.toolCall
        ..activeTool = 'web_search'
        ..partialTranscript = 'hola'
        ..userPaused = true;
      expect(rig.coordinator.phase, VoicePhase.toolCall);
      expect(rig.coordinator.activeTool, 'web_search');
      expect(rig.coordinator.partialTranscript, 'hola');
      expect(rig.coordinator.userPaused, isTrue);
      expect(rig.coordinator.ownsChat(rig.chat), isTrue);
      expect(rig.coordinator.ownerChat, same(rig.chat));
      rig.coordinator
        ..onOrbTap()
        ..cancelBackend()
        ..retry();
      expect(rig.live.calls, ['enter', 'onOrbTap', 'cancelBackend', 'retry']);
    });

    test('idle facade reports an idle, inactive voice', () {
      expect(rig.coordinator.active, isFalse);
      expect(rig.coordinator.phase, VoicePhase.idle);
      expect(rig.coordinator.ownerChat, isNull);
      expect(rig.coordinator.ownsChat(rig.chat), isFalse);
      expect(rig.coordinator.audioLeaseRequired, isFalse);
      expect(rig.coordinator.sessionId, isNull);
    });

    test('exit leaves the engine and clears the fallback notice', () async {
      rig.known(VoiceLiveMode.gptLive, available: false);
      await rig.enter();
      expect(rig.coordinator.note, isNotNull);
      await rig.coordinator.exit();
      expect(rig.chained.calls, ['enter', 'exit']);
      expect(rig.coordinator.note, isNull);
      expect(rig.coordinator.active, isFalse);
    });

    test('engine changes notify the facade listeners', () async {
      rig.optIn = true;
      await rig.enter();
      var notified = 0;
      rig.coordinator.addListener(() => notified++);
      rig.live.emitChange();
      expect(notified, 1);
    });

    test('dictation problems of both engines reach one stream', () async {
      rig.optIn = true;
      final checks = <SttCheck>[];
      rig.coordinator.unavailable.listen(checks.add);
      await rig.enter();
      const check = SttCheck(
        SttStatus.needsMicPermission,
        SttEngineKind.system,
      );
      rig.live.unavailableController.add(check);
      rig.chained.unavailableController.add(check);
      await Future<void>.delayed(Duration.zero);
      expect(checks, hasLength(2));
    });
  });

  group('live session teardown triggers', () {
    setUp(() => rig.optIn = true);

    test('leaving the chat route ends the live session', () async {
      await rig.enter();
      rig.visible.value = null;
      expect(rig.live.ended, [LiveSessionEnd.routeLeave]);
    });

    test('another chat becoming visible ends it too', () async {
      await rig.enter();
      rig.visible.value = 'some-other-chat';
      expect(rig.live.ended, [LiveSessionEnd.routeLeave]);
    });

    test('the owner chat staying visible does not end it', () async {
      await rig.enter();
      rig.visible.value = 'chat-1';
      expect(rig.live.ended, isEmpty);
    });

    test('route changes never touch a chained conversation', () async {
      rig.optIn = false;
      await rig.enter();
      rig.visible.value = null;
      expect(rig.chained.calls, ['enter']);
      expect(rig.live.ended, isEmpty);
    });

    test('a profile switch ends the live session', () async {
      await rig.enter();
      rig.profile = 'other';
      rig.profileChanges.value++;
      expect(rig.live.ended, [LiveSessionEnd.profileSwitch]);
    });

    test('a profile notification without a change is ignored', () async {
      await rig.enter();
      rig.profileChanges.value++;
      expect(rig.live.ended, isEmpty);
    });

    test('after exit the watches are gone', () async {
      await rig.enter();
      await rig.coordinator.exit();
      rig.visible.value = null;
      rig.profile = 'other';
      rig.profileChanges.value++;
      expect(rig.live.ended, isEmpty);
    });
  });

  // Owner decision: the lock-screen opt-in now covers GPT-Live. The live
  // engine says whether its open session may continue with the app hidden
  // (`continuesWhileHidden`: opt-in, microphone service, session open); the
  // coordinator neither stops nor blanks such a session, and still lets
  // nothing start hidden.
  group('GPT-Live while the app is hidden', () {
    setUp(() => rig.optIn = true);

    for (final continueWhenLocked in [false, true]) {
      test('a session that may not continue is stopped as before '
          '(lock-screen opt-in: $continueWhenLocked)', () async {
        await rig.enter();
        rig.live
          ..phase = VoicePhase.listening
          ..partialTranscript = 'hola';
        expect(rig.coordinator.requiresForegroundVisibility, isTrue);
        await rig.hideApp(continueWhenLocked: continueWhenLocked);
        expect(rig.live.calls, [
          'enter',
          'suspendFullDuplexForAppBackground',
          'suspendFullDuplexForAppBackground',
          'onAppBackgrounded',
          'suspendFullDuplexForAppBackground',
          'onAppBackgrounded',
        ]);
        // Nothing of the conversation is shown while hidden.
        expect(rig.coordinator.phase, VoicePhase.idle);
        expect(rig.coordinator.partialTranscript, isEmpty);
        rig.coordinator.retry();
        expect(rig.live.calls, isNot(contains('retry')));
      });
    }

    test(
      'a session that may continue is neither stopped nor blanked',
      () async {
        rig.live.continuesWhileHidden = true;
        await rig.enter();
        rig.live
          ..phase = VoicePhase.listening
          ..partialTranscript = 'hola'
          ..audioLeaseRequired = true;
        expect(rig.coordinator.requiresForegroundVisibility, isFalse);
        await rig.hideApp(continueWhenLocked: true);
        expect(rig.live.ended, isEmpty);
        expect(rig.live.calls, [
          'enter',
          'suspendFullDuplexForAppBackground',
          'suspendFullDuplexForAppBackground',
          'suspendFullDuplexForAppBackground',
        ], reason: 'the host never asks it to stop, and the engine is told');
        expect(rig.chained.calls, isEmpty);
        expect(rig.coordinator.active, isTrue);
        expect(rig.coordinator.ownsChat(rig.chat), isTrue);
        expect(rig.coordinator.phase, VoicePhase.listening);
        expect(rig.coordinator.partialTranscript, 'hola');
        expect(rig.coordinator.audioLeaseRequired, isTrue);
        // Even a host that asked would not blank it: the engine decides.
        await rig.coordinator.onAppBackgrounded();
        expect(rig.live.ended, isEmpty);
        expect(rig.coordinator.phase, VoicePhase.listening);
        expect(rig.coordinator.partialTranscript, 'hola');
      },
    );

    test(
      'an engine that stops allowing it is stopped at the next step',
      () async {
        rig.live.continuesWhileHidden = true;
        await rig.enter();
        rig.live.phase = VoicePhase.listening;
        await rig.coordinator.suspendFullDuplexForAppBackground();
        expect(rig.coordinator.phase, VoicePhase.listening);
        rig.live.continuesWhileHidden = false;
        expect(rig.coordinator.requiresForegroundVisibility, isTrue);
        await rig.hideApp(continueWhenLocked: true);
        expect(rig.live.calls, contains('onAppBackgrounded'));
        expect(rig.coordinator.phase, VoicePhase.idle);
      },
    );

    for (final continues in [false, true]) {
      test('leaving the chat still ends it (may continue hidden: '
          '$continues)', () async {
        rig.live.continuesWhileHidden = continues;
        await rig.enter();
        await rig.hideApp(continueWhenLocked: continues);
        rig.visible.value = null;
        expect(rig.live.ended, [LiveSessionEnd.routeLeave]);
      });

      test('a profile switch still ends it (may continue hidden: '
          '$continues)', () async {
        rig.live.continuesWhileHidden = continues;
        await rig.enter();
        await rig.hideApp(continueWhenLocked: continues);
        rig.profile = 'other';
        rig.profileChanges.value++;
        expect(rig.live.ended, [LiveSessionEnd.profileSwitch]);
      });
    }

    test(
      'the app lock still closes and blanks a session kept hidden',
      () async {
        rig.live.continuesWhileHidden = true;
        await rig.enter();
        rig.live
          ..phase = VoicePhase.listening
          ..partialTranscript = 'privado';
        await rig.hideApp(continueWhenLocked: true);
        await rig.coordinator.suspendForPrivacy();
        expect(rig.live.calls.last, 'suspendForPrivacy');
        expect(rig.coordinator.phase, VoicePhase.idle);
        expect(rig.coordinator.partialTranscript, isEmpty);
        // Coming back locked keeps it fenced; unlocking never starts audio.
        rig.coordinator.onAppResumed(appUnlocked: false);
        rig.coordinator.retry();
        expect(rig.live.calls, isNot(contains('retry')));
        expect(rig.coordinator.phase, VoicePhase.idle);
        rig.coordinator.onAppResumed(appUnlocked: true);
        expect(rig.live.calls, isNot(contains('retry')));
        expect(rig.live.calls.where((c) => c == 'enter'), hasLength(1));
      },
    );

    test('GPT-Live is not entered while the app is hidden, opt-in or '
        'not', () async {
      rig.live.continuesWhileHidden = true;
      await rig.hideApp(continueWhenLocked: true);
      await rig.enter();
      expect(rig.liveCreated, 0);
      expect(rig.live.calls, isEmpty);
      expect(rig.chained.calls, isEmpty);
      expect(rig.coordinator.active, isFalse);
      rig.showApp();
      await rig.enter();
      expect(rig.live.calls, ['enter']);
    });

    test('losing focus alone (a system dialog on top) does not refuse a '
        'first entry', () async {
      await rig.coordinator.suspendFullDuplexForAppBackground();
      await rig.enter();
      expect(rig.live.calls, ['enter']);
    });

    test('a first probe that answers GPT-Live after the app was hidden '
        'opens nothing', () async {
      final fresh = _Rig();
      addTearDown(fresh.dispose);
      fresh.api.status = const VoiceLiveStatus(
        mode: VoiceLiveMode.gptLive,
        available: true,
      );
      fresh.live.continuesWhileHidden = true;
      await fresh.hideApp(continueWhenLocked: true);
      await fresh.enter();
      expect(fresh.api.statusCalls, 1);
      expect(fresh.liveCreated, 0);
      expect(fresh.live.calls, isEmpty);
      expect(fresh.chained.calls, isEmpty);
      expect(fresh.coordinator.active, isFalse);
    });

    test('a GPT-Live retry waits for the app to be in front', () async {
      rig.live.continuesWhileHidden = true;
      await rig.enter();
      await rig.hideApp(continueWhenLocked: true);
      rig.coordinator.retry();
      expect(rig.live.calls, isNot(contains('retry')));
      rig.showApp();
      rig.coordinator.retry();
      expect(rig.live.calls.last, 'retry');
    });

    test('the chained conversation keeps its own rule when hidden', () async {
      rig.optIn = false;
      await rig.enter();
      await rig.hideApp(continueWhenLocked: true);
      expect(rig.chained.calls, [
        'enter',
        'suspendFullDuplexForAppBackground',
        'suspendFullDuplexForAppBackground',
        'suspendFullDuplexForAppBackground',
      ]);
      rig.coordinator.retry();
      expect(rig.chained.calls.last, 'retry');
    });
  });
}
