// Estados vacíos de la piel nueva del Kanban. Cada uno ofrece una salida:
// sin coincidencias, limpiar los filtros; una columna vacía dice qué es y
// sigue siendo un destino válido al arrastrar.
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';

/// Pantalla completa sin resultados, con su botón de salida.
class KanbanEmptyState extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const KanbanEmptyState({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HermesSpace.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: HermesType.textSize,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: HermesSpace.x3),
            OutlinedButton(
              key: const ValueKey('kanban-empty-action'),
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hueco de una columna sin tarjetas.
class KanbanColumnEmpty extends StatelessWidget {
  final String message;

  const KanbanColumnEmpty({required this.message, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      padding: const EdgeInsets.all(HermesSpace.x4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HermesRadius.row),
        border: Border.all(color: colors.divider),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: HermesType.supportSize,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}
