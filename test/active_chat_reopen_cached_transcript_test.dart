import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

final _connection = SavedConnection(
  id: 'reopen-cache',
  label: 'reopen-cache',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

ApiClient _unusedApi() => ApiClient(
  baseUrl: 'https://example.invalid',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('unused', 500)),
);

const _rows = <Map<String, dynamic>>[
  {'id': 1, 'role': 'user', 'content': 'pregunta guardada'},
  {'id': 2, 'role': 'assistant', 'content': 'respuesta guardada'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ActiveChatService service;

  setUp(() {
    service = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
  });

  tearDown(() => service.dispose());

  ActiveChat attach({
    required StoredSessionMessageLoader loader,
    String sessionId = 'stored-reopen',
    String? initialStoredSessionId,
  }) => service.attach(
    connection: _connection,
    sessionId: sessionId,
    sessionTitle: 'Reopen',
    initialStoredSessionId: initialStoredSessionId,
    api: _unusedApi(),
    storedMessageLoader: loader,
    disableForegroundKeepAlive: true,
  );

  Future<void> openAndClose({String sessionId = 'stored-reopen'}) async {
    final first = attach(
      sessionId: sessionId,
      loader: (_, _) async => List.of(_rows),
    );
    await first.loadMessages(expectedMessageCount: 2);
    expect(first.messages, hasLength(2));
    service.release(_connection.id, sessionId);
    expect(service.of(_connection.id, sessionId), isNull);
  }

  test('reopening a released chat shows its last transcript before the '
      'slow network read completes', () async {
    await openAndClose();

    final slowNetwork = Completer<List<Map<String, dynamic>>>();
    final reopened = attach(loader: (_, _) => slowNetwork.future);
    final loading = reopened.loadMessages(expectedMessageCount: 2);
    await Future<void>.delayed(Duration.zero);

    expect(reopened.messages.map((m) => m['content']), [
      'respuesta guardada',
      'pregunta guardada',
    ]);

    slowNetwork.complete([
      ..._rows,
      {'id': 3, 'role': 'user', 'content': 'nueva desde otra superficie'},
      {'id': 4, 'role': 'assistant', 'content': 'respuesta nueva'},
    ]);
    await loading;
    expect(reopened.messages.first['content'], 'respuesta nueva');
    expect(reopened.messages, hasLength(4));
  });

  test('a deleted session is not shown from the reopen cache', () async {
    await openAndClose();
    await service.clearCancelledTurnsForSession(
      connectionId: _connection.id,
      profile: '',
      sessionId: 'stored-reopen',
    );

    final reopened = attach(
      loader: (_, _) => Completer<List<Map<String, dynamic>>>().future,
    );
    expect(reopened.messages, isEmpty);
  });

  test('a different durable identity does not reuse the cached rows', () async {
    await openAndClose();

    final reopened = attach(
      initialStoredSessionId: 'stored-rotated',
      loader: (_, _) => Completer<List<Map<String, dynamic>>>().future,
    );
    expect(reopened.messages, isEmpty);
  });
}
