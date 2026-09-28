import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _MemoryOutbox implements TurnOutboxPersistence {
  final Map<String, PreparedTurn> rows = {};
  @override
  Future<void> save(PreparedTurn turn) async => rows[turn.storageId] = turn;
  @override
  Future<void> delete(PreparedTurn turn) async => rows.remove(turn.storageId);
}

class _RecoveryGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopIdempotentGateway,
        HermesDesktopTypedRecoveryGateway {
  _RecoveryGateway(this.status);

  DesktopTurnStatus status;
  final List<String> runtimeSessionIds = const ['runtime'];
  final eventsController = StreamController<TuiGatewayEvent>.broadcast();
  final List<String> submitted = <String>[];
  final List<String> statusRequests = <String>[];
  final ReplayCoordinator _recovery = ReplayCoordinator();
  final Object _recoveryChannel = Object();
  int _resumeIndex = 0;
  @override
  Stream<TuiGatewayEvent> get events => eventsController.stream;
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
    runtimeSessionId: _nextRuntimeSessionId(),
    storedSessionId: storedSessionId,
    created: false,
  );
  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw StateError('recovery must not create');

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: _nextRuntimeSessionId(),
    storedSessionId: storedSessionId,
    created: false,
  );

  String _nextRuntimeSessionId() {
    final index = _resumeIndex++;
    return runtimeSessionIds[index.clamp(0, runtimeSessionIds.length - 1)];
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async {
    statusRequests.add(clientTurnId);
    return status;
  }

  @override
  RecoveryProof recoveryProofForSnapshot(
    DesktopSessionSnapshot snapshot, {
    required String connectionId,
    required String profile,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required Set<RecoveryDomain> coverage,
    int? postSnapshotSequence,
  }) {
    _recovery.quarantine(snapshot.runtimeSessionId);
    return _recovery.mintRecoveryProof(
      connectionId: connectionId,
      durableSessionId: snapshot.storedSessionId,
      runtimeSessionId: snapshot.runtimeSessionId,
      profile: profile,
      socketGeneration: 1,
      channel: _recoveryChannel,
      bindGeneration: bindGeneration,
      sessionGeneration: sessionGeneration,
      turnGeneration: turnGeneration,
      replayEpoch: null,
      created: snapshot.created,
      durableIdentityExplicit: snapshot.storedSessionIdentityExplicit,
      identityAliasesConsistent: snapshot.identityAliasesConsistent,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 1,
    );
  }

  @override
  bool validateRecovery(RecoveryProof proof) => _recovery.canCommitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool commitRecovery(RecoveryProof proof) => _recovery.commitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool recoveryAuthorityStillCurrent(RecoveryProof proof) =>
      _recovery.isRecoveryAuthorityCurrent(
        proof,
        socketGeneration: 1,
        channel: _recoveryChannel,
        replayEpoch: null,
      );

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    submitted.add(text);
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-$clientTurnId',
      state: DesktopTurnState.accepted,
      duplicate: false,
    );
  }

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
  Future<void> close() => eventsController.close();
}

PreparedTurn _queued(
  String id, {
  required PreparedTurnState state,
  int? createdAtMs,
}) {
  final admittedAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;
  return PreparedTurn(
    connectionId: 'conn',
    sessionId: 'session',
    clientTurnId: id,
    createdAtMs: admittedAtMs,
    updatedAtMs: admittedAtMs,
    text: id,
    attachments: const [],
    model: 'model',
    profile: 'default',
    state: state,
    queued: true,
  );
}

PreparedTurn _ordered(String id, PreparedTurnState state, int order) =>
    _queued(id, state: state).copyWith(queueOrder: order);
ActiveChat _chat({HermesDesktopGateway? gateway, http.Client? httpClient}) =>
    ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn',
        label: 'test',
        host: 'example.invalid',
        port: 443,
        apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
        useHttps: true,
      ),
      sessionId: 'session',
      sessionTitle: 'test',
      notifications: null,
      onTerminal: () {},
      api: ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: String.fromCharCodes(const [116, 101, 115, 116]),
        httpClient:
            httpClient ?? MockClient((_) async => http.Response('{}', 500)),
      ),
      desktopGateway: gateway,
      turnIdempotencyCapability: () async => true,
      storedMessageLoader: (_, _) async => const [],
      terminalReconcileBudget: Duration.zero,
    );

Iterable<String> _queuedIds(ActiveChat chat) =>
    chat.queuedTurns.map((item) => item.turn.clientTurnId);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(TurnOutboxStore.resetSerializationForTesting);

  for (final uncertainState in <PreparedTurnState>[
    PreparedTurnState.submitting,
    PreparedTurnState.ambiguous,
  ]) {
    testWidgets(
      'uncertain head ($uncertainState) is marked, and the user can let it go',
      (tester) async {
        final gateway = _RecoveryGateway(
          const DesktopTurnStatus(known: false, clientTurnId: 'A'),
        );
        final chat = _chat(gateway: gateway);
        addTearDown(chat.dispose);
        final store = _MemoryOutbox();
        final head = _ordered('A', uncertainState, 10);
        final follower = _ordered('B', PreparedTurnState.prepared, 11);
        await store.save(head);
        await store.save(follower);
        await chat.restoreQueuedTurns(
          [head, follower],
          store,
          scheduleDrain: false,
        );
        expect(_queuedIds(chat), ['A', 'B']);

        // The row says what is going on instead of a mute "retry".
        final a = chat.queuedEntries.singleWhere((e) => e.id == 'prepared:A');
        expect(a.deliveryUnknown, isTrue);
        final b = chat.queuedEntries.singleWhere((e) => e.id == 'prepared:B');
        expect(b.deliveryUnknown, isFalse);

        // Ordinary delete still refuses: it could lose a message that
        // arrived. Only the explicit "let it go" gesture retires it.
        expect(await chat.cancelQueuedByIdentity('prepared:A'), isFalse);
        expect(_queuedIds(chat), ['A', 'B']);

        expect(await chat.abandonUncertainQueuedTurn('prepared:A'), isTrue);
        expect(_queuedIds(chat), ['B']);
        expect(
          store.rows.values.map((t) => t.clientTurnId),
          isNot(contains('A')),
        );
        // Never resent: the server may already have it.
        expect(gateway.submitted, isNot(contains('A')));
      },
    );
  }

  testWidgets('an acknowledged row is not "unknown" and cannot be let go', (
    tester,
  ) async {
    final gateway = _RecoveryGateway(
      const DesktopTurnStatus(known: false, clientTurnId: 'A'),
    );
    final chat = _chat(gateway: gateway);
    addTearDown(chat.dispose);
    final store = _MemoryOutbox();
    final head = _ordered('A', PreparedTurnState.accepted, 10);
    await store.save(head);
    await chat.restoreQueuedTurns([head], store, scheduleDrain: false);
    expect(
      chat.queuedEntries
          .singleWhere((e) => e.id == 'prepared:A')
          .deliveryUnknown,
      isFalse,
    );
    expect(await chat.abandonUncertainQueuedTurn('prepared:A'), isFalse);
    expect(_queuedIds(chat), ['A']);
  });

  testWidgets('let-it-go refuses rows that are not uncertain', (tester) async {
    final gateway = _RecoveryGateway(
      const DesktopTurnStatus(known: false, clientTurnId: 'A'),
    );
    final chat = _chat(gateway: gateway);
    addTearDown(chat.dispose);
    final store = _MemoryOutbox();
    final prepared = _ordered('B', PreparedTurnState.prepared, 11);
    await store.save(prepared);
    await chat.restoreQueuedTurns([prepared], store, scheduleDrain: false);

    expect(await chat.abandonUncertainQueuedTurn('prepared:B'), isFalse);
    expect(await chat.abandonUncertainQueuedTurn('desktop-accepted'), isFalse);
    expect(await chat.abandonUncertainQueuedTurn('prepared:missing'), isFalse);
    expect(_queuedIds(chat), ['B']);
  });

  test('delivery refuses to retire a turn the server acknowledged', () async {
    final store = _MemoryOutbox();
    final accepted = _ordered('A', PreparedTurnState.accepted, 10);
    await store.save(accepted);
    final delivery = ActiveTurnDelivery(prepared: accepted, store: store);
    expect(await delivery.abandonUncertain(), isFalse);
    expect(store.rows.values.single.clientTurnId, 'A');

    final unknown = _ordered('B', PreparedTurnState.ambiguous, 11);
    await store.save(unknown);
    final open = ActiveTurnDelivery(prepared: unknown, store: store);
    expect(await open.abandonUncertain(), isTrue);
    expect(store.rows.values.map((t) => t.clientTurnId), ['A']);
  });
}
