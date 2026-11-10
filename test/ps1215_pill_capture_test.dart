import 'support/live_chat_v4.dart';

// ps1215: PNG capture (412×915, Spanish, dark) of ordinary live tool work
// inside the transcript after leaving and re-entering it, without a footer.
// Writes PNGs only when PS1215_SHOTS_DIR is set; otherwise it just checks
// the frames build without exceptions.
import 'dart:io';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart' show debugInlineClockWhenFolded;
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart'
    show formatTurnElapsed;
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;
import 'support/design_shots.dart' show loadDesignFonts;
import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

final _connection = SavedConnection(
  id: 'peer',
  label: 'Peer',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _session = Session(
  id: 'stored-peer',
  title: 'Peer',
  model: 'hermes-agent',
  source: 'api_server',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: 0,
);

/// The turn starts here on the server. The tests move [_Wall] around it.
final _turnStart = DateTime.utc(2026, 10, 2, 9);

class _Wall {
  DateTime now = _turnStart;
  int ms() => now.millisecondsSinceEpoch;
  void advance(Duration by) => now = now.add(by);
}

DesktopSessionSnapshot _snapshot({
  required bool running,
  DateTime? turnStartedAt,
  bool todos = false,
}) => DesktopSessionSnapshot.fromJson(
  {
    'session_id': 'runtime-peer',
    'session_key': 'stored-peer',
    'message_count': 1,
    'messages': [peer.publicSnapshot],
    'running': running,
    if (running) 'inflight': {'assistant': '', 'streaming': true},
    if (turnStartedAt != null)
      'turn_started_at': turnStartedAt.millisecondsSinceEpoch / 1000,
    if (todos)
      'todo_state': {
        'revision': 2,
        'todos': [
          {'id': '1', 'content': 'Leer el informe', 'status': 'completed'},
          {
            'id': '2',
            'content': 'Arreglar la pastilla',
            'status': 'in_progress',
          },
          {'id': '3', 'content': 'Probar en el móvil', 'status': 'pending'},
        ],
      },
  },
  requestedStoredSessionId: 'stored-peer',
  created: false,
  method: 'session.resume',
);

/// Read the rendered transcript clock, normalizing its localized seconds to
/// the m:ss representation used by this re-entry regression.
String? _elapsed(WidgetTester tester) {
  final clock = find.byKey(const ValueKey('chat-inline-activity-clock'));
  if (clock.evaluate().isEmpty) return null;
  final shown = tester.widget<Text>(clock).data!;
  if (shown.endsWith('s')) {
    return formatTurnElapsed(
      Duration(seconds: int.parse(shown.substring(0, shown.length - 1))),
    );
  }
  return shown;
}

const _shotKey = ValueKey('ps1215-shot');

Future<void> _save(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final dir = Platform.environment['PS1215_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  // These tests pin the clock itself; the folded row hides it (video).
  setUp(() => debugInlineClockWhenFolded = true);
  tearDown(() => debugInlineClockWhenFolded = false);
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'onboarding_done': true,
      'theme_mode': 'dark',
    });
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
          case 'readAll':
            return Map<String, String>.from(secure);
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
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
    final temp = Directory.systemTemp.createTempSync('ps1215_shot_');
    addTearDown(() => temp.deleteSync(recursive: true));
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => temp.path,
    );
  });

  testWidgets('es dark: live transcript work after re-entry', (tester) async {
    await loadDesignFonts();
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    final wall = _Wall()..advance(const Duration(seconds: 5));
    final service = ActiveChatService(
      attachDesktopRuntimeOnLoad: true,
      compressionRestoreStore: testCompressionRestoreStore(),
      globalActivity: GlobalActivityAggregate.inMemory(),
    );
    final gateway = peer.PeerGateway(
      _snapshot(running: true, turnStartedAt: _turnStart, todos: true),
    );
    final chat = service.attach(
      connection: _connection,
      sessionId: 'stored-peer',
      sessionTitle: 'Peer',
      sessionSnapshot: _session,
      api: testApiClient(
        baseUrl: 'https://example.invalid',
        httpClient: MockClient((_) async => http.Response('nf', 404)),
      ),
      desktopGateway: gateway,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
      wallClockMsForTesting: wall.ms,
    );
    await tester.runAsync(chat.loadMessages);

    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: HermesApp(
          connManager: manager,
          appLock: AppLockService(prefs),
          approvalPolicy: ApprovalPolicyService(prefs),
          fontSize: FontSizeService(prefs),

          sshManager: SshManager(secure, manager),
          sftpTransfers: SftpTransferService(
            SshManager(secure, manager),
            NotificationService(prefs),
          ),
          sshSessions: SshSessionService(SshManager(secure, manager)),
          notifications: NotificationService(prefs),
          activeChats: service,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));

    void push() =>
        Navigator.of(tester.element(find.byType(Navigator).first)).push(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) =>
                ChatScreen(connection: _connection, session: _session),
          ),
        );

    push();
    await tester.pump();
    gateway.emit('tool.start', {
      'tool_id': 't1',
      'name': 'terminal',
      'args': {'command': 'pytest -q'},
    });
    await tester.pump(const Duration(milliseconds: 16));
    wall.advance(const Duration(seconds: 2));
    gateway.emit('tool.complete', {'tool_id': 't1', 'name': 'terminal'});
    gateway.emit('tool.start', {
      'tool_id': 't2',
      'name': 'read_file',
      'args': {'path': '/tmp/a/informe.md'},
    });
    await tester.pump(const Duration(milliseconds: 16));
    wall.advance(const Duration(seconds: 23));

    // Leave at +30 s, come back at +50 s.
    Navigator.of(tester.element(find.byType(ChatScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    wall.advance(const Duration(seconds: 20));
    push();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('activity-pill')), findsNothing);
    // The live look (9 nov): «Trabajando» on the card, the words spoken.
    expect(
      tester.widget<Semantics>(inlineActivity).properties.label,
      contains('informe.md'),
    );
    await openInlineDetails(tester);
    expect(find.byKey(const ValueKey('turn-step-card-t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('turn-step-mark-t2')), findsOneWidget);
    expect(wall.now.difference(chat.turnClockOrigin!).inSeconds, 50);
    await _save(tester, 'ps1215_transcript_reentry_running_tool_es_dark');

    // The ordinary turn clock is in the conversation between tools. Keep
    // the running-tool assertions above and verify its visible successor too.
    gateway.emit('tool.complete', {'tool_id': 't2', 'name': 'read_file'});
    // loadMessages subscribed to this gateway in runAsync; flush that zone
    // before advancing the widget frames that consume its service events.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 300));
    final status = find.byKey(const ValueKey('chat-inline-activity'));
    expect(status.hitTestable(), findsOneWidget);
    expect(_elapsed(tester), '0:50');
    expect(
      tester.getRect(status).bottom,
      lessThan(
        tester.getRect(find.byKey(const ValueKey('chat-composer-host'))).top,
      ),
    );
    // Still running between tools: the live phase owns the status line.
    // Worked/Trabajó belongs to the finished-turn summary (3d394d9f).
    expect(chat.isStreaming, isTrue);
    // The live look (9 nov): the card says «Trabajando» while it runs.
    expect(tester.widget<Text>(inlineLabel).data, startsWith('Trabajando'));
    expect(_elapsed(tester), '0:50');
    expect(find.textContaining('Trabajó', findRichText: true), findsNothing);
    expect(find.byKey(const ValueKey('activity-pill')), findsNothing);
    await _save(tester, 'ps1215_transcript_reentry_es_dark');

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
}
