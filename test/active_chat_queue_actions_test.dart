import 'package:hermes_android/core/models/bot_mention.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_mention_roster.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: 'Queue test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

ActiveChat _chat(String id, {HermesDesktopGateway? gateway}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
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

class _RedirectQueueGateway extends _QueueGateway
    implements HermesDesktopRedirectGateway {
  final List<String> redirects = [];
  DesktopRedirectDisposition disposition =
      DesktopRedirectDisposition.redirected;
  Object? redirectError;

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    redirects.add(text);
    final error = redirectError;
    if (error != null) throw error;
    return disposition;
  }
}

class _QueuedDrainGateway extends _QueueGateway
    implements
        HermesDesktopQueuedPromptGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopIdempotentGateway {
  final List<String> queuedSubmissions = [];

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
  }) => resumeSession('session-queue-drain', profile: profile);

  @override
  Future<void> submitQueuedPrompt(String runtimeSessionId, String text) async {
    queuedSubmissions.add(text);
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async => DesktopTurnAck(
    accepted: true,
    clientTurnId: clientTurnId,
    serverTurnId: 'server-$clientTurnId',
    state: DesktopTurnState.accepted,
    duplicate: false,
  );

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String runtimeSessionId,
    String clientTurnId,
  ) async => DesktopTurnStatus(
    known: true,
    clientTurnId: clientTurnId,
    serverTurnId: 'server-$clientTurnId',
    state: DesktopTurnState.running,
  );

  @override
  Future<DesktopTurnAck> submitQueuedPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    queuedSubmissions.add(text);
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-$clientTurnId',
      state: DesktopTurnState.accepted,
      duplicate: false,
    );
  }
}

class _MentionLifecycleGateway extends _QueueGateway implements HermesDesktopSessionLifecycleGateway {
  @override
  Future<DesktopSessionBinding> resumeExisting(String storedSessionId, {
    String profile = '', bool omitMessages = false, bool deferHistory = false,
  }) => resumeSession(storedSessionId, profile: profile);
  @override
  Future<DesktopSessionBinding> createForFirstSubmit({String profile = '',
    List<Map<String, dynamic>> seedMessages = const [], String model = '',
  }) => resumeSession('session-queue-prepared', profile: profile);
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
  setUp(BotMentionRoster.shared.clear);
  tearDown(BotMentionRoster.shared.clear);
  void mentionRoster() => BotMentionRoster.shared.replace('queue-prepared', 'Local', const [
    AgentProfile(name: 'ops'),
  ]);

  test('mentions: queued steer and restored drain use the frozen note after roster loss', () async {
    mentionRoster();
    final note = buildBotMentionAnnotation(const [BotMention(connectionId: 'queue-prepared', profile: 'ops', handle: 'ops')]);
    final gateway = _MentionLifecycleGateway();
    final chat = _chat('queue-prepared', gateway: gateway)..state = ChatPipelineState.idle;
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    await chat.send(fullText: 'initial', model: 'hermes-agent', history: const []);
    final store = _MemoryOutbox();
    final prepared = _prepared('mention-steer', '@ops').copyWith(mentionAnnotation: note);
    await chat.enqueuePreparedTurn(ActiveTurnDelivery(prepared: prepared, store: store));
    BotMentionRoster.shared.clear();
    expect(await chat.steerQueuedTurn('prepared:mention-steer'), isTrue);
    expect(gateway.steers, ['@ops$note']);
    expect(chat.messages.where((row) => row['role'] == 'user').any((row) => row['content'] == '@ops'), isTrue);
    final restored = PreparedTurn.fromJson(_prepared('mention-restore', '@ops').copyWith(
      mentionAnnotation: note, queueOrder: 9, queued: true,
    ).toJson());
    await chat.restoreQueuedTurns([restored], store);
    chat.state = ChatPipelineState.idle;
    await chat.sendQueuedNow('prepared:mention-restore');
    expect(gateway.submissions.last, '@ops$note');
  });

  test('mentions: legacy queue freezes resolution including an empty result', () async {
    mentionRoster();
    final gateway = _QueueGateway();
    final chat = _chat('queue-prepared', gateway: gateway)..state = ChatPipelineState.idle;
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    await chat.send(fullText: 'initial', model: 'hermes-agent', history: const []);
    chat.enqueue('@ops');
    chat.enqueue('@future');
    BotMentionRoster.shared.replace('queue-prepared', 'Local', const [AgentProfile(name: 'future')]);
    final entries = chat.queuedEntries;
    expect(entries.map((e) => e.text), ['@ops', '@future']);
    chat.state = ChatPipelineState.idle;
    await chat.sendQueuedNow(entries.first.id);
    expect(gateway.submissions.last, startsWith('@ops\n\n[@mentions'));
    chat.state = ChatPipelineState.idle;
    await chat.sendQueuedNow(entries.last.id);
    expect(gateway.submissions.last, '@future');
  });

  test('mentions: prepared payload wins over changed caller text on idempotent resend', () async {
    final gateway = _QueueGateway();
    final chat = _chat('queue-prepared', gateway: gateway)..state = ChatPipelineState.idle;
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    final note = buildBotMentionAnnotation(const [BotMention(connectionId: 'remote', profile: 'ops', handle: 'ops-remote', remote: true)]);
    final original = _prepared('frozen', '@ops-remote').copyWith(mentionAnnotation: note);
    final delivery = ActiveTurnDelivery(prepared: PreparedTurn.fromJson(original.toJson()), store: _MemoryOutbox());
    await chat.send(fullText: 'must not replace frozen payload', desktopText: 'nor this',
      model: 'hermes-agent', history: const [], delivery: delivery);
    expect(gateway.submissions, ['@ops-remote$note']);
    expect(chat.messages.where((row) => row['role'] == 'user').single['content'], '@ops-remote');
  });


  test(
    'exhausted text waits for manual retry despite a fresh queue drain',
    () async {
      final gateway = _QueueGateway();
      final chat = _chat('retry-boundary', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      expect(
        await chat.send(
          fullText: 'initial',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      chat.enqueue('retry me');
      final id = chat.queuedEntries.single.id;
      chat.markQueuedRetryExhaustedForTesting(id);
      chat.state = ChatPipelineState.idle;
      chat.enqueue('later');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gateway.submissions, ['initial']);
      expect(chat.queuedRetriesExhausted, {id});
      expect(await chat.sendQueuedNow(id), isTrue);
      expect(gateway.submissions, ['initial', 'retry me']);
      expect(chat.queuedRetriesExhausted, isEmpty);
      expect(chat.queuedMessages, ['later']);
    },
  );

  group('agotar el reintento automático de una entrada es observable', () {
    test('queuedRetriesExhausted publica la entrada atascada', () async {
      final chat = _chat('queue-exhausted');
      addTearDown(chat.dispose);
      expect(chat.enqueue('atascado'), isTrue);
      final dynamic subject = chat;
      final String id = subject.queuedEntries.single.id as String;

      expect(chat.queuedRetriesExhausted, isEmpty);

      // Un `queueChanged` es lo único que la UI recibe; sin este conjunto la
      // entrada agotada quedaba indistinguible de una simplemente encolada.
      final emitted = <ActiveChatEvent>[];
      final sub = chat.changes.listen(emitted.add);
      addTearDown(sub.cancel);
      chat.markQueuedRetryExhaustedForTesting(id);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, contains(ActiveChatEvent.queueChanged));
      expect(chat.queuedRetriesExhausted, {id});
    });

    test('una entrada que sale de la cola deja de estar agotada', () async {
      final chat = _chat('queue-exhausted-pruned');
      addTearDown(chat.dispose);
      expect(chat.enqueue('atascado'), isTrue);
      final dynamic subject = chat;
      final String id = subject.queuedEntries.single.id as String;
      chat.markQueuedRetryExhaustedForTesting(id);
      expect(chat.queuedRetriesExhausted, {id});

      // Borrarla a mano resuelve el atasco: mantenerla en el conjunto haría
      // que la UI siguiese creyendo que hay algo pendiente de reenviar.
      expect(await subject.cancelQueuedByIdentity(id) as bool, isTrue);

      expect(chat.queuedMessages, isEmpty);
      expect(chat.queuedRetriesExhausted, isEmpty);
    });
  });

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

  test('redirect rejected stays queued with a rejected outcome', () async {
    final gateway = _RedirectQueueGateway()
      ..disposition = DesktopRedirectDisposition.rejected;
    final chat = _chat('queue-redirect-rejected', gateway: gateway)
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
    final id = chat.queuedEntries.single.id;

    expect(
      await chat.steerQueuedTurnWithOutcome(id),
      QueuedSteerOutcome.rejected,
    );
    expect(gateway.redirects, ['corrige el rumbo']);
    expect(chat.queuedMessages, ['corrige el rumbo']);
  });

  test('redirect 4010 stays queued with a rejected outcome', () async {
    final gateway = _RedirectQueueGateway()
      ..redirectError = const TuiGatewayRpcError(
        'session.redirect',
        'active-turn redirect is unavailable',
        code: 4010,
      );
    final chat = _chat('queue-redirect-4010', gateway: gateway)
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
    final id = chat.queuedEntries.single.id;

    expect(
      await chat.steerQueuedTurnWithOutcome(id),
      QueuedSteerOutcome.rejected,
    );
    expect(chat.queuedMessages, ['corrige el rumbo']);
  });

  test('queue drain submits with queued transport intent', () async {
    final gateway = _QueuedDrainGateway();
    final chat = _chat('queue-drain-wire', gateway: gateway)
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
    chat.state = ChatPipelineState.completed;
    expect(chat.enqueue('seguimiento drenado'), isTrue);
    for (var i = 0; i < 50 && gateway.queuedSubmissions.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(gateway.queuedSubmissions, ['seguimiento drenado']);
    expect(gateway.submissions, ['turno vivo']);
  });

  test('prepared queue drain submits with queued transport intent', () async {
    final gateway = _QueuedDrainGateway();
    final chat = _chat('queue-prepared', gateway: gateway)
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
    chat.state = ChatPipelineState.completed;
    final store = _MemoryOutbox();
    final delivery = ActiveTurnDelivery(
      prepared: _prepared('prepared-drain', 'seguimiento preparado'),
      store: store,
    );
    expect(await chat.enqueuePreparedTurn(delivery), isTrue);
    for (var i = 0; i < 50 && gateway.queuedSubmissions.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(gateway.queuedSubmissions, ['seguimiento preparado']);
    expect(gateway.submissions, ['turno vivo']);
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
