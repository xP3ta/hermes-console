import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class StaleRunningSessionBanner extends StatelessWidget {
  const StaleRunningSessionBanner({
    required this.enabled,
    required this.onStop,
    required this.onDismiss,
    super.key,
  });

  final bool enabled;
  final VoidCallback onStop;

  /// Cierra el aviso sin detener nada: la sesión sigue trabajando.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Semantics(
      container: true,
      label: strings.chaStaleRunningStopTitle,
      child: Container(
        key: const ValueKey('stale-running-session-stop-banner'),
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      strings.chaStaleRunningStopTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('stale-running-session-dismiss'),
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: strings.chaStaleRunningDismiss,
                  // 48 dp de área táctil aunque el icono sea compacto.
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
              ],
            ),
            Text(
              strings.chaStaleRunningStopBody,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  key: const ValueKey('stale-running-session-keep'),
                  onPressed: onDismiss,
                  child: Text(strings.chaStaleRunningKeepAction),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('stale-running-session-stop'),
                  onPressed: enabled ? onStop : null,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: Text(strings.chaStaleRunningStopAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
