import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final placeholder = RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}');
  Set<String> args(String text) =>
      placeholder.allMatches(text).map((m) => m.group(0)!).toSet();

  test('nine notification catalogs have exact keys and placeholders', () {
    expect(notificationCatalogs.keys.toSet(),
        {'es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'});
    final english = notificationCatalogs['en']!;
    expect(english, isNotEmpty);
    for (final catalog in notificationCatalogs.entries) {
      expect(catalog.value.keys.toSet(), english.keys.toSet(),
          reason: catalog.key);
      for (final entry in catalog.value.entries) {
        expect(entry.value.trim(), isNotEmpty,
            reason: '${catalog.key}:${entry.key}');
        expect(args(entry.value), args(english[entry.key]!),
            reason: '${catalog.key}:${entry.key}');
      }
    }
  });

  test('explicit preference wins, unknown preference falls back to English', () async {
    for (final entry in {'es': 'es', 'de': 'de', 'pt_PT': 'pt',
      'zh-Hant-TW': 'zh', 'unknown': 'en'}.entries) {
      SharedPreferences.setMockInitialValues({'app_locale': entry.key});
      final prefs = await SharedPreferences.getInstance();
      expect(NotifL10n.of(prefs, deviceLocale: const Locale('fr')).lang,
          entry.value);
    }
  });

  test('system and absent preference use the supported device language', () async {
    for (final pref in [null, 'system']) {
      SharedPreferences.setMockInitialValues({'app_locale': ?pref});
      final prefs = await SharedPreferences.getInstance();
      expect(NotifL10n.of(prefs, deviceLocale: const Locale('ko')).lang, 'ko');
      expect(NotifL10n.of(prefs, deviceLocale: const Locale('xx')).lang, 'en');
    }
  });

  test('missing translation uses English and substitutions do not recurse', () {
    expect(notificationMessage('de', 'privateBody', translations: const {}),
        'Tap to see it');
    expect(notificationMessage('xx', 'privateBody'), 'Tap to see it');
    expect(const NotifL10n('en').replyTitle('{n}'), 'Hermes replied in {n}');
    expect(const NotifL10n(true).lang, 'es');
    expect(const NotifL10n(false).lang, 'en');
    expect(const NotifL10n(false, true).lang, 'pt');
    expect(const NotifL10n('pt').replyTitle('Backup'),
        'Hermes respondeu em Backup');
  });
}
