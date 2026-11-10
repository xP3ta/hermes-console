import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

/// qrc: on a resume the chat on screen reconciles first; the covered chats
/// wait [ActiveChatService.resumeFanoutStagger] so their reads do not
/// compete with the visible chat's probe, ticket and first read.

SavedConnection _connection() => SavedConnection(
  id: 'conn-qrc-stagger',
  label: 'qrc',
  host: 'example.test',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
);

ApiClient _api() => testApiClient(
  baseUrl: 'https://example.test',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

Map<String, dynamic> _user(String id) => {
  'message_id': id,
  'role': 'user',
  'content': id,
};

void main() {
  test(
    'the visible chat reads at once; the covered ones after the stagger',
    () async {
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(service.dispose);

      var coveredReads = 0;
      final covered = service.attach(
        connection: _connection(),
        sessionId: 'covered',
        sessionTitle: 'covered',
        api: _api(),
        storedMessageLoader: (_, _) {
          coveredReads += 1;
          return Future.value([_user('covered-user')]);
        },
        disableForegroundKeepAlive: true,
      );
      var visibleReads = 0;
      final visible = service.attach(
        connection: _connection(),
        sessionId: 'visible',
        sessionTitle: 'visible',
        api: _api(),
        storedMessageLoader: (_, _) {
          visibleReads += 1;
          return Future.value([_user('visible-user')]);
        },
        disableForegroundKeepAlive: true,
      );
      await covered.loadMessages();
      await visible.loadMessages();
      covered.state = ChatPipelineState.completed;
      visible.state = ChatPipelineState.completed;
      expect(coveredReads, 1);
      expect(visibleReads, 1);

      // A screen listens to the visible chat; nobody looks at the other one.
      final subscription = visible.changes.listen((_) {});
      addTearDown(subscription.cancel);
      expect(visible.hasListeners, isTrue);
      expect(covered.hasListeners, isFalse);

      final resume = service.reconcileAfterResume();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(visibleReads, 2, reason: 'the visible chat went first');
      expect(coveredReads, 1, reason: 'the covered chat waits the stagger');
      await Future<void>.delayed(
        ActiveChatService.resumeFanoutStagger +
            const Duration(milliseconds: 300),
      );
      expect(coveredReads, 2);
      await resume.timeout(const Duration(seconds: 5));
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}
