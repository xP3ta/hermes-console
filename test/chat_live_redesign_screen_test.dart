import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
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
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/main.dart';

import 'support/test_api_client.dart';
import 'support/in_memory_compression_restore_storage.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-live-redesign',
  label: 'Composer recall',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
);

Session _session() => Session(
  id: 'sess-live-redesign',
  title: 'Recuperar mensaje',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

class _LiveGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopIdempotentGateway,
        HermesDesktopRedirectGateway,
        HermesDesktopControlGateway,
        HermesDesktopProcessStopGateway {
  AgentCenterSnapshot processes = const AgentCenterSnapshot(
    snapshots: [],
    processes: [],
  );
  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async => processes;
  @override
  Future<void> killBackgroundProcess(
    String runtimeSessionId,
    String processId,
  ) async {
    calls.add('kill:$processId');
  }

  @override
  Future<void> stopBackgroundProcesses(String runtimeSessionId) async {
    calls.add('stop-background');
    processes = const AgentCenterSnapshot(snapshots: [], processes: []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final calls = <String>[];
  final turnIds = <String>[];
  Completer<void>? interruptAck;
  Completer<void>? redirectAck;
  Completer<void>? submitAck;
  Future<void> Function()? onRedirect;
  Object? redirectError;
  Object? interruptError;
  Object? steerError;
  bool completeOnInterrupt = true;
  DesktopRedirectDisposition redirectDisposition =
      DesktopRedirectDisposition.redirected;

  void completeTurn() => _events.add(
    const TuiGatewayEvent(
      type: 'message.complete',
      sessionId: 'runtime-live',
      payload: {'text': 'finished'},
    ),
  );
  bool interruptUnsupported = false;
  bool steerUnsupported = false;

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
    runtimeSessionId: 'runtime-live',
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
    runtimeSessionId: 'runtime-live',
    storedSessionId: storedSessionId,
    created: false,
  );
  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => resumeExisting('sess-live-redesign', profile: profile);
  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    calls.add('send:$text');
    await submitAck?.future;
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    turnIds.add(clientTurnId);
    calls.add('send:$text');
    await submitAck?.future;
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-$clientTurnId',
      state: DesktopTurnState.accepted,
      duplicate: false,
    );
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String runtimeSessionId,
    String clientTurnId,
  ) async => DesktopTurnStatus(known: false, clientTurnId: clientTurnId);
  @override
  Future<void> interrupt(String runtimeSessionId) async {
    calls.add('interrupt');
    if (interruptUnsupported) {
      throw const TuiGatewayRpcError(
        'session.interrupt',
        'missing',
        code: -32601,
      );
    }
    if (interruptError case final error?) throw error;
    await interruptAck?.future;
    calls.add('ack');
    if (completeOnInterrupt) {
      _events.add(
        const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-live',
          payload: {'text': '', 'status': 'interrupted'},
        ),
      );
    }
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    calls.add('steer:$text');
    if (steerError case final error?) throw error;
    if (steerUnsupported) {
      throw const TuiGatewayRpcError('session.steer', 'missing', code: -32601);
    }
  }

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    calls.add('redirect:$text');
    await onRedirect?.call();
    await redirectAck?.future;
    if (redirectError case final error?) throw error;
    return redirectDisposition;
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}
  @override
  Future<void> close() => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final processCase in [false, true]) {
    testWidgets(
      processCase
          ? 'real chat anchors background process to the capsule and stops only delegated work'
          : 'real chat keeps queued input out of transcript until terminal, then delivers it as a user bubble',
      (tester) async {
        tester.platformDispatcher.localesTestValue = [const Locale('es')];
        addTearDown(tester.platformDispatcher.clearLocalesTestValue);
        tester.view
          ..physicalSize = const Size(1080, 2280)
          ..devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final support = Directory.systemTemp.createTempSync(
          'chat-live-redesign-',
        );
        final store = <String, String>{};
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => support.path,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                store[args['key'] as String] = args['value'] as String;
              case 'read':
                return store[args['key'] as String];
              case 'delete':
                store.remove(args['key']);
              case 'readAll':
                return Map<String, String>.from(store);
              case 'containsKey':
                return store.containsKey(args['key']);
            }
            return null;
          },
        );
        for (final channel in [
          'dexterous.com/flutter/local_notifications',
          'flutter_foreground_task/methods',
          'flutter_foreground_task/background',
        ]) {
          messenger.setMockMethodCallHandler(
            MethodChannel(channel),
            (_) async => null,
          );
        }
        SharedPreferences.setMockInitialValues({'onboarding_done': true});
        final prefs = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(prefs);
        final secure = SecureStorage();
        final gateway = _LiveGateway();
        final service = ActiveChatService(
          attachDesktopRuntimeOnLoad: false,
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        final routes = MockClient(
          (request) async => http.Response(
            request.url.path == '/api/config'
                ? '{"display":{"busy_input_mode":"queue"}}'
                : '{}',
            request.url.path == '/api/config' ? 200 : 404,
          ),
        );
        final chat = service.attach(
          connection: _connection(),
          sessionId: _session().id,
          sessionTitle: _session().title,
          sessionProfile: 'default',
          initialStoredSessionId: _session().id,
          api: testApiClient(httpClient: routes),
          transcriptDashboard: testDashboardClient(httpClient: routes),
          desktopGateway: gateway,
          turnIdempotencyCapability: () async => true,
          storedMessageLoader: (_, _) async => const [],
          disableForegroundKeepAlive: true,
          attachDesktopRuntimeOnLoad: false,
          allowUnownedDesktopSnapshotForTesting: true,
        )..messagesLoaded = true;
        Future<void> settle() async {
          for (var frame = 0; frame < 12; frame++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        try {
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
          await tester.pump(const Duration(seconds: 5));
          Navigator.of(tester.element(find.byType(Navigator).first)).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  ChatScreen(connection: _connection(), session: _session()),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.runAsync(() async {
            await chat.refreshBusyInputMode();
            expect(
              await chat.send(
                fullText: 'Primer turno',
                model: 'hermes-agent',
                profile: 'default',
                history: const [],
              ),
              isTrue,
            );
          });
          await settle();
          expect(
            find.byKey(const ValueKey('chat-inline-activity')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('delegates-capsule')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('chat-jump-to-prompt')),
            findsNothing,
            reason: 'prompt is visible',
          );
          if (processCase) {
            gateway.processes = const AgentCenterSnapshot(
              snapshots: [],
              processes: [
                BackgroundProcessEntry(
                  opaqueId: 'process-test',
                  status: AgentCenterStatus.running,
                  uptimeSeconds: 4,
                  command: 'sleep 60',
                  notifyOnComplete: true,
                ),
              ],
            );
            await chat.refreshBackgroundProcessesForTesting();
            await settle();
            final pill = find.byKey(const ValueKey('delegates-capsule'));
            expect(pill, findsOneWidget);
            expect(
              find.descendant(
                of: find.byType(FloatingChatHeader),
                matching: pill,
              ),
              findsNothing,
              reason: 'design B: the header stays identity only',
            );
            expect(
              find.descendant(
                of: find.byType(FloatingChatHeader),
                matching: find.textContaining('proceso'),
              ),
              findsNothing,
            );
            expect(
              tester.getBottomLeft(pill).dy,
              lessThan(tester.getTopLeft(find.byType(ConsoleComposer)).dy),
            );
            expect(find.byKey(const ValueKey('chat-queue-chip')), findsNothing);
            expect(
              find.byKey(const ValueKey('delegates-sprite-halo')),
              findsOneWidget,
            );
            await tester.tap(pill);
            await tester.pump(const Duration(milliseconds: 400));
            expect(
              find.byKey(const ValueKey('subagent-panel')),
              findsOneWidget,
            );
            expect(find.text('sleep 60'), findsOneWidget);
            await tester.tap(find.byKey(const ValueKey('delegates-stop')));
            await settle();
            expect(
              gateway.calls.where((call) => call == 'stop-background'),
              hasLength(1),
            );
            expect(gateway.calls, isNot(contains('interrupt')));
            expect(chat.sending, isTrue);
            expect(tester.takeException(), isNull);
            return;
          }
          final field = find.descendant(
            of: find.byType(ConsoleComposer),
            matching: find.byType(TextField),
          );
          await tester.enterText(field, 'Y después resúmelo');
          await tester.pump();
          tester
              .widget<ConsoleComposer>(find.byType(ConsoleComposer))
              .onQueue!();
          await settle();
          expect(chat.queuedEntries.single.text, 'Y después resúmelo');
          final chip = find.byKey(const ValueKey('chat-queue-chip'));
          expect(chip, findsOneWidget);
          expect(
            tester.getBottomLeft(chip).dy,
            lessThanOrEqualTo(
              tester.getTopLeft(find.byType(ConsoleComposer)).dy,
            ),
          );
          expect(
            find.descendant(
              of: find.byType(FloatingChatHeader),
              matching: chip,
            ),
            findsNothing,
          );
          expect(
            find.text('Y después resúmelo'),
            findsNothing,
            reason: 'queued input is not a user bubble yet',
          );
          gateway.completeTurn();
          await settle();
          expect(
            gateway.calls.where((call) => call == 'send:Y después resúmelo'),
            hasLength(1),
          );
          expect(chat.queuedEntries, isEmpty);
          expect(chip, findsNothing);
          expect(find.text('Y después resúmelo'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          chat.dispose();
          await tester.pumpWidget(const SizedBox());
          service.dispose();
          await tester.pump();
          messenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
          support.deleteSync(recursive: true);
        }
      },
    );
  }
}
