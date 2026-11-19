import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/semantic_markdown.dart';
import 'accent_card.dart';

/// Tarjeta de hallazgo: realza un problema/advertencia/error de la respuesta
/// para que el usuario lo identifique de un vistazo.
///
/// Solo presentación. Usa [AccentCard] (la única forma segura de pintar la tira
/// de color a la izquierda sin caer en la trampa `borderRadius` + `Border` no
/// uniforme) y colores que YA define el tema (warning/error): no introduce
/// colores nuevos ni cambia la paleta.
class CalloutCard extends StatelessWidget {
  final CalloutKind kind;
  final String title;
  final String body;

  const CalloutCard({
    required this.kind,
    required this.title,
    required this.body,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;

    final Color color =
        kind == CalloutKind.error ? colors.error : colors.warning;
    final IconData icon = kind == CalloutKind.error
        ? HIcons.error_outline_rounded
        : HIcons.warning_amber_rounded;

    return AccentCard(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(13, 10, 12, 11),
      accent: color,
      accentWidth: 3,
      background: color.withValues(alpha: 0.07),
      borderColor: color.withValues(alpha: 0.30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 7),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.textPrimary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
