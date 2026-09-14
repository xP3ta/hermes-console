import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Canonical TUI status pill used across the app.
///
/// Estilo outline de las referencias (LIVE / READ ONLY): texto uppercase
/// mono 10px, fondo casi transparente (alpha 0.07), borde del color de estado.
class HermesPill extends StatelessWidget {
  final Color color;
  final String label;
  final bool showDot;

  const HermesPill({
    required this.color,
    required this.label,
    this.showDot = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.40), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                // 10px como base mínima legible de las pills (spec 028 A-113).
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact TUI-style loading indicator.
///
/// A 16×16 CircularProgressIndicator with strokeWidth 1.5 next to a
/// lowercase mono label. Replaces bare CircularProgressIndicator spinners.
class TuiLoader extends StatelessWidget {
  final String? label;

  const TuiLoader({this.label, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final effectiveLabel =
        label ??
        Localizations.of<Strings>(context, Strings)?.commonLoading ??
        'Loading…';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: colors.accent,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          effectiveLabel,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
      ],
    );
  }
}
