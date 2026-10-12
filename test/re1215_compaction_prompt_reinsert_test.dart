// re1215 (QA 9481): an in-place compaction that runs in the middle of a turn
// re-inserts the turn's prompt into the new generation: same role, content
// and timestamp as the archived prompt, but a NEW, higher row id, after the
// summary. Console showed that prompt twice: once at its original place
// and again after the post-compaction assistant rows.
//
// Shape (ids, role, timestamp, length) from the owner's store:
//   464256 user 18:48:51 len 10      (the prompt, now compacted)
//   …      assistant/tool 18:56–19:01 (compacted)
//   464288 user 19:02:28 len 35545   (summary carrier, active)
//   464292 user 18:48:51 len 10      (SAME prompt, re-inserted, active)
//   464308 user 19:02:28 len 861     (post-compaction note, active)
//   …      assistant/tool 19:04–19:07 (active)
//
// Hermes folds display generations by (role, content, timestamp, tool
// fields) (`hermes_state_messages._display_dedupe_key`), so the Dashboard
// display read pages ONE logical prompt, represented by the live copy but
// ordered at the first copy's position. The API server (:8642) reads active
// rows only and returns the live copy after the summary.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_render_projection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _prompt = 'Vale hazlo';
const _promptTs = 1790000000.0; // "18:48:51"
const _compactionTs = _promptTs + 817; // "19:02:28"

Map<String, dynamic> _row(
  int id,
  String role,
  double ts,
  String content, {
  required bool active,
  String? displayKind,
  List<Map<String, dynamic>>? toolCalls,
  String? toolCallId,
  bool summary = false,
}) => {
  'id': id,
  'session_id': 'stored-qa9481',
  'role': role,
  'content': content,
  'timestamp': ts,
  'active': active ? 1 : 0,
  'compacted': active ? 0 : 1,
  'display_kind': displayKind,
  'tool_calls': toolCalls,
  'tool_call_id': toolCallId,
  'tool_name': toolCallId == null ? null : 'terminal',
  '_compressed_summary': summary ? 1 : 0,
};

List<Map<String, dynamic>> _call(String id) => [
  {
    'id': id,
    'type': 'function',
    'function': {'name': 'terminal', 'arguments': '{"command":"ls"}'},
  },
];

/// Every stored row of the session, in id order (both generations).
List<Map<String, dynamic>> _storedRows() {
  final rows = <Map<String, dynamic>>[];
  var id = 464000;
  // Older conversation before the prompt (compacted).
  for (var i = 0; i < 20; i++) {
    rows.add(
      _row(
        id++,
        i.isEven ? 'user' : 'assistant',
        _promptTs - 3600 + i,
        'older ${i.isEven ? 'question' : 'answer'} $i',
        active: false,
      ),
    );
  }
  id = 464256;
  rows.add(_row(id++, 'user', _promptTs, _prompt, active: false));
  for (var i = 0; i < 10; i++) {
    rows.add(
      _row(
        id++,
        'assistant',
        _promptTs + 420 + i * 30,
        '',
        active: false,
        toolCalls: _call('pre_$i'),
      ),
    );
    rows.add(
      _row(
        id++,
        'tool',
        _promptTs + 421 + i * 30,
        '{"output":"pre $i"}',
        active: false,
        toolCallId: 'pre_$i',
      ),
    );
  }
  id = 464288;
  rows.add(
    _row(
      id,
      'user',
      _compactionTs,
      '[CONTEXT COMPACTION] ${'s' * 35500}',
      active: true,
      summary: true,
    ),
  );
  id = 464292;
  rows.add(_row(id, 'user', _promptTs, _prompt, active: true));
  id = 464308;
  rows.add(
    _row(
      id++,
      'user',
      _compactionTs,
      '[System: context was compacted; continue the task] ${'n' * 800}',
      active: true,
      displayKind: 'hidden',
    ),
  );
  for (var i = 0; i < 6; i++) {
    rows.add(
      _row(
        id++,
        'assistant',
        _compactionTs + 100 + i * 30,
        '',
        active: true,
        toolCalls: _call('post_$i'),
      ),
    );
    rows.add(
      _row(
        id++,
        'tool',
        _compactionTs + 101 + i * 30,
        '{"output":"post $i"}',
        active: true,
        toolCallId: 'post_$i',
      ),
    );
  }
  rows.add(
    _row(
      id++,
      'assistant',
      _compactionTs + 300,
      'Respuesta final',
      active: true,
    ),
  );
  return rows;
}

/// `hermes_state_messages._dedupe_display_generations`: one row per
/// (role, content, timestamp, tool fields), the live copy wins, ordered by
/// the logical message's FIRST row id.
List<Map<String, dynamic>> _displayRows(List<Map<String, dynamic>> stored) {
  final seen = <String, Map<String, dynamic>>{};
  final firstId = <String, int>{};
  for (final row in stored) {
    final key = jsonEncode([
      row['role'],
      row['content'],
      row['timestamp'],
      row['tool_call_id'],
      row['tool_calls'],
      row['tool_name'],
    ]);
    final current = seen[key];
    final rank = [row['active'] as int, row['id'] as int];
    if (current == null ||
        rank[0] > (current['active'] as int) ||
        (rank[0] == current['active'] && rank[1] > (current['id'] as int))) {
      seen[key] = row;
    }
    firstId[key] = math.min(firstId[key] ?? row['id'] as int, row['id'] as int);
  }
  final keys = seen.keys.toList()
    ..sort((a, b) => firstId[a]!.compareTo(firstId[b]!));
  return [for (final key in keys) seen[key]!];
}

/// API server projection: a pure compaction handoff becomes an empty
/// `display_kind=hidden` row with its id (`_project_client_message`).
Map<String, dynamic> _apiProjection(Map<String, dynamic> row) =>
    row['_compressed_summary'] == 1
    ? {...row, 'content': '', 'display_kind': 'hidden'}
    : row;

http.Response _page(
  List<Map<String, dynamic>> rows,
  Uri url, {
  required String key,
}) {
  final limit = int.parse(url.queryParameters['limit'] ?? '500');
  final offset = int.parse(url.queryParameters['offset'] ?? '0');
  final end = math.max(0, rows.length - offset);
  final start = math.max(0, end - limit);
  final page = rows.sublist(start, end);
  return http.Response(
    jsonEncode({
      'session_id': 'stored-qa9481',
      key: page,
      'pagination': {
        'limit': limit,
        'offset': offset,
        'order': 'latest',
        'returned': page.length,
      },
    }),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

ActiveChat _chat({
  required List<Map<String, dynamic>> apiRows,
  required List<Map<String, dynamic>> dashboardRows,
}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  transcriptPageSizeForTesting: 20,
  connection: SavedConnection(
    id: 'qa9481',
    label: 'qa9481',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'k',
    kind: InstanceKind.vps,
  ),
  sessionId: 'stored-qa9481',
  sessionTitle: 'QA 9481',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'k',
    httpClient: MockClient(
      (request) async => _page(apiRows, request.url, key: 'data'),
    ),
  ),
  transcriptDashboard: DashboardClient(
    host: '127.0.0.1',
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient(
      (request) async => _page(dashboardRows, request.url, key: 'messages'),
    ),
  ),
  allowUnownedDesktopSnapshotForTesting: true,
);

Iterable<int> _unitIndexes(ChatRenderUnitPlan unit) => switch (unit) {
  ChatMessageUnitPlan(:final messageIndex) => [messageIndex],
  ChatUserTurnUnitPlan(
    :final primaryMessageIndex,
    :final supplementMessageIndexes,
  ) =>
    [primaryMessageIndex, ...supplementMessageIndexes],
  ChatToolActivityUnitPlan(:final messageIndexes) => messageIndexes,
};

/// User bubbles the chat list paints, oldest first.
List<Map<String, dynamic>> _renderedUserBubbles(
  List<Map<String, dynamic>> messages,
) {
  final projection = ChatRenderProjection.build(messages);
  return [
    for (final unit in projection.units.reversed)
      if (unit is! ChatToolActivityUnitPlan)
        for (final index in _unitIndexes(unit))
          if (messages[index]['role'] == 'user' &&
              (messages[index]['display_kind'] ?? '') == '')
            messages[index],
  ];
}

Future<void> _scrollToStart(ActiveChat chat) async {
  var guard = 0;
  while (chat.hasEarlierMessages && guard++ < 30) {
    await chat.loadEarlierMessages(continuePastInvisible: true);
  }
  expect(chat.hasEarlierMessages, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final stored = _storedRows();
  final active = [
    for (final row in stored)
      if (row['active'] == 1) _apiProjection(row),
  ];

  for (final (label, dashboard) in [
    ('Dashboard folds generations', _displayRows(stored)),
    ('Dashboard returns both generations', [for (final row in stored) row]),
  ]) {
    test('QA 9481 ($label): the re-inserted prompt is painted once, at its '
        'original place, before the post-compaction work', () async {
      final chat = _chat(apiRows: active, dashboardRows: dashboard);
      addTearDown(chat.dispose);
      await chat.loadMessages(expectedMessageCount: active.length);
      await _scrollToStart(chat);

      final bubbles = _renderedUserBubbles(chat.messages);
      final prompts = bubbles.where((m) => m['content'] == _prompt).toList();
      // ignore: avoid_print
      print(
        '[qa9481] $label: prompt bubbles='
        '${prompts.map((m) => m['id']).toList()} '
        'rows=${chat.messages.length}',
      );
      final chronological0 = chat.messages.reversed.toList();
      // ignore: avoid_print
      print(
        '[qa9481] $label order: '
        '${chronological0.map((m) => m['role'] == 'user'
            ? 'U${m['id']}'
            : m['role'] == 'tool'
            ? 't'
            : 'a').join(' ')}',
      );
      expect(prompts, hasLength(1), reason: 'one prompt bubble');

      // Chronology: the prompt precedes every assistant row of its turn,
      // including the ones written after the compaction.
      final chronological = chat.messages.reversed.toList();
      final promptAt = chronological.indexWhere(
        (m) => m['role'] == 'user' && m['content'] == _prompt,
      );
      final finalAt = chronological.indexWhere(
        (m) => m['content'] == 'Respuesta final',
      );
      expect(promptAt, isNonNegative);
      expect(finalAt, greaterThan(promptAt));
      // The work done before the compaction belongs to this turn too.
      final preWorkAt = chronological.indexWhere(
        (m) =>
            m['content'] == '{"output":"pre 0"}' ||
            m['tool_call_id'] == 'pre_0',
      );
      if (preWorkAt >= 0) expect(preWorkAt, greaterThan(promptAt));
      expect(chronological[promptAt + 1]['role'], 'assistant');
      final carrierAt = chronological.indexWhere((m) => m['id'] == 464288);
      if (carrierAt >= 0) expect(carrierAt, greaterThan(promptAt + 1));
      final olderAt = chronological.indexWhere(
        (m) => m['content'] == 'older answer 19',
      );
      expect(olderAt, lessThan(promptAt));
      expect(
        chronological.where((m) => m['content'] == 'Respuesta final'),
        hasLength(1),
      );
      final ids = chat.messages.map((m) => m['id']).whereType<int>().toList();
      expect(ids.toSet(), hasLength(ids.length));
    });
  }

  test(
    'QA 9481 in one page: a read holding both copies paints one prompt',
    () async {
      // A Dashboard that does not fold generations, both copies on one page.
      final chat = _chat(apiRows: stored, dashboardRows: stored);
      addTearDown(chat.dispose);
      await chat.loadMessages(expectedMessageCount: stored.length);
      await _scrollToStart(chat);
      final prompts = _renderedUserBubbles(
        chat.messages,
      ).where((m) => m['content'] == _prompt).toList();
      expect(prompts, hasLength(1));
      expect(prompts.single['id'], 464292);
      final chronological = chat.messages.reversed.toList();
      final promptAt = chronological.indexOf(prompts.single);
      // The turn's work from before the compaction follows its prompt and
      // precedes the summary, as Hermes orders the display.
      expect(chronological[promptAt + 1]['role'], 'assistant');
      final carrierAt = chronological.indexWhere((m) => m['id'] == 464288);
      if (carrierAt >= 0) expect(carrierAt, greaterThan(promptAt + 1));
    },
  );

  test(
    'a prompt repeated after a compaction with a NEW timestamp stays',
    () async {
      final rows = <Map<String, dynamic>>[
        _row(1, 'user', _promptTs, _prompt, active: false),
        _row(2, 'assistant', _promptTs + 5, 'Primera', active: false),
        _row(
          3,
          'user',
          _compactionTs,
          '[CONTEXT COMPACTION] s',
          active: true,
          summary: true,
        ),
        _row(4, 'user', _compactionTs + 60, _prompt, active: true),
        _row(5, 'assistant', _compactionTs + 65, 'Segunda', active: true),
      ];
      final chat = _chat(apiRows: rows, dashboardRows: rows);
      addTearDown(chat.dispose);
      await chat.loadMessages(expectedMessageCount: rows.length);
      await _scrollToStart(chat);
      expect(
        _renderedUserBubbles(
          chat.messages,
        ).where((m) => m['content'] == _prompt),
        hasLength(2),
      );
    },
  );

  test('identical prompt rows with the same timestamp and no compaction '
      'between them are never folded', () async {
    final rows = <Map<String, dynamic>>[
      _row(
        1,
        'user',
        _compactionTs - 10,
        '[CONTEXT COMPACTION] s',
        active: true,
        summary: true,
      ),
      _row(2, 'user', _promptTs, _prompt, active: true),
      _row(3, 'assistant', _promptTs, 'Primera', active: true),
      _row(4, 'user', _promptTs, _prompt, active: true),
      _row(5, 'assistant', _promptTs + 1, 'Segunda', active: true),
    ];
    final chat = _chat(apiRows: rows, dashboardRows: rows);
    addTearDown(chat.dispose);
    await chat.loadMessages(expectedMessageCount: rows.length);
    await _scrollToStart(chat);
    expect(
      _renderedUserBubbles(chat.messages).where((m) => m['content'] == _prompt),
      hasLength(2),
    );
  });

  test(
    'two genuinely identical prompts sent at different times both stay',
    () async {
      final rows = <Map<String, dynamic>>[
        _row(1, 'user', _promptTs, _prompt, active: true),
        _row(2, 'assistant', _promptTs + 5, 'Primera', active: true),
        _row(3, 'user', _promptTs + 60, _prompt, active: true),
        _row(4, 'assistant', _promptTs + 65, 'Segunda', active: true),
      ];
      final chat = _chat(apiRows: rows, dashboardRows: rows);
      addTearDown(chat.dispose);
      await chat.loadMessages(expectedMessageCount: rows.length);
      await _scrollToStart(chat);
      expect(
        _renderedUserBubbles(
          chat.messages,
        ).where((m) => m['content'] == _prompt),
        hasLength(2),
      );
      expect(chat.messages.map((m) => m['content']).toList(), [
        'Segunda',
        _prompt,
        'Primera',
        _prompt,
      ]);
    },
  );

  test('three copies across two compactions keep the live copy once, at the '
      'first copy\'s place', () async {
    // Two mid-turn compactions re-insert the prompt twice: first, an
    // intermediate copy (compacted again) and the live one.
    final rows = <Map<String, dynamic>>[
      _row(1, 'user', _promptTs - 60, 'Antes', active: false),
      _row(2, 'assistant', _promptTs - 55, 'Previa', active: false),
      _row(10, 'user', _promptTs, _prompt, active: false),
      _row(11, 'assistant', _promptTs + 10, 'Trabajo 1', active: false),
      _row(
        12,
        'user',
        _compactionTs,
        '[CONTEXT COMPACTION] uno',
        active: false,
        summary: true,
      ),
      _row(13, 'user', _promptTs, _prompt, active: false),
      _row(14, 'assistant', _compactionTs + 10, 'Trabajo 2', active: false),
      _row(
        15,
        'user',
        _compactionTs + 100,
        '[CONTEXT COMPACTION] dos',
        active: true,
        summary: true,
      ),
      _row(16, 'user', _promptTs, _prompt, active: true),
      _row(
        17,
        'assistant',
        _compactionTs + 110,
        'Respuesta final',
        active: true,
      ),
    ];
    final chat = _chat(apiRows: rows, dashboardRows: rows);
    addTearDown(chat.dispose);
    await chat.loadMessages(expectedMessageCount: rows.length);
    await _scrollToStart(chat);
    final prompts = _renderedUserBubbles(
      chat.messages,
    ).where((m) => m['content'] == _prompt).toList();
    expect(prompts, hasLength(1));
    expect(prompts.single['id'], 16, reason: 'the live copy represents it');
    final chronological = chat.messages.reversed.toList();
    final promptAt = chronological.indexOf(prompts.single);
    final previaAt = chronological.indexWhere((m) => m['content'] == 'Previa');
    final work1At = chronological.indexWhere(
      (m) => m['content'] == 'Trabajo 1',
    );
    expect(previaAt, lessThan(promptAt));
    expect(work1At, promptAt + 1, reason: "at the first copy's place");
    final ids = chat.messages.map((m) => m['id']).whereType<int>().toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.where((id) => id == 13 || id == 10), isEmpty);
  });

  test('an older page that overlaps a normal prompt sent after a compaction '
      'leaves it after the summary, once', () async {
    final rows = <Map<String, dynamic>>[
      for (var i = 0; i < 30; i++)
        _row(
          100 + i,
          i.isEven ? 'user' : 'assistant',
          _promptTs - 3600 + i,
          'older ${i.isEven ? 'question' : 'answer'} $i',
          active: false,
        ),
      _row(
        200,
        'user',
        _compactionTs,
        '[CONTEXT COMPACTION] s',
        active: true,
        summary: true,
      ),
      _row(201, 'user', _compactionTs + 60, 'Nuevo prompt', active: true),
      for (var i = 0; i < 18; i++)
        _row(
          202 + i,
          'assistant',
          _compactionTs + 61 + i,
          'post $i',
          active: true,
        ),
    ];
    final chat = _chat(apiRows: rows, dashboardRows: rows);
    addTearDown(chat.dispose);
    await chat.loadMessages(expectedMessageCount: rows.length);
    expect(
      chat.messages.last['id'],
      200,
      reason: 'the tail ends on the carrier',
    );
    // Rows land after the opening read: the next older page, read by offset,
    // overlaps the carrier and the prompt that follows it.
    for (var i = 0; i < 2; i++) {
      rows.add(
        _row(
          300 + i,
          'assistant',
          _compactionTs + 200 + i,
          'late $i',
          active: true,
        ),
      );
    }
    await _scrollToStart(chat);
    final chronological = chat.messages.reversed.toList();
    final ids = chronological.map((m) => m['id']).whereType<int>().toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.where((id) => id == 201), hasLength(1));
    final carrierAt = ids.indexOf(200);
    final promptAt = ids.indexOf(201);
    // ignore: avoid_print
    print(
      '[re1215] overlap order around carrier: '
      '${ids.sublist(math.max(0, carrierAt - 2), math.min(ids.length, promptAt + 3))}',
    );
    expect(carrierAt, isNonNegative);
    expect(
      promptAt,
      carrierAt + 1,
      reason: 'the prompt stays after the summary',
    );
    expect(ids.indexOf(202), promptAt + 1);
    final sorted = [...ids]..sort();
    expect(ids, sorted, reason: 'nothing is reordered');
  });
}
