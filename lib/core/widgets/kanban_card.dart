// Tarjeta de la piel nueva del Kanban: avatar de quien lleva la tarea,
// prioridad como glifo de texto, cronómetro en vivo si se está ejecutando y
// contador de hijos/enlaces. Solo dibuja; arrastrar, abrir y mover siguen en
// la pantalla.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/kanban.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'kanban_skin_style.dart';

class KanbanCard extends StatelessWidget {
  final KanbanTask task;

  /// Texto secundario del pie (estado, progreso o fecha relativa).
  final String trailing;

  /// Color del texto secundario del pie.
  final Color trailingColor;

  /// Hijos del tablero más el enlace al padre: lo que la tarjeta cuenta.
  final int linkCount;

  /// En modo selección, tocar marca la tarjeta y se dibuja su casilla.
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;

  /// Aspecto levantado de la tarjeta mientras se arrastra.
  final bool elevated;

  /// Reloj inyectable para el cronómetro (pruebas).
  final DateTime Function()? now;

  const KanbanCard({
    required this.task,
    required this.trailing,
    required this.trailingColor,
    required this.onTap,
    this.linkCount = 0,
    this.selectionMode = false,
    this.selected = false,
    this.elevated = false,
    this.now,
    super.key,
  });

  bool get _clockRuns =>
      task.status == 'running' &&
      task.startedAt != null &&
      task.completedAt == null;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final assignee = (task.assignee ?? '').trim();
    final glyph = kanbanPriorityGlyph(task.priority);
    final support = TextStyle(
      fontSize: HermesType.supportSize,
      color: colors.textSecondary,
    );
    return Material(
      color: elevated ? colors.surfaceVariant : colors.surface,
      elevation: elevated ? 8 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.row),
        side: selected
            ? BorderSide(color: colors.accent, width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('kanban-task-${task.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(HermesSpace.x3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KanbanAvatar(assignee: assignee),
              const SizedBox(width: HermesSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (glyph != null) ...[
                          Semantics(
                            label: kanbanPriorityName(s, task.priority),
                            excludeSemantics: true,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                top: HermesSpace.x1,
                                right: HermesSpace.x2,
                              ),
                              child: Text(
                                glyph,
                                key: ValueKey('kanban-priority-${task.id}'),
                                style: TextStyle(
                                  fontSize: HermesType.captionSize,
                                  color: kanbanPriorityColor(
                                    colors,
                                    task.priority,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                        Expanded(
                          child: Text(
                            task.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: HermesType.bodySize,
                              fontWeight: FontWeight.w500,
                              height: 1.35,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: HermesSpace.x1),
                    Text(
                      assignee.isEmpty ? s.kanbanUnassigned : '@$assignee',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: support,
                    ),
                    const SizedBox(height: HermesSpace.x1),
                    Wrap(
                      spacing: HermesSpace.x3,
                      runSpacing: HermesSpace.x1,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_clockRuns)
                          KanbanRunClock(
                            key: ValueKey('kanban-clock-${task.id}'),
                            startedAt: task.startedAt!,
                            now: now,
                            style: support.copyWith(color: colors.success),
                          ),
                        if (task.commentCount > 0)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.mode_comment_outlined,
                                size: HermesIcon.sm,
                                color: colors.textSecondary,
                              ),
                              const SizedBox(width: HermesSpace.x1),
                              Text('${task.commentCount}', style: support),
                            ],
                          ),
                        if (linkCount > 0)
                          Semantics(
                            label: s.kanbanSkinLinksCount(linkCount),
                            excludeSemantics: true,
                            child: Text(
                              '↳ $linkCount',
                              key: ValueKey('kanban-links-${task.id}'),
                              style: support,
                            ),
                          ),
                        Text(
                          trailing,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: support.copyWith(color: trailingColor),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (selectionMode) ...[
                const SizedBox(width: HermesSpace.x2),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  key: ValueKey('kanban-select-mark-${task.id}'),
                  size: HermesIcon.lg,
                  color: selected ? colors.accent : colors.textSecondary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Círculo con la inicial de quien lleva la tarea, de un tono estable por
/// nombre. Sin asignado, un círculo apagado.
class KanbanAvatar extends StatelessWidget {
  final String assignee;
  final double size;

  const KanbanAvatar({required this.assignee, this.size = 28, super.key});

  static const String _noInitial = '·';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final named = assignee.isNotEmpty;
    final tone = named
        ? kanbanAvatarTone(colors, assignee)
        : colors.textSecondary;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Text(
        named
            ? String.fromCharCode(assignee.runes.first).toUpperCase()
            : _noInitial,
        style: TextStyle(
          fontSize: HermesType.supportSize,
          fontWeight: FontWeight.w700,
          color: named ? tone : colors.textSecondary,
        ),
      ),
    );
  }
}

/// Cronómetro de una tarea en ejecución: transcurrido desde `started_at`,
/// con un tic por segundo mientras esté en pantalla.
class KanbanRunClock extends StatefulWidget {
  /// Inicio en segundos desde la época (el formato del servidor).
  final int startedAt;
  final DateTime Function()? now;
  final TextStyle? style;

  const KanbanRunClock({
    required this.startedAt,
    this.now,
    this.style,
    super.key,
  });

  @override
  State<KanbanRunClock> createState() => _KanbanRunClockState();
}

class _KanbanRunClockState extends State<KanbanRunClock> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = (widget.now ?? DateTime.now)();
    final elapsed = Duration(
      milliseconds: now.millisecondsSinceEpoch - widget.startedAt * 1000,
    );
    return Text(
      kanbanElapsedLabel(elapsed),
      style: widget.style?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
