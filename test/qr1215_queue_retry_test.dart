import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// A socket that can be taken down and brought back. While down every RPC
/// fails fast, exactly like `TuiGatewayClient` during its reconnect backoff.
class _FlakyGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionActivityGateway {
  final controller = StreamController<TuiGatewayEvent>.broadcast();
  final submissions = <String>[];
  final List<Completer<void>> heldActiveLists = [];
  bool down = false;
  int holdNextActiveLists = 0;
  int activeListCalls = 0;
  // xr1215: when set, only [connect] brings a dropped socket back, as with
  // a real `TuiGatewayClient`; [reachable] says whether the server answers.
  bool onlyConnectRestores = false;
  bool reachable = false;
  int connectCalls = 0;
  // xr1215: the rows `session.active_list` reports.
  List<DesktopActiveSession> activeSessions = const [];

  Never _lost() => throw const TuiGatewayRpcError(
    'gateway.connect',
    'Hermes Desktop reconnect is backing off',
    failureKind: TuiGatewayRpcFailureKind.connectionLost,
  );

  @override
  Stream<TuiGatewayEvent> get events => controller.stream;
  @override
  bool get isConnected => !down;
  @override
  Future<void> connect() async {
    connectCalls += 1;
    if (down && onlyConnectRestores && reachable) {
      down = false;
      return;
    }
    if (down) _lost();
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    if (down) _lost();
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-qr',
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionBinding> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) => resumeSession(storedSessionId, profile: profile);

  @override
  Future<DesktopSessionBinding> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => resumeSession('session-qr', profile: profile);

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    if (down) _lost();
    submissions.add(text);
  }

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async => throw StateError('not used');

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async {
    activeListCalls += 1;
    if (holdNextActiveLists > 0) {
      holdNextActiveLists -= 1;
      final gate = Completer<void>();
      heldActiveLists.add(gate);
      await gate.future;
    }
    if (down) _lost();
    return DesktopActiveSessionList(sessions: activeSessions);
  }

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
  Future<void> close() => controller.close();

  void dropSocket() {
    down = true;
    controller.addError(StateError('socket dropped'));
  }
}

class _MemoryOutbox implements TurnOutboxPersistence {
  @override
  Future<void> save(PreparedTurn turn) async {}
  @override
  Future<void> delete(PreparedTurn turn) async {}
}

ActiveChat _chat(String id, _FlakyGateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: id,
    label: 'Queue retry',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'test',
  ),
  sessionId: 'session-qr',
  sessionTitle: 'Queue retry',
  notifications: null,
  onTerminal: () {},
  desktopGateway: gateway,
  initialStoredSessionId: 'session-qr',
)..state = ChatPipelineState.idle;

PreparedTurn _prepared(String id, String text) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return PreparedTurn(
    connectionId: 'qr',
    sessionId: 'session-qr',
    clientTurnId: id,
    createdAtMs: now,
    updatedAtMs: now,
    text: text,
    fullText: text,
    desktopText: text,
    attachments: const [],
    model: 'hermes-agent',
    profile: '',
    queued: true,
  );
}

void main() {
  test('a queued head drained during a reconnect is sent once the socket '
      'is back instead of burning its retries', () {
    fakeAsync((async) {
      final gateway = _FlakyGateway();
      final chat = _chat('qr-reconnect', gateway);
      chat.send(fullText: 'turno vivo', model: 'hermes-agent', history: []);
      async.flushMicrotasks();
      expect(gateway.submissions, ['turno vivo']);
      chat.state = ChatPipelineState.completed;

      // The socket drops right as the queue head comes up.
      gateway.down = true;
      chat.enqueuePreparedTurn(
        ActiveTurnDelivery(
          prepared: _prepared('qr-head', 'seguimiento'),
          store: _MemoryOutbox(),
        ),
      );
      // Longer than the whole 400/800/1600 ms ladder.
      async.elapse(const Duration(seconds: 6));
      expect(gateway.submissions, ['turno vivo']);
      expect(chat.queuedMessages, ['seguimiento']);
      // Nothing was tried on a healthy socket: the entry is not "given up".
      expect(chat.queuedRetriesExhausted, isEmpty);

      gateway.down = false;
      async.elapse(const Duration(seconds: 20));
      expect(gateway.submissions, ['turno vivo', 'seguimiento']);
      expect(chat.queuedMessages, isEmpty);
      // No later trigger sends it a second time.
      async.elapse(const Duration(seconds: 30));
      expect(gateway.submissions, ['turno vivo', 'seguimiento']);

      chat.dispose();
      async.flushTimers();
    });
  });

  test('a queued text head drained during a reconnect is sent once the '
      'socket is back', () {
    fakeAsync((async) {
      final gateway = _FlakyGateway();
      final chat = _chat('qr-reconnect-text', gateway);
      chat.send(fullText: 'turno vivo', model: 'hermes-agent', history: []);
      async.flushMicrotasks();
      chat.state = ChatPipelineState.completed;

      gateway.down = true;
      chat.enqueue('seguimiento');
      async.elapse(const Duration(seconds: 6));
      expect(gateway.submissions, ['turno vivo']);
      expect(chat.queuedMessages, ['seguimiento']);
      expect(chat.queuedRetriesExhausted, isEmpty);

      gateway.down = false;
      async.elapse(const Duration(seconds: 20));
      expect(gateway.submissions, ['turno vivo', 'seguimiento']);
      expect(chat.queuedMessages, isEmpty);
      async.elapse(const Duration(seconds: 30));
      expect(gateway.submissions, ['turno vivo', 'seguimiento']);

      chat.dispose();
      async.flushTimers();
    });
  });

  test('a drain skipped behind an in-flight authority check is '
      'rescheduled and sends exactly once', () {
    fakeAsync((async) {
      final gateway = _FlakyGateway()..holdNextActiveLists = 1;
      final chat = _chat('qr-authority', gateway);

      // Drain A starts its active_list check and is held there.
      chat.enqueue('seguimiento');
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      expect(gateway.heldActiveLists, hasLength(1));

      // A passive inventory read proves the session idle and asks for a drain
      // while A still holds the authority check: that drain is skipped. It
      // also makes A's answer stale.
      chat.refreshPassiveRemoteActivity();
      async.flushMicrotasks();
      expect(gateway.submissions, isEmpty);

      gateway.heldActiveLists.single.complete();
      async.elapse(const Duration(seconds: 5));

      expect(gateway.submissions, ['seguimiento']);
      expect(chat.queuedMessages, isEmpty);
      async.elapse(const Duration(seconds: 30));
      expect(gateway.submissions, ['seguimiento']);

      chat.dispose();
      async.flushTimers();
    });
  });

  test('a drain queued behind a check that then authorizes does not send '
      'the head twice', () {
    fakeAsync((async) {
      final gateway = _FlakyGateway()..holdNextActiveLists = 1;
      final chat = _chat('qr-authority-current', gateway);

      chat.enqueue('primero');
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      expect(gateway.heldActiveLists, hasLength(1));
      // A second admission asks for a drain while the first check is held.
      chat.enqueue('segundo');
      async.elapse(Duration.zero);

      gateway.heldActiveLists.single.complete();
      async.elapse(const Duration(seconds: 5));

      // The current answer drains the head once; the rerun finds the turn
      // running and leaves the rest queued.
      expect(gateway.submissions, ['primero']);
      expect(chat.queuedMessages, ['segundo']);
      async.elapse(const Duration(seconds: 30));
      expect(gateway.submissions, ['primero']);

      chat.dispose();
      async.flushTimers();
    });
  });

  test('a budget used up on a healthy socket comes back with the next '
      'reconnect', () {
    fakeAsync((async) {
      final gateway = _FlakyGateway();
      final chat = _chat('qr-budget-reset', gateway);
      chat.send(fullText: 'turno vivo', model: 'hermes-agent', history: []);
      async.flushMicrotasks();
      chat.state = ChatPipelineState.completed;

      // Hold the head behind a live turn, then mark its budget as spent on a
      // healthy socket (the real ladder is covered by the existing suite).
      chat.state = ChatPipelineState.streaming;
      chat.enqueue('seguimiento');
      final id = chat.queuedEntries.single.id;
      chat.markQueuedRetryExhaustedForTesting(id);
      chat.state = ChatPipelineState.completed;
      async.elapse(const Duration(seconds: 6));
      expect(chat.queuedRetriesExhausted, {id});
      expect(gateway.submissions, ['turno vivo']);

      gateway.dropSocket();
      async.elapse(const Duration(seconds: 3));
      expect(gateway.submissions, ['turno vivo']);
      gateway.down = false;
      async.elapse(const Duration(seconds: 20));

      expect(gateway.submissions, ['turno vivo', 'seguimiento']);
      expect(chat.queuedMessages, isEmpty);
      expect(chat.queuedRetriesExhausted, isEmpty);
      async.elapse(const Duration(seconds: 30));
      expect(gateway.submissions, ['turno vivo', 'seguimiento']);

      chat.dispose();
      async.flushTimers();
    });
  });

  test('a queue paused with Stop stays paused across a reconnect', () {
    fakeAsync((async) {
      final gateway = _FlakyGateway();
      final chat = _chat('qr-parked', gateway);
      chat.send(fullText: 'turno vivo', model: 'hermes-agent', history: []);
      async.flushMicrotasks();
      chat.enqueue('retenido');
      chat.cancel();
      async.elapse(const Duration(seconds: 2));
      expect(chat.queueParked, isTrue);

      gateway.dropSocket();
      async.elapse(const Duration(seconds: 3));
      gateway.down = false;
      async.elapse(const Duration(seconds: 30));

      expect(gateway.submissions, ['turno vivo']);
      expect(chat.queueParked, isTrue);
      expect(chat.queuedMessages, ['retenido']);

      chat.dispose();
      async.flushTimers();
    });
  });
  // External review of 6e9596f: two entries admitted while the socket is
  // down still trigger the queue's own redial; the head goes once and the
  // second stays queued, in order, behind it.
  test('xr1215 two entries queued while down still redial and keep order', () {
    fakeAsync((async) {
      final gateway = _FlakyGateway()..onlyConnectRestores = true;
      final chat = _chat('xr-redial-two', gateway);
      chat.send(fullText: 'turno vivo', model: 'hermes-agent', history: []);
      async.flushMicrotasks();
      chat.state = ChatPipelineState.completed;

      gateway.down = true;
      chat.enqueue('primero');
      chat.enqueue('segundo');
      async.elapse(const Duration(seconds: 6));
      expect(gateway.submissions, ['turno vivo']);
      expect(chat.queuedMessages, ['primero', 'segundo']);

      gateway.reachable = true;
      final connectsBefore = gateway.connectCalls;
      async.elapse(const Duration(seconds: 20));
      expect(gateway.connectCalls, greaterThan(connectsBefore));
      expect(gateway.isConnected, isTrue);
      expect(gateway.submissions, ['turno vivo', 'primero']);
      expect(chat.queuedMessages, ['segundo']);
      expect(chat.queuedRetriesExhausted, isEmpty);

      chat.dispose();
      async.flushTimers();
    });
  });

  test('xr1215 a queued head waits for connect() itself to redial the '
      'socket', () {
    fakeAsync((async) {
      final gateway = _FlakyGateway()..onlyConnectRestores = true;
      final chat = _chat('xr-redial', gateway);
      chat.send(fullText: 'turno vivo', model: 'hermes-agent', history: []);
      async.flushMicrotasks();
      expect(gateway.submissions, ['turno vivo']);
      chat.state = ChatPipelineState.completed;

      gateway.down = true;
      chat.enqueue('seguimiento');
      async.elapse(const Duration(seconds: 6));
      expect(gateway.submissions, ['turno vivo']);
      expect(chat.queuedRetriesExhausted, isEmpty);

      // The server is reachable again, but nothing flips the socket up from
      // outside: only the queue's own redial can restore it.
      gateway.reachable = true;
      final connectsBefore = gateway.connectCalls;
      async.elapse(const Duration(seconds: 20));
      expect(gateway.connectCalls, greaterThan(connectsBefore));
      expect(gateway.isConnected, isTrue);
      expect(gateway.submissions, ['turno vivo', 'seguimiento']);
      expect(chat.queuedMessages, isEmpty);
      async.elapse(const Duration(seconds: 30));
      expect(gateway.submissions, ['turno vivo', 'seguimiento']);

      chat.dispose();
      async.flushTimers();
    });
  });

  // External review of d645dd8: every busy roster status holds the queue,
  // not only the literal `working`.
  for (final status in const ['working', 'running', 'active']) {
    test('xr1215 a drain behind an in-flight check never sends while '
        'session.active_list reports the session busy ($status)', () {
      fakeAsync((async) {
        final busy = [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-remote',
            storedSessionId: 'session-qr',
            status: status,
          ),
        ];
        final gateway = _FlakyGateway()
          ..holdNextActiveLists = 1
          ..activeSessions = busy;
        final chat = _chat('xr-authority-busy', gateway);

        // Drain A holds the authority check; a second admission drains while
        // it is in flight.
        chat.enqueue('primero');
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        expect(gateway.heldActiveLists, hasLength(1));
        chat.enqueue('segundo');
        async.elapse(Duration.zero);
        expect(gateway.submissions, isEmpty);

        // The server keeps answering busy: nothing is sent, however long.
        gateway.heldActiveLists.single.complete();
        async.elapse(const Duration(seconds: 30));
        expect(gateway.submissions, isEmpty);
        expect(chat.queuedMessages, ['primero', 'segundo']);
        final checksWhileBusy = gateway.activeListCalls;
        expect(checksWhileBusy, greaterThanOrEqualTo(2));

        // Only a fresh idle answer releases the head, exactly once.
        gateway.activeSessions = const [];
        chat.refreshPassiveRemoteActivity();
        async.elapse(const Duration(seconds: 5));
        expect(gateway.submissions, ['primero']);
        expect(chat.queuedMessages, ['segundo']);
        async.elapse(const Duration(seconds: 30));
        expect(gateway.submissions, ['primero']);

        chat.dispose();
        async.flushTimers();
      });
    });
  }
}
