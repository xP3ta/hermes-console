/// ARTCAUSA: a transcript with percent escapes that are not UTF-8 (`%FF`, a
/// lone `%C3`, a cut `%E2%80`), the rows that threw a FormatException and
/// left «Artefactos» blank on the Fold, between three good artifacts.
/// Chronological (oldest first).
library;

import 'dart:collection';

List<Map<String, dynamic>> malformedArtifactRows() => [
  _assistant('Mira https://example.com/docs/uno', 1781774300),
  _assistant('[foto](#media:%FF)', 1781774301),
  _assistant('MEDIA:/out/informe.pdf', 1781774302),
  _assistant('[audio](#media:%C3)', 1781774303),
  _assistant('Mira https://x/%E2%80', 1781774304),
  _assistant('[captura](file:///a/%FF.png)', 1781774305),
  _assistant('MEDIA:/out/notas.txt', 1781774306),
];

/// The three good artifacts of [malformedArtifactRows], in its order.
const malformedRowsGoodValues = [
  'https://example.com/docs/uno',
  '/out/informe.pdf',
  '/out/notas.txt',
];

Map<String, dynamic> _assistant(String content, int timestamp) => {
  'role': 'assistant',
  'content': content,
  'timestamp': timestamp,
};

/// A transcript row that throws on every read: a stand-in for a row the
/// extractors cannot handle, whatever the reason.
final class UnreadableRow extends MapBase<String, dynamic> {
  @override
  dynamic operator [](Object? key) => throw StateError('unreadable row');

  @override
  void operator []=(String key, dynamic value) {}

  @override
  void clear() {}

  @override
  Iterable<String> get keys => const ['role', 'content'];

  @override
  dynamic remove(Object? key) => null;
}
