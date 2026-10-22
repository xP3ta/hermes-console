import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/strings/oauth_callback_copy.dart';

void main() {
  test('callback tables have the exact same four nonempty keys', () {
    expect(oauthCallbackCatalogs.keys, unorderedEquals(['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']));
    for (final catalog in oauthCallbackCatalogs.values) {
      expect(catalog.keys, unorderedEquals(['successTitle', 'successBody', 'failureTitle', 'failureBody']));
      for (final value in catalog.values) {
        expect(value.trim(), isNotEmpty);
        expect(value, isNot(contains('{')));
      }
    }
  });
  test('first browser language resolves regions and defaults to English', () {
    expect(oauthCallbackLanguage('pt-BR,pt;q=0.9,en;q=0.8'), 'pt');
    expect(oauthCallbackLanguage('de-DE;q=0.9,en;q=0.8'), 'de');
    expect(oauthCallbackLanguage('zh-Hant-TW, en'), 'zh');
    expect(oauthCallbackLanguage('xx,es'), 'en');
    expect(oauthCallbackLanguage(null), 'en');
    expect(oauthCallbackLanguage('<script>'), 'en');
  });
  for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    test('$lang callback renders success and failure without request data', () {
      final (success, body, failure) = switch (lang) {
        'es' => ('Sesión iniciada', 'Puedes cerrar esta pestaña y volver a Console.', 'No se pudo completar el acceso'),
        'pt' => ('Sessão iniciada', 'Você pode fechar esta aba e voltar ao Console.', 'Não foi possível concluir o acesso'),
        _ => ('Signed in', 'You can close this tab and go back to Console.', "Sign-in didn't finish"),
      };
      final page = oauthCallbackPage(ok: true, lang: lang);
      expect(page, contains('<html lang="$lang">'));
      expect(page, contains('<title>$success</title>'));
      expect(page, contains('<p>$body</p>'));
      expect(oauthCallbackPage(ok: false, lang: lang), contains('<h1>$failure</h1>'));
    });
  }
  test('untrusted or unknown language cannot enter the HTML', () {
    const injection = '"><script>fixture</script>';
    final page = oauthCallbackPage(ok: false, lang: injection);
    expect(page, contains('<html lang="en">'));
    expect(page, isNot(contains(injection)));
  });
}
