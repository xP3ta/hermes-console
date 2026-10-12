import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/activity_snapshot.dart';
import '../models/agent_task_list.dart';
import '../models/tool_label.dart';
import '../theme/app_theme.dart';
import '../utils/plain_preview.dart';
import 'activity_pill.dart';
import 'reasoning_panel.dart';

String _lang(BuildContext context) =>
    Localizations.localeOf(context).languageCode;

/// Título de sección: compacto y calmado, no un `ListTile`.
class ActivitySectionHeader extends StatelessWidget {
  const ActivitySectionHeader({
    required this.title,
    this.trailing,
    this.keyName,
    super.key,
  });

  final String title;
  final Widget? trailing;
  final String? keyName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                key: keyName == null ? null : ValueKey<String>(keyName!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tareas
// ─────────────────────────────────────────────────────────────────────────────

class _TaskStatusIcon extends StatefulWidget {
  const _TaskStatusIcon({required this.status, required this.size});

  final AgentTaskStatus status;
  final double size;

  @override
  State<_TaskStatusIcon> createState() => _TaskStatusIconState();
}

class _TaskStatusIconState extends State<_TaskStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.4, end: 1.25), weight: 55),
    TweenSequenceItem(tween: Tween(begin: 1.25, end: 1.0), weight: 45),
  ]).animate(CurvedAnimation(parent: _pop, curve: Curves.easeOutCubic));

  @override
  void didUpdateWidget(_TaskStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (oldWidget.status != AgentTaskStatus.completed &&
        widget.status == AgentTaskStatus.completed &&
        !reduce) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final size = widget.size;
    return switch (widget.status) {
      AgentTaskStatus.completed => ScaleTransition(
        key: const ValueKey('activity-task-check-pop'),
        scale: _scale,
        child: Icon(
          Icons.check_circle_rounded,
          key: const ValueKey('activity-task-icon-completed'),
          size: size,
          color: colors.success,
        ),
      ),
      AgentTaskStatus.inProgress =>
        reduceMotion
            ? Icon(
                Icons.play_circle_outline_rounded,
                key: const ValueKey('activity-task-icon-in-progress'),
                size: size,
                color: colors.accent,
              )
            : SizedBox(
                key: const ValueKey('activity-task-icon-in-progress'),
                width: size - 3,
                height: size - 3,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              ),
      AgentTaskStatus.pending => Icon(
        Icons.radio_button_unchecked_rounded,
        key: const ValueKey('activity-task-icon-pending'),
        size: size,
        color: colors.textSecondary,
      ),
      AgentTaskStatus.cancelled => Icon(
        Icons.block_rounded,
        key: const ValueKey('activity-task-icon-cancelled'),
        size: size,
        color: colors.textSecondary,
      ),
    };
  }
}

String _taskStatusWord(Strings s, AgentTaskStatus status) => switch (status) {
  AgentTaskStatus.pending => s.agentTasksStatusPending,
  AgentTaskStatus.inProgress => s.agentTasksStatusInProgress,
  AgentTaskStatus.completed => s.agentTasksStatusCompleted,
  AgentTaskStatus.cancelled => s.agentTasksStatusCancelled,
};

class ActivityTaskRow extends StatelessWidget {
  const ActivityTaskRow({
    required this.item,
    required this.depth,
    this.dense = false,
    super.key,
  });

  final AgentTaskItem item;
  final int depth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final style = switch (item.status) {
      AgentTaskStatus.inProgress => TextStyle(
        fontWeight: FontWeight.w700,
        color: colors.textPrimary,
      ),
      AgentTaskStatus.pending => TextStyle(color: colors.textPrimary),
      AgentTaskStatus.completed => TextStyle(
        color: colors.textSecondary.withValues(alpha: 0.75),
        decoration: TextDecoration.lineThrough,
        decorationColor: colors.textSecondary,
      ),
      AgentTaskStatus.cancelled => TextStyle(
        color: colors.textSecondary,
        fontStyle: FontStyle.italic,
      ),
    };
    final iconSize = dense ? 15.0 : 18.0;
    final current = item.status == AgentTaskStatus.inProgress;
    final row = Padding(
      padding: EdgeInsets.only(
        left: (depth > 3 ? 3 : depth) * 14.0,
        top: dense ? 2 : 3.5,
        bottom: dense ? 2 : 3.5,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: iconSize + 2,
            height: 13 * 1.35 + 2,
            child: Center(
              child: _TaskStatusIcon(status: item.status, size: iconSize),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              plainPreview(item.content),
              style: style.copyWith(fontSize: dense ? 12.5 : 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      container: true,
      label: '${_taskStatusWord(s, item.status)}: ${item.content}',
      excludeSemantics: true,
      // fh1215: the task in progress is the one to find at a glance: a soft
      // accent band behind it (same insets, so nothing shifts).
      // The band is always there (transparent unless current) so a row
      // keeps its element, and its check pop, when its status changes.
      child: DecoratedBox(
        key: const ValueKey('activity-task-band'),
        decoration: BoxDecoration(
          color: current
              ? colors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: row,
      ),
    );
  }
}

/// fh1215: the folded completed tasks («✓ 5 completadas ›»), dimmed; a tap
/// shows them in place (and the row then offers to hide them again).
class _DoneFoldRow extends StatelessWidget {
  const _DoneFoldRow({
    required this.folded,
    required this.label,
    required this.dense,
    required this.onTap,
  });

  final bool folded;
  final String label;
  final bool dense;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final iconSize = dense ? 15.0 : 18.0;
    final muted = colors.textSecondary.withValues(alpha: 0.85);
    return Semantics(
      button: true,
      expanded: !folded,
      child: InkWell(
        key: const ValueKey('activity-tasks-done-toggle'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            children: [
              SizedBox(
                width: iconSize + 2,
                child: Icon(
                  Icons.check_circle_rounded,
                  size: iconSize,
                  color: colors.success.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: dense ? 12.5 : 13,
                    fontWeight: FontWeight.w600,
                    color: muted,
                  ),
                ),
              ),
              Icon(
                folded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                size: 18,
                color: muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «Tareas n/m»: barra fina + checklist. Muestra 6 filas y un expansor «+N más».
class ActivityTasksSection extends StatefulWidget {
  const ActivityTasksSection({
    required this.tasks,
    this.maxRows = 6,
    this.incomplete = false,
    this.dense = false,
    super.key,
  });

  final AgentTaskList tasks;
  final int maxRows;

  /// Turno terminado con elementos abiertos (historial).
  final bool incomplete;
  final bool dense;

  @override
  State<ActivityTasksSection> createState() => _ActivityTasksSectionState();
}

class _ActivityTasksSectionState extends State<ActivityTasksSection> {
  bool _expanded = false;
  bool _showDone = false;

  /// fh1215: more completed tasks than this fold into one «N completadas»
  /// row, so the open work stays on top of a long list.
  static const int foldDoneAbove = 3;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final tasks = widget.tasks;
    final allRows = tasks.rows;
    final doneRows = [
      for (final row in allRows)
        if (row.item.status == AgentTaskStatus.completed) row,
    ];
    final foldable = doneRows.length > foldDoneAbove;
    final folded = foldable && !_showDone;
    final rows = folded
        ? [
            for (final row in allRows)
              if (row.item.status != AgentTaskStatus.completed) row,
          ]
        : allRows;
    // Unfolding the completed tasks is an explicit ask to see the whole
    // list: no window then (the panel scrolls).
    final overflow = rows.length > widget.maxRows && !(foldable && _showDone);
    var visible = rows;
    var hidden = 0;
    if (overflow && !_expanded) {
      // La ventana sigue a la tarea en curso para que no quede fuera de vista.
      final current = rows.indexWhere(
        (row) => row.item.status == AgentTaskStatus.inProgress,
      );
      var start = current < 0 ? 0 : (current - 2).clamp(0, rows.length);
      if (start > rows.length - widget.maxRows) {
        start = rows.length - widget.maxRows;
      }
      visible = rows.sublist(start, start + widget.maxRows);
      hidden = rows.length - visible.length;
    }
    final cancelled = tasks.cancelledCount;
    final extras = [
      if (cancelled > 0) s.agentTasksCancelledCount(cancelled),
      if (widget.incomplete) s.agentTasksIncomplete,
    ];
    return Column(
      key: const ValueKey('activity-tasks-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ActivitySectionHeader(
          keyName: 'activity-tasks-title',
          title: [
            s.agentTasksPillTitle(tasks.done, tasks.total),
            ...extras,
          ].join(' · '),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            key: const ValueKey('activity-tasks-progress'),
            value: tasks.progress,
            minHeight: 3.5,
            backgroundColor: colors.divider,
            color: tasks.isFinished ? colors.success : colors.accent,
          ),
        ),
        const SizedBox(height: 6),
        if (foldable)
          _DoneFoldRow(
            folded: folded,
            label: folded
                ? s.fh1215TasksCompleted(doneRows.length)
                : s.fh1215TasksHideCompleted,
            dense: widget.dense,
            onTap: () => setState(() => _showDone = !_showDone),
          ),
        for (final row in visible)
          ActivityTaskRow(
            key: ValueKey('activity-task-row-${row.item.id}'),
            item: row.item,
            depth: row.depth,
            dense: widget.dense,
          ),
        if (overflow)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('activity-tasks-toggle'),
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 40),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                foregroundColor: colors.textSecondary,
                textStyle: const TextStyle(fontSize: 12.5),
              ),
              child: Text(
                _expanded ? s.liveShowLess : s.agentTasksMore(hidden),
              ),
            ),
          )
        else if (tasks.omitted > 0)
          Text(
            s.agentTasksMore(tasks.omitted),
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pasos: «Ahora» y «Hecho»
// ─────────────────────────────────────────────────────────────────────────────

/// Una fila de paso: `✓ terminal · date        0.7 s`.
class ActivityStepRow extends StatelessWidget {
  const ActivityStepRow({
    required this.step,
    required this.now,
    this.dense = false,
    this.muted = false,
    super.key,
  });

  final ActivityStep step;
  final DateTime now;
  final bool dense;

  /// Historial: la marca de «hecho» va en tono apagado, sin verde.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final lang = _lang(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Widget icon = switch (step.status) {
      ActivityStepStatus.done => Icon(
        Icons.check_rounded,
        size: 15,
        color: muted
            ? colors.textSecondary.withValues(alpha: 0.7)
            : colors.success.withValues(alpha: 0.9),
      ),
      ActivityStepStatus.failed => Icon(
        Icons.close_rounded,
        size: 15,
        color: colors.error,
      ),
      ActivityStepStatus.running =>
        reduceMotion
            ? Icon(Icons.more_horiz_rounded, size: 15, color: colors.accent)
            : SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: colors.accent,
                ),
              ),
    };
    final Duration? shown = step.isRunning
        ? (step.startedAt == null
              ? null
              : (now.difference(step.startedAt!).isNegative
                    ? Duration.zero
                    : now.difference(step.startedAt!)))
        : step.duration;
    final timeText = shown == null
        ? null
        : step.isRunning
        ? formatTurnElapsed(shown)
        : formatStepDuration(shown, languageCode: lang);
    final name = activityStepTitle(s, step);
    final status = switch (step.status) {
      ActivityStepStatus.done => s.liveStepDone,
      ActivityStepStatus.failed => s.liveStepFailed,
      ActivityStepStatus.running => s.liveStepRunning,
    };
    final running = step.isRunning;
    return Semantics(
      container: true,
      label: [name, ?step.detail, status, if (!running) ?timeText].join(', '),
      excludeSemantics: true,
      child: Padding(
        // tp1216: dense rows (history detail) sit tighter.
        padding: EdgeInsets.symmetric(vertical: dense ? 1.5 : 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(width: 20, child: Center(child: icon)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: name,
                          style: TextStyle(
                            fontWeight: running
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: step.status == ActivityStepStatus.failed
                                ? colors.error
                                : (running
                                      ? colors.textPrimary
                                      : colors.textSecondary),
                          ),
                        ),
                        if (step.detail != null)
                          TextSpan(
                            text: ' · ${step.detail}',
                            style: TextStyle(color: colors.textSecondary),
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, height: 1.3),
                  ),
                ),
                if (timeText != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    timeText,
                    key: running
                        ? const ValueKey('activity-now-elapsed')
                        : null,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
            if (step.text != null && step.kind != ActivityStepKind.reasoning)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: _FoldedText(text: step.text!),
              ),
          ],
        ),
      ),
    );
  }
}

/// Texto largo plegado a 3 líneas; un toque lo despliega entero.
class _FoldedText extends StatefulWidget {
  const _FoldedText({required this.text});

  final String text;

  @override
  State<_FoldedText> createState() => _FoldedTextState();
}

class _FoldedTextState extends State<_FoldedText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Text(
        widget.text,
        maxLines: _open ? null : 3,
        overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          height: 1.3,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

/// «Hecho»: pasos terminados, el más reciente primero. Con [maxRows] filas y un
/// «+N anteriores» para no crecer sin límite en turnos larguísimos.
class ActivityDoneSection extends StatelessWidget {
  const ActivityDoneSection({
    required this.steps,
    required this.now,
    this.maxRows = 30,
    this.dense = false,
    this.muted = false,
    this.showTitle = true,
    this.trailingFor,
    this.rowAttachments = const {},
    super.key,
  });

  final List<ActivityStep> steps;
  final DateTime now;
  final int maxRows;
  final bool dense;
  final bool muted;
  final bool showTitle;
  final Map<String, Widget> rowAttachments;

  /// Optional card under a step's row (a file diff, terminal output). Only
  /// called while this section is built, i.e. while the trace is unfolded.
  final Widget? Function(ActivityStep step)? trailingFor;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final shown = steps.take(maxRows).toList(growable: false);
    final hidden = steps.length - shown.length;
    return Column(
      key: const ValueKey('activity-done-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle)
          ActivitySectionHeader(
            title: s.liveSectionDone,
            keyName: 'activity-done-title',
          ),
        for (final step in shown) ...[
          // rt1215: finished reasoning is a «Pensamiento · 12 s» block, never
          // text inside a step row.
          if (step.kind == ActivityStepKind.reasoning && step.text != null)
            Padding(
              key: ValueKey('activity-done-${step.id}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ReasoningPanel(
                text: step.text!,
                meta: step.duration == null
                    ? null
                    : formatStepDuration(
                        step.duration!,
                        languageCode: _lang(context),
                      ),
              ),
            )
          else
            ActivityStepRow(
              key: ValueKey('activity-done-${step.id}'),
              step: step,
              now: now,
              dense: dense,
              muted: muted,
            ),
          ?trailingFor?.call(step),
          if (rowAttachments.containsKey(step.id))
            KeyedSubtree(
              key: ValueKey('activity-step-attachment-${step.id}'),
              child: rowAttachments[step.id]!,
            ),
        ],
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              s.liveOlderSteps(hidden),
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}
