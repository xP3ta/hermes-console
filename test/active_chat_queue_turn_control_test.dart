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

    test('promoting the second row over the head in flight is refused', () async {
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
    });
  });
}
