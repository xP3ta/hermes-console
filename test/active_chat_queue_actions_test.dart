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
  Completer<void>? submitGate;

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
    await submitGate?.future;
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
  Completer<void>? redirectGate;
  void Function()? onRedirect;

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    redirects.add(text);
    onRedirect?.call();
    await redirectGate?.future;
    final error = redirectError;
    if (error != null) throw error;
    return disposition;
  }
}

class _PreflightQueueChat extends ActiveChat {
  final entered = Completer<void>();
  final preflight = Completer<void>();

  _PreflightQueueChat(HermesDesktopGateway gateway)
    : super(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _connection('queue-prepared'),
        sessionId: 'session-queue-prepared',
        sessionTitle: 'Preflight queue',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
      );

  @override
  Future<DesktopRedirectDisposition> steer(
    String fullText, {
    bool mentionsFrozen = false,
    bool interrupt = true,
    bool allowLegacyFallback = true,
    String? clientTurnId,
  }) async {
    entered.complete();
    await preflight.future;
    return super.steer(
      fullText,
      mentionsFrozen: mentionsFrozen,
      interrupt: interrupt,
      allowLegacyFallback: allowLegacyFallback,
      clientTurnId: clientTurnId,
    );
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

class _TerminalRedirectQueueGateway extends _QueuedDrainGateway
    implements HermesDesktopRedirectGateway {
  final redirectEntered = Completer<void>();
  final redirectResult = Completer<DesktopRedirectDisposition>();
  final queuedSubmitted = Completer<void>();

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) {
    redirectEntered.complete();
    return redirectResult.future;
  }

  void _submitted() {
    if (!queuedSubmitted.isCompleted) queuedSubmitted.complete();
  }

  @override
  Future<void> submitQueuedPrompt(String runtimeSessionId, String text) async {
    await super.submitQueuedPrompt(runtimeSessionId, text);
    _submitted();
  }

  @override
  Future<DesktopTurnAck> submitQueuedPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    final ack = await super.submitQueuedPromptIdempotent(
      runtimeSessionId,
      text,
      clientTurnId,
    );
    _submitted();
    return ack;
  }
}

class _MentionLifecycleGateway extends _QueueGateway
    implements HermesDesktopSessionLifecycleGateway {
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
  }) => resumeSession('session-queue-prepared', profile: profile);
}

class _MemoryOutbox implements TurnOutboxPersistence {
  final List<PreparedTurn> writes = [];
  final List<PreparedTurn> deletes = [];
  Completer<void>? nextSaveGate;
  bool failDelete = false;
  bool failSave = false;

  @override
  Future<void> save(PreparedTurn turn) async {
    final gate = nextSaveGate;
    nextSaveGate = null;
    if (gate != null) await gate.future;
    if (failSave) throw StateError('save unavailable');
    writes.add(turn);
  }

  @override
  Future<void> delete(PreparedTurn turn) async {
    if (failDelete) throw StateError('delete unavailable');
    deletes.add(turn);
  }
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
  test(
    'run_not preflight failures are safe; transport loss stays ambiguous',
    () {
      for (final message in ['run_not_active', 'run_not_ready']) {
        expect(
          activeChatSteerFailureIsSafeToQueue(StateError(message)),
          isTrue,
        );
      }
      expect(
        activeChatSteerFailureIsSafeToQueue(StateError('socket lost')),
        isFalse,
      );
    },
  );

  for (final source in ['text', 'prepared', 'composer']) {
    for (final stopped in [false, true]) {
      test(
        'terminal during rejected redirect rearms drain, source=$source Stop=$stopped',
        () async {
          final gateway = _TerminalRedirectQueueGateway();
          final chat = _chat('queue-prepared', gateway: gateway)
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
          if (source == 'prepared') {
            expect(
              await chat.enqueuePreparedTurn(
                ActiveTurnDelivery(
                  prepared: _prepared('terminal-rpc-head', 'head'),
                  store: _MemoryOutbox(),
                ),
              ),
              isTrue,
            );
          } else {
            expect(chat.enqueue('head'), isTrue);
          }
          expect(chat.enqueue('tail'), isTrue);
          final ids = chat.queuedEntries.map((row) => row.id).toList();
          final Future<bool> rejected;
          if (source == 'composer') {
            rejected = chat
                .redirectPreparedComposerTurn(
                  ActiveTurnDelivery(
                    prepared: _prepared('terminal-rpc-composer', 'correction'),
                    store: _MemoryOutbox(),
                  ),
                )
                .then(
                  (result) => result == DesktopRedirectDisposition.rejected,
                );
          } else {
            rejected = chat
                .steerQueuedTurnWithOutcome(ids.first)
                .then((result) => result == QueuedSteerOutcome.rejected);
          }
          await gateway.redirectEntered.future;
          if (stopped) {
            await chat.cancel();
            expect(chat.queueParked, isTrue);
          } else {
            final done = chat.changes.firstWhere(
              (e) => e == ActiveChatEvent.done,
            );
            gateway.controller.add(
              const TuiGatewayEvent(
                type: 'message.complete',
                sessionId: 'runtime-queue',
                payload: {'text': 'initial complete'},
              ),
            );
            await done.timeout(const Duration(seconds: 2));
          }
          // Let the terminal's one scheduled drain observe the pending RPC.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(chat.isStreaming, isFalse);
          expect(gateway.queuedSubmissions, isEmpty);
          expect(chat.queuedEntries.map((row) => row.id), ids);
          gateway.redirectResult.complete(DesktopRedirectDisposition.rejected);
          expect(await rejected, isTrue);
          if (stopped) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(chat.queueParked, isTrue);
            expect(gateway.queuedSubmissions, isEmpty);
            expect(chat.queuedEntries.map((row) => row.id), ids);
          } else {
            await gateway.queuedSubmitted.future.timeout(
              const Duration(seconds: 2),
            );
            await Future<void>.delayed(const Duration(milliseconds: 20));
            expect(gateway.queuedSubmissions, ['head']);
            expect(chat.queuedEntries.map((row) => row.id), [ids.last]);
            expect(chat.queuedEntries.single.text, 'tail');
            expect(chat.queuedEntries.single.deliveryUnknown, isFalse);
          }
        },
      );
    }
  }

  for (final prepared in [false, true]) {
    test(
      'Stop during queued redirect preflight, prepared=$prepared: stays actionable in FIFO',
      () async {
        final gateway = _RedirectQueueGateway();
        final chat = _PreflightQueueChat(gateway)
          ..state = ChatPipelineState.streaming;
        addTearDown(chat.dispose);
        addTearDown(gateway.close);
        ActiveTurnDelivery? delivery;
        if (prepared) {
          delivery = ActiveTurnDelivery(
            prepared: _prepared('preflight', 'head'),
            store: _MemoryOutbox(),
          );
          await chat.enqueuePreparedTurn(delivery);
        } else {
          chat.enqueue('head');
        }
        chat.enqueue('tail');
        final ids = chat.queuedEntries.map((e) => e.id).toList();
        final flight = chat.steerQueuedTurnWithOutcome(ids.first);
        await chat.entered.future;
        // A safe preflight failure stays queued when Stop explicitly paused it.
        // Without Stop the terminal/RPC race above must rearm its drain.
        await chat.cancel();
        expect(chat.queueParked, isTrue);
        chat.state = ChatPipelineState.idle;
        chat.preflight.complete();
        expect(await flight, QueuedSteerOutcome.rejected);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(gateway.redirects, isEmpty);
        expect(gateway.steers, isEmpty);
        expect(gateway.submissions, isEmpty);
        expect(chat.queuedEntries.map((e) => e.id), ids);
        expect(chat.queuedEntries.first.deliveryUnknown, isFalse);
        expect(chat.holdQueuedTurn(ids.first), isTrue);
        if (delivery != null) expect(delivery.transportStarted, isFalse);
      },
    );

    for (final ambiguous in [false, true]) {
      test(
        'rejected queued redirect preserves Stop pause, prepared=$prepared ambiguous=$ambiguous',
        () async {
          final gateway = _RedirectQueueGateway();
          final chat = _chat('queue-prepared', gateway: gateway)
            ..state = ChatPipelineState.idle;
          addTearDown(chat.dispose);
          addTearDown(gateway.close);
          await chat.send(
            fullText: 'initial',
            model: 'hermes-agent',
            history: const [],
          );
          if (prepared) {
            await chat.enqueuePreparedTurn(
              ActiveTurnDelivery(
                prepared: _prepared('paused', 'head'),
                store: _MemoryOutbox(),
              ),
            );
          } else {
            chat.enqueue('head');
          }
          chat.enqueue('tail');
          await chat.cancel();
          expect(chat.queueParked, isTrue);
          final ids = chat.queuedEntries.map((e) => e.id).toList();
          chat.state = ChatPipelineState.streaming;
          gateway.onRedirect = () => chat.state = ChatPipelineState.idle;
          gateway.disposition = DesktopRedirectDisposition.rejected;
          if (ambiguous) gateway.redirectError = StateError('lost ACK');
          expect(
            await chat.steerQueuedTurnWithOutcome(ids.first),
            ambiguous
                ? QueuedSteerOutcome.unconfirmed
                : QueuedSteerOutcome.rejected,
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(chat.queueParked, isTrue);
          expect(chat.queueDrainSuspendedForTesting, isTrue);
          expect(chat.queuedEntries.map((e) => e.id), ids);
          expect(gateway.redirects, ['head']);
          expect(gateway.submissions, ['initial']);
        },
      );
    }
  }

  test(
    'accepted redirect stays in transcript, never in local queue; Stop parks once',
    () async {
      final gateway = _RedirectQueueGateway()
        ..disposition = DesktopRedirectDisposition.queued;
      final chat = _chat('accepted-redirect', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(
        fullText: 'initial',
        model: 'hermes-agent',
        history: const [],
      );
      expect(
        await chat.steer('WAF request'),
        DesktopRedirectDisposition.queued,
      );
      expect(
        chat.messages.where((row) => row['content'] == 'WAF request'),
        hasLength(1),
      );
      expect(chat.queuedEntries, isEmpty);
      expect(chat.queuedMessages, isEmpty);
      expect(chat.queuedTextMessages, isEmpty);
      // Stop takes back the server-owned pending input through its existing
      // interrupt protocol, giving it a real cancellable local identity.
      await chat.cancel();
      final parked = chat.queuedEntries.single;
      expect(chat.queueParked, isTrue);
      expect(parked.id, startsWith('parked-accepted:'));
      expect(await chat.cancelQueuedByIdentity(parked.id), isTrue);
      expect(chat.queuedEntries, isEmpty);
      expect(gateway.redirects, ['WAF request']);
      expect(gateway.submissions, ['initial']);
    },
  );

  test(
    'delete parks a durable tombstone even if physical outbox delete fails',
    () async {
      final chat = _chat('queue-prepared');
      addTearDown(chat.dispose);
      final store = _MemoryOutbox()..failDelete = true;
      final delivery = ActiveTurnDelivery(
        prepared: _prepared('delete', 'keep until deleted'),
        store: store,
      );
      await chat.enqueuePreparedTurn(delivery);
      chat.enqueue('tail');
      expect(await chat.cancelQueuedByIdentity('prepared:delete'), isTrue);
      expect(store.writes.last.state, PreparedTurnState.terminal);
      expect(delivery.discarded, isTrue);
      expect(await delivery.updatePreparedText('late edit'), isFalse);
      expect(
        await delivery.beginTransport(PreparedTurnTransport.desktop),
        isFalse,
      );
      expect(chat.queuedMessages, ['tail']);
    },
  );

  test(
    'failed durable delete stays visible in FIFO and can be retried',
    () async {
      final chat = _chat('queue-prepared');
      addTearDown(chat.dispose);
      final store = _MemoryOutbox();
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(prepared: _prepared('delete', 'head'), store: store),
      );
      chat.enqueue('tail');
      store.failSave = true;
      expect(await chat.cancelQueuedByIdentity('prepared:delete'), isFalse);
      expect(chat.queuedMessages, ['head', 'tail']);
      store.failSave = false;
      expect(await chat.cancelQueuedByIdentity('prepared:delete'), isTrue);
      expect(chat.queuedMessages, ['tail']);
    },
  );

  test(
    'text in flight refuses deletion; later rows keep their place',
    () async {
      final gateway = _QueueGateway();
      final chat = _chat('inflight-delete', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(
        fullText: 'initial',
        model: 'hermes-agent',
        history: const [],
      );
      chat
        ..enqueue('head')
        ..enqueue('tail');
      final id = chat.queuedEntries.first.id;
      gateway.submitGate = Completer<void>();
      chat.state = ChatPipelineState.idle;
      final sending = chat.sendQueuedNow(id);
      for (var i = 0; i < 100 && gateway.submissions.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(chat.queuedEntries.first.sending, isTrue);
      expect(await chat.cancelQueuedByIdentity(id), isFalse);
      gateway.submitGate!.complete();
      await sending;
      expect(chat.queuedMessages, ['tail']);
      expect(gateway.submissions, ['initial', 'head']);
    },
  );

  test('blocked prepared head cannot be overtaken by later text', () async {
    final gateway = _QueueGateway();
    final chat = _chat('queue-prepared', gateway: gateway)
      ..state = ChatPipelineState.idle;
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    await chat.send(
      fullText: 'initial',
      model: 'hermes-agent',
      history: const [],
    );
    await chat.restoreQueuedTurns([
      _prepared('unpositioned', 'blocked head'),
    ], _MemoryOutbox());
    chat.state = ChatPipelineState.idle;
    chat.enqueue('later text');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(gateway.submissions, ['initial']);
    expect(chat.queuedMessages, ['blocked head', 'later text']);
    expect(await chat.cancelQueuedByIdentity('prepared:unpositioned'), isTrue);
  });

  test(
    'queued redirect reserves its identity across terminal and removes accepted outbox row',
    () async {
      final gateway = _RedirectQueueGateway()..redirectGate = Completer<void>();
      final chat = _chat('queue-prepared', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(
        fullText: 'initial',
        model: 'hermes-agent',
        history: const [],
      );
      final store = _MemoryOutbox()..failDelete = true;
      final delivery = ActiveTurnDelivery(
        prepared: _prepared('redirect', 'correction'),
        store: store,
      );
      await chat.enqueuePreparedTurn(delivery);
      final flight = chat.steerQueuedTurnWithOutcome('prepared:redirect');
      for (var i = 0; i < 100 && gateway.redirects.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(delivery.current.state, PreparedTurnState.submitting);
      expect(await chat.cancelQueuedTurn('redirect'), isFalse);
      expect(
        await chat.steerQueuedTurnWithOutcome('prepared:redirect'),
        QueuedSteerOutcome.rejected,
      );
      gateway.controller.add(
        const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-queue',
          payload: {'text': 'done'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(gateway.submissions, ['initial']);
      gateway.redirectGate!.complete();
      expect(await flight, QueuedSteerOutcome.accepted);
      expect(chat.queuedEntries, isEmpty);
      expect(store.writes.last.state, PreparedTurnState.terminal);
      expect(gateway.redirects, ['correction']);
      expect(gateway.submissions, ['initial']);
    },
  );

  test(
    'ambiguous queued redirect remains protected, never becomes a fresh send',
    () async {
      final gateway = _RedirectQueueGateway()
        ..redirectError = StateError('socket lost after dispatch');
      final chat = _chat('queue-prepared', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(
        fullText: 'initial',
        model: 'hermes-agent',
        history: const [],
      );
      final delivery = ActiveTurnDelivery(
        prepared: _prepared('unknown', 'correction'),
        store: _MemoryOutbox(),
      );
      await chat.enqueuePreparedTurn(delivery);
      expect(
        await chat.steerQueuedTurnWithOutcome('prepared:unknown'),
        QueuedSteerOutcome.unconfirmed,
      );
      expect(delivery.current.state, PreparedTurnState.ambiguous);
      expect(chat.queuedEntries.single.deliveryUnknown, isTrue);
      expect(await chat.cancelQueuedByIdentity('prepared:unknown'), isFalse);
      expect(
        await chat.steerQueuedTurnWithOutcome('prepared:unknown'),
        QueuedSteerOutcome.rejected,
      );
      expect(gateway.redirects, ['correction']);
      expect(gateway.submissions, ['initial']);
    },
  );

  test('legacy indexed delete uses the displayed mixed queue order', () async {
    final chat = _chat('queue-prepared');
    addTearDown(chat.dispose);
    chat.enqueue('first');
    await chat.enqueuePreparedTurn(
      ActiveTurnDelivery(
        prepared: _prepared('middle', 'prepared middle'),
        store: _MemoryOutbox(),
      ),
    );
    chat.enqueue('last');
    expect(chat.queuedEntryCount, 3);
    expect(chat.queuedEntryCount, chat.queuedEntries.length);
    chat.cancelQueued(1);
    await Future<void>.delayed(Duration.zero);
    expect(chat.queuedMessages, ['first', 'last']);
    expect(chat.queuedEntryCount, 2);
  });

  test(
    'ambiguous legacy redirect keeps its FIFO slot until explicitly abandoned',
    () async {
      final gateway = _RedirectQueueGateway()
        ..redirectError = StateError('lost ACK');
      final chat = _chat('legacy-unknown', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(
        fullText: 'initial',
        model: 'hermes-agent',
        history: const [],
      );
      chat
        ..enqueue('unknown')
        ..enqueue('later');
      final id = chat.queuedEntries.first.id;
      expect(
        await chat.steerQueuedTurnWithOutcome(id),
        QueuedSteerOutcome.unconfirmed,
      );
      expect(chat.queuedEntries.first.deliveryUnknown, isTrue);
      gateway.controller.add(
        const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-queue',
          payload: {'text': 'done'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gateway.submissions, ['initial']);
      expect(await chat.sendQueuedNow(id), isFalse);
      expect(await chat.editQueuedTurn(id, 'changed'), isFalse);
      expect(chat.holdQueuedTurn(id), isFalse);
      expect(await chat.abandonUncertainQueuedTurn(id), isTrue);
      expect(chat.queuedMessages, ['later']);
    },
  );

  test(
    'public send acceptance retires the same queued delivery without cancelling its live turn',
    () async {
      final gateway = _QueueGateway();
      final chat = _chat('queue-prepared', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(
        fullText: 'initial',
        model: 'hermes-agent',
        history: const [],
      );
      final delivery = ActiveTurnDelivery(
        prepared: _prepared('accepted-outside-drain', 'accepted follow up'),
        store: _MemoryOutbox(),
      );
      await chat.enqueuePreparedTurn(delivery);
      chat.state = ChatPipelineState.idle;
      expect(
        await chat.send(
          fullText: delivery.current.fullText,
          model: 'hermes-agent',
          history: const [],
          delivery: delivery,
        ),
        isTrue,
      );
      expect(delivery.acknowledged, isTrue);
      expect(delivery.current.state, PreparedTurnState.running);
      expect(chat.isStreaming, isTrue);
      expect(chat.queuedEntries, isEmpty);
      expect(chat.queuedTurns, isEmpty);
      expect(gateway.submissions, ['initial', 'accepted follow up']);
      expect(
        chat.messages.where((row) => row['content'] == 'accepted follow up'),
        hasLength(1),
      );
    },
  );

  setUp(BotMentionRoster.shared.clear);
  tearDown(BotMentionRoster.shared.clear);
  void mentionRoster() => BotMentionRoster.shared.replace(
    'queue-prepared',
    'Local',
    const [AgentProfile(name: 'ops')],
  );

  test(
    'mentions: queued steer and restored drain use the frozen note after roster loss',
    () async {
      mentionRoster();
      final note = buildBotMentionAnnotation(const [
        BotMention(
          connectionId: 'queue-prepared',
          profile: 'ops',
          handle: 'ops',
        ),
      ]);
      final gateway = _MentionLifecycleGateway();
      final chat = _chat('queue-prepared', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(
        fullText: 'initial',
        model: 'hermes-agent',
        history: const [],
      );
      final store = _MemoryOutbox();
      final prepared = _prepared(
        'mention-steer',
        '@ops',
      ).copyWith(mentionAnnotation: note);
      await chat.enqueuePreparedTurn(
        ActiveTurnDelivery(prepared: prepared, store: store),
      );
      BotMentionRoster.shared.clear();
      expect(await chat.steerQueuedTurn('prepared:mention-steer'), isTrue);
      expect(gateway.steers, ['@ops$note']);
      expect(
        chat.messages
            .where((row) => row['role'] == 'user')
            .any((row) => row['content'] == '@ops'),
        isTrue,
      );
      final restored = PreparedTurn.fromJson(
        _prepared('mention-restore', '@ops')
            .copyWith(mentionAnnotation: note, queueOrder: 9, queued: true)
            .toJson(),
      );
      await chat.restoreQueuedTurns([restored], store);
      chat.state = ChatPipelineState.idle;
      await chat.sendQueuedNow('prepared:mention-restore');
      expect(gateway.submissions.last, '@ops$note');
    },
  );

  test(
    'mentions: legacy queue freezes resolution including an empty result',
    () async {
      mentionRoster();
      final gateway = _QueueGateway();
      final chat = _chat('queue-prepared', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(
        fullText: 'initial',
        model: 'hermes-agent',
        history: const [],
      );
      chat.enqueue('@ops');
      chat.enqueue('@future');
      BotMentionRoster.shared.replace('queue-prepared', 'Local', const [
        AgentProfile(name: 'future'),
      ]);
      final entries = chat.queuedEntries;
      expect(entries.map((e) => e.text), ['@ops', '@future']);
      chat.state = ChatPipelineState.idle;
      await chat.sendQueuedNow(entries.first.id);
      expect(gateway.submissions.last, startsWith('@ops\n\n[@mentions'));
      chat.state = ChatPipelineState.idle;
      await chat.sendQueuedNow(entries.last.id);
      expect(gateway.submissions.last, '@future');
    },
  );

  test(
    'mentions: prepared payload wins over changed caller text on idempotent resend',
    () async {
      final gateway = _QueueGateway();
      final chat = _chat('queue-prepared', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      final note = buildBotMentionAnnotation(const [
        BotMention(
          connectionId: 'remote',
          profile: 'ops',
          handle: 'ops-remote',
          remote: true,
        ),
      ]);
      final original = _prepared(
        'frozen',
        '@ops-remote',
      ).copyWith(mentionAnnotation: note);
      final delivery = ActiveTurnDelivery(
        prepared: PreparedTurn.fromJson(original.toJson()),
        store: _MemoryOutbox(),
      );
      await chat.send(
        fullText: 'must not replace frozen payload',
        desktopText: 'nor this',
        model: 'hermes-agent',
        history: const [],
        delivery: delivery,
      );
      expect(gateway.submissions, ['@ops-remote$note']);
      expect(
        chat.messages.where((row) => row['role'] == 'user').single['content'],
        '@ops-remote',
      );
    },
  );

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

  test(
    'plain-text queue drains automatically once the live turn completes',
    () async {
      // Regression for the "EN COLA" badge sticking after a turn finished:
      // the terminal drain gate only re-armed itself for prepared (attachment)
      // turns with a durable owner record. A queue holding only plain text
      // (`enqueue`, no attachments) has no such per-item ownership record, so
      // the old condition never scheduled a drain and the queue strip stayed
      // on screen until the user sent something else manually.
      final gateway = _QueuedDrainGateway();
      final chat = _chat('queue-drain-plaintext', gateway: gateway)
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
      // Queue while the turn is still live: `enqueue()` only auto-schedules
      // an immediate drain when `!isStreaming`, so this reproduces the queue
      // sitting untouched until the terminal callback fires.
      expect(chat.isStreaming, isTrue);
      expect(chat.enqueue('seguimiento en cola'), isTrue);
      expect(chat.queuedEntries.map((entry) => entry.text), [
        'seguimiento en cola',
      ]);

      gateway.controller.add(
        const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-queue',
          payload: {'text': 'turno vivo respondido'},
        ),
      );

      for (var i = 0; i < 100 && gateway.queuedSubmissions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(gateway.queuedSubmissions, ['seguimiento en cola']);
      expect(chat.queuedEntries, isEmpty);
    },
  );

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

  group('lo1216 restored queue from a previous run', () {
    ActiveChat idleChat(String id, HermesDesktopGateway gateway) =>
        _chat(id, gateway: gateway)..state = ChatPipelineState.idle;

    PreparedTurn persisted(String id, String text, int order) =>
        PreparedTurn.fromJson(
          _prepared(id, text).copyWith(queueOrder: order).toJson(),
        );

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    test('comes back paused and resumes exactly once in order', () async {
      final gateway = _MentionLifecycleGateway();
      final chat = idleChat('queue-prepared', gateway);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      final store = _MemoryOutbox();

      await chat.restoreQueuedTurns([
        persisted('lo1216-old-2', 'segundo', 2),
        persisted('lo1216-old-1', 'primero', 1),
      ], store);
      await settle();

      expect(gateway.submissions, isEmpty);
      expect(chat.queueParked, isTrue);
      expect(chat.queueParkedFromPreviousSession, isTrue);
      expect(chat.queuedEntries.map((e) => e.text), ['primero', 'segundo']);

      expect(chat.resumeParkedQueue(), isTrue);
      expect(chat.queueParkedFromPreviousSession, isFalse);
      for (var i = 0; i < 50 && gateway.submissions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gateway.submissions, ['primero']);
      chat.state = ChatPipelineState.idle;
      await chat.sendQueuedNow('prepared:lo1216-old-2');
      await settle();
      expect(gateway.submissions, ['primero', 'segundo']);
    });

    test('resume waits for an unresolved composer turn', () async {
      final gateway = _MentionLifecycleGateway();
      final chat = idleChat('queue-prepared', gateway);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.restoreQueuedTurns(
        [persisted('lo1216-behind', 'detrás', 1)],
        _MemoryOutbox(),
        scheduleDrain: false,
      );
      expect(chat.queueParked, isTrue);

      expect(chat.resumeParkedQueue(), isTrue);
      await settle();
      expect(gateway.submissions, isEmpty);

      chat.resumeQueueDrainAfterComposerTurnResolved();
      for (var i = 0; i < 50 && gateway.submissions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gateway.submissions, ['detrás']);
    });

    test('a turn queued in this run still drains when restored', () async {
      final store = _MemoryOutbox();
      final firstGateway = _MentionLifecycleGateway();
      final first = _chat('queue-prepared', gateway: firstGateway);
      addTearDown(firstGateway.close);
      final delivery = ActiveTurnDelivery(
        prepared: _prepared('lo1216-this-run', 'de esta sesión'),
        store: store,
      );
      expect(await first.enqueuePreparedTurn(delivery), isTrue);
      final saved = PreparedTurn.fromJson(delivery.current.toJson());
      first.dispose();

      final gateway = _MentionLifecycleGateway();
      final chat = idleChat('queue-prepared', gateway);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.restoreQueuedTurns([saved], store);
      for (var i = 0; i < 50 && gateway.submissions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(chat.queueParked, isFalse);
      expect(gateway.submissions, ['de esta sesión']);
    });

    test('a turn parked with Stop stays parked when restored', () async {
      final store = _MemoryOutbox();
      final firstGateway = _QueueGateway()..settleOnInterrupt = true;
      final first = _chat('queue-prepared', gateway: firstGateway)
        ..state = ChatPipelineState.idle;
      addTearDown(firstGateway.close);
      expect(
        await first.send(
          fullText: 'turno vivo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      final delivery = ActiveTurnDelivery(
        prepared: _prepared('lo1216-parked', 'retenido'),
        store: store,
      );
      expect(await first.enqueuePreparedTurn(delivery), isTrue);
      await first.cancel();
      expect(first.queueParked, isTrue);
      final saved = PreparedTurn.fromJson(delivery.current.toJson());
      first.dispose();

      final gateway = _MentionLifecycleGateway();
      final chat = idleChat('queue-prepared', gateway);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.restoreQueuedTurns([saved], store);
      await settle();

      expect(gateway.submissions, isEmpty);
      expect(chat.queueParked, isTrue);
      expect(chat.queueParkedFromPreviousSession, isFalse);
    });
  });

  group('issue 113 Stop never retires a started row', () {
    PreparedTurn persisted(String id, int order, PreparedTurnState state) =>
        PreparedTurn.fromJson(
          _prepared(id, id).copyWith(queueOrder: order, state: state).toJson(),
        );

    test('a queue restored with an accepted row sends nothing', () async {
      final gateway = _MentionLifecycleGateway();
      final chat = _chat('queue-prepared', gateway: gateway)
        ..state = ChatPipelineState.idle;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);

      await chat.restoreQueuedTurns([
        persisted('i113-accepted', 1, PreparedTurnState.accepted),
        persisted('i113-prepared', 2, PreparedTurnState.prepared),
      ], _MemoryOutbox());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(gateway.submissions, isEmpty);
      expect(chat.queueParked, isTrue);
    });

    test(
      'clearing the queue keeps the accepted row and drops the rest',
      () async {
        final gateway = _MentionLifecycleGateway();
        final chat = _chat('queue-prepared', gateway: gateway)
          ..state = ChatPipelineState.idle;
        addTearDown(chat.dispose);
        addTearDown(gateway.close);
        final store = _MemoryOutbox();
        await chat.restoreQueuedTurns([
          persisted('i113-accepted', 1, PreparedTurnState.accepted),
          persisted('i113-prepared', 2, PreparedTurnState.prepared),
        ], store);

        chat.clearQueueForTesting();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(chat.queuedEntries.map((e) => e.id), ['prepared:i113-accepted']);
        expect(chat.queuedEntries.single.stopWaitingAvailable, isTrue);
        expect(store.deletes.map((turn) => turn.clientTurnId), [
          'i113-prepared',
        ]);
      },
    );

    for (final state in [
      PreparedTurnState.submitting,
      PreparedTurnState.ambiguous,
    ]) {
      test(
        'clearing keeps a ${state.name} row whose transport started',
        () async {
          final gateway = _MentionLifecycleGateway();
          final chat = _chat('queue-prepared', gateway: gateway)
            ..state = ChatPipelineState.idle;
          addTearDown(chat.dispose);
          addTearDown(gateway.close);
          final store = _MemoryOutbox();
          await chat.restoreQueuedTurns([
            persisted('i113-started', 1, state),
            persisted('i113-prepared', 2, PreparedTurnState.prepared),
          ], store);

          chat.clearQueueForTesting();
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(chat.queuedEntries.map((e) => e.id), [
            'prepared:i113-started',
          ]);
          expect(
            store.deletes.map((turn) => turn.clientTurnId),
            isNot(contains('i113-started')),
          );
          expect(gateway.submissions, isEmpty);
        },
      );
    }
  });
}
