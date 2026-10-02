import 'dart:convert';
import 'dart:math' as math;

import 'lc1215_long_session_shape.dart';

export 'lc1215_long_session_shape.dart';

/// Builders over the shape-only capture. Every string is synthetic; a row's
/// public text carries `lc-row-<index>` so tests can track it.

class Lc1215Row {
  final int index;
  final String code;
  final bool active;
  final bool reasoning;
  final int toolCalls;
  final bool large;

  const Lc1215Row(
    this.index,
    this.code,
    this.active,
    this.reasoning,
    this.toolCalls,
    this.large,
  );
}

List<Lc1215Row> lc1215ShapeRows() {
  final codes = (lc1215ShapeCodes);
  final active = (lc1215ShapeActive);
  final reasoning = (lc1215ShapeReasoning);
  final calls = (lc1215ShapeToolCallCounts);
  final large = (lc1215ShapeLargeContent);
  return [
    for (var i = 0; i < codes.length; i++)
      Lc1215Row(
        i,
        codes[i],
        active[i] == '1',
        reasoning[i] == 'r',
        int.parse(calls[i]),
        large[i] == 'L',
      ),
  ];
}

String _body(String marker, bool large) => large
    ? '$marker\n\n${List.filled(400, 'synthetic filler line for size').join('\n')}'
    : marker;

/// Synthetic rows with the same field shapes as the Dashboard projection.
List<Map<String, dynamic>> lc1215DashboardRows(List<Lc1215Row> shape) {
  final rows = <Map<String, dynamic>>[];
  final pendingCallIds = <String>[];
  var id = 447793;
  for (final row in shape) {
    final marker = 'lc-row-${row.index}';
    final base = <String, dynamic>{
      'id': id++,
      'session_id': 'stored-chat',
      'timestamp': 1790000000.0 + row.index ~/ 2,
      'active': row.active ? 1 : 0,
      'compacted': row.active ? 0 : 1,
      'display_order': 447793 + row.index,
      'finish_reason': null,
      'tool_calls': null,
      'reasoning': row.reasoning ? 'lc-reasoning-${row.index}' : null,
      'reasoning_content': row.reasoning ? 'lc-reasoning-${row.index}' : null,
      'reasoning_details': row.reasoning ? '[]' : null,
      'display_kind': null,
      'display_metadata': null,
      '_compressed_summary': 0,
      'api_content': null,
      'codex_message_items': null,
      'codex_reasoning_items': null,
      'observed': 0,
      'platform_message_id': null,
      'effect_disposition': null,
      'token_count': null,
      'tool_call_id': null,
      'tool_name': null,
    };
    List<Map<String, dynamic>> calls(int count) => [
      for (var c = 0; c < math.max(1, count); c++)
        {
          'id': 'toolu_${row.index}_$c',
          'call_id': 'toolu_${row.index}_$c',
          'response_item_id': 'fc_${row.index}_$c',
          'type': 'function',
          'function': {
            'name': c.isEven ? 'terminal' : 'vision_analyze',
            'arguments': jsonEncode({'command': 'echo $c'}),
          },
        },
    ];
    switch (row.code) {
      case 'U':
        rows.add({...base, 'role': 'user', 'content': _body(marker, false)});
      case 'u':
        rows.add({
          ...base,
          'role': 'user',
          'content':
              '[📎 synthetic_screenshot.png · 42.0 KB]\n$marker\n'
              '@image:/tmp/synthetic/lc_${row.index}.png\n[screenshot]',
        });
      case 'A':
        rows.add({
          ...base,
          'role': 'assistant',
          'content': _body(marker, row.large),
          'finish_reason': 'stop',
        });
      case 'a':
      case 't':
        final made = calls(row.toolCalls);
        pendingCallIds.addAll(made.map((call) => call['id'] as String));
        rows.add({
          ...base,
          'role': 'assistant',
          'content': row.code == 'a' ? _body(marker, row.large) : '',
          'tool_calls': made,
          'finish_reason': 'tool_calls',
        });
      case 'T':
        final callId = pendingCallIds.isEmpty
            ? 'orphan_${row.index}'
            : pendingCallIds.removeAt(0);
        rows.add({
          ...base,
          'role': 'tool',
          'content': row.large
              ? _body('{"output": "tool-$marker"}', true)
              : '{"output": "tool-$marker", "exit_code": 0}',
          'tool_call_id': callId,
          'tool_name': 'terminal',
        });
      case 'H':
        rows.add({
          ...base,
          'role': row.index.isEven ? 'assistant' : 'user',
          'content': '',
          'display_kind': 'hidden',
        });
      case 'C':
        rows.add({
          ...base,
          'role': 'assistant',
          'content': '[PRIOR CONTEXT — synthetic carrier]\n${_body('x', true)}',
          'display_content': marker,
          '_compressed_summary': 1,
          'tool_calls': calls(1),
          'finish_reason': 'tool_calls',
        });
      case 'K':
        rows.add({
          ...base,
          'role': 'user',
          'content': '[System: synthetic auto continue] $marker',
          'display_kind': 'auto_continue',
        });
      case 'S':
        rows.add({
          ...base,
          'role': 'user',
          'content': '[OUT-OF-BAND USER MESSAGE — synthetic]\n$marker',
          'display_kind': 'steer',
        });
      case 'P':
        rows.add({
          ...base,
          'role': 'user',
          'content':
              '[IMPORTANT: Background process proc_0123456789ab exited '
              '(exit code 0).\n$marker',
          'display_kind': 'process_complete',
          'display_metadata': {'display_text': 'Background process finished'},
        });
      default:
        throw StateError('unknown shape code ${row.code}');
    }
  }
  return rows;
}

/// The same rows as `session.history` projects them: ACTIVE rows only (the
/// RPC reads the model history, not compacted display generations), text in
/// `text`, tool rows reduced to name/context, no assistant `tool_calls`.
List<Map<String, dynamic>> lc1215NativeHistoryRows(
  List<Map<String, dynamic>> dashboardRows,
) {
  final out = <Map<String, dynamic>>[];
  for (final row in dashboardRows) {
    if (row['active'] != 1) continue;
    if (row['display_kind'] == 'hidden') continue;
    if (row['_compressed_summary'] == 1 && row['display_content'] == null) {
      continue;
    }
    final role = row['role'] as String;
    if (role == 'tool') {
      out.add({
        'role': 'tool',
        'name': row['tool_name'],
        'context': 'echo',
        'tool_call_id': row['tool_call_id'],
        'timestamp': row['timestamp'],
      });
      continue;
    }
    final text = '${row['display_content'] ?? row['content']}';
    final hasDetail = role == 'assistant' && row['reasoning'] != null;
    if (text.trim().isEmpty && !hasDetail) continue;
    out.add({
      'role': role,
      'text': text,
      'timestamp': row['timestamp'],
      'row_id': row['id'],
      if (hasDetail) ...{
        'reasoning': row['reasoning'],
        'reasoning_content': row['reasoning_content'],
        'reasoning_details': row['reasoning_details'],
      },
      if (row['display_kind'] != null) 'display_kind': row['display_kind'],
      if (row['display_metadata'] != null)
        'display_metadata': row['display_metadata'],
    });
  }
  return out;
}

/// Markers Desktop paints as their own bubble/notice, oldest first.
List<String> lc1215DesktopVisibleMarkers(Iterable<Lc1215Row> shape) => [
  for (final row in shape)
    if (const {'U', 'u', 'A', 'a', 'C', 'K', 'S', 'P'}.contains(row.code))
      'lc-row-${row.index}',
];
