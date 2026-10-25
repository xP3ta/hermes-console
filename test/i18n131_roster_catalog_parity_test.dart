import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const keys = <String>{
    'i18n131RosterNow',
    'i18n131RosterYesterday'
  };
  Map<String, int> arguments(String value) {
    final result = <String, int>{};
    for (final match in RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}').allMatches(value)) {
      result.update(match.group(0)!, (n) => n + 1, ifAbsent: () => 1);
    }
    return result;
  }
  final catalogs = <String, Map<String, dynamic>>{
    for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'])
      lang: jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
          as Map<String, dynamic>,
  };
  test('exact class keys and placeholder multiplicity in all nine locales', () {
    for (final catalog in catalogs.values) {
      expect(catalog.keys.where((key) => key.startsWith('i18n131Roster')), unorderedEquals(keys));
      for (final key in keys) {
        expect((catalog[key] as String).trim(), isNotEmpty, reason: key);
        expect(arguments(catalog[key] as String), arguments(catalogs['en']![key] as String), reason: key);
      }
    }
  });
  test('generated accessors preserve literal and parameterized copy', () {
    expect(lookupStrings(const Locale('es')).i18n131RosterNow, "ahora");
    expect(lookupStrings(const Locale('en')).i18n131RosterNow, "now");
    expect(lookupStrings(const Locale('pt')).i18n131RosterNow, "agora");
    expect(lookupStrings(const Locale('de')).i18n131RosterNow, "jetzt");
    expect(lookupStrings(const Locale('fr')).i18n131RosterNow, "à l’instant");
    expect(lookupStrings(const Locale('it')).i18n131RosterNow, "ora");
    expect(lookupStrings(const Locale('ja')).i18n131RosterNow, "今");
    expect(lookupStrings(const Locale('ko')).i18n131RosterNow, "지금");
    expect(lookupStrings(const Locale('zh')).i18n131RosterNow, "现在");
    expect(lookupStrings(const Locale('es')).i18n131RosterYesterday, "ayer");
    expect(lookupStrings(const Locale('en')).i18n131RosterYesterday, "yesterday");
    expect(lookupStrings(const Locale('pt')).i18n131RosterYesterday, "ontem");
    expect(lookupStrings(const Locale('de')).i18n131RosterYesterday, "gestern");
    expect(lookupStrings(const Locale('fr')).i18n131RosterYesterday, "hier");
    expect(lookupStrings(const Locale('it')).i18n131RosterYesterday, "ieri");
    expect(lookupStrings(const Locale('ja')).i18n131RosterYesterday, "昨日");
    expect(lookupStrings(const Locale('ko')).i18n131RosterYesterday, "어제");
    expect(lookupStrings(const Locale('zh')).i18n131RosterYesterday, "昨天");
  });
}
