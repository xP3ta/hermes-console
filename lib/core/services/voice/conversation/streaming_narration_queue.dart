import '../read_aloud_session.dart';
import '../speech_renderer.dart';

class StreamingNarrationUpdate {
  final bool queueChanged;
  final bool revisionChanged;

  /// Índice del primer chunk cuyo TEXTO divergió respecto a la cola anterior,
  /// o -1 si la actualización fue una extensión pura. Diagnóstico: la decisión
  /// de cortar ya viene tomada en [revisionChanged] (valla de reproducción).
  final int divergenceIndex;

  const StreamingNarrationUpdate({
    required this.queueChanged,
    required this.revisionChanged,
    this.divergenceIndex = -1,
  });
}

/// Cola incremental de la respuesta visible que puede narrarse sin leer una
/// frase todavía inestable. No aplica un presupuesto de turno: el límite es
/// únicamente un techo defensivo muy alto para una respuesta patológica.
class StreamingNarrationQueue {
  StreamingNarrationQueue({
    required String language,
    this.maxChunkChars = 160,
    this.safetyCeilingChars = 200000,
  }) : _renderer = SpeechRenderer(language: language);

  final SpeechRenderer _renderer;
  final int maxChunkChars;
  final int safetyCeilingChars;

  String _rawObserved = '';
  List<ReadAloudChunk> _chunks = const [];
  int _cursor = 0;
  int _revision = 0;
  int _playbackFence = 0;
  bool _terminal = false;
  bool _silenced = false;
  bool _paused = false;

  /// The raw text last released by a flush; a later observe of the same text
  /// keeps it released.
  String? _flushedRaw;

  String get rawObserved => _rawObserved;
  List<ReadAloudChunk> get chunks => _chunks;
  int get cursor => _cursor;
  int get revision => _revision;
  bool get terminal => _terminal;
  bool get silenced => _silenced;
  bool get paused => _paused;
  bool get hasPending =>
      !_silenced && !_paused && _cursor >= 0 && _cursor < _chunks.length;
  ReadAloudChunk? get current => hasPending ? _chunks[_cursor] : null;

  void reset() {
    _revision++;
    _rawObserved = '';
    _flushedRaw = null;
    _chunks = const [];
    _cursor = 0;
    _playbackFence = 0;
    _terminal = false;
    _silenced = false;
    _paused = false;
  }

  /// Valla de reproducción (spec 048/US1): el controlador la fija justo antes
  /// de encolar un lote `[cursor, endExclusive)`. Solo una divergencia POR
  /// DEBAJO de la valla invalida la reproducción; lo demás es una simple
  /// actualización de cola pendiente.
  void markPlaybackThrough(int endExclusive) {
    _playbackFence = endExclusive.clamp(_cursor, _chunks.length).toInt();
  }

  /// Fin exclusivo del lote comprometido con el reproductor. El controlador lo
  /// usa como arranque del siguiente lote a pre-sintetizar (spec 048/US3).
  int get playbackFence => _playbackFence;

  /// [flush] releases the last, unpunctuated sentence without ending the
  /// turn: a sealed bubble while its tool runs, as Desktop's
  /// `session.flush()` (`use-voice-conversation.ts:687-693`).
  StreamingNarrationUpdate observe(
    String visibleMarkdown, {
    bool terminal = false,
    bool flush = false,
  }) {
    assert(maxChunkChars > 0);
    assert(safetyCeilingChars > 0);
    final bounded = visibleMarkdown.length <= safetyCeilingChars
        ? visibleMarkdown
        : visibleMarkdown.substring(0, safetyCeilingChars);
    final release = terminal || flush;
    if (bounded == _rawObserved &&
        (!terminal || _terminal) &&
        (!flush || _flushedRaw == bounded)) {
      return const StreamingNarrationUpdate(
        queueChanged: false,
        revisionChanged: false,
      );
    }
    if (flush) _flushedRaw = bounded;

    final segments = _renderer.render(bounded);
    final rendered = chunkNarrationSegments(segments, maxChars: maxChunkChars);
    var stable = _stablePrefix(
      rendered,
      bounded,
      terminal: release || _flushedRaw == bounded,
    );
    stable = _coalesceOpeningHeadings(segments, stable, terminal: release);

    // El renderer puede rebajar la pausa de una frase que antes era final al
    // aparecer la siguiente. Su texto ya era estable y quizá ya sonó: conserva
    // el par anterior para que la cola siga siendo prefijo de sí misma. Vale
    // igual para appends y para reescrituras: solo el TEXTO decide divergencia.
    final merged = <ReadAloudChunk>[];
    for (var index = 0; index < stable.length; index++) {
      final candidate = stable[index];
      if (index < _chunks.length && _chunks[index].text == candidate.text) {
        merged.add(_chunks[index]);
      } else {
        merged.add(candidate);
      }
    }
    final next = List<ReadAloudChunk>.unmodifiable(merged);

    // Divergencia = primer chunk cuyo texto cambió o desapareció. Una
    // extensión pura (la cola vieja es prefijo de la nueva) no diverge.
    final commonText = _commonTextPrefix(_chunks, next);
    final divergenceIndex = commonText == _chunks.length ? -1 : commonText;

    // Valla de reproducción (spec 048/US1): solo invalida la reproducción una
    // divergencia que toca texto ya comprometido (< valla). Una reescritura
    // por delante sustituye la cola pendiente sin cortar ni retroceder.
    final revisionChanged =
        divergenceIndex >= 0 && divergenceIndex < _playbackFence;

    if (revisionChanged) {
      _revision++;
      final commonCompleted = _commonExactPrefix(_chunks, next);
      final acceptedOverlap = _resumeAfterAcceptedOverlap(
        _chunks,
        _playbackFence,
        next,
      );
      // Un final autoritativo puede añadir una entradilla o reagrupar Markdown
      // delante de un cuerpo que el motor ya aceptó. Ese audio terminará antes
      // del cambio de revisión: si el cuerpo completo reaparece de forma exacta
      // y suficientemente larga, continúa detrás de él en vez de leerlo otra
      // vez. Las correcciones reales (sin solapamiento fiable) conservan el
      // rollback histórico al prefijo común.
      final reconciledCursor = acceptedOverlap ?? commonCompleted;
      _cursor = reconciledCursor.clamp(0, next.length).toInt();
      _playbackFence = _cursor;
    } else {
      if (_cursor > next.length) _cursor = next.length;
      if (_playbackFence > next.length) _playbackFence = next.length;
    }

    final changed = !_sameChunks(_chunks, next);
    _rawObserved = bounded;
    _chunks = List.unmodifiable(next);
    _terminal = _terminal || terminal;
    return StreamingNarrationUpdate(
      queueChanged: changed,
      revisionChanged: revisionChanged,
      divergenceIndex: divergenceIndex,
    );
  }

  /// Avanza solo si termina la revisión que empezó a reproducirse. Una
  /// completion vieja después de Pause/Stop/reconciliación no mueve el cursor.
  bool completeCurrent(int expectedRevision) {
    if (expectedRevision != _revision || _cursor >= _chunks.length) {
      return false;
    }
    _cursor++;
    // Un chunk completado queda comprometido para siempre: la valla nunca
    // puede quedar por debajo de lo ya hablado.
    if (_playbackFence < _cursor) _playbackFence = _cursor;
    return true;
  }

  void pause() => _paused = true;

  void resume() => _paused = false;

  /// Stop-and-talk descarta únicamente el audio pendiente de esta revisión.
  /// El texto y el cursor quedan como contexto visible/diagnosticable.
  void silence() {
    _silenced = true;
    _paused = false;
    _playbackFence = _cursor;
  }

  /// Un steering aceptado continúa dentro del mismo run y no emite `started`.
  /// Descarta todo lo ya visible mientras el usuario interrumpía y vuelve a
  /// habilitar únicamente los chunks que aparezcan a partir de ahora.
  void resumeFromVisibleEnd() {
    _cursor = _chunks.length;
    _playbackFence = _cursor;
    _silenced = false;
    _paused = false;
  }

  List<ReadAloudChunk> _stablePrefix(
    List<ReadAloudChunk> rendered,
    String raw, {
    required bool terminal,
  }) {
    if (terminal || rendered.isEmpty || _endsAtSemanticBoundary(raw)) {
      return rendered;
    }
    return List<ReadAloudChunk>.unmodifiable(
      rendered.take(rendered.length - 1),
    );
  }

  /// Un encabezado Markdown corto suele llegar antes que el primer párrafo del
  /// streaming. Publicarlo solo obliga al TTS neuronal a generar dos audios y
  /// deja un silencio largo entre ambos. Lo retenemos únicamente al principio
  /// del turno hasta que exista una unidad oral estable que pueda compartir el
  /// mismo lote; una respuesta terminal nunca se pierde.
  List<ReadAloudChunk> _coalesceOpeningHeadings(
    List<NarrationSegment> segments,
    List<ReadAloudChunk> stable, {
    required bool terminal,
  }) {
    if (terminal ||
        stable.isEmpty ||
        _cursor != 0 ||
        _playbackFence != 0 ||
        segments.isEmpty ||
        segments.first.sourceKind != NarrationSourceKind.heading) {
      return stable;
    }

    final headings = <NarrationSegment>[];
    var headingChars = 0;
    for (final segment in segments) {
      if (segment.sourceKind != NarrationSourceKind.heading) break;
      headings.add(segment);
      headingChars += segment.text.length;
    }
    if (headings.isEmpty || headingChars > 96) return stable;

    final headingChunks = chunkNarrationSegments(
      headings,
      maxChars: maxChunkChars,
    ).length;
    return stable.length <= headingChunks ? const [] : stable;
  }

  static bool _endsAtSemanticBoundary(String raw) {
    final right = raw.trimRight();
    if (right.isEmpty) return false;
    if (raw.endsWith('\n')) return true;
    return const {'.', '!', '?', '…'}.contains(right[right.length - 1]);
  }

  static int _commonTextPrefix(
    List<ReadAloudChunk> before,
    List<ReadAloudChunk> after,
  ) {
    final limit = before.length < after.length ? before.length : after.length;
    var index = 0;
    while (index < limit && before[index].text == after[index].text) {
      index++;
    }
    return index;
  }

  static int _commonExactPrefix(
    List<ReadAloudChunk> before,
    List<ReadAloudChunk> after,
  ) {
    final limit = before.length < after.length ? before.length : after.length;
    var index = 0;
    while (index < limit &&
        before[index].text == after[index].text &&
        before[index].pauseAfter == after[index].pauseAfter) {
      index++;
    }
    return index;
  }

  static int? _resumeAfterAcceptedOverlap(
    List<ReadAloudChunk> before,
    int playbackFence,
    List<ReadAloudChunk> after,
  ) {
    if (playbackFence <= 0 || before.isEmpty || after.isEmpty) return null;
    final acceptedEnd = playbackFence.clamp(0, before.length).toInt();
    final accepted = _normalizedChunkText(before.take(acceptedEnd));
    // Evita que una coincidencia incidental como "Sí." o una fecha salte texto
    // nuevo. La reproducción física que motivó esta reconciliación abarcaba
    // varios lotes y cientos de caracteres.
    if (accepted.length < 48 || accepted.split(' ').length < 6) return null;

    final authoritative = _normalizedChunkText(after);
    final matchStart = authoritative.indexOf(accepted);
    if (matchStart < 0) return null;
    final matchEnd = matchStart + accepted.length;
    final startsAtBoundary =
        matchStart == 0 || authoritative.codeUnitAt(matchStart - 1) == 0x20;
    final endsAtBoundary =
        matchEnd == authoritative.length ||
        authoritative.codeUnitAt(matchEnd) == 0x20;
    if (!startsAtBoundary || !endsAtBoundary) return null;

    // Solo reanuda en una frontera real de chunk. Saltar hasta mitad de una
    // frase podría omitir un sufijo que todavía no llegó al altavoz.
    var prefixLength = 0;
    for (var index = 0; index < after.length; index++) {
      final chunk = _normalizeChunkText(after[index].text);
      if (chunk.isNotEmpty) {
        if (prefixLength > 0) prefixLength++;
        prefixLength += chunk.length;
      }
      if (prefixLength == matchEnd) return index + 1;
      if (prefixLength > matchEnd) return null;
    }
    return null;
  }

  static String _normalizedChunkText(Iterable<ReadAloudChunk> chunks) => chunks
      .map((chunk) => _normalizeChunkText(chunk.text))
      .where((text) => text.isNotEmpty)
      .join(' ')
      .trim();

  static String _normalizeChunkText(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static bool _sameChunks(
    List<ReadAloudChunk> before,
    List<ReadAloudChunk> after,
  ) {
    if (before.length != after.length) return false;
    return _commonExactPrefix(before, after) == before.length;
  }
}
