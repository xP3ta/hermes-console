import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/screens/foreground_conversation_reader.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

import 'support/in_memory_compression_fence_storage.dart';

SavedConnection connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: 'example.test',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
);

ApiClient api() => ApiClient(
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

Map<String, dynamic> user(String id) => {
  'message_id': id,
  'role': 'user',
  'content': id,
};

Map<String, dynamic> assistant(String id) => {
  'message_id': id,
  'role': 'assistant',
  'content': id,
};

void main() {
  test(
    'resume reserva el chat visible antes de esperar a otro chat lento',
    () async {
      final service = ActiveChatService(
        compressionFenceStore: testCompressionFenceStore(),
      );
      addTearDown(service.dispose);

      final releaseEarlierResume = Completer<List<Map<String, dynamic>>>();
      var earlierReads = 0;
      final earlier = service.attach(
        connection: connection('conn-resume-order'),
        sessionId: 'earlier',
        sessionTitle: 'earlier',
        api: api(),
        storedMessageLoader: (_, _) {
          earlierReads += 1;
          if (earlierReads == 1) {
            return Future.value([user('earlier-user')]);
          }
          return releaseEarlierResume.future;
        },
        disableForegroundKeepAlive: true,
      );

      var visibleReads = 0;
      final visible = service.attach(
        connection: connection('conn-resume-order'),
        sessionId: 'visible',
        sessionTitle: 'visible',
        api: api(),
        storedMessageLoader: (_, _) {
          visibleReads += 1;
          if (visibleReads == 1) {
            return Future.value([user('visible-user')]);
          }
          if (visibleReads == 2) {
            return Future.value([
              user('visible-user'),
              assistant('new-visible-row'),
            ]);
          }
          throw StateError('lectura visible solapada inesperada');
        },
        disableForegroundKeepAlive: true,
      );

      await earlier.loadMessages();
      await visible.loadMessages();
      earlier.state = ChatPipelineState.completed;
      visible.state = ChatPipelineState.completed;

      final globalResume = service.reconcileAfterResume();
      await Future<void>.delayed(Duration.zero);
      expect(earlier.resumeReconciliationInFlight, isTrue);
      expect(
        visible.resumeReconciliationInFlight,
        isTrue,
        reason: 'el chat visible debe quedar reservado antes del await serial',
      );

      final reader = ForegroundConversationReader(
        successInterval: const Duration(seconds: 3),
        failureIntervals: const [Duration(seconds: 5)],
        canRead: () => !visible.resumeReconciliationInFlight,
        read: () async {
          await visible.loadMessages(passiveOnly: true);
          return true;
        },
      );
      addTearDown(reader.dispose);
      reader.setVisible(true);

      await Future<void>.delayed(const Duration(milliseconds: 3100));
      expect(
        visibleReads,
        1,
        reason: 'el polling no debe adelantarse a la reconciliación reservada',
      );

      releaseEarlierResume.complete([user('earlier-user')]);
      await globalResume;
      expect(visibleReads, 2);
      expect(
        visible.messages.any(
          (message) => message['content'] == 'new-visible-row',
        ),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
