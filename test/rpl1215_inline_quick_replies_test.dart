import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_frame.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
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
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesQuickReplySuggestionGateway {
  int smartCalls = 0;

  @override
  bool get quickReplySuggestionsAvailable => true;

  @override
  Future<List<String>> suggestQuickReplies({
    required String lastAssistant,
    required String lastUser,
    String profile = '',
  }) async {
    smartCalls++;
    return const ['Sí, aplícalo'];
  }

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
    runtimeSessionId: 'runtime-inline-qr',
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
    runtimeSessionId: 'runtime-inline-qr',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-inline-qr',
    storedSessionId: 'sess-inline-qr',
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
  id: 'conn-inline-qr',
  label: 'Inline quick replies',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-inline-qr',
  title: 'Respuestas rápidas en línea',
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
        'id': 'inline-qr-message-$index',
        'role': index.isEven ? 'assistant' : 'user',
        'content':
            'respuesta histórica $index. '
            '${List.filled(18, 'Contenido estable.').join(' ')}'
            '${questionAt.contains(index) ? _question : ''}',
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
      sessionId: 'sess-inline-qr',
      sessionTitle: 'Respuestas rápidas en línea',
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
  Finder chip(int index) =>
      find.byKey(ValueKey('quick-reply-$index'), skipOffstage: false);
  double bottomPadding(WidgetTester tester) =>
      (tester.widget<ListView>(transcript()).padding! as EdgeInsets).bottom;

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
  Finder smart() => find.byKey(const ValueKey('quick-reply-smart'));

  /// The message frame that paints the newest answer.
  Finder latestAnswerFrame() => find.ancestor(
    of: find.textContaining('respuesta histórica 0.', findRichText: true),
    matching: find.byType(ChatMessageFrame),
  );

  testWidgets('rpl1215 chips render inside the latest assistant bubble', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    await tester.pump(const Duration(milliseconds: 400));

    expect(chip(0), findsOneWidget);
    expect(
      find.descendant(of: latestAnswerFrame(), matching: chip(0)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: latestAnswerFrame(), matching: smart()),
      findsOneWidget,
    );
    // Below the answer text, inside the transcript (no floating rail).
    expect(
      find.descendant(of: transcript(), matching: chip(0)),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(chip(0)).dy,
      greaterThan(
        tester
            .getBottomLeft(
              find
                  .textContaining(
                    '¿Quieres que lo aplique?',
                    findRichText: true,
                  )
                  .first,
            )
            .dy,
      ),
    );
    expect(bottomPadding(tester), 12);
    expect(gateway.smartCalls, 0);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });

  testWidgets('rpl1215 an older answer never gets chips', (tester) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    // Only an older answer closes with a question; the newest is generic.
    await pumpChat(tester, gateway, questionAt: const {2});
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.textContaining(
        '¿Quieres que lo aplique?',
        findRichText: true,
        skipOffstage: false,
      ),
      findsWidgets,
    );
    expect(chip(0), findsNothing);
    // Without contextual chips there is no lone ✨ either.
    expect(smart(), findsNothing);
    expect(bottomPadding(tester), 12);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });

  testWidgets('rpl1215 the latest question gets exactly one set of chips', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway, questionAt: const {0, 2});
    await tester.pump(const Duration(milliseconds: 400));

    expect(chip(0), findsOneWidget);
    expect(smart(), findsOneWidget);
    expect(
      find.descendant(of: latestAnswerFrame(), matching: chip(0)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });

  testWidgets(
    'rpl1215 the keyboard leaves the chips, the padding and the rows alone',
    (tester) async {
      usePhoneView(tester);
      final gateway = _Gateway();
      await pumpChat(tester, gateway);
      await tester.pump(const Duration(milliseconds: 400));
      expect(chip(0), findsOneWidget);
      final listElement = tester.element(transcript());
      final rebuilds = countTranscriptRebuilds(tester);

      for (final inset in [..._openFrames, ..._closeFrames]) {
        await setInset(tester, inset);
        expect(bottomPadding(tester), 12, reason: 'inset $inset');
        expect(rebuilds(), 0, reason: 'inset $inset rebuilt transcript rows');
        expect(identical(tester.element(transcript()), listElement), isTrue);
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(chip(0), findsOneWidget);
      expect(bottomPadding(tester), 12);
      expect(rebuilds(), 0);
      expect(tester.takeException(), isNull);
      await tearDownChat(tester, gateway);
    },
  );

  testWidgets('rpl1215 the setting hides the inline chips and the ✨', (
    tester,
  ) async {
    usePhoneView(tester);
    final gateway = _Gateway();
    await pumpChat(tester, gateway);
    await tester.pump(const Duration(milliseconds: 400));
    expect(chip(0), findsOneWidget);

    await QuickReplyPrefs.shared.setEnabled(false);
    await tester.pump();
    expect(chip(0), findsNothing);
    expect(smart(), findsNothing);
    expect(bottomPadding(tester), 12);

    await QuickReplyPrefs.shared.setEnabled(true);
    await tester.pump();
    expect(chip(0), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });
}
