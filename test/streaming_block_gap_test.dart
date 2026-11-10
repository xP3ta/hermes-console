// The space a split live reply puts between its closed text and the rest:
// 10 dp between stretches of prose (one Markdown body's block spacing) and
// 4 dp when a table is on either side of the seam (what the finished reply
// leaves around a table). Only the paragraph at each edge counts.
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/widgets/chat/streaming_markdown_blocks.dart';

const String _table =
    '| Servicio | Estado |\n'
    '|---|---|\n'
    '| Pasarela | activa |\n';

void main() {
  const prose = StreamingMarkdownBlocks.blockSpacing;
  const table = 4.0;

  test('prose on both sides keeps the block spacing', () {
    expect(streamingBlockGap('Primero.\n\n', 'Después.'), prose);
  });

  test('a table at either edge leaves 4 dp', () {
    expect(streamingBlockGap('Antes.\n\n$_table\n', 'Después.'), table);
    expect(streamingBlockGap('Antes.\n\n', _table), table);
    expect(streamingBlockGap('$_table\n', _table), table);
  });

  test('blank space after the closed table does not hide it', () {
    expect(streamingBlockGap('Antes.\n\n$_table\n  \n\n', 'Después.'), table);
  });

  test('only the paragraph at the seam counts', () {
    expect(
      streamingBlockGap('Antes.\n\n$_table\nCierre.\n\n', 'Después.'),
      prose,
    );
    expect(streamingBlockGap('Antes.\n\n', 'Inicio.\n\n$_table'), prose);
  });

  test('bars that are not a table keep the block spacing', () {
    expect(streamingBlockGap('Usa `a | b` para unir.\n\n', 'Sigue.'), prose);
    expect(streamingBlockGap('Colores: rojo | verde | azul.\n\n', 'Y'), prose);
    expect(streamingBlockGap('Antes.\n\n', 'Colores: rojo | verde.'), prose);
  });

  test('a table inside a code fence is code', () {
    const fenced = '```\n$_table```\n\n';
    expect(streamingBlockGap(fenced, 'Después.'), prose);
    expect(streamingBlockGap('Antes.\n\n', '```\n$_table```\n'), prose);
  });

  test('a table header still arriving at the seam leaves 4 dp', () {
    expect(streamingBlockGap('Antes.\n\n', '| Servicio | Estado |\n'), table);
  });
}
