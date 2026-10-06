import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
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
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/main.dart';

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

SavedConnection _connection() => SavedConnection(
  id: 'conn-scroll-stress',
  label: 'Scroll stress',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-scroll-stress',
  title: 'Prueba de scroll',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

ApiClient _safeApi() => ApiClient(
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

// QA 1215 (Pixel 9 Pro): abrir y cerrar el teclado en el chat «se traba».
// Android anima `viewInsets.bottom` frame a frame. Cualquier lectura de
// `MediaQuery.of(context)` en el State de la pantalla la suscribe a TODOS los
// campos del MediaQuery, así que cada frame de la animación del IME
// reconstruía la pantalla entera: transcript (markdown, código, tablas,
// tarjetas de herramienta), composer y cabecera. Estas pruebas recorren la
// animación como lo hace Android y exigen que ni la pantalla ni el transcript
// se reconstruyan, que el composer conserve el foco y que la lectura no se
// mueva mientras el teclado entra o sale.

List<Map<String, dynamic>> _transcript(int turns) {
  final messages = <Map<String, dynamic>>[];
  for (var turn = turns - 1; turn >= 0; turn--) {
    messages.add({
      'id': 'kb-answer-$turn',
      'role': 'assistant',
      'content':
          '## Resultado $turn\n\nHe revisado **el fichero** y `main.dart`.\n\n'
          '- primer punto\n- segundo punto con [enlace](https://example.com)\n\n'
          '```dart\nvoid main() {\n  print("hola $turn");\n}\n```\n\n'
          '| a | b |\n|---|---|\n| 1 | 2 |\n',
    });
    messages.add({
      'id': 'kb-tool-$turn',
      'role': 'tool',
      'tool_call_id': 'kb-call-$turn',
      'content': 'línea de salida\n' * 30,
    });
    messages.add({
      'id': 'kb-call-row-$turn',
      'role': 'assistant',
      'content': 'Voy a mirar.',
      'tool_calls': [
        {
          'id': 'kb-call-$turn',
          'type': 'function',
          'function': {'name': 'terminal', 'arguments': '{"command":"ls"}'},
        },
      ],
    });
    messages.add({
      'id': 'kb-user-$turn',
      'role': 'user',
      'content': 'Pregunta $turn: ¿qué hay en el repositorio?',
    });
  }
  return messages;
}

/// Insets que publica Android durante una apertura y un cierre del IME.
final _openFrames = [for (var i = 1; i <= 20; i++) 900.0 * i / 20];
final _closeFrames = [for (var i = 19; i >= 0; i--) 900.0 * i / 20];

class _HomeClient extends ApiClient {
  _HomeClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<bool> healthReachable() => healthCheck();

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => [
    for (var i = 0; i < 8; i++)
      Session(
        id: 'home-recent-$i',
        title: 'Conversación reciente $i',
        model: 'hermes-agent',
        source: 'mobile',
        messageCount: 4,
        isActive: false,
        preview: 'Vista previa $i',
        startedAt: DateTime.now().millisecondsSinceEpoch / 1000 - i,
      ),
  ];

  @override
  void close() {}
}

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

  void usePhoneView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1280, 2856)
      ..devicePixelRatio = 3.0
      ..padding = const FakeViewPadding(top: 120, bottom: 72)
      ..viewPadding = const FakeViewPadding(top: 120, bottom: 72);
    addTearDown(tester.view.reset);
  }

  /// Counts rebuilt elements whose ancestor chain contains [root].
  ///
  /// Only elements that already existed when counting started are counted: a
  /// row first mounted because the resized viewport brings it into the cache
  /// extent is ordinary list virtualization (it depends on where row edges
  /// fall), not a rebuild caused by the inset.
  int Function() countRebuildsUnder(Element root) {
    var count = 0;
    final existing = Set<Element>.identity()..add(root);
    void collect(Element element) {
      existing.add(element);
      element.visitChildren(collect);
    }

    root.visitChildren(collect);
    debugOnRebuildDirtyWidget = (element, _) {
      if (!existing.contains(element)) return;
      if (identical(element, root)) {
        count++;
        return;
      }
      element.visitAncestorElements((ancestor) {
        if (!identical(ancestor, root)) return true;
        count++;
        return false;
      });
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    return () => count;
  }

  Future<ChatPerformanceProbe> pumpChat(
    WidgetTester tester,
    _StreamingGateway gateway,
  ) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-scroll-stress',
      sessionTitle: 'Prueba de scroll',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = _transcript(60)
      ..messagesLoaded = true;
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
    final probe = ChatPerformanceProbe();
    Navigator.of(tester.element(find.byType(Navigator).first)).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          connection: connection,
          session: _session(),
          performanceProbe: probe,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return probe;
  }

  Finder transcript() => find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );

  /// Focus the composer and let every entrance/focus animation finish, so the
  /// only thing that changes afterwards is the keyboard inset.
  Future<Finder> focusComposer(WidgetTester tester) async {
    final composer = find.byType(TextField).last;
    await tester.tap(composer);
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isTrue);
    return composer;
  }

  Future<void> tearDownChat(WidgetTester tester, _StreamingGateway g) async {
    debugOnRebuildDirtyWidget = null;
    tester.view.resetViewInsets();
    await g.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  }

  testWidgets(
    'keyboard animation does not rebuild the chat screen or its transcript',
    (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      final probe = await pumpChat(tester, gateway);
      final composer = await focusComposer(tester);
      final controller = tester.widget<ListView>(transcript()).controller!;
      expect(controller.position.pixels, 0);
      final listWidget = tester.widget<ListView>(transcript());
      final markdownBefore = tester.widget(find.byType(MarkdownBody).first);
      final transcriptRebuilds = countRebuildsUnder(
        tester.element(transcript()),
      );
      probe.reset();

      for (final inset in [..._openFrames, ..._closeFrames]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          probe.screenBuilds,
          0,
          reason: 'inset $inset rebuilt the whole chat screen',
        );
        expect(
          transcriptRebuilds(),
          0,
          reason: 'inset $inset rebuilt transcript rows',
        );
        expect(probe.composerBuilds, 0, reason: 'inset $inset');
        // Reader at the bottom stays pinned to the latest message.
        expect(controller.position.pixels, 0, reason: 'inset $inset');
        expect(
          tester.widget<TextField>(composer).focusNode!.hasFocus,
          isTrue,
          reason: 'inset $inset',
        );
      }
      expect(
        identical(tester.widget<ListView>(transcript()), listWidget),
        isTrue,
      );
      expect(
        identical(
          tester.widget(find.byType(MarkdownBody).first),
          markdownBefore,
        ),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    },
  );

  testWidgets(
    'keyboard animation keeps the reading position while reading history',
    (tester) async {
      usePhoneView(tester);
      final gateway = _StreamingGateway();
      final probe = await pumpChat(tester, gateway);
      final controller = tester.widget<ListView>(transcript()).controller!;
      // Scroll up the way a reader does (drags), so every row on screen
      // has been laid out for real before the keyboard opens.
      for (var drag = 0; drag < 4; drag++) {
        await tester.drag(transcript(), const Offset(0, 600));
        await tester.pump(const Duration(milliseconds: 500));
      }
      await focusComposer(tester);
      final reading = controller.position.pixels;
      expect(reading, greaterThan(1000));
      final transcriptRebuilds = countRebuildsUnder(
        tester.element(transcript()),
      );
      probe.reset();

      // Mientras el IME anima, nada desplaza al lector ni reconstruye filas.
      for (final inset in _openFrames) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.position.pixels, reading, reason: 'inset $inset');
        expect(probe.screenBuilds, 0, reason: 'inset $inset');
        expect(transcriptRebuilds(), 0, reason: 'inset $inset');
      }
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    },
  );

  testWidgets('keyboard animation does not rebuild the home screen', (
    tester,
  ) async {
    usePhoneView(tester);
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    await manager.setActiveConnection(manager.getConnections().single.id);
    final client = _HomeClient();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => client,
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find
          .textContaining('Conversación reciente 0')
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(find.textContaining('Conversación reciente 0'), findsOneWidget);
    final field = find.byType(TextField).first;
    await tester.tap(field);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final homeRebuilds = countRebuildsUnder(
      tester.element(find.byType(HomeDashboardScreen)),
    );
    var dashboardBuilds = 0;
    final countAll = debugOnRebuildDirtyWidget!;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is HomeDashboardScreen) dashboardBuilds++;
      countAll(element, builtOnce);
    };
    var maxPerFrame = 0;
    for (final inset in [..._openFrames, ..._closeFrames]) {
      final before = homeRebuilds();
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      final frame = homeRebuilds() - before;
      if (frame > maxPerFrame) maxPerFrame = frame;
      expect(dashboardBuilds, 0, reason: 'inset $inset rebuilt Home');
    }
    // Only the Scaffold chrome that must resize may rebuild (a few dozen
    // elements); the recents list and the composer must not.
    expect(maxPerFrame, lessThan(100));
    debugOnRebuildDirtyWidget = null;
    tester.view.resetViewInsets();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
  });
}
