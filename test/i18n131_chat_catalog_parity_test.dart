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
    expect(lookupStrings(const Locale('de')).i18n131ChatBusy, "Hermes is busy (for example, compacting this conversation). Your message is still in the composer; try again in a moment.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatBusy, "Hermes is busy (for example, compacting this conversation). Your message is still in the composer; try again in a moment.");
    expect(lookupStrings(const Locale('it')).i18n131ChatBusy, "Hermes is busy (for example, compacting this conversation). Your message is still in the composer; try again in a moment.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatBusy, "Hermes is busy (for example, compacting this conversation). Your message is still in the composer; try again in a moment.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatBusy, "Hermes is busy (for example, compacting this conversation). Your message is still in the composer; try again in a moment.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatBusy, "Hermes is busy (for example, compacting this conversation). Your message is still in the composer; try again in a moment.");
    expect(lookupStrings(const Locale('es')).i18n131ChatNotOwned, "No se puede continuar en directo porque esta conversación pertenece a otro gateway o proceso. El historial se conserva y puedes iniciar un chat nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatNotOwned, "This conversation can’t continue live because it belongs to another gateway or process. Its history remains available, and you can still start a new chat.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatNotOwned, "Esta conversa não pode continuar ao vivo porque pertence a outro gateway ou processo. O histórico continua disponível e você pode iniciar uma nova conversa.");
    expect(lookupStrings(const Locale('de')).i18n131ChatNotOwned, "This conversation can’t continue live because it belongs to another gateway or process. Its history remains available, and you can still start a new chat.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatNotOwned, "This conversation can’t continue live because it belongs to another gateway or process. Its history remains available, and you can still start a new chat.");
    expect(lookupStrings(const Locale('it')).i18n131ChatNotOwned, "This conversation can’t continue live because it belongs to another gateway or process. Its history remains available, and you can still start a new chat.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatNotOwned, "This conversation can’t continue live because it belongs to another gateway or process. Its history remains available, and you can still start a new chat.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatNotOwned, "This conversation can’t continue live because it belongs to another gateway or process. Its history remains available, and you can still start a new chat.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatNotOwned, "This conversation can’t continue live because it belongs to another gateway or process. Its history remains available, and you can still start a new chat.");
    expect(lookupStrings(const Locale('es')).i18n131ChatLimit, "Hermes alcanzó el límite configurado de sesiones activas. Espera a que termine una sesión o ajusta el límite.");
    expect(lookupStrings(const Locale('en')).i18n131ChatLimit, "Hermes reached the configured active-session limit. Wait for a session to finish or adjust the limit.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatLimit, "O Hermes atingiu o limite configurado de sessões ativas. Aguarde uma sessão terminar ou ajuste o limite.");
    expect(lookupStrings(const Locale('de')).i18n131ChatLimit, "Hermes reached the configured active-session limit. Wait for a session to finish or adjust the limit.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatLimit, "Hermes reached the configured active-session limit. Wait for a session to finish or adjust the limit.");
    expect(lookupStrings(const Locale('it')).i18n131ChatLimit, "Hermes reached the configured active-session limit. Wait for a session to finish or adjust the limit.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatLimit, "Hermes reached the configured active-session limit. Wait for a session to finish or adjust the limit.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatLimit, "Hermes reached the configured active-session limit. Wait for a session to finish or adjust the limit.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatLimit, "Hermes reached the configured active-session limit. Wait for a session to finish or adjust the limit.");
    expect(lookupStrings(const Locale('es')).i18n131ChatCoordination, "Hermes no pudo reservar esta conversación con seguridad. Revisa el servidor y vuelve a intentarlo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatCoordination, "Hermes could not safely reserve this conversation. Check the server and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatCoordination, "O Hermes não pôde reservar esta conversa com segurança. Verifique o servidor e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatCoordination, "Hermes could not safely reserve this conversation. Check the server and try again.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatCoordination, "Hermes could not safely reserve this conversation. Check the server and try again.");
    expect(lookupStrings(const Locale('it')).i18n131ChatCoordination, "Hermes could not safely reserve this conversation. Check the server and try again.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatCoordination, "Hermes could not safely reserve this conversation. Check the server and try again.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatCoordination, "Hermes could not safely reserve this conversation. Check the server and try again.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatCoordination, "Hermes could not safely reserve this conversation. Check the server and try again.");
    expect(lookupStrings(const Locale('es')).i18n131ChatSendFailed, "No se pudo enviar el mensaje. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatSendFailed, "The message could not be sent. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatSendFailed, "Não foi possível enviar a mensagem. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatSendFailed, "The message could not be sent. Try again.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatSendFailed, "The message could not be sent. Try again.");
    expect(lookupStrings(const Locale('it')).i18n131ChatSendFailed, "The message could not be sent. Try again.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatSendFailed, "The message could not be sent. Try again.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatSendFailed, "The message could not be sent. Try again.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatSendFailed, "The message could not be sent. Try again.");
    expect(lookupStrings(const Locale('es')).i18n131ChatStoredNotOwned, "No se puede continuar esta conversación en directo. El historial se conserva y puedes iniciar un chat nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatStoredNotOwned, "This conversation cannot continue live. Its history remains available and you can start a new chat.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatStoredNotOwned, "Esta conversa não pode continuar ao vivo. O histórico continua disponível e você pode iniciar uma nova conversa.");
    expect(lookupStrings(const Locale('de')).i18n131ChatStoredNotOwned, "This conversation cannot continue live. Its history remains available and you can start a new chat.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatStoredNotOwned, "This conversation cannot continue live. Its history remains available and you can start a new chat.");
    expect(lookupStrings(const Locale('it')).i18n131ChatStoredNotOwned, "This conversation cannot continue live. Its history remains available and you can start a new chat.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatStoredNotOwned, "This conversation cannot continue live. Its history remains available and you can start a new chat.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatStoredNotOwned, "This conversation cannot continue live. Its history remains available and you can start a new chat.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatStoredNotOwned, "This conversation cannot continue live. Its history remains available and you can start a new chat.");
    expect(lookupStrings(const Locale('es')).i18n131ChatStoredFailed, "No se pudo completar la respuesta. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatStoredFailed, "The response could not be completed. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatStoredFailed, "Não foi possível concluir a resposta. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatStoredFailed, "The response could not be completed. Try again.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatStoredFailed, "The response could not be completed. Try again.");
    expect(lookupStrings(const Locale('it')).i18n131ChatStoredFailed, "The response could not be completed. Try again.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatStoredFailed, "The response could not be completed. Try again.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatStoredFailed, "The response could not be completed. Try again.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatStoredFailed, "The response could not be completed. Try again.");
    expect(lookupStrings(const Locale('es')).i18n131ChatStoredDisconnected, "Se perdió la conexión con Hermes. El mensaje no se confirmó; revisa el borrador y reintenta.");
    expect(lookupStrings(const Locale('en')).i18n131ChatStoredDisconnected, "The connection with Hermes was lost. The message was not confirmed; review the draft and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatStoredDisconnected, "A conexão com o Hermes foi perdida. A mensagem não foi confirmada; revise o rascunho e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatStoredDisconnected, "The connection with Hermes was lost. The message was not confirmed; review the draft and try again.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatStoredDisconnected, "The connection with Hermes was lost. The message was not confirmed; review the draft and try again.");
    expect(lookupStrings(const Locale('it')).i18n131ChatStoredDisconnected, "The connection with Hermes was lost. The message was not confirmed; review the draft and try again.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatStoredDisconnected, "The connection with Hermes was lost. The message was not confirmed; review the draft and try again.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatStoredDisconnected, "The connection with Hermes was lost. The message was not confirmed; review the draft and try again.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatStoredDisconnected, "The connection with Hermes was lost. The message was not confirmed; review the draft and try again.");
    expect(lookupStrings(const Locale('es')).i18n131ChatRecoveryFailed, "No se pudo recuperar el turno. Inténtalo de nuevo.");
    expect(lookupStrings(const Locale('en')).i18n131ChatRecoveryFailed, "The turn could not be recovered. Try again.");
    expect(lookupStrings(const Locale('pt')).i18n131ChatRecoveryFailed, "Não foi possível recuperar o turno. Tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ChatRecoveryFailed, "The turn could not be recovered. Try again.");
    expect(lookupStrings(const Locale('fr')).i18n131ChatRecoveryFailed, "The turn could not be recovered. Try again.");
    expect(lookupStrings(const Locale('it')).i18n131ChatRecoveryFailed, "The turn could not be recovered. Try again.");
    expect(lookupStrings(const Locale('ja')).i18n131ChatRecoveryFailed, "The turn could not be recovered. Try again.");
    expect(lookupStrings(const Locale('ko')).i18n131ChatRecoveryFailed, "The turn could not be recovered. Try again.");
    expect(lookupStrings(const Locale('zh')).i18n131ChatRecoveryFailed, "The turn could not be recovered. Try again.");
    expect(lookupStrings(const Locale('es')).i18n131ChatFailureCause("value {other}"), "No se pudo completar la respuesta: value {other}");
    expect(lookupStrings(const Locale('en')).i18n131ChatFailureCause("value {other}"), "The response could not be completed: value {other}");
    expect(lookupStrings(const Locale('pt')).i18n131ChatFailureCause("value {other}"), "Não foi possível concluir a resposta: value {other}");
    expect(lookupStrings(const Locale('de')).i18n131ChatFailureCause("value {other}"), "The response could not be completed: value {other}");
    expect(lookupStrings(const Locale('fr')).i18n131ChatFailureCause("value {other}"), "The response could not be completed: value {other}");
    expect(lookupStrings(const Locale('it')).i18n131ChatFailureCause("value {other}"), "The response could not be completed: value {other}");
    expect(lookupStrings(const Locale('ja')).i18n131ChatFailureCause("value {other}"), "The response could not be completed: value {other}");
    expect(lookupStrings(const Locale('ko')).i18n131ChatFailureCause("value {other}"), "The response could not be completed: value {other}");
    expect(lookupStrings(const Locale('zh')).i18n131ChatFailureCause("value {other}"), "The response could not be completed: value {other}");
  });
}
