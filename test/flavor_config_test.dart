import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/flavor.dart';

void main() {
  group('flavor config', () {
    test('el flavor efectivo coincide con el define de compilación', () {
      const requestedFlavor = String.fromEnvironment(
        'HERMES_FLAVOR',
        defaultValue: 'full',
      );
      expect(kHermesFlavor, requestedFlavor);
    });

    test('modo voz activo por defecto con rollback explícito', () {
      const disabled = bool.fromEnvironment(
        'HERMES_DISABLE_VOICE_MODE',
        defaultValue: false,
      );
      expect(kVoiceModeEnabled, !disabled);
      expect(kVoiceRuntimeEnabled, kVoiceModeEnabled || kVoiceQaHarnessEnabled);
    });
  });
}
