import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class StaleRunningSessionBanner extends StatelessWidget {
  const StaleRunningSessionBanner({
    required this.enabled,
    required this.onStop,
    super.key,
  });

  final bool enabled;
  final VoidCallback onStop;

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
            Text(
              strings.chaStaleRunningStopTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              strings.chaStaleRunningStopBody,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonalIcon(
                key: const ValueKey('stale-running-session-stop'),
                onPressed: enabled ? onStop : null,
                icon: const Icon(Icons.stop_rounded, size: 18),
                label: Text(strings.chaStaleRunningStopAction),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
