import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/conversation/chat_recognizer_prewarm.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/device_memory_profile.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart'
    show SherpaModelKind;
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// This phone's recogniser: it can be loaded without a capture.
class _Recognizer extends SttEngine implements WarmSttEngine {
  int prewarmCalls = 0;
  int parkCalls = 0;
  int disposeCalls = 0;

  /// Anything that opens the microphone or asks for its permission.
  int microphoneCalls = 0;

  @override
  bool get supportsPartials => true;

  @override
  Future<bool> available() async {
    microphoneCalls++;
    return true;
  }

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    microphoneCalls++;
    onCaptureReady?.call();
    return const Stream<SttResult>.empty();
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> prewarm() async {
    prewarmCalls++;
  }

  @override
  Future<void> park() async {
    parkCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _Tts implements TtsEngine {
  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _Timer implements VoiceIdleTimer {
  _Timer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  void fire() {
    if (!cancelled) _callback();
  }
}

class _Timers {
  final List<_Timer> created = <_Timer>[];

  VoiceIdleTimer create(Duration delay, void Function() callback) {
    final timer = _Timer(delay, callback);
    created.add(timer);
    return timer;
  }

  /// The live timer set for [delay], if any.
  _Timer? pending(Duration delay) => created
      .where((timer) => !timer.cancelled && timer.delay == delay)
      .lastOrNull;
}

class _Rig {
  _Rig(this.voice, this.preferences, this.timers, this.engines);

  final VoiceService voice;
  final SharedPreferences preferences;
  final _Timers timers;
  final List<_Recognizer> engines;

  /// Questions that cost something: the profile and the platform probe.
  int profileAsked = 0;
  int deviceAsked = 0;
  bool deviceConstrained = false;
}

const _dashboard = 'http://hermes-demo.local:9119';
const _bigDevice = DeviceMemoryProfile(memTotalBytes: 16 * 1024 * 1024 * 1024);
const _smallDevice = DeviceMemoryProfile(memTotalBytes: 4 * 1024 * 1024 * 1024);
const _threeMinutes = Duration(minutes: 3);
const _chatLeftGrace = Duration(seconds: 20);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final connection = SavedConnection(
    id: 'demo-node',
    label: 'Server',
    host: 'hermes-demo.local',
    port: 8642,
    apiKey: 'test-key',
    dashboardUrl: _dashboard,
  );

  int daysAgo(int days) => VoiceService.voiceUseDay(DateTime.now()) - days;

  /// A phone whose owner talked to it [lastUse] days ago (null: never).
  Future<_Rig> rig({
    int? lastUse = 0,
    Map<String, Object> stored = const {},
    DeviceMemoryProfile memory = _bigDevice,
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_locale': 'es',
      if (lastUse != null)
        VoiceService.lastOnDeviceVoiceDayKey: daysAgo(lastUse),
      ...stored,
    });
    final preferences = await SharedPreferences.getInstance();
    final timers = _Timers();
    final voice = VoiceService(
      preferences,
      SecureStorage(),
      idleTimerFactory: timers.create,
    );
    final engines = <_Recognizer>[];
    voice.debugSttFactory = () {
      final engine = _Recognizer();
      engines.add(engine);
      return engine;
    };
    voice.debugTtsFactory = _Tts.new;
    voice.debugMemoryProfile = memory;
    return _Rig(voice, preferences, timers, engines);
  }

  Future<void> settle() async {
    for (var turn = 0; turn < 6; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// A chat whose first frame is out.
  Future<ChatRecognizerPrewarm> openChat(
    _Rig rig, {
    String profile = '',
  }) async {
    final prewarm = ChatRecognizerPrewarm.attach(
      voice: rig.voice,
      preferences: rig.preferences,
      connection: connection,
      profile: () async {
        rig.profileAsked++;
        return profile;
      },
      deviceConstrained: () async {
        rig.deviceAsked++;
        return rig.deviceConstrained;
      },
      dashboardIdentity: (_) => _dashboard,
      settle: Duration.zero,
    );
    addTearDown(prewarm.detach);
    await settle();
    return prewarm;
  }

  group('when it loads', () {
    test('for somebody who talked to this phone lately, on this phone, on a '
        'device with room: once, and without the microphone', () async {
      for (final lastUse in [0, VoiceService.recentVoiceUseDays]) {
        final phone = await rig(lastUse: lastUse);
        await openChat(phone);

        final engine = phone.engines.single;
        expect(engine.prewarmCalls, 1, reason: 'used $lastUse days ago');
        expect(engine.microphoneCalls, 0);
        expect(engine.parkCalls, 0);
        // It waits like the recogniser a finished conversation leaves.
        expect(phone.timers.pending(_threeMinutes), isNotNull);
      }
    });

    test('never for somebody who does not talk to this phone, and it costs '
        'them nothing', () async {
      for (final lastUse in [null, VoiceService.recentVoiceUseDays + 1]) {
        final phone = await rig(lastUse: lastUse);
        await openChat(phone);

        expect(phone.engines, isEmpty, reason: 'last use: $lastUse');
        // One preference read decided it: nothing was asked of the platform.
        expect(phone.profileAsked, 0);
        expect(phone.deviceAsked, 0);
        expect(phone.timers.created, isEmpty);
      }
    });

    test('not when the conversation runs on the Hermes server', () async {
      final phone = await rig();
      await NativeVoiceModeStore(
        phone.preferences,
      ).write(_dashboard, NativeVoiceMode.server);

      await openChat(phone);

      expect(phone.engines, isEmpty);
      expect(phone.deviceAsked, 0);
    });

    test('the server route of one profile does not stop another', () async {
      final phone = await rig();
      await NativeVoiceModeStore(phone.preferences).write(
        nativeVoicePreferenceIdentity(_dashboard, profile: 'coder'),
        NativeVoiceMode.server,
      );

      await openChat(phone, profile: 'coder');
      expect(phone.engines, isEmpty);

      await openChat(phone);
      expect(phone.engines.single.prewarmCalls, 1);
    });

    test(
      'not when the conversation is GPT-Live, unless it cannot start',
      () async {
        final live = await rig(
          stored: {'voice_chat_mode_v1::demo-node::': 'gpt-live'},
        );
        await openChat(live);
        expect(live.engines, isEmpty);

        // Set to GPT-Live but unable to start: the conversation runs on this
        // phone, with its recogniser.
        final fallback = await rig(
          stored: {'voice_chat_mode_v1::demo-node::': 'gpt-live:unavailable'},
        );
        await openChat(fallback);
        expect(fallback.engines.single.prewarmCalls, 1);
      },
    );

    test('not on a low-RAM device or in battery saver', () async {
      final phone = await rig()
        ..deviceConstrained = true;

      final chat = await openChat(phone);
      expect(phone.deviceAsked, 1);
      expect(phone.engines, isEmpty);

      // Battery saver goes off while the app is away: coming back loads it.
      phone.deviceConstrained = false;
      chat.didChangeAppLifecycleState(AppLifecycleState.hidden);
      chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(phone.engines.single.prewarmCalls, 1);
    });

    test('not again in this run of the app once memory pressure was '
        'reported', () async {
      // In front, and in the background, the one level Android 14 still
      // sends there.
      for (final level in [10, 40]) {
        final phone = await rig();
        await phone.voice.onTrimMemory(level);

        final chat = await openChat(phone);
        expect(phone.engines, isEmpty, reason: 'trim level $level');
        expect(phone.deviceAsked, 0);

        chat.didChangeAppLifecycleState(AppLifecycleState.hidden);
        chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await settle();
        expect(phone.engines, isEmpty, reason: 'trim level $level');
      }
    });

    test('pressure a running conversation sat out counts too', () async {
      final phone = await rig();
      phone.voice.setVoiceConversationActive(true);
      await phone.voice.onTrimMemory(40); // TRIM_MEMORY_BACKGROUND
      phone.voice.setVoiceConversationActive(false);

      await openChat(phone);

      expect(phone.engines, isEmpty);
    });

    test('the app merely leaving the screen is not memory pressure', () async {
      final phone = await rig();
      await phone.voice.onTrimMemory(20); // TRIM_MEMORY_UI_HIDDEN

      await openChat(phone);

      expect(phone.engines.single.prewarmCalls, 1);
    });

    test(
      'not where the recogniser and the voice may not share memory',
      () async {
        final phone = await rig(memory: _smallDevice);
        await openChat(phone);
        expect(phone.engines, isEmpty);

        // With the system voice only one model is ever loaded: it fits.
        final light = await rig(
          memory: _smallDevice,
          stored: {'voice_tts_engine': TtsEngineKind.device.id},
        );
        await openChat(light);
        expect(light.engines.single.prewarmCalls, 1);
      },
    );

    test('not when the conversation uses a recogniser that cannot wait '
        'loaded', () async {
      final phone = await rig(
        stored: {'voice_stt_engine': SttEngineKind.whisper.id},
      );
      await openChat(phone);
      expect(phone.engines, isEmpty);
    });

    test('not over a conversation or a recogniser already there', () async {
      final phone = await rig();
      phone.voice.enableOnDeviceVoice();
      phone.voice.setVoiceConversationActive(true);
      expect((await phone.voice.checkStt()).ready, isTrue);
      phone.voice.startDictation();
      final inUse = phone.engines.single;

      await openChat(phone);

      expect(phone.engines, hasLength(1));
      expect(inUse.disposeCalls, 0);
      await phone.voice.disposeSttForVoiceExit();
    });

    test('two chats at once load it once', () async {
      final phone = await rig();
      await Future.wait([openChat(phone), openChat(phone)]);
      expect(phone.engines.single.prewarmCalls, 1);
    });
  });

  testWidgets('the chat comes in first: nothing is asked or loaded while it '
      'settles, and leaving meanwhile loads nothing', (tester) async {
    final phone = (await tester.runAsync(rig))!;
    ChatRecognizerPrewarm open() => ChatRecognizerPrewarm.attach(
      voice: phone.voice,
      preferences: phone.preferences,
      connection: connection,
      profile: () async {
        phone.profileAsked++;
        return '';
      },
      deviceConstrained: () async => false,
      dashboardIdentity: (_) => _dashboard,
    );

    final gone = open();
    await tester.pump(
      ChatRecognizerPrewarm.settleTime - const Duration(milliseconds: 1),
    );
    expect(phone.profileAsked, 0);
    expect(phone.engines, isEmpty);
    gone.detach();
    await tester.pump(const Duration(seconds: 1));
    expect(phone.profileAsked, 0);
    expect(phone.engines, isEmpty);

    final stays = open();
    await tester.pump(ChatRecognizerPrewarm.settleTime);
    await tester.pump();
    expect(phone.engines.single.prewarmCalls, 1);
    stays.detach();
  });

  group('the voice start that follows', () {
    test('finds it loaded: the same recogniser, no second load', () async {
      final phone = await rig();
      await openChat(phone);
      final loaded = phone.engines.single;

      // In, as the chat does it: the phone's route, then the conversation.
      final preparation = phone.voice.beginNativeVoicePreparation(
        owner: Object(),
      );
      phone.voice.cancelNativeVoicePreparation(preparation!);
      expect(phone.voice.enableOnDeviceVoice(), isTrue);
      expect((await phone.voice.checkStt()).ready, isTrue);
      phone.voice.setVoiceConversationActive(true);
      phone.voice.startDictation();

      expect(phone.engines, hasLength(1));
      expect(loaded.disposeCalls, 0);
      // Used now, it is nobody's leftover: its timer does not release it.
      for (final timer in phone.timers.created) {
        timer.fire();
      }
      await settle();
      expect(loaded.disposeCalls, 0);
      await phone.voice.disposeSttForVoiceExit();
    });

    test('a capture on this phone is what keeps the habit alive', () async {
      final phone = await rig(lastUse: null);
      expect(
        phone.preferences.getInt(VoiceService.lastOnDeviceVoiceDayKey),
        isNull,
      );

      expect((await phone.voice.checkStt()).ready, isTrue);
      phone.voice.startDictation();
      await settle();

      expect(
        phone.preferences.getInt(VoiceService.lastOnDeviceVoiceDayKey),
        daysAgo(0),
      );
      await phone.voice.disposeSttForVoiceExit();
    });
  });

  group('what releases it', () {
    test('three minutes unused', () async {
      final phone = await rig();
      await openChat(phone);

      phone.timers.pending(_threeMinutes)!.fire();
      await settle();

      expect(phone.engines.single.disposeCalls, 1);
    });

    test('memory pressure', () async {
      final phone = await rig();
      await openChat(phone);

      await phone.voice.onTrimMemory(10); // TRIM_MEMORY_RUNNING_LOW
      await settle();

      expect(phone.engines.single.disposeCalls, 1);
    });

    test(
      'the app leaving the screen, and coming back loads it again',
      () async {
        final phone = await rig();
        final chat = await openChat(phone);

        chat.didChangeAppLifecycleState(AppLifecycleState.inactive);
        await settle();
        expect(
          phone.engines.single.disposeCalls,
          0,
          reason: 'a dialog over the app is still the app',
        );

        chat.didChangeAppLifecycleState(AppLifecycleState.hidden);
        chat.didChangeAppLifecycleState(AppLifecycleState.paused);
        await settle();
        expect(phone.engines.single.disposeCalls, 1);

        chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await settle();
        expect(phone.engines, hasLength(2));
        expect(phone.engines.last.prewarmCalls, 1);
        expect(phone.engines.last.disposeCalls, 0);
      },
    );

    test('the system hiding the app, whatever the chat heard', () async {
      final phone = await rig();
      await openChat(phone);

      await phone.voice.onTrimMemory(20); // TRIM_MEMORY_UI_HIDDEN
      await settle();

      expect(phone.engines.single.disposeCalls, 1);
    });

    test('another recognition model', () async {
      final phone = await rig();
      await openChat(phone);

      await phone.voice.saveSettings(
        phone.voice.settings.copyWith(
          sherpaModel: SherpaModelKind.whisperSmall,
        ),
      );
      await settle();

      expect(phone.engines.single.disposeCalls, 1);
    });

    test('another recognition engine', () async {
      final phone = await rig();
      await openChat(phone);

      await phone.voice.saveSettings(
        phone.voice.settings.copyWith(sttEngine: SttEngineKind.whisper),
      );
      await settle();

      expect(phone.engines.single.disposeCalls, 1);
    });

    test('another language: the next chat loads it in the new one', () async {
      final phone = await rig();
      await openChat(phone);
      await phone.preferences.setString('app_locale', 'en');

      await openChat(phone);

      expect(phone.engines, hasLength(2));
      expect(phone.engines.first.disposeCalls, 1);
      expect(phone.engines.last.prewarmCalls, 1);
    });

    test(
      'leaving the chat with nothing running, after a short grace',
      () async {
        final phone = await rig();
        final chat = await openChat(phone);

        chat.detach();
        await settle();
        expect(phone.engines.single.disposeCalls, 0);

        phone.timers.pending(_chatLeftGrace)!.fire();
        await settle();
        expect(phone.engines.single.disposeCalls, 1);
      },
    );

    test('going from one chat to the next keeps it', () async {
      final phone = await rig();
      final first = await openChat(phone);

      // Back to the list and into another chat within the grace.
      first.detach();
      final grace = phone.timers.pending(_chatLeftGrace)!;
      final second = await openChat(phone);
      grace.fire();
      await settle();
      expect(phone.engines.single.disposeCalls, 0);
      expect(phone.engines.single.prewarmCalls, 1);

      // A chat opened over another, then closed: one is still on screen.
      final third = await openChat(phone);
      third.detach();
      await settle();
      expect(phone.timers.pending(_chatLeftGrace), isNull);
      second.detach();
      expect(phone.timers.pending(_chatLeftGrace), isNotNull);
    });

    test('a conversation that goes on keeps its recogniser, off screen and '
        'out of the chat', () async {
      final phone = await rig();
      final chat = await openChat(phone);
      phone.voice.enableOnDeviceVoice();
      expect((await phone.voice.checkStt()).ready, isTrue);
      phone.voice.setVoiceConversationActive(true);
      phone.voice.startDictation();
      final talking = phone.engines.single;

      chat.didChangeAppLifecycleState(AppLifecycleState.hidden);
      chat.detach();
      for (final timer in phone.timers.created) {
        timer.fire();
      }
      await settle();

      expect(talking.disposeCalls, 0);
      // Paused by the user it waits for the conversation, not for a chat.
      await phone.voice.disposeSttForVoiceExit(keepRecognizerWarm: true);
      chat.didChangeAppLifecycleState(AppLifecycleState.paused);
      await settle();
      expect(talking.disposeCalls, 0);
      await phone.voice.disposeSttForVoiceExit();
    });
  });
}
