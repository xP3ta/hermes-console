import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/main.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-composer-recall',
  label: 'Composer recall',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
);

Session _session() => Session(
  id: 'sess-composer-recall',
  title: 'Recuperar mensaje',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

ApiClient _safeApi() => ApiClient(
  baseUrl: 'http://192.168.255.254:8642',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
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

  Future<ActiveChat> pumpChat(
    WidgetTester tester, {
    List<Map<String, dynamic>>? history,
    ApiClient? api,
    bool messagesLoaded = true,
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view
      ..physicalSize = const Size(1080, 2280)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService(attachDesktopRuntimeOnLoad: false);
    addTearDown(activeChats.dispose);
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: _session().id,
      sessionTitle: _session().title,
      api: api ?? _safeApi(),
      attachDesktopRuntimeOnLoad: false,
      allowUnownedDesktopSnapshotForTesting: messagesLoaded,
      transcriptPageSizeForTesting: 120,
    );
    if (history != null) chat.internalMessagesForTesting = history;
    chat.messagesLoaded = messagesLoaded;

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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));

    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    return chat;
  }

  Finder composerField() => find.descendant(
    of: find.byType(ConsoleComposer),
    matching: find.byType(TextField),
  );

  TextEditingController composer(WidgetTester tester) =>
      tester.widget<TextField>(composerField()).controller!;

  Future<void> focusComposer(WidgetTester tester) async {
    await tester.tap(composerField());
    await tester.pump();
    expect(
      tester.widget<TextField>(composerField()).focusNode!.hasFocus,
      isTrue,
    );
  }

  /// Newest first, as ActiveChat stores it.
  List<Map<String, dynamic>> history() => [
    {'role': 'assistant', 'content': 'Respuesta a la segunda.'},
    {'role': 'user', 'content': 'Segunda pregunta enviada'},
    {'role': 'assistant', 'content': 'Respuesta a la primera.'},
    {'role': 'user', 'content': 'Primera pregunta'},
  ];

  testWidgets('arrow up in an empty composer recalls the last sent message', (
    tester,
  ) async {
    await pumpChat(tester, history: history());
    await focusComposer(tester);
    expect(composer(tester).text, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    final value = composer(tester).value;
    expect(value.text, 'Segunda pregunta enviada');
    expect(
      value.selection,
      const TextSelection.collapsed(offset: 'Segunda pregunta enviada'.length),
    );
  });

  testWidgets('arrow up with text keeps the text and normal caret moves', (
    tester,
  ) async {
    await pumpChat(tester, history: history());
    await focusComposer(tester);
    await tester.enterText(composerField(), 'borrador');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(composer(tester).text, 'borrador');
  });

  testWidgets('arrow up leaves an open slash palette alone', (tester) async {
    await pumpChat(tester, history: history());
    await focusComposer(tester);
    await tester.enterText(composerField(), '/');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('chat-slash-palette')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(composer(tester).text, '/');
    expect(find.byKey(const ValueKey('chat-slash-palette')), findsOneWidget);
  });

  testWidgets('arrow up without a previous message does nothing', (
    tester,
  ) async {
    await pumpChat(
      tester,
      history: [
        {'role': 'assistant', 'content': 'Hola, ¿en qué te ayudo?'},
      ],
    );
    await focusComposer(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(composer(tester).text, isEmpty);
  });
}
