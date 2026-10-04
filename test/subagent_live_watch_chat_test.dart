import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/core/services/subagent_live_watch.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_subagent_watch_gateway.dart' show watchTestSnapshot;
import 'support/in_memory_compression_restore_storage.dart';

const _childSession = 'child-session-chat';

class _WatchableGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSubagentGateway,
        SubagentWatchGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final resumes = <({String childId, String profile})>[];
  final closed = <String>[];
  final submitted = <String>[];
  int tailCalls = 0;

  void emit(
    String type,
    Map<String, dynamic> payload, {
    String runtime = 'runtime-chat',
  }) => _events.add(
    TuiGatewayEvent(type: type, sessionId: runtime, payload: payload),
  );

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-chat',
    storedSessionId: storedSessionId,
    created: false,
    running: true,
    status: 'working',
  );

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-chat',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async => const [
    DesktopSubagentSnapshot(subagentId: 'sa-chat', status: 'running'),
  ];

  @override
  Future<DesktopSubagentTailResult> tailSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async {
    tailCalls += 1;
    return const DesktopSubagentTailResult(
      available: true,
      content: 'cola sondeada',
      truncated: false,
    );
  }

  @override
  Future<DesktopSessionSnapshot> resumeWatchSession(
    String childSessionId, {
    required String profile,
  }) async {
    resumes.add((childId: childSessionId, profile: profile));
    return watchTestSnapshot('watch-runtime');
  }

  @override
  Future<bool> closeSession(String runtimeSessionId) async {
    closed.add(runtimeSessionId);
    return true;
  }

  @override
  void retainSessionRuntime(String runtimeSessionId) {}

  @override
  void releaseSessionRuntime(String runtimeSessionId) {}

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async =>
      submitted.add(text);

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

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _connection = SavedConnection(
  id: 'watch-chat',
  label: 'Watch chat',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-only',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _session = Session(
  id: 'stored-chat',
  title: 'Chat con subagente',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
  profile: 'parent-profile',
);

Future<(_WatchableGateway, ActiveChat, ActiveChatService, ConnectionManager)>
_mountChat(WidgetTester tester) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  // The globally active profile is NOT the chat's: the watch must use the
  // chat's.
  await manager.setActiveProfile(_connection.id, 'other-profile');
  final secure = SecureStorage();
  final gateway = _WatchableGateway();
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = activeChats.attach(
    connection: _connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    initialStoredSessionId: _session.id,
    sessionProfile: 'parent-profile',
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: false,
    allowUnownedDesktopSnapshotForTesting: true,
    disableForegroundKeepAlive: true,
  );
  chat.messagesLoaded = true;
  expect(
    await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
    isTrue,
  );
  await tester.pump();

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
      pageBuilder: (_, _, _) => ChatScreen(
        connection: _connection,
        session: _session,
        initialStoredSessionId: 'stored-chat',
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (gateway, chat, activeChats, manager);
}

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

  testWidgets(
    'opening a running subagent watches its child on the chat gateway with '
    'the chat profile and never polls the tail',
    (tester) async {
      final (gateway, chat, activeChats, _) = await _mountChat(tester);
      expect(
        await chat.send(
          fullText: 'delegar',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );
      gateway.emit('message.start', const {});
      gateway.emit('subagent.start', const {
        'subagent_id': 'sa-chat',
        'child_session_id': _childSession,
        'goal': 'Revisar el proyecto',
        'status': 'running',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The activity pill opens the detail through this controller.
      tester
          .widget<SubagentActivityCard>(
            find.byKey(
              const ValueKey('chat-subagent-status'),
              skipOffstage: false,
            ),
          )
          .controller!
          .open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(gateway.resumes, [
        (childId: _childSession, profile: 'parent-profile'),
      ]);
      gateway.emit('message.delta', const {
        'text': 'texto en directo',
      }, runtime: 'watch-runtime');
      await tester.pump();
      expect(find.text('texto en directo'), findsOneWidget);
      expect(gateway.tailCalls, 0);
      final submittedBefore = gateway.submitted.length;

      // Leaving the detail closes the watch exactly once.
      tester.state<NavigatorState>(find.byType(Navigator).last).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      gateway.emit('message.delta', const {
        'text': 'tarde',
      }, runtime: 'watch-runtime');
      await tester.pump();

      expect(gateway.closed, ['watch-runtime']);
      expect(gateway.submitted, hasLength(submittedBefore));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      activeChats.dispose();
      await gateway.close();
    },
  );

  testWidgets(
    'switching the active profile with the watch open closes it and falls back '
    'to the polled tail without any further event',
    (tester) async {
      final (gateway, chat, activeChats, manager) = await _mountChat(tester);
      expect(
        await chat.send(
          fullText: 'delegar',
          model: 'hermes-agent',
          history: chat.messages,
        ),
        isTrue,
      );
      gateway.emit('message.start', const {});
      gateway.emit('subagent.start', const {
        'subagent_id': 'sa-chat',
        'child_session_id': _childSession,
        'goal': 'Revisar el proyecto',
        'status': 'running',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      tester
          .widget<SubagentActivityCard>(
            find.byKey(
              const ValueKey('chat-subagent-status'),
              skipOffstage: false,
            ),
          )
          .controller!
          .open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(gateway.resumes, hasLength(1));
      expect(gateway.tailCalls, 0);

      // The globally active profile changes; no delta, error or complete
      // follows it.
      await manager.setActiveProfile(_connection.id, 'third-profile');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(gateway.closed, ['watch-runtime']);
      expect(gateway.tailCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      activeChats.dispose();
      await gateway.close();
    },
  );
}
