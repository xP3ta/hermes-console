import 'dart:async';

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
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

final _connection = SavedConnection(
  id: 'reopen-screen',
  label: 'Reopen screen',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _session = Session(
  id: 'stored-reopen-screen',
  title: 'Reopen screen',
  model: 'hermes-agent',
  source: 'api_server',
  messageCount: 2,
  isActive: false,
  preview: '',
  startedAt: 0,
);

const _rows = <Map<String, dynamic>>[
  {'id': 1, 'role': 'user', 'content': 'cached question'},
  {'id': 2, 'role': 'assistant', 'content': 'cached answer'},
];

ActiveChat _attach(
  ActiveChatService service,
  StoredSessionMessageLoader loader,
) => service.attach(
  connection: _connection,
  sessionId: _session.id,
  sessionTitle: _session.title,
  sessionSnapshot: _session,
  api: ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-key',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  ),
  storedMessageLoader: loader,
  attachDesktopRuntimeOnLoad: false,
  disableForegroundKeepAlive: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
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
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async => call.method == 'isRunningService' ? false : null,
        );
  });

  testWidgets('reopening a recent chat paints its cached transcript on the '
      'first frame while the network read is still pending', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    final activeChats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );

    // A previous visit loaded the transcript and closed the chat.
    final previous = _attach(activeChats, (_, _) async => List.of(_rows));
    await tester.runAsync(() => previous.loadMessages(expectedMessageCount: 2));
    activeChats.release(_connection.id, _session.id);
    expect(activeChats.of(_connection.id, _session.id), isNull);

    // This visit's network read never answers during the test.
    final slowNetwork = Completer<List<Map<String, dynamic>>>();
    var networkReads = 0;
    _attach(activeChats, (_, _) {
      networkReads += 1;
      return slowNetwork.future;
    });

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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));

    final context = tester.element(find.byType(Navigator).first);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            ChatScreen(connection: _connection, session: _session),
      ),
    );
    await tester.pump();
    await tester.pump();

    final strings = Strings.of(tester.element(find.byType(ChatScreen)));
    expect(find.textContaining('cached answer'), findsWidgets);
    expect(find.textContaining('cached question'), findsWidgets);
    expect(find.text(strings.commonLoading), findsNothing);
    expect(networkReads, 1);
    expect(slowNetwork.isCompleted, isFalse);

    slowNetwork.complete(List.of(_rows));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    activeChats.dispose();
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('returning to the foreground keeps the open chat and its '
      'visible transcript', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    final activeChats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    var reads = 0;
    final chat = _attach(activeChats, (_, _) async {
      reads += 1;
      // Every read after the first never answers: a reload from scratch
      // would leave the screen on the loader.
      if (reads > 1) return Completer<List<Map<String, dynamic>>>().future;
      return List.of(_rows);
    });
    await tester.runAsync(() => chat.loadMessages(expectedMessageCount: 2));

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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));
    final context = tester.element(find.byType(Navigator).first);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            ChatScreen(connection: _connection, session: _session),
      ),
    );
    await tester.pump();
    await tester.pump();
    final screenState = tester.state(find.byType(ChatScreen));
    expect(find.textContaining('cached answer'), findsWidgets);

    // Background long enough for the idle-socket timer, then foreground.
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(seconds: 90));
    for (final state in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final strings = Strings.of(tester.element(find.byType(ChatScreen)));
    expect(
      identical(tester.state(find.byType(ChatScreen)), screenState),
      isTrue,
    );
    expect(
      identical(activeChats.of(_connection.id, _session.id), chat),
      isTrue,
    );
    expect(find.textContaining('cached answer'), findsWidgets);
    expect(find.text(strings.commonLoading), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    activeChats.dispose();
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('reopening a cached chat still marks what arrived while away', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    final activeChats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );

    // A previous visit read up to the cached answer and closed the chat.
    final previous = _attach(activeChats, (_, _) async => List.of(_rows));
    await tester.runAsync(() => previous.loadMessages(expectedMessageCount: 2));
    activeChats.release(_connection.id, _session.id);
    await prefs.setString(
      'chat_last_read_v1.${_connection.id}.${_session.id}',
      'row:2',
    );

    // Another surface continued the conversation meanwhile.
    final network = Completer<List<Map<String, dynamic>>>();
    _attach(activeChats, (_, _) => network.future);

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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));
    final context = tester.element(find.byType(Navigator).first);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            ChatScreen(connection: _connection, session: _session),
      ),
    );
    await tester.pump();
    await tester.pump();
    final divider = find.byKey(const ValueKey('chat-new-since-divider'));
    expect(find.textContaining('cached answer'), findsWidgets);
    expect(divider, findsNothing, reason: 'the cached rows hold nothing new');

    network.complete([
      ..._rows,
      {'id': 3, 'role': 'user', 'content': 'question from another surface'},
      {'id': 4, 'role': 'assistant', 'content': 'answer from another surface'},
    ]);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.textContaining('answer from another surface'), findsWidgets);
    expect(divider, findsOneWidget);
    final dividerTop = tester.getTopLeft(divider).dy;
    expect(
      tester.getTopLeft(find.textContaining('cached answer').first).dy,
      lessThan(dividerTop),
    );
    // QA 9489: the owner's own question from another surface is not news;
    // the divider marks the first reply.
    expect(
      tester
          .getTopLeft(
            find.textContaining('question from another surface').first,
          )
          .dy,
      lessThan(dividerTop),
    );
    expect(
      tester
          .getTopLeft(find.textContaining('answer from another surface').first)
          .dy,
      greaterThan(dividerTop),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    activeChats.dispose();
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('reopening a long cached chat lands on what arrived while away', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    final activeChats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );

    // A previous visit read up to the cached answer and closed the chat.
    final previous = _attach(activeChats, (_, _) async => _longRows(1, 40));
    await tester.runAsync(() => previous.loadMessages(expectedMessageCount: 2));
    activeChats.release(_connection.id, _session.id);
    await prefs.setString(
      'chat_last_read_v1.${_connection.id}.${_session.id}',
      'row:80',
    );

    // Another surface continued the conversation meanwhile.
    final network = Completer<List<Map<String, dynamic>>>();
    _attach(activeChats, (_, _) => network.future);

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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));
    final context = tester.element(find.byType(Navigator).first);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            ChatScreen(connection: _connection, session: _session),
      ),
    );
    await tester.pump();
    await tester.pump();
    final divider = find.byKey(const ValueKey('chat-new-since-divider'));
    expect(find.textContaining('long answer 40.'), findsWidgets);
    expect(divider, findsNothing, reason: 'the cached rows hold nothing new');

    network.complete(_longRows(1, 60));
    final list = find.descendant(
      of: find.byType(ChatScreen),
      matching: find.byType(ListView),
    );
    bool landed() =>
        divider.evaluate().isNotEmpty &&
        (tester.getTopLeft(divider).dy - tester.getRect(list.first).top)
                .abs() <=
            1;
    // Wait for the landing itself (bounded), not for a fixed number of
    // frames: how many frames the lazy list needs is not a contract.
    for (var frame = 0; frame < 300 && !landed(); frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(divider, findsOneWidget, reason: 'the chat opens on the divider');
    final viewport = tester.getRect(list.first);
    expect(tester.getTopLeft(divider).dy, closeTo(viewport.top, 1));
    // QA 9489: the first news is the reply, not the owner's question.
    expect(find.textContaining('long answer 41.'), findsOneWidget);
    // One landing, then stillness.
    final landedAt = tester.getTopLeft(divider).dy;
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getTopLeft(divider).dy,
        landedAt,
        reason: 'frame $frame: the landing moved after it settled',
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    activeChats.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
}

List<Map<String, dynamic>> _longRows(int first, int last) => [
  for (var turn = first; turn <= last; turn++) ...[
    {
      'id': turn * 2 - 1,
      'role': 'user',
      'content': 'long question $turn with some extra context.',
    },
    {
      'id': turn * 2,
      'role': 'assistant',
      'content':
          'long answer $turn. This text takes several lines so that the '
          'transcript is much taller than the screen of the phone.',
    },
  ],
];
