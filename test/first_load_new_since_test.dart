// The opening page is the newest 120 rows (Desktop parity). A reader who left
// a chat more than one page ago must still land on "new since you left":
// the screen pages back until the stored marker is loaded.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/utils/chat_read_marker.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _storedId = 'stored-new-since';

final class _Server {
  _Server(int rows) {
    for (var id = 1; id <= rows; id++) {
      _rows.add({
        'id': id,
        'session_id': _storedId,
        'role': id.isOdd ? 'user' : 'assistant',
        'content': 'row $id',
        'timestamp': 1790000000 + id,
      });
    }
  }

  final List<Map<String, Object?>> _rows = [];
  final requests = <Uri>[];

  http.Client client() => MockClient((request) async {
    if (request.url.path != '/api/sessions/$_storedId/messages') {
      return http.Response('{"error":"not found"}', 404);
    }
    requests.add(request.url);
    final query = request.url.queryParameters;
    final limit = int.parse(query['limit'] ?? '500').clamp(1, 500);
    final offset = int.parse(query['offset'] ?? '0');
    final end = (_rows.length - offset).clamp(0, _rows.length);
    final start = (end - limit).clamp(0, end);
    final page = _rows.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': _storedId,
        'data': page,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': 'latest',
          'returned': page.length,
        },
      }),
      200,
    );
  });
}

final _connection = SavedConnection(
  id: 'new-since-conn',
  label: 'New since',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  kind: InstanceKind.vps,
);

const _session = Session(
  id: _storedId,
  title: 'Left long ago',
  model: 'hermes-agent',
  source: 'desktop',
  messageCount: 400,
  isActive: true,
  preview: '',
  startedAt: 0,
);

String _markerFor(int id) => chatReadMarkerKey({
  'id': id,
  'role': id.isOdd ? 'user' : 'assistant',
  'content': 'row $id',
})!;

Future<(ActiveChat, ActiveChatService)> _open(
  WidgetTester tester,
  _Server server, {
  required String marker,
}) async {
  SharedPreferences.setMockInitialValues({
    'onboarding_done': true,
    'chat_last_read_v1.${_connection.id}.${_session.id}': marker,
  });
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = activeChats.attach(
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
  await chat.loadMessages(expectedMessageCount: 400);
  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
      approvalPolicy: ApprovalPolicyService(prefs),
      fontSize: FontSizeService(prefs),
      bridgeManager: BridgeManager(secure, manager),
      sshManager: SshManager(secure, manager),
      sftpTransfers: SftpTransferService(
        SshManager(secure, manager),
        NotificationService(prefs),
      ),
      sshSessions: SshSessionService(SshManager(secure, manager)),
      notifications: NotificationService(prefs),
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  final context = tester.element(find.byType(Navigator).first);
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => ChatScreen(
        connection: _connection,
        session: _session,
        initialStoredSessionId: chat.serverSessionId,
      ),
    ),
  );
  for (var frame = 0; frame < 120; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return (chat, activeChats);
}

List<int> _ids(ActiveChat chat) => [
  for (final message in chat.messages) message['id'] as int,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
          case 'delete':
            secure.remove(args['key']);
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
        }
        return null;
      },
    );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  Finder divider() => find.byKey(const ValueKey('chat-new-since-divider'));

  testWidgets('a marker older than the first page is paged in and lands', (
    tester,
  ) async {
    final server = _Server(400);
    final (chat, service) = await _open(
      tester,
      server,
      marker: _markerFor(260),
    );
    // Rows 261..400 are new: the marker sits beyond the 120-row tail.
    expect(_ids(chat), containsAllInOrder([400, 261, 260]));
    expect(divider(), findsOneWidget);
    final ids = _ids(chat);
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids, [for (var id = 400; id > 400 - ids.length; id--) id]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('a marker no longer in the history stops paging after the '
      'former opening depth', (tester) async {
    final server = _Server(1000);
    final (chat, service) = await _open(
      tester,
      server,
      marker: 'message:gone-forever',
    );
    expect(divider(), findsNothing);
    // Bounded: covers the former 500-row opening page, plus at most the
    // page that crossed that depth, and no further.
    expect(chat.messages.length, greaterThanOrEqualTo(500));
    expect(
      chat.messages.length,
      lessThan(500 + ActiveChat.authoritativeTranscriptPageSize),
    );
    expect(chat.hasEarlierMessages, isTrue);
    final ids = _ids(chat);
    expect(ids, [for (var id = 1000; id > 1000 - ids.length; id--) id]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
}
