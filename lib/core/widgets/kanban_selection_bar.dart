// Barra flotante de acciones masivas de la piel nueva del Kanban. Aparece
// con la selección múltiple; no sabe nada de red: cada botón llama a lo que
// la pantalla le da.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';

class KanbanSelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onMove;
  final VoidCallback onAssign;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const KanbanSelectionBar({
    required this.count,
    required this.onMove,
    required this.onAssign,
    required this.onArchive,
    required this.onDelete,
    required this.onClose,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final enabled = count > 0;
    Widget action(String key, String label, VoidCallback onTap, {Color? ink}) =>
        TextButton(
          key: ValueKey(key),
          onPressed: enabled ? onTap : null,
          style: TextButton.styleFrom(
            foregroundColor: ink ?? colors.textPrimary,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x2),
          ),
          child: Text(label),
        );
    return Material(
      key: const ValueKey('kanban-selection-bar'),
      color: colors.surfaceVariant,
      elevation: 6,
      borderRadius: BorderRadius.circular(HermesRadius.floating),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpace.x3,
          vertical: HermesSpace.x1,
        ),
        child: Row(
          children: [
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: HermesSpace.x2),
                    child: Text(
                      s.kanbanSkinSelected(count),
                      style: TextStyle(
                        fontSize: HermesType.supportSize,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  action('kanban-bulk-move', s.kanbanMove, onMove),
                  action(
                    'kanban-bulk-assign',
                    s.kanbanSkinBulkAssign,
                    onAssign,
                  ),
                  action('kanban-bulk-archive', s.kanbanArchive, onArchive),
                  action(
                    'kanban-bulk-delete',
                    s.kanbanSkinBulkDelete,
                    onDelete,
                    ink: colors.error,
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('kanban-bulk-close'),
              tooltip: s.kanbanSkinSelectExit,
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
