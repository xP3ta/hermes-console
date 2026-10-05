import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/quick_reply_prefs.dart';
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
    runtimeSessionId: 'runtime-kb-settle',
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
    runtimeSessionId: 'runtime-kb-settle',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-kb-settle',
    storedSessionId: 'sess-kb-settle',
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
  id: 'conn-kb-settle',
  label: 'Keyboard settle',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-kb-settle',
  title: 'Respuestas rápidas y teclado',
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

List<Map<String, dynamic>> _history() => List.generate(12, (index) {
  return {
    'id': 'kb-settle-message-$index',
    'role': index.isEven ? 'assistant' : 'user',
    'content':
        'teclado histórico $index. '
        '${List.filled(18, 'Contenido estable.').join(' ')}'
        '${index == 0 ? '\n\n¿Quieres que lo aplique?' : ''}',
  };
});

/// Insets Android publishes frame by frame while the IME opens or closes.
final _openFrames = [for (var i = 1; i <= 20; i++) 900.0 * i / 20];
final _closeFrames = [for (var i = 19; i >= 0; i--) 900.0 * i / 20];
const _frame = Duration(milliseconds: 16);

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
    QuickReplyPrefs.debugUse(QuickReplyPrefs.forTesting(null));
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
  tearDown(() => QuickReplyPrefs.debugUse(null));

  void usePhoneView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1280, 2856)
      ..devicePixelRatio = 3.0
      ..padding = const FakeViewPadding(top: 120, bottom: 72)
      ..viewPadding = const FakeViewPadding(top: 120, bottom: 72);
    addTearDown(tester.view.reset);
  }

  /// Counts notifications of the listenables the transcript ListView is
  /// built from. Each one rebuilds the ListView and hands its sliver a new
  /// builder delegate, which rebuilds every visible row.
  int Function() countTranscriptRebuilds(WidgetTester tester) {
    var count = 0;
    tester
        .widget<ListenableBuilder>(
          find
              .ancestor(
                of: find.byType(ChatScrollInteractionGuard),
                matching: find.byType(ListenableBuilder),
              )
              .first,
        )
        .listenable
        .addListener(() => count++);
    return () => count;
  }

  Future<void> pumpChat(WidgetTester tester, _Gateway gateway) async {
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
      sessionId: 'sess-kb-settle',
      sessionTitle: 'Respuestas rápidas y teclado',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = _history()
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
  Finder chip(int index) =>
      find.byKey(ValueKey('quick-reply-$index'), skipOffstage: false);
  double bottomPadding(WidgetTester tester) =>
      (tester.widget<ListView>(transcript()).padding! as EdgeInsets).bottom;
  ScrollController controller(WidgetTester tester) =>
      tester.widget<ListView>(transcript()).controller!;

  Future<void> setInset(WidgetTester tester, double inset) async {
    tester.view.viewInsets = FakeViewPadding(bottom: inset);
    await tester.pump(_frame);
  }

  Future<void> tearDownChat(WidgetTester tester, _Gateway gateway) async {
    tester.view.resetViewInsets();
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Chips shown at the latest message, nothing animating: returns the
  /// padding the rail adds to the transcript.
  Future<double> settledWithChips(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    expect(chip(0), findsOneWidget);
    expect(controller(tester).position.pixels, 0);
    final withChips = bottomPadding(tester);
    // Base padding (12) plus the rail's measured height.
    expect(withChips, greaterThan(12 + 20));
    return withChips;
  }

  testWidgets(
    'rpl1215 the padding and the rows hold still while the keyboard moves',
    (tester) async {
      usePhoneView(tester);
      final gateway = _Gateway();
      await pumpChat(tester, gateway);
      final withChips = await settledWithChips(tester);
      final listElement = tester.element(transcript());
      final rebuilds = countTranscriptRebuilds(tester);

      for (final inset in _openFrames) {
        await setInset(tester, inset);
        expect(chip(0), findsNothing, reason: 'inset $inset');
        expect(bottomPadding(tester), withChips, reason: 'inset $inset');
        expect(rebuilds(), 0, reason: 'inset $inset rebuilt transcript rows');
        expect(identical(tester.element(transcript()), listElement), isTrue);
      }
      // Still inside the debounce window after the last frame.
      await tester.pump(const Duration(milliseconds: 150));
      expect(bottomPadding(tester), withChips);
      expect(rebuilds(), 0);

      await tester.pump(const Duration(milliseconds: 100));
      expect(bottomPadding(tester), 12);
      expect(rebuilds(), 1);
      final afterOpen = rebuilds();

      for (final inset in _closeFrames) {
        await setInset(tester, inset);
        expect(bottomPadding(tester), 12, reason: 'inset $inset');
        expect(rebuilds(), afterOpen, reason: 'inset $inset rebuilt rows');
      }
      expect(chip(0), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      expect(bottomPadding(tester), 12);
      expect(rebuilds(), afterOpen);

      await tester.pump(const Duration(milliseconds: 100));
      expect(bottomPadding(tester), withChips);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    },
  );

  testWidgets('rpl1215 the settled padding matches the final keyboard state', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    final withChips = await settledWithChips(tester);

    // Keyboard open and stable: chips hidden, base padding only.
    for (final inset in _openFrames) {
      await setInset(tester, inset);
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(chip(0), findsNothing);
    expect(bottomPadding(tester), 12);
    await tester.pump(const Duration(seconds: 1));
    expect(bottomPadding(tester), 12);

    // Keyboard closed and stable: chips back with their padding.
    for (final inset in _closeFrames) {
      await setInset(tester, inset);
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(chip(0), findsOneWidget);
    expect(bottomPadding(tester), withChips);
    await tester.pump(const Duration(seconds: 1));
    expect(bottomPadding(tester), withChips);

    // Open and close again inside one debounce window: the padding never
    // moves and ends where it started.
    for (final inset in [300.0, 600.0, 900.0, 600.0, 300.0, 0.0]) {
      await setInset(tester, inset);
      expect(bottomPadding(tester), withChips, reason: 'inset $inset');
    }
    expect(chip(0), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(bottomPadding(tester), withChips);

    // Quick open that stays open: the padding lands on the open value.
    for (final inset in [300.0, 900.0]) {
      await setInset(tester, inset);
      expect(bottomPadding(tester), withChips, reason: 'inset $inset');
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(bottomPadding(tester), 12);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });

  testWidgets('rpl1215 a reader away when the keyboard settles keeps the '
      'padding until returning', (tester) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    final withChips = await settledWithChips(tester);

    for (final inset in _openFrames) {
      await setInset(tester, inset);
    }
    expect(bottomPadding(tester), withChips);
    // The reader leaves the latest message before the inset settles.
    controller(tester).jumpTo(120);
    await tester.pump();
    expect(bottomPadding(tester), withChips + 48);
    await tester.pump(const Duration(milliseconds: 250));
    expect(bottomPadding(tester), withChips + 48);
    await tester.pump(const Duration(seconds: 1));
    expect(bottomPadding(tester), withChips + 48);

    // Back at the latest message the settled measure (no rail) applies.
    controller(tester).jumpTo(0);
    await tester.pump();
    expect(bottomPadding(tester), 12);
    await tester.pump(const Duration(milliseconds: 300));
    expect(chip(0), findsNothing);
    expect(bottomPadding(tester), 12);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });

  testWidgets('rpl1215 no settle timer survives leaving the chat', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    await settledWithChips(tester);

    for (final inset in _openFrames.take(5)) {
      await setInset(tester, inset);
    }
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetViewInsets();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  // Ends inside the debounce window: a settle timer left behind by the
  // disposed screen trips the binding's pending timer check.
  testWidgets('rpl1215 leaving the chat cancels a pending settle', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    await settledWithChips(tester);

    for (final inset in _openFrames.take(5)) {
      await setInset(tester, inset);
    }
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetViewInsets();
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
  });
}
