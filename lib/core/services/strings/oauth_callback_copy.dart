import '../notifications/notification_strings.dart' show resolveNotificationLang;

import 'oauth_callback_es.dart';
import 'oauth_callback_en.dart';
import 'oauth_callback_pt.dart';
import 'oauth_callback_de.dart';
import 'oauth_callback_fr.dart';
import 'oauth_callback_it.dart';
import 'oauth_callback_ja.dart';
import 'oauth_callback_ko.dart';
import 'oauth_callback_zh.dart';

const oauthCallbackCatalogs = <String, Map<String, String>>{
  'es': oauthCallbackEs,
  'en': oauthCallbackEn,
  'pt': oauthCallbackPt,
  'de': oauthCallbackDe,
  'fr': oauthCallbackFr,
  'it': oauthCallbackIt,
  'ja': oauthCallbackJa,
  'ko': oauthCallbackKo,
  'zh': oauthCallbackZh,
};

/// The first browser preference, using the same regional fallback as the UI.
String oauthCallbackLanguage(String? acceptLanguage) => resolveNotificationLang(
  (acceptLanguage ?? '').split(',').first.split(';').first.trim(),
);

/// Static loopback page: request parameters and secrets never enter the HTML.
String oauthCallbackPage({required bool ok, required String lang}) {
  lang = resolveNotificationLang(lang);
  final copy = oauthCallbackCatalogs[lang]!;
  final prefix = ok ? 'success' : 'failure';
  final title = copy['${prefix}Title'] ?? oauthCallbackEn['${prefix}Title']!;
  final body = copy['${prefix}Body'] ?? oauthCallbackEn['${prefix}Body']!;
  return '<!doctype html><html lang="$lang"><head>'
      '<meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<meta name="color-scheme" content="light dark">'
      '<title>$title</title><style>'
      ':root{color-scheme:light dark}'
      'body{margin:0;min-height:100vh;display:grid;place-items:center;'
      'font:18px/1.5 system-ui,sans-serif;background:#faf7f2;color:#2b2b2b}'
      'main{padding:24px;max-width:28em;text-align:center}'
      'h1{font-size:1.5em;margin:0 0 .5em}p{margin:0;font-size:1em}'
      '@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#eeeae4}}'
      '</style></head><body><main><h1>$title</h1><p>$body</p></main></body></html>';
}
