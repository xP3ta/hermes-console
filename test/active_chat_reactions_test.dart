// ActiveChat keeps the reactions of a transcript: optimistic apply for the
// user's own, rollback when the gateway refuses, and live agent reactions.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/message_reaction.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _FakeDesktopGateway
    implements HermesDesktopGateway, HermesMessageReactionGateway {
  final List<Map<String, Object?>> calls = [];
  bool available = true;

  /// What the probe will find: the server has `message.react` or not. While
  /// [available] is false and unconfirmed, nothing is offered.
  bool serverHasReactions = true;
  int confirmCalls = 0;

  @override
  bool get messageReactionsAvailable => available;

  @override
  Future<bool> confirmMessageReactions(String runtimeSessionId) async {
    confirmCalls++;
    available = serverHasReactions;
    return available;
  }

  Completer<({int rowId, List<MessageReaction> reactions})>? pending;

  @override
  Future<({int rowId, List<MessageReaction> reactions})> reactToMessage(
    String runtimeSessionId, {
    int? rowId,
    String? newestRole,
    String? emoji,
    String? profile,
  }) {
    calls.add({'row': rowId, 'role': newestRole, 'emoji': emoji});
    return pending!.future;
  }

  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast(sync: true);

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

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
    runtimeSessionId: 'runtime-contract',
    storedSessionId: storedSessionId,
    created: false,
  );

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
  Future<void> close() async {}

  void emit(String type, Map<String, dynamic> payload) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: 'runtime-contract',
      payload: Map<String, dynamic>.unmodifiable(payload),
    ),
  );
}

Future<ActiveChat> _liveChat(_FakeDesktopGateway gateway) async {
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-contract',
      label: 'Contract',
      host: 'example.invalid',
      port: 443,
      apiKey: 'unused',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-contract',
    sessionTitle: 'Contract',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'unused',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  addTearDown(chat.dispose);
  expect(
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
    isTrue,
  );
  return chat;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'the user reaction shows at once and the server list replaces it',
    () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      final done = Completer<({int rowId, List<MessageReaction> reactions})>();
      gateway.pending = done;
      final future = chat.reactToMessage(rowId: 5, emoji: '👍');
      expect(chat.reactionsFor(5).single.emoji, '👍');
      done.complete((
        rowId: 5,
        reactions: const [
          MessageReaction(emoji: '👍', author: MessageReactionAuthor.user),
          MessageReaction(emoji: '🎉', author: MessageReactionAuthor.agent),
        ],
      ));
      await future;
      expect(chat.reactionsFor(5).map((r) => r.emoji), ['👍', '🎉']);
      expect(gateway.calls.single, {'row': 5, 'role': null, 'emoji': '👍'});
    },
  );

  test('a refused reaction is rolled back and the error surfaces', () async {
    final gateway = _FakeDesktopGateway();
    final chat = await _liveChat(gateway);
    final done = Completer<({int rowId, List<MessageReaction> reactions})>();
    gateway.pending = done;
    final future = chat.reactToMessage(rowId: 5, emoji: '👍');
    final failure = expectLater(future, throwsA(isA<StateError>()));
    expect(chat.reactionsFor(5), isNotEmpty);
    done.completeError(StateError('no'));
    await failure;
    expect(chat.reactionsFor(5), isEmpty);
  });

  test(
    'an unconfirmed gateway offers nothing until the probe finds support',
    () async {
      final gateway = _FakeDesktopGateway()..available = false;
      final chat = await _liveChat(gateway);
      final emitted = <ActiveChatEvent>[];
      final sub = chat.changes.listen(emitted.add);
      addTearDown(sub.cancel);
      expect(chat.canReact, isFalse);
      await chat.confirmReactions();
      expect(gateway.confirmCalls, 1);
      expect(chat.canReact, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(emitted, contains(ActiveChatEvent.reactionsChanged));
    },
  );

  test(
    'the probe runs once per chat and never when the server lacks it',
    () async {
      final gateway = _FakeDesktopGateway()
        ..available = false
        ..serverHasReactions = false;
      final chat = await _liveChat(gateway);
      await chat.confirmReactions();
      await chat.confirmReactions();
      expect(gateway.confirmCalls, 1);
      expect(chat.canReact, isFalse);
    },
  );

  test(
    'an inconclusive probe may be retried after the cooldown, not before',
    () async {
      final gateway = _FakeDesktopGateway()
        ..available = false
        ..serverHasReactions = false;
      final chat = await _liveChat(gateway);
      await chat.confirmReactions();
      await chat.confirmReactions();
      expect(gateway.confirmCalls, 1, reason: 'inside the cooldown');
      chat.reactionProbeRetryAfter = Duration.zero;
      gateway.serverHasReactions = true;
      await chat.confirmReactions();
      expect(gateway.confirmCalls, 2);
      expect(chat.canReact, isTrue);
    },
  );

  test(
    'reactions are offered only while the gateway says it can take them',
    () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      expect(chat.canReact, isTrue);
      gateway.available = false;
      expect(chat.canReact, isFalse);
    },
  );

  test(
    'a refusal that ends the capability repaints the chat without it',
    () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      final emitted = <ActiveChatEvent>[];
      final sub = chat.changes.listen(emitted.add);
      addTearDown(sub.cancel);
      final done = Completer<({int rowId, List<MessageReaction> reactions})>();
      gateway.pending = done;
      final future = chat.reactToMessage(rowId: 5, emoji: '👍');
      final failure = expectLater(future, throwsA(isA<StateError>()));
      emitted.clear();
      gateway.available = false;
      done.completeError(StateError('method not found'));
      await failure;
      expect(chat.canReact, isFalse);
      expect(emitted, contains(ActiveChatEvent.reactionsChanged));
    },
  );

  test('without a confirmed capability a reaction is not even sent', () async {
    final gateway = _FakeDesktopGateway();
    final chat = await _liveChat(gateway);
    gateway.available = false;
    await expectLater(
      chat.reactToMessage(rowId: 5, emoji: '👍'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(gateway.calls, isEmpty);
    expect(chat.reactionsFor(5), isEmpty);
  });

  test('tapping the same emoji retracts it', () async {
    final gateway = _FakeDesktopGateway();
    final chat = await _liveChat(gateway);
    gateway.pending =
        Completer<({int rowId, List<MessageReaction> reactions})>()..complete((
          rowId: 5,
          reactions: const [
            MessageReaction(emoji: '👍', author: MessageReactionAuthor.user),
          ],
        ));
    await chat.reactToMessage(rowId: 5, emoji: '👍');
    gateway.pending =
        Completer<({int rowId, List<MessageReaction> reactions})>();
    final future = chat.reactToMessage(rowId: 5, emoji: '👍');
    expect(chat.reactionsFor(5), isEmpty);
    gateway.pending!.complete((rowId: 5, reactions: const <MessageReaction>[]));
    await future;
  });

  test('a live agent reaction arrives as an event and repaints', () async {
    final gateway = _FakeDesktopGateway();
    final chat = await _liveChat(gateway);
    final emitted = <ActiveChatEvent>[];
    final sub = chat.changes.listen(emitted.add);
    addTearDown(sub.cancel);
    gateway.emit('message.reaction', {
      'row_id': 9,
      'role': 'assistant',
      'reactions': [
        {'emoji': '❤️', 'author': 'agent'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(chat.reactionsFor(9).single.author, MessageReactionAuthor.agent);
    expect(emitted, contains(ActiveChatEvent.reactionsChanged));
  });

  test('a malformed reaction event changes nothing', () async {
    final gateway = _FakeDesktopGateway();
    final chat = await _liveChat(gateway);
    final emitted = <ActiveChatEvent>[];
    final sub = chat.changes.listen(emitted.add);
    addTearDown(sub.cancel);
    gateway.emit('message.reaction', {'row_id': 'x', 'reactions': 3});
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isEmpty);
  });
}
