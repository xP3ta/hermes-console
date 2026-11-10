// Cabecera de columna de la piel nueva del Kanban: marca con el tono del
// estado, nombre, contador y, debajo, el texto de ayuda de la columna.
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';

class KanbanColumnHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color tone;

  /// Qué significa la columna; null en una columna desconocida.
  final String? help;

  /// Acción propia de la columna (p. ej. limpiar las hechas).
  final Widget? trailing;

  const KanbanColumnHeader({
    required this.title,
    required this.count,
    required this.tone,
    this.help,
    this.trailing,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
                child: const SizedBox.square(dimension: HermesSpace.x2),
              ),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: HermesType.textSize,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: HermesSpace.x2),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: HermesType.supportSize,
                  fontWeight: FontWeight.w600,
                  color: tone,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: HermesSpace.x1),
                trailing!,
              ],
            ],
          ),
          if (help != null) ...[
            const SizedBox(height: HermesSpace.x1),
            Text(
              help!,
              style: TextStyle(
                fontSize: HermesType.captionSize,
                height: 1.3,
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
