// lr1215: the model's reasoning is shown while it streams, as Hermes Desktop
// does: in the turn, in the transcript, whole. Decorative `thinking.delta`
// spinner phrases are never reasoning.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
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
import 'support/in_memory_compression_restore_storage.dart';

final DateTime _t0 = DateTime(2026, 10, 5, 12);

Map<String, dynamic> _reasoning(String text, {String status = 'running'}) => {
  'kind': 'reasoning',
  'text': text,
  'status': status,
  'timestamp': _t0.millisecondsSinceEpoch,
};

Map<String, dynamic> _tool(String label, String status, String id) => {
  'kind': 'tool',
  'label': label,
  'status': status,
  'id': id,
};

/// The thought being written, where the turn tells it: in the transcript.
Finder get _tail => find.byKey(const ValueKey('turn-reasoning'));

String _tailText(WidgetTester tester) => find
    .descendant(of: _tail, matching: find.byType(RichText))
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .join('\n');

void main() {
  group('snapshot carries the open reasoning', () {
    test('fromTrace keeps the reasoning text', () {
      final step = ActivityStep.fromTrace(_reasoning('Reading the file'));
      expect(step!.kind, ActivityStepKind.reasoning);
      expect(step.text, 'Reading the file');
    });

    test('splitSteps returns the open reasoning outside current and done', () {
      final split = ActivitySnapshot.splitSteps([
        _tool('read_file', 'completed', '1'),
        _reasoning('First I check. Then I edit.'),
      ]);
      expect(split.liveReasoning, 'First I check. Then I edit.');
      expect(split.current, isNull);
      expect(split.done.map((s) => s.label), ['read_file']);
    });

    test('a closed reasoning step is not live', () {
      final split = ActivitySnapshot.splitSteps([
        _reasoning('Done thinking', status: 'completed'),
        _tool('terminal', 'running', '2'),
      ]);
      expect(split.liveReasoning, isNull);
      expect(split.current!.label, 'terminal');
    });

    test('equality is stable for the same trace and moves with the text', () {
      ActivitySnapshot build(String text) {
        final split = ActivitySnapshot.splitSteps([_reasoning(text)]);
        return ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          current: split.current,
          done: split.done,
          liveReasoning: split.liveReasoning,
        );
      }

      expect(build('abc'), build('abc'));
      expect(build('abc').hashCode, build('abc').hashCode);
      expect(build('abc'), isNot(build('abcd')));
      expect(
        build('abc').copyWith(headline: 'x').liveReasoning,
        'abc',
        reason: 'copyWith keeps the reasoning',
      );
      expect(build('abc').withTasksActive(true).liveReasoning, 'abc');
    });
  });

  group('live chat', () {
    final connection = SavedConnection(
      id: 'peer',
      label: 'Peer',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-key',
      useHttps: true,
      kind: InstanceKind.vps,
    );
    const session = Session(
      id: 'stored-peer',
      title: 'Peer',
      model: 'hermes-agent',
      source: 'api_server',
      messageCount: 1,
      isActive: false,
      preview: '',
      startedAt: 0,
    );
    final turnStart = DateTime.utc(2026, 10, 5, 9);
    final snapshot = DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-peer',
        'session_key': 'stored-peer',
        'message_count': 1,
        'messages': [peer.publicSnapshot],
        'running': true,
        'inflight': {'assistant': '', 'streaming': true},
        'turn_started_at': turnStart.millisecondsSinceEpoch / 1000,
      },
      requestedStoredSessionId: 'stored-peer',
      created: false,
      method: 'session.resume',
    );
    setUp(() {
      SharedPreferences.setMockInitialValues({'onboarding_done': true});
      final secure = <String, String>{};
      final messenger =
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
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
      final temp = Directory.systemTemp.createTempSync('lr1215_reasoning_');
      addTearDown(() => temp.deleteSync(recursive: true));
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => temp.path,
      );
    });

    Future<(ActiveChatService, peer.PeerGateway)> open(
      WidgetTester tester,
    ) async {
      final service = ActiveChatService(
        attachDesktopRuntimeOnLoad: true,
        compressionRestoreStore: testCompressionRestoreStore(),
        globalActivity: GlobalActivityAggregate.inMemory(),
      );
      final gateway = peer.PeerGateway(snapshot);
      final wallNow = turnStart.add(const Duration(seconds: 3));
      final chat = service.attach(
        connection: connection,
        sessionId: 'stored-peer',
        sessionTitle: 'Peer',
        sessionSnapshot: session,
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('nf', 404)),
        ),
        desktopGateway: gateway,
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
        wallClockMsForTesting: () => wallNow.millisecondsSinceEpoch,
      );
      await tester.runAsync(chat.loadMessages);
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

          sshManager: SshManager(secure, manager),
          sftpTransfers: SftpTransferService(
            SshManager(secure, manager),
            NotificationService(prefs),
          ),
          sshSessions: SshSessionService(SshManager(secure, manager)),
          notifications: NotificationService(prefs),
          activeChats: service,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 500));
      Navigator.of(tester.element(find.byType(Navigator).first)).push(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) =>
              ChatScreen(connection: connection, session: session),
        ),
      );
      await tester.pump();
      return (service, gateway);
    }

    Future<void> close(WidgetTester tester, ActiveChatService service) async {
      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
      await tester.pump(const Duration(minutes: 5));
    }

    // The chat was loaded under runAsync: its change stream delivers in the
    // real zone, so let real time pass before pumping the frames.
    Future<void> frames(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 16));
    }

    testWidgets('reasoning deltas grow in the turn, whole, and the final '
        'text is not duplicated', (tester) async {
      final (service, gateway) = await open(tester);
      gateway.emit('reasoning.delta', {'text': 'First I read '});
      await frames(tester);
      expect(_tail, findsOneWidget);
      expect(_tailText(tester), 'First I read');

      gateway.emit('reasoning.delta', {'text': 'the config, '});
      await frames(tester);
      expect(_tailText(tester), 'First I read the config,');
      gateway.emit('reasoning.delta', {'text': 'then I patch it.'});
      await frames(tester);
      expect(_tailText(tester), 'First I read the config, then I patch it.');
      gateway.emit('reasoning.available', {
        'text': 'First I read the config, then I patch it.',
      });
      await frames(tester);
      expect(_tailText(tester), 'First I read the config, then I patch it.');
      await close(tester, service);
    });

    testWidgets('a thinking.delta spinner phrase is not reasoning', (
      tester,
    ) async {
      final (service, gateway) = await open(tester);
      gateway.emit('thinking.delta', {'text': '(¬_¬) pondering...'});
      await frames(tester);
      expect(_tail, findsNothing);
      expect(find.textContaining('pondering'), findsNothing);
      await close(tester, service);
    });
  });
}
