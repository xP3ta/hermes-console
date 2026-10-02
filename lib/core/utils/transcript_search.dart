/// Búsqueda de texto dentro de la transcripción cargada de un único chat.
///
/// Pura y sin dependencias de Flutter: normaliza mayúsculas y diacríticos
/// (`Café` ≡ `cafe`), devuelve todas las coincidencias por mensaje con sus
/// offsets en el texto ORIGINAL y memoiza el texto normalizado por mensaje para
/// que cada pulsación no vuelva a normalizar toda la conversación.
library;

/// Una coincidencia dentro de un mensaje visible de la transcripción.
class TranscriptMatch {
  /// Índice del mensaje en la lista recibida (la del chat: 0 = más reciente).
  final int messageIndex;

  /// Offset inicial (inclusive) en el contenido original del mensaje.
  final int start;

  /// Offset final (exclusivo) en el contenido original del mensaje.
  final int end;

  const TranscriptMatch({
    required this.messageIndex,
    required this.start,
    required this.end,
  });

  @override
  bool operator ==(Object other) =>
      other is TranscriptMatch &&
      other.messageIndex == messageIndex &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(messageIndex, start, end);

  @override
  String toString() => 'TranscriptMatch($messageIndex, $start, $end)';
}

/// Texto normalizado con el mapa de vuelta a offsets del original.
class NormalizedSearchText {
  final String text;

  /// `sourceOffsets[i]` es el offset en el original del carácter `text[i]`;
  /// tiene `text.length + 1` entradas (la última es la longitud original).
  final List<int> sourceOffsets;

  const NormalizedSearchText(this.text, this.sourceOffsets);
}

bool _isCombiningMark(int code) =>
    (code >= 0x0300 && code <= 0x036F) ||
    (code >= 0x1AB0 && code <= 0x1AFF) ||
    (code >= 0x1DC0 && code <= 0x1DFF) ||
    (code >= 0x20D0 && code <= 0x20FF) ||
    (code >= 0xFE20 && code <= 0xFE2F);

const _foldTable = <String, String>{
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'ç': 'c',
  'ć': 'c',
  'ĉ': 'c',
  'ċ': 'c',
  'č': 'c',
  'ď': 'd',
  'đ': 'd',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ĕ': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'ĝ': 'g',
  'ğ': 'g',
  'ġ': 'g',
  'ģ': 'g',
  'ĥ': 'h',
  'ħ': 'h',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ĩ': 'i',
  'ī': 'i',
  'ĭ': 'i',
  'į': 'i',
  'ı': 'i',
  'ĵ': 'j',
  'ķ': 'k',
  'ĺ': 'l',
  'ļ': 'l',
  'ľ': 'l',
  'ŀ': 'l',
  'ł': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ņ': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ō': 'o',
  'ŏ': 'o',
  'ő': 'o',
  'ŕ': 'r',
  'ŗ': 'r',
  'ř': 'r',
  'ś': 's',
  'ŝ': 's',
  'ş': 's',
  'š': 's',
  'ţ': 't',
  'ť': 't',
  'ŧ': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ũ': 'u',
  'ū': 'u',
  'ŭ': 'u',
  'ů': 'u',
  'ű': 'u',
  'ų': 'u',
  'ŵ': 'w',
  'ý': 'y',
  'ÿ': 'y',
  'ŷ': 'y',
  'ź': 'z',
  'ż': 'z',
  'ž': 'z',
};

/// Minúsculas y sin diacríticos, conservando el mapa de offsets. Cada unidad
/// del original produce como mucho una unidad normalizada, salvo las marcas
/// combinantes, que se descartan.
NormalizedSearchText normalizeForSearch(String source) {
  final out = StringBuffer();
  final offsets = <int>[];
  for (var i = 0; i < source.length; i++) {
    final code = source.codeUnitAt(i);
    if (_isCombiningMark(code)) continue;
    var char = String.fromCharCode(code).toLowerCase();
    if (char.length != 1) char = String.fromCharCode(code);
    char = _foldTable[char] ?? char;
    out.write(char);
    offsets.add(i);
  }
  offsets.add(source.length);
  return NormalizedSearchText(out.toString(), offsets);
}

/// Normaliza solo la consulta (sin mapa) y recorta espacios de los extremos.
String normalizeSearchQuery(String query) =>
    normalizeForSearch(query.trim()).text;

/// ¿Participa este mensaje en la búsqueda? Solo texto de usuario y asistente;
/// las filas internas (pipeline, tools, system) no son texto conversacional.
bool isSearchableTranscriptMessage(Map<String, dynamic> message) {
  final role = message['role'];
  if (role != 'user' && role != 'assistant') return false;
  if (message['_pipeline'] == true) return false;
  return message['content'] is String;
}

class _MemoEntry {
  final String content;
  final NormalizedSearchText normalized;

  const _MemoEntry(this.content, this.normalized);
}

/// Índice memoizado de la transcripción. Reutiliza el texto normalizado de
/// cada mensaje mientras su contenido no cambie; la clave es el id estable del
/// mensaje cuando existe y, si no, la identidad del propio mapa.
class TranscriptSearchIndex {
  final Map<Object, _MemoEntry> _memo = {};

  /// Número de normalizaciones realizadas (observabilidad del memo).
  int normalizationCount = 0;

  Object _keyFor(Map<String, dynamic> message) {
    final id = message['id'] ?? message['message_id'];
    if (id != null) return 'id:$id';
    return message;
  }

  NormalizedSearchText _normalized(Map<String, dynamic> message) {
    final content = message['content'] as String;
    final key = _keyFor(message);
    final cached = _memo[key];
    if (cached != null && cached.content == content) {
      return cached.normalized;
    }
    normalizationCount++;
    final normalized = normalizeForSearch(content);
    _memo[key] = _MemoEntry(content, normalized);
    return normalized;
  }

  /// Todas las coincidencias de [query] en [messages], de abajo arriba en la
  /// pantalla: primero el mensaje más reciente (índice 0 de la lista) y, dentro
  /// de cada mensaje, del final al principio. Así «siguiente» siempre sube por
  /// el historial. Una consulta vacía o solo de espacios no produce nada.
  List<TranscriptMatch> search(
    List<Map<String, dynamic>> messages,
    String query,
  ) {
    final needle = normalizeSearchQuery(query);
    if (needle.isEmpty) return const [];
    final matches = <TranscriptMatch>[];
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (!isSearchableTranscriptMessage(message)) continue;
      final normalized = _normalized(message);
      final inMessage = <TranscriptMatch>[];
      var from = 0;
      while (true) {
        final hit = normalized.text.indexOf(needle, from);
        if (hit < 0) break;
        final endExclusive = hit + needle.length;
        inMessage.add(
          TranscriptMatch(
            messageIndex: index,
            start: normalized.sourceOffsets[hit],
            end: normalized.sourceOffsets[endExclusive],
          ),
        );
        from = endExclusive;
      }
      matches.addAll(inMessage.reversed);
    }
    return matches;
  }

  void clear() => _memo.clear();
}
