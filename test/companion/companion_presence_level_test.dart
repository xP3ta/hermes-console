import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/models/companion_presence_level.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CompanionPresenceLevel: where the pet shows', () {
    test('three choices; what the old ones become', () {
      expect(companionPresenceLevelFromId('off'), CompanionPresenceLevel.off);
      expect(companionPresenceLevelFromId('chat'), CompanionPresenceLevel.chat);
      expect(companionPresenceLevelFromId('app'), CompanionPresenceLevel.full);
      // Until 1.2.15: "Mínima" (the default) and "Completa".
      expect(
        companionPresenceLevelFromId('minimal'),
        CompanionPresenceLevel.full,
      );
      expect(companionPresenceLevelFromId('full'), CompanionPresenceLevel.full);
      // Nothing stored, or something unknown: on, everywhere.
      expect(companionPresenceLevelFromId(null), CompanionPresenceLevel.full);
      expect(companionPresenceLevelFromId(''), CompanionPresenceLevel.full);
      expect(
        companionPresenceLevelFromId('desconocido'),
        CompanionPresenceLevel.full,
      );
      // "ambient" is what a chat reads, never something stored.
      expect(
        companionPresenceLevelFromId('ambient'),
        CompanionPresenceLevel.full,
      );
    });

    test('only the old "Completa" is the legacy full', () {
      expect(companionPresenceIsLegacyFull('full'), isTrue);
      expect(companionPresenceIsLegacyFull('app'), isFalse);
      expect(companionPresenceIsLegacyFull('minimal'), isFalse);
      expect(companionPresenceIsLegacyFull(null), isFalse);
    });

    test('what each one shows', () {
      const off = CompanionPresenceLevel.off;
      const ambient = CompanionPresenceLevel.ambient;
      const chat = CompanionPresenceLevel.chat;
      const full = CompanionPresenceLevel.full;
      expect(
        [
          for (final l in [off, ambient, chat, full]) l.isVisible,
        ],
        [false, true, true, true],
      );
      // The pet on the chat's island.
      expect(
        [
          for (final l in [off, ambient, chat, full]) l.showsStatusPresence,
        ],
        [false, false, true, true],
      );
      // The pet floating outside chats.
      expect(
        [
          for (final l in [off, ambient, chat, full]) l.showsEverywhere,
        ],
        [false, false, false, true],
      );
    });

    test('a choice made now is stored under its own name', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final p = CompanionPreferences(prefs);
      expect(p.presenceLevel, CompanionPresenceLevel.full);
      expect(p.presenceIsLegacyFull, isFalse);
      await p.setPresenceLevel(CompanionPresenceLevel.chat);
      expect(prefs.getString(CompanionPreferences.presenceLevelKey), 'chat');
      expect(p.presenceLevel, CompanionPresenceLevel.chat);
      await p.setPresenceLevel(CompanionPresenceLevel.full);
      expect(prefs.getString(CompanionPreferences.presenceLevelKey), 'app');
      expect(p.presenceLevel, CompanionPresenceLevel.full);
      expect(p.presenceIsLegacyFull, isFalse);
      await p.setPresenceLevel(CompanionPresenceLevel.off);
      expect(p.presenceLevel, CompanionPresenceLevel.off);
    });

    test('a stored "Completa" keeps being read as the legacy full', () async {
      SharedPreferences.setMockInitialValues({
        CompanionPreferences.presenceLevelKey: 'full',
      });
      final p = CompanionPreferences(await SharedPreferences.getInstance());
      expect(p.presenceLevel, CompanionPresenceLevel.full);
      expect(p.presenceIsLegacyFull, isTrue);
    });
  });
}
