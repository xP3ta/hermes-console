import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
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

class _Gateway
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
    runtimeSessionId: 'runtime-kbf',
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
    runtimeSessionId: 'runtime-kbf',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-kbf',
    storedSessionId: 'sess-kbf',
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

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'conn-kbf',
  label: 'Keyboard focus frames',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-kbf',
  title: 'Foco del teclado',
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

const _question = '\n\n¿Quieres que lo aplique?';

/// Newest first. [questionAt] lists the assistant rows that close with a
/// question.
List<Map<String, dynamic>> _history({Set<int> questionAt = const {0}}) =>
    List.generate(12, (index) {
      return {
        'id': 'kbf-message-$index',
        'role': index.isEven ? 'assistant' : 'user',
        'content':
            'respuesta histórica $index. '
            '${List.filled(18, 'Contenido estable.').join(' ')}'
            '${questionAt.contains(index) ? _question : ''}',
      };
    });

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

  Future<void> pumpChat(
    WidgetTester tester,
    _Gateway gateway, {
    Set<int> questionAt = const {0},
  }) async {
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
      sessionId: 'sess-kbf',
      sessionTitle: 'Foco del teclado',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = _history(questionAt: questionAt)
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
    Navigator.of(tester.element(find.byType(Navigator).first)).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Finder transcript() => find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );
  Finder composerField() => find.descendant(
    of: find.byKey(const ValueKey('chat-composer-host')),
    matching: find.byType(TextField),
  );
  FocusNode composerFocus(WidgetTester tester) =>
      tester.widget<TextField>(composerField()).focusNode!;

  Future<void> tearDownChat(WidgetTester tester, _Gateway gateway) async {
    debugOnRebuildDirtyWidget = null;
    tester.view.resetViewInsets();
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Counts rebuilds of row elements that already existed under the
  /// transcript sliver when called (fresh mounts from virtualization and the
  /// scroll view's own chrome are not counted).
  int Function() countRowRebuilds(WidgetTester tester) {
    final list = tester.element(
      find.descendant(of: transcript(), matching: find.byType(SliverList)),
    );
    final existing = <Element>{};
    void collect(Element element) {
      existing.add(element);
      element.visitChildren(collect);
    }

    list.visitChildren(collect);
    var count = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (existing.contains(element)) count++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    return () => count;
  }

  /// Lets entrance and focus animations finish so only the action under
  /// test produces rebuilds.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('kbf1215 focusing and unfocusing the composer rebuilds no row', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    await settle(tester);
    final rows = countRowRebuilds(tester);

    composerFocus(tester).requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(composerFocus(tester).hasFocus, isTrue);
    expect(rows(), 0, reason: 'focus rebuilt transcript rows');

    composerFocus(tester).unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(composerFocus(tester).hasFocus, isFalse);
    expect(rows(), 0, reason: 'unfocus rebuilt transcript rows');
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });

  testWidgets('kbf1215 the composer focus ring still follows focus', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    await settle(tester);
    bool surfaceFocused() => tester
        .widget<HermesComposerSurface>(
          find.descendant(
            of: find.byKey(const ValueKey('chat-composer-host')),
            matching: find.byType(HermesComposerSurface),
          ),
        )
        .focused;
    expect(surfaceFocused(), isFalse);

    composerFocus(tester).requestFocus();
    // The focus listeners run after the frame that moved focus.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(surfaceFocused(), isTrue);

    composerFocus(tester).unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(surfaceFocused(), isFalse);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });

  testWidgets('kbf1215 the slash palette still opens while focused', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    await settle(tester);

    await tester.tap(composerField());
    await tester.pump();
    await tester.enterText(composerField(), '/');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(composerFocus(tester).hasFocus, isTrue);
    expect(find.byKey(const ValueKey('chat-slash-palette')), findsOneWidget);

    // Losing focus closes it, as on Desktop.
    composerFocus(tester).unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('chat-slash-palette')), findsNothing);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });

  testWidgets('kbf1215 the scroll-to-bottom arrow rebuilds no row', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    await settle(tester);
    final controller = tester.widget<ListView>(transcript()).controller!;
    double arrowPadding() =>
        (tester.widget<ListView>(transcript()).padding! as EdgeInsets).bottom;
    final before = arrowPadding();

    // Scroll a little first so the jump below only toggles the arrow.
    controller.jumpTo(40);
    await settle(tester);
    final rows = countRowRebuilds(tester);
    controller.jumpTo(160);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(arrowPadding(), before + 48, reason: 'the arrow is showing');
    expect(rows(), 0, reason: 'showing the arrow rebuilt rows');

    controller.jumpTo(40);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(arrowPadding(), before);
    expect(rows(), 0, reason: 'hiding the arrow rebuilt rows');
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });
}
