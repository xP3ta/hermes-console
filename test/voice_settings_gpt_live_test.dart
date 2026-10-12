import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/live/voice_chat_mode_store.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the app keeps no GPT-Live switch of its own any more', () async {
    // A preference written by an older build is neither read nor rewritten.
    SharedPreferences.setMockInitialValues({'voice_gpt_live_enabled_v1': true});
    final prefs = await SharedPreferences.getInstance();
    await VoiceSettings.load(prefs).copyWith(autoSpeak: true).save(prefs);
    expect(prefs.getBool('voice_gpt_live_enabled_v1'), isTrue);
    expect(VoiceSettings.load(prefs).autoSpeak, isTrue);
  });

  test('the server mode is remembered per connection and profile', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = VoiceChatModeStore(prefs);
    final work = VoiceChatModeStore.identity('conn', 'work');
    final defaults = VoiceChatModeStore.identity('conn', null);
    expect(store.read(work), isNull);

    store.remember(
      work,
      const VoiceLiveStatus(mode: VoiceLiveMode.gptLive, available: true),
    );
    expect(store.read(work)!.startsLive, isTrue);
    expect(store.read(defaults), isNull, reason: 'profiles do not mix');
    // Another instance over the same preferences sees it at once: the
    // conversation and the settings screen never disagree.
    expect(VoiceChatModeStore(prefs).read(work)!.startsLive, isTrue);

    // No profile and `default` are the same server profile.
    expect(VoiceChatModeStore.identity('conn', 'default'), defaults);
    expect(VoiceChatModeStore.identity('conn', ''), defaults);
    expect(VoiceChatModeStore.identity('other', null), isNot(defaults));
  });

  test('only gpt-live that can start counts as GPT-Live', () {
    final store = VoiceChatModeStore.memory();
    const id = 'conn::';
    for (final (mode, available, live) in const [
      (VoiceLiveMode.gptLive, true, true),
      (VoiceLiveMode.gptLive, false, false),
      (VoiceLiveMode.chained, true, false),
      (VoiceLiveMode.chained, false, false),
    ]) {
      store.remember(id, VoiceLiveStatus(mode: mode, available: available));
      expect(store.read(id), VoiceChatMode(mode: mode, available: available));
      expect(store.read(id)!.startsLive, live);
    }
    // A server without the feature can only run the normal conversation.
    store.remember(id, null);
    expect(
      store.read(id),
      const VoiceChatMode(mode: VoiceLiveMode.chained, available: false),
    );
  });

  test(
    'keeps the last status in full for a screen that paints first',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = VoiceChatModeStore(prefs);
      final identity = VoiceChatModeStore.identity('conn', 'work');

      expect(store.lastStatus(identity), isNull);
      store.remember(
        identity,
        const VoiceLiveStatus(
          mode: VoiceLiveMode.chained,
          available: false,
          reason: 'no OpenAI API key',
        ),
      );
      // Another instance over the same preferences sees it at once.
      final seen = VoiceChatModeStore(prefs).lastStatus(identity)!;
      expect(seen.mode, VoiceLiveMode.chained);
      expect(seen.available, isFalse);
      expect(seen.reason, 'no OpenAI API key');
      // What the conversation reads did not change.
      expect(
        store.read(identity),
        const VoiceChatMode(mode: VoiceLiveMode.chained, available: false),
      );
      expect(
        store.lastStatus(VoiceChatModeStore.identity('conn', null)),
        isNull,
      );

      store.remember(
        identity,
        const VoiceLiveStatus(
          mode: VoiceLiveMode.gptLive,
          available: true,
          voice: 'cedar',
        ),
      );
      final live = store.lastStatus(identity)!;
      expect(live.mode, VoiceLiveMode.gptLive);
      expect(live.available, isTrue);
      expect(live.reason, isNull);
      expect(live.voice, 'cedar');

      // A server without the route: the conversation falls back to the normal
      // one, and there is no GPT-Live status to show.
      store.remember(identity, null);
      expect(store.lastStatus(identity), isNull);
      expect(
        store.read(identity),
        const VoiceChatMode(mode: VoiceLiveMode.chained, available: false),
      );
    },
  );

  test('an answer remembered before the reason was kept shows the choice only '
      'when GPT-Live was available', () async {
    SharedPreferences.setMockInitialValues({
      'voice_chat_mode_v1::conn::live': 'gpt-live',
      'voice_chat_mode_v1::conn::plain': 'chained',
      'voice_chat_mode_v1::conn::none': 'chained:unavailable',
      'voice_chat_mode_v1::conn::blocked': 'gpt-live:unavailable',
      'voice_live_status_v1::conn::broken': 'not json',
    });
    final prefs = await SharedPreferences.getInstance();
    final store = VoiceChatModeStore(prefs);

    final live = store.lastStatus('conn::live')!;
    expect(live.mode, VoiceLiveMode.gptLive);
    expect(live.available, isTrue);
    expect(store.lastStatus('conn::plain')!.mode, VoiceLiveMode.chained);
    // "Unavailable" alone could be a server without GPT-Live at all.
    expect(store.lastStatus('conn::none'), isNull);
    expect(store.lastStatus('conn::blocked'), isNull);
    expect(store.lastStatus('conn::broken'), isNull);
  });

  test('the memory-only store keeps the last status too', () {
    final store = VoiceChatModeStore.memory();
    store.remember(
      'conn::',
      const VoiceLiveStatus(
        mode: VoiceLiveMode.gptLive,
        available: false,
        reason: 'why',
      ),
    );
    expect(store.lastStatus('conn::')!.reason, 'why');
    store.remember('conn::', null);
    expect(store.lastStatus('conn::'), isNull);
  });
}
