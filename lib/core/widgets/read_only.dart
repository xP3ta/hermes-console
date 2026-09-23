import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';
import 'hermes_notice.dart';

/// Pill discreta que marca una instancia en modo solo lectura.
class ReadOnlyBadge extends StatelessWidget {
  /// Versión mini para AppBars y filas densas.
  final bool compact;

  const ReadOnlyBadge({this.compact = false, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.visibility_outlined,
            size: compact ? 10 : 11,
            color: colors.warning,
          ),
          const SizedBox(width: 4),
          Text(
            Strings.of(context).readOnlyBadge,
            style: TextStyle(
              fontSize: compact ? 8.5 : 9.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: colors.warning,
            ),
          ),
        ],
      ),
    );
  }
}

/// Aviso estándar al intentar una acción de escritura en una instancia
/// de solo lectura.
void showReadOnlyNotice(BuildContext context) {
  HermesNotice.of(context).showSnackBar(
    SnackBar(
      content: Text(
        Strings.of(context).readOnlyNotice,
        style: const TextStyle(fontSize: 13),
      ),
      duration: const Duration(seconds: 2),
    ),
  );
}
