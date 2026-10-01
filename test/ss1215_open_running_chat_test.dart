// ss1215: opening a chat that is already running on the server paints the
// pill (running tool, «n/m» tasks) on its first frame, the resume snapshot
// replaces it without an empty frame, and the headline never claims
// «Ejecutando herramientas…» while no tool runs.
import 'dart:async';

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
  apiKey: 'k',
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

DesktopSessionSnapshot _snapshot({required bool running}) =>
    DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-peer',
        'session_key': 'stored-peer',
        'message_count': 1,
        'messages': [peer.publicSnapshot],
        'running': running,
        if (running) 'inflight': {'assistant': '', 'streaming': true},
        'todo_state': {
          'revision': 3,
          'todos': [
            {'id': '1', 'content': 'Leer', 'status': 'completed'},
            {'id': '2', 'content': 'Arreglar', 'status': 'in_progress'},
            {'id': '3', 'content': 'Probar', 'status': 'pending'},
          ],
        },
      },
      requestedStoredSessionId: 'stored-peer',
      created: false,
      method: 'session.resume',
    );

/// The pill's visible text (action · detail, n/m), or null without a pill.
String? _pill(WidgetTester tester) {
  final pill = find.byKey(const ValueKey('activity-pill'));
  if (pill.evaluate().isEmpty) return null;
  return find
      .descendant(of: pill, matching: find.byType(RichText))
      .evaluate()
      .map((e) => (e.widget as RichText).text.toPlainText())
      .where((text) => text.trim().isNotEmpty && !text.contains(':'))
      .join(' | ');
}

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

  ActiveChat attach(ActiveChatService service, peer.PeerGateway gateway) =>
      service.attach(
        connection: _connection,
        sessionId: 'stored-peer',
        sessionTitle: 'Peer',
        sessionSnapshot: _session,
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'k',
          httpClient: MockClient((_) async => http.Response('nf', 404)),
        ),
        desktopGateway: gateway,
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
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

  testWidgets('open a running chat: tool + tasks on the first frame, then the '
      'snapshot without an empty frame; headline never «Ejecutando»', (
    tester,
  ) async {
    final service = ActiveChatService(
      attachDesktopRuntimeOnLoad: true,
      compressionRestoreStore: testCompressionRestoreStore(),
      globalActivity: GlobalActivityAggregate.inMemory(),
    );
    // A previous visit saw `terminal · pytest` running with 1/3 tasks.
    final first = peer.PeerGateway(_snapshot(running: true));
    final previous = attach(service, first);
    await tester.runAsync(previous.loadMessages);
    first.emit('tool.start', {
      'tool_id': 't1',
      'name': 'terminal',
      'args': {'command': 'pytest -q'},
    });
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    service.debugDisposeChatForTesting('peer', 'stored-peer');

    roster(service, 'working');
    final gateway = peer.PeerGateway(_snapshot(running: true))
      ..resumeHold = Completer<void>();
    attach(service, gateway);
    await boot(tester, service);
    push(tester);
    await tester.pump();

    final frames = <String?>[];
    frames.add(_pill(tester));
    expect(frames.first, contains('terminal · pytest'));
    expect(frames.first, contains('1/3'));

    gateway.resumeHold!.complete();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(_pill(tester));
    }
    expect(frames, everyElement(isNotNull), reason: 'never an empty frame');
    // The snapshot has no tool running: the pill says so, with the task.
    expect(frames.last, contains('Pensando… · Arreglar'));
    expect(frames.last, contains('1/3'));
    expect(frames.join(), isNot(contains('Ejecutando herramientas')));

    gateway.emit('tool.start', {
      'tool_id': 't2',
      'name': 'read_file',
      'args': {'path': '/tmp/a/informe.md'},
    });
    await tester.pump(const Duration(milliseconds: 16));
    expect(_pill(tester), contains('read_file · informe.md'));
    gateway.emit('tool.complete', {'tool_id': 't2', 'name': 'read_file'});
    gateway.emit('reasoning.delta', {'text': 'pienso'});
    await tester.pump(const Duration(milliseconds: 16));
    expect(_pill(tester), contains('Pensando…'));
    expect(_pill(tester), isNot(contains('read_file')));

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('open an idle chat: no pill, no spinner', (tester) async {
    final service = ActiveChatService(
      attachDesktopRuntimeOnLoad: true,
      compressionRestoreStore: testCompressionRestoreStore(),
      globalActivity: GlobalActivityAggregate.inMemory(),
    );
    final gateway = peer.PeerGateway(_snapshot(running: false))
      ..resumeHold = Completer<void>();
    attach(service, gateway);
    await boot(tester, service);
    push(tester);
    await tester.pump();
    expect(_pill(tester), isNull);
    gateway.resumeHold!.complete();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(seconds: 3));
    expect(_pill(tester), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
}
