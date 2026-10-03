import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Aviso en flujo de un turno recuperado cuya entrega no está confirmada.
///
/// Vive en el grupo inferior del chat (encima del composer), nunca sobre la
/// barra superior: no tapa el menú ni el selector de modelo. El mensaje se
/// ajusta en varias líneas sin elipsis porque explica qué hacer con el turno.
class RecoveredTurnBanner extends StatelessWidget {
  const RecoveredTurnBanner({
    required this.message,
    required this.discardLabel,
    required this.onDiscard,
    required this.dismissTooltip,
    required this.onDismiss,
    this.keepsDraftHint,
    this.restoreLabel,
    this.onRestore,
    super.key = const ValueKey('recovered-turn-banner'),
  });

  final String message;

  /// Explica que el borrador actual del usuario se conserva.
  final String? keepsDraftHint;

  /// Null oculta la acción (turnos que no vuelven al composer).
  final String? restoreLabel;

  /// Null deshabilita restaurar (el composer contiene otro borrador).
  final VoidCallback? onRestore;
  final String discardLabel;
  final VoidCallback onDiscard;
  final String dismissTooltip;

  /// Oculta el aviso sin descartar nada: el turno sigue en la outbox.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.warning.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, right: 8),
                  child: Icon(
                    Icons.help_outline_rounded,
                    size: 18,
                    color: colors.warning,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      message,
                      key: const ValueKey('recovered-turn-message'),
                      softWrap: true,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.textPrimary,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('recovered-turn-dismiss'),
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: dismissTooltip,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
              ],
            ),
            if (keepsDraftHint case final hint?)
              Padding(
                padding: const EdgeInsets.only(left: 26, right: 8, top: 2),
                child: Text(
                  hint,
                  key: const ValueKey('recovered-turn-keeps-draft'),
                  softWrap: true,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (restoreLabel case final label?)
                    TextButton(
                      key: const ValueKey('recovered-turn-restore'),
                      onPressed: onRestore,
                      child: Text(label),
                    ),
                  FilledButton.tonal(
                    key: const ValueKey('recovered-turn-discard'),
                    onPressed: onDiscard,
                    child: Text(discardLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
