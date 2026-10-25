// Matriz de derivación del idioma de voz efectivo (spec 031, contrato §1 en
// contracts/voice-language-resolution.md). El locale del dispositivo se
// inyecta con `deviceLocale:` para no depender del host de test.
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/voice/voice_lang.dart';
import 'package:hermes_android/main.dart' show AppLocales;

Future<SharedPreferences> _prefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  const en = Locale('en', 'US');
  const es = Locale('es', 'ES');
  const fr = Locale('fr', 'FR');

  group('effectiveVoiceLang', () {
    test('es/en explícitos mandan, el dispositivo es irrelevante', () async {
      final prefsEs = await _prefs({kAppLocalePrefKey: 'es'});
      expect(effectiveVoiceLang(prefsEs, deviceLocale: en), 'es');
      expect(effectiveVoiceLang(prefsEs, deviceLocale: fr), 'es');

      final prefsEn = await _prefs({kAppLocalePrefKey: 'en'});
      expect(effectiveVoiceLang(prefsEn, deviceLocale: es), 'en');
      expect(effectiveVoiceLang(prefsEn, deviceLocale: fr), 'en');
    });

    test('system sigue al dispositivo: en → en, es → es', () async {
      final prefs = await _prefs({kAppLocalePrefKey: 'system'});
      expect(effectiveVoiceLang(prefs, deviceLocale: en), 'en');
      expect(effectiveVoiceLang(prefs, deviceLocale: es), 'es');
      // Variantes regionales del inglés también cuentan como inglés.
      expect(
        effectiveVoiceLang(prefs, deviceLocale: const Locale('en', 'GB')),
        'en',
      );
    });

    test('all nine system languages and regions resolve without Spanish fallback', () async {
      final prefs = await _prefs({kAppLocalePrefKey: 'system'});
      for (final code in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
        expect(effectiveVoiceLang(prefs, deviceLocale: Locale(code)), code);
        final explicit = await _prefs({kAppLocalePrefKey: '${code}_XX'});
        expect(effectiveVoiceLang(explicit, deviceLocale: es), code);
      }
      expect(effectiveVoiceLang(prefs, deviceLocale: const Locale('xx')), 'en');
    });

    test('português explícito manda e o sistema pt-BR é reconhecido', () async {
      final prefsPt = await _prefs({kAppLocalePrefKey: 'pt'});
      expect(effectiveVoiceLang(prefsPt, deviceLocale: en), 'pt');
      expect(effectiveVoiceLang(prefsPt, deviceLocale: fr), 'pt');

      final prefs = await _prefs({kAppLocalePrefKey: 'system'});
      expect(
        effectiveVoiceLang(prefs, deviceLocale: const Locale('pt', 'BR')),
        'pt',
      );
      expect(
        effectiveVoiceLang(prefs, deviceLocale: const Locale('pt', 'PT')),
        'pt',
      );
    });

    test('absent preference uses the device; unknown explicit preference uses English', () async {
      final ausente = await _prefs({});
      expect(effectiveVoiceLang(ausente, deviceLocale: en), 'en');
      expect(effectiveVoiceLang(ausente, deviceLocale: fr), 'fr');

      final raro = await _prefs({kAppLocalePrefKey: 'xx'});
      expect(effectiveVoiceLang(raro, deviceLocale: en), 'en');
      expect(effectiveVoiceLang(raro, deviceLocale: es), 'en');
    });

    test('la clave duplicada no diverge de AppLocales.prefKey', () {
      expect(kAppLocalePrefKey, AppLocales.prefKey);
    });
  });
}
