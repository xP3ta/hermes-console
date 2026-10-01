import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_render_projection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/lc1215_long_session_fixture.dart';

/// Replays the SHAPE of a long Desktop session (QA 9478) through Console's
/// real transcript pipeline: Dashboard REST page (`order=latest`,
/// `include_compacted=true`), ActiveChat normalization/merge and the
/// ChatRenderProjection that builds the chat list. Every row Hermes Desktop
/// would paint must be reachable, once, in order.

class _DashboardTranscript {
  _DashboardTranscript(this.rows);

  final List<Map<String, dynamic>> rows;
  final requests = <Uri>[];
  bool healthy = true;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    if (!healthy) return http.Response('unavailable', 503);
    final limit = int.parse(request.url.queryParameters['limit'] ?? '500');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final start = math.max(0, end - limit);
    final page = rows.sublist(start, end);
    return http.Response(
      jsonEncode({
        'session_id': 'stored-chat',
        'profile': 'default',
        'messages': page,
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
  });
}

/// Hermes API server (:8642) `GET /api/sessions/{id}/messages`: it ignores
/// `include_compacted`, reads ACTIVE rows only and answers under `data`
/// (gateway/platforms/api_server.py `_handle_session_messages`).
class _ApiServerTranscript {
  _ApiServerTranscript(List<Map<String, dynamic>> displayRows)
    : rows = [
        for (final row in displayRows)
          if (row['active'] == 1) row,
      ];

  final List<Map<String, dynamic>> rows;
  final requests = <Uri>[];

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final limit = int.parse(request.url.queryParameters['limit'] ?? '500');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final start = math.max(0, end - limit);
    final page = rows.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': 'stored-chat',
        'data': page,
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
  });
}

ActiveChat _splitChat(
  _ApiServerTranscript api,
  _DashboardTranscript dashboard,
) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'lc1215-split',
    label: 'lc1215',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'test-key',
    kind: InstanceKind.vps,
  ),
  sessionId: 'stored-chat',
  sessionTitle: 'Long session',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'test-key',
    httpClient: api.client(),
  ),
  transcriptDashboard: DashboardClient(
    host: '127.0.0.1',
    manualToken: 'dashboard-token',
    httpClientOverride: dashboard.client(),
  ),
  allowUnownedDesktopSnapshotForTesting: true,
);

ActiveChat _chat(http.Client client) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'lc1215',
    label: 'lc1215',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'test-key',
    kind: InstanceKind.vps,
  ),
  sessionId: 'stored-chat',
  sessionTitle: 'Long session',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'test-key',
    httpClient: client,
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

Iterable<String> _markersOf(Map<String, dynamic> message) => RegExp(
  r'lc-row-\d+\b',
).allMatches('${message['content'] ?? ''}').map((match) => match.group(0)!);

/// Markers reachable from the rendered list, oldest first.
List<String> _renderedMarkers(List<Map<String, dynamic>> messages) {
  final projection = ChatRenderProjection.build(messages);
  final out = <String>[];
  for (final unit in projection.units.reversed) {
    final indexes = _unitIndexes(unit).toList()..sort((a, b) => b - a);
    if (unit is ChatToolActivityUnitPlan) continue;
    for (final index in indexes) {
      out.addAll(_markersOf(messages[index]));
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final shape = lc1215ShapeRows();

  test('shape fixture matches the captured session statistics', () {
    expect(shape, hasLength(1448));
    final counts = <String, int>{};
    for (final row in shape) {
      counts[row.code] = (counts[row.code] ?? 0) + 1;
    }
    expect(counts['U']! + counts['u']!, 86);
    expect(counts['t'], 242);
    expect(shape.where((row) => !row.active).length, greaterThan(1000));
  });

  test(
    'opening page paints every Desktop-visible row of the latest 500',
    () async {
      final server = _DashboardTranscript(lc1215DashboardRows(shape));
      final chat = _chat(server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: server.rows.length);

      final tail = shape.sublist(shape.length - 500);
      final expected = lc1215DesktopVisibleMarkers(tail);
      expect(_renderedMarkers(chat.messages), expected);
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'scrolling back reaches every Desktop-visible row once and in order',
    () async {
      final server = _DashboardTranscript(lc1215DashboardRows(shape));
      final chat = _chat(server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: server.rows.length);
      var guard = 0;
      while (chat.hasEarlierMessages && guard++ < 20) {
        await chat.loadEarlierMessages(continuePastInvisible: true);
      }

      expect(chat.hasEarlierMessages, isFalse);
      expect(
        _renderedMarkers(chat.messages),
        lc1215DesktopVisibleMarkers(shape),
      );
      final ids = chat.messages.map((m) => m['id']).whereType<int>().toList();
      expect(ids.toSet(), hasLength(ids.length));
    },
  );

  test('reasoning and tool calls of tool-only rows stay visible', () async {
    final server = _DashboardTranscript(lc1215DashboardRows(shape));
    final chat = _chat(server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: server.rows.length);
    var guard = 0;
    while (chat.hasEarlierMessages && guard++ < 20) {
      await chat.loadEarlierMessages(continuePastInvisible: true);
    }

    final projection = ChatRenderProjection.build(chat.messages);
    final rendered = <Map<String, dynamic>>[
      for (final unit in projection.units)
        if (unit is! ChatToolActivityUnitPlan)
          for (final index in _unitIndexes(unit)) chat.messages[index],
    ];
    final reasoning = rendered.map((m) => '${m['reasoning'] ?? ''}').join('\n');
    final toolIds = <String>{
      for (final message in rendered)
        for (final step in normalizeAssistantActivityTrace(
          message[assistantActivityTraceKey],
        ))
          if (step['kind'] == 'tool') '${step['id']}',
    };
    final missingReasoning = <int>[];
    final missingTools = <int>[];
    for (final row in shape) {
      if (row.code != 't' && row.code != 'a') continue;
      if (row.reasoning &&
          !RegExp('lc-reasoning-${row.index}\\b').hasMatch(reasoning)) {
        missingReasoning.add(row.index);
      }
      if (!toolIds.contains('toolu_${row.index}_0')) {
        missingTools.add(row.index);
      }
    }
    expect(missingReasoning, isEmpty);
    expect(missingTools, isEmpty);
  });

  test('compacted history the API server omits stays reachable through the '
      'Dashboard display read, like Desktop', () async {
    final rows = lc1215DashboardRows(shape);
    final api = _ApiServerTranscript(rows);
    final dashboard = _DashboardTranscript(rows);
    final chat = _splitChat(api, dashboard);
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: api.rows.length);
    // The API server page is terminal: on its own it would close history at
    // the last compaction boundary.
    expect(chat.hasEarlierMessages, isTrue);

    var guard = 0;
    while (chat.hasEarlierMessages && guard++ < 20) {
      await chat.loadEarlierMessages(continuePastInvisible: true);
    }
    expect(chat.hasEarlierMessages, isFalse);
    expect(_renderedMarkers(chat.messages), lc1215DesktopVisibleMarkers(shape));
    expect(
      dashboard.requests.map((uri) => uri.queryParameters['include_compacted']),
      everyElement('true'),
    );
  });

  test('a session without compactions never queries the Dashboard', () async {
    final rows = [
      for (final row in lc1215DashboardRows(shape))
        if (row['active'] == 1 && row['display_kind'] != 'hidden') row,
    ];
    final api = _ApiServerTranscript(rows);
    final dashboard = _DashboardTranscript(rows);
    final chat = _splitChat(api, dashboard);
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: rows.length);
    var guard = 0;
    while (chat.hasEarlierMessages && guard++ < 20) {
      await chat.loadEarlierMessages(continuePastInvisible: true);
    }
    expect(chat.hasEarlierMessages, isFalse);
    expect(dashboard.requests, isEmpty);
    expect(
      _renderedMarkers(chat.messages),
      lc1215DesktopVisibleMarkers(shape.where((row) => row.active)),
    );
  });

  test('display rows fewer than active rows re-anchor by row id without '
      'skipping archived history', () async {
    final rows = lc1215DashboardRows(shape);
    final api = _ApiServerTranscript(rows);
    // Model-only active rows exist in the API page but never in a display
    // read: the Dashboard counts three rows fewer above the boundary.
    final modelOnlyIds = <Object?>{
      for (final row in api.rows.where((row) => row['role'] == 'tool').take(3))
        row['id'],
    };
    final dashboard = _DashboardTranscript([
      for (final row in rows)
        if (!modelOnlyIds.contains(row['id'])) row,
    ]);
    final chat = _splitChat(api, dashboard);
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: api.rows.length);
    var guard = 0;
    while (chat.hasEarlierMessages && guard++ < 20) {
      await chat.loadEarlierMessages(continuePastInvisible: true);
    }
    expect(chat.hasEarlierMessages, isFalse);
    expect(_renderedMarkers(chat.messages), lc1215DesktopVisibleMarkers(shape));
  });

  test(
    'an unavailable Dashboard keeps the gateway transcript intact',
    () async {
      final rows = lc1215DashboardRows(shape);
      final api = _ApiServerTranscript(rows);
      final dashboard = _DashboardTranscript(rows)..healthy = false;
      final chat = _splitChat(api, dashboard);
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: api.rows.length);
      final before = _renderedMarkers(chat.messages);
      var guard = 0;
      while (chat.hasEarlierMessages && guard++ < 20) {
        await chat.loadEarlierMessages(continuePastInvisible: true);
      }
      expect(_renderedMarkers(chat.messages), before);
      expect(
        before,
        lc1215DesktopVisibleMarkers(shape.where((row) => row.active)),
      );
      expect(dashboard.requests, hasLength(lessThanOrEqualTo(4)));
    },
  );
}
