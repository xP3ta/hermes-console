// Voice follows the app preference, with regional normalization and English fallback.
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

import 'voice_language.dart';

/// Clave del ajuste de idioma de la app. Duplicada de `AppLocales.prefKey`
/// (main.dart) a propósito: main.dart importa medio árbol de la app y este
/// módulo debe seguir siendo importable desde servicios puros y tests ligeros.
/// Hay un test que ancla que ambas no diverjan.
const String kAppLocalePrefKey = 'app_locale';

/// Supported app voice language; system/absent uses the device locale.
String effectiveVoiceLang(SharedPreferences prefs, {Locale? deviceLocale}) {
  final preference = prefs.getString(kAppLocalePrefKey);
  final code = preference == null || preference == 'system'
      ? (deviceLocale ?? PlatformDispatcher.instance.locale).languageCode
      : preference;
  return voiceLanguageFor(code).code;
}
