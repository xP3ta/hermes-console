import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/conversation/gpt_live_voice_conversation_controller.dart';
import 'package:hermes_android/core/services/voice/conversation/voice_conversation_coordinator.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart'
    show SttEngineKind;

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
      gptLiveEnabled: () => optIn,
      apiFactory: (_) {
        if (apiFails) throw StateError('no transport');
        return api;
      },
      languageCode: () => 'en',
      visibleSession: visible,
      profileWatch: (_) => (changes: profileChanges, current: () => profile),
    );
  }

  final chained = FakeVoiceEngine('chained');
  final live = FakeVoiceEngine('live');
  final api = FakeVoiceLiveApi();
  final visible = ValueNotifier<String?>('chat-1');
  final profileChanges = ValueNotifier<int>(0);
  late final VoiceConversationCoordinator coordinator;
  final chat = _chat('chat-1');
  bool optIn = false;
  bool apiFails = false;
  String profile = 'ops';
  int liveCreated = 0;

  Future<void> enter({String profile = 'ops'}) =>
      coordinator.enter(chat: chat, model: 'hermes-agent', profile: profile);

  void dispose() {
    coordinator.dispose();
    chat.dispose();
    visible.dispose();
    profileChanges.dispose();
  }
}

void main() {
  late _Rig rig;
  setUp(() => rig = _Rig());
  tearDown(() => rig.dispose());

  group('engine choice', () {
    test('opt-in off: chained, no status read, live never created', () async {
      await rig.enter();
      expect(rig.chained.calls, ['enter']);
      expect(rig.api.statusCalls, 0);
      expect(rig.liveCreated, 0);
      expect(rig.coordinator.active, isTrue);
      expect(rig.coordinator.note, isNull);
    });

    test(
      'opt-in on and available: live, probed once for the profile',
      () async {
        rig.optIn = true;
        rig.api.status = const VoiceLiveStatus(
          mode: VoiceLiveMode.gptLive,
          available: true,
        );
        await rig.enter(profile: 'ops');
        expect(rig.live.calls, ['enter']);
        expect(rig.chained.calls, isEmpty);
        expect(rig.api.statusProfiles, ['ops']);
        expect(rig.api.closeCalls, 1, reason: 'the probe client is released');
      },
    );

    test('the mode field alone does not decide: availability does', () async {
      rig.optIn = true;
      rig.api.status = const VoiceLiveStatus(
        mode: VoiceLiveMode.chained,
        available: true,
      );
      await rig.enter();
      expect(rig.live.calls, ['enter']);
    });

    test('unavailable with a reason: chained and one notice', () async {
      rig.optIn = true;
      rig.api.status = const VoiceLiveStatus(
        mode: VoiceLiveMode.chained,
        available: false,
        reason: 'no OpenAI API key',
      );
      await rig.enter();
      expect(rig.chained.calls, ['enter']);
      expect(rig.liveCreated, 0);
      expect(
        rig.coordinator.note,
        'GPT-Live unavailable: no OpenAI API key. Using turn-based voice.',
      );
    });

    test('a server without the feature falls back without a reason', () async {
      rig.optIn = true;
      rig.api.status = null;
      await rig.enter();
      expect(rig.chained.calls, ['enter']);
      expect(
        rig.coordinator.note,
        'GPT-Live unavailable. Using turn-based voice.',
      );
    });

    test('a failing status read falls back instead of failing enter', () async {
      rig.optIn = true;
      rig.api.statusError = StateError('offline');
      await rig.enter();
      expect(rig.chained.calls, ['enter']);
      expect(rig.api.closeCalls, 1);
    });

    test('an api client that cannot be built falls back too', () async {
      rig.optIn = true;
      rig.apiFails = true;
      await rig.enter();
      expect(rig.chained.calls, ['enter']);
      expect(rig.liveCreated, 0);
    });

    test('the chained engine own note wins over the fallback notice', () async {
      rig.optIn = true;
      rig.api.status = null;
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

    test('exit during the status read opens nothing', () async {
      rig.optIn = true;
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
      rig.optIn = true;
      rig.api.status = null;
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
}
