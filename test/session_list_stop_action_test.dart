import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _StopGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionActivityGateway,
        HermesDesktopSubagentGateway,
        HermesDesktopProcessStopGateway,
        HermesDesktopControlGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final interrupted = <String>[];
  final interruptedSubagents = <String>[];
  final killed = <({String runtimeId, String processId})>[];
  final failingSubagentIds = <String>{};
  final processStopRuntimeIds = <String>[];
  int get processStopCalls => processStopRuntimeIds.length;
  int subagentListCalls = 0;
  int processListCalls = 0;
  int? clearSubagentsOnListCall;
  int? blockedSubagentListCall;
  Completer<void>? subagentListGate;
  bool retainInterruptedSubagents = false;
  bool running = true;
  bool exposeProcess = false;
  List<DesktopSubagentSnapshot> subagents = const [];

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  DesktopSessionSnapshot _snapshot(String storedSessionId) =>
      DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-$storedSessionId',
        storedSessionId: storedSessionId,
        created: false,
        running: running,
        status: running ? 'working' : 'idle',
        inflight: running
            ? DesktopInflightTurn(user: 'keep working', streaming: true)
            : null,
      );

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-$storedSessionId',
    storedSessionId: storedSessionId,
    created: false,
    running: running,
    status: running ? 'working' : 'idle',
    inflight: running
        ? DesktopInflightTurn(user: 'keep working', streaming: true)
        : null,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => _snapshot(storedSessionId);

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw UnimplementedError();

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interrupted.add(runtimeSessionId);
    running = false;
  }

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    subagentListCalls += 1;
    if (subagentListCalls == blockedSubagentListCall) {
      await subagentListGate?.future;
    }
    final clearCall = clearSubagentsOnListCall;
    if (clearCall != null && subagentListCalls >= clearCall) {
      subagents = const [];
    }
    return subagents;
  }

  @override
  Future<DesktopSubagentTailResult> tailSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async => const DesktopSubagentTailResult(
    available: false,
    content: '',
    truncated: false,
  );

  @override
  Future<DesktopSubagentSteerResult> steerSubagent(
    String runtimeSessionId,
    String subagentId,
    String text,
  ) async => DesktopSubagentSteerResult(
    status: 'queued',
    subagentId: subagentId,
    text: text,
  );

  @override
  Future<DesktopSubagentInterruptResult> interruptSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async {
    interruptedSubagents.add(subagentId);
    if (failingSubagentIds.contains(subagentId)) {
      throw const TuiGatewayRpcError(
        'subagent.interrupt',
        'interrupt failed',
      );
    }
    if (!retainInterruptedSubagents) {
      subagents = subagents
          .where((subagent) => subagent.subagentId != subagentId)
          .toList(growable: false);
    }
    return DesktopSubagentInterruptResult(
      found: true,
      subagentId: subagentId,
    );
  }

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async => _snapshot(storedSessionId);

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => DesktopActiveSessionList(
    sessions: running
        ? const [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-stop-session',
              storedSessionId: 'stop-session',
              status: 'working',
            ),
          ]
        : const [],
  );

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async {
    processListCalls += 1;
    return AgentCenterSnapshot(
      snapshots: const [],
      processes: exposeProcess
          ? const [
              BackgroundProcessEntry(
                opaqueId: 'process-1',
                status: AgentCenterStatus.running,
                uptimeSeconds: 1,
              ),
            ]
          : const [],
    );
  }

  @override
  Future<void> killBackgroundProcess(
    String runtimeSessionId,
    String processId,
  ) async {
    killed.add((runtimeId: runtimeSessionId, processId: processId));
    exposeProcess = false;
  }

  @override
  Future<void> stopBackgroundProcesses(String runtimeSessionId) async {
    processStopRuntimeIds.add(runtimeSessionId);
    exposeProcess = false;
  }

  void emitControlUpdate(Map<String, dynamic> control) {
    _events.add(
      TuiGatewayEvent(
        type: 'session.control.update',
        sessionId: 'runtime-stop-session',
        payload: {'control': control},
      ),
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

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

SavedConnection _connection() => SavedConnection(
  id: 'stop-connection',
  label: 'Stop test',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

Session _session() => Session(
  id: 'stop-session',
  title: 'Stop session',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 1,
  isActive: true,
  preview: 'Working',
  startedAt: 1,
);

ApiClient _api() => ApiClient(
  baseUrl: 'https://example.invalid',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('{"messages":[]}', 200)),
);

ActiveChat _backgroundChat(_StopGateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _connection(),
  sessionId: _session().id,
  sessionTitle: _session().title,
  notifications: null,
  onTerminal: () {},
  api: _api(),
  desktopGateway: gateway,
  initialStoredSessionId: _session().id,
  storedMessageLoader: (_, _) async => const [],
  attachDesktopRuntimeOnLoad: true,
  allowUnownedDesktopSnapshotForTesting: true,
  backgroundStopRecheckDelays: const [
    Duration.zero,
    Duration.zero,
    Duration.zero,
  ],
);

Future<ActiveChat> _hydrateBackgroundChat(_StopGateway gateway) async {
  final chat = _backgroundChat(gateway);
  await chat.loadMessages();
  await Future.wait([
    chat.refreshSubagentsForTesting(),
    chat.refreshBackgroundProcessesForTesting(),
  ]);
  chat.state = ChatPipelineState.idle;
  return chat;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('row Stop resumes a missing ActiveChat and interrupts its runtime', () async {
    final gateway = _StopGateway();
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    addTearDown(gateway.close);

    expect(service.of(_connection().id, _session().id), isNull);

    await service.stopSessionWork(
      connection: _connection(),
      session: _session(),
      desktopGateway: gateway,
      api: _api(),
      storedMessageLoader: (_, _) async => const [],
    );

    expect(gateway.interrupted, ['runtime-stop-session']);
    expect(service.of(_connection().id, _session().id), isNull);
  });

  test('live-turn session Stop interrupts every active child and process', () async {
    final gateway = _StopGateway()
      ..exposeProcess = true
      ..subagents = const [
        DesktopSubagentSnapshot(subagentId: 'child-a', status: 'running'),
        DesktopSubagentSnapshot(subagentId: 'child-b', status: 'tool'),
      ];
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    addTearDown(gateway.close);
    final chat = service.attach(
      connection: _connection(),
      sessionId: _session().id,
      sessionTitle: _session().title,
      initialStoredSessionId: _session().id,
      desktopGateway: gateway,
      api: _api(),
      storedMessageLoader: (_, _) async => const [],
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );
    await chat.loadMessages();
    await Future.wait([
      chat.refreshSubagentsForTesting(),
      chat.refreshBackgroundProcessesForTesting(),
    ]);
    expect(chat.safeActiveSubagentCount, 2);
    expect(chat.backgroundProcesses.map((process) => process.id), ['process-1']);

    await service.stopSessionWork(
      connection: _connection(),
      session: _session(),
    );

    expect(gateway.interrupted, ['runtime-stop-session']);
    expect(gateway.interruptedSubagents, ['child-a', 'child-b']);
    expect(gateway.processStopRuntimeIds, ['runtime-stop-session']);
    expect(gateway.killed, isEmpty);
    expect(chat.state, ChatPipelineState.cancelled);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
    expect(chat.stopConfirmationOnlyBackground, isFalse);
  });

  test('schedule-only Stop confirms zero remaining background work', () async {
    final gateway = _StopGateway()..running = false;
    final chat = await _hydrateBackgroundChat(gateway);
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    gateway.emitControlUpdate(const {
      'loop': {
        'status': 'active',
        'interval_seconds': 300,
        'ticks_fired': 0,
        'awaiting_response': false,
      },
      'revision': 'loop-active',
    });
    await Future<void>.delayed(Duration.zero);

    expect(chat.canStopSessionWork, isTrue);
    final result = await chat.stopSessionWork();

    expect(result.remainingBackgroundTasks, 0);
    expect(chat.backgroundStopRemainingTasks, isNull);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
    expect(chat.stopConfirmationOnlyBackground, isTrue);
  });

  test('background Stop confirms only after the second authoritative recheck', () async {
    final gateway = _StopGateway()
      ..running = false
      ..exposeProcess = true
      ..retainInterruptedSubagents = true
      ..subagents = const [
        DesktopSubagentSnapshot(subagentId: 'child-a', status: 'running'),
        DesktopSubagentSnapshot(subagentId: 'child-b', status: 'tool'),
      ];
    final chat = await _hydrateBackgroundChat(gateway);
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    expect(chat.isStreaming, isFalse);
    expect(chat.remoteSurfaceOwnsLiveTurn, isFalse);
    final secondRecheck = Completer<void>();
    gateway
      ..clearSubagentsOnListCall = gateway.subagentListCalls + 2
      ..blockedSubagentListCall = gateway.subagentListCalls + 2
      ..subagentListGate = secondRecheck;

    final firstStop = chat.stopSessionWork();
    final duplicateStop = chat.stopSessionWork();
    expect(identical(firstStop, duplicateStop), isTrue);
    for (var index = 0; index < 8; index++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(chat.backgroundStopVerificationInFlight, isTrue);
    expect(chat.stopConfirmationOnlyBackground, isFalse);
    expect(gateway.interruptedSubagents, ['child-a', 'child-b']);
    expect(gateway.processStopCalls, 1);

    secondRecheck.complete();
    final result = await firstStop;
    expect(result.allBackgroundWorkStopped, isTrue);
    expect(chat.backgroundStopVerificationInFlight, isFalse);
    expect(chat.backgroundStopRemainingTasks, 0);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
    expect(chat.stopConfirmationOnlyBackground, isTrue);
    expect(gateway.interruptedSubagents, ['child-a', 'child-b']);
    expect(gateway.processStopCalls, 1);
  });

  test('one failed child interrupt does not block siblings and stays truthful', () async {
    final gateway = _StopGateway()
      ..running = false
      ..failingSubagentIds.add('child-a')
      ..subagents = const [
        DesktopSubagentSnapshot(subagentId: 'child-a', status: 'running'),
        DesktopSubagentSnapshot(subagentId: 'child-b', status: 'thinking'),
      ];
    final chat = await _hydrateBackgroundChat(gateway);
    addTearDown(chat.dispose);
    addTearDown(gateway.close);

    final result = await chat.stopSessionWork();

    expect(gateway.interruptedSubagents, ['child-a', 'child-b']);
    expect(gateway.processStopCalls, 1);
    expect(result.remainingSubagents, 1);
    expect(result.remainingProcesses, 0);
    expect(chat.backgroundStopRemainingTasks, 1);
    expect(chat.stopConfirmationOnlyBackground, isFalse);
    expect(chat.canStopSessionWork, isTrue);
  });

  test('children that remain listed keep Stop visible with a warning result', () async {
    final gateway = _StopGateway()
      ..running = false
      ..retainInterruptedSubagents = true
      ..subagents = const [
        DesktopSubagentSnapshot(subagentId: 'child-a', status: 'running'),
        DesktopSubagentSnapshot(subagentId: 'child-b', status: 'tool'),
      ];
    final chat = await _hydrateBackgroundChat(gateway);
    addTearDown(chat.dispose);
    addTearDown(gateway.close);

    final result = await chat.stopSessionWork();

    expect(gateway.processStopCalls, 1);
    expect(result.remainingBackgroundTasks, 2);
    expect(chat.backgroundStopRemainingTasks, 2);
    expect(chat.stopConfirmationOnlyBackground, isFalse);
    expect(chat.canStopSessionWork, isTrue);
  });
}
