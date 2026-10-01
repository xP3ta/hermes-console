// sa1215: the chat menu opens «Archivos y enlaces» with what the loaded
// transcript shared, including tool deliveries that never render as text.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/chat_content_screen.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/image_viewer_screen.dart';
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
import 'package:hermes_android/main.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-chat-content',
  label: 'Chat content',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
);

Session _session() => Session(
  id: 'sess-chat-content',
  title: 'Contenido del chat',
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

/// Newest first, as ActiveChat stores it internally.
List<Map<String, dynamic>> _history() => [
  {
    'role': 'assistant',
    'content': 'Te dejo la guía: https://example.com/docs/guia',
    'timestamp': 1781774300,
  },
  {
    'role': 'tool',
    'tool_name': 'image_generate',
    'tool_call_id': 'call-img',
    'content': jsonEncode({'image': 'https://cdn.example.com/gen/gato.png'}),
    'timestamp': 1781774250,
  },
  {
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'call-img',
        'type': 'function',
        'function': {'name': 'image_generate', 'arguments': '{}'},
      },
    ],
    'timestamp': 1781774200,
  },
  {
    'role': 'user',
    'content': 'Hazme un gato\n@file:/home/u/.hermes/uploads/brief.pdf',
    'timestamp': 1781774100,
  },
];

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
    Future<void> Function(String path, File destination)?
    userServerMediaFetcher,
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
        builder: (_) => ChatScreen(
          connection: connection,
          session: _session(),
          userServerMediaFetcher: userServerMediaFetcher,
        ),
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

  testWidgets('el menú del chat abre Archivos y enlaces con su contenido', (
    tester,
  ) async {
    await pumpChat(tester, history: _history());
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('chat-control-trigger')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final entry = find.byKey(const ValueKey('chat-control-content'));
    await tester.ensureVisible(entry);
    expect(
      find.descendant(of: entry, matching: find.text('Archivos y enlaces')),
      findsOneWidget,
    );
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(ChatContentScreen), findsOneWidget);
    for (final label in ['guia', 'gato.png', 'brief.pdf']) {
      expect(
        find.byKey(ValueKey('sa1215-item-$label')),
        findsOneWidget,
        reason: label,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('una imagen adjunta en el servidor se abre en el visor', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('sa1215-media-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    const serverPath = '/home/u/.hermes/images/plano.png';
    final fetched = <String>[];
    await pumpChat(
      tester,
      history: [
        {'role': 'assistant', 'content': 'Recibido.'},
        {
          'role': 'user',
          'content': 'Revisa el plano\n@image:$serverPath',
          'timestamp': 1781774300,
        },
      ],
      userServerMediaFetcher: (path, destination) async {
        fetched.add(path);
        await destination.writeAsBytes(base64Decode(_pngBase64));
      },
    );
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('chat-control-trigger')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final entry = find.byKey(const ValueKey('chat-control-content'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byKey(const ValueKey('sa1215-item-plano.png')));
    for (var frame = 0; frame < 40; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(fetched.last, serverPath);
    expect(find.byType(ImageViewerScreen), findsOneWidget);
  });
}

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
