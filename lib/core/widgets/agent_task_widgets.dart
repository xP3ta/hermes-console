import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/agent_task_list.dart';
import '../services/session_reconciler.dart';
import '../theme/app_theme.dart';

/// Etiquetas con las que el gateway nombra la herramienta de lista de tareas
/// (`todo_list`; `todo` en transcripts anteriores al renombrado).
bool isAgentTaskToolLabel(String label) {
  final normalized = label.trim().toLowerCase();
  return normalized == 'todo_list' || normalized == 'todo';
}

/// Id del paso `todo_list` más reciente del transcript, o `null`.
///
/// La lista de tareas de la sesión es UNA (la última que escribió el agente);
/// se cuelga del bloque de actividad del turno que la escribió. Los mensajes
/// llegan más nuevo primero (`ActiveChat.messages`).
String? latestAgentTaskStepId(List<Map<String, dynamic>> messagesNewestFirst) {
  for (final message in messagesNewestFirst) {
    if (message['role'] != 'assistant') continue;
    final trace = message[assistantActivityTraceKey];
    if (trace is! List) continue;
    for (var i = trace.length - 1; i >= 0; i--) {
      final step = trace[i];
      if (step is! Map || step['kind'] != 'tool') continue;
      if (!isAgentTaskToolLabel('${step['label'] ?? ''}')) continue;
      final id = step['id']?.toString().trim();
      return id == null || id.isEmpty ? null : id;
    }
  }
  return null;
}

/// Entrega la lista de tareas de la sesión y el paso que la posee a los
/// bloques de actividad del transcript, sin añadir parámetros a los tres
/// envoltorios de mensaje del chat.
class AgentTaskScope extends InheritedWidget {
  const AgentTaskScope({
    required this.tasks,
    required this.ownerStepId,
    required super.child,
    super.key,
  });

  final AgentTaskList? tasks;
  final String? ownerStepId;

  static AgentTaskScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentTaskScope>();

  /// La lista, únicamente si [eventIds] contiene el paso `todo_list` que la
  /// posee. Así solo UN bloque de actividad la muestra.
  static AgentTaskList? ownedBy(
    BuildContext context,
    Iterable<({String id, String label})> steps,
  ) {
    final scope = maybeOf(context);
    final tasks = scope?.tasks;
    final owner = scope?.ownerStepId;
    if (tasks == null || tasks.isEmpty || owner == null) return null;
    for (final step in steps) {
      if (step.id == owner && isAgentTaskToolLabel(step.label)) return tasks;
    }
    return null;
  }

  @override
  bool updateShouldNotify(AgentTaskScope oldWidget) =>
      oldWidget.ownerStepId != ownerStepId ||
      !identical(oldWidget.tasks, tasks);
}

String _statusWord(Strings s, AgentTaskStatus status) => switch (status) {
  AgentTaskStatus.pending => s.agentTasksStatusPending,
  AgentTaskStatus.inProgress => s.agentTasksStatusInProgress,
  AgentTaskStatus.completed => s.agentTasksStatusCompleted,
  AgentTaskStatus.cancelled => s.agentTasksStatusCancelled,
};

// ─────────────────────────────────────────────────────────────────────────────
// Lista + tarjeta
// ─────────────────────────────────────────────────────────────────────────────

/// Cabecera «Tareas 3/7 · 1 cancelada» con barra de progreso fina.
class AgentTaskHeader extends StatelessWidget {
  const AgentTaskHeader({
    required this.tasks,
    this.incomplete = false,
    this.dense = false,
    super.key,
  });

  final AgentTaskList tasks;

  /// Turno terminado con elementos abiertos: se anota «incompleta» (igual que
  /// el archivo de la TUI).
  final bool incomplete;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final cancelled = tasks.cancelledCount;
    final extras = [
      if (cancelled > 0) s.agentTasksCancelledCount(cancelled),
      if (incomplete) s.agentTasksIncomplete,
    ];
    return Semantics(
      container: true,
      header: true,
      label: [
        s.agentTasksSummary(tasks.done, tasks.total),
        ...extras,
      ].join(', '),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            key: const ValueKey('agent-task-header'),
            TextSpan(
              children: [
                TextSpan(
                  text: s.agentTasksPillTitle(tasks.done, tasks.total),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                if (extras.isNotEmpty)
                  TextSpan(
                    text: ' · ${extras.join(' · ')}',
                    style: TextStyle(color: colors.textSecondary),
                  ),
              ],
            ),
            style: TextStyle(fontSize: dense ? 12 : 14),
          ),
          SizedBox(height: dense ? 4 : 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              key: const ValueKey('agent-task-progress'),
              value: tasks.progress,
              minHeight: 4,
              backgroundColor: colors.divider,
              color: tasks.isFinished ? colors.success : colors.accent,
            ),
          ),
        ],
      ),
    );
  }
}

/// Filas de la lista en orden de árbol. Sin scroll propio: el contenedor
/// (tarjeta flotante o bloque de actividad) decide el alto.
class AgentTaskChecklist extends StatelessWidget {
  const AgentTaskChecklist({
    required this.tasks,
    this.dense = false,
    super.key,
  });

  final AgentTaskList tasks;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Column(
      key: const ValueKey('agent-task-checklist'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in tasks.rows)
          _TaskRow(
            key: ValueKey('agent-task-row-${row.item.id}'),
            item: row.item,
            depth: row.depth,
            dense: dense,
          ),
        if (tasks.omitted > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              s.agentTasksMore(tasks.omitted),
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.item,
    required this.depth,
    required this.dense,
    super.key,
  });

  final AgentTaskItem item;
  final int depth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final iconSize = dense ? 14.0 : 18.0;
    final Widget icon = switch (item.status) {
      AgentTaskStatus.completed => Icon(
        Icons.check_circle_rounded,
        key: const ValueKey('agent-task-icon-completed'),
        size: iconSize,
        color: colors.success,
      ),
      AgentTaskStatus.inProgress =>
        reduceMotion
            // Movimiento reducido: marca estática, sin spinner animado.
            ? Icon(
                Icons.play_circle_outline_rounded,
                key: const ValueKey('agent-task-icon-in-progress'),
                size: iconSize,
                color: colors.accent,
              )
            : SizedBox(
                key: const ValueKey('agent-task-icon-in-progress'),
                width: iconSize - 2,
                height: iconSize - 2,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              ),
      AgentTaskStatus.pending => Icon(
        Icons.radio_button_unchecked_rounded,
        key: const ValueKey('agent-task-icon-pending'),
        size: iconSize,
        color: colors.textSecondary,
      ),
      AgentTaskStatus.cancelled => Icon(
        Icons.block_rounded,
        key: const ValueKey('agent-task-icon-cancelled'),
        size: iconSize,
        color: colors.textSecondary,
      ),
    };
    final textStyle = switch (item.status) {
      AgentTaskStatus.inProgress => TextStyle(
        fontWeight: FontWeight.w600,
        color: colors.textPrimary,
      ),
      AgentTaskStatus.pending => TextStyle(color: colors.textPrimary),
      AgentTaskStatus.completed => TextStyle(
        color: colors.textSecondary,
        decoration: TextDecoration.lineThrough,
        decorationColor: colors.textSecondary,
      ),
      AgentTaskStatus.cancelled => TextStyle(
        color: colors.textSecondary,
        fontStyle: FontStyle.italic,
      ),
    };
    final indent = (depth > 3 ? 3 : depth) * (dense ? 12.0 : 16.0);
    return Semantics(
      container: true,
      label: '${_statusWord(s, item.status)}: ${item.content}',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.only(
          left: indent,
          top: dense ? 2 : 4,
          bottom: dense ? 2 : 4,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: iconSize + 2,
              height: (dense ? 12.0 : 14.0) * 1.35 + 2,
              child: Center(child: icon),
            ),
            SizedBox(width: dense ? 6 : 8),
            Expanded(
              child: Text(
                item.content,
                style: textStyle.copyWith(
                  fontSize: dense ? 12 : 14,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Contenido de la tarjeta flotante: cabecera + lista, con scroll propio.
class AgentTaskCardBody extends StatelessWidget {
  const AgentTaskCardBody({required this.tasks, super.key});

  final AgentTaskList tasks;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      children: [
        if (tasks.isEmpty)
          Text(
            s.agentTasksEmpty,
            style: TextStyle(fontSize: 14, color: colors.textSecondary),
          )
        else ...[
          AgentTaskHeader(tasks: tasks),
          const SizedBox(height: 12),
          AgentTaskChecklist(tasks: tasks),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dentro del bloque de actividad del turno
// ─────────────────────────────────────────────────────────────────────────────

/// Chip «3/7» que acompaña al chevron del bloque de actividad plegado.
class AgentTaskChip extends StatelessWidget {
  const AgentTaskChip({required this.tasks, super.key});

  final AgentTaskList tasks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final finished = tasks.isFinished;
    final color = finished ? colors.success : colors.textSecondary;
    return Container(
      key: const ValueKey('agent-task-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            finished ? Icons.check_rounded : Icons.checklist_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            '${tasks.done}/${tasks.total}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
