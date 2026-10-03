// ps1215: the activity pill of a running chat keeps counting from the real
// turn start when the user leaves the chat and comes back, its expanded panel
// shows what is actually known (running tool, finished steps, tasks) or says
// honestly that nothing is known yet, and it is on screen on the first frame.
//
// Every clock in these tests is the injected wall clock of the chat; nothing
// depends on real time.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/widgets/compaction_dock.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;
import 'support/in_memory_compression_restore_storage.dart';

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

Finder get _pill => find.byKey(const ValueKey('activity-pill'));
Finder get _panel => find.byKey(const ValueKey('activity-panel'));

/// The pill's elapsed timer, or null when the pill shows none (or is absent).
String? _elapsed(WidgetTester tester) {
  final timer = find.descendant(
    of: _pill,
    matching: find.byKey(const ValueKey('activity-pill-elapsed')),
  );
  if (timer.evaluate().isEmpty) return null;
  return tester.widget<Text>(timer).data;
}

int _seconds(String? mss) {
  final parts = mss!.split(':').map(int.parse).toList();
  return parts.fold(0, (total, part) => total * 60 + part);
}

String _textIn(Finder root) => find
    .descendant(of: root, matching: find.byType(RichText))
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .where((text) => text.trim().isNotEmpty)
    .join(' | ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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
    // runAsync lets app init reach path_provider: answer with a temp dir.
    final temp = Directory.systemTemp.createTempSync('ps1215_pill_');
    addTearDown(() => temp.deleteSync(recursive: true));
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => temp.path,
    );
  });

  Future<void> boot(WidgetTester tester, ActiveChatService activeChats) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
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
  }

  void push(WidgetTester tester) {
    Navigator.of(tester.element(find.byType(Navigator).first)).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            ChatScreen(connection: _connection, session: _session),
      ),
    );
  }

  Future<void> leave(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(ChatScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(ChatScreen), findsNothing);
  }

  ActiveChatService newService() => ActiveChatService(
    attachDesktopRuntimeOnLoad: true,
    compressionRestoreStore: testCompressionRestoreStore(),
    globalActivity: GlobalActivityAggregate.inMemory(),
  );

  ActiveChat attach(
    ActiveChatService service,
    peer.PeerGateway gateway,
    _Wall wall,
  ) => service.attach(
    connection: _connection,
    sessionId: 'stored-peer',
    sessionTitle: 'Peer',
    sessionSnapshot: _session,
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-key',
      httpClient: MockClient((_) async => http.Response('nf', 404)),
    ),
    desktopGateway: gateway,
    allowUnownedDesktopSnapshotForTesting: true,
    disableForegroundKeepAlive: true,
    wallClockMsForTesting: wall.ms,
  );

  void roster(ActiveChatService service, String status) =>
      service.globalActivity.applyRoster(
        connectionId: 'peer',
        profile: 'default',
        replayEpoch: 'current',
        requestGeneration: service.globalActivity.beginRosterRequest(
          'peer',
          'default',
        ),
        roster: DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-peer',
              storedSessionId: 'stored-peer',
              status: status,
            ),
          ],
        ),
      );

  Future<void> tearDownApp(WidgetTester tester, ActiveChatService s) async {
    await tester.pumpWidget(const SizedBox.shrink());
    s.dispose();
    await tester.pump(const Duration(minutes: 5));
  }

  group('the pill timer survives leaving the chat', () {
    testWidgets('gateway turn start: leave at +30 s, back at +50 s shows '
        '0:50 on the first frame and keeps counting', (tester) async {
      final wall = _Wall()..advance(const Duration(seconds: 5));
      final service = newService();
      final gateway = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart),
      );
      final chat = attach(service, gateway, wall);
      await tester.runAsync(chat.loadMessages);
      expect(chat.isStreaming, isTrue);
      await boot(tester, service);

      push(tester);
      await tester.pump();
      expect(_seconds(_elapsed(tester)), 5);

      wall.advance(const Duration(seconds: 25));
      await tester.pump(const Duration(seconds: 1));
      expect(_seconds(_elapsed(tester)), 30);

      await leave(tester);
      wall.advance(const Duration(seconds: 20));
      push(tester);
      await tester.pump();
      expect(
        _seconds(_elapsed(tester)),
        50,
        reason: 'the timer counts from the turn start, not from the reopen',
      );
      var last = 50;
      for (var i = 0; i < 4; i++) {
        wall.advance(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        final now = _seconds(_elapsed(tester));
        expect(now, greaterThanOrEqualTo(last), reason: 'monotonic');
        last = now;
      }
      expect(last, 54);
      await tearDownApp(tester, service);
    });

    testWidgets('no gateway turn start: the origin seen on the first visit '
        'survives a leave and re-enter', (tester) async {
      final wall = _Wall();
      final service = newService();
      final gateway = peer.PeerGateway(_snapshot(running: true));
      final chat = attach(service, gateway, wall);
      await tester.runAsync(chat.loadMessages);
      expect(chat.isStreaming, isTrue);
      await boot(tester, service);

      push(tester);
      await tester.pump();
      wall.advance(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(_seconds(_elapsed(tester)), 30);

      await leave(tester);
      wall.advance(const Duration(seconds: 20));
      push(tester);
      await tester.pump();
      expect(_seconds(_elapsed(tester)), 50);
      await tearDownApp(tester, service);
    });

    testWidgets('chat released while away: the provisional first frame '
        'already shows ~0:50 and the resume never moves it back', (
      tester,
    ) async {
      final wall = _Wall();
      final service = newService();
      final first = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart, todos: true),
      );
      final previous = attach(service, first, wall);
      await tester.runAsync(previous.loadMessages);
      first.emit('tool.start', {
        'tool_id': 't1',
        'name': 'terminal',
        'args': {'command': 'pytest -q'},
      });
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      wall.advance(const Duration(seconds: 30));
      // Leaving disposed this chat (e.g. memory pressure): only the
      // in-memory remembered status is left.
      service.debugDisposeChatForTesting('peer', 'stored-peer');

      wall.advance(const Duration(seconds: 20));
      roster(service, 'working');
      final gateway = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart, todos: true),
      )..resumeHold = Completer<void>();
      attach(service, gateway, wall);
      await boot(tester, service);
      push(tester);
      await tester.pump();
      expect(_textIn(_pill), contains('terminal · pytest'));
      expect(
        _seconds(_elapsed(tester)),
        inInclusiveRange(50, 55),
        reason: 'provisional first frame: the remembered turn start',
      );
      var last = _seconds(_elapsed(tester));

      gateway.resumeHold!.complete();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final shown = _seconds(_elapsed(tester));
        expect(shown, greaterThanOrEqualTo(last), reason: 'never back');
        last = shown;
      }
      await tearDownApp(tester, service);
    });

    test('a new turn after a finished one starts from its own start and '
        'never inherits the old gateway start', () async {
      final wall = _Wall()..advance(const Duration(seconds: 40));
      final service = newService();
      addTearDown(service.dispose);
      final gateway = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart),
      );
      final chat = attach(service, gateway, wall);
      await chat.loadMessages();
      expect(chat.anchorTurnClock()!.isAtSameMomentAs(_turnStart), isTrue);

      gateway.snapshot = _snapshot(running: false);
      gateway.emit('message.complete', {'text': 'Hecho'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.isStreaming, isFalse);
      expect(chat.turnClockOrigin, isNull, reason: 'idle chat: no timer');

      wall.advance(const Duration(seconds: 10));
      // A stale snapshot still names the finished turn's start.
      gateway.snapshot = _snapshot(running: true, turnStartedAt: _turnStart);
      unawaited(
        chat.send(
          fullText: 'otra cosa',
          model: 'hermes-agent',
          history: chat.messages,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.isStreaming, isTrue);
      final origin = chat.turnClockOrigin;
      expect(
        origin!.isAtSameMomentAs(wall.now),
        isTrue,
        reason: 'this device saw the turn start, not the stale server one',
      );
      wall.advance(const Duration(seconds: 3));
      expect(chat.anchorTurnClock(), origin);
      expect(wall.now.difference(chat.turnClockOrigin!).inSeconds, 3);
    });

    testWidgets('compaction mini-pill keeps its start across a leave and '
        're-enter (guard)', (tester) async {
      final wall = _Wall();
      final service = newService();
      final gateway = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart),
      );
      final chat = attach(service, gateway, wall);
      await tester.runAsync(chat.loadMessages);
      await boot(tester, service);
      push(tester);
      await tester.pump();
      gateway.emit('status.update', const {
        'kind': 'compacting',
        'text': 'Compacting context — summarizing earlier conversation',
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      DateTime shownStart() => tester
          .widget<CompactionPillSegment>(find.byType(CompactionPillSegment))
          .compaction
          .startedAt;
      final started = chat.desktopCompactionStartedAt;
      expect(started, isNotNull);
      expect(shownStart(), started);

      await leave(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(
        service.liveStatusOf('peer', 'stored-peer'),
        isNotNull,
        reason: 'the compacting chat stays attached while away',
      );
      push(tester);
      await tester.pump();
      expect(
        shownStart(),
        started,
        reason: 'the mini-pill timer counts from the compaction start',
      );
      await tearDownApp(tester, service);
    });

    test('a later snapshot with the real turn start moves an origin '
        'anchored at open back to that start', () async {
      final wall = _Wall()..advance(const Duration(seconds: 30));
      final service = newService();
      addTearDown(service.dispose);
      final gateway = peer.PeerGateway(_snapshot(running: true));
      final chat = attach(service, gateway, wall);
      await chat.loadMessages();
      final anchored = chat.anchorTurnClock()!;
      expect(anchored.isAtSameMomentAs(wall.now), isTrue);

      gateway.snapshot = _snapshot(running: true, turnStartedAt: _turnStart);
      await chat.loadMessages();
      expect(chat.turnClockOrigin!.isAtSameMomentAs(_turnStart), isTrue);
      expect(chat.anchorTurnClock()!.isAtSameMomentAs(_turnStart), isTrue);
    });

    testWidgets('idle chat: no pill and no timer, before and after re-entry', (
      tester,
    ) async {
      final wall = _Wall();
      final service = newService();
      final gateway = peer.PeerGateway(_snapshot(running: false));
      final chat = attach(service, gateway, wall);
      await tester.runAsync(chat.loadMessages);
      await boot(tester, service);
      push(tester);
      await tester.pump();
      expect(_pill, findsNothing);
      await leave(tester);
      wall.advance(const Duration(seconds: 20));
      push(tester);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(_pill, findsNothing);
      expect(_elapsed(tester), isNull);
      await tearDownApp(tester, service);
    });
  });

  group('the expanded pill shows what is known', () {
    testWidgets('after re-entry: running tool with its elapsed, the steps '
        'already done and the tasks', (tester) async {
      final wall = _Wall()..advance(const Duration(seconds: 5));
      final service = newService();
      final gateway = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart, todos: true),
      );
      final chat = attach(service, gateway, wall);
      await tester.runAsync(chat.loadMessages);
      await boot(tester, service);
      push(tester);
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

      await leave(tester);
      wall.advance(const Duration(seconds: 20));
      push(tester);
      await tester.pump();
      expect(_textIn(_pill), contains('read_file · informe.md'));

      await tester.tap(_pill);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final body = _textIn(_panel);
      expect(body, contains('read_file · informe.md'), reason: 'running');
      expect(body, contains('terminal · pytest'), reason: 'done this turn');
      expect(body, contains('Arreglar la pastilla'), reason: 'tasks');
      expect(find.byKey(const ValueKey('activity-tasks-title')), findsOne);
      expect(
        find.byKey(const ValueKey('activity-now-no-details')),
        findsNothing,
      );
      await tearDownApp(tester, service);
    });

    testWidgets('resumed with nothing known: the panel says so instead of '
        'repeating the headline; the next tool event fills it', (tester) async {
      final wall = _Wall()..advance(const Duration(seconds: 12));
      final service = newService();
      final gateway = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart),
      );
      final chat = attach(service, gateway, wall);
      await tester.runAsync(chat.loadMessages);
      await boot(tester, service);
      push(tester);
      await tester.pump();
      expect(_pill, findsOneWidget);
      expect(_textIn(_pill), isNot(contains('Ejecutando herramientas')));

      await tester.tap(_pill);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('activity-now-no-details')),
        findsOneWidget,
      );
      expect(
        _textIn(_panel),
        isNot(contains('Ejecutando herramientas')),
        reason: 'never claims tools it cannot list',
      );
      expect(
        find.text(
          'Sin detalles todavía: se actualizará con el siguiente evento.',
        ),
        findsOneWidget,
      );

      gateway.emit('tool.start', {
        'tool_id': 't3',
        'name': 'web_search',
        'args': {'query': 'flutter'},
      });
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_textIn(_panel), contains('web_search'));
      expect(
        find.byKey(const ValueKey('activity-now-no-details')),
        findsNothing,
      );
      await tearDownApp(tester, service);
    });

    // Follow-up to 62c6437: the "no details yet" line is honest only when
    // nothing at all is known. A finished step in this turn, or a task list,
    // is detail, so the line must stay hidden even with no tool running.
    testWidgets('a step already done, nothing running: no "no details" line', (
      tester,
    ) async {
      final wall = _Wall()..advance(const Duration(seconds: 5));
      final service = newService();
      final gateway = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart),
      );
      final chat = attach(service, gateway, wall);
      await tester.runAsync(chat.loadMessages);
      await boot(tester, service);
      push(tester);
      await tester.pump();
      gateway.emit('tool.start', {
        'tool_id': 't1',
        'name': 'terminal',
        'args': {'command': 'pytest -q'},
      });
      await tester.pump(const Duration(milliseconds: 16));
      wall.advance(const Duration(seconds: 2));
      gateway.emit('tool.complete', {'tool_id': 't1', 'name': 'terminal'});
      await tester.pump(const Duration(milliseconds: 16));

      await tester.tap(_pill);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_textIn(_panel), contains('terminal · pytest'));
      expect(
        find.byKey(const ValueKey('activity-now-no-details')),
        findsNothing,
      );
      await tearDownApp(tester, service);
    });

    testWidgets('a task list, nothing running or done: no "no details" line', (
      tester,
    ) async {
      final wall = _Wall()..advance(const Duration(seconds: 5));
      final service = newService();
      final gateway = peer.PeerGateway(
        _snapshot(running: true, turnStartedAt: _turnStart, todos: true),
      );
      final chat = attach(service, gateway, wall);
      await tester.runAsync(chat.loadMessages);
      await boot(tester, service);
      push(tester);
      await tester.pump();

      await tester.tap(_pill);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('activity-tasks-title')), findsOne);
      expect(_textIn(_panel), contains('Arreglar la pastilla'));
      expect(
        find.byKey(const ValueKey('activity-now-no-details')),
        findsNothing,
      );
      await tearDownApp(tester, service);
    });
  });
}
