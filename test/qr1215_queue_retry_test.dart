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
    return const DesktopActiveSessionList();
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
}
