/// Reensambla frames SSE («\n\n» como separador) sin coste cuadrático.
///
/// El patrón anterior era `buffer += chunk` seguido de `buffer.indexOf(...)`
/// desde el principio: cada trozo que llegaba de la red copiaba todo lo
/// acumulado y lo reescaneaba entero, así que ensamblar un frame grande
/// costaba el cuadrado de su tamaño (medido: 567ms para 512KB).
///
/// Aquí cada trozo se inspecciona UNA vez y los fragmentos sólo se unen
/// cuando un frame se completa, de modo que el trabajo total es proporcional
/// al texto recibido.
class SseFrameBuffer {
  final List<String> _parts = <String>[];
  bool _endsWithNewline = false;

  /// Añade un trozo recién llegado y devuelve los frames ya completos.
  Iterable<String> addChunk(String chunk) sync* {
    if (chunk.isEmpty) return;

    var cursor = 0;

    // Separador partido entre dos trozos: «\n» al final del anterior y «\n»
    // al principio de éste.
    if (_endsWithNewline && chunk.codeUnitAt(0) == 0x0A) {
      yield _takeFrame(dropTrailingNewline: true);
      cursor = 1;
    }

    while (cursor < chunk.length) {
      final sep = chunk.indexOf('\n\n', cursor);
      if (sep < 0) break;
      _parts.add(chunk.substring(cursor, sep));
      yield _takeFrame();
      cursor = sep + 2;
    }

    if (cursor < chunk.length) {
      final rest = chunk.substring(cursor);
      _parts.add(rest);
      _endsWithNewline = rest.codeUnitAt(rest.length - 1) == 0x0A;
    } else {
      _endsWithNewline = false;
    }
  }

  String _takeFrame({bool dropTrailingNewline = false}) {
    final frame = _parts.length == 1 ? _parts.first : _parts.join();
    _parts.clear();
    _endsWithNewline = false;
    if (dropTrailingNewline && frame.endsWith('\n')) {
      return frame.substring(0, frame.length - 1);
    }
    return frame;
  }
}
