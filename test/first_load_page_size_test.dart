// First open of a long chat reads only the newest page, like Hermes Desktop
// (`LATEST_SESSION_MESSAGES_LIMIT = 120`); older pages load on demand. The
// field transcripts weigh 0.5–1.75 MB per 500-row page on a phone link.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _storedId = 'stored-first-load';

/// `/api/sessions/{id}/messages` with `order=latest` offsets and integer row
/// ids. Every response is charged a modelled cost (150 ms server time plus
/// transfer at a mobile-like 1 MB/s) on a virtual clock, so first paint can
/// be compared without real waits.
final class _Server {
  _Server({int rows = 1000}) {
    for (var id = 1; id <= rows; id++) {
      _rows.add({
        'id': id,
        'session_id': _storedId,
        'role': id.isOdd ? 'user' : 'assistant',
        'content': '${id.isOdd ? 'user' : 'assistant'} $id ${'x' * 1700}',
        'timestamp': 1790000000 + id,
      });
    }
  }

  final List<Map<String, Object?>> _rows = [];

  void append(int count) {
    for (var i = 0; i < count; i++) {
      final id = _rows.length + 1;
      _rows.add({
        'id': id,
        'session_id': _storedId,
        'role': id.isOdd ? 'user' : 'assistant',
        'content': 'late $id',
        'timestamp': 1790000000 + id,
      });
    }
  }

  final requests = <Uri>[];
  var bytes = 0;
  var virtualMs = 0;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    if (request.url.path != '/api/sessions/$_storedId/messages') {
      return http.Response('{"error":"not found"}', 404);
    }
    final query = request.url.queryParameters;
    final limit = int.parse(query['limit'] ?? '500').clamp(1, 500);
    final offset = int.parse(query['offset'] ?? '0');
    final end = (_rows.length - offset).clamp(0, _rows.length);
    final start = (end - limit).clamp(0, end);
    final page = _rows.sublist(start, end);
    final body = jsonEncode({
      'object': 'list',
      'session_id': _storedId,
      'data': page,
      'pagination': {
        'limit': limit,
        'offset': offset,
        'order': 'latest',
        'returned': page.length,
      },
    });
    final size = utf8.encode(body).length;
    bytes += size;
    virtualMs += 150 + size * 1000 ~/ (1024 * 1024);
    return http.Response(body, 200);
  });
}

final _connection = SavedConnection(
  id: 'first-load-conn',
  label: 'First load',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  kind: InstanceKind.vps,
);

const _session = Session(
  id: _storedId,
  title: 'Long chat',
  model: 'hermes-agent',
  source: 'desktop',
  messageCount: 1000,
  isActive: true,
  preview: '',
  startedAt: 0,
);

ActiveChat _attach(ActiveChatService service, _Server server) => service.attach(
  connection: _connection,
  sessionId: _session.id,
  sessionTitle: _session.title,
  sessionSnapshot: _session,
  initialStoredSessionId: _storedId,
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'k',
    httpClient: server.client(),
  ),
  attachDesktopRuntimeOnLoad: false,
  disableForegroundKeepAlive: true,
);

List<int> _ids(ActiveChat chat) => [
  for (final message in chat.messages) message['id'] as int,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('first open of a 1000-message chat reads one 120-row page', () async {
    final server = _Server();
    final service = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    final chat = _attach(service, server);
    await chat.loadMessages(expectedMessageCount: 1000);
    final firstPaintMs = server.virtualMs;
    // ignore: avoid_print
    print(
      '[first-load] requests=${server.requests.length} '
      'bytes=${server.bytes} firstPaint=${firstPaintMs}ms',
    );
    expect(server.requests, hasLength(1));
    expect(server.requests.single.queryParameters['limit'], '120');
    expect(chat.messages, hasLength(120));
    expect(_ids(chat), [for (var id = 1000; id > 880; id--) id]);
    expect(chat.hasEarlierMessages, isTrue);
    expect(server.bytes, lessThan(300 * 1024));
    expect(firstPaintMs, lessThan(500));

    // Older history stays reachable page by page, in order, exactly once,
    // and the exact-count guard never turns a partial tail into an error.
    var pages = 0;
    while (chat.hasEarlierMessages && pages < 20) {
      expect(await chat.loadEarlierMessages(), isTrue);
      pages++;
    }
    expect(_ids(chat), [for (var id = 1000; id >= 1; id--) id]);
    expect(chat.hasEarlierMessages, isFalse);
    expect(chat.earlierMessagesLoadFailed, isFalse);
  });

  test('a refresh after more than one page of new rows keeps every row '
      'once and in order', () async {
    final server = _Server(rows: 400);
    final service = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    final chat = _attach(service, server);
    await chat.loadMessages(expectedMessageCount: 400);
    while (chat.hasEarlierMessages) {
      expect(await chat.loadEarlierMessages(), isTrue);
    }
    expect(_ids(chat), [for (var id = 400; id >= 1; id--) id]);

    // Another surface wrote 150 rows: more than the 120-row tail page.
    server.append(150);
    await chat.loadMessages(expectedMessageCount: 550);
    var guard = 0;
    while (chat.hasEarlierMessages && guard++ < 20) {
      await chat.loadEarlierMessages();
    }
    expect(_ids(chat), [for (var id = 550; id >= 1; id--) id]);
  });
}
