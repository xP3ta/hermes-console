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
  label: 'Turn control',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: 'test-key',
);

ActiveChat _chat(String id, HermesDesktopGateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _connection(id),
  sessionId: 'session-$id',
  sessionTitle: 'Turn control',
  notifications: null,
  onTerminal: () {},
  desktopGateway: gateway,
  initialStoredSessionId: 'session-$id',
);

/// Gateway whose next `submitPrompt` can be held open, so a test can act while
/// the drained head sits between its awaits (the late-ACK window).
class _GatedGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> controller =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> submissions = [];
  final List<String> interrupts = [];
  Completer<void>? gate;

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
    runtimeSessionId: 'runtime-turn-control',
    storedSessionId: storedSessionId,
    created: false,
  );
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
  }) => resumeSession('session-turn-control', profile: profile);
  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
    final pending = gate;
    if (pending != null) await pending.future;
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}
  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interrupts.add(runtimeSessionId);
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

class _KeepingOutbox implements TurnOutboxPersistence {
  final Map<String, PreparedTurn> latest = {};

  @override
  Future<void> save(PreparedTurn turn) async =>
      latest[turn.clientTurnId] = turn;

  @override
  Future<void> delete(PreparedTurn turn) async =>
      latest.remove(turn.clientTurnId);
}

PreparedTurn _prepared(String id, String text) {
  const now = 1700000000000;
  return PreparedTurn(
    connectionId: 'turn-control',
    sessionId: 'session-turn-control',
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

Future<void> _pump([int turns = 24]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A chat that already ran one turn, now idle with two text rows queued.
Future<(ActiveChat, _GatedGateway)> _idleChatWithQueue(String id) async {
  final gateway = _GatedGateway();
  final chat = _chat(id, gateway);
  addTearDown(chat.dispose);
  addTearDown(gateway.close);
  expect(
    await chat.send(fullText: 'initial', model: 'hermes-agent', history: []),
    isTrue,
  );
  chat
    ..state = ChatPipelineState.idle
    ..enqueue('head')
    ..enqueue('second');
  return (chat, gateway);
}

void main() {
  group('the drained head is pinned until its send settles', () {
    test('editing the head while it is being sent is refused', () async {
      final (chat, gateway) = await _idleChatWithQueue('edit-in-flight');
      final headId = chat.queuedEntries.first.id;
      gateway.gate = Completer<void>();

      final sending = chat.sendQueuedNow(headId);
      await _pump();
      expect(gateway.submissions, ['initial', 'head']);

      expect(await chat.editQueuedTurn(headId, 'edited'), isFalse);

      gateway.gate!.complete();
      await sending;
      await _pump();
      expect(gateway.submissions, ['initial', 'head']);
      expect(chat.queuedMessages, ['second']);
    });

    test(
      'Stop while the head is in flight: the late ACK sends nothing more',
      () async {
        final (chat, gateway) = await _idleChatWithQueue('stop-in-flight');
        final headId = chat.queuedEntries.first.id;
        gateway.gate = Completer<void>();

        final sending = chat.sendQueuedNow(headId);
        await _pump();
        expect(gateway.submissions, ['initial', 'head']);

        await chat.cancel();
        gateway.gate!.complete();
        await sending;
        await _pump(60);

        expect(gateway.submissions, ['initial', 'head']);
        expect(chat.queueParked, isTrue);
      },
    );

    test(
      'promoting the second row over the head in flight is refused',
      () async {
        final (chat, gateway) = await _idleChatWithQueue('promote-in-flight');
        final ids = chat.queuedEntries.map((entry) => entry.id).toList();
        gateway.gate = Completer<void>();

        final sending = chat.sendQueuedNow(ids.first);
        await _pump();
        expect(gateway.submissions, ['initial', 'head']);

        expect(chat.promoteQueuedTurn(ids.last), isFalse);
        expect(await chat.sendQueuedNow(ids.last), isFalse);

        gateway.gate!.complete();
        await sending;
        await _pump();
        expect(gateway.submissions, ['initial', 'head']);
        expect(chat.queuedMessages, ['second']);
      },
    );
  });

  group('a durable prepared head is pinned until its transport settles', () {
    Future<(ActiveChat, _GatedGateway)> preparedHeadInFlight(String id) async {
      final gateway = _GatedGateway();
      final chat = _chat(id, gateway);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      expect(
        await chat.send(
          fullText: 'initial',
          model: 'hermes-agent',
          history: [],
        ),
        isTrue,
      );
      chat.state = ChatPipelineState.idle;
      gateway.gate = Completer<void>();
      final store = _KeepingOutbox();
      expect(
        await chat.enqueuePreparedTurn(
          ActiveTurnDelivery(prepared: _prepared('a', 'a'), store: store),
        ),
        isTrue,
      );
      await _pump();
      expect(gateway.submissions, ['initial', 'a']);
      expect(
        await chat.enqueuePreparedTurn(
          ActiveTurnDelivery(prepared: _prepared('b', 'b'), store: store),
        ),
        isTrue,
      );
      return (chat, gateway);
    }

    test('edit, promote, move and send-now cannot reorder it', () async {
      final (chat, gateway) = await preparedHeadInFlight('prepared-in-flight');
      expect(chat.queuedEntries.map((entry) => entry.id), [
        'prepared:a',
        'prepared:b',
      ]);
      expect(chat.queuedEntries.first.sending, isTrue);

      expect(await chat.editQueuedTurn('prepared:a', 'edited'), isFalse);
      expect(chat.holdQueuedTurn('prepared:a'), isFalse);
      expect(chat.promoteQueuedTurn('prepared:b'), isFalse);
      expect(await chat.moveQueuedTurn('prepared:b', up: true), isFalse);
      expect(await chat.moveQueuedTurn('prepared:a', up: false), isFalse);
      expect(await chat.sendQueuedNow('prepared:b'), isFalse);

      expect(chat.queuedEntries.map((entry) => entry.id), [
        'prepared:a',
        'prepared:b',
      ]);
      expect(gateway.submissions, ['initial', 'a']);

      gateway.gate!.complete();
      await _pump(60);
      expect(gateway.submissions, ['initial', 'a']);
    });

    test(
      'Stop while it is in flight: the late ACK sends nothing more',
      () async {
        final (chat, gateway) = await preparedHeadInFlight('prepared-stop');

        await chat.cancel();
        gateway.gate!.complete();
        await _pump(60);

        expect(gateway.submissions, ['initial', 'a']);
        expect(chat.queueParked, isTrue);
      },
    );
  });

  group('moving a queued row swaps persisted orders', () {
    test('text rows swap with their neighbour and keep their ids', () async {
      final (chat, _) = await _idleChatWithQueue('move-text');
      chat.state = ChatPipelineState.streaming;
      final before = chat.queuedEntries;
      final orders = before.map((entry) => entry.queueOrder).toList();

      expect(await chat.moveQueuedTurn(before.last.id, up: true), isTrue);

      final after = chat.queuedEntries;
      expect(after.map((entry) => entry.text), ['second', 'head']);
      expect(after.map((entry) => entry.id), [before.last.id, before.first.id]);
      expect(after.map((entry) => entry.queueOrder), orders);
      expect(chat.queuedMessages, ['second', 'head']);
      expect(await chat.moveQueuedTurn(before.last.id, up: true), isFalse);
      expect(await chat.moveQueuedTurn(before.first.id, up: false), isFalse);
      expect(await chat.moveQueuedTurn(before.last.id, up: false), isTrue);
      expect(chat.queuedMessages, ['head', 'second']);
    });

    test(
      'prepared rows persist the swap and restore in the user order',
      () async {
        final gateway = _GatedGateway();
        final chat = _chat('move-prepared', gateway);
        addTearDown(chat.dispose);
        addTearDown(gateway.close);
        await chat.send(
          fullText: 'initial',
          model: 'hermes-agent',
          history: [],
        );
        final store = _KeepingOutbox();
        for (final id in ['a', 'b', 'c']) {
          expect(
            await chat.enqueuePreparedTurn(
              ActiveTurnDelivery(prepared: _prepared(id, id), store: store),
            ),
            isTrue,
          );
        }

        expect(await chat.moveQueuedTurn('prepared:c', up: true), isTrue);
        expect(await chat.moveQueuedTurn('prepared:c', up: true), isTrue);
        expect(chat.queuedEntries.map((entry) => entry.text), ['c', 'a', 'b']);

        final reopened = _chat('move-prepared', _GatedGateway());
        addTearDown(reopened.dispose);
        await reopened.restoreQueuedTurns(
          store.latest.values.map(
            (turn) => PreparedTurn.fromJson(turn.toJson()),
          ),
          store,
          scheduleDrain: false,
        );
        expect(reopened.queuedEntries.map((entry) => entry.text), [
          'c',
          'a',
          'b',
        ]);
      },
    );

    test('a store failure leaves both rows where they were', () async {
      final gateway = _GatedGateway();
      final chat = _chat('move-store-failure', gateway);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(fullText: 'initial', model: 'hermes-agent', history: []);
      final store = _KeepingOutbox();
      for (final id in ['a', 'b']) {
        await chat.enqueuePreparedTurn(
          ActiveTurnDelivery(prepared: _prepared(id, id), store: store),
        );
      }
      final failing = _FailingOutbox();
      for (final item in chat.queuedTurns) {
        item.delivery.rebindStore(failing);
      }

      expect(await chat.moveQueuedTurn('prepared:b', up: true), isFalse);
      expect(chat.queuedEntries.map((entry) => entry.text), ['a', 'b']);
      expect(
        store.latest['a']!.queueOrder,
        lessThan(store.latest['b']!.queueOrder!),
      );
    });

    test('the head in flight cannot move and cannot be overtaken', () async {
      final (chat, gateway) = await _idleChatWithQueue('move-in-flight');
      final ids = chat.queuedEntries.map((entry) => entry.id).toList();
      gateway.gate = Completer<void>();

      final sending = chat.sendQueuedNow(ids.first);
      await _pump();
      expect(gateway.submissions, ['initial', 'head']);

      expect(await chat.moveQueuedTurn(ids.last, up: true), isFalse);
      expect(await chat.moveQueuedTurn(ids.first, up: false), isFalse);

      gateway.gate!.complete();
      await sending;
      await _pump();
      expect(gateway.submissions, ['initial', 'head']);
      expect(chat.queuedMessages, ['second']);
    });
  });

  group('an editor holds its row against the drain', () {
    test('a held head is not drained and nothing overtakes it', () async {
      final gateway = _GatedGateway();
      final chat = _chat('hold-head', gateway);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(fullText: 'initial', model: 'hermes-agent', history: []);
      chat.state = ChatPipelineState.idle;
      chat
        ..enqueue('head')
        ..enqueue('second');
      final ids = chat.queuedEntries.map((entry) => entry.id).toList();
      expect(chat.holdQueuedTurn(ids.first), isTrue);

      await _pump();
      expect(gateway.submissions, ['initial']);
      expect(chat.promoteQueuedTurn(ids.last), isFalse);
      expect(await chat.moveQueuedTurn(ids.first, up: false), isFalse);

      expect(await chat.editQueuedTurn(ids.first, 'edited'), isTrue);
      chat.releaseQueuedTurn(ids.first);
      await _pump();
      expect(gateway.submissions, ['initial', 'edited']);
      expect(chat.queuedMessages, ['second']);
    });

    test('a head the drain already took cannot be held', () async {
      final (chat, gateway) = await _idleChatWithQueue('hold-too-late');
      final headId = chat.queuedEntries.first.id;
      gateway.gate = Completer<void>();

      final sending = chat.sendQueuedNow(headId);
      await _pump();
      expect(gateway.submissions, ['initial', 'head']);

      expect(chat.holdQueuedTurn(headId), isFalse);

      gateway.gate!.complete();
      await sending;
    });

    test('a row that left the queue cannot be held', () async {
      final (chat, _) = await _idleChatWithQueue('hold-missing');
      expect(chat.holdQueuedTurn('text:999'), isFalse);
      expect(chat.holdQueuedTurn('prepared:missing'), isFalse);
    });

    test('a prepared row whose transport started is never held', () async {
      final gateway = _GatedGateway();
      final chat = _chat('hold-started', gateway);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.send(fullText: 'initial', model: 'hermes-agent', history: []);
      final store = _KeepingOutbox();
      final delivery = ActiveTurnDelivery(
        prepared: _prepared('started', 'started'),
        store: store,
      );
      await chat.enqueuePreparedTurn(delivery);
      await delivery.beginTransport(PreparedTurnTransport.desktop);

      expect(chat.holdQueuedTurn('prepared:started'), isFalse);
      expect(await chat.editQueuedTurn('prepared:started', 'late'), isFalse);
    });
  });
}

class _FailingOutbox implements TurnOutboxPersistence {
  @override
  Future<void> save(PreparedTurn turn) async => throw StateError('disk full');

  @override
  Future<void> delete(PreparedTurn turn) async {}
}
