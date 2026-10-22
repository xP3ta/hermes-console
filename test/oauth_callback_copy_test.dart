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
        "de" => ("Angemeldet", "Du kannst diesen Tab schließen und zu Console zurückkehren.", "Anmeldung nicht abgeschlossen"),
        "fr" => ("Connexion réussie", "Tu peux fermer cet onglet et revenir à Console.", "La connexion n’a pas abouti"),
        "it" => ("Accesso effettuato", "Puoi chiudere questa scheda e tornare a Console.", "Accesso non completato"),
        "ja" => ("ログインしました", "このタブを閉じてConsoleに戻ってください。", "ログインが完了しませんでした"),
        "ko" => ("로그인 완료", "이 탭을 닫고 Console로 돌아가세요.", "로그인을 완료하지 못했습니다"),
        "zh" => ("已登录", "你可以关闭此标签页，返回Console。", "登录未完成"),
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
