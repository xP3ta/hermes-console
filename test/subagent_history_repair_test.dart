// Durable repair of subagents that ended while the phone was away (Hermes
// `session.history`, read after a fenced `subagent.list` no longer names
// them). The read is fenced by the real authority — gateway, runtime, scope
// and binding (session epoch) — and not by a newer roster read of the same
// runtime: a history slower than the 5 s roster poll still settles the
// children. A child that is live again when the result applies stays live; a
// late list cannot revive a completed child. Losing the UI lease keeps the
// evidence private. A failed read gets one retry on the next fenced list of
// the same binding; a read without evidence is not repeated. Reads are
// counted exactly. Fixture adapted from transport_retained_activity_test.
//
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
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

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

ActiveChat _chat(
  _RetainingGateway gateway, {
  StoredSessionMessageLoader? storedMessageLoader,
  Duration retainedActivityMaxAge = const Duration(minutes: 10),
  http.Client? httpClient,
  int transcriptPageSizeForTesting = 500,
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
  api: testApiClient(
    baseUrl: 'http://127.0.0.1:1',
    httpClient:
        httpClient ?? MockClient((_) async => http.Response('not found', 404)),
  ),
  transcriptPageSizeForTesting: transcriptPageSizeForTesting,
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

const _n = 8;

class _HistoryGateway extends _RetainingGateway
    implements HermesDesktopSessionHistoryGateway {
  List<Map<String, dynamic>> history = const [];
  int historyCalls = 0;
  int failHistory = 0;
  Completer<void>? historyGate;

  @override
  Future<SessionMessagesPage> sessionHistory({
    required String sessionId,
    String? profile,
  }) async {
    historyCalls += 1;
    await historyGate?.future;
    if (failHistory > 0) {
      failHistory -= 1;
      throw StateError('session.history cut');
    }
    return SessionMessagesPage(messages: history, pagination: null);
  }
}

List<DesktopSubagentSnapshot> _listed(Iterable<int> ids) => [
  for (final i in ids)
    DesktopSubagentSnapshot(
      subagentId: 'child-$i',
      delegationId: 'deleg-$i',
      status: 'running',
    ),
];

List<Map<String, dynamic>> _closures() => [
  {'role': 'user', 'content': 'delegar', 'message_id': 'u-1'},
  for (var i = 1; i <= _n; i++) ...[
    {
      'role': 'tool',
      'tool_name': 'delegate_task',
      'tool_call_id': 'call-$i',
      'content':
          '{"status":"dispatched","delegation_id":"deleg-$i","subagent_ids":["child-$i"]}',
    },
    {
      'role': 'user',
      'message_id': 'u-done-$i',
      'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg-$i]',
      'display_kind': 'async_delegation_complete',
      'timestamp':
          DateTime.utc(2026, 11, 15, 10, 5).millisecondsSinceEpoch / 1000,
      'display_metadata': {
        'delegation_id': 'deleg-$i',
        'task_count': 1,
        'completed_count': 1,
        'failed_count': 0,
      },
    },
  ],
  {'role': 'user', 'content': 'sigue', 'message_id': 'u-next'},
];

const _noClosure = [
  {'role': 'user', 'content': 'delegar', 'message_id': 'u-1'},
];

late SubagentPresentationOwnerToken _token;

/// Eight live children, shown by the UI (as the chat reads the roster).
Future<ActiveChat> _eightShown(_HistoryGateway g) async {
  g.subagents = _listed([for (var i = 1; i <= _n; i++) i]);
  final chat = await _boundWithLiveWork(g);
  _token = chat.acquireSubagentForegroundPresentation();
  for (var i = 1; i <= _n; i++) {
    g.emit('subagent.start', {
      'subagent_id': 'child-$i',
      'delegation_id': 'deleg-$i',
      'status': 'running',
      'event_id': 'e$i',
      'event_revision': 1,
    });
  }
  await Future<void>.delayed(Duration.zero);
  await chat.refreshSubagentsForTesting();
  expect(chat.conversationSubagents, hasLength(_n));
  return chat;
}

/// The phone comes back: the socket was cut, Hermes resumes with [runtime].
Future<void> _comeBack(
  _HistoryGateway g,
  ActiveChat chat, {
  String runtime = 'runtime-rotated',
}) async {
  g.liveRuntimeId = runtime;
  g.subagents = const [];
  g.drop();
  await _waitUntil(() => chat.desktopRuntimeSessionId == runtime);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, SubagentActivityPhase> _phases(ActiveChat chat) => {
  for (final a in chat.conversationSubagents) a.subagentId!: a.phase,
};

int _completed(ActiveChat chat) => chat.conversationSubagents
    .where((a) => a.phase == SubagentActivityPhase.completed)
    .length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('durable subagent repair', () {
    test('a history slower than two roster polls still settles all eight; '
        'exactly one read', () async {
      final g = _HistoryGateway()..history = _closures();
      final chat = await _eightShown(g);
      addTearDown(chat.dispose);
      final gate = g.historyGate = Completer<void>();
      await _comeBack(g, chat);
      await _waitUntil(() => g.historyCalls >= 1);
      await chat.refreshSubagentsForTesting(); // poll 1 during the read
      await chat.refreshSubagentsForTesting(); // poll 2 during the read
      g.historyGate = null;
      gate.complete();
      await _settle();
      expect(_completed(chat), _n);
      expect(chat.conversationSubagents, hasLength(_n));
      expect(g.historyCalls, 1);
      expect(chat.safeActiveSubagentCount, 0);
    });

    test('a child listed live again before the result applies stays live; '
        'the others settle', () async {
      final g = _HistoryGateway()..history = _closures();
      final chat = await _eightShown(g);
      addTearDown(chat.dispose);
      final gate = g.historyGate = Completer<void>();
      await _comeBack(g, chat);
      await _waitUntil(() => g.historyCalls >= 1);
      g.subagents = _listed([1]);
      await chat.refreshSubagentsForTesting(); // names child-1 live
      g.historyGate = null;
      gate.complete();
      await _settle();
      final phases = _phases(chat);
      expect(phases['child-1'], SubagentActivityPhase.running);
      expect(
        phases.values.where((p) => p == SubagentActivityPhase.completed),
        hasLength(_n - 1),
      );
      expect(g.historyCalls, 1);
    });

    test(
      'a late list naming a child after its closure was accepted keeps it '
      'completed: no revival, no duplicate, safe count does not rise',
      () async {
        final g = _HistoryGateway()..history = _closures();
        final chat = await _eightShown(g);
        addTearDown(chat.dispose);
        final gate = g.historyGate = Completer<void>();
        await _comeBack(g, chat);
        await _waitUntil(() => g.historyCalls >= 1);
        final listGate = g.subagentListGate = Completer<void>();
        final staleRead = chat.refreshSubagentsForTesting(); // in flight
        await Future<void>.delayed(Duration.zero);
        g.historyGate = null;
        gate.complete();
        await _settle();
        expect(_completed(chat), _n);
        g.subagents = _listed([1]);
        g.subagentListGate = null;
        listGate.complete();
        await staleRead;
        await _settle();
        expect(_phases(chat)['child-1'], SubagentActivityPhase.completed);
        expect(chat.conversationSubagents, hasLength(_n));
        expect(chat.safeActiveSubagentCount, 0);
        expect(g.historyCalls, 1);
      },
    );

    test('a new binding of the same runtime id (park and resume) discards the '
        'read in flight; the new binding reads once: two reads', () async {
      final g = _HistoryGateway()..history = _closures();
      final chat = await _eightShown(g);
      addTearDown(chat.dispose);
      final gate = g.historyGate = Completer<void>();
      await _comeBack(g, chat);
      await _waitUntil(() => g.historyCalls >= 1);
      g.reaped = true;
      g.drop();
      await _waitUntil(() => chat.desktopRuntimeSessionId == null);
      g.reaped = false;
      await chat.ensureDesktopRuntime(acquireForExplicitAction: true);
      await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-rotated');
      expect(_completed(chat), 0, reason: 'nothing applied yet');
      g.historyGate = null;
      gate.complete(); // the old binding's read returns: discarded
      await _settle();
      await chat.refreshSubagentsForTesting();
      await _settle();
      expect(g.historyCalls, 2);
      expect(_completed(chat), _n);
    });

    test('a read of the previous runtime that returns after rotating is '
        'discarded; the new runtime reads once', () async {
      final g = _HistoryGateway()..history = _closures();
      final chat = await _eightShown(g);
      addTearDown(chat.dispose);
      final gate = g.historyGate = Completer<void>();
      await _comeBack(g, chat);
      await _waitUntil(() => g.historyCalls >= 1);
      await _comeBack(g, chat, runtime: 'runtime-third');
      g.historyGate = null;
      gate.complete();
      await _settle();
      await chat.refreshSubagentsForTesting();
      await _settle();
      expect(g.historyCalls, 2);
      expect(_completed(chat), _n);
    });

    test('losing the UI lease during the read keeps the evidence private; on '
        'return the rows are completed; one read; Stop unchanged', () async {
      final g = _HistoryGateway()..history = _closures();
      final chat = await _eightShown(g);
      addTearDown(chat.dispose);
      final gate = g.historyGate = Completer<void>();
      await _comeBack(g, chat);
      await _waitUntil(() => g.historyCalls >= 1);
      final stopBefore = chat.canStopSessionWork;
      final safeBefore = chat.safeActiveSubagentCount;
      chat.releaseSubagentForegroundPresentation(_token);
      g.historyGate = null;
      gate.complete();
      await _settle();
      expect(chat.canStopSessionWork, stopBefore);
      expect(chat.safeActiveSubagentCount, safeBefore);
      _token = chat.acquireSubagentForegroundPresentation();
      expect(_completed(chat), _n);
      expect(g.historyCalls, 1);
    });

    test('a failed read is retried once on the next fenced list: two reads, '
        'settled', () async {
      final g = _HistoryGateway()
        ..history = _closures()
        ..failHistory = 1;
      final chat = await _eightShown(g);
      addTearDown(chat.dispose);
      await _comeBack(g, chat);
      await _waitUntil(() => g.historyCalls >= 1);
      await _settle();
      for (var i = 0; i < 3; i++) {
        await chat.refreshSubagentsForTesting();
        await _settle();
      }
      expect(g.historyCalls, 2);
      expect(_completed(chat), _n);
    });

    test('two failed reads: two reads and nothing settled', () async {
      final g = _HistoryGateway()
        ..history = _closures()
        ..failHistory = 2;
      final chat = await _eightShown(g);
      addTearDown(chat.dispose);
      await _comeBack(g, chat);
      await _waitUntil(() => g.historyCalls >= 1);
      await _settle();
      for (var i = 0; i < 4; i++) {
        await chat.refreshSubagentsForTesting();
        await _settle();
      }
      expect(g.historyCalls, 2);
      expect(_completed(chat), 0);
    });

    test(
      'a read without evidence is not repeated by polls: one read',
      () async {
        final g = _HistoryGateway()..history = _noClosure;
        final chat = await _eightShown(g);
        addTearDown(chat.dispose);
        await _comeBack(g, chat);
        await _waitUntil(() => g.historyCalls >= 1);
        await _settle();
        for (var i = 0; i < 4; i++) {
          await chat.refreshSubagentsForTesting();
          await _settle();
        }
        expect(g.historyCalls, 1);
        expect(_completed(chat), 0);
      },
    );
  });
}
