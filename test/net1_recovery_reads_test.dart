import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _DroppingDesktopGateway implements HermesDesktopGateway {
  _DroppingDesktopGateway({this.canonicalStoredId});

  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final String? canonicalStoredId;
  bool _connected = false;
  int connectCalls = 0;
  int resumeCalls = 0;
  int submitCalls = 0;
  int interruptCalls = 0;
  int hangingInterruptsRemaining = 0;
  int interruptErrorsRemaining = 0;
  Object? interruptError;
  Object? resumeSessionError;
  final List<String> interruptedRuntimeIds = [];
  final List<String> submittedRuntimeIds = [];
  final List<String> resumedStoredIds = [];

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    connectCalls++;
    _connected = true;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    if (resumeSessionError case final error?) throw error;
    resumeCalls++;
    resumedStoredIds.add(storedSessionId);
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-$resumeCalls',
      storedSessionId: canonicalStoredId ?? storedSessionId,
      created: false,
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submitCalls++;
    submittedRuntimeIds.add(runtimeSessionId);
  }

  void drop() {
    _connected = false;
    _events.addError(StateError('socket dropped'));
  }

  void failWith(Object error) {
    _connected = false;
    _events.addError(error);
  }

  /// The event stream reports a loss while the socket itself stays open
  /// (e.g. the silent-fanout watchdog): `connect()` is then a no-op.
  void loseStreamKeepingSocket() {
    _events.addError(
      const TuiGatewayRpcError(
        'gateway.transport',
        'Hermes Desktop connection lost',
        failureKind: TuiGatewayRpcFailureKind.connectionLost,
      ),
    );
  }

  void emit(
    String type, {
    String? sessionId,
    Map<String, dynamic> payload = const {},
  }) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: sessionId ?? 'runtime-$resumeCalls',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    _connected = false;
    await _events.close();
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interruptCalls++;
    interruptedRuntimeIds.add(runtimeSessionId);
    if (hangingInterruptsRemaining > 0) {
      hangingInterruptsRemaining--;
      await Completer<void>().future;
    }
    if (interruptErrorsRemaining > 0) {
      interruptErrorsRemaining--;
      throw interruptError ?? StateError('interrupt failed');
    }
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}
}

class _NonIdempotentLifecycleGateway extends _DroppingDesktopGateway
    implements
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopRosterBoundRecoveryGateway,
        HermesDesktopTypedRecoveryGateway {
  _NonIdempotentLifecycleGateway(String storedSessionId)
    : super(canonicalStoredId: storedSessionId);

  final ReplayCoordinator _recovery = ReplayCoordinator();
  final Object _recoveryChannel = Object();
  int createForFirstSubmitCalls = 0;
  int resumeExistingCalls = 0;
  int rosterResumeCalls = 0;
  int recoveryCommits = 0;
  int restoredFailuresRemaining = 0;
  bool networkAvailable = true;
  DesktopSessionSnapshot? recoverySnapshot;
  final List<String> resumeExistingStoredIds = [];

  @override
  Future<void> connect() async {
    await super.connect();
    if (connectCalls <= 1) return;
    if (!networkAvailable || restoredFailuresRemaining > 0) {
      if (networkAvailable) restoredFailuresRemaining -= 1;
      _connected = false;
      throw const DashboardWebSocketAuthException(
        DashboardWebSocketAuthFailureCode.unavailable,
        cause: DashboardWebSocketAuthFailureCause.transport,
      );
    }
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    createForFirstSubmitCalls += 1;
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-initial-$canonicalStoredId',
      storedSessionId: canonicalStoredId!,
      created: true,
    );
  }

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) => resumeExistingForRecovery(storedSessionId, profile: profile);

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    resumeExistingCalls += 1;
    resumeExistingStoredIds.add(storedSessionId);
    return recoverySnapshot ??
        DesktopSessionBinding(
          runtimeSessionId: 'runtime-recovered-$resumeExistingCalls',
          storedSessionId: storedSessionId,
          created: false,
        );
  }

  @override
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    rosterResumeCalls += 1;
    final snapshot = recoverySnapshot;
    if (snapshot == null || !snapshot.running) {
      throw const TuiGatewayRpcError(
        'session.active_list',
        'test roster has no active owner',
      );
    }
    resumeExistingCalls += 1;
    resumeExistingStoredIds.add(storedSessionId);
    return DesktopRosterBoundRecovery.forTesting(snapshot, this);
  }

  @override
  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery) {
    recoveryCommits += 1;
    return true;
  }

  @override
  bool consumeRosterBoundViewerAttachment(
    DesktopRosterBoundRecovery recovery,
  ) => false;

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
      coverage: coverage,
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
  bool commitRecovery(RecoveryProof proof) {
    final committed = _recovery.commitRecovery(
      proof,
      socketGeneration: 1,
      channel: _recoveryChannel,
      replayEpoch: null,
    );
    if (committed) recoveryCommits += 1;
    return committed;
  }

  @override
  bool recoveryAuthorityStillCurrent(RecoveryProof proof) =>
      _recovery.isRecoveryAuthorityCurrent(
        proof,
        socketGeneration: 1,
        channel: _recoveryChannel,
        replayEpoch: null,
      );

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {}
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
);

// N6b: one `GET …/messages` per recovery generation. A cut with a turn in
// flight is recovered through the durable transcript; the recovery loop, the
// ms1215 ownership proof, `sessions.changed` and the foreground
// reconciliation used to read it independently.

ActiveChat _attachRecovering(
  ActiveChatService service,
  String id,
  _NonIdempotentLifecycleGateway gateway,
  StoredSessionMessageLoader loader,
) => service.attach(
  connection: _connection(id),
  sessionId: 'session-$id',
  sessionTitle: id,
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:1',
    apiKey: 'k',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  ),
  desktopGateway: gateway,
  allowUnownedDesktopSnapshotForTesting: true,
  attachDesktopRuntimeOnLoad: false,
  storedMessageLoader: loader,
  disableForegroundKeepAlive: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(
    () => GatewayReconnectBackoff.debugBaseOverride = const Duration(
      milliseconds: 20,
    ),
  );
  tearDownAll(() => GatewayReconnectBackoff.debugBaseOverride = null);

  const prompt = 'haz los cuatro pasos';
  const answer = 'pasos 1 a 4 hechos';

  test('N6b a cut with a turn in flight reads the transcript at most twice and '
      'sessions.changed right after converging reads nothing', () async {
    SharedPreferences.setMockInitialValues({});
    const id = 'n6b-reads';
    const storedId = 'stored-n6b-reads';
    final gateway = _NonIdempotentLifecycleGateway(storedId);
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    var reads = 0;
    final chat = _attachRecovering(service, id, gateway, (_, _) async {
      reads++;
      return [
        const {'id': 101, 'role': 'user', 'content': prompt},
        if (reads >= 2)
          const {'id': 102, 'role': 'assistant', 'content': answer},
      ];
    });
    await chat.send(fullText: prompt, model: 'hermes-agent', history: const []);
    reads = 0;
    gateway.recoverySnapshot = DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-n6b-reads',
      storedSessionId: storedId,
      created: false,
      messagesProvided: false,
      running: false,
      status: 'idle',
    );
    // The server finishes while the phone is cut: the first read (before
    // the reconnect) still sees the open turn, the second one the answer.
    gateway.failWith(const SocketException('Connection reset by peer'));
    await _waitUntil(
      () =>
          chat.state == ChatPipelineState.completed &&
          chat.transportStatus.isConnected,
      timeout: const Duration(seconds: 5),
    );
    final recoveryReads = reads;
    expect(recoveryReads, lessThanOrEqualTo(2));
    // The viewer reloads the converged chat once (not part of the count).
    await chat.loadMessages();
    reads = 0;
    // sessions.changed ×3 (Desktop's broadcast after the turn persisted).
    for (var i = 0; i < 3; i++) {
      await service.invalidateDurableSession(
        connectionId: id,
        profile: '',
        sessionId: storedId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(chat.messages.where((m) => m['content'] == answer), hasLength(1));
    expect(
      recoveryReads + reads,
      lessThanOrEqualTo(2),
      reason: 'GET /messages per recovery (recovery + invalidations)',
    );
  }, timeout: const Timeout(Duration(seconds: 20)));

  test(
    'N6b regression: a running snapshot still binds the owned inflight with at most two reads',
    () async {
      SharedPreferences.setMockInitialValues({});
      const id = 'n6b-owned';
      const storedId = 'stored-n6b-owned';
      final gateway = _NonIdempotentLifecycleGateway(storedId);
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(service.dispose);
      var reads = 0;
      final chat = _attachRecovering(service, id, gateway, (_, _) async {
        reads++;
        return const [
          {'id': 101, 'role': 'user', 'content': prompt},
        ];
      });
      await chat.loadMessages();
      await chat.send(
        fullText: prompt,
        model: 'hermes-agent',
        history: const [],
      );
      final live = chat.desktopRuntimeSessionId!;
      gateway
        ..emit('message.start', sessionId: live)
        ..emit(
          'message.delta',
          sessionId: live,
          payload: const {'text': 'paso 1'},
        );
      await _waitUntil(
        () => chat.messages.any((m) => m['content'] == 'paso 1'),
      );
      reads = 0;
      // Idle snapshot that carries a complete (but unproven) transcript: the
      // idle read and the ownership proof judge the same snapshot.
      gateway.recoverySnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-n6b-owned',
        storedSessionId: storedId,
        created: false,
        messagesProvided: true,
        running: true,
        inflight: DesktopInflightTurn(
          user: prompt,
          assistant: 'paso 1 y 2',
          streaming: true,
        ),
        status: 'working',
      );
      gateway.failWith(const SocketException('Connection reset by peer'));
      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-n6b-owned',
        timeout: const Duration(seconds: 5),
      );
      expect(reads, lessThanOrEqualTo(2));
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test('N6b concurrent recovery readers share one read and a failure is not '
      'kept', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _NonIdempotentLifecycleGateway('stored-n6b-shared');
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    var reads = 0;
    final gate = Completer<void>();
    var failNext = false;
    final chat = _attachRecovering(service, 'n6b-shared', gateway, (
      _,
      _,
    ) async {
      reads++;
      await gate.future;
      if (failNext) {
        failNext = false;
        throw StateError('read failed');
      }
      return const [
        {'id': 1, 'role': 'user', 'content': prompt},
      ];
    });
    final a = chat.loadRecoveryTranscriptSharedForTesting('s', '');
    final b = chat.loadRecoveryTranscriptSharedForTesting('s', '');
    gate.complete();
    await Future.wait([a, b]);
    expect(reads, 1, reason: 'two concurrent readers, one GET');
    await chat.loadRecoveryTranscriptSharedForTesting('s', '');
    expect(reads, 1, reason: 'a settled read is reusable for a few seconds');
    await chat.loadRecoveryTranscriptSharedForTesting('other', '');
    expect(reads, 2, reason: 'another session never reuses it');
    failNext = true;
    await expectLater(
      chat.loadRecoveryTranscriptSharedForTesting('bad', ''),
      throwsStateError,
    );
    await chat.loadRecoveryTranscriptSharedForTesting('bad', '');
    expect(reads, 4, reason: 'a failed read is never kept');
  });

  test('N6b the foreground reconciliation resumes the visible chat first, then '
      'chats with a turn, two at a time', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    final order = <String>[];
    var live = 0;
    var maxLive = 0;
    final gates = <String, Completer<void>>{};
    ActiveChat make(String name) {
      final gateway = _NonIdempotentLifecycleGateway('stored-$name');
      var calls = 0;
      return _attachRecovering(service, name, gateway, (_, _) async {
        calls++;
        if (calls == 1) {
          return [
            {'id': 1, 'role': 'user', 'content': name},
          ];
        }
        order.add(name);
        live++;
        if (live > maxLive) maxLive = live;
        final gate = gates[name] = Completer<void>();
        await gate.future;
        live--;
        return [
          {'id': 1, 'role': 'user', 'content': name},
          {'id': 2, 'role': 'assistant', 'content': 'new-$name'},
        ];
      });
    }

    final first = make('c-first');
    final second = make('c-second');
    final third = make('c-visible');
    for (final chat in [first, second, third]) {
      await chat.loadMessages();
      chat.state = ChatPipelineState.completed;
    }
    final sub = third.changes.listen((_) {});
    addTearDown(sub.cancel);

    final resume = service.reconcileAfterResume();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(order.first, 'c-visible');
    expect(order, hasLength(2), reason: 'two at a time');
    gates['c-visible']!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(order, hasLength(3));
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await resume;
    expect(maxLive, 2);
    expect(order.toSet(), {'c-first', 'c-second', 'c-visible'});
  }, timeout: const Timeout(Duration(seconds: 20)));
}
