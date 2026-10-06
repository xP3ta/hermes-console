import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/navigation/chat_route.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/main.dart';

// Tablet list-detail must keep ONE chat per session: the conversation open in
// the right pane and the same conversation opened from a deep link or a
// notification share the same ActiveChat (and therefore the same socket).

class _StreamingGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-scroll-stress',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-scroll-stress',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-scroll-stress',
    storedSessionId: 'sess-scroll-stress',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-scroll-stress',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

const _sessionId = 'sess-scroll-stress';

SavedConnection _connection() => SavedConnection(
  id: 'conn-tablet-single',
  label: 'Tablet single chat',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

Session _session() => Session(
  id: _sessionId,
  title: 'Prueba de panel',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 2,
  isActive: false,
  preview: '',
  startedAt: 0,
);

ApiClient _safeApi() => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'k',
  connectionId: 'conn-tablet-single',
  httpClient: MockClient((request) async {
    if (request.url.path == '/health' || request.url.path == '/api/sessions') {
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    secureStore.clear();
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
    mockChannel('dexterous.com/flutter/local_notifications');
    mockChannel('flutter_foreground_task/methods');
    mockChannel('flutter_foreground_task/background');
  });

  testWidgets('the pane chat and a deep link to the same session share one '
      'ActiveChat and one socket', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    var socketsCreated = 0;
    final activeChats = ActiveChatService(
      desktopGatewayFactory: (_) {
        socketsCreated++;
        return _StreamingGateway();
      },
      defaultApiForTesting: (_) => _safeApi(),
    );
    final connection = _connection();
    final gateway = _StreamingGateway();
    // The socket the conversation already has (it was running before).
    final chat = activeChats.attach(
      connection: connection,
      sessionId: _sessionId,
      sessionTitle: 'Prueba de panel',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = [
        {'id': 'u1', 'role': 'user', 'content': 'Hola'},
        {'id': 'a1', 'role': 'assistant', 'content': 'Hola, dime.'},
      ]
      ..messagesLoaded = true;
    expect(activeChats.chatCountForTesting, 1);

    await tester.pumpWidget(
      HermesApp(
        connManager: connectionManager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),
        bridgeManager: BridgeManager(secureStorage, connectionManager),
        sshManager: SshManager(secureStorage, connectionManager),
        sftpTransfers: SftpTransferService(
          SshManager(secureStorage, connectionManager),
          NotificationService(prefs),
        ),
        sshSessions: SshSessionService(
          SshManager(secureStorage, connectionManager),
        ),
        notifications: NotificationService(prefs),
        activeChats: activeChats,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'sessions': [
                {
                  'id': _sessionId,
                  '_lineage_root_id': _sessionId,
                  'title': 'Prueba de panel',
                  'preview': '',
                  'model': 'model-a',
                  'source': 'mobile',
                  'message_count': 2,
                  'is_active': false,
                  'started_at': now - 60,
                  'ended_at': now - 1,
                  'last_active': now - 1,
                  'archived': false,
                },
              ],
              'total': 1,
              'limit': 50,
              'offset': 0,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final listApi = _safeApi();
    final repository = SessionRepository(dashboard, listApi);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => SessionListScreen(
            connection: connection,
            connManager: connectionManager,
            clientOverride: listApi,
            repositoryOverride: repository,
            activeChatsOverride: activeChats,
          ),
        ),
      ),
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Prueba de panel').evaluate().isNotEmpty) break;
    }

    // Open it in the right pane.
    await tester.tap(find.text('Prueba de panel').first);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final pane = find.byKey(const ValueKey('adaptive-detail-pane'));
    expect(
      find.descendant(of: pane, matching: find.byType(ChatScreen)),
      findsOneWidget,
    );
    expect(activeChats.chatCountForTesting, 1);
    expect(activeChats.of(connection.id, _sessionId), same(chat));

    // A second surface for the same session while the pane is still open
    // (e.g. a notification tapped over the list): both screens bind the one
    // chat.
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ChatScreen(connection: connection, session: _session()),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ChatScreen, skipOffstage: false), findsNWidgets(2));
    expect(activeChats.chatCountForTesting, 1);
    expect(activeChats.of(connection.id, _sessionId), same(chat));
    navigator.pop();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The deep-link path itself (notifications, widgets, shares).
    unawaited(
      openChatFromHomeNavigator<void>(
        navigator,
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(activeChats.chatCountForTesting, 1);
    expect(activeChats.of(connection.id, _sessionId), same(chat));
    expect(socketsCreated, 0, reason: 'no second socket for the session');

    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
}
