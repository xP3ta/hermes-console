import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/running_work.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/subagent_group_visibility.dart';
import 'package:hermes_android/core/services/subagent_transcript_projection.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/chat/chat_notch.dart'
    show kChatNotchSheetOpen;
import 'package:hermes_android/core/widgets/chat_control_sheet.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

class _AdaptiveGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSubagentGateway,
        HermesDesktopProcessStopGateway,
        HermesDesktopControlGateway,
        HermesDesktopSessionControlGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopRosterBoundRecoveryGateway {
  _AdaptiveGateway({required this.changeEventsAvailable});

  final bool changeEventsAvailable;
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  bool connected = true;
  bool failReads = false;

  /// Only `subagent.list` fails (process and control reads still answer).
  bool failList = false;
  bool resumedSessionRunning = true;
  List<DesktopSubagentSnapshot> subagents = const [];
  AgentCenterSnapshot processSnapshot = const AgentCenterSnapshot(
    snapshots: [],
    processes: [],
  );
  final List<AgentCenterSnapshot> processSnapshots = [];
  final List<String> killedProcesses = [];
  final List<String> interruptedSubagents = [];
  final processStopRuntimeIds = <String>[];
  int listCalls = 0;
  int processCalls = 0;
  int resumeExistingCalls = 0;
  Completer<void>? resumeExistingGate;
  int controlCalls = 0;

  void resetCounts() {
    listCalls = 0;
    processCalls = 0;
    controlCalls = 0;
  }

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-adaptive',
        payload: payload,
      ),
    );
  }

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeExistingCalls += 1;
    final gate = resumeExistingGate;
    if (gate != null) await gate.future;
    return DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-adaptive',
      storedSessionId: storedSessionId,
      created: false,
      running: resumedSessionRunning,
      status: resumedSessionRunning ? 'working' : 'idle',
    );
  }

  // The production gateway implements the recovery interfaces: after a
  // background cut the service itself reattaches the runtime on resume.
  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) => resumeExisting(storedSessionId, profile: profile);

  @override
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async => DesktopRosterBoundRecovery.forTesting(
    await resumeExisting(storedSessionId, profile: profile),
    this,
  );

  @override
  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery) => true;

  @override
  bool consumeRosterBoundViewerAttachment(
    DesktopRosterBoundRecovery recovery,
  ) => true;

  @override
  // ignore: deprecated_member_use_from_same_package
  void commitRecoveryRuntime(String runtimeSessionId) {}

  /// Corte de transporte del socket de Desktop (el servicio retira el runtime).
  void dropTransport([Object error = const _SocketLikeDrop()]) =>
      _events.addError(error);

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-adaptive',
    storedSessionId: 'stored-adaptive',
    created: true,
  );

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-adaptive',
    storedSessionId: storedSessionId,
    created: false,
  );

  /// Retiene la respuesta de `subagent.list` (el roster aún no contestó).
  Completer<void>? listGate;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    listCalls += 1;
    await listGate?.future;
    if (failReads || failList) throw StateError('subagent snapshot failed');
    return subagents;
  }

  @override
  Future<DesktopSubagentInterruptResult> interruptSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async {
    interruptedSubagents.add(subagentId);
    return DesktopSubagentInterruptResult(found: true, subagentId: subagentId);
  }

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async {
    processCalls += 1;
    if (failReads) throw StateError('process snapshot failed');
    if (processSnapshots.isNotEmpty) return processSnapshots.removeAt(0);
    return processSnapshot;
  }

  @override
  Future<void> killBackgroundProcess(
    String runtimeSessionId,
    String processId,
  ) async {
    killedProcesses.add(processId);
  }

  @override
  Future<void> stopBackgroundProcesses(String runtimeSessionId) async {
    processStopRuntimeIds.add(runtimeSessionId);
  }

  @override
  Future<SessionControlSnapshot> readSessionControl(
    String runtimeSessionId,
  ) async {
    controlCalls += 1;
    if (failReads) throw StateError('control snapshot failed');
    return const SessionControlSnapshot(
      goal: null,
      loop: null,
      heartbeat: null,
      revision: '',
      updatedAt: null,
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

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
    connected = false;
    if (!_events.isClosed) await _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SocketLikeDrop implements Exception {
  const _SocketLikeDrop();
}

class _Fixture {
  const _Fixture({
    required this.gateway,
    required this.chat,
    required this.activeChats,
  });

  final _AdaptiveGateway gateway;
  final ActiveChat chat;
  final ActiveChatService activeChats;
}

final _connection = SavedConnection(
  id: 'adaptive-refresh',
  label: 'Adaptive refresh',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-only',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _session = Session(
  id: 'stored-adaptive',
  title: 'Adaptive refresh',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

Future<_Fixture> _mountChat(
  WidgetTester tester, {
  required bool changeEventsAvailable,
  List<DesktopSubagentSnapshot> subagents = const [],
  bool failReads = false,
  bool attachDesktopRuntimeOnLoad = false,
  bool resumedSessionRunning = true,
  StoredSessionMessageLoader? storedMessageLoader,
  List<Map<String, dynamic>>? coldTranscript,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final gateway = _AdaptiveGateway(changeEventsAvailable: changeEventsAvailable)
    ..subagents = subagents
    ..failReads = failReads
    ..resumedSessionRunning = resumedSessionRunning;
  final cold = coldTranscript;
  final StoredSessionMessageLoader? coldLoader = cold == null
      ? null
      : (_, _) async => cold;
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: attachDesktopRuntimeOnLoad,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = activeChats.attach(
    connection: _connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    initialStoredSessionId: _session.id,
    api: testApiClient(
      baseUrl: 'https://example.invalid',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: attachDesktopRuntimeOnLoad,
    storedMessageLoader: storedMessageLoader ?? coldLoader,
    allowUnownedDesktopSnapshotForTesting: true,
    disableForegroundKeepAlive: true,
  );
  if (coldTranscript == null) {
    chat.messagesLoaded = true;
  } else {
    // A cold reopen: the stored transcript is read (and projected) first.
    final load = chat.loadMessages();
    for (var i = 0; i < 20; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await load;
  }
  expect(
    await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
    isTrue,
  );
  await tester.pump();
  gateway.resetCounts();

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
        initialStoredSessionId: 'stored-adaptive',
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Fixture(gateway: gateway, chat: chat, activeChats: activeChats);
}

Future<void> _disposeFixture(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  fixture.activeChats.dispose();
  await fixture.gateway.close();
}

void _expectFullReads(_AdaptiveGateway gateway, int count) {
  expect(gateway.listCalls, count, reason: 'subagent.list reads');
  expect(gateway.processCalls, count, reason: 'process snapshot reads');
  expect(gateway.controlCalls, count, reason: 'session control reads');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // These tests pin the adaptive snapshot's cadence (subagents, processes
  // and control read together at 30/60 s, 5 s eventless, failure backoff).
  // The visible chat's separate 5 s roster poll (Desktop
  // use-subagent-snapshot.ts) is tested in subagent_roster_poll_test.dart.
  setUp(() => ChatScreen.subagentRosterPollInterval = null);
  tearDown(
    () => ChatScreen.subagentRosterPollInterval = const Duration(seconds: 5),
  );

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

  testWidgets('event gateway snapshots on attach and debounces unknown child', (
    tester,
  ) async {
    final fixture = await _mountChat(tester, changeEventsAvailable: true);
    _expectFullReads(fixture.gateway, 1);

    for (var index = 0; index < 10; index++) {
      fixture.gateway.emit('subagent.start', {
        'subagent_id': 'unknown-child',
        'event_id': 'event-$index',
        'event_revision': index + 1,
        'status': 'running',
      });
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 249));
    _expectFullReads(fixture.gateway, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.gateway.listCalls, 2);
    expect(fixture.gateway.processCalls, 1);
    expect(fixture.gateway.controlCalls, 1);

    await _disposeFixture(tester, fixture);
  });

  testWidgets('event gateway uses 30 second active backstop', (tester) async {
    final fixture = await _mountChat(
      tester,
      changeEventsAvailable: true,
      subagents: const [
        DesktopSubagentSnapshot(subagentId: 'active-child', status: 'running'),
      ],
    );
    _expectFullReads(fixture.gateway, 1);

    await tester.pump(const Duration(milliseconds: 29999));
    _expectFullReads(fixture.gateway, 1);
    await tester.pump(const Duration(milliseconds: 1));
    _expectFullReads(fixture.gateway, 2);

    await _disposeFixture(tester, fixture);
  });

  testWidgets('event gateway uses 60 second stable empty backstop', (
    tester,
  ) async {
    final fixture = await _mountChat(tester, changeEventsAvailable: true);
    _expectFullReads(fixture.gateway, 1);

    await tester.pump(const Duration(milliseconds: 59999));
    _expectFullReads(fixture.gateway, 1);
    await tester.pump(const Duration(milliseconds: 1));
    _expectFullReads(fixture.gateway, 2);

    await _disposeFixture(tester, fixture);
  });

  testWidgets('legacy gateway retains five second cadence', (tester) async {
    final fixture = await _mountChat(tester, changeEventsAvailable: false);
    _expectFullReads(fixture.gateway, 1);

    await tester.pump(const Duration(milliseconds: 4999));
    _expectFullReads(fixture.gateway, 1);
    await tester.pump(const Duration(milliseconds: 1));
    _expectFullReads(fixture.gateway, 2);

    await _disposeFixture(tester, fixture);
  });

  testWidgets('failures back off and a relevant event resets the delay', (
    tester,
  ) async {
    final fixture = await _mountChat(
      tester,
      changeEventsAvailable: true,
      failReads: true,
    );
    _expectFullReads(fixture.gateway, 1);

    for (final delay in const [5, 15, 30, 60]) {
      await tester.pump(
        Duration(seconds: delay) - const Duration(milliseconds: 1),
      );
      _expectFullReads(
        fixture.gateway,
        const [1, 2, 3, 4][const [5, 15, 30, 60].indexOf(delay)],
      );
      await tester.pump(const Duration(milliseconds: 1));
      _expectFullReads(
        fixture.gateway,
        const [2, 3, 4, 5][const [5, 15, 30, 60].indexOf(delay)],
      );
    }

    fixture.gateway.emit('status.update', const {'kind': 'process'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(fixture.gateway.processCalls, 6);
    await tester.pump(
      const Duration(seconds: 5) - const Duration(milliseconds: 1),
    );
    expect(fixture.gateway.processCalls, 6);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.gateway.listCalls, 5);
    expect(fixture.gateway.processCalls, 7);
    expect(fixture.gateway.controlCalls, 5);

    await _disposeFixture(tester, fixture);
  });

  testWidgets(
    'Stop rechecks stale process snapshots until absence is confirmed',
    (tester) async {
      const running = AgentCenterSnapshot(
        snapshots: [],
        processes: [
          BackgroundProcessEntry(
            opaqueId: 'process-stop-recheck',
            status: AgentCenterStatus.running,
            uptimeSeconds: 5,
            command: 'sleep 200',
            notifyOnComplete: true,
          ),
        ],
      );
      const empty = AgentCenterSnapshot(snapshots: [], processes: []);
      final fixture = await _mountChat(tester, changeEventsAvailable: true);
      expect(
        await fixture.chat.send(
          fullText: 'Finish this turn before background Stop',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      fixture.gateway.emit('message.start');
      fixture.gateway.emit('message.complete', const {
        'text': 'Completed normally before background Stop',
      });
      await tester.pump();
      expect(fixture.chat.isStreaming, isFalse);
      expect(fixture.chat.messages.first['_cancelled'], isNot(true));
      fixture.gateway.resumedSessionRunning = false;
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump();

      fixture.gateway.processSnapshot = running;
      fixture.gateway.emit('status.update', const {'kind': 'process'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      // Work moved below the header. Process evidence and Stop survive
      // stale snapshots until the second authoritative absence.
      expect(
        find.byKey(const ValueKey('delegates-capsule')),
        findsOneWidget,
      );
      expect(fixture.chat.backgroundProcesses.map((p) => p.id), [
        'process-stop-recheck',
      ]);
      expect(fixture.chat.canStopSessionWork, isTrue);
      expect(
        find.byKey(const ValueKey('delegates-capsule')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);

      fixture.gateway.processSnapshots.addAll([running, empty, empty]);
      fixture.gateway.processSnapshot = empty;
      final processCallsBeforeStop = fixture.gateway.processCalls;
      await tester.tap(find.byKey(const ValueKey('stop')));
      await tester.pump();
      await tester.pump();

      expect(fixture.gateway.processStopRuntimeIds, ['runtime-adaptive']);
      expect(fixture.gateway.killedProcesses, isEmpty);
      expect(fixture.gateway.processCalls - processCallsBeforeStop, 1);
      expect(
        find.byKey(const ValueKey('delegates-capsule')),
        findsOneWidget,
      );
      expect(fixture.chat.backgroundProcesses.map((p) => p.id), [
        'process-stop-recheck',
      ]);
      expect(fixture.chat.canStopSessionWork, isTrue);
      expect(
        find.byKey(const ValueKey('delegates-capsule')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);
      expect(find.text('Background work stopped'), findsNothing);

      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump();
      expect(fixture.gateway.processCalls - processCallsBeforeStop, 2);
      expect(find.byKey(const ValueKey('delegates-capsule')), findsOneWidget);
      expect(fixture.chat.backgroundProcesses.map((p) => p.id), [
        'process-stop-recheck',
      ]);
      expect(fixture.chat.canStopSessionWork, isTrue);
      expect(
        find.byKey(const ValueKey('delegates-capsule')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);
      expect(find.text('Background work stopped'), findsNothing);

      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pump();
      expect(fixture.gateway.processCalls - processCallsBeforeStop, 3);
      expect(find.byKey(const ValueKey('delegates-capsule')), findsOneWidget);
      expect(fixture.chat.isStreaming, isFalse);
      expect(fixture.chat.remoteSurfaceOwnsLiveTurn, isFalse);
      expect(fixture.chat.safeActiveSubagentCount, 0);
      expect(fixture.chat.backgroundProcesses, isEmpty);
      expect(fixture.chat.canStopSessionWork, isFalse);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('stop')), findsNothing);
      expect(fixture.chat.messages.first['_cancelled'], isNot(true));
      expect(
        fixture.chat.messages.any(
          (message) => message['_cancelledUser'] == true,
        ),
        isFalse,
      );
      expect(find.text('Background work stopped'), findsOneWidget);
      final strip = find.byKey(const ValueKey('chat-stop-status-strip'));
      expect(strip, findsOneWidget);
      expect(tester.getTopLeft(strip).dx, 14);
      expect(tester.getSize(strip).height, lessThanOrEqualTo(32));
      final label = tester.widget<Text>(find.text('Background work stopped'));
      expect(label.style?.fontSize, 12);
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      final icon = tester.widget<Icon>(
        find.byKey(const ValueKey('chat-stop-status-icon')),
      );
      expect(icon.size, 14);
      final composer = find.byKey(const ValueKey('chat-composer-host'));
      expect(
        tester.getBottomLeft(strip).dy,
        lessThanOrEqualTo(tester.getTopLeft(composer).dy),
      );

      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Background work stopped'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Background work stopped'), findsNothing);

      await _disposeFixture(tester, fixture);
    },
  );

  testWidgets(
    'Stop warns and keeps the control when background work remains listed',
    (tester) async {
      const running = AgentCenterSnapshot(
        snapshots: [],
        processes: [
          BackgroundProcessEntry(
            opaqueId: 'process-still-running',
            status: AgentCenterStatus.running,
            uptimeSeconds: 5,
            command: 'sleep 200',
          ),
        ],
      );
      final fixture = await _mountChat(tester, changeEventsAvailable: true);
      expect(
        await fixture.chat.send(
          fullText: 'Finish before background Stop',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      fixture.gateway.emit('message.start');
      fixture.gateway.emit('message.complete', const {'text': 'Done'});
      await tester.pump();
      fixture.gateway.resumedSessionRunning = false;
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump();

      fixture.gateway.processSnapshot = running;
      fixture.gateway.emit('status.update', const {'kind': 'process'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('stop')));
      await tester.pump();
      expect(find.text('Background work stopped'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pump();

      expect(fixture.gateway.processStopRuntimeIds, ['runtime-adaptive']);
      expect(
        find.text('Could not stop everything: 1 background task remains'),
        findsWidgets,
      );
      expect(find.text('Background work stopped'), findsNothing);
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);
      expect(fixture.chat.backgroundProcesses, hasLength(1));
      expect(fixture.chat.canStopSessionWork, isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.text('Could not stop everything: 1 background task remains'),
        findsWidgets,
      );

      await _disposeFixture(tester, fixture);
    },
  );

  Future<void> background(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  testWidgets(
    'P2-3 live-confirmed processes are not marked stale by a retained '
    'subagent count',
    (tester) async {
      final fixture = await _mountChat(
        tester,
        changeEventsAvailable: true,
        attachDesktopRuntimeOnLoad: true,
        resumedSessionRunning: false,
        subagents: const [
          DesktopSubagentSnapshot(subagentId: 'child-1', status: 'running'),
        ],
      );
      // The delegating turn ends first; its child keeps running afterwards.
      expect(
        await fixture.chat.send(
          fullText: 'Delegate and finish',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      fixture.gateway.emit('message.start');
      fixture.gateway.emit('message.complete', const {'text': 'Delegated.'});
      await tester.pump();
      fixture.gateway.emit('subagent.start', const {
        'subagent_id': 'child-1',
        'event_id': 'e1',
        'event_revision': 1,
        'status': 'running',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.chat.safeActiveSubagentCount, 1);
      expect(fixture.chat.isStreaming, isFalse);

      // Background cut: the subagent count is retained as last known state.
      await background(tester);
      fixture.gateway.dropTransport();
      await tester.pump();
      expect(fixture.chat.desktopRuntimeSessionId, isNull);
      expect(fixture.chat.subagentLivenessStale, isTrue);

      // Resume reattaches; subagent.list has not answered yet, but the fenced
      // process.list on the live runtime confirms a running process.
      final listGate = fixture.gateway.listGate = Completer<void>();
      fixture.gateway
        ..subagents = const []
        ..processSnapshot = const AgentCenterSnapshot(
          snapshots: [],
          processes: [
            BackgroundProcessEntry(
              opaqueId: 'process-live',
              status: AgentCenterStatus.running,
              uptimeSeconds: 5,
              command: 'sleep 200',
            ),
          ],
        );
      await resume(tester);
      for (var i = 0; i < 6; i += 1) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-adaptive');
      expect(fixture.chat.backgroundProcesses.map((p) => p.id), [
        'process-live',
      ]);
      expect(fixture.chat.subagentLivenessStale, isTrue);

      // Background processes now live in the supplemental Activity sheet.
      expect(fixture.chat.backgroundProcessesStale, isFalse);
      await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final card = find.byKey(const ValueKey('subagent-panel'));
      expect(card, findsOneWidget);
      final process = find.byKey(
        const ValueKey('running-process-process-live'),
      );
      expect(process, findsOneWidget);
      expect(
        find.descendant(of: process, matching: find.text('Last known state')),
        findsNothing,
        reason: 'the processes were just confirmed live by process.list',
      );
      // A retained agent may be unconfirmed in the same sheet; it must not
      // taint the separately live-confirmed process section.
      final agent = find.descendant(
        of: card,
        matching: find.byKey(const ValueKey('subagent-row-child-1')),
      );
      expect(agent, findsOneWidget);
      expect(
        find.descendant(
          of: agent,
          matching: find.textContaining('Unconfirmed', findRichText: true),
        ),
        findsOneWidget,
      );
      final processes = find.descendant(
        of: card,
        matching: find.byType(RunningWork),
      );
      expect(processes, findsOneWidget);
      for (final warning in ['Last known state', 'Unconfirmed']) {
        expect(
          find.descendant(
            of: processes,
            matching: find.textContaining(warning, findRichText: true),
          ),
          findsNothing,
        );
      }
      Navigator.of(tester.element(card)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      listGate.complete();
      fixture.gateway.listGate = null;
      await tester.pump(const Duration(milliseconds: 500));
      await _disposeFixture(tester, fixture);
    },
  );

  testWidgets(
    'F3 resume relaunches the viewer attach once after a background transport loss',
    (tester) async {
      final fixture = await _mountChat(
        tester,
        changeEventsAvailable: true,
        attachDesktopRuntimeOnLoad: true,
        resumedSessionRunning: false,
      );
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-adaptive');
      expect(fixture.chat.isStreaming, isFalse);

      await background(tester);
      fixture.gateway.dropTransport();
      await tester.pump();
      expect(fixture.chat.desktopRuntimeSessionId, isNull);
      expect(fixture.chat.desktopViewerRecoveryClosed, isFalse);

      fixture.gateway
        ..resetCounts()
        ..resumeExistingCalls = 0
        ..resumeExistingGate = Completer<void>();
      await resume(tester);
      await tester.pump();
      // A repeated `resumed` without leaving the foreground coalesces.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(fixture.gateway.resumeExistingCalls, 1);
      // The service owns the reattach after a background cut and coalesces it:
      // bouncing through `inactive` neither duplicates nor drops the attach.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(fixture.gateway.resumeExistingCalls, 1);
      expect(fixture.gateway.listCalls, 0);
      expect(fixture.gateway.processCalls, 0);

      fixture.gateway.resumeExistingGate!.complete();
      fixture.gateway.resumeExistingGate = null;
      for (var i = 0; i < 6; i += 1) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-adaptive');
      expect(fixture.gateway.resumeExistingCalls, 1);
      expect(fixture.gateway.listCalls, greaterThanOrEqualTo(1));
      expect(fixture.gateway.processCalls, greaterThanOrEqualTo(1));

      await _disposeFixture(tester, fixture);
    },
  );

  testWidgets(
    'F3 resume does not relaunch the viewer attach when recovery is closed',
    (tester) async {
      final fixture = await _mountChat(
        tester,
        changeEventsAvailable: true,
        attachDesktopRuntimeOnLoad: true,
        resumedSessionRunning: false,
      );
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-adaptive');

      await background(tester);
      fixture.gateway.dropTransport(
        const TuiGatewayRpcError(
          'transport',
          'malformed frame',
          origin: CompressionFailureOrigin.malformed,
        ),
      );
      await tester.pump();
      expect(fixture.chat.desktopRuntimeSessionId, isNull);
      expect(fixture.chat.desktopViewerRecoveryClosed, isTrue);

      fixture.gateway
        ..resetCounts()
        ..resumeExistingCalls = 0;
      await resume(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.gateway.resumeExistingCalls, 0);
      expect(fixture.chat.desktopRuntimeSessionId, isNull);
      expect(fixture.gateway.listCalls, 0);
      expect(fixture.gateway.processCalls, 0);

      await _disposeFixture(tester, fixture);
    },
  );

  testWidgets(
    'F3 resume does not relaunch the viewer attach during a live turn',
    (tester) async {
      final fixture = await _mountChat(
        tester,
        changeEventsAvailable: true,
        attachDesktopRuntimeOnLoad: true,
        resumedSessionRunning: false,
      );
      expect(
        await fixture.chat.send(
          fullText: 'Keep streaming while the app is in the background',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      fixture.gateway.emit('message.start');
      await tester.pump();
      expect(fixture.chat.isStreaming, isTrue);

      // The service's own turn recovery owns the reattach of a live turn; hold
      // it in flight so any extra session.resume can only come from resume.
      fixture.gateway.resumeExistingGate = Completer<void>();
      await background(tester);
      fixture.gateway.dropTransport();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.chat.desktopRuntimeSessionId, isNull);
      expect(fixture.chat.isStreaming, isTrue);

      final serviceRecoveryCalls = fixture.gateway.resumeExistingCalls;
      await resume(tester);
      await tester.pump();
      await tester.pump();
      // Recovery is suspended in the background: the one resume after the
      // return is the service's own turn recovery, never the screen's attach.
      expect(fixture.gateway.resumeExistingCalls, serviceRecoveryCalls + 1);
      for (var i = 0; i < 4; i += 1) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(fixture.gateway.resumeExistingCalls, serviceRecoveryCalls + 1);
      fixture.gateway.resumeExistingGate!.complete();
      fixture.gateway.resumeExistingGate = null;

      await _disposeFixture(tester, fixture);
    },
  );

  testWidgets(
    'C2 resume attaches the idle parent once a stale live turn settles from '
    'the durable transcript and lists its async child',
    (tester) async {
      // The parent delegated an async child and its turn ended while the app
      // was away: on return the local turn still reads as live, so the
      // screen defers the attach to the service's resume reconciliation.
      var durable = <Map<String, dynamic>>[];
      final fixture = await _mountChat(
        tester,
        changeEventsAvailable: true,
        attachDesktopRuntimeOnLoad: true,
        resumedSessionRunning: false,
        storedMessageLoader: (_, _) async => durable,
      );
      expect(
        await fixture.chat.send(
          fullText: 'Delegate in the background',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      fixture.gateway.emit('message.start');
      await tester.pump();
      expect(fixture.chat.isStreaming, isTrue);

      await background(tester);
      fixture.gateway.dropTransport();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.chat.desktopRuntimeSessionId, isNull);
      expect(fixture.chat.isStreaming, isTrue);

      // Meanwhile the turn finished on the server; its async child runs on.
      durable = [
        {
          'message_id': 'c2-user',
          'role': 'user',
          'content': 'Delegate in the background',
        },
        {
          'message_id': 'c2-answer',
          'role': 'assistant',
          'content': 'Delegated.',
        },
      ];
      fixture.gateway
        ..resetCounts()
        ..resumeExistingCalls = 0
        ..subagents = const [
          DesktopSubagentSnapshot(subagentId: 'child-async', status: 'running'),
        ];

      // No navigation, gesture or layout change: only the return.
      await resume(tester);
      for (var i = 0; i < 6; i += 1) {
        await tester.pump();
      }
      for (var i = 0; i < 10; i += 1) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      expect(fixture.chat.isStreaming, isFalse);
      expect(
        fixture.chat.desktopRuntimeSessionId,
        'runtime-adaptive',
        reason: 'the idle parent must be reattached after the return',
      );
      expect(
        fixture.gateway.resumeExistingCalls,
        1,
        reason: 'exactly one viewer attach',
      );
      expect(fixture.gateway.listCalls, greaterThanOrEqualTo(1));
      expect(fixture.chat.safeActiveSubagentCount, 1);

      await _disposeFixture(tester, fixture);
    },
  );

  testWidgets(
    'N6a: sessions.changed broadcasts do not relaunch the full snapshot',
    (tester) async {
      final fixture = await _mountChat(tester, changeEventsAvailable: true);
      _expectFullReads(fixture.gateway, 1);
      fixture.gateway.resetCounts();

      // An idle visible chat on a busy server: another session changes every
      // 10 s and the server broadcasts sessions.changed to every client.
      for (var second = 0; second < 120; second += 10) {
        fixture.gateway.emit('sessions.changed');
        await tester.pump(const Duration(seconds: 10));
      }

      // A full snapshot is subagent.list + spawn_tree.list + process.list +
      // session.control.read = 4 RPC; budget 6 RPC/min over 120 s.
      final rpc =
          fixture.gateway.listCalls +
          2 * fixture.gateway.processCalls +
          fixture.gateway.controlCalls;
      expect(rpc, lessThanOrEqualTo(12), reason: 'polling RPC in 120 s');
      // The 60 s backstop is not starved by the broadcasts.
      expect(fixture.gateway.listCalls, greaterThanOrEqualTo(1));
      expect(fixture.gateway.controlCalls, greaterThanOrEqualTo(1));

      // Freshness: a subagent event still reaches its snapshot within 1 s.
      final listBefore = fixture.gateway.listCalls;
      fixture.gateway.emit('subagent.start', const {
        'subagent_id': 'unknown-child',
        'event_id': 'event-n6a',
        'event_revision': 1,
        'status': 'running',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.gateway.listCalls, listBefore + 1);

      await _disposeFixture(tester, fixture);
    },
  );

  testWidgets('hidden and background routes perform zero reads', (
    tester,
  ) async {
    final fixture = await _mountChat(tester, changeEventsAvailable: true);
    _expectFullReads(fixture.gateway, 1);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push<void>(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    fixture.gateway.resetCounts();
    await tester.pump(const Duration(seconds: 65));
    _expectFullReads(fixture.gateway, 0);

    navigator.pop();
    await tester.pump();
    await tester.pump();
    _expectFullReads(fixture.gateway, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    fixture.gateway.resetCounts();
    await tester.pump(const Duration(seconds: 65));
    _expectFullReads(fixture.gateway, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _disposeFixture(tester, fixture);
  });

  // subagent-roster: the visible chat's own roster poll, as Desktop
  // app/chat/composer/status-stack/use-subagent-snapshot.ts: `subagent.list`
  // every 5 s while visible; a failed read keeps the roster; three failures
  // in a row stop it until the gateway state changes (or the chat is shown
  // again). Process and control reads keep their own adaptive cadence.
  group('roster poll (Desktop 5 s)', () {
    setUp(
      () => ChatScreen.subagentRosterPollInterval = const Duration(seconds: 5),
    );

    testWidgets('the visible chat re-reads only subagent.list every 5 s', (
      tester,
    ) async {
      final fixture = await _mountChat(tester, changeEventsAvailable: true);
      _expectFullReads(fixture.gateway, 1);

      await tester.pump(const Duration(seconds: 5));
      expect(fixture.gateway.listCalls, 2);
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.gateway.listCalls, 3);
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.gateway.listCalls, 4);
      // The process and control snapshot keeps its 60 s idle backstop.
      expect(fixture.gateway.processCalls, 1);
      expect(fixture.gateway.controlCalls, 1);

      await _disposeFixture(tester, fixture);
    });

    testWidgets('a covered or backgrounded chat does not poll the roster', (
      tester,
    ) async {
      final fixture = await _mountChat(tester, changeEventsAvailable: true);
      _expectFullReads(fixture.gateway, 1);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      fixture.gateway.resetCounts();
      await tester.pump(const Duration(seconds: 30));
      expect(fixture.gateway.listCalls, 0);

      navigator.pop();
      await tester.pump();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      fixture.gateway.resetCounts();
      await tester.pump(const Duration(seconds: 30));
      expect(fixture.gateway.listCalls, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _disposeFixture(tester, fixture);
    });

    testWidgets('a subagent detail page over the chat keeps the roster poll '
        'going (REVISION-3 #7); closing it with the chat covered stops it', (
      tester,
    ) async {
      final fixture = await _mountChat(tester, changeEventsAvailable: true);
      _expectFullReads(fixture.gateway, 1);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      // The detail page: a route over the chat that holds its own lease.
      unawaited(
        navigator.push<void>(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final release =
          (tester.state(find.byType(ChatScreen, skipOffstage: false))
                  as dynamic)
              .acquireSubagentDetailLeaseForTesting() as VoidCallback;
      fixture.gateway.resetCounts();
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.gateway.listCalls, greaterThanOrEqualTo(1));
      final reads = fixture.gateway.listCalls;
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.gateway.listCalls, greaterThan(reads));

      release();
      await tester.pump();
      fixture.gateway.resetCounts();
      await tester.pump(const Duration(seconds: 30));
      expect(fixture.gateway.listCalls, 0, reason: 'covered, no lease');

      navigator.pop();
      await tester.pump();
      await _disposeFixture(tester, fixture);
    });

    testWidgets(
      'three failed reads stop the poll and keep the roster; the gateway '
      'coming back reads again at once',
      (tester) async {
        final fixture = await _mountChat(
          tester,
          changeEventsAvailable: true,
          subagents: const [
            DesktopSubagentSnapshot(
              subagentId: 'kept-child',
              goal: 'Keep me',
              status: 'running',
            ),
          ],
        );
        _expectFullReads(fixture.gateway, 1);
        expect(fixture.chat.activeSubagentCount, 1);

        fixture.gateway.failList = true;
        for (var second = 0; second < 28; second++) {
          await tester.pump(const Duration(seconds: 1));
        }
        // Reads at +5, +10 and +15 fail; then the poll rests (the active
        // adaptive backstop is 30 s, not reached yet).
        expect(fixture.gateway.listCalls, 4);
        expect(fixture.gateway.processCalls, 1);
        // A failed read proves nothing: the child is still shown.
        expect(fixture.chat.activeSubagentCount, 1);
        expect(
          fixture.chat.subagentActivities.map((a) => a.subagentId),
          ['kept-child'],
        );

        fixture.gateway.failList = false;
        fixture.gateway.connected = false;
        fixture.gateway.emit('status.update', const {'kind': 'process'});
        await tester.pump();
        expect(fixture.gateway.listCalls, 4, reason: 'no read while offline');

        fixture.gateway.connected = true;
        fixture.gateway.emit('status.update', const {'kind': 'process'});
        await tester.pump();
        expect(fixture.gateway.listCalls, 5, reason: 'gateway back: read now');

        await _disposeFixture(tester, fixture);
      },
    );
  });

  // oldchat-capsule: a finished async delegation in an old chat, reopened cold
  // with no live event. The chat shows the editorial capsule «Subagentes ·
  // 2/2 / 2 completados · 0:06» between the parent's answer and its summary
  // (Console's advantage over the official app in old chats). The roster's
  // own reads (the 5 s poll, the idle backstop) answer an empty live list:
  // they must not hide that capsule behind a group that draws nothing.
  group('old chat reopened cold (oldchat-capsule)', () {
    Future<void> expectCapsuleKept(
      WidgetTester tester, {
      required Duration? poll,
      required int seconds,
    }) async {
      ChatScreen.subagentRosterPollInterval = poll;
      final fixture = await _mountChat(
        tester,
        changeEventsAvailable: true,
        resumedSessionRunning: false,
        coldTranscript: _oldDelegationChat(),
      );
      for (var second = 0; second < seconds; second += 1) {
        await tester.pump(const Duration(seconds: 1));
      }
      // One report of every link (transcript card, roster, painted widget),
      // so a failure says which one broke.
      final cards = fixture.chat.messages
          .map(historicalSubagentCompletionOf)
          .whereType<SubagentCompletionCardData>()
          .toList();
      final painted = find
          .byType(SubagentCompletionCard, skipOffstage: false)
          .evaluate()
          .length;
      final diag = {
        'listCalls': fixture.gateway.listCalls,
        'cardOnMessage': cards.map((c) => c.subagentIds).toList(),
        'roster': fixture.chat.conversationSubagents
            .map((a) => '${a.subagentId}:${a.phase.name}')
            .toList(),
        'paintedCapsules': painted,
      };
      expect(
        fixture.gateway.listCalls,
        greaterThanOrEqualTo(2),
        reason: '$diag',
      );
      expect(cards, hasLength(1), reason: '$diag');
      expect(cards.single.subagentIds, [
        'sa-0-fd1b1751',
        'sa-1-4b70c0cc',
      ], reason: '$diag');
      // No child of that delegation is live: nothing above the composer
      // stands for them, so the transcript capsule is their one place.
      expect(
        fixture.chat.conversationSubagents.where((a) => !a.isTerminal),
        isEmpty,
        reason: '$diag',
      );
      expect(painted, 1, reason: '$diag');
      expect(tester.takeException(), isNull);
      await _disposeFixture(tester, fixture);
    }

    testWidgets('the 5 s roster poll keeps the finished delegation capsule', (
      tester,
    ) async {
      await expectCapsuleKept(
        tester,
        poll: const Duration(seconds: 5),
        seconds: 11,
      );
    });

    testWidgets(
      'the idle snapshot backstop keeps the finished delegation capsule',
      (tester) async {
        await expectCapsuleKept(tester, poll: null, seconds: 65);
      },
    );

    // Closing the group never loses the way back, even after a restart: the
    // closed ids live in the preferences, the snapshots of the closed agents
    // did not survive. The roster rebuilt from the transcript lists them in
    // «Subagentes · n», and «Mostrar subagentes ocultos» brings the capsule
    // back.
    Future<_Fixture> reopenAfterRestart(
      WidgetTester tester,
      List<String> closedIds,
    ) async {
      ChatScreen.subagentRosterPollInterval = const Duration(seconds: 5);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        SubagentGroupVisibility.prefsKey,
        jsonEncode({'${_connection.id}.${_session.logicalId}': closedIds}),
      );
      // A new process: a fresh store read back from the preferences.
      await SubagentGroupVisibility.load(prefs);
      addTearDown(SubagentGroupVisibility.shared.debugReset);
      final fixture = await _mountChat(
        tester,
        changeEventsAvailable: true,
        resumedSessionRunning: false,
        coldTranscript: _oldDelegationChat(),
      );
      for (var second = 0; second < 11; second += 1) {
        await tester.pump(const Duration(seconds: 1));
      }
      return fixture;
    }

    int paintedCapsules() => find
        .byType(SubagentCompletionCard, skipOffstage: false)
        .evaluate()
        .length;

    Future<ChatControlSheet> openChatMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('chat-settings-button')));
      await tester.pump();
      await tester.pump(kChatNotchSheetOpen);
      return tester.widget<ChatControlSheet>(find.byType(ChatControlSheet));
    }

    testWidgets('closed before a restart: the menu lists them and «Mostrar '
        'subagentes ocultos» brings the capsule back', (tester) async {
      final fixture = await reopenAfterRestart(tester, const [
        'sa-0-fd1b1751',
        'sa-1-4b70c0cc',
      ]);
      // The person closed them: the capsule stays out of the way.
      expect(paintedCapsules(), 0);

      final menu = await openChatMenu(tester);
      expect(menu.labels.subagents, 'Subagents · 2');
      expect(menu.onSubagents, isNotNull);
      expect(menu.labels.showHiddenSubagents, 'Show hidden subagents');
      expect(menu.onShowHiddenSubagents, isNotNull);
      menu.onShowHiddenSubagents!();
      for (var frame = 0; frame < 8; frame += 1) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(
        SubagentGroupVisibility.shared.isAgentClosed(
          '${_connection.id}.${_session.logicalId}',
          'sa-0-fd1b1751',
        ),
        isFalse,
      );
      expect(paintedCapsules(), 1);
      expect(tester.takeException(), isNull);
      await _disposeFixture(tester, fixture);
    });

    // A child that FAILED is finished too: its capsule in the transcript
    // stays, opening the «Failed» notice above the composer does not take it
    // away, and the capsule opens the failed detail.
    testWidgets('an old chat whose only child failed keeps its capsule and '
        'opens the failed detail', (tester) async {
      ChatScreen.subagentRosterPollInterval = const Duration(seconds: 5);
      final fixture = await _mountChat(
        tester,
        changeEventsAvailable: true,
        resumedSessionRunning: false,
        coldTranscript: _oldFailedDelegationChat(),
      );
      for (var second = 0; second < 11; second += 1) {
        await tester.pump(const Duration(seconds: 1));
      }
      String diag() => {
        'listCalls': fixture.gateway.listCalls,
        'roster': fixture.chat.conversationSubagents
            .map((a) => '${a.subagentId}:${a.phase.name}')
            .toList(),
        'paintedCapsules': paintedCapsules(),
        'pill': find
            .byKey(const ValueKey('delegates-capsule'))
            .evaluate()
            .length,
      }.toString();
      expect(
        fixture.gateway.listCalls,
        greaterThanOrEqualTo(2),
        reason: diag(),
      );
      expect(
        fixture.chat.conversationSubagents.map((a) => a.phase),
        [SubagentActivityPhase.failed],
        reason: diag(),
      );
      expect(paintedCapsules(), 1, reason: diag());

      // The «Failed» notice above the composer: opening it (which marks the
      // failure as seen) leaves the transcript capsule where it is.
      expect(find.byKey(const ValueKey('delegates-capsule')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      Navigator.of(
        tester.element(find.byKey(const ValueKey('subagent-panel'))),
      ).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 6));
      expect(paintedCapsules(), 1, reason: diag());

      // The capsule opens the delegation with its failed child.
      final open = find.byKey(const ValueKey('subagent-completion-open'));
      await tester.ensureVisible(open);
      await tester.pump();
      await tester.tap(open);
      for (var frame = 0; frame < 8; frame += 1) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      // Historical rows are keyed «<delegation>#<task>».
      final row = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'subagent-row-$_failedDelegationId#',
            ),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('Failed', findRichText: true),
        ),
        findsWidgets,
      );
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SubagentDetailScreen), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('Billing or credits exhausted', findRichText: true),
        300,
        scrollable: find
            .descendant(
              of: find.byType(SubagentDetailScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.takeException(), isNull);
      await _disposeFixture(tester, fixture);
    });

    testWidgets('closed ids of other agents hide nothing here and offer no '
        '«Mostrar subagentes ocultos»', (tester) async {
      final fixture = await reopenAfterRestart(tester, const [
        'sa-0-0ldc1d00',
        'deleg_0ld0ld00',
      ]);
      expect(paintedCapsules(), 1);
      final menu = await openChatMenu(tester);
      expect(menu.onShowHiddenSubagents, isNull);
      expect(tester.takeException(), isNull);
      await _disposeFixture(tester, fixture);
    });
  });
}

const _oldDelegationId = 'deleg_fe60aadc';

/// The stored transcript of the device chat «Hacer prueba con subagentes»
/// (shapes of a Hermes 0.22 session, as historical_delegation_rows_test).
List<Map<String, dynamic>> _oldDelegationChat() => [
  {
    'id': 1,
    'message_id': 'old-user',
    'role': 'user',
    'content': 'Podríamos hacer una prueba con subagentes?',
    'timestamp': 1794085960.0,
  },
  {
    'id': 2,
    'message_id': 'old-call',
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'call-delegate',
        'type': 'function',
        'function': {'name': 'delegate_task', 'arguments': '{}'},
      },
    ],
    'timestamp': 1794085985.0,
  },
  {
    'id': 3,
    'message_id': 'old-dispatch',
    'role': 'tool',
    'tool_name': 'delegate_task',
    'tool_call_id': 'call-delegate',
    'content': jsonEncode({
      'status': 'dispatched',
      'mode': 'background',
      'count': 2,
      'delegation_id': _oldDelegationId,
      'goals': [
        'Prueba de delegación A. Analiza esta afirmación.',
        'Prueba de delegación B. Explica la diferencia entre una copia de '
            'seguridad y alta disponibilidad.',
      ],
      'subagent_ids': ['sa-0-fd1b1751', 'sa-1-4b70c0cc'],
    }),
    'timestamp': 1794085987.0,
  },
  {
    'id': 4,
    'message_id': 'old-ack',
    'role': 'assistant',
    'content':
        'Los dos subagentes están ejecutándose en paralelo; sus resultados '
        'llegarán aquí al terminar.',
    'timestamp': 1794085988.0,
  },
  {
    'id': 5,
    'message_id': 'old-complete',
    'role': 'user',
    'content':
        '[ASYNC DELEGATION BATCH COMPLETE — $_oldDelegationId]\n'
        'A background fan-out unit you dispatched earlier — 2 subagent(s) — '
        'has finished; its consolidated results are below.\n\n'
        'Role: leaf   Model: claude-opus-5-5   Total duration: 6.10s\n\n'
        '--- ✓ TASK 1/2: Prueba de delegación A.  (status=completed, '
        'api_calls=1, 4.62s) ---\n'
        'Un ping no demuestra que la web funcione.\n\n'
        '--- ✓ TASK 2/2: Prueba de delegación B.  (status=completed, '
        'api_calls=1, 3.1s) ---\n'
        'Las copias permiten recuperar datos.\n',
    'timestamp': 1794085994.0,
    'display_kind': 'async_delegation_complete',
    'display_metadata': jsonEncode({
      'delegation_id': _oldDelegationId,
      'task_count': 2,
      'completed_count': 2,
      'failed_count': 0,
      'duration_seconds': 6.1,
    }),
  },
  {
    'id': 6,
    'message_id': 'old-final',
    'role': 'assistant',
    'content':
        'Prueba completada: ambos subagentes terminaron y devolvieron sus '
        'respuestas.',
    'timestamp': 1794085999.0,
  },
];

const _failedDelegationId = 'deleg_0fa11ed0';

/// An old chat whose one background child failed (a homogeneous batch: the
/// transcript proves its outcome, so the roster read makes it public).
List<Map<String, dynamic>> _oldFailedDelegationChat() => [
  {
    'id': 1,
    'message_id': 'fail-user',
    'role': 'user',
    'content': 'Delega una tarea que falle',
    'timestamp': 1794085960.0,
  },
  {
    'id': 2,
    'message_id': 'fail-call',
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'call-fail',
        'type': 'function',
        'function': {'name': 'delegate_task', 'arguments': '{}'},
      },
    ],
    'timestamp': 1794085985.0,
  },
  {
    'id': 3,
    'message_id': 'fail-dispatch',
    'role': 'tool',
    'tool_name': 'delegate_task',
    'tool_call_id': 'call-fail',
    'content': jsonEncode({
      'status': 'dispatched',
      'mode': 'background',
      'count': 1,
      'delegation_id': _failedDelegationId,
      'goals': ['Prueba de delegación C. Resume el informe.'],
      'subagent_ids': ['sa-0-fa11fa11'],
    }),
    'timestamp': 1794085987.0,
  },
  {
    'id': 4,
    'message_id': 'fail-ack',
    'role': 'assistant',
    'content': 'El subagente está trabajando; su resultado llegará aquí.',
    'timestamp': 1794085988.0,
  },
  {
    'id': 5,
    'message_id': 'fail-complete',
    'role': 'user',
    'content':
        '[ASYNC DELEGATION BATCH COMPLETE — $_failedDelegationId]\n'
        'A background fan-out unit you dispatched earlier — 1 subagent(s) — '
        'has finished; its consolidated results are below.\n\n'
        'Role: leaf   Model: claude-opus-5-5   Total duration: 6.10s\n\n'
        '--- ✗ TASK 1/1: Prueba de delegación C. Resume el informe.  '
        '(status=failed, api_calls=2, 6.1s) ---\n'
        'Billing or credits exhausted.\n',
    'timestamp': 1794085994.0,
    'display_kind': 'async_delegation_complete',
    'display_metadata': jsonEncode({
      'delegation_id': _failedDelegationId,
      'task_count': 1,
      'completed_count': 0,
      'failed_count': 1,
      'duration_seconds': 6.1,
    }),
  },
  {
    'id': 6,
    'message_id': 'fail-final',
    'role': 'assistant',
    'content': 'El subagente falló: no quedaban créditos.',
    'timestamp': 1794085999.0,
  },
];
