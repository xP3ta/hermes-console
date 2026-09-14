import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_fence_storage.dart';

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: 'Queue test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

ActiveChat _chat(String id, {HermesDesktopGateway? gateway}) => ActiveChat(
  compressionFenceStore: testCompressionFenceStore(),
  connection: _connection(id),
  sessionId: 'session-$id',
  sessionTitle: 'Queue actions',
  notifications: null,
  onTerminal: () {},
  desktopGateway: gateway,
  initialStoredSessionId: 'session-$id',
)..state = ChatPipelineState.streaming;

class _QueueGateway implements HermesDesktopGateway {
  final StreamController<TuiGatewayEvent> controller =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> steers = [];
  final List<String> interrupts = [];
  final List<String> submissions = [];
  bool rejectSteer = false;
  bool settleOnInterrupt = false;

  @override
  Stream<TuiGatewayEvent> get events => controller.stream;
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
    runtimeSessionId: 'runtime-queue',
    storedSessionId: storedSessionId,
    created: false,
  );
  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steers.add(text);
    if (rejectSteer) throw StateError('steer rejected');
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interrupts.add(runtimeSessionId);
    if (settleOnInterrupt) {
      scheduleMicrotask(() {
        controller.add(
          const TuiGatewayEvent(
            type: 'message.complete',
            sessionId: 'runtime-queue',
            payload: {'text': 'interrupted'},
          ),
        );
      });
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
  Future<void> close() => controller.close();
}

class _MemoryOutbox implements TurnOutboxPersistence {
  final List<PreparedTurn> writes = [];
  final List<PreparedTurn> deletes = [];
  Completer<void>? nextSaveGate;

  @override
  Future<void> save(PreparedTurn turn) async {
    final gate = nextSaveGate;
    nextSaveGate = null;
    if (gate != null) await gate.future;
    writes.add(turn);
  }

  @override
  Future<void> delete(PreparedTurn turn) async => deletes.add(turn);
}

PreparedTurn _prepared(String id, String text) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return PreparedTurn(
    connectionId: 'queue-prepared',
    sessionId: 'session-queue-prepared',
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
  test('queuedEntries expone identidad estable en el orden de drenaje', () {
    final chat = _chat('queue-order');
    addTearDown(chat.dispose);
    expect(chat.enqueue('primero'), isTrue);
    expect(chat.enqueue('segundo'), isTrue);

    final dynamic subject = chat;
    final List<dynamic> entries = subject.queuedEntries as List<dynamic>;

    expect(entries.map((entry) => entry.text), ['primero', 'segundo']);
    expect(entries.map((entry) => entry.id).toSet(), hasLength(2));
    expect(entries.map((entry) => entry.queueOrder), orderedEquals([0, 1]));
  });

  test('promoteQueuedTurn mueve una identidad a la cabeza', () async {
    final chat = _chat('queue-promote');
    addTearDown(chat.dispose);
    chat
      ..enqueue('primero')
      ..enqueue('segundo')
      ..enqueue('tercero');
    final dynamic subject = chat;
    final String thirdId = subject.queuedEntries[2].id as String;

    expect(await subject.promoteQueuedTurn(thirdId) as bool, isTrue);

    expect(chat.queuedMessages, ['tercero', 'primero', 'segundo']);
    final promotedEntries = subject.queuedEntries as List<dynamic>;
    expect(promotedEntries.first.id, thirdId);
    expect(promotedEntries.map((entry) => entry.text), [
      'tercero',
      'primero',
      'segundo',
    ]);
  });

  test('editQueuedTurn serializa y persiste el texto prepared', () async {
    final chat = _chat('queue-prepared');
    addTearDown(chat.dispose);
    final store = _MemoryOutbox();
    final delivery = ActiveTurnDelivery(
      prepared: _prepared('turn-editable', 'original'),
      store: store,
    );
    expect(await chat.enqueuePreparedTurn(delivery), isTrue);
    final dynamic subject = chat;
    final String id = subject.queuedEntries.single.id as String;
    final gate = Completer<void>();
    store.nextSaveGate = gate;

    final Future<bool> first = subject.editQueuedTurn(id, 'primera edición');
    final Future<bool> second = subject.editQueuedTurn(id, 'edición final');
    await Future<void>.delayed(Duration.zero);

    expect(store.writes.map((turn) => turn.text), ['original']);
    gate.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(delivery.current.text, 'edición final');
    expect(store.writes.map((turn) => turn.text), [
      'original',
      'primera edición',
      'edición final',
    ]);
  });

  test(
    'cancelQueuedByIdentity borra exacto y cancelQueued sigue delegando',
    () async {
      final chat = _chat('queue-cancel');
      addTearDown(chat.dispose);
      chat
        ..enqueue('primero')
        ..enqueue('segundo');
      final dynamic subject = chat;
      final String secondId = subject.queuedEntries[1].id as String;

      expect(await subject.cancelQueuedByIdentity(secondId) as bool, isTrue);
      expect(chat.queuedMessages, ['primero']);

      chat
        ..enqueue('tercero')
        ..cancelQueued(0);
      expect(chat.queuedMessages, ['tercero']);
    },
  );

  test('steerQueuedTurn rechazado conserva la entrada', () async {
    final gateway = _QueueGateway()..rejectSteer = true;
    final chat = _chat('queue-steer', gateway: gateway)
      ..state = ChatPipelineState.idle;
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    chat.enqueue('corrige el rumbo');
    final dynamic subject = chat;
    final String id = subject.queuedEntries.single.id as String;

    expect(await subject.steerQueuedTurn(id) as bool, isFalse);

    expect(gateway.steers, ['corrige el rumbo']);
    expect(chat.queuedMessages, ['corrige el rumbo']);
  });

  test('sendQueuedNow promueve, interrumpe y conserva el resto', () async {
    final gateway = _QueueGateway()..settleOnInterrupt = true;
    final chat = _chat('queue-send-now', gateway: gateway)
      ..state = ChatPipelineState.idle;
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    chat
      ..enqueue('primero')
      ..enqueue('enviar ahora');
    final dynamic subject = chat;
    final String id = subject.queuedEntries[1].id as String;

    expect(await subject.sendQueuedNow(id) as bool, isTrue);
    for (var i = 0; i < 50 && gateway.submissions.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(gateway.interrupts, ['runtime-queue']);
    expect(gateway.submissions, ['turno vivo', 'enviar ahora']);
    expect(chat.queuedMessages, ['primero']);
    expect(chat.queueParked, isFalse);
  });

  test(
    'promover prepared mantiene panel y drenaje en el mismo orden',
    () async {
      final chat = _chat('queue-mixed-promote');
      addTearDown(chat.dispose);
      chat.enqueue('texto primero');
      final store = _MemoryOutbox();
      final delivery = ActiveTurnDelivery(
        prepared: _prepared('turn-mixed', 'prepared segundo'),
        store: store,
      );
      expect(await chat.enqueuePreparedTurn(delivery), isTrue);
      chat.enqueue('texto tercero');
      expect(chat.queuedEntries.map((entry) => entry.text), [
        'texto primero',
        'prepared segundo',
        'texto tercero',
      ]);

      expect(chat.promoteQueuedTurn('prepared:turn-mixed'), isTrue);

      expect(chat.queuedEntries.map((entry) => entry.text), [
        'prepared segundo',
        'texto primero',
        'texto tercero',
      ]);
    },
  );

  test('encolar prepared levanta un park anterior', () async {
    final gateway = _QueueGateway()..settleOnInterrupt = true;
    final chat = _chat('queue-prepared-unpark', gateway: gateway)
      ..state = ChatPipelineState.idle;
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    expect(
      await chat.send(
        fullText: 'turno vivo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    chat.enqueue('retenido');
    await chat.cancel();
    expect(chat.queueParked, isTrue);
    final delivery = ActiveTurnDelivery(
      prepared: _prepared('turn-fresh-intent', 'intención nueva'),
      store: _MemoryOutbox(),
    );

    expect(await chat.enqueuePreparedTurn(delivery), isTrue);

    expect(chat.queueParked, isFalse);
    expect(chat.queueDrainSuspendedForTesting, isFalse);
  });
}
