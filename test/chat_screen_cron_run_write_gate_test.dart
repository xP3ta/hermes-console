import 'dart:convert';

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
  id: 'cron-gate-screen',
  label: 'Cron gate',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _runId = 'cron_job1_20261004_101500';

const _rows = <Map<String, dynamic>>[
  {'id': 1, 'role': 'user', 'content': 'scheduled prompt'},
  {'id': 2, 'role': 'assistant', 'content': 'scheduled answer'},
];

/// The run row the server answers on `GET /api/sessions/{id}`; tests flip it.
class _Server {
  Map<String, dynamic>? row;
  int rowReads = 0;
  final List<String> otherRequests = [];

  http.Client client() => MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/api/sessions/$_runId')) {
      rowReads += 1;
      final current = row;
      if (current == null) return http.Response('unavailable', 503);
      return http.Response(jsonEncode({'session': current}), 200);
    }
    otherRequests.add('${request.method} $path');
    return http.Response('unused', 500);
  });
}

Map<String, dynamic> _row({Object? endedAt, bool? schedulerOwned}) => {
  'id': _runId,
  'source': 'cron',
  'title': 'Daily digest',
  'message_count': 2,
  'started_at': 1790000000,
  'ended_at': endedAt,
  'scheduler_owned': ?schedulerOwned,
};

void _mockPlatform() {
  SharedPreferences.setMockInitialValues({'onboarding_done': true});
  final secure = <String, String>{};
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
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
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }
  messenger.setMockMethodCallHandler(
    const MethodChannel('flutter_foreground_task/methods'),
    (call) async => call.method == 'isRunningService' ? false : null,
  );
}

Future<ActiveChatService> _openRun(
  WidgetTester tester,
  _Server server,
  Session session,
) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = activeChats.attach(
    connection: _connection,
    sessionId: session.id,
    sessionTitle: session.title,
    sessionSnapshot: session,
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-key',
      httpClient: server.client(),
    ),
    storedMessageLoader: (_, _) async => List.of(_rows),
    attachDesktopRuntimeOnLoad: false,
    disableForegroundKeepAlive: true,
  );
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
          ChatScreen(connection: _connection, session: session),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return activeChats;
}

Future<void> _close(WidgetTester tester, ActiveChatService chats) async {
  await tester.pumpWidget(const SizedBox.shrink());
  chats.dispose();
  await tester.pump(const Duration(minutes: 5));
}

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(ChatScreen)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_mockPlatform);

  testWidgets('a cron run never closed opens view-only, without composer', (
    tester,
  ) async {
    final server = _Server()..row = _row(schedulerOwned: false);
    final chats = await _openRun(
      tester,
      server,
      Session.fromJson(_row(schedulerOwned: false)),
    );

    expect(find.textContaining('scheduled answer'), findsWidgets);
    expect(find.byKey(const ValueKey('send')), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text(_strings(tester).au1215CronRunViewOnly), findsOneWidget);
    await _close(tester, chats);
  });

  for (final viewOnly in [true, false]) {
    testWidgets(
      'rpl1215 ask about this on a ${viewOnly ? 'view-only' : 'writable'} '
      'cron run',
      (tester) async {
        final server = _Server()..row = _row(schedulerOwned: !viewOnly);
        final chats = await _openRun(
          tester,
          server,
          Session.fromJson(_row(schedulerOwned: !viewOnly)),
        );
        // A writable connection: only the run verdict hides the action.
        expect(_connection.readOnly, isFalse);
        final answer = find
            .textContaining('scheduled answer', findRichText: true)
            .first;
        await tester.longPressAt(
          tester.getTopLeft(answer) + const Offset(8, 8),
        );
        await tester.pump(const Duration(milliseconds: 400));
        final strings = _strings(tester);
        final copy = MaterialLocalizations.of(
          tester.element(find.byType(ChatScreen)),
        ).copyButtonLabel;
        // The selection menu itself opens either way.
        expect(find.text(copy), findsOneWidget);
        expect(
          find.text(strings.rpl1215AskAboutThis),
          viewOnly ? findsNothing : findsOneWidget,
        );
        await _close(tester, chats);
      },
    );
  }

  testWidgets('the opened run row decides before any server read answers', (
    tester,
  ) async {
    // The detail read fails: only the row the Cron surface opened is known.
    final server = _Server();
    final chats = await _openRun(
      tester,
      server,
      Session.fromJson(_row(schedulerOwned: false)),
    );

    expect(find.byType(TextField), findsNothing);
    expect(find.text(_strings(tester).au1215CronRunViewOnly), findsOneWidget);
    await _close(tester, chats);
  });

  testWidgets('a closed cron run keeps a writable composer', (tester) async {
    final server = _Server()..row = _row(endedAt: 1790000100);
    final chats = await _openRun(
      tester,
      server,
      Session.fromJson(_row(endedAt: 1790000100, schedulerOwned: false)),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text(_strings(tester).au1215CronRunViewOnly), findsNothing);
    await _close(tester, chats);
  });

  testWidgets('a cron run the scheduler still owns keeps a writable composer', (
    tester,
  ) async {
    final server = _Server()..row = _row(schedulerOwned: true);
    final chats = await _openRun(
      tester,
      server,
      Session.fromJson(_row(schedulerOwned: true)),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text(_strings(tester).au1215CronRunViewOnly), findsNothing);
    await _close(tester, chats);
  });

  testWidgets('a run that stops being resumable after opening refuses the '
      'send at send time and turns view-only', (tester) async {
    final server = _Server()..row = _row(schedulerOwned: true);
    final chats = await _openRun(
      tester,
      server,
      Session.fromJson(_row(schedulerOwned: true)),
    );
    expect(find.byType(TextField), findsOneWidget);
    final readsBeforeSend = server.rowReads;

    // The scheduler lost the run (process died) while the chat stayed open.
    server.row = _row(schedulerOwned: false);
    server.otherRequests.clear();
    await tester.enterText(find.byType(TextField), 'reply into the run');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final strings = _strings(tester);
    expect(server.rowReads, greaterThan(readsBeforeSend));
    expect(find.text(strings.au1215CronRunSendBlocked), findsOneWidget);
    expect(find.text(strings.au1215CronRunViewOnly), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(server.otherRequests.where((r) => r.startsWith('POST')), isEmpty);
    await _close(tester, chats);
  });

  testWidgets('a run row that cannot be read at send time refuses the send', (
    tester,
  ) async {
    final server = _Server()..row = _row(schedulerOwned: true);
    final chats = await _openRun(
      tester,
      server,
      Session.fromJson(_row(schedulerOwned: true)),
    );
    final readsBeforeSend = server.rowReads;

    server.row = null;
    await tester.enterText(find.byType(TextField), 'reply into the run');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(server.rowReads, greaterThan(readsBeforeSend));
    expect(
      find.text(_strings(tester).au1215CronRunSendBlocked),
      findsOneWidget,
    );
    expect(server.otherRequests.where((r) => r.startsWith('POST')), isEmpty);
    await _close(tester, chats);
  });

  testWidgets('a still-writable run passes the gate at send time', (
    tester,
  ) async {
    final server = _Server()..row = _row(schedulerOwned: true);
    final chats = await _openRun(
      tester,
      server,
      Session.fromJson(_row(schedulerOwned: true)),
    );
    final readsBeforeSend = server.rowReads;

    await tester.enterText(find.byType(TextField), 'reply into the run');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(server.rowReads, greaterThan(readsBeforeSend));
    expect(find.text(_strings(tester).au1215CronRunSendBlocked), findsNothing);
    expect(find.text(_strings(tester).au1215CronRunViewOnly), findsNothing);
    await _close(tester, chats);
  });
}
