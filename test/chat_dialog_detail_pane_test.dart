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
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/adaptive_list_detail.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';

import 'support/test_api_client.dart';

// The chat's own confirmations (delete this conversation, YOLO for this
// session) open on the app's root navigator. In the medium layout the chat
// lives in the detail pane's nested navigator: their buttons must close the
// dialog there, never pop the chat underneath it.

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
const _openChat = ValueKey('dialog-pane-open-chat');

SavedConnection _connection() => SavedConnection(
  id: 'conn-dialog-pane',
  label: 'Dialog pane',
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

ApiClient _safeApi() => testApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  connectionId: 'conn-dialog-pane',
  httpClient: MockClient((request) async {
    if (request.url.path == '/api/status' ||
        request.url.path == '/api/sessions') {
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  }),
);

/// Pumps frames until [done] holds, failing with [what] after [max].
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration max = const Duration(seconds: 3),
}) async {
  const step = Duration(milliseconds: 50);
  var waited = Duration.zero;
  while (!done() && waited < max) {
    await tester.pump(step);
    waited += step;
  }
  expect(done(), isTrue, reason: 'Timed out waiting for $what');
}

/// The route of [finder]'s widget has finished its entrance transition.
bool _routeSettled(WidgetTester tester, Finder finder) {
  if (finder.evaluate().length != 1) return false;
  final route = ModalRoute.of(tester.element(finder));
  return route?.animation?.status == AnimationStatus.completed;
}

/// A tap on [finder] lands inside the view. Fails before the tap, so an
/// unsettled layout is never mistaken for a failure of the dialog fix.
void _expectOnScreen(WidgetTester tester, Finder finder, String what) {
  expect(finder, findsOneWidget, reason: '$what is not in the tree');
  final view = tester.view.physicalSize / tester.view.devicePixelRatio;
  final centre = tester.getCenter(finder);
  expect(
    (Offset.zero & view).contains(centre),
    isTrue,
    reason:
        '$what is at $centre, outside the ${view.width}x${view.height} '
        'view: the layout has not settled',
  );
}

/// A running app at 700 dp (medium) with the chat open in the detail pane.
Future<AdaptiveListDetailState> _pumpChatInPane(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(700, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'onboarding_done': true});
  final prefs = await SharedPreferences.getInstance();
  final connectionManager = await ConnectionManager.create(prefs);
  final secureStorage = SecureStorage();
  final activeChats = ActiveChatService(
    desktopGatewayFactory: (_) => _StreamingGateway(),
    defaultApiForTesting: (_) => _safeApi(),
  );
  final connection = _connection();
  final gateway = _StreamingGateway();
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
  addTearDown(() async {
    await gateway.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

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

  final navigator = tester.state<NavigatorState>(
    find.byType(Navigator).first,
  );
  unawaited(
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: AdaptiveListDetail(
            placeholder: const SizedBox.shrink(),
            list: Builder(
              builder: (listContext) => Center(
                child: TextButton(
                  key: _openChat,
                  onPressed: () => pushInDetailPane<void>(
                    listContext,
                    MaterialPageRoute<void>(
                      builder: (_) => ChatScreen(
                        connection: connection,
                        session: _session(),
                      ),
                    ),
                  ),
                  child: const Text('Open chat'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final open = find.byKey(_openChat);
  await _pumpUntil(
    tester,
    () => _routeSettled(tester, open),
    what: 'the list route',
  );
  _expectOnScreen(tester, open, 'Open chat');
  await tester.tap(open);
  final chatScreen = find.byType(ChatScreen);
  await _pumpUntil(
    tester,
    () => _routeSettled(tester, chatScreen),
    what: 'the chat page transition in the pane',
  );
  final pane = tester.state<AdaptiveListDetailState>(
    find.byType(AdaptiveListDetail),
  );
  final chatContext = tester.element(chatScreen);
  expect(pane.hasDetail, isTrue);
  expect(
    identical(
      Navigator.of(chatContext),
      Navigator.of(chatContext, rootNavigator: true),
    ),
    isFalse,
    reason: 'the chat must live in the pane navigator',
  );
  return pane;
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

  testWidgets('700 dp: cancelling the delete dialog keeps the chat open', (
    tester,
  ) async {
    final pane = await _pumpChatInPane(tester);
    final chatScreen = find.byType(ChatScreen);
    final chatState = tester.state(chatScreen);
    final strings = Strings.of(tester.element(chatScreen));

    final notch = find.byKey(const ValueKey('chat-notch'));
    _expectOnScreen(tester, notch, 'The chat notch');
    await tester.tap(notch);
    final sheet = find.byKey(const ValueKey('chat-control-sheet'));
    await _pumpUntil(
      tester,
      () => _routeSettled(tester, sheet),
      what: 'the chat control sheet',
    );
    await tester.pump(const Duration(milliseconds: 350));
    final delete = find.byKey(const ValueKey('chat-control-delete'));
    await tester.scrollUntilVisible(
      delete,
      260,
      scrollable: find
          .descendant(of: sheet, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pump(const Duration(milliseconds: 350));
    _expectOnScreen(tester, delete, 'Delete in the control sheet');
    await tester.tap(delete);

    final dialog = find.byType(AlertDialog);
    await _pumpUntil(
      tester,
      () => _routeSettled(tester, dialog),
      what: 'the delete dialog',
    );
    expect(
      find.descendant(of: dialog, matching: find.text(strings.sesDeleteTitle)),
      findsOneWidget,
    );
    final cancel = find.descendant(
      of: dialog,
      matching: find.text(strings.sesCancel),
    );
    _expectOnScreen(tester, cancel, 'Cancel in the delete dialog');
    await tester.tap(cancel);
    // Bounded pumps: a broken pop must fail, not await the unresolved dialog.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(AlertDialog), findsNothing);
    expect(chatScreen, findsOneWidget);
    expect(tester.state(chatScreen), same(chatState));
    expect(chatState.mounted, isTrue);
    expect(pane.hasDetail, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('700 dp: cancelling YOLO keeps the chat and its sheet open', (
    tester,
  ) async {
    final pane = await _pumpChatInPane(tester);
    final chatScreen = find.byType(ChatScreen);
    final chatState = tester.state(chatScreen);
    final strings = Strings.of(tester.element(chatScreen));

    final permissions = find.byKey(const ValueKey('status-pill-permissions'));
    _expectOnScreen(tester, permissions, 'The permissions pill');
    await tester.tap(permissions);
    final modeSheet = find.byKey(const ValueKey('chat-mode-dialog'));
    await _pumpUntil(
      tester,
      () => _routeSettled(tester, modeSheet),
      what: 'the permissions sheet',
    );
    await tester.pump(const Duration(milliseconds: 400));
    final yolo = find.byKey(const ValueKey('chat-mode-option-yolo'));
    _expectOnScreen(tester, yolo, 'The YOLO option');
    await tester.tap(yolo);

    final dialog = find.byType(AlertDialog);
    await _pumpUntil(
      tester,
      () => _routeSettled(tester, dialog),
      what: 'the YOLO dialog',
    );
    expect(
      find.descendant(of: dialog, matching: find.text(strings.chaYoloTitle)),
      findsOneWidget,
    );
    final cancel = find.descendant(
      of: dialog,
      matching: find.text(strings.chaCancel),
    );
    _expectOnScreen(tester, cancel, 'Cancel in the YOLO dialog');
    await tester.tap(cancel);
    // Bounded pumps: a broken pop must fail, not await the unresolved dialog.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(AlertDialog), findsNothing);
    expect(modeSheet, findsOneWidget);
    expect(chatScreen, findsOneWidget);
    expect(tester.state(chatScreen), same(chatState));
    expect(chatState.mounted, isTrue);
    expect(pane.hasDetail, isTrue);
    expect(tester.takeException(), isNull);
  });
}
