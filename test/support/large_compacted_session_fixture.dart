import 'dart:convert';
import 'dart:math' as math;

/// Sintético con la forma de una sesión larga y muy compactada (QA 9340:
/// 791 filas, mayoría `compacted=1, active=0`, markdown largo, tool rows,
/// marcadores de delegación y la fila «STILL IN PROGRESS» reenunciada tras
/// la frontera de compactación). Contenido inventado: nunca texto real.
///
/// Devuelve la página REST en orden cronológico (como `order=latest`).
List<Map<String, dynamic>> largeCompactedSessionPage({
  int rows = 500,
  int compacted = 450,
  int seed = 9340,
}) {
  final random = math.Random(seed);
  final out = <Map<String, dynamic>>[];
  var id = 1000;
  var call = 0;
  var turn = 0;

  String paragraph(int words) => List.generate(
    words,
    (i) => const [
      'transcript',
      'proyección',
      'identidad',
      'compactación',
      '**negrita**',
      '`código`',
      'render',
      'viewport',
      'cursor',
      'fila',
    ][(i * 7 + words) % 10],
  ).join(' ');

  String markdown(int size) {
    final buffer = StringBuffer()
      ..writeln('## Resultado ${turn++}')
      ..writeln();
    var section = 0;
    while (buffer.length < size) {
      switch (section++ % 5) {
        case 0:
          buffer
            ..writeln(paragraph(40 + random.nextInt(40)))
            ..writeln();
        case 1:
          for (var i = 0; i < 4; i++) {
            buffer.writeln('- ${paragraph(10)}');
          }
          buffer.writeln();
        case 2:
          buffer
            ..writeln('| Clave | Valor | Nota |')
            ..writeln('| --- | --- | --- |');
          for (var i = 0; i < 4; i++) {
            buffer.writeln('| k$i | v$i | ${paragraph(4)} |');
          }
          buffer.writeln();
        case 3:
          buffer.writeln('```dart');
          for (var i = 0; i < 6; i++) {
            buffer.writeln('final value$i = compute($i); // ${paragraph(3)}');
          }
          buffer
            ..writeln('```')
            ..writeln();
        case 4:
          buffer
            ..writeln('### Detalle $section')
            ..writeln()
            ..writeln('> ${paragraph(20)}')
            ..writeln();
      }
    }
    return buffer.toString();
  }

  Map<String, dynamic> row(String role, Object? content, [Map? extra]) => {
    'id': id++,
    'role': role,
    'content': content,
    'timestamp': 1790000000 + id,
    ...?extra,
  };

  var delegations = 0;
  while (out.length < rows) {
    final userIndex = out.length;
    if (userIndex > 0 && userIndex % 97 == 0 && delegations < 4) {
      delegations++;
      out.add(
        row('user', '[ASYNC DELEGATION BATCH COMPLETE — deleg_$delegations]', {
          'display_kind': 'async_delegation_complete',
          'display_metadata': {
            'delegation_id': 'deleg_$delegations',
            'task_count': 2,
            'completed_count': 2,
            'failed_count': 0,
            'subagent_ids': ['sa-$delegations-a', 'sa-$delegations-b'],
          },
        }),
      );
      continue;
    }
    out.add(
      row(
        'user',
        '${paragraph(30 + random.nextInt(200))}\n\n'
            '[Pasted image: captura-$userIndex.png]',
      ),
    );
    final tools = 2 + random.nextInt(6);
    for (var t = 0; t < tools && out.length < rows - 1; t++) {
      final callId = 'call_${call++}';
      out.add(
        row('assistant', t == 0 ? paragraph(25) : '', {
          'reasoning': paragraph(60),
          'tool_calls': [
            {
              'id': callId,
              'type': 'function',
              'function': {
                'name': t.isEven ? 'terminal' : 'read_file',
                'arguments': jsonEncode({'command': 'ls -la $t'}),
              },
            },
          ],
        }),
      );
      final size = random.nextDouble() < 0.03
          ? 60000
          : 800 + random.nextInt(4000);
      out.add(
        row(
          'tool',
          jsonEncode({
            'output': List.filled(size ~/ 16, 'lorem ipsum dol ').join(),
            'exit_code': 0,
          }),
          {
            'tool_call_id': callId,
            'tool_name': t.isEven ? 'terminal' : 'read_file',
          },
        ),
      );
    }
    if (out.length < rows) {
      out.add(
        row(
          'assistant',
          markdown(
            random.nextDouble() < 0.05 ? 20000 : 1200 + random.nextInt(3000),
          ),
          {'reasoning': paragraph(80), 'finish_reason': 'stop'},
        ),
      );
    }
  }
  out.removeRange(rows, out.length);
  // Frontera de compactación: las más antiguas quedan compactadas y el
  // resumen + reenunciado abren la región activa.
  for (var i = 0; i < out.length; i++) {
    final isCompacted = i < compacted;
    out[i]['compacted'] = isCompacted ? 1 : 0;
    out[i]['active'] = isCompacted ? 0 : 1;
  }
  if (compacted > 0 && compacted < out.length - 1) {
    out[compacted] =
        {
            ...out[compacted],
            'role': 'user',
            'content':
                '[STILL IN PROGRESS — this is the active request, restated after '
                'the compaction boundary] ${paragraph(120)}',
          }
          ..remove('tool_calls')
          ..remove('tool_call_id')
          ..remove('tool_name');
  }
  return out;
}
