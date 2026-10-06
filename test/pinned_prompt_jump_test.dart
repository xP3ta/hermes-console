// QA 9491: tapping the slim pinned prompt must open THAT prompt, also in a
// long chat whose earlier pages were loaded while reading back.
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
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _storedId = 'stored-pinned-jump';

String _prompt(int id) => 'Pregunta número $id del lector';

final class _Server {
  _Server(int rows) {
    for (var id = 1; id <= rows; id++) {
      _rows.add({
        'id': id,
        'session_id': _storedId,
        'role': id.isOdd ? 'user' : 'assistant',
        'content': id.isOdd
            ? _prompt(id)
            : List.filled(
                40,
                'Respuesta $id: un párrafo largo que ocupa varias líneas en '
                'la pantalla del teléfono para que cada turno sea alto.',
              ).join('\n\n'),
        'timestamp': 1790000000 + id,
      });
    }
  }

  final List<Map<String, Object?>> _rows = [];

  http.Client client() => MockClient((request) async {
    if (request.url.path != '/api/sessions/$_storedId/messages') {
      return http.Response('{"error":"not found"}', 404);
    }
    final query = request.url.queryParameters;
    final limit = int.parse(query['limit'] ?? '500').clamp(1, 500);
    final offset = int.parse(query['offset'] ?? '0');
    final end = (_rows.length - offset).clamp(0, _rows.length);
    final start = (end - limit).clamp(0, end);
    final page = _rows.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': _storedId,
        'data': page,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': 'latest',
          'returned': page.length,
        },
      }),
      200,
    );
  });
}

final _connection = SavedConnection(
  id: 'pinned-jump-conn',
  label: 'Pinned jump',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
);

const _session = Session(
  id: _storedId,
  title: 'Long chat',
  model: 'hermes-agent',
  source: 'desktop',
  messageCount: 400,
  isActive: true,
  preview: '',
  startedAt: 0,
);

Future<(ActiveChat, ActiveChatService)> _open(
  WidgetTester tester,
  _Server server,
) async {
  SharedPreferences.setMockInitialValues({'onboarding_done': true});
  final prefs = await SharedPreferences.getInstance();
  await PinnedPromptPrefs.load(prefs);
  addTearDown(() => PinnedPromptPrefs.debugUse(null));
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = activeChats.attach(
    connection: _connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    sessionSnapshot: _session,
    initialStoredSessionId: _storedId,
    api: ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'test-key',
      httpClient: server.client(),
    ),
    attachDesktopRuntimeOnLoad: false,
    disableForegroundKeepAlive: true,
  );
  await chat.loadMessages(expectedMessageCount: 400);
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
  final context = tester.element(find.byType(Navigator).first);
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => ChatScreen(
        connection: _connection,
        session: _session,
        initialStoredSessionId: chat.serverSessionId,
      ),
    ),
  );
  for (var frame = 0; frame < 60; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return (chat, activeChats);
}

Finder _transcript() => find.descendant(
  of: find.byType(ChatScrollInteractionGuard),
  matching: find.byType(ListView),
);

Finder _sticky() => find.byKey(const ValueKey('chat-sticky-prompt'));

Future<void> _frames(WidgetTester tester, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// The prompt id the pinned header shows, read from its text.
int? _stickyId(WidgetTester tester) {
  if (_sticky().evaluate().isEmpty) return null;
  for (final element
      in find
          .descendant(of: _sticky(), matching: find.byType(RichText))
          .evaluate()) {
    final text = (element.widget as RichText).text.toPlainText();
    final match = RegExp(r'Pregunta número (\d+) del lector').firstMatch(text);
    if (match != null) return int.parse(match.group(1)!);
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => '/tmp',
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  testWidgets('tapping the pinned prompt of a long chat with earlier pages '
      'loaded opens that prompt at the top', (tester) async {
    final server = _Server(400);
    final (chat, service) = await _open(tester, server);
    final firstPage = chat.messages.length;
    expect(firstPage, lessThan(400));

    ScrollPosition position() =>
        tester.widget<ListView>(_transcript()).controller!.position;
    // Read back to the oldest loaded row, then with the finger until an
    // earlier page is loaded.
    for (var i = 0; i < 40 && chat.messages.length <= firstPage; i++) {
      position().jumpTo(position().maxScrollExtent);
      await _frames(tester, 4);
      await tester.timedDrag(
        _transcript(),
        const Offset(0, 400),
        const Duration(milliseconds: 300),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await _frames(tester, 20);
    }
    expect(
      chat.messages.length,
      greaterThan(firstPage),
      reason: 'precondition: an earlier page was loaded while reading',
    );
    // Settle inside a tall reply of the earlier page, so the header pins
    // its prompt.
    position().jumpTo(position().maxScrollExtent - 5000);
    await _frames(tester, 20);
    for (var i = 0; i < 12 && _stickyId(tester) == null; i++) {
      await tester.timedDrag(
        _transcript(),
        const Offset(0, 230),
        const Duration(milliseconds: 200),
      );
      await _frames(tester, 20);
    }
    final id = _stickyId(tester);
    expect(id, isNotNull, reason: 'precondition: the header pins a prompt');
    final before = find.descendant(
      of: _transcript(),
      matching: find.text(_prompt(id!), skipOffstage: false),
      skipOffstage: false,
    );
    if (before.evaluate().isNotEmpty) {
      expect(
        tester.getBottomLeft(before).dy,
        lessThanOrEqualTo(tester.getRect(_transcript()).top),
        reason: 'precondition: the prompt bubble itself is off screen',
      );
    }

    await tester.tap(_sticky());
    await _frames(tester, 120);

    final bubble = find.descendant(
      of: _transcript(),
      matching: find.text(_prompt(id)),
    );
    expect(
      bubble,
      findsOneWidget,
      reason: 'the tapped prompt ($id) is on screen after the jump',
    );
    final viewport = tester.getRect(_transcript());
    final top = tester.getTopLeft(bubble).dy;
    expect(top, greaterThanOrEqualTo(viewport.top));
    expect(
      top,
      lessThan(viewport.top + 120),
      reason: 'the tapped prompt sits at the top of the transcript',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
}
