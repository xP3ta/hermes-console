import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const keys = <String>{
    'i18n131ChatBusy',
    'i18n131ChatNotOwned',
    'i18n131ChatLimit',
    'i18n131ChatCoordination',
    'i18n131ChatSendFailed',
    'i18n131ChatStoredNotOwned',
    'i18n131ChatStoredFailed',
    'i18n131ChatStoredDisconnected',
    'i18n131ChatRecoveryFailed',
    'i18n131ChatFailureCause'
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
      expect(catalog.keys.where((key) => key.startsWith('i18n131Chat')), unorderedEquals(keys));
      for (final key in keys) {
        expect((catalog[key] as String).trim(), isNotEmpty, reason: key);
        expect(arguments(catalog[key] as String), arguments(catalogs['en']![key] as String), reason: key);
      }
    }
  });
  test('generated accessors preserve literal and parameterized copy', () {
    expect(lookupStrings(const Locale('es')).i18n131ChatBusy, "Hermes está ocupado (por ejemplo, compactando la conversación). Tu mensaje sigue en el composer: inténtalo en un momento.");
    expect(lookupStrings(const Locale('en')).i18n131ChatBusy, "Hermes is busy (for example, compacting this conversation). Your message is still in the composer; try again in a moment.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatBusy, "O Hermes está ocupado (por exemplo, compactando esta conversa). Sua mensagem continua no campo de composição; tente novamente em instantes.");
    expect(lookupStrings(const Locale('de')).i18n131ChatBusy, "Hermes ist beschäftigt (zum Beispiel mit dem Komprimieren dieses Gesprächs). Deine Nachricht ist noch im Eingabefeld; versuche es gleich noch einmal.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatBusy, "Hermes est occupé (par exemple, à compacter cette conversation). Ton message est toujours dans la zone de saisie ; réessaie dans un instant.");
    expect(lookupStrings(const Locale('it')).i18n131ChatBusy, "Hermes è occupato (ad esempio, sta compattando questa conversazione). Il messaggio è ancora nel campo di scrittura; riprova tra poco.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatBusy, "Hermesは処理中です（会話の圧縮など）。メッセージは入力欄に残っています。少し待って再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatBusy, "Hermes가 다른 작업을 처리 중입니다(예: 이 대화의 컨텍스트 압축). 메시지는 입력창에 남아 있습니다. 잠시 후 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatBusy, "Hermes正忙（例如正在压缩此对话）。消息仍保留在输入框中，请稍后重试。");
    expect(lookupStrings(const Locale('es')).i18n131ChatNotOwned, "No se puede continuar en directo porque esta conversación pertenece a otro gateway o proceso. El historial se conserva y puedes iniciar un chat nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatNotOwned, "This conversation can’t continue live because it belongs to another gateway or process. Its history remains available, and you can still start a new chat.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatNotOwned, "Esta conversa não pode continuar ao vivo porque pertence a outro gateway ou processo. O histórico continua disponível e você pode iniciar uma nova conversa.");
    expect(lookupStrings(const Locale('de')).i18n131ChatNotOwned, "Dieses Gespräch kann nicht live fortgesetzt werden, da es zu einem anderen Gateway oder Prozess gehört. Der Verlauf bleibt verfügbar und du kannst einen neuen Chat starten.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatNotOwned, "Cette conversation ne peut pas continuer en direct, car elle appartient à une autre passerelle ou à un autre processus. Son historique reste accessible et tu peux démarrer une nouvelle conversation.");
    expect(lookupStrings(const Locale('it')).i18n131ChatNotOwned, "Questa conversazione non può proseguire in tempo reale perché appartiene a un altro gateway o processo. La cronologia resta disponibile e puoi comunque avviare una nuova chat.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatNotOwned, "この会話は別のゲートウェイまたはプロセスに属しているため、このまま続けられません。履歴の閲覧や新しいチャットの開始はできます。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatNotOwned, "이 대화는 다른 게이트웨이나 프로세스에 속해 있어 실시간으로 이어갈 수 없습니다. 기록은 계속 볼 수 있으며 새 대화를 시작할 수도 있습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatNotOwned, "此对话属于另一网关或进程，无法继续实时对话。你仍可查看历史记录或新建对话。");
    expect(lookupStrings(const Locale('es')).i18n131ChatLimit, "Hermes alcanzó el límite configurado de sesiones activas. Espera a que termine una sesión o ajusta el límite.");
    expect(lookupStrings(const Locale('en')).i18n131ChatLimit, "Hermes reached the configured active-session limit. Wait for a session to finish or adjust the limit.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatLimit, "O Hermes atingiu o limite configurado de sessões ativas. Aguarde uma sessão terminar ou ajuste o limite.");
    expect(lookupStrings(const Locale('de')).i18n131ChatLimit, "Hermes hat die konfigurierte Grenze für aktive Sitzungen erreicht. Warte, bis eine Sitzung endet, oder passe die Grenze an.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatLimit, "Hermes a atteint la limite configurée de sessions actives. Attends qu’une session se termine ou ajuste la limite.");
    expect(lookupStrings(const Locale('it')).i18n131ChatLimit, "Hermes ha raggiunto il limite configurato di sessioni attive. Attendi che una sessione termini oppure modifica il limite.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatLimit, "Hermesのアクティブセッション数が設定上限に達しました。セッションの終了を待つか、上限を調整してください。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatLimit, "Hermes가 설정된 활성 세션 한도에 도달했습니다. 세션이 끝날 때까지 기다리거나 한도를 조정하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatLimit, "Hermes已达到设置的活跃会话上限。请等待会话结束，或调整上限。");
    expect(lookupStrings(const Locale('es')).i18n131ChatCoordination, "Hermes no pudo reservar esta conversación con seguridad. Revisa el servidor y vuelve a intentarlo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatCoordination, "Hermes could not safely reserve this conversation. Check the server and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatCoordination, "O Hermes não pôde reservar esta conversa com segurança. Verifique o servidor e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatCoordination, "Hermes konnte dieses Gespräch nicht sicher reservieren. Prüfe den Server und versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatCoordination, "Hermes n’a pas pu réserver cette conversation de façon sûre. Vérifie le serveur et réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131ChatCoordination, "Hermes non ha potuto riservare questa conversazione in sicurezza. Controlla il server e riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatCoordination, "Hermesはこの会話を安全に確保できませんでした。サーバーを確認して再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatCoordination, "Hermes가 이 대화를 안전하게 확보하지 못했습니다. 서버를 확인한 후 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatCoordination, "Hermes无法安全锁定此对话。请检查服务器后重试。");
    expect(lookupStrings(const Locale('es')).i18n131ChatSendFailed, "No se pudo enviar el mensaje. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatSendFailed, "The message could not be sent. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatSendFailed, "Não foi possível enviar a mensagem. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatSendFailed, "Die Nachricht konnte nicht gesendet werden. Versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatSendFailed, "Impossible d’envoyer le message. Réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131ChatSendFailed, "Impossibile inviare il messaggio. Riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatSendFailed, "メッセージを送信できませんでした。再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatSendFailed, "메시지를 보내지 못했습니다. 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatSendFailed, "消息发送失败，请重试。");
    expect(lookupStrings(const Locale('es')).i18n131ChatStoredNotOwned, "No se puede continuar esta conversación en directo. El historial se conserva y puedes iniciar un chat nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatStoredNotOwned, "This conversation cannot continue live. Its history remains available and you can start a new chat.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatStoredNotOwned, "Esta conversa não pode continuar ao vivo. O histórico continua disponível e você pode iniciar uma nova conversa.");
    expect(lookupStrings(const Locale('de')).i18n131ChatStoredNotOwned, "Dieses Gespräch kann nicht live fortgesetzt werden. Der Verlauf bleibt verfügbar und du kannst einen neuen Chat starten.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatStoredNotOwned, "Cette conversation ne peut pas continuer en direct. Son historique reste accessible et tu peux démarrer une nouvelle conversation.");
    expect(lookupStrings(const Locale('it')).i18n131ChatStoredNotOwned, "Questa conversazione non può proseguire in tempo reale. La cronologia resta disponibile e puoi avviare una nuova chat.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatStoredNotOwned, "この会話はこのまま続けられません。履歴の閲覧や新しいチャットの開始はできます。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatStoredNotOwned, "이 대화를 실시간으로 이어갈 수 없습니다. 기록은 계속 볼 수 있으며 새 대화를 시작할 수 있습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatStoredNotOwned, "此对话无法继续实时进行。你仍可查看历史记录或新建对话。");
    expect(lookupStrings(const Locale('es')).i18n131ChatStoredFailed, "No se pudo completar la respuesta. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatStoredFailed, "The response could not be completed. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatStoredFailed, "Não foi possível concluir a resposta. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatStoredFailed, "Die Antwort konnte nicht abgeschlossen werden. Versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatStoredFailed, "Impossible de terminer la réponse. Réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131ChatStoredFailed, "Impossibile completare la risposta. Riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatStoredFailed, "応答を完了できませんでした。再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatStoredFailed, "응답을 완료하지 못했습니다. 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatStoredFailed, "无法完成回复，请重试。");
    expect(lookupStrings(const Locale('es')).i18n131ChatStoredDisconnected, "Se perdió la conexión con Hermes. El mensaje no se confirmó; revisa el borrador y reintenta.");
    expect(lookupStrings(const Locale('en')).i18n131ChatStoredDisconnected, "The connection with Hermes was lost. The message was not confirmed; review the draft and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatStoredDisconnected, "A conexão com o Hermes foi perdida. A mensagem não foi confirmada; revise o rascunho e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatStoredDisconnected, "Die Verbindung zu Hermes wurde unterbrochen. Die Nachricht wurde nicht bestätigt; prüfe den Entwurf und versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatStoredDisconnected, "La connexion avec Hermes a été perdue. Le message n’a pas été confirmé ; vérifie le brouillon et réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131ChatStoredDisconnected, "La connessione con Hermes è stata interrotta. Il messaggio non è stato confermato; controlla la bozza e riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatStoredDisconnected, "Hermesとの接続が切れました。メッセージの送信は確認できていません。下書きを確認して再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatStoredDisconnected, "Hermes와의 연결이 끊겼습니다. 메시지 전송이 확인되지 않았습니다. 초안을 확인한 후 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatStoredDisconnected, "与Hermes的连接已断开，消息尚未确认。请检查草稿后重试。");
    expect(lookupStrings(const Locale('es')).i18n131ChatRecoveryFailed, "No se pudo recuperar el turno. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatRecoveryFailed, "The turn could not be recovered. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatRecoveryFailed, "Não foi possível recuperar o turno. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatRecoveryFailed, "Die Runde konnte nicht wiederhergestellt werden. Versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatRecoveryFailed, "Impossible de récupérer le tour. Réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131ChatRecoveryFailed, "Impossibile recuperare il turno. Riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatRecoveryFailed, "ターンを復旧できませんでした。再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131ChatRecoveryFailed, "대화 차례를 복구하지 못했습니다. 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatRecoveryFailed, "无法恢复本轮对话，请重试。");
    expect(lookupStrings(const Locale('es')).i18n131ChatFailureCause("value {other}"), "No se pudo completar la respuesta: value {other}");
    expect(lookupStrings(const Locale('en')).i18n131ChatFailureCause("value {other}"), "The response could not be completed: value {other}");
    expect(lookupStrings(const Locale('pt')).i18n131ChatFailureCause("value {other}"), "Não foi possível concluir a resposta: value {other}");
    expect(lookupStrings(const Locale('de')).i18n131ChatFailureCause("value {other}"), "Die Antwort konnte nicht abgeschlossen werden: value {other}");
    expect(lookupStrings(const Locale('fr')).i18n131ChatFailureCause("value {other}"), "Impossible de terminer la réponse : value {other}");
    expect(lookupStrings(const Locale('it')).i18n131ChatFailureCause("value {other}"), "Impossibile completare la risposta: value {other}");
    expect(lookupStrings(const Locale('ja')).i18n131ChatFailureCause("value {other}"), "応答を完了できませんでした：value {other}");
    expect(lookupStrings(const Locale('ko')).i18n131ChatFailureCause("value {other}"), "응답을 완료하지 못했습니다: value {other}");
    expect(lookupStrings(const Locale('zh')).i18n131ChatFailureCause("value {other}"), "无法完成回复：value {other}");
  });
}
