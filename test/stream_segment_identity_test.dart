// Hypothesis A, reproduced in this series: a reply chunk the server sends
// twice under a new sequence (reconnect replay, superseded attempt, second
// socket) was appended twice. Hermes 0.23.1 stamps every reply frame with
// its identity (public contract tui_gateway/stream_segments.py and
// contracts/events.py MessageDeltaPayload): `message.start` carries
// `turn_id`; `message.delta` `turn_id` + `segment` (interim seals before
// it) + `offset` (UTF-16 code units of that segment already sent);
// `message.interim` the `segment` it seals. A client applies only what it
// has not applied yet. Frames without a stamp (older servers) are unchanged.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/stream_segments.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

class _Gateway implements HermesDesktopGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast(sync: true);
  int _seq = 0;

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
    runtimeSessionId: 'runtime-seg',
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

  /// Every frame gets a NEW sequence, as a replay or a second socket does.
  void emit(String type, Map<String, dynamic> payload) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: 'runtime-seg',
      sequence: ++_seq,
      payload: Map<String, dynamic>.unmodifiable(payload),
    ),
  );

  void start([String turn = 'turn-1']) =>
      emit('message.start', {'turn_id': turn});
  void delta(String text, int segment, int offset, [String turn = 'turn-1']) =>
      emit('message.delta', {
        'text': text,
        'turn_id': turn,
        'segment': segment,
        'offset': offset,
      });
  void interim(String text, int segment, [String turn = 'turn-1']) =>
      emit('message.interim', {
        'text': text,
        'already_streamed': true,
        'turn_id': turn,
        'segment': segment,
      });
}

Future<ActiveChat> _chat(_Gateway gateway) async {
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-seg',
      label: 'Seg',
      host: 'example.invalid',
      port: 443,
      apiKey: 'unused',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-seg',
    sessionTitle: 'Seg',
    notifications: null,
    onTerminal: () {},
    api: testApiClient(
      baseUrl: 'https://example.invalid',
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

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 600));

/// The assistant text on screen, all rows joined.
String _assistant(ActiveChat chat) => chat.messages
    .where((row) => row['role'] == 'assistant')
    .map((row) => '${row['content'] ?? ''}')
    .join('\n');

int _count(ActiveChat chat, String token) =>
    token.allMatches(_assistant(chat)).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('[RED] the same chunk re-sent with a new sequence shows once', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    g.start();
    g.delta('ZQX1 alpha ', 0, 0);
    g.delta('ZQX1 alpha ', 0, 0);
    await _settle();
    expect(_count(chat, 'ZQX1'), 1, reason: _assistant(chat));
  });

  test('[RED] a replay of the start and the whole segment, after the seal, '
      'paints the narration once', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    const narration = 'ZQX2 checking the files first.';
    g.start();
    g.delta(narration.substring(0, 10), 0, 0);
    g.delta(narration.substring(10), 0, 10);
    await _settle();
    g.interim(narration, 0);
    // The superseded attempt / reconnect replay sends it all again.
    g.start();
    g.delta(narration.substring(0, 10), 0, 0);
    g.delta(narration.substring(10), 0, 10);
    g.interim(narration, 0);
    g.delta('ZQX3 final.', 1, 0);
    await _settle();
    expect(_count(chat, 'ZQX2'), 1, reason: _assistant(chat));
    expect(_count(chat, 'ZQX3'), 1, reason: _assistant(chat));
  });

  test('[RED] an overlapping re-send keeps only the unseen tail', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    g.start();
    g.delta('ZQX4 one ', 0, 0);
    g.delta('ZQX4 one two', 0, 0);
    await _settle();
    expect(_assistant(chat), contains('ZQX4 one two'));
    expect(_count(chat, 'ZQX4'), 1, reason: _assistant(chat));
  });

  test('[RED] offsets are UTF-16 code units (an emoji counts 2)', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    g.start();
    g.delta('ZQX5 😀 ', 0, 0); // 'ZQX5 ' (5) + 😀 (2) + ' ' (1) = 8 units
    g.delta('ZQX5 😀 ', 0, 0); // re-send: dropped
    g.delta('tail', 0, 8);
    await _settle();
    expect(_assistant(chat), contains('ZQX5 😀 tail'));
    expect(_count(chat, 'ZQX5'), 1, reason: _assistant(chat));
  });

  test('[CONTROL] an older server (no stamp) is unchanged: repeated text '
      'is appended as before', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    g.emit('message.start', const {});
    g.emit('message.delta', const {'text': 'ZQX6 '});
    g.emit('message.delta', const {'text': 'ZQX6 '});
    await _settle();
    expect(_count(chat, 'ZQX6'), 2, reason: _assistant(chat));
  });

  test('[CONTROL] text the agent genuinely repeats in a later segment '
      'stays twice', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    const line = 'ZQX7 same words.';
    g.start();
    g.delta(line, 0, 0);
    await _settle();
    g.interim(line, 0);
    g.delta(line, 1, 0);
    await _settle();
    expect(_count(chat, 'ZQX7'), 2, reason: _assistant(chat));
  });

  test('[CONTROL] a frame lost in between (gap) applies whole', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    g.start();
    g.delta('ZQX8 a', 0, 0);
    g.delta(' c', 0, 10); // 4 units never arrived
    await _settle();
    expect(_assistant(chat), contains('ZQX8 a c'));
  });

  test('[CONTROL] invalid stamps are ignored (treated as unstamped)', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    g.start();
    for (final bad in <Map<String, Object?>>[
      {'turn_id': 'turn-1', 'segment': -1, 'offset': 0},
      {'turn_id': 'turn-1', 'segment': 0, 'offset': -3},
      {'turn_id': '', 'segment': 0, 'offset': 0},
      {'turn_id': 'turn-1', 'segment': 1.5, 'offset': 0},
    ]) {
      g.emit('message.delta', {'text': 'ZQX9 ', ...bad});
    }
    await _settle();
    // segment -1 / '' turn / 1.5 → unstamped (applied); offset -3 → the
    // stamp keeps segment 0 with no valid offset (applied as offset 0).
    expect(_count(chat, 'ZQX9'), greaterThanOrEqualTo(3), reason: _assistant(chat));
  });

  test('[CONTROL] after the transcript is rebuilt from the server, a frame '
      'replayed after it is applied, never dropped', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    g.start();
    g.delta('ZQXh one ', 0, 0);
    await _settle();
    // A snapshot rebuild (it can be older than what was shown live).
    chat.debugEmitMessagesHydrated();
    g.delta('ZQXk two', 0, 9);
    await _settle();
    expect(_count(chat, 'ZQXk'), 1, reason: _assistant(chat));
  });

  test('[CONTROL] a new turn starts a new cursor', () async {
    final g = _Gateway();
    final chat = await _chat(g);
    g.start('turn-a');
    g.delta('ZQXa ', 0, 0, 'turn-a');
    g.start('turn-b');
    g.delta('ZQXb ', 0, 0, 'turn-b');
    await _settle();
    expect(_count(chat, 'ZQXb'), 1, reason: _assistant(chat));
  });

  group('ReplySegments.alignTo (review A1: a running snapshot drives the '
      'reply)', () {
    ReplyStamp d(int segment, int offset) => ReplyStamp('t', segment, offset);

    test('in segment 0 the cursor follows the snapshot both ways', () {
      final c = ReplySegments();
      expect(c.admitDelta(d(0, 0), 'abcde'), 'abcde');
      c.alignTo(3); // the screen now holds 'abc'
      expect(c.admitDelta(d(0, 3), 'de'), 'de', reason: 'beyond it applies');
      c.alignTo(9); // the snapshot holds more than was streamed here
      expect(c.admitDelta(d(0, 5), 'fgh'), '', reason: 'already on screen');
      expect(c.admitDelta(d(0, 9), 'X'), 'X');
    });

    test('a chat opened mid-turn: the floor counts for the first segment-0 '
        'frame only', () {
      final c = ReplySegments()..alignTo(4);
      expect(c.admitDelta(d(0, 0), 'abcd'), '', reason: 'in the snapshot');
      expect(c.admitDelta(d(0, 4), 'ef'), 'ef');
      final later = ReplySegments()..alignTo(4);
      expect(
        later.admitDelta(d(1, 0), 'new'),
        'new',
        reason: 'past a seal the floor says nothing about segment 1',
      );
    });

    test('past a seal the cursor is kept (Desktop parity)', () {
      final c = ReplySegments();
      c.admitDelta(d(0, 0), 'abc');
      expect(c.admitSeal(const ReplyStamp('t', 0)), isTrue);
      c.admitDelta(d(1, 0), 'xy');
      c.alignTo(100);
      expect(c.admitDelta(d(1, 2), 'z'), 'z', reason: 'cursor unchanged');
    });

    test('a turn boundary drops a pending floor; negatives are ignored', () {
      final c = ReplySegments()..alignTo(4);
      c.reset();
      expect(c.admitDelta(d(0, 0), 'abcd'), 'abcd');
      c.alignTo(-1);
      expect(c.admitDelta(d(0, 4), 'e'), 'e');
    });
  });
}
