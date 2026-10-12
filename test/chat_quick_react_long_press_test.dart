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
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/models/message_reaction.dart';
import 'package:hermes_android/core/services/message_reaction_prefs.dart';
import 'package:hermes_android/main.dart';

class _StreamingGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesMessageReactionGateway {
  final List<(int?, String?)> reacts = [];

  @override
  bool get messageReactionsAvailable => true;

  @override
  Future<bool> confirmMessageReactions(String runtimeSessionId) async => true;

  @override
  Future<({int rowId, List<MessageReaction> reactions})> reactToMessage(
    String runtimeSessionId, {
    int? rowId,
    String? newestRole,
    String? emoji,
    String? profile,
  }) async {
    reacts.add((rowId, emoji));
    return (
      rowId: rowId ?? 0,
      reactions: [
        if (emoji != null)
          MessageReaction(emoji: emoji, author: MessageReactionAuthor.user),
      ],
    );
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
    runtimeSessionId: 'runtime-react',
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
    runtimeSessionId: 'runtime-react',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-react',
    storedSessionId: 'sess-react',
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
      TuiGatewayEvent(type: type, sessionId: 'runtime-react', payload: payload),
    );
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'conn-react',
  label: 'Scroll stress',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-react',
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

/// rr1215 in a chat: long-press on a message with reactions on opens the
/// quick reactions on top of the message actions, with no text selection;
/// «Select text» starts it, «Copy message» copies the plain text.
List<Map<String, dynamic>> _history() => [
  {'id': 11, 'role': 'user', 'content': 'Pregunta corta del usuario.'},
  {
    'id': 12,
    'role': 'assistant',
    'content': 'La **tercera** opción es la buena.',
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
    WidgetTester tester,
    _StreamingGateway gateway, {
    List<Map<String, dynamic>>? history,
    Map<String, Object> initialPrefs = const {},
    int Function()? wallClockMs,
    bool earlierAvailable = false,
    Future<void> Function(ActiveChat chat)? beforeOpen,
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    SharedPreferences.setMockInitialValues({
      ...initialPrefs,
      'onboarding_done': true,
    });
    final prefs = await SharedPreferences.getInstance();
    await PinnedPromptPrefs.load(prefs);
    addTearDown(() => PinnedPromptPrefs.debugUse(null));
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-react',
      sessionTitle: 'Prueba de respuesta',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
      wallClockMsForTesting: wallClockMs,
    );
    chat
      ..internalMessagesForTesting = history ?? _history()
      ..messagesLoaded = true;
    if (earlierAvailable) chat.earlierMessagesAvailableForTesting = true;

    await tester.pumpWidget(
      HermesApp(
        connManager: connectionManager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),

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
    if (beforeOpen != null) await beforeOpen(chat);

    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    return chat;
  }

  Future<void> tearDownChat(WidgetTester tester, _StreamingGateway g) async {
    await g.close();
    await tester.pumpWidget(const SizedBox.shrink());
    // A turn left open arms the service's activity watchdog and the stop
    // settle timer; let them run out so no timer outlives the test.
    await tester.pump(const Duration(minutes: 6));
  }

  Future<void> settle(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  Finder answer() =>
      find.textContaining('opción es la buena', findRichText: true);

  List<SelectionOverlay> overlays(WidgetTester tester) => [
    for (final state in tester.stateList<SelectionAreaState>(
      find.byType(SelectionArea, skipOffstage: false),
    ))
      ?state.selectableRegion.selectionOverlay,
  ];

  Future<_StreamingGateway> open(WidgetTester tester) async {
    final reactions = MessageReactionPrefs.forTesting(null);
    await reactions.setEnabled(true);
    MessageReactionPrefs.debugUse(reactions);
    addTearDown(() => MessageReactionPrefs.debugUse(null));
    final gateway = _StreamingGateway();
    await pumpChat(tester, gateway, history: _history());
    await settle(tester);
    expect(answer(), findsOneWidget);
    return gateway;
  }

  testWidgets('long-press on an answer: reactions over the actions, no '
      'selection; a pick reacts', (tester) async {
    final gateway = await open(tester);
    await tester.longPress(answer());
    await settle(tester);
    final surface = find.byKey(const ValueKey('message-actions-surface'));
    expect(surface, findsOneWidget);
    expect(find.byKey(const ValueKey('quick-reaction-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('message-action-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('message-action-select')), findsOneWidget);
    expect(overlays(tester), isEmpty);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(tester.getRect(surface).overlaps(tester.getRect(answer())), isFalse);

    await tester.tap(find.byKey(const ValueKey('quick-reaction-👍')));
    await settle(tester);
    expect(gateway.reacts, [(12, '👍')]);
    expect(surface, findsNothing);
    await tearDownChat(tester, gateway);
  });

  testWidgets('«Copy message» copies the plain answer; «Select text» starts '
      'the selection', (tester) async {
    final clip = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip.add((call.arguments as Map)['text'] as String?);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final gateway = await open(tester);
    await tester.longPress(answer());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('message-action-copy')));
    await settle(tester);
    expect(clip, ['La tercera opción es la buena.']);
    expect(overlays(tester), isEmpty);

    await tester.longPress(answer());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('message-action-select')));
    await settle(tester);
    expect(find.byKey(const ValueKey('message-actions-surface')), findsNothing);
    final selected = overlays(tester);
    expect(selected, hasLength(1));
    expect(selected.single.toolbarIsVisible, isTrue);
    await tearDownChat(tester, gateway);
  });

  testWidgets('control: reactions off keeps the plain long-press selection', (
    tester,
  ) async {
    final reactions = MessageReactionPrefs.forTesting(null);
    MessageReactionPrefs.debugUse(reactions);
    addTearDown(() => MessageReactionPrefs.debugUse(null));
    final gateway = _StreamingGateway();
    await pumpChat(tester, gateway, history: _history());
    await settle(tester);
    await tester.longPress(answer());
    await settle(tester);
    expect(find.byKey(const ValueKey('message-actions-surface')), findsNothing);
    expect(overlays(tester), hasLength(1));
    await tearDownChat(tester, gateway);
  });
}
