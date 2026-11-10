// The profile's `voice.thinking_sound` and `voice.beep_volume` are still
// read like Desktop's (`voice-prefs.ts:148-157`, `tools/voice_mode.py`), but
// QA 9709 (the owner): Console plays nothing while the agent works, whatever they
// say (`local_voice_conversation_controller_test`, «silent while it works»).
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_server_prefs.dart';

void main() {
  group('voice.thinking_sound and voice.beep_volume', () {
    Map<String, Object?> voice(Map<String, Object?> v) => {'voice': v};

    test('on unless explicitly false (voice-prefs.ts:148-157)', () {
      expect(voiceThinkingSoundFromConfig(voice({})), isTrue);
      expect(
        voiceThinkingSoundFromConfig(voice({'thinking_sound': true})),
        isTrue,
      );
      expect(
        voiceThinkingSoundFromConfig(voice({'thinking_sound': false})),
        isFalse,
      );
    });

    test('silent until the profile config is read', () {
      expect(VoiceServerPrefs.desktopDefaults.thinkingSound, isFalse);
      expect(
        VoiceServerPrefs.fromServerConfig(voice({}), null).thinkingSound,
        isTrue,
      );
    });

    test('beep_volume like the backend: 0.0-1.0, else 0.3', () {
      double read(Object? value) =>
          voiceBeepVolumeFromConfig(voice({'beep_volume': value}));
      expect(read(0.5), 0.5);
      expect(read(0), 0);
      expect(read(1), 1);
      expect(read('0.7'), 0.7);
      for (final bad in [null, true, -0.1, 1.5, 'loud', double.nan]) {
        expect(read(bad), kDefaultVoiceBeepVolume, reason: '$bad');
      }
    });
  });
}
