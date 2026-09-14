import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_fence_storage.dart';

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
  _RecoveryGateway(
    this.status, {
    this.statusGate,
    this.statusStarted,
    this.runtimeSessionIds = const ['runtime'],
  });

  DesktopTurnStatus status;
  final Future<DesktopTurnStatus>? statusGate;
  final Completer<void>? statusStarted;
  final List<String> runtimeSessionIds;
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
    if (statusStarted?.isCompleted == false) statusStarted!.complete();
    return await statusGate ?? status;
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
      compressionFenceStore: testCompressionFenceStore(),
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

Future<List<PreparedTurn>> _loadQueue() =>
    TurnOutboxStore().loadAllForChat('conn', 'session', profile: 'default');

Iterable<String> _queuedIds(ActiveChat chat) =>
    chat.queuedTurns.map((item) => item.turn.clientTurnId);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};

  setUp(() {
    secure.clear();
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
              case 'read':
                return secure[args['key'] as String];
              case 'delete':
                secure.remove(args['key'] as String);
              case 'readAll':
                return Map<String, String>.from(secure);
            }
            return null;
          },
        );
  });

  test('orden durable gana al timestamp empatado y al UUID', () async {
    final first = _queued('z-first', state: PreparedTurnState.prepared);
    final second = _queued('a-second', state: PreparedTurnState.prepared);
    final firstJson = first.toJson()..['queue_order'] = 41;
    final secondJson = second.toJson()..['queue_order'] = 42;
    secure['chat_turn_outbox_v1'] = jsonEncode({
      first.storageId: firstJson,
      second.storageId: secondJson,
    });

    final restored = await _loadQueue();

    expect(restored.map((turn) => turn.clientTurnId), ['z-first', 'a-second']);
  });

  test('orden duplicado se conserva pero bloquea ambos turnos', () async {
    final first = _queued('first', state: PreparedTurnState.prepared);
    final second = _queued('second', state: PreparedTurnState.prepared);
    final firstJson = first.toJson()..['queue_order'] = 7;
    final secondJson = second.toJson()..['queue_order'] = 7;
    secure['chat_turn_outbox_v1'] = jsonEncode({
      first.storageId: firstJson,
      second.storageId: secondJson,
    });

    final restored = await _loadQueue();

    expect(restored, hasLength(2));
    expect(
      restored.every((turn) => turn.state == PreparedTurnState.ambiguous),
      isTrue,
    );
  });

  test('orden negativo es corrupción y falla cerrado', () async {
    final malformed = _queued('negative', state: PreparedTurnState.prepared);
    final malformedJson = malformed.toJson()..['queue_order'] = -1;
    secure['chat_turn_outbox_v1'] = jsonEncode({
      malformed.storageId: malformedJson,
    });

    await expectLater(_loadQueue(), throwsA(isA<StateError>()));
  });

  test('recreación continúa el contador durable sin colisiones', () async {
    final store = _MemoryOutbox();
    final restored = _queued(
      'restored',
      state: PreparedTurnState.prepared,
    ).copyWith(queueOrder: 41);
    await store.save(restored);
    final chat = _chat();
    addTearDown(chat.dispose);
    await chat.restoreQueuedTurns([restored], store, scheduleDrain: false);

    final admitted = _queued('new', state: PreparedTurnState.prepared);
    expect(
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(prepared: admitted, store: store),
      ),
      isTrue,
    );

    expect(
      store.rows.values
          .singleWhere((turn) => turn.clientTurnId == 'new')
          .queueOrder,
      42,
    );
  });

  test('TTL nunca elimina una cabeza incierta', () async {
    final old = DateTime.now()
        .subtract(const Duration(days: 31))
        .millisecondsSinceEpoch;
    final head = _queued(
      'uncertain-old',
      state: PreparedTurnState.ambiguous,
      createdAtMs: old,
    );
    await TurnOutboxStore().save(head);

    final restored = await _loadQueue();

    expect(restored.single.clientTurnId, 'uncertain-old');
    expect(restored.single.state, PreparedTurnState.ambiguous);
  });

  test(
    'registro queued legacy sin orden explícito se vuelve incierto',
    () async {
      final legacy = _queued('legacy', state: PreparedTurnState.prepared);
      secure['chat_turn_outbox_v1'] = jsonEncode({
        legacy.storageId: legacy.toJson(),
      });

      final restored = await _loadQueue();

      expect(restored.single.clientTurnId, 'legacy');
      expect(restored.single.state, PreparedTurnState.ambiguous);
    },
  );

  testWidgets(
    'reconciliación pendiente suspende el drain de admisiones concurrentes',
    (tester) async {
      final statusStarted = Completer<void>();
      final statusGate = Completer<DesktopTurnStatus>();
      final gateway = _RecoveryGateway(
        const DesktopTurnStatus(known: false, clientTurnId: 'A'),
        statusGate: statusGate.future,
        statusStarted: statusStarted,
      );
      final chat = _chat(gateway: gateway);
      addTearDown(chat.dispose);
      final store = _MemoryOutbox();
      final head = _ordered('A', PreparedTurnState.ambiguous, 10);

      final restoration = chat.restoreQueuedTurns([head], store);
      await statusStarted.future;
      final follower = _queued('B', state: PreparedTurnState.prepared);
      expect(
        await chat.enqueuePreparedTurn(
          ActiveTurnDelivery(prepared: follower, store: store),
        ),
        isTrue,
      );
      await tester.pump();

      expect(gateway.submitted, isEmpty);
      statusGate.complete(
        const DesktopTurnStatus(known: false, clientTurnId: 'A'),
      );
      await restoration;
      await tester.pump(const Duration(milliseconds: 1));
      expect(_queuedIds(chat), ['A', 'B']);
    },
  );

  test(
    'dos restores solapados se serializan hasta terminar el primero',
    () async {
      final statusStarted = Completer<void>();
      final statusGate = Completer<DesktopTurnStatus>();
      final gateway = _RecoveryGateway(
        const DesktopTurnStatus(known: false, clientTurnId: 'A'),
        statusGate: statusGate.future,
        statusStarted: statusStarted,
      );
      final chat = _chat(gateway: gateway);
      addTearDown(chat.dispose);
      final store = _MemoryOutbox();
      final first = chat.restoreQueuedTurns(
        [_ordered('A', PreparedTurnState.ambiguous, 10)],
        store,
        scheduleDrain: false,
      );
      await statusStarted.future;

      var secondCompleted = false;
      final second = chat
          .restoreQueuedTurns(
            [_ordered('B', PreparedTurnState.prepared, 11)],
            store,
            scheduleDrain: false,
          )
          .whenComplete(() => secondCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(secondCompleted, isFalse);
      expect(_queuedIds(chat), isEmpty);
      statusGate.complete(
        const DesktopTurnStatus(known: false, clientTurnId: 'A'),
      );
      await Future.wait([first, second]);
      expect(_queuedIds(chat), ['A', 'B']);
    },
  );

  testWidgets(
    'dispose durante settlement no deja que callback tardío borre la cabeza',
    (tester) async {
      final statusStarted = Completer<void>();
      final statusGate = Completer<DesktopTurnStatus>();
      final gateway = _RecoveryGateway(
        const DesktopTurnStatus(known: false, clientTurnId: 'A'),
        statusGate: statusGate.future,
        statusStarted: statusStarted,
      );
      final chat = _chat(gateway: gateway);
      final store = _MemoryOutbox();
      final head = _ordered('A', PreparedTurnState.ambiguous, 10);
      await store.save(head);

      final restoration = chat.restoreQueuedTurns([head], store);
      await statusStarted.future;
      chat.dispose();
      statusGate.complete(
        const DesktopTurnStatus(
          known: true,
          clientTurnId: 'A',
          serverTurnId: 'server-A',
          state: DesktopTurnState.terminal,
        ),
      );
      await restoration;

      expect(store.rows.values.single.clientTurnId, 'A');
      expect(store.rows.values.single.state, PreparedTurnState.ambiguous);
    },
  );

  test(
    'reconcile sin callback falla cerrado si dispose vence al status',
    () async {
      final statusStarted = Completer<void>();
      final statusGate = Completer<DesktopTurnStatus>();
      final gateway = _RecoveryGateway(
        const DesktopTurnStatus(known: false, clientTurnId: 'A'),
        statusGate: statusGate.future,
        statusStarted: statusStarted,
      );
      final chat = _chat(gateway: gateway);
      final store = _MemoryOutbox();
      final head = _ordered('A', PreparedTurnState.ambiguous, 10);
      await store.save(head);

      final reconciliation = chat.reconcileAmbiguousTurn(head, store);
      await statusStarted.future;
      chat.dispose();
      statusGate.complete(
        const DesktopTurnStatus(
          known: true,
          clientTurnId: 'A',
          serverTurnId: 'server-A',
          state: DesktopTurnState.terminal,
        ),
      );

      expect(await reconciliation, same(head));
      expect(store.rows.values.single, same(head));
    },
  );

  test(
    'bind nuevo durante status no puede ser sobrescrito por runtime viejo',
    () async {
      final statusStarted = Completer<void>();
      final statusGate = Completer<DesktopTurnStatus>();
      final gateway = _RecoveryGateway(
        const DesktopTurnStatus(known: false, clientTurnId: 'A'),
        statusGate: statusGate.future,
        statusStarted: statusStarted,
        runtimeSessionIds: const ['runtime-old', 'runtime-new'],
      );
      final chat = _chat(gateway: gateway);
      addTearDown(chat.dispose);
      final store = _MemoryOutbox();
      final head = _ordered('A', PreparedTurnState.ambiguous, 10);

      final reconciliation = chat.reconcileAmbiguousTurn(head, store);
      await statusStarted.future;
      expect(
        await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isTrue,
      );
      expect(chat.desktopRuntimeSessionId, 'runtime-new');
      statusGate.complete(
        const DesktopTurnStatus(
          known: true,
          clientTurnId: 'A',
          serverTurnId: 'server-A',
          state: DesktopTurnState.running,
        ),
      );

      expect(await reconciliation, same(head));
      expect(chat.desktopRuntimeSessionId, 'runtime-new');
      expect(chat.activeTurnDelivery, isNull);
    },
  );

  for (final uncertainState in <PreparedTurnState>[
    PreparedTurnState.submitting,
    PreparedTurnState.ambiguous,
    PreparedTurnState.accepted,
    PreparedTurnState.running,
  ]) {
    testWidgets(
      'known false conserva A $uncertainState y bloquea B sin submit ni REST',
      (tester) async {
        var restRequests = 0;
        final gateway = _RecoveryGateway(
          const DesktopTurnStatus(known: false, clientTurnId: 'A'),
        );
        final chat = _chat(
          gateway: gateway,
          httpClient: MockClient((_) async {
            restRequests++;
            return http.Response('{"run_id":"forbidden"}', 200);
          }),
        );
        addTearDown(chat.dispose);
        final store = _MemoryOutbox();
        final head = _ordered('A', uncertainState, 10);
        final follower = _ordered('B', PreparedTurnState.prepared, 11);

        await chat.restoreQueuedTurns(
          [follower, head],
          store,
          scheduleDrain: false,
        );

        if (uncertainState == PreparedTurnState.submitting) {
          expect(gateway.statusRequests, isEmpty);
        } else {
          expect(gateway.statusRequests, ['A']);
        }
        expect(_queuedIds(chat), ['A', 'B']);
        expect(gateway.submitted, isEmpty);
        expect(restRequests, 0);
      },
    );
  }
  testWidgets(
    'settlement terminal posterior retira el owner bloqueado exacto',
    (tester) async {
      final gateway = _RecoveryGateway(
        const DesktopTurnStatus(
          known: true,
          clientTurnId: 'otra-cabeza',
          serverTurnId: 'server-otra',
          state: DesktopTurnState.terminal,
        ),
      );
      final chat = _chat(gateway: gateway);
      addTearDown(chat.dispose);
      final store = _MemoryOutbox();
      final head = _ordered('A', PreparedTurnState.ambiguous, 10);
      final follower = _ordered('B', PreparedTurnState.prepared, 11);
      await store.save(head);
      await store.save(follower);
      await chat.restoreQueuedTurns(
        [head, follower],
        store,
        scheduleDrain: false,
      );
      expect(_queuedIds(chat), ['A', 'B']);

      gateway.status = const DesktopTurnStatus(
        known: true,
        clientTurnId: 'A',
        serverTurnId: 'server-A',
        state: DesktopTurnState.terminal,
      );
      await chat.restoreQueuedTurns([head], store, scheduleDrain: false);

      expect(_queuedIds(chat), ['B']);
      expect(
        store.rows.values.any((turn) => turn.clientTurnId == 'A'),
        isFalse,
      );
      expect(gateway.submitted, isEmpty);
    },
  );

  testWidgets('adjunto ausente bloquea el drain text-only', (tester) async {
    final gateway = _RecoveryGateway(
      const DesktopTurnStatus(known: false, clientTurnId: 'A'),
    );
    final chat = _chat(gateway: gateway);
    addTearDown(chat.dispose);
    final store = _MemoryOutbox();
    final head = _ordered('A', PreparedTurnState.ambiguous, 0);
    final blocked =
        _queued(
          'attachment-blocked',
          state: PreparedTurnState.prepared,
        ).copyWith(
          queueOrder: 1,
          attachments: const [
            AttachmentDraft(
              localId: 'missing',
              type: AttachmentType.document,
              name: 'missing.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 1,
              localPath: '/missing.pdf',
              uploadState: AttachmentUploadState.error,
              errorKind: AttachmentErrorKind.missingFile,
            ),
          ],
        );

    await chat.restoreQueuedTurns([head, blocked], store, scheduleDrain: true);
    gateway.status = const DesktopTurnStatus(
      known: true,
      clientTurnId: 'A',
      serverTurnId: 'server-A',
      state: DesktopTurnState.terminal,
    );
    await chat.restoreQueuedTurns([head], store, scheduleDrain: true);
    await tester.pump(const Duration(milliseconds: 1));

    final queuedId = chat.queuedTurns.single.turn.clientTurnId;
    final pipelineState = chat.state;
    final submitted = List<String>.of(gateway.submitted);
    chat.dispose();
    expect(queuedId, 'attachment-blocked');
    expect(pipelineState, ChatPipelineState.idle);
    expect(submitted, isEmpty);
  });

  test('perfil omitido falla cerrado aunque solo haya una fila', () async {
    await TurnOutboxStore().save(
      _queued('profile-owned', state: PreparedTurnState.prepared),
    );

    await expectLater(
      TurnOutboxStore().loadAllForChat('conn', 'session'),
      throwsA(isA<StateError>()),
    );
  });
}
