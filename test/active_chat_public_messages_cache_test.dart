import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ActiveChat _chat(ActiveChatService service) => service.attach(
  connection: SavedConnection(
    id: 'cache',
    label: 'Cache',
    host: '10.0.0.1',
    port: 8642,
    apiKey: 'test',
  ),
  sessionId: 'cache-session',
  sessionTitle: 'Cache',
  api: ApiClient(
    baseUrl: 'http://10.0.0.1:8642',
    apiKey: 'test',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  ),
);

void main() {
  test('public transcript is reused while internal rows are unchanged', () {
    final service = ActiveChatService();
    addTearDown(service.dispose);
    final chat = _chat(service);
    chat.replaceInternalMessagesForTesting([
      {'message_id': 'a', 'role': 'assistant', 'content': 'A'},
      {'message_id': 'u', 'role': 'user', 'content': 'U'},
    ]);

    final first = chat.messages;
    expect(identical(chat.messages, first), isTrue);
  });

  test('public transcript recomputes after append, replace or mutation', () {
    final service = ActiveChatService();
    addTearDown(service.dispose);
    final chat = _chat(service);
    final row = <String, dynamic>{
      'message_id': 'a',
      'role': 'assistant',
      'content': 'A',
    };
    chat.replaceInternalMessagesForTesting([row]);
    final first = chat.messages;

    row['content'] = 'B';
    final mutated = chat.messages;
    expect(identical(mutated, first), isFalse);
    expect(mutated.single['content'], 'B');

    chat.replaceInternalMessagesForTesting([
      {'message_id': 'b', 'role': 'user', 'content': 'C'},
      row,
    ]);
    final appended = chat.messages;
    expect(appended, hasLength(2));
    expect(identical(chat.messages, appended), isTrue);
  });
}
