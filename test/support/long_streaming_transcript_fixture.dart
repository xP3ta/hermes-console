import 'dart:convert';

import 'package:hermes_android/core/services/session_reconciler.dart';

/// Deterministic newest-first transcript shaped like a long real session:
/// prose and code answers (some with `<` literals and inline think tags),
/// tool calls with large results, activity traces, reasoning, Responses API
/// sidecars and a dispatched delegation with its completion marker.
List<Map<String, dynamic>> longStreamingTranscriptNewestFirst({
  int turns = 75,
  int answerChars = 2400,
}) {
  final chronological = <Map<String, dynamic>>[];
  var id = 1;
  String prose(int turn) {
    final buffer = StringBuffer();
    var line = 0;
    while (buffer.length < answerChars) {
      buffer.write(switch (line % 6) {
        0 => '## Sección $turn.$line\n\n',
        1 => 'Texto de la respuesta $turn con **énfasis** y `código`.\n',
        2 => '- elemento $line de la lista con un [enlace](https://x.y)\n',
        3 => '```dart\nfinal v$line = $turn;\n```\n',
        4 =>
          turn.isEven ? 'Comparación a < b en HTML <div>$line</div>\n' : '\n',
        _ => 'Párrafo $line con tildes, ñ y emoji 🙂 para UTF-16.\n\n',
      });
      line++;
    }
    return buffer.toString();
  }

  for (var turn = 0; turn < turns; turn++) {
    chronological.add({
      'role': 'user',
      'content': 'Pregunta $turn: revisa el módulo $turn y explica.',
      'id': id,
      'message_id': 'm-${id++}',
      'timestamp': 1700000000 + turn * 60,
    });
    final callId = 'call-$turn';
    final delegate = turn == 3;
    chronological.add({
      'role': 'assistant',
      'content': '',
      'id': id,
      'message_id': 'm-${id++}',
      'tool_calls': [
        {
          'id': callId,
          'type': 'function',
          'function': {
            'name': delegate ? 'delegate_task' : 'read_file',
            'arguments': '{"path":"lib/m$turn.dart"}',
          },
        },
      ],
    });
    chronological.add({
      'role': 'tool',
      'tool_call_id': callId,
      'name': delegate ? 'delegate_task' : 'read_file',
      'id': id,
      'message_id': 'm-${id++}',
      'content': delegate
          ? jsonEncode({
              'status': 'dispatched',
              'delegation_id': 'deleg_0000abcd',
              'subagent_ids': ['sa-1', 'sa-2'],
            })
          : 'línea de archivo $turn\n' * 120,
    });
    final codex = turn % 10 == 7;
    chronological.add(
      {
        'role': 'assistant',
        'content': codex
            ? ''
            : turn % 9 == 5
            ? '<think>razono $turn</think>${prose(turn)}'
            : prose(turn),
        'id': id,
        'message_id': 'm-${id++}',
        'reasoning': turn % 3 == 0 ? 'Razonamiento $turn.' : null,
        if (codex)
          'codex_message_items': jsonEncode([
            {
              'type': 'message',
              'role': 'assistant',
              'phase': 'commentary',
              'content': [
                {'type': 'output_text', 'text': 'Comentario $turn'},
              ],
            },
            {
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': prose(turn)},
              ],
            },
          ]),
        assistantActivityTraceKey: [
          {
            'kind': 'tool',
            'label': delegate ? 'delegate_task' : 'read_file',
            'status': 'completed',
            'id': callId,
            'timestamp': 1700000000 + turn * 60,
          },
        ],
        '_activity_duration_seconds': 3,
      }..removeWhere((_, value) => value == null),
    );
    if (turn == 4) {
      chronological.add({
        'role': 'user',
        'display_kind': 'async_delegation_complete',
        'content': '[ASYNC DELEGATION COMPLETE — deleg_0000abcd]\nhecho',
        'display_metadata': {'delegation_id': 'deleg_0000abcd'},
        'id': id,
        'message_id': 'm-${id++}',
      });
    }
  }
  return chronological.reversed.toList(growable: true);
}
