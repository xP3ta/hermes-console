import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/compaction_progress.dart';
import '../theme/app_theme.dart';
import 'activity_pill.dart'
    show ActivityTicker, activityTextScale, formatTurnElapsed;

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

/// Pastilla flotante de la compactación, del mismo lenguaje que la pastilla
/// de actividad: se ajusta a su contenido, sin barra.
///
///  * en curso: aro indeterminado (o determinado si el backend publica
///    `chunk_index/chunk_count`) + «Compactando» + hechos atenuados + reloj;
///  * terminada: la misma pastilla cambia a ✓ + el desenlace unos segundos.
///
/// El reloj es el medido en el dispositivo; no hay tiempo restante estimado.
class CompactionDock extends StatelessWidget {
  const CompactionDock({required this.compaction, this.clock, super.key});

  final CompactionProgress compaction;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final finished = compaction.isFinished;
    return ActivityTicker(
      active: !finished,
      clock: clock,
      builder: (context, now) {
        final label = finished
            ? compactionResultText(strings, compaction, lang)
            : strings.liveCompacting;
        final facts = finished
            ? const <String>[]
            : compactionFacts(strings, compaction);
        return _CompactionPill(
          compaction: compaction,
          label: label,
          facts: facts,
          elapsed: finished ? null : formatTurnElapsed(compaction.elapsed(now)),
        );
      },
    );
  }
}

class _CompactionPill extends StatelessWidget {
  const _CompactionPill({
    required this.compaction,
    required this.label,
    required this.facts,
    required this.elapsed,
  });

  final CompactionProgress compaction;
  final String label;
  final List<String> facts;
  final String? elapsed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final finished = compaction.isFinished;
    final bigText = activityTextScale(context) >= 1.6;
    final factsText = facts.join(' · ');
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: label,
            style: TextStyle(
              fontWeight: finished ? FontWeight.w600 : FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          if (factsText.isNotEmpty)
            TextSpan(
              text: ' · $factsText',
              style: TextStyle(color: colors.textSecondary),
            ),
        ],
      ),
      key: const ValueKey('compaction-label'),
      maxLines: bigText ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, height: 1.25),
    );
    return Semantics(
      key: ValueKey(
        finished ? 'compaction-result' : 'desktop-session-compression-progress',
      ),
      liveRegion: true,
      container: true,
      label: [label, ...facts].join(', '),
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('compaction-dock'),
        color: colors.surface,
        shape: StadiumBorder(
          side: BorderSide(color: colors.divider, width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 14, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CompactionGlyph(compaction: compaction),
                const SizedBox(width: 9),
                Flexible(child: text),
                if (elapsed != null) ...[
                  const SizedBox(width: 9),
                  Text(
                    elapsed!,
                    key: const ValueKey('compaction-elapsed'),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Aro fino mientras trabaja (determinado solo con trozos reales publicados),
/// ✓ al terminar. Con movimiento reducido, un aro quieto.
class _CompactionGlyph extends StatelessWidget {
  const _CompactionGlyph({required this.compaction});

  final CompactionProgress compaction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (compaction.isFinished) {
      return Icon(
        compaction.noop
            ? Icons.check_circle_outline_rounded
            : Icons.check_circle_rounded,
        key: const ValueKey('compaction-done-icon'),
        size: 16,
        color: compaction.noop ? colors.textSecondary : colors.success,
      );
    }
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final fraction = compaction.fraction;
    return SizedBox.square(
      key: const ValueKey('compaction-spinner'),
      dimension: 14,
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
