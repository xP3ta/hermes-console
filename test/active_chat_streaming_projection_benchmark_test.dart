import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/utils/assistant_content.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/long_streaming_transcript_fixture.dart';

/// Counts projection work per streaming tick on a ~300-row transcript (the
/// shape of the long session that stutters while the agent streams). Work is
/// counted, not timed, so the result does not depend on the shared host.
void main() {
  late ActiveChatService service;
  late ActiveChat chat;

  setUp(() {
    service = ActiveChatService();
    chat = service.attach(
      connection: SavedConnection(
        id: 'bench',
        label: 'Bench',
        host: '10.0.0.1',
        port: 8642,
        apiKey: 'k',
      ),
      sessionId: 'bench',
      sessionTitle: 'Bench',
      api: ApiClient(
        baseUrl: 'http://10.0.0.1:8642',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      ),
    );
    chat.replaceInternalMessagesForTesting([
      {'role': 'assistant', 'content': '', '_pipeline': true},
      ...longStreamingTranscriptNewestFirst(),
    ]);
    chat.state = ChatPipelineState.streaming;
    chat.messages;
  });
  tearDown(() => service.dispose());

  void tick(int index) {
    final rows = chat.internalMessagesForTesting;
    rows[0] = {
      ...rows[0],
      'content': '${rows[0]['content']}palabra $index ',
      '_pipeline': false,
    };
  }

  test('a streaming tick re-projects only the streaming row', () {
    expect(chat.internalMessagesForTesting.length, greaterThanOrEqualTo(300));
    debugPublicRowProjections = 0;
    debugAssistantProjectionInputChars = 0;
    const ticks = 30;
    for (var i = 0; i < ticks; i++) {
      tick(i);
      chat.messages;
    }
    // ignore: avoid_print
    print(
      'per tick: rows=${debugPublicRowProjections / ticks} '
      'assistantChars=${debugAssistantProjectionInputChars / ticks}',
    );
    expect(debugPublicRowProjections, ticks);
    expect(debugAssistantProjectionInputChars, 0);
  });

  test('repeated reads within one frame reuse the same snapshot', () {
    tick(0);
    final first = chat.messages;
    debugPublicRowProjections = 0;
    debugPublicTranscriptProjections = 0;
    for (var i = 0; i < 6; i++) {
      expect(identical(chat.messages, first), isTrue);
    }
    expect(debugPublicRowProjections, 0);
    expect(debugPublicTranscriptProjections, 0);
  });
}
