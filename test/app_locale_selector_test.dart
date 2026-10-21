import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show AppLocales, HermesApp;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the selector exposes every approved catalog in its native language', () {
    const expected = {
      'es': 'Español',
      'en': 'English',
      'zh': '中文',
      'pt_BR': 'Português (Brasil)',
      'de': 'Deutsch',
      'fr': 'Français',
      'ja': '日本語',
      'it': 'Italiano',
      'ko': '한국어',
    };
    expect(AppLocales.all.map((option) => option.id).toSet(), {
      'system',
      ...expected.keys,
    });
    for (final entry in expected.entries) {
      final option = AppLocales.byId(entry.key);
      expect(option.label, entry.value);
      expect(option.locale, isNotNull);
      expect(Strings.supportedLocales, contains(option.locale));
      final catalog = jsonDecode(
        File('lib/l10n/app_${entry.key}.arb').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(catalog['@@locale'], entry.key);
    }
  });

  test('unsupported saved choices use the system option', () {
    expect(AppLocales.byId('ru').id, 'system');
    expect(AppLocales.byId(null).locale, isNull);
  });

  test('all approved choices persist including the Brazilian region', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    for (final option in AppLocales.all) {
      await HermesApp.setLocaleId(prefs, option.id);
      expect(HermesApp.getLocaleId(prefs), option.id);
      expect(AppLocales.byId(HermesApp.getLocaleId(prefs)).locale, option.locale);
    }
  });

  test('manual and system locales resolve to installed catalogs', () {
    for (final locale in Strings.supportedLocales) {
      expect(AppLocales.resolve(locale, Strings.supportedLocales), locale);
    }
    expect(
      AppLocales.resolve(const Locale('zh', 'TW'), Strings.supportedLocales),
      const Locale('zh'),
    );
    expect(
      AppLocales.resolve(const Locale('pt', 'PT'), Strings.supportedLocales),
      const Locale('pt', 'BR'),
    );
    expect(
      AppLocales.resolve(const Locale('de', 'AT'), Strings.supportedLocales),
      const Locale('de'),
    );
    expect(AppLocales.resolve(null, Strings.supportedLocales), const Locale('en'));
    expect(
      AppLocales.resolve(const Locale('ru'), Strings.supportedLocales),
      const Locale('en'),
    );
  });

  test('resolution preserves an exact regional or script match', () {
    const supported = [
      Locale('en'),
      Locale('pt', 'BR'),
      Locale('pt', 'PT'),
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    ];
    expect(
      AppLocales.resolve(const Locale('pt', 'PT'), supported),
      const Locale('pt', 'PT'),
    );
    expect(
      AppLocales.resolve(
        const Locale.fromSubtags(
          languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW',
        ),
        supported,
      ),
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );
  });
}
