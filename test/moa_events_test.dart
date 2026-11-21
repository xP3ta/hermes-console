// `moa.*` events (Hermes `tui_gateway/contracts/events.py`; Desktop
// `gateway-event/message-stream.ts`): a mixture-of-agents turn shows its
// progress and its reference answers as labelled lines of the turn's
// reasoning, the first line of each kind replacing the stale trail, and the
// turn ends as any other.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/desktop_chat_socket.dart';
import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

/// The reasoning of the turn in the transcript, as the user can open it.
String _reasoning(ActiveChat chat) => chat.messages
    .map((row) => '${row['reasoning'] ?? ''}'.trim())
    .where((text) => text.isNotEmpty)
    .join('\n');

Future<(ActiveChat, DesktopChatSocket, List<ActiveChatEvent>)> _open() async {
  SharedPreferences.setMockInitialValues({});
  final socket = DesktopChatSocket();
  addTearDown(socket.close);
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-moa',
      label: 'moa',
      host: 'example.invalid',
      port: 443,
      apiKey: 'unused',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-moa',
    sessionTitle: 'moa',
    notifications: null,
    onTerminal: () {},
    api: testApiClient(
      baseUrl: 'https://example.invalid',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: socket,
    storedMessageLoader: (_, _) async => const [
      {'role': 'user', 'content': 'hola'},
      {'role': 'assistant', 'content': 'Final answer'},
    ],
    terminalReconcileBudget: Duration.zero,
  );
  addTearDown(chat.dispose);
  expect(
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
    isTrue,
  );
  final emitted = <ActiveChatEvent>[];
  final subscription = chat.changes.listen(emitted.add);
  addTearDown(subscription.cancel);
  socket.emit('message.start');
  await pumpEventQueue();
  emitted.clear();
  return (chat, socket, emitted);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('progress, references and the aggregator build the reasoning as '
      'Desktop does, and the turn then ends cleanly', () async {
    final (chat, socket, emitted) = await _open();

    socket.emit('reasoning.delta', {'text': 'stale thought'});
    await pumpEventQueue();
    expect(_reasoning(chat), 'stale thought');

    // The first progress line replaces what the reasoning held; the next
    // ones follow it.
    socket.emit('moa.progress', {
      'label': 'model-a',
      'refs_done': 1,
      'refs_total': 3,
    });
    await pumpEventQueue();
    expect(_reasoning(chat), '◇ MoA refs 1/3 — model-a');
    expect(emitted, contains(ActiveChatEvent.toolProgress));
    expect(chat.state, ChatPipelineState.executing);

    socket.emit('moa.progress', {
      'label': 'model-b',
      'refs_done': 2,
      'refs_total': 3,
    });
    socket.emit('moa.progress', {'label': '', 'refs_done': 3, 'refs_total': 3});
    socket.emit('moa.phase', {'phase': 'aggregator'});
    await pumpEventQueue();
    expect(
      _reasoning(chat),
      '◇ MoA refs 1/3 — model-a\n'
      '◇ MoA refs 2/3 — model-b\n'
      '◇ MoA refs 3/3\n'
      '◇ MoA aggregating…',
    );

    // The first reference replaces the whole trail; later ones accumulate.
    socket.emit('moa.reference', {
      'label': 'model-a',
      'text': 'Alpha says 42',
      'index': 1,
      'count': 2,
    });
    await pumpEventQueue();
    expect(_reasoning(chat), '◇ Reference 1/2 — model-a\nAlpha says 42');
    socket.emit('moa.reference', {
      'label': 'model-b',
      'text': 'Beta says 43',
      'index': 2,
      'count': 2,
    });
    await pumpEventQueue();
    expect(
      _reasoning(chat),
      '◇ Reference 1/2 — model-a\nAlpha says 42\n\n'
      '◇ Reference 2/2 — model-b\nBeta says 43',
    );

    // The aggregator starting changes nothing the user sees.
    final before = _reasoning(chat);
    emitted.clear();
    socket.emit('moa.aggregating', {'aggregator': 'model-big'});
    await pumpEventQueue();
    expect(_reasoning(chat), before);
    expect(emitted, isEmpty);

    // Its reply is a normal message and the turn ends once.
    socket.emit('message.delta', {'text': 'Final answer'});
    socket.emit('message.complete', {
      'text': 'Final answer',
      'status': 'complete',
    });
    await pumpEventQueue(times: 50);
    expect(chat.isStreaming, isFalse);
    expect(chat.state, ChatPipelineState.completed);
    expect(
      chat.messages.where((row) => row['content'] == 'Final answer'),
      hasLength(1),
    );
  });

  test('a replace never wipes a reply that already has text', () async {
    final (chat, socket, emitted) = await _open();

    socket.emit('message.delta', {'text': 'Hello'});
    await pumpEventQueue();
    emitted.clear();
    socket.emit('moa.progress', {
      'label': 'model-a',
      'refs_done': 1,
      'refs_total': 2,
    });
    socket.emit('moa.reference', {
      'label': 'model-a',
      'text': 'Alpha',
      'index': 1,
      'count': 2,
    });
    await pumpEventQueue();
    expect(_reasoning(chat), isEmpty);
    expect(chat.assistantContent, contains('Hello'));
    expect(emitted, isNot(contains(ActiveChatEvent.toolProgress)));

    // An appended line still lands, as Desktop's does.
    socket.emit('moa.phase', {'phase': 'aggregator'});
    await pumpEventQueue();
    expect(_reasoning(chat), '◇ MoA aggregating…');
  });

  test('a reference without a number or a label is still a block', () async {
    final (chat, socket, _) = await _open();

    socket.emit('moa.reference', {'text': 'Unnumbered'});
    await pumpEventQueue();
    expect(_reasoning(chat), '◇ Reference — reference\nUnnumbered');

    // A zero index is no index in Desktop either (`idx && cnt`).
    socket.emit('moa.reference', {
      'label': 'zero',
      'text': 'Zeroth',
      'index': 0,
      'count': 2,
    });
    await pumpEventQueue();
    expect(_reasoning(chat), '◇ Reference — zero\nZeroth');
  });

  test('frames that carry nothing to show leave the turn alone', () async {
    final (chat, socket, emitted) = await _open();

    socket.emit('moa.progress', {
      'label': 'model-a',
      'refs_done': '1',
      'refs_total': 2,
    });
    socket.emit('moa.progress', {'label': 'model-a'});
    socket.emit('moa.phase', {'phase': 'fan_out', 'refs_done': 1});
    socket.emit('moa.phase', {'refs_done': 1});
    await pumpEventQueue();

    expect(_reasoning(chat), isEmpty);
    expect(emitted, isEmpty);
    expect(chat.isStreaming, isTrue);
  });

  test('a frame after the turn ended does not reopen it', () async {
    final (chat, socket, emitted) = await _open();
    socket.emit('message.delta', {'text': 'Final answer'});
    socket.emit('message.complete', {
      'text': 'Final answer',
      'status': 'complete',
    });
    await pumpEventQueue(times: 50);
    expect(chat.isStreaming, isFalse);
    emitted.clear();

    socket.emit('moa.progress', {
      'label': 'late',
      'refs_done': 1,
      'refs_total': 2,
    });
    socket.emit('moa.reference', {
      'label': 'late',
      'text': 'Late',
      'index': 1,
      'count': 2,
    });
    await pumpEventQueue();

    expect(chat.isStreaming, isFalse);
    expect(_reasoning(chat), isNot(contains('late')));
    expect(emitted, isNot(contains(ActiveChatEvent.toolProgress)));
  });
}
