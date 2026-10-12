import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/compaction_progress.dart';
import '../theme/app_theme.dart';
import 'activity_pill.dart' show ActivityTicker, formatTurnElapsed;

/// Duración de una compactación en segundos enteros («71 s»), con un decimal por
/// debajo de 10 s y `m:ss` pasados 3 minutos.
String formatCompactionDuration(Duration value, {String languageCode = 'en'}) {
  final ms = value.inMilliseconds;
  if (ms < 10000) {
    final text = (ms / 1000).toStringAsFixed(1);
    return '${languageCode == 'es' ? text.replaceAll('.', ',') : text} s';
  }
  if (ms < 180000) return '${value.inSeconds} s';
  return formatTurnElapsed(value);
}

/// Hechos conocidos mientras compacta («22 msj · ~21.5k tok · parte 2 de 4»).
/// Solo lo que el backend ha dicho.
List<String> compactionFacts(Strings strings, CompactionProgress compaction) =>
    [
      if (compaction.messagesBefore != null)
        strings.liveCompactionMessagesShort(compaction.messagesBefore!),
      if (compaction.tokensBefore != null)
        strings.liveCompactionTokensShort(
          formatCompactTokens(compaction.tokensBefore!),
        ),
      if (compaction.chunkIndex != null && compaction.chunkCount != null)
        strings.liveCompactionChunks(
          compaction.chunkIndex!,
          compaction.chunkCount!,
        ),
    ];

/// El desenlace, como el titular de Hermes Desktop («Compressed: 34 → 12
/// messages» / «No changes from compression: 6 messages»), con solo las cifras
/// que el backend dio: «Compactado · 34 → 12 mensajes · 30.3k → 25.7k tokens»
/// o «Nada que compactar · 6 mensajes». Sin cifras, la duración medida.
String compactionResultText(
  Strings strings,
  CompactionProgress compaction,
  String languageCode,
) {
  if (compaction.noop) {
    return [
      strings.liveCompactionNothing,
      if (compaction.messagesBefore != null)
        strings.liveCompactionMessagesCount(compaction.messagesBefore!),
    ].join(' · ');
  }
  final facts = [
    if (compaction.messagesBefore != null && compaction.messagesAfter != null)
      strings.liveCompactionMessagesChange(
        compaction.messagesBefore!,
        compaction.messagesAfter!,
      ),
    if (compaction.tokensBefore != null && compaction.tokensAfter != null)
      strings.liveCompactionTokensChange(
        formatCompactTokens(compaction.tokensBefore!),
        formatCompactTokens(compaction.tokensAfter!),
      ),
  ];
  return [
    strings.liveCompactionDone,
    ...facts,
    if (facts.isEmpty && compaction.duration != null)
      formatCompactionDuration(
        compaction.duration!,
        languageCode: languageCode,
      ),
  ].join(' · ');
}

/// Texto completo de la compactación para lectores de pantalla y el panel:
/// «Compactando · 22 msj · ~21.5k tok» en curso, el desenlace al terminar.
String compactionStatusText(
  Strings strings,
  CompactionProgress compaction,
  String languageCode,
) => compaction.isFinished
    ? compactionResultText(strings, compaction, languageCode)
    : [
        strings.liveCompacting,
        ...compactionFacts(strings, compaction),
      ].join(' · ');

/// Estado de la compactación dentro de la mini píldora de contexto+modo
/// bajo el composer: sustituye al aro y al porcentaje mientras dura.
///
///  * en curso: aro indeterminado (determinado solo si el backend publica
///    `chunk_index/chunk_count`) + «Compactando…» + reloj medido;
///  * terminada: ✓ + «Compactada» unos segundos (los que el tracker retiene
///    el resultado) y la píldora vuelve sola a su porcentaje.
///
/// Las cifras (mensajes, tokens, partes) no caben aquí: van en la etiqueta
/// semántica y en el panel que abre la píldora. Sin estimaciones.
class CompactionPillSegment extends StatelessWidget {
  const CompactionPillSegment({
    required this.compaction,
    this.clock,
    this.fontSize = 10.5,
    super.key,
  });

  final CompactionProgress compaction;
  final DateTime Function()? clock;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final lang = Localizations.localeOf(context).languageCode;
    final finished = compaction.isFinished;
    final label = finished
        ? (compaction.noop
              ? strings.tp1216PillNothingToCompact
              : strings.tp1216PillCompacted)
        : strings.tp1216PillCompacting;
    return Semantics(
      key: ValueKey(
        finished ? 'compaction-result' : 'desktop-session-compression-progress',
      ),
      liveRegion: true,
      container: true,
      label: compactionStatusText(strings, compaction, lang),
      excludeSemantics: true,
      child: ActivityTicker(
        active: !finished,
        clock: clock,
        builder: (context, now) => Row(
          key: const ValueKey('compaction-dock'),
          mainAxisSize: MainAxisSize.min,
          children: [
            CompactionGlyph(compaction: compaction),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                key: const ValueKey('compaction-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (!finished) ...[
              const SizedBox(width: 5),
              Text(
                formatTurnElapsed(compaction.elapsed(now)),
                key: const ValueKey('compaction-elapsed'),
                maxLines: 1,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: colors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Indicador mínimo para superficies sin la píldora de contexto (Bot Chat):
/// la misma cápsula pequeña bajo el composer, solo con la compactación.
class CompactionInlineIndicator extends StatelessWidget {
  const CompactionInlineIndicator({
    required this.compaction,
    this.clock,
    super.key,
  });

  final CompactionProgress compaction;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      key: const ValueKey('compaction-inline-indicator'),
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.divider.withValues(alpha: 0.7)),
      ),
      child: CompactionPillSegment(compaction: compaction, clock: clock),
    );
  }
}

/// Aro fino mientras trabaja (determinado solo con trozos reales publicados),
/// ✓ al terminar. Con movimiento reducido, un aro quieto.
class CompactionGlyph extends StatelessWidget {
  const CompactionGlyph({required this.compaction, this.size = 14, super.key});

  final CompactionProgress compaction;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (compaction.isFinished) {
      return Icon(
        compaction.noop
            ? Icons.check_circle_outline_rounded
            : Icons.check_circle_rounded,
        key: const ValueKey('compaction-done-icon'),
        size: size + 1,
        color: compaction.noop ? colors.textSecondary : colors.success,
      );
    }
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final fraction = compaction.fraction;
    return SizedBox.square(
      key: const ValueKey('compaction-spinner'),
      dimension: size,
      child: CircularProgressIndicator(
        value: fraction ?? (reduceMotion ? 0.25 : null),
        strokeWidth: 2,
        strokeCap: StrokeCap.round,
        backgroundColor: colors.divider,
        color: colors.accent,
      ),
    );
  }
}
