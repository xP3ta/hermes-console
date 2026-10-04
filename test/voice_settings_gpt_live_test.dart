import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('GPT-Live is off by default', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(const VoiceSettings().gptLiveEnabled, isFalse);
    expect(VoiceSettings.load(prefs).gptLiveEnabled, isFalse);
  });

  test('GPT-Live opt-in persists and round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await const VoiceSettings().copyWith(gptLiveEnabled: true).save(prefs);
    expect(prefs.getBool('voice_gpt_live_enabled_v1'), isTrue);
    expect(VoiceSettings.load(prefs).gptLiveEnabled, isTrue);
    await VoiceSettings.load(prefs).copyWith(gptLiveEnabled: false).save(prefs);
    expect(VoiceSettings.load(prefs).gptLiveEnabled, isFalse);
  });

  test('copyWith keeps GPT-Live when changing another setting', () {
    final settings = const VoiceSettings(
      gptLiveEnabled: true,
    ).copyWith(autoSpeak: true);
    expect(settings.gptLiveEnabled, isTrue);
  });
}
