import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

void main() {
  for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    test('$lang local errors use UI language and keep arbitrary content intact', () {
      const unknown = TuiGatewayRpcError('prompt.submit', 'private provider detail', code: 5001);
      final expected = switch (lang) {
        'es' => 'No se pudo enviar el mensaje. Inténtalo de nuevo.',
        'pt' => 'Não foi possível enviar a mensagem. Tente novamente.',
        _ => 'The message could not be sent. Try again.',
      };
      expect(activeChatPromptFailureUiMessage(unknown, languageCode: lang), expected);
      expect(activeChatStoredErrorUiMessage('No se pudo enviar el mensaje. Inténtalo de nuevo.', languageCode: lang), expected);
      for (final reason in ['SESSION_NOT_OWNED', 'MAX_CONCURRENT_SESSIONS', 'SESSION_COORDINATION_UNAVAILABLE']) {
        final error = TuiGatewayRpcError('prompt.submit', 'private provider detail', code: 4090, data: {'reason': reason});
        final display = activeChatPromptFailureUiMessage(error, languageCode: lang);
        expect(display, isNot(contains('private provider detail')));
        expect(activeChatStoredErrorUiMessage(activeChatPromptFailureUiMessage(error, languageCode: 'es'), languageCode: lang), display);
      }
      const opaque = 'Unclassified provider message {cause}';
      expect(activeChatStoredErrorUiMessage(opaque, languageCode: lang), opaque);
      final cause = activeChatStoredErrorUiMessage('No se pudo completar la respuesta: safe {cause}', languageCode: lang);
      expect(cause, contains('safe {cause}'));
      expect(activeChatStoredErrorUiMessage('SocketException: private fixture', languageCode: lang), isNot(contains('private fixture')));
      expect(activeChatStoredErrorUiMessage('No se pudo completar la respuesta: SocketException private fixture', languageCode: lang), isNot(contains('private fixture')));
    });
  }
  test('absent and unknown language use English', () {
    expect(activeChatPromptFailureUiMessage(StateError('fixture')), 'The message could not be sent. Try again.');
    expect(activeChatStoredErrorUiMessage('Hermes reported an error'), 'The response could not be completed. Try again.');
    expect(activeChatPromptFailureUiMessage(StateError('fixture'), languageCode: 'xx'), 'The message could not be sent. Try again.');
  });
}
