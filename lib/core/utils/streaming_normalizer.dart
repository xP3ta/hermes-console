/// HermesStreamingNormalizer
///
/// Capa **puramente de presentación** sobre el texto parcial que llega durante
/// el streaming. NO muta el contenido real guardado por `ActiveChatService`:
/// solo se aplica al renderizar el mensaje en curso, para que un bloque de
/// código o un marcador inline a medio escribir no parpadee ni "rompa" el
/// Markdown mientras llegan tokens.
///
/// Reglas (conservadoras: ante la duda, no tocar):
///  - Si hay un número impar de vallas ```` ``` ````, cierra una valla virtual
///    al final para que flutter_markdown renderice el bloque como código en vez
///    de tratar el resto como texto suelto.
///  - Si, fuera de un bloque de código, queda un backtick inline ` impar en la
///    última línea, lo cierra para no dejar `código a medias.
///
/// Cuando `isStreaming` es false devuelve el texto intacto: el mensaje ya
/// finalizado se renderiza tal cual llegó del servidor.
library;

/// Escapa los `*` dentro de tokens que parecen rutas/globs (contienen `/`),
/// para que Markdown no los interprete como *cursiva*/**negrita** y corrompa
/// rutas como `/home/user/**/*.pdf`. Respeta el código: no toca nada dentro
/// de vallas ``` ni de spans inline `…`.
///
/// Es seguro porque solo actúa sobre tokens con `/` (rutas), nunca sobre prosa.
String escapePathGlobs(String text) {
  if (text.isEmpty || !text.contains('*')) return text;
  final out = StringBuffer();
  var inFence = false;
  for (final line in text.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      out.writeln(line);
      continue;
    }
    if (inFence) {
      out.writeln(line);
      continue;
    }
    // Alterna segmentos fuera/dentro de inline-code (separados por backtick):
    // los pares (índice par) están fuera de código y se escapan; los impares
    // son código inline y quedan intactos. Se reconstruyen con los backticks.
    final segments = line.split('`');
    for (var i = 0; i < segments.length; i++) {
      out.write(i.isEven ? _escapeStarsInPaths(segments[i]) : segments[i]);
      if (i < segments.length - 1) out.write('`');
    }
    out.write('\n');
  }
  var result = out.toString();
  // split('\n') + writeln añade un salto de más; recórtalo si el original no lo tenía.
  if (!text.endsWith('\n') && result.endsWith('\n')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

String _escapeStarsInPaths(String segment) {
  if (!segment.contains('*')) return segment;
  final openEmphasis = <String>[];
  return segment.replaceAllMapped(RegExp(r'\S+'), (m) {
    final token = m.group(0)!;
    final leading = RegExp(r'^(\*{1,3})(?!\*)').firstMatch(token);
    final trailing = RegExp(r'(\*{1,3})([.,;:!?)\]]*)$').firstMatch(token);
    String? openingMarker;
    String? closingMarker;

    if (leading != null) {
      final marker = leading.group(1)!;
      final trailingStartsAfterBody =
          trailing != null && trailing.start > marker.length;
      final next = token.length > marker.length ? token[marker.length] : '';
      // `**/home/**/*.pdf**` es énfasis completo alrededor de una ruta; un
      // `**/` sin cierre, en cambio, es mucho más probablemente un glob.
      if (next.isNotEmpty && (next != '/' || trailingStartsAfterBody)) {
        openingMarker = marker;
        openEmphasis.add(marker);
      }
    }

    if (trailing != null && trailing.start > (openingMarker?.length ?? 0)) {
      final marker = trailing.group(1)!;
      if (openEmphasis.isNotEmpty) {
        final expected = openEmphasis.last;
        if (expected == marker) {
          closingMarker = marker;
          openEmphasis.removeLast();
        } else if (expected.startsWith(marker)) {
          // El cierre llega carácter a carácter: con un opener `**`, el primer
          // `*` final todavía es un delimitador parcial, no un glob literal.
          // Se conserva sin cerrar el estado; el normalizador lo oculta hasta
          // que llegue el segundo asterisco.
          closingMarker = marker;
        }
      }
    }

    if (token.contains('/') && token.contains('*')) {
      // La apertura y el cierre pueden vivir en tokens distintos:
      // `**Pack de temas/personalización**`. El código anterior solo reconocía
      // énfasis contenido en un único token y escapaba el cierre como `\*\*`;
      // el normalizador veía entonces una apertura huérfana y añadía dos
      // asteriscos visibles incluso en la respuesta terminal.
      final protectedPrefix = openingMarker?.length ?? 0;
      final protectedSuffixStart = closingMarker == null
          ? token.length
          : trailing!.start;
      return _escapeUnescapedStars(
        token,
        protectedPrefix: protectedPrefix,
        protectedSuffixStart: protectedSuffixStart,
      );
    }
    return token;
  });
}

String _escapeUnescapedStars(
  String text, {
  int protectedPrefix = 0,
  int? protectedSuffixStart,
}) {
  final out = StringBuffer();
  final suffixStart = protectedSuffixStart ?? text.length;
  for (var i = 0; i < text.length; i++) {
    final protected = i < protectedPrefix || i >= suffixStart;
    if (!protected && text[i] == '*' && !_isEscaped(text, i)) out.write(r'\');
    out.write(text[i]);
  }
  return out.toString();
}

/// Normaliza [text] para una visualización Markdown estable.
///
/// Con `isStreaming: false` devuelve el texto intacto: el mensaje ya finalizado
/// se renderiza tal cual llegó del servidor. Con `isStreaming: true` parte el
/// documento en bloques superiores estables y repara cada uno de forma
/// independiente. Así un marcador huérfano no queda visible ni puede extender
/// su formato a los párrafos siguientes; durante streaming solo la última cola
/// permanece mutable. Las reparaciones viven únicamente en esta copia de
/// presentación: el mensaje almacenado y el texto copiado conservan lo recibido.
String normalizeStreamingMarkdown(String text, {required bool isStreaming}) {
  if (text.isEmpty) return text;
  // Mensaje terminal: se renderiza tal cual llegó del servidor. La reparación
  // por bloque existe para el texto vivo (un `[`, `*` o enlace a medias mientras
  // llegan tokens); aplicarla al mensaje final recortaría sufijos legítimos.
  if (!isStreaming) return text;

  final blockStarts = _markdownTopLevelBlockStarts(text);
  final tailStart = blockStarts.last;
  final out = StringBuffer();
  for (var index = 0; index < blockStarts.length - 1; index++) {
    final start = blockStarts[index];
    final end = blockStarts[index + 1];
    out.write(_repairStableMarkdownBlock(text.substring(start, end)));
  }
  out.write(
    _repairMarkdownTail(
      text.substring(tailStart),
      hideMarkerOnlySuffix: isStreaming,
      flattenClosedLinkCandidate: isStreaming,
    ),
  );
  return out.toString();
}

/// Inicio de la cola mutable de un documento en streaming: su último bloque
/// superior. Todo lo anterior son bloques CERRADOS que ya no cambian mientras
/// llegan tokens, así que el asistente vivo puede proyectarlos una sola vez
/// (caché por contenido) y reprocesar en cada frame únicamente la cola.
int streamingMarkdownTailStart(String text) {
  if (text.isEmpty) return 0;
  return _markdownTopLevelBlockStarts(text).last;
}

/// Repara los bloques cerrados de [text] exactamente como lo haría
/// [normalizeStreamingMarkdown] si formaran la parte estable de un documento
/// mayor: cada bloque superior se repara de forma independiente y conserva sus
/// separadores. El resultado concatenado con la cola normalizada es byte a byte
/// el mismo que normalizar el documento entero con `isStreaming: true`.
String normalizeStableStreamingPrefix(String text) {
  if (text.isEmpty) return text;
  final blockStarts = _markdownTopLevelBlockStarts(text);
  final out = StringBuffer();
  for (var index = 0; index < blockStarts.length; index++) {
    final start = blockStarts[index];
    final end = index + 1 < blockStarts.length
        ? blockStarts[index + 1]
        : text.length;
    out.write(_repairStableMarkdownBlock(text.substring(start, end)));
  }
  return out.toString();
}

String _repairStableMarkdownBlock(String text) {
  var contentEnd = text.length;
  while (contentEnd > 0) {
    final unit = text.codeUnitAt(contentEnd - 1);
    if (unit != 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) break;
    contentEnd--;
  }
  final content = text.substring(0, contentEnd);
  final separator = text.substring(contentEnd);
  return '${_repairMarkdownTail(content, hideMarkerOnlySuffix: true, flattenClosedLinkCandidate: true)}$separator';
}

String _repairMarkdownTail(
  String text, {
  required bool hideMarkerOnlySuffix,
  required bool flattenClosedLinkCandidate,
}) {
  var tail = text;
  // Desktop deja que el revelado acumule los delimitadores iniciales antes de
  // publicarlos. En Flutter ocultamos esa cola durante el stream para que no
  // exista ni un frame con `*`, `**`, `` ` `` o `[` como texto visible.
  if (hideMarkerOnlySuffix) tail = _hideMarkerOnlySuffix(tail);
  if (tail.isEmpty) return tail;

  // Una valla abierta domina el resto del bloque. Dentro de ella, backticks,
  // corchetes y asteriscos son datos y no deben participar en otras reglas.
  final openFence = _openFenceMarker(tail);
  if (openFence != null) {
    if (!tail.endsWith('\n')) tail += '\n';
    return '$tail$openFence';
  }

  tail = _stripIncompleteHtmlTail(tail);
  if (flattenClosedLinkCandidate) {
    tail = _flattenClosedLinkCandidateTail(tail);
  }
  tail = _repairIncompleteLinkTail(tail);
  tail = _closeInlineCodeTail(tail);
  tail = _closeUnbalancedInlineDelimiters(tail);
  return tail;
}

/// Inicios de los bloques superiores que pueden repararse de forma
/// independiente. Una valla o bloque matemático abierto conserva juntas sus
/// líneas aunque contenga separaciones en blanco.
List<int> _markdownTopLevelBlockStarts(String text) {
  final starts = <int>[0];
  var inFence = false;
  var fenceChar = '';
  var fenceLength = 0;
  var inMath = false;
  int? pending;

  for (var lineStart = 0; lineStart <= text.length;) {
    final foundEnd = text.indexOf('\n', lineStart);
    final lineEnd = foundEnd < 0 ? text.length : foundEnd;
    var first = lineStart;
    while (first < lineEnd && (text[first] == ' ' || text[first] == '\t')) {
      first++;
    }

    var fenceLine = false;
    if (first < lineEnd &&
        (text[first] == '`' || text[first] == '~') &&
        first - lineStart <= 3) {
      var runEnd = first + 1;
      while (runEnd < lineEnd && text[runEnd] == text[first]) {
        runEnd++;
      }
      final runLength = runEnd - first;
      if (runLength >= 3) {
        fenceLine = true;
        if (!inFence) {
          inFence = true;
          fenceChar = text[first];
          fenceLength = runLength;
        } else if (text[first] == fenceChar &&
            runLength >= fenceLength &&
            text.substring(runEnd, lineEnd).trim().isEmpty) {
          inFence = false;
          fenceChar = '';
          fenceLength = 0;
        }
      }
    }

    if (!inFence && !fenceLine) {
      // Escaneo por unidad de código dentro de la línea. `indexOf` no acepta
      // un índice final: aunque se descarte el resultado, sigue recorriendo
      // hasta el fin del documento desde cada línea, y el coste del escaneo
      // de bloques crecía con el cuadrado de la longitud. En la ruta viva de
      // streaming esto corre en CADA frame (medido: 320ms por frame con 60KB
      // solo para localizar una cola de 54 caracteres; ahora 0,5ms).
      for (var i = lineStart; i + 1 < lineEnd; i++) {
        if (text.codeUnitAt(i) == 0x24 && text.codeUnitAt(i + 1) == 0x24) {
          if (!_isEscaped(text, i)) inMath = !inMath;
          i++;
        }
      }
    }

    final blank = first >= lineEnd;
    if (blank && !inFence && !inMath) {
      pending = lineEnd < text.length ? lineEnd + 1 : lineEnd;
    } else if (pending != null) {
      if (pending > starts.last && pending < text.length) {
        starts.add(pending);
      }
      pending = null;
    }

    if (lineEnd >= text.length) break;
    lineStart = lineEnd + 1;
  }
  return starts;
}

String _hideMarkerOnlySuffix(String text) {
  final lastLineStart = text.lastIndexOf('\n') + 1;
  final lastLine = text.substring(lastLineStart).trim();
  if (RegExp(r'^(?:\*{3,}|_{3,})$').hasMatch(lastLine)) {
    // Regla horizontal CommonMark completa, no un opener transitorio.
    return text;
  }
  // Un flush del Gateway puede terminar justo después de abrir una lista,
  // cita o cabecera. No pintes ese marcador como una línea suelta mientras
  // llega su contenido; las reglas horizontales completas siguen preservadas.
  if (RegExp(r'^(?:[-+>]|#{1,6}|\d+[.)])$').hasMatch(lastLine)) {
    return text.substring(0, lastLineStart);
  }
  final match = RegExp(
    r'(!?\[|`+|~{1,2}|\*{1,3}|_{1,3})[ \t]*$',
  ).firstMatch(text);
  if (match == null || _isEscaped(text, match.start)) return text;
  return text.substring(0, match.start);
}

String? _openFenceMarker(String text) {
  String? fenceChar;
  var fenceLength = 0;
  for (final line in text.split('\n')) {
    final match = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
    if (match == null) continue;
    final marker = match.group(1)!;
    final suffix = match.group(2)!;
    if (fenceChar == null) {
      fenceChar = marker[0];
      fenceLength = marker.length;
    } else if (marker[0] == fenceChar &&
        marker.length >= fenceLength &&
        suffix.trim().isEmpty) {
      fenceChar = null;
      fenceLength = 0;
    }
  }
  return fenceChar == null ? null : fenceChar * fenceLength;
}

String _stripIncompleteHtmlTail(String text) {
  final match = RegExp(r'<[A-Za-z/][^>]*$').firstMatch(text);
  if (match == null || _isInsideCode(text, match.start)) return text;
  return text.substring(0, match.start).trimRight();
}

String _flattenClosedLinkCandidateTail(String text) {
  final match = RegExp(r'(!?)\[([^\]\n]+)\]$').firstMatch(text);
  if (match == null ||
      _isEscaped(text, match.start + match.group(1)!.length) ||
      _isInsideCode(text, match.start)) {
    return text;
  }
  final prefix = text.substring(0, match.start);
  return match.group(1) == '!' ? prefix : '$prefix${match.group(2)}';
}

/// Convierte enlaces todavía incompletos en su etiqueta visible. Es el modo
/// `text-only` de remend: `[guía](https://exa` se presenta como `guía`, nunca
/// como sintaxis cruda ni como un enlace temporal hacia una URL inventada.
String _repairIncompleteLinkTail(String text) {
  final brackets = <int>[];
  var inFence = false;
  String? fenceChar;
  var fenceLength = 0;
  int? inlineTicks;
  int? destinationOpen;
  int? destinationLabelEnd;
  var destinationDepth = 0;

  for (var i = 0; i < text.length;) {
    final lineStart = i == 0 || text[i - 1] == '\n';
    if (lineStart) {
      final lineEnd = text.indexOf('\n', i);
      final end = lineEnd < 0 ? text.length : lineEnd;
      final line = text.substring(i, end);
      final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!;
        final suffix = fence.group(2)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLength = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLength &&
            suffix.trim().isEmpty) {
          inFence = false;
          fenceChar = null;
          fenceLength = 0;
        }
        i = lineEnd < 0 ? text.length : lineEnd + 1;
        continue;
      }
    }
    if (inFence) {
      i++;
      continue;
    }

    if (text[i] == '`' && !_isEscaped(text, i)) {
      final run = _markerRun(text, i, '`');
      if (inlineTicks == null) {
        inlineTicks = run;
      } else if (inlineTicks == run) {
        inlineTicks = null;
      }
      i += run;
      continue;
    }
    if (inlineTicks != null) {
      i++;
      continue;
    }

    if (destinationDepth > 0) {
      if (text[i] == '(' && !_isEscaped(text, i)) {
        destinationDepth++;
      } else if (text[i] == ')' && !_isEscaped(text, i)) {
        destinationDepth--;
        if (destinationDepth == 0) {
          destinationOpen = null;
          destinationLabelEnd = null;
        }
      }
      i++;
      continue;
    }

    if (text[i] == '[' && !_isEscaped(text, i)) {
      brackets.add(i);
    } else if (text[i] == ']' && !_isEscaped(text, i) && brackets.isNotEmpty) {
      final open = brackets.removeLast();
      if (i + 1 < text.length && text[i + 1] == '(') {
        destinationOpen = open;
        destinationLabelEnd = i;
        destinationDepth = 1;
        i += 2;
        continue;
      }
    }
    i++;
  }

  if (destinationDepth > 0 &&
      destinationOpen != null &&
      destinationLabelEnd != null) {
    final image = destinationOpen > 0 && text[destinationOpen - 1] == '!';
    final prefixEnd = image ? destinationOpen - 1 : destinationOpen;
    if (image) return text.substring(0, prefixEnd);
    final label = text.substring(destinationOpen + 1, destinationLabelEnd);
    return '${text.substring(0, prefixEnd)}$label';
  }
  if (brackets.isNotEmpty) {
    final open = brackets.first;
    final image = open > 0 && text[open - 1] == '!';
    final prefixEnd = image ? open - 1 : open;
    if (image) return text.substring(0, prefixEnd);
    return '${text.substring(0, prefixEnd)}${text.substring(open + 1)}';
  }
  return text;
}

String _closeInlineCodeTail(String text) {
  var inFence = false;
  String? fenceChar;
  var fenceLength = 0;
  int? openTicks;

  for (var i = 0; i < text.length;) {
    final lineStart = i == 0 || text[i - 1] == '\n';
    if (lineStart) {
      final lineEnd = text.indexOf('\n', i);
      final end = lineEnd < 0 ? text.length : lineEnd;
      final line = text.substring(i, end);
      final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!;
        final suffix = fence.group(2)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLength = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLength &&
            suffix.trim().isEmpty) {
          inFence = false;
          fenceChar = null;
          fenceLength = 0;
        }
        i = lineEnd < 0 ? text.length : lineEnd + 1;
        continue;
      }
    }
    if (!inFence && text[i] == '`' && !_isEscaped(text, i)) {
      final run = _markerRun(text, i, '`');
      if (openTicks == null) {
        openTicks = run;
      } else if (openTicks == run) {
        openTicks = null;
      }
      i += run;
      continue;
    }
    i++;
  }
  return openTicks == null
      ? text
      : _appendBeforeTrailingWhitespace(text, '`' * openTicks);
}

String _closeUnbalancedInlineDelimiters(String text) {
  final open = <String>[];
  var inFence = false;
  String? fenceChar;
  var fenceLength = 0;
  int? inlineTicks;
  var linkDestinationDepth = 0;

  for (var i = 0; i < text.length;) {
    final char = text[i];
    final atLineStart = i == 0 || text[i - 1] == '\n';
    if (atLineStart) {
      final lineEnd = text.indexOf('\n', i);
      final end = lineEnd < 0 ? text.length : lineEnd;
      final line = text.substring(i, end);
      final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!;
        final suffix = fence.group(2)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLength = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLength &&
            suffix.trim().isEmpty) {
          inFence = false;
          fenceChar = null;
          fenceLength = 0;
        }
        i = lineEnd < 0 ? text.length : lineEnd + 1;
        inlineTicks = null;
        continue;
      }
    }
    if (inFence) {
      i++;
      continue;
    }
    if (char == '`' && !_isEscaped(text, i)) {
      final run = _markerRun(text, i, '`');
      if (inlineTicks == null) {
        inlineTicks = run;
      } else if (inlineTicks == run) {
        inlineTicks = null;
      }
      i += run;
      continue;
    }
    if (inlineTicks != null) {
      i++;
      continue;
    }

    if (linkDestinationDepth > 0) {
      if (char == '(' && !_isEscaped(text, i)) {
        linkDestinationDepth++;
      } else if (char == ')' && !_isEscaped(text, i)) {
        linkDestinationDepth--;
      }
      i++;
      continue;
    }
    if (char == '(' && i > 0 && text[i - 1] == ']') {
      linkDestinationDepth = 1;
      i++;
      continue;
    }
    if ((char != '*' && char != '_' && char != '~') || _isEscaped(text, i)) {
      i++;
      continue;
    }

    var end = i + 1;
    while (end < text.length && text[end] == char) {
      end++;
    }
    final runLength = end - i;
    if (char == '~' && runLength < 2) {
      i = end;
      continue;
    }
    final delimiterLength = char == '~' ? 2 : runLength;
    final previous = i == 0 ? null : text[i - 1];
    final next = end == text.length ? null : text[end];
    final currentLineStart = i == 0 ? 0 : text.lastIndexOf('\n', i - 1) + 1;
    final before = text.substring(currentLineStart, i);
    final tokenStart = _tokenStart(text, i);
    final token = text.substring(tokenStart, _tokenEnd(text, end));
    final insideWord = char == '_' && _isWord(previous) && _isWord(next);
    final emphasisDelimiters = char == '~'
        ? List<String>.filled(runLength ~/ delimiterLength, '~~')
        : _emphasisDelimiters(char, runLength);
    final canOpen = next != null && !_isWhitespace(next);
    final canClose = previous != null && !_isWhitespace(previous);
    final closesOpenEmphasis =
        canClose &&
        emphasisDelimiters.any(
          (delimiter) => open.isNotEmpty && open.last == delimiter,
        );
    final startsEmphasis =
        char == '*' &&
        i == tokenStart &&
        runLength <= 3 &&
        canOpen &&
        next != '/';
    final pathGlob =
        char == '*' &&
        token.contains('/') &&
        !startsEmphasis &&
        !closesOpenEmphasis;
    final listMarker =
        before.trim().isEmpty && next != null && _isWhitespace(next);
    final lineEnd = text.indexOf('\n', end);
    final wholeLine = text
        .substring(currentLineStart, lineEnd < 0 ? text.length : lineEnd)
        .replaceAll(RegExp(r'\s'), '');
    final thematicBreak =
        wholeLine.length >= 3 &&
        wholeLine.split('').every((item) => item == char);
    if (insideWord || pathGlob || listMarker || thematicBreak) {
      i = end;
      continue;
    }

    var closed = false;
    if (canClose) {
      for (final delimiter in emphasisDelimiters.reversed) {
        if (open.isNotEmpty && open.last == delimiter) {
          open.removeLast();
          closed = true;
        }
      }
    }
    if (canOpen && !closed) open.addAll(emphasisDelimiters);
    i = end;
  }

  return open.isEmpty
      ? text
      : _appendBeforeTrailingWhitespace(text, open.reversed.join());
}

String _appendBeforeTrailingWhitespace(String text, String closer) {
  var end = text.length;
  while (end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t')) {
    end--;
  }
  return '${text.substring(0, end)}$closer${text.substring(end)}';
}

int _markerRun(String text, int start, String marker) {
  var end = start + 1;
  while (end < text.length && text[end] == marker) {
    end++;
  }
  return end - start;
}

bool _isInsideCode(String text, int offset) {
  var inFence = false;
  int? inlineTicks;
  for (var i = 0; i < offset;) {
    if ((i == 0 || text[i - 1] == '\n') &&
        (text.startsWith('```', i) || text.startsWith('~~~', i))) {
      inFence = !inFence;
      final newline = text.indexOf('\n', i);
      if (newline < 0 || newline >= offset) return inFence;
      i = newline + 1;
      continue;
    }
    if (!inFence && text[i] == '`' && !_isEscaped(text, i)) {
      final run = _markerRun(text, i, '`');
      if (inlineTicks == null) {
        inlineTicks = run;
      } else if (inlineTicks == run) {
        inlineTicks = null;
      }
      i += run;
      continue;
    }
    i++;
  }
  return inFence || inlineTicks != null;
}

List<String> _emphasisDelimiters(String char, int length) {
  final result = <String>[];
  var remaining = length;
  while (remaining >= 2) {
    result.add('$char$char');
    remaining -= 2;
  }
  if (remaining == 1) result.add(char);
  return result;
}

bool _isEscaped(String text, int index) {
  var slashes = 0;
  for (var i = index - 1; i >= 0 && text[i] == r'\'; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

bool _isWhitespace(String char) => RegExp(r'\s').hasMatch(char);

bool _isWord(String? char) =>
    char != null && RegExp(r'[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ]').hasMatch(char);

int _tokenStart(String text, int index) {
  var start = index;
  while (start > 0 && !_isWhitespace(text[start - 1])) {
    start--;
  }
  return start;
}

int _tokenEnd(String text, int index) {
  var end = index;
  while (end < text.length && !_isWhitespace(text[end])) {
    end++;
  }
  return end;
}
