import 'dart:io';

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

// A named profile (a bot) whose own API server route answers 401 and whose
// Dashboard refuses the profile read too. The chat itself streams over the
// gateway socket, so what the user sees must depend on whether anything is
// actually missing from the screen.

final _connection = SavedConnection(
  id: 'profile-dashboard-access',
  label: 'Profile access',
  host: 'example.invalid',
  port: 443,
  apiKey: 'main-connection-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _profile = 'research';
const _sessionId = 'stored-bot';

const _rows = <Map<String, dynamic>>[
  {'id': 1, 'role': 'user', 'content': 'hola bot'},
  {'id': 2, 'role': 'assistant', 'content': 'hola humano'},
];

class _Routes {
  final gatewayPaths = <String>[];
  final dashboardPaths = <String>[];

  http.Client gateway() => MockClient((request) async {
    gatewayPaths.add(request.url.path);
    // The connection key is not this profile's key.
    return http.Response('{"error":{"code":"gateway_auth_failed"}}', 401);
  });

  http.Client dashboard() => MockClient((request) async {
    dashboardPaths.add(request.url.path);
    return http.Response('{"detail":"Forbidden"}', 403);
  });
}

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
  final support = Directory.systemTemp.createTempSync('pdash-support');
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (_) async => support.path,
  );
}

Session _session() => Session.fromJson(const {
  'id': _sessionId,
  'title': 'Bot',
  'profile': _profile,
  'message_count': 2,
  'started_at': 1790000000,
});

Future<(ActiveChatService, ActiveChat)> _open(
  WidgetTester tester,
  _Routes routes, {
  required bool withRows,
  StoredSessionMessageLoader? loader,
  Future<void> Function(ActiveChat chat)? beforeOpen,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final session = _session();
  final chat = activeChats.attach(
    connection: _connection,
    sessionId: _sessionId,
    sessionTitle: session.title,
    sessionSnapshot: session,
    sessionProfile: _profile,
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'main-connection-key',
      httpClient: routes.gateway(),
    ),
    transcriptDashboard: DashboardClient(
      host: 'example.invalid',
      useHttps: true,
      manualToken: 'dashboard-session',
      httpClientOverride: routes.dashboard(),
    ),
    // The rows the gateway socket already delivered.
    storedMessageLoader:
        loader ?? (withRows ? (_, _) async => List.of(_rows) : null),
    attachDesktopRuntimeOnLoad: false,
    disableForegroundKeepAlive: true,
  );
  if (withRows) {
    await tester.runAsync(
      () => chat.loadMessages(expectedMessageCount: 2, profile: _profile),
    );
  }
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
  if (beforeOpen != null) {
    await tester.runAsync(() => beforeOpen(chat));
  }
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
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return (activeChats, chat);
}

Future<void> _close(WidgetTester tester, ActiveChatService chats) async {
  await tester.pumpWidget(const SizedBox.shrink());
  chats.dispose();
  await tester.pump(const Duration(minutes: 5));
}

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(ChatScreen)));

Finder _accessNotice(Strings s) => find.text(s.chaErrProfileDashboardAccess);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_mockPlatform);

  testWidgets('a background read that cannot reach the profile does not '
      'cover a chat that is on screen with an access notice', (tester) async {
    final routes = _Routes();
    final (chats, chat) = await _open(tester, routes, withRows: true);
    final s = _strings(tester);
    expect(find.textContaining('hola humano'), findsWidgets);

    // A background whole-transcript read (subagent page, delivery settle,
    // recovery) meets the 401 and the Dashboard refusal.
    await tester.runAsync(() async {
      try {
        await chat.loadChildTranscript('child-1');
      } on Object {
        // The caller of this background read handles its own failure.
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(chat.profileTranscriptAccessBlocked, isTrue);
    expect(routes.gatewayPaths, isNotEmpty);
    expect(routes.dashboardPaths, isNotEmpty);
    expect(_accessNotice(s), findsNothing);
    expect(find.text(s.chaMessagesError), findsNothing);
    expect(find.textContaining('hola humano'), findsWidgets);
    await _close(tester, chats);
  });

  testWidgets('a screen load that succeeds while the profile is blocked for '
      'REST shows the rows without an access notice', (tester) async {
    final routes = _Routes();
    final (chats, chat) = await _open(
      tester,
      routes,
      withRows: true,
      beforeOpen: (chat) async {
        try {
          await chat.loadChildTranscript('child-1');
        } on Object {
          // Blocks the profile for the rest of this chat.
        }
        // The screen performs its own load when it opens.
        chat.messagesLoaded = false;
      },
    );
    final s = _strings(tester);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(chat.profileTranscriptAccessBlocked, isTrue);
    expect(chat.messagesLoaded, isTrue);
    expect(find.textContaining('hola humano'), findsWidgets);
    expect(_accessNotice(s), findsNothing);
    await _close(tester, chats);
  });

  testWidgets('an empty chat whose history neither route serves says which '
      'feature is missing and what to do', (tester) async {
    final routes = _Routes();
    final (chats, _) = await _open(tester, routes, withRows: false);
    final s = _strings(tester);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(_accessNotice(s), findsOneWidget);
    final text = s.chaErrProfileDashboardAccess;
    // Precise: names the history, the Dashboard sign-in and the fix; no
    // server configuration jargon the user cannot act on from the phone.
    expect(text, isNot(contains('API_SERVER_KEY')));
    expect(text.toLowerCase(), contains('dashboard'));
    await _close(tester, chats);
  });

  testWidgets('control: any other refresh failure over a chat on screen '
      'still shows the refresh notice', (tester) async {
    final routes = _Routes();
    var loads = 0;
    final (chats, _) = await _open(
      tester,
      routes,
      withRows: true,
      loader: (_, _) async {
        loads += 1;
        if (loads == 1) return List.of(_rows);
        throw StateError('server unavailable');
      },
      beforeOpen: (chat) async => chat.messagesLoaded = false,
    );
    final s = _strings(tester);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(loads, greaterThan(1));
    expect(find.textContaining('hola humano'), findsWidgets);
    expect(find.text(s.chaMessagesError), findsOneWidget);
    await _close(tester, chats);
  });
}
