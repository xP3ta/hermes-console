// La pastilla de actividad no puede apagarse mientras Hermes sigue trabajando
// solo porque el socket se cortó o el runtime rotó (F1/F2/F4). Lo último visto
// se conserva como «último estado conocido» hasta una prueba real: un
// `process.list`/`subagent.list` con fence sobre una sesión viva, una fila
// durable de finalización o un tope de edad. Stop y los retiros explícitos
// siguen limpiando.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';
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

const _runtimeId = 'runtime-retained';
const _storedId = 'stored-retained';

/// Modela el servidor real: `process.list`/`subagent.list` son
/// `live_session=True` (solo responden sobre un runtime vivo) y, tras el reap
/// de la sesión huérfana, la recuperación ligada al roster falla con
/// `ROSTER_SESSION_NOT_ACTIVE` (preflight local del cliente real).
class _RetainingGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopRosterBoundRecoveryGateway,
        HermesDesktopSubagentGateway,
        HermesDesktopControlGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  bool connected = true;

  /// El servidor retiró la sesión huérfana: no hay runtime al que volver.
  bool reaped = false;
  String liveRuntimeId = _runtimeId;
  List<BackgroundProcessEntry> processes = const [];
  List<DesktopSubagentSnapshot> subagents = const [];
  int processCalls = 0;
  int subagentCalls = 0;

  /// Retiene la respuesta de `subagent.list` (el roster aún no contestó).
  Completer<void>? subagentListGate;
  int rosterResumeCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  void drop() {
    connected = false;
    _events.addError(StateError('socket dropped'));
  }

  void emit(String type, Map<String, dynamic> payload) {
    _events.add(
      TuiGatewayEvent(type: type, sessionId: liveRuntimeId, payload: payload),
    );
  }

  DesktopSessionSnapshot _snapshot(String storedSessionId) =>
      DesktopSessionSnapshot(
        runtimeSessionId: liveRuntimeId,
        storedSessionId: storedSessionId,
        created: false,
      );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    if (reaped) {
      // Attach-on-load only rejoins an advertised runtime; a reaped session
      // has none (the real client checks the roster before resuming).
      throw const TuiGatewayRpcError(
        'session.active_list',
        'Hermes no longer advertises the durable session',
        origin: CompressionFailureOrigin.localPreflight,
        data: {'reason': rosterSessionNotActiveReason},
      );
    }
    return _snapshot(storedSessionId);
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('no create in this fixture');

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async => _snapshot(storedSessionId);

  @override
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    rosterResumeCalls += 1;
    await connect();
    if (reaped) {
      throw const TuiGatewayRpcError(
        'session.active_list',
        'Hermes no longer advertises the durable session',
        origin: CompressionFailureOrigin.localPreflight,
        data: {'reason': rosterSessionNotActiveReason},
      );
    }
    return DesktopRosterBoundRecovery.forTesting(
      _snapshot(storedSessionId),
      this,
    );
  }

  @override
  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery) => true;

  @override
  bool consumeRosterBoundViewerAttachment(
    DesktopRosterBoundRecovery recovery,
  ) => true;

  @override
  // ignore: deprecated_member_use_from_same_package
  void commitRecoveryRuntime(String runtimeSessionId) {}

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    subagentCalls += 1;
    await subagentListGate?.future;
    if (reaped || runtimeSessionId != liveRuntimeId) {
      throw const TuiGatewayRpcError('subagent.list', 'session not live');
    }
    return subagents;
  }

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async {
    processCalls += 1;
    if (reaped || runtimeSessionId != liveRuntimeId) {
      throw const TuiGatewayRpcError('process.list', 'session not live');
    }
    return AgentCenterSnapshot(snapshots: const [], processes: processes);
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

const _runningProcess = BackgroundProcessEntry(
  opaqueId: 'proc-build',
  status: AgentCenterStatus.running,
  uptimeSeconds: 5,
  command: 'make build',
);

ActiveChat _chat(
  _RetainingGateway gateway, {
  StoredSessionMessageLoader? storedMessageLoader,
  Duration retainedActivityMaxAge = const Duration(minutes: 10),
}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'conn-retained',
    label: 'Retained',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-key',
    useHttps: true,
    kind: InstanceKind.vps,
  ),
  sessionId: _storedId,
  sessionTitle: 'Retained',
  sessionProfile: 'default',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:1',
    apiKey: 'test-key',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  ),
  desktopGateway: gateway,
  attachDesktopRuntimeOnLoad: true,
  allowUnownedDesktopSnapshotForTesting: true,
  storedMessageLoader: storedMessageLoader,
  desktopRecoveryBackoff: const [Duration.zero],
  retainedActivityMaxAge: retainedActivityMaxAge,
);

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<ActiveChat> _boundWithLiveWork(
  _RetainingGateway gateway, {
  StoredSessionMessageLoader? storedMessageLoader,
}) async {
  final chat = _chat(gateway, storedMessageLoader: storedMessageLoader);
  chat.messagesLoaded = true;
  expect(
    await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
    isTrue,
  );
  // A live child keeps the pipeline executing; end that turn first so the
  // cut happens after it, while its delegated work is still running.
  if (gateway.subagents.isNotEmpty) await _endTurn(chat, gateway);
  await chat.refreshBackgroundProcessesForTesting();
  await chat.refreshSubagentsForTesting();
  return chat;
}

Future<void> _endTurn(ActiveChat chat, _RetainingGateway gateway) async {
  expect(
    await chat.send(
      fullText: 'start the background work',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  gateway.emit('message.start', const {});
  gateway.emit('message.complete', const {'text': 'Started.'});
  await _waitUntil(() => !chat.isStreaming);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'F1 un corte de transporte conserva los procesos como desfasados',
    () async {
      final gateway = _RetainingGateway()..processes = const [_runningProcess];
      final chat = await _boundWithLiveWork(gateway);
      addTearDown(chat.dispose);
      expect(chat.backgroundProcesses.map((p) => p.id), ['proc-build']);
      expect(chat.sessionActivity.stale, isFalse);

      gateway.reaped = true;
      gateway.drop();
      await _waitUntil(() => gateway.rosterResumeCalls >= 1);
      await Future<void>.delayed(Duration.zero);

      expect(chat.desktopRuntimeSessionId, isNull);
      // Honest: the row survives but is marked «último estado conocido».
      expect(chat.backgroundProcesses.map((p) => p.id), ['proc-build']);
      expect(chat.sessionActivity.active, isTrue);
      expect(chat.sessionActivity.stale, isTrue);
    },
  );

  test(
    'F1 un process.list con fence sobre la sesión viva liquida lo conservado',
    () async {
      final gateway = _RetainingGateway()..processes = const [_runningProcess];
      final chat = await _boundWithLiveWork(gateway);
      addTearDown(chat.dispose);

      gateway.drop();
      await _waitUntil(() => chat.desktopRuntimeSessionId != null);
      await _waitUntil(() => !chat.hasPendingBackgroundProcessRefresh);
      expect(chat.backgroundProcesses, hasLength(1));
      expect(chat.sessionActivity.stale, isTrue);

      // The live session answers: the process finished while disconnected.
      gateway.processes = const [];
      await chat.refreshBackgroundProcessesForTesting();

      expect(chat.backgroundProcesses, isEmpty);
      expect(chat.sessionActivity.stale, isFalse);
      expect(chat.sessionActivity.active, isFalse);
    },
  );

  test('F1 Stop sí limpia lo conservado tras un corte', () async {
    final gateway = _RetainingGateway()..processes = const [_runningProcess];
    final chat = await _boundWithLiveWork(gateway);
    addTearDown(chat.dispose);
    gateway.reaped = true;
    gateway.drop();
    await _waitUntil(() => gateway.rosterResumeCalls >= 1);
    expect(chat.backgroundProcesses, hasLength(1));

    await chat.stopSessionWork();

    expect(chat.backgroundProcesses, isEmpty);
    expect(chat.sessionActivity.active, isFalse);
  });

  test(
    'F1/F4 el recuento de subagentes sobrevive al corte y a la rotación hasta '
    'un subagent.list con fence',
    () async {
      final gateway = _RetainingGateway()
        ..subagents = const [
          DesktopSubagentSnapshot(subagentId: 'child-1', status: 'running'),
        ];
      final chat = await _boundWithLiveWork(gateway);
      addTearDown(chat.dispose);
      gateway.emit('subagent.start', const {
        'subagent_id': 'child-1',
        'status': 'running',
        'event_id': 'e1',
        'event_revision': 1,
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.safeActiveSubagentCount, 1);

      // The recovered runtime rotates (new incarnation, same lineage) and
      // subagent.list has not answered for it yet.
      gateway.liveRuntimeId = 'runtime-retained-2';
      gateway.subagents = const [];
      final listGate = gateway.subagentListGate = Completer<void>();
      gateway.drop();
      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-retained-2',
      );
      await Future<void>.delayed(Duration.zero);

      expect(chat.safeActiveSubagentCount, 1);
      expect(chat.subagentLivenessStale, isTrue);
      expect(chat.sessionActivity.active, isTrue);
      expect(chat.sessionActivity.stale, isTrue);

      // A fenced list on the live runtime is the authority that it ended.
      gateway.subagentListGate = null;
      listGate.complete();
      await chat.refreshSubagentsForTesting();
      await chat.refreshSubagentsForTesting();
      expect(chat.safeActiveSubagentCount, 0);
      expect(chat.subagentLivenessStale, isFalse);
      expect(chat.sessionActivity.active, isFalse);
    },
  );

  test(
    'F4 suspender la presentación no borra el recuento conservado',
    () async {
      final gateway = _RetainingGateway()
        ..subagents = const [
          DesktopSubagentSnapshot(subagentId: 'child-1', status: 'running'),
        ];
      final chat = await _boundWithLiveWork(gateway);
      addTearDown(chat.dispose);
      gateway.emit('subagent.start', const {
        'subagent_id': 'child-1',
        'status': 'running',
        'event_id': 'e1',
        'event_revision': 1,
      });
      await Future<void>.delayed(Duration.zero);
      gateway.reaped = true;
      gateway.drop();
      await _waitUntil(() => gateway.rosterResumeCalls >= 1);

      chat.suspendSubagentForegroundPresentation();

      expect(chat.safeActiveSubagentCount, 1);
      expect(chat.subagentLivenessStale, isTrue);
    },
  );

  test('F2 sesión reapeada: lo conservado se retira con la fila durable '
      'process_complete', () async {
    var completed = false;
    final gateway = _RetainingGateway()..processes = const [_runningProcess];
    final chat = await _boundWithLiveWork(
      gateway,
      storedMessageLoader: (_, _) async => [
        const {
          'message_id': 'u1',
          'role': 'user',
          'content': 'start the background work',
          'timestamp': 1,
        },
        const {
          'message_id': 'a1',
          'role': 'assistant',
          'content': 'Started.',
          'timestamp': 2,
        },
        if (completed)
          const {
            'message_id': 'done-1',
            'role': 'user',
            'content':
                '[IMPORTANT: Background process proc_0123456789ab exited '
                '(exit code 0).]',
            'display_kind': 'process_complete',
            'display_metadata': {'display_text': 'make build finished'},
            'timestamp': 3,
          },
        if (completed)
          const {
            'message_id': 'a2',
            'role': 'assistant',
            'content': 'The build finished.',
            'timestamp': 4,
          },
      ],
    );
    addTearDown(chat.dispose);
    gateway.reaped = true;
    gateway.drop();
    await _waitUntil(() => gateway.rosterResumeCalls >= 1);
    expect(chat.backgroundProcesses, hasLength(1));
    expect(chat.sessionActivity.stale, isTrue);

    await chat.loadMessages();
    expect(
      chat.backgroundProcesses,
      hasLength(1),
      reason: 'a transcript without a new completion row proves nothing',
    );

    completed = true;
    await chat.loadMessages();
    expect(chat.backgroundProcesses, isEmpty);
    expect(chat.sessionActivity.active, isFalse);
  });

  test(
    'F2 sesión reapeada: lo conservado caduca tras el tope de edad',
    () async {
      final gateway = _RetainingGateway()..processes = const [_runningProcess];
      final chat = _chat(
        gateway,
        retainedActivityMaxAge: const Duration(milliseconds: 300),
      )..messagesLoaded = true;
      addTearDown(chat.dispose);
      expect(
        await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isTrue,
      );
      await chat.refreshBackgroundProcessesForTesting();
      expect(chat.backgroundProcesses, hasLength(1));

      gateway.reaped = true;
      gateway.drop();
      await _waitUntil(() => gateway.rosterResumeCalls >= 1);
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.backgroundProcesses, hasLength(1));
      expect(chat.sessionActivity.stale, isTrue);

      await _waitUntil(() => chat.backgroundProcesses.isEmpty);
      expect(chat.sessionActivity.active, isFalse);
    },
  );
}
