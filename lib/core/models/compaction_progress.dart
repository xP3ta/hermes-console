/// Lo que se sabe de una compactación, y nada más.
///
/// Hermes Agent NO publica porcentaje ni progreso de la compactación: solo un
/// inicio (`status.update` `compacting`/`compressing`, con latidos periódicos) y
/// un final (`compacted`, o el resultado de `session.compress`). Por eso esta
/// clase solo guarda hechos reales: el tiempo medido en el dispositivo, los
/// recuentos que la línea de estado trae (`compressing N messages (~T tok)`), el
/// resultado exacto de un `/compress` y —solo si el backend algún día lo
/// publica— el trozo `chunk_index / chunk_count`. No hay estimaciones.
final class CompactionProgress {
  const CompactionProgress({
    required this.startedAt,
    required this.manual,
    this.tokensBefore,
    this.messagesBefore,
    this.chunkIndex,
    this.chunkCount,
    this.finishedAt,
    this.tokensAfter,
    this.messagesAfter,
    this.noop = false,
  });

  final DateTime startedAt;

  /// `/compress` (o «Comprimir ahora») frente a la compactación automática.
  final bool manual;
  final int? tokensBefore;
  final int? messagesBefore;

  /// Progreso determinado real (trozo actual / total), o `null`.
  final int? chunkIndex;
  final int? chunkCount;

  /// No nulo cuando la compactación terminó.
  final DateTime? finishedAt;
  final int? tokensAfter;
  final int? messagesAfter;

  /// Terminó sin cambiar la conversación (no-op, rechazada o abortada sin
  /// tocar el transcript): «Nada que compactar».
  final bool noop;

  bool get isFinished => finishedAt != null;

  Duration elapsed(DateTime now) {
    final end = finishedAt ?? now;
    final value = end.difference(startedAt);
    return value.isNegative ? Duration.zero : value;
  }

  /// Duración total, solo una vez terminada.
  Duration? get duration => finishedAt == null ? null : elapsed(finishedAt!);

  /// Fracción `0..1` SOLO si el backend publicó el trozo actual y el total.
  double? get fraction {
    final index = chunkIndex;
    final count = chunkCount;
    if (isFinished || index == null || count == null || count <= 0) return null;
    return (index / count).clamp(0.0, 1.0).toDouble();
  }

  CompactionProgress copyWith({
    DateTime? finishedAt,
    int? tokensBefore,
    int? tokensAfter,
    int? messagesBefore,
    int? messagesAfter,
    int? chunkIndex,
    int? chunkCount,
    bool? noop,
  }) => CompactionProgress(
    startedAt: startedAt,
    manual: manual,
    tokensBefore: tokensBefore ?? this.tokensBefore,
    messagesBefore: messagesBefore ?? this.messagesBefore,
    chunkIndex: chunkIndex ?? this.chunkIndex,
    chunkCount: chunkCount ?? this.chunkCount,
    finishedAt: finishedAt ?? this.finishedAt,
    tokensAfter: tokensAfter ?? this.tokensAfter,
    messagesAfter: messagesAfter ?? this.messagesAfter,
    noop: noop ?? this.noop,
  );
}

/// Lee un progreso determinado de un payload de estado, o `null`.
///
/// Solo acepta los campos `chunk_index` (trozo actual, `0..count`) y
/// `chunk_count` (total, `> 0`). El backend actual NO los envía: cualquier otro
/// nombre («progress», «percent»…) se ignora a propósito, para no inventar una
/// barra a partir de un campo que no significa lo que parece.
({int index, int count})? parseCompactionChunks(Map<String, dynamic> payload) {
  int? whole(Object? raw) => raw is int
      ? raw
      : raw is num && raw == raw.roundToDouble()
      ? raw.toInt()
      : null;
  final index = whole(payload['chunk_index']);
  final count = whole(payload['chunk_count']);
  if (index == null || count == null || count <= 0) return null;
  if (index < 0 || index > count) return null;
  return (index: index, count: count);
}

/// Formatea tokens de forma compacta: `842`, `12.4k`, `180k`, `1.2M`.
String formatCompactTokens(int tokens) {
  if (tokens <= 0) return '0';
  if (tokens >= 999950) {
    final compact = (tokens / 1000000).toStringAsFixed(1);
    return '${compact.replaceFirst(RegExp(r'\.0$'), '')}M';
  }
  if (tokens >= 1000) {
    final compact = (tokens / 1000).toStringAsFixed(1);
    return '${compact.replaceFirst(RegExp(r'\.0$'), '')}k';
  }
  return '$tokens';
}
