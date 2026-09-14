/// Modelado del contenido del asistente para presentación.
///
/// Capa **puramente de presentación**: separa el razonamiento (`<think>…`) de la
/// respuesta final y aplica retoques conservadores al Markdown que algunos
/// modelos emiten mal formado (encabezados pegados al `#`). NO altera el
/// contenido guardado por `ActiveChatService`: se aplica solo al renderizar.
///
/// Reglas (conservadoras: ante la duda, no tocar). Si el texto no contiene
/// ninguna etiqueta de razonamiento, [splitReasoning] devuelve la respuesta
/// intacta, garantizando cero cambios de comportamiento en el caso normal.
library;

/// True when transport metadata makes a transcript row non-public.
///
/// Call this before projecting or copying a row: several parsers deliberately
/// discard unknown payload fields, so delaying the decision loses the evidence
/// that a row was hidden, reasoning, or otherwise privately classified.
bool hasPrivateTranscriptClassifier(Map<String, dynamic> payload) {
  for (final key in const [
    'hidden',
    'is_hidden',
    'is_reasoning',
    'channel',
    'kind',
    'content_type',
  ]) {
    if (payload.containsKey(key)) return true;
  }
  return payload['reasoning'] == true;
}

/// Resultado de separar el razonamiento de la respuesta visible.
class ReasoningSplit {
  /// Texto del razonamiento (sin etiquetas). Puede ser cadena vacía.
  final String reasoning;

  /// Respuesta final visible (Markdown), ya sin las etiquetas de razonamiento.
  final String answer;

  /// `true` cuando hay un `<think>` abierto sin cerrar todavía (el modelo sigue
  /// razonando durante el streaming). Útil para mostrar un estado "pensando…".
  final bool reasoningInProgress;

  const ReasoningSplit({
    required this.reasoning,
    required this.answer,
    this.reasoningInProgress = false,
  });

  /// `true` si hay algo de razonamiento que mostrar (cerrado o en curso).
  bool get hasReasoning => reasoning.isNotEmpty || reasoningInProgress;
}

// Bloque de razonamiento completo: <think>…</think> / <thinking>…</thinking>.
final RegExp _thinkBlock = RegExp(
  r'<(think|thinking)>([\s\S]*?)</\1>',
  caseSensitive: false,
);

// Apertura de razonamiento sin cierre (streaming a mitad de pensar).
final RegExp _thinkOpen = RegExp(
  r'<(think|thinking)>([\s\S]*)$',
  caseSensitive: false,
);

// Restos sueltos de etiquetas (cierres huérfanos por contenido malformado).
final RegExp _thinkTagResidue = RegExp(
  r'</?(think|thinking)>',
  caseSensitive: false,
);

/// Typed vocabulary for Harmony assistant channels.
///
/// Only [finalResponse] and [commentary] belong to the public allowlist. New or
/// misspelled channels parse as [unknown] and therefore fail closed.
enum HarmonyAssistantChannel {
  finalResponse,
  commentary,
  analysis,
  reasoning,
  think,
  tool,
  unknown;

  static HarmonyAssistantChannel parse(String wireName) =>
      switch (wireName.trim().toLowerCase()) {
        'final' => finalResponse,
        'commentary' => commentary,
        'analysis' => analysis,
        'reasoning' => reasoning,
        'think' => think,
        'tool' => tool,
        _ => unknown,
      };

  bool get publiclyRenderable => this == finalResponse || this == commentary;
}

// Cada barra de un delimitador Harmony puede llegar como ASCII o U+FF5C de
// forma independiente. El cuerpo nunca se normaliza: PUBLIC ｜ conserva bytes.
final RegExp _harmonyDelimiter = RegExp(
  r'<[|｜](start|end|channel|message|think|/think)[|｜]>',
  caseSensitive: false,
);

const _harmonyDelimiterNames = <String>[
  'start',
  'end',
  'channel',
  'message',
  'think',
  '/think',
];

class _HarmonyToken {
  final String name;
  final int start;
  final int end;

  const _HarmonyToken(this.name, this.start, this.end);
}

enum _HeaderStatus { valid, incomplete, invalid }

class _HarmonyHeader {
  final _HeaderStatus status;
  final HarmonyAssistantChannel? channel;
  final int end;

  const _HarmonyHeader(this.status, {this.channel, required this.end});
}

class _HarmonyProjection {
  final String text;
  final List<int> rawToPublicOffset;
  final List<String> reasoning;
  final bool reasoningInProgress;

  const _HarmonyProjection({
    required this.text,
    required this.rawToPublicOffset,
    required this.reasoning,
    required this.reasoningInProgress,
  });
}

/// Texto público y mapa exacto desde offsets UTF-16 de la fuente.
///
/// El mapa permite intercalar corrections sin volver a parsear sufijos ni usar
/// prefijos recortados, que desplazarían whitespace a la fila equivocada.
class AssistantPublicProjection {
  final String text;
  final List<int> _rawToPublicOffset;

  const AssistantPublicProjection._(this.text, this._rawToPublicOffset);

  int publicOffsetAtRawOffset(int rawOffset) {
    if (rawOffset <= 0) return 0;
    if (rawOffset >= _rawToPublicOffset.length) return text.length;
    return _rawToPublicOffset[rawOffset];
  }
}

_HarmonyToken? _nextHarmonyToken(String source, int start) {
  for (final match in _harmonyDelimiter.allMatches(source, start)) {
    return _HarmonyToken(
      (match.group(1) ?? '').toLowerCase(),
      match.start,
      match.end,
    );
  }
  return null;
}

_HarmonyHeader _parseHarmonyHeader(
  String source,
  _HarmonyToken opener, {
  required bool streaming,
}) {
  var channelToken = opener;
  if (opener.name == 'start') {
    final next = _nextHarmonyToken(source, opener.end);
    if (next == null) {
      return _HarmonyHeader(
        streaming ? _HeaderStatus.incomplete : _HeaderStatus.invalid,
        end: opener.end,
      );
    }
    if (next.name != 'channel') {
      return _HarmonyHeader(_HeaderStatus.invalid, end: opener.end);
    }
    channelToken = next;
  }

  final messageToken = _nextHarmonyToken(source, channelToken.end);
  if (messageToken == null) {
    return _HarmonyHeader(
      streaming ? _HeaderStatus.incomplete : _HeaderStatus.invalid,
      end: opener.end,
    );
  }
  if (messageToken.name != 'message') {
    return _HarmonyHeader(_HeaderStatus.invalid, end: opener.end);
  }
  return _HarmonyHeader(
    _HeaderStatus.valid,
    channel: HarmonyAssistantChannel.parse(
      source.substring(channelToken.end, messageToken.start),
    ),
    end: messageToken.end,
  );
}

int _trailingHarmonyTokenPrefixLength(String source) {
  final lower = source.toLowerCase();
  var held = 0;
  for (final name in _harmonyDelimiterNames) {
    for (final left in const ['|', '｜']) {
      for (final right in const ['|', '｜']) {
        final token = '<$left$name$right>';
        final max = token.length - 1 < lower.length
            ? token.length - 1
            : lower.length;
        for (var length = max; length > held; length--) {
          if (lower.endsWith(token.substring(0, length))) {
            held = length;
            break;
          }
        }
      }
    }
  }
  return held;
}

_HarmonyProjection _projectHarmony(String source, {required bool streaming}) {
  final answer = StringBuffer();
  final offsets = List<int>.filled(source.length + 1, 0);
  final reasoning = <String>[];
  var publicLength = 0;
  var cursor = 0;
  HarmonyAssistantChannel? channel;
  final harmonyThinkChannels = <HarmonyAssistantChannel?>[];
  var reasoningInProgress = false;
  var channelReasoning = StringBuffer();
  var thinkReasoning = StringBuffer();

  bool inHarmonyThink() => harmonyThinkChannels.isNotEmpty;
  bool canPublish() =>
      !inHarmonyThink() && (channel == null || channel.publiclyRenderable);

  void appendPublic(int start, int end) {
    for (var index = start; index < end; index++) {
      answer.writeCharCode(source.codeUnitAt(index));
      publicLength++;
      offsets[index + 1] = publicLength;
    }
  }

  void hide(int start, int end) {
    for (var index = start; index < end; index++) {
      offsets[index + 1] = publicLength;
    }
  }

  void capturePrivate(int start, int end) {
    if (channel == HarmonyAssistantChannel.analysis) {
      channelReasoning.write(source.substring(start, end));
    } else if (inHarmonyThink()) {
      thinkReasoning.write(source.substring(start, end));
    }
    hide(start, end);
  }

  void flushChannelReasoning() {
    final value = channelReasoning.toString().trim();
    if (value.isNotEmpty) reasoning.add(value);
    channelReasoning = StringBuffer();
  }

  void flushThinkReasoning() {
    final value = thinkReasoning.toString().trim();
    if (value.isNotEmpty) reasoning.add(value);
    thinkReasoning = StringBuffer();
  }

  while (cursor < source.length) {
    final token = _nextHarmonyToken(source, cursor);
    if (token == null) {
      if (!canPublish() || inHarmonyThink()) {
        capturePrivate(cursor, source.length);
        if (channel == HarmonyAssistantChannel.analysis || inHarmonyThink()) {
          reasoningInProgress = true;
        }
      } else {
        final held = streaming
            ? _trailingHarmonyTokenPrefixLength(source.substring(cursor))
            : 0;
        appendPublic(cursor, source.length - held);
        hide(source.length - held, source.length);
      }
      cursor = source.length;
      break;
    }

    if (!canPublish() || inHarmonyThink()) {
      capturePrivate(cursor, token.start);
    } else {
      appendPublic(cursor, token.start);
    }

    if (inHarmonyThink()) {
      if (token.name == '/think') {
        hide(token.start, token.end);
        channel = harmonyThinkChannels.removeLast();
        if (!inHarmonyThink()) flushThinkReasoning();
      } else if (token.name == 'think') {
        harmonyThinkChannels.add(channel);
        hide(token.start, token.end);
      } else {
        capturePrivate(token.start, token.end);
      }
      cursor = token.end;
      continue;
    }

    if (token.name == 'start' || token.name == 'channel') {
      final header = _parseHarmonyHeader(source, token, streaming: streaming);
      if (header.status == _HeaderStatus.valid) {
        flushChannelReasoning();
        channel = header.channel;
        hide(token.start, header.end);
        cursor = header.end;
        continue;
      }
      if (header.status == _HeaderStatus.incomplete) {
        if (!canPublish()) {
          capturePrivate(token.start, source.length);
          if (channel == HarmonyAssistantChannel.analysis) {
            reasoningInProgress = true;
          }
        } else {
          hide(token.start, source.length);
        }
        cursor = source.length;
        break;
      }
      if (canPublish()) {
        appendPublic(token.start, token.end);
      } else {
        capturePrivate(token.start, token.end);
      }
      cursor = token.end;
      continue;
    }

    if (token.name == 'end' && channel != null) {
      flushChannelReasoning();
      hide(token.start, token.end);
      channel = null;
      cursor = token.end;
      continue;
    }

    if (token.name == 'think') {
      harmonyThinkChannels.add(channel);
      hide(token.start, token.end);
      cursor = token.end;
      continue;
    }

    // Un token fuera de un envelope no demuestra contenido privado. En modo
    // final se conserva literalmente; esto evita borrar citas malformadas.
    if (canPublish()) {
      appendPublic(token.start, token.end);
    } else {
      capturePrivate(token.start, token.end);
    }
    cursor = token.end;
  }

  flushChannelReasoning();
  if (!inHarmonyThink()) flushThinkReasoning();
  return _HarmonyProjection(
    text: answer.toString(),
    rawToPublicOffset: List<int>.unmodifiable(offsets),
    reasoning: List<String>.unmodifiable(reasoning),
    reasoningInProgress: reasoningInProgress,
  );
}

class _MappedProjection {
  final String text;
  final List<int> sourceToPublicOffset;

  const _MappedProjection(this.text, this.sourceToPublicOffset);
}

final RegExp _classicThinkDelimiter = RegExp(
  r'</?(think|thinking)>',
  caseSensitive: false,
);

int _trailingClassicThinkPrefixLength(String source) {
  final lower = source.toLowerCase();
  var held = 0;
  for (final token in const [
    '<think>',
    '<thinking>',
    '</think>',
    '</thinking>',
  ]) {
    final max = token.length - 1 < lower.length
        ? token.length - 1
        : lower.length;
    for (var length = max; length > held; length--) {
      if (lower.endsWith(token.substring(0, length))) {
        held = length;
        break;
      }
    }
  }
  return held;
}

_MappedProjection _projectClassicThink(
  String source, {
  required bool streaming,
}) {
  final answer = StringBuffer();
  final offsets = List<int>.filled(source.length + 1, 0);
  var publicLength = 0;
  var cursor = 0;
  final privateStack = <String>[];

  void appendPublic(int start, int end) {
    for (var index = start; index < end; index++) {
      answer.writeCharCode(source.codeUnitAt(index));
      publicLength++;
      offsets[index + 1] = publicLength;
    }
  }

  void hide(int start, int end) {
    for (var index = start; index < end; index++) {
      offsets[index + 1] = publicLength;
    }
  }

  for (final match in _classicThinkDelimiter.allMatches(source)) {
    if (privateStack.isEmpty) {
      appendPublic(cursor, match.start);
    } else {
      hide(cursor, match.start);
    }
    final closing = source.codeUnitAt(match.start + 1) == 0x2f;
    final name = (match.group(1) ?? '').toLowerCase();
    if (closing) {
      if (privateStack.isNotEmpty && privateStack.last == name) {
        privateStack.removeLast();
      }
    } else {
      privateStack.add(name);
    }
    hide(match.start, match.end);
    cursor = match.end;
  }

  if (privateStack.isNotEmpty) {
    hide(cursor, source.length);
  } else {
    final held = streaming
        ? _trailingClassicThinkPrefixLength(source.substring(cursor))
        : 0;
    appendPublic(cursor, source.length - held);
    hide(source.length - held, source.length);
  }
  return _MappedProjection(answer.toString(), List<int>.unmodifiable(offsets));
}

AssistantPublicProjection projectPublicAssistantText(
  String raw, {
  required bool streaming,
}) {
  final harmony = _projectHarmony(raw, streaming: streaming);
  final classic = _projectClassicThink(harmony.text, streaming: streaming);
  final composed = <int>[
    for (final harmonyOffset in harmony.rawToPublicOffset)
      classic.sourceToPublicOffset[harmonyOffset],
  ];
  return AssistantPublicProjection._(
    classic.text,
    List<int>.unmodifiable(composed),
  );
}

/// Returns only assistant text safe to publish while more bytes may arrive.
String streamingPublicAssistantText(String raw) =>
    projectPublicAssistantText(raw, streaming: true).text.trim();

/// Returns public text from a completed row/event.
///
/// Invalid envelope-like literals are released byte-for-byte on completion,
/// while bodies behind a valid private header remain withheld even if unclosed.
String finalizedPublicAssistantText(String raw) =>
    projectPublicAssistantText(raw, streaming: false).text;

/// Separa el razonamiento (`<think>…</think>`, `<thinking>…`) de la respuesta.
ReasoningSplit splitReasoning(String content) {
  if (!_thinkTagResidue.hasMatch(content) &&
      !_harmonyDelimiter.hasMatch(content)) {
    return ReasoningSplit(reasoning: '', answer: content);
  }

  final harmony = _projectHarmony(content, streaming: true);
  final parts = <String>[...harmony.reasoning];
  var inProgress = harmony.reasoningInProgress;
  var answer = harmony.text;

  answer = answer.replaceAllMapped(_thinkBlock, (match) {
    final inner = match.group(2)?.trim() ?? '';
    if (inner.isNotEmpty) parts.add(inner);
    return '';
  });
  final open = _thinkOpen.firstMatch(answer);
  if (open != null) {
    final inner = open.group(2)?.trim() ?? '';
    if (inner.isNotEmpty) parts.add(inner);
    answer = answer.substring(0, open.start);
    inProgress = true;
  }
  answer = answer.replaceAll(_thinkTagResidue, '').trim();

  return ReasoningSplit(
    reasoning: parts.join('\n\n').trim(),
    answer: answer,
    reasoningInProgress: inProgress,
  );
}

/// Extrae el razonamiento ESTRUCTURADO que el backend entrega fuera del
/// `content` del mensaje (campos `reasoning_content`/`reasoning` al estilo
/// DeepSeek-reasoner, o la lista `reasoning_details` de OpenRouter). Es la
/// misma señal que el `<think>` inline, pero viajando por metadata: la UI lo
/// muestra como el bloque de razonamiento plegado habitual.
String structuredReasoningText(Map<String, dynamic> metadata) {
  final parts = <String>[];
  for (final key in const ['reasoning_content', 'reasoning']) {
    final value = metadata[key];
    if (value is String && value.trim().isNotEmpty) parts.add(value.trim());
  }
  final details = metadata['reasoning_details'];
  if (details is List) {
    for (final item in details) {
      final text = item is Map ? (item['text'] ?? item['summary']) : item;
      if (text is String && text.trim().isNotEmpty) parts.add(text.trim());
    }
  }
  return parts.join('\n\n');
}

/// Compone el razonamiento estructurado de la metadata del mensaje con el
/// `<think>` inline ya separado en [base]. Si no hay razonamiento estructurado
/// devuelve [base] intacta (cero cambios de comportamiento en el caso normal).
ReasoningSplit mergeStructuredReasoning(
  ReasoningSplit base,
  Map<String, dynamic> metadata,
) {
  final structured = structuredReasoningText(metadata);
  if (structured.isEmpty) return base;
  return ReasoningSplit(
    reasoning: base.reasoning.isEmpty
        ? structured
        : '$structured\n\n${base.reasoning}',
    answer: base.answer,
    reasoningInProgress: base.reasoningInProgress,
  );
}

// Encabezado ATX pegado al marcador: hasta 3 espacios de sangría, 1-6 '#' y a
// continuación una letra (no espacio, no otro '#', no dígito). Captura el caso
// `##Titulo` que CommonMark NO interpreta como encabezado, sin tocar `#1`,
// `#### ya correcto` ni hashtags numéricos.
final RegExp _gluedHeading = RegExp(
  r'^(\s{0,3})(#{1,6})([A-Za-zÁÉÍÓÚÜÑáéíóúüñ].*)$',
);
final RegExp _standaloneInlineCodeLine = RegExp(r'^`[^`\n]+`[.,:;]?\s*$');
final RegExp _numberedBoldHeadingWithTrailingCode = RegExp(
  r'^(\*\*\d+[.)]\s+.+?\*\*)\s+(`[^`\n]+`)\s*$',
);
final RegExp _atxHeadingWithTrailingCode = RegExp(
  r'^(\s{0,3}#{1,6}\s+.+?)\s+(`[^`\n]+`)\s*$',
);
final RegExp _approximationMarker = RegExp(r'(^|[^~])(?:~|≈)\s*(?=\d)');
final RegExp _adjacentInlineCodePunctuation = RegExp(r'`([,;])`');

String _polishInlineMarkdownLine(String line) {
  // Dos spans de código consecutivos necesitan aire tras la puntuación. Sin
  // él, flutter_markdown pinta fondos contiguos y parece que las rutas se han
  // fusionado (`keys`,`locks`).
  final spaced = line.replaceAllMapped(
    _adjacentInlineCodePunctuation,
    (match) => '`${match.group(1)} `',
  );

  // El modelo usa con frecuencia `~123` para "aproximadamente". En prosa se
  // presenta como una abreviatura legible; dentro de backticks se conserva el
  // byte exacto para no alterar rutas ni comandos que el usuario pueda copiar.
  final result = StringBuffer();
  int? codeDelimiterLength;
  var cursor = 0;
  while (cursor < spaced.length) {
    final tick = spaced.indexOf('`', cursor);
    if (tick < 0) {
      final tail = spaced.substring(cursor);
      result.write(
        codeDelimiterLength == null ? _polishProseSegment(tail) : tail,
      );
      break;
    }

    final segment = spaced.substring(cursor, tick);
    result.write(
      codeDelimiterLength == null ? _polishProseSegment(segment) : segment,
    );
    var runEnd = tick + 1;
    while (runEnd < spaced.length && spaced[runEnd] == '`') {
      runEnd++;
    }
    final runLength = runEnd - tick;
    result.write(spaced.substring(tick, runEnd));
    if (codeDelimiterLength == null) {
      codeDelimiterLength = runLength;
    } else if (codeDelimiterLength == runLength) {
      codeDelimiterLength = null;
    }
    cursor = runEnd;
  }
  return result.toString();
}

String _polishProseSegment(String value) => value.replaceAllMapped(
  _approximationMarker,
  (match) => '${match.group(1)}aprox. ',
);

/// Retoques conservadores del Markdown del asistente, fuera de bloques de
/// código. Inserta el espacio que falta tras los `#` de un encabezado pegado
/// (`##Titulo` → `## Titulo`) y conserva como bloque una línea formada solo
/// por código inline. Esto evita que CommonMark pegue una ruta como
/// `` `/home/backups` `` al encabezado anterior y la parta de forma arbitraria.
String tidyAssistantMarkdown(String text) {
  if (text.isEmpty) return text;
  final lines = text.split('\n');
  var inFence = false;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    // CommonMark también admite bloques de código sin valla mediante cuatro
    // espacios (o tab). No se debe tipografiar ni reescribir su contenido.
    if (lines[i].startsWith('    ') || lines[i].startsWith('\t')) continue;
    lines[i] = _polishInlineMarkdownLine(lines[i]);
    final m = _gluedHeading.firstMatch(lines[i]);
    if (m != null) {
      lines[i] = '${m.group(1)}${m.group(2)} ${m.group(3)}';
    }
    final trailingCode =
        _numberedBoldHeadingWithTrailingCode.firstMatch(lines[i]) ??
        _atxHeadingWithTrailingCode.firstMatch(lines[i]);
    if (trailingCode != null) {
      lines[i] = trailingCode.group(1)!;
      lines.insert(i + 1, trailingCode.group(2)!);
    }
  }

  final separated = <String>[];
  inFence = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
    }
    final standaloneCode =
        !inFence && line == trimmed && _standaloneInlineCodeLine.hasMatch(line);
    if (standaloneCode &&
        separated.isNotEmpty &&
        separated.last.trim().isNotEmpty) {
      separated.add('');
    }
    separated.add(line);
    if (standaloneCode &&
        i + 1 < lines.length &&
        lines[i + 1].trim().isNotEmpty) {
      separated.add('');
    }
  }
  return separated.join('\n');
}

// HTML inline que algunos modelos insertan en la respuesta. El render Markdown
// no tiene builders HTML y lo descartaría en silencio, así que convertimos los
// tags comunes a su equivalente de texto plano antes de parsear.
final RegExp _inlineHtmlBreak = RegExp(r'<br\s*/?>', caseSensitive: false);
final RegExp _inlineHtmlDetailsTag = RegExp(
  r'</?details(\s[^>]*)?>',
  caseSensitive: false,
);
final RegExp _inlineHtmlSummaryTag = RegExp(
  r'</?summary(\s[^>]*)?>',
  caseSensitive: false,
);

/// Fallback conservador para el HTML inline que `MarkdownBody` descarta sin
/// `extensionSet` ni builders. Convierte `<br>` en saltos de línea y desenvuelve
/// `<details>`/`<summary>` conservando su contenido como texto plano. NO es un
/// engine HTML: el resto de etiquetas se deja intacto (ante la duda, no tocar).
/// Respeta vallas ``` y spans de código inline, donde un tag es un literal.
String flattenInlineHtml(String text) {
  if (!text.contains('<')) return text;
  final lines = text.split('\n');
  var inFence = false;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    lines[i] = _flattenInlineHtmlLine(lines[i]);
  }
  return lines.join('\n');
}

String _flattenInlineHtmlLine(String line) {
  if (!line.contains('<')) return line;
  // Alterna segmentos fuera/dentro de código inline (separados por backtick):
  // solo se transforman los pares, como en escapePathGlobs.
  final segments = line.split('`');
  for (var i = 0; i < segments.length; i += 2) {
    var segment = segments[i];
    if (!segment.contains('<')) continue;
    segment = segment
        .replaceAll(_inlineHtmlBreak, '\n')
        .replaceAll(_inlineHtmlDetailsTag, '\n')
        .replaceAll(_inlineHtmlSummaryTag, '');
    segments[i] = segment;
  }
  final out = StringBuffer();
  for (var i = 0; i < segments.length; i++) {
    out.write(segments[i]);
    if (i < segments.length - 1) out.write('`');
  }
  return out.toString();
}
