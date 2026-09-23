import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/activity_snapshot.dart';
import '../models/agent_task_list.dart';
import '../models/session_activity.dart';
import '../models/subagent_activity.dart';
import '../theme/app_theme.dart';
import 'activity_pill.dart';

/// Acciones por elemento del panel. Son los mismos controladores que tenían las
/// hojas anteriores de segundo plano / subagentes; el panel no pierde ninguna.
enum ActivityScheduleAction { pause, resume, stop }

class ActivityPanelActions {
  const ActivityPanelActions({
    this.canStopProcesses = false,
    this.stopProcess,
    this.canControlSchedules = false,
    this.scheduleAction,
    this.canControlGoal = false,
    this.goalAction,
    this.goalDetails,
    this.openSubagent,
    this.dismissSubagents,
  });

  static const ActivityPanelActions none = ActivityPanelActions();

  final bool canStopProcesses;
  final Future<void> Function(String processId)? stopProcess;
  final bool canControlSchedules;
  final Future<void> Function(
    SessionActivitySchedule schedule,
    ActivityScheduleAction action,
  )?
  scheduleAction;
  final bool canControlGoal;

  /// `goal.pause`, `goal.resume`, `goal.unwait` o `goal.clear`.
  final Future<void> Function(String action)? goalAction;
  final VoidCallback? goalDetails;

  /// Abre el detalle/control (seguir, dirigir, detener, abrir conversación) del
  /// subagente; `null` = el primero.
  final void Function(SubagentActivity? activity)? openSubagent;
  final VoidCallback? dismissSubagents;
}

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
    return Semantics(
      container: true,
      label: '${_taskStatusWord(s, item.status)}: ${item.content}',
      excludeSemantics: true,
      child: Padding(
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
                item.content,
                style: style.copyWith(
                  fontSize: dense ? 12.5 : 13,
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

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final tasks = widget.tasks;
    final rows = tasks.rows;
    final overflow = rows.length > widget.maxRows;
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
    final name = step.kind == ActivityStepKind.reasoning
        ? s.chatActivityReasoning
        : step.label;
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
        padding: EdgeInsets.symmetric(vertical: dense ? 2.5 : 4),
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
            if (step.text != null)
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
        style: TextStyle(fontSize: 12, height: 1.3, color: colors.textDisabled),
      ),
    );
  }
}

/// «Ahora»: el paso vivo (o el titular del pipeline) con su cronómetro.
class ActivityNowSection extends StatelessWidget {
  const ActivityNowSection({
    required this.snapshot,
    required this.now,
    this.sectionKey,
    super.key,
  });

  final ActivitySnapshot snapshot;
  final DateTime now;
  final Key? sectionKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final current = snapshot.current;
    final Widget row;
    if (snapshot.noActivityHint) {
      row = _NowLine(
        text: s.chaTurnStillWorking,
        since: snapshot.turnStartedAt,
        now: now,
      );
    } else if (snapshot.waitingForUser) {
      row = _NowLine(
        text: s.liveWaitingForUser,
        since: snapshot.turnStartedAt,
        now: now,
      );
    } else if (current != null) {
      row = current.kind == ActivityStepKind.reasoning
          ? _NowLine(
              text: s.chatActivityThinking,
              since: current.startedAt ?? snapshot.turnStartedAt,
              now: now,
            )
          : ActivityStepRow(step: current, now: now);
    } else {
      row = _NowLine(
        text: snapshot.headline ?? s.chaPipelineThinking,
        since: snapshot.turnStartedAt,
        now: now,
      );
    }
    return Column(
      key: sectionKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ActivitySectionHeader(
          title: s.liveSectionNow,
          keyName: 'activity-now-title',
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: row,
          ),
        ),
      ],
    );
  }
}

class _NowLine extends StatelessWidget {
  const _NowLine({required this.text, required this.since, required this.now});

  final String text;
  final DateTime? since;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final start = since;
    final elapsed = start == null
        ? null
        : (now.difference(start).isNegative
              ? Duration.zero
              : now.difference(start));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Center(
              child: reduceMotion
                  ? Icon(
                      Icons.more_horiz_rounded,
                      size: 15,
                      color: colors.accent,
                    )
                  : SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: colors.accent,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (elapsed != null) ...[
            const SizedBox(width: 8),
            Text(
              formatTurnElapsed(elapsed),
              key: const ValueKey('activity-now-elapsed'),
              style: TextStyle(
                fontSize: 11.5,
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
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
    super.key,
  });

  final List<ActivityStep> steps;
  final DateTime now;
  final int maxRows;
  final bool dense;
  final bool muted;
  final bool showTitle;

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
        for (final step in shown)
          ActivityStepRow(
            key: ValueKey('activity-done-${step.id}'),
            step: step,
            now: now,
            dense: dense,
            muted: muted,
          ),
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

// ─────────────────────────────────────────────────────────────────────────────
// Segundo plano, bucles, objetivo, subagentes
// ─────────────────────────────────────────────────────────────────────────────

/// Botón de texto compacto que se desactiva mientras su acción está en vuelo.
class ActivityActionButton extends StatefulWidget {
  const ActivityActionButton({
    required this.label,
    required this.onPressed,
    this.destructive = false,
    super.key,
  });

  final String label;
  final Future<void> Function()? onPressed;
  final bool destructive;

  @override
  State<ActivityActionButton> createState() => _ActivityActionButtonState();
}

class _ActivityActionButtonState extends State<ActivityActionButton> {
  bool _busy = false;

  Future<void> _run() async {
    final action = widget.onPressed;
    if (action == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return TextButton(
      onPressed: widget.onPressed == null || _busy ? null : _run,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: widget.destructive ? colors.error : colors.accentText,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(widget.label),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.child, this.keyName});

  final Widget child;
  final String? keyName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      key: keyName == null ? null : ValueKey<String>(keyName!),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider, width: 0.8),
      ),
      child: child,
    );
  }
}

String _statusLabel(Strings s, String value) => switch (value) {
  'active' => s.chaBackgroundStatusActive,
  'paused' => s.chaBackgroundStatusPaused,
  'waiting' => s.chaBackgroundStatusWaiting,
  'done' => s.chaBackgroundStatusDone,
  _ => value,
};

String _durationLabel(Duration value) {
  if (value.inHours > 0 && value.inMinutes % 60 == 0) {
    return '${value.inHours} h';
  }
  if (value.inMinutes > 0) return '${value.inMinutes} min';
  return '${value.inSeconds} s';
}

class ActivityBackgroundSection extends StatelessWidget {
  const ActivityBackgroundSection({
    required this.snapshot,
    required this.actions,
    required this.now,
    super.key,
  });

  final ActivitySnapshot snapshot;
  final ActivityPanelActions actions;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final started = snapshot.backgroundStartedAt;
    return Column(
      key: const ValueKey('activity-background-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ActivitySectionHeader(
          title: s.liveSectionBackground,
          keyName: 'activity-background-title',
        ),
        if (snapshot.processesStale)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              s.chaBackgroundActivityStale,
              style: TextStyle(fontSize: 12, color: colors.warning),
            ),
          ),
        for (final process in snapshot.processes)
          _ItemCard(
            keyName: 'activity-process-${process.id}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.terminal_rounded,
                      size: 15,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        process.command.isEmpty
                            ? s.chaBackgroundProcessRunning
                            : process.command,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    if (process.startedAt != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        formatTurnElapsed(
                          now
                                  .toUtc()
                                  .difference(process.startedAt!.toUtc())
                                  .isNegative
                              ? Duration.zero
                              : now.toUtc().difference(
                                  process.startedAt!.toUtc(),
                                ),
                        ),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
                if (process.watchPatterns.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    s.chaBackgroundWatchPatterns,
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  for (final pattern in process.watchPatterns)
                    Text(
                      pattern,
                      key: ValueKey('process-watch-$pattern'),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                ],
                if (process.watchHit)
                  Text(
                    s.chaBackgroundWatchHit,
                    style: TextStyle(fontSize: 12, color: colors.success),
                  ),
                if (process.notifyOnComplete)
                  Text(
                    s.chaBackgroundProcessWillNotify,
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                if (actions.canStopProcesses && actions.stopProcess != null)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: ActivityActionButton(
                      key: ValueKey('background-process-stop-${process.id}'),
                      label: s.chaBackgroundActionStop,
                      destructive: true,
                      onPressed: () => actions.stopProcess!(process.id),
                    ),
                  ),
              ],
            ),
          ),
        if (started == null && snapshot.processes.isEmpty)
          const SizedBox.shrink(),
      ],
    );
  }
}

class ActivityLoopsSection extends StatelessWidget {
  const ActivityLoopsSection({
    required this.snapshot,
    required this.actions,
    super.key,
  });

  final ActivitySnapshot snapshot;
  final ActivityPanelActions actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final loc = MaterialLocalizations.of(context);
    String time(DateTime v) =>
        loc.formatTimeOfDay(TimeOfDay.fromDateTime(v.toLocal()));
    return Column(
      key: const ValueKey('activity-loops-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ActivitySectionHeader(
          title: s.liveSectionLoops,
          keyName: 'activity-loops-title',
        ),
        for (final schedule in snapshot.schedules)
          _scheduleCard(context, colors, s, schedule, time),
      ],
    );
  }

  Widget _scheduleCard(
    BuildContext context,
    HermesThemeColors colors,
    Strings s,
    SessionActivitySchedule schedule,
    String Function(DateTime) time,
  ) {
    final isLoop = schedule.kind == SessionActivityScheduleKind.loop;
    final id = isLoop ? 'loop' : 'heartbeat';
    final facts = <String>[
      s.chaBackgroundStatus(_statusLabel(s, schedule.status)),
      s.chaBackgroundInterval(_durationLabel(schedule.interval)),
      if (schedule.nextDueAt case final next?)
        s.chaBackgroundNextDue(time(next)),
      if (schedule.lastRunAt case final last?)
        s.chaBackgroundLastRun(time(last)),
      s.chaBackgroundRunCount(schedule.runCount),
      if (schedule.awaitingResponse) s.chaBackgroundAwaitingResponse,
      if (schedule.deferredByGoal) s.chaBackgroundDeferredByGoal,
    ];
    final can = actions.canControlSchedules && actions.scheduleAction != null;
    return _ItemCard(
      keyName: 'activity-$id',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isLoop ? s.chaBackgroundLoop : s.chaBackgroundHeartbeat,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          for (final fact in facts)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                fact,
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ),
          if (can)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 2,
                children: [
                  if (schedule.status == 'paused')
                    ActivityActionButton(
                      key: ValueKey('background-$id-resume'),
                      label: s.chaBackgroundActionResume,
                      onPressed: () => actions.scheduleAction!(
                        schedule,
                        ActivityScheduleAction.resume,
                      ),
                    )
                  else if (schedule.status == 'active')
                    ActivityActionButton(
                      key: ValueKey('background-$id-pause'),
                      label: s.chaBackgroundActionPause,
                      onPressed: () => actions.scheduleAction!(
                        schedule,
                        ActivityScheduleAction.pause,
                      ),
                    ),
                  ActivityActionButton(
                    key: ValueKey(
                      isLoop
                          ? 'background-loop-stop'
                          : 'background-heartbeat-clear',
                    ),
                    label: isLoop
                        ? s.chaBackgroundActionStop
                        : s.chaBackgroundActionClear,
                    destructive: true,
                    onPressed: () => actions.scheduleAction!(
                      schedule,
                      ActivityScheduleAction.stop,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class ActivityGoalSection extends StatelessWidget {
  const ActivityGoalSection({
    required this.goal,
    required this.actions,
    super.key,
  });

  final SessionActivityGoal goal;
  final ActivityPanelActions actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final can = actions.canControlGoal && actions.goalAction != null;
    return Column(
      key: const ValueKey('activity-goal-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ActivitySectionHeader(
          title: s.liveSectionGoal,
          keyName: 'activity-goal-title',
        ),
        _ItemCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                goal.title.isEmpty ? s.chaGoalSheetTitle : goal.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  s.chaBackgroundStatus(_statusLabel(s, goal.status)),
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  spacing: 2,
                  children: [
                    if (actions.goalDetails != null)
                      TextButton(
                        key: const ValueKey('background-goal-details'),
                        onPressed: actions.goalDetails,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 44),
                          foregroundColor: colors.accentText,
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: Text(s.chaBackgroundGoalDetails),
                      ),
                    if (can && goal.status == 'active')
                      ActivityActionButton(
                        key: const ValueKey('background-goal-pause'),
                        label: s.chaGoalActionPause,
                        onPressed: () => actions.goalAction!('goal.pause'),
                      ),
                    if (can && goal.status == 'paused')
                      ActivityActionButton(
                        key: const ValueKey('background-goal-resume'),
                        label: s.chaGoalActionResume,
                        onPressed: () => actions.goalAction!('goal.resume'),
                      ),
                    if (can && goal.status == 'waiting')
                      ActivityActionButton(
                        key: const ValueKey('background-goal-resume-now'),
                        label: s.chaGoalActionResumeNow,
                        onPressed: () => actions.goalAction!('goal.unwait'),
                      ),
                    if (can)
                      ActivityActionButton(
                        key: const ValueKey('background-goal-clear'),
                        label: s.chaGoalActionClear,
                        destructive: true,
                        onPressed: () => actions.goalAction!('goal.clear'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _phaseWord(Strings s, SubagentActivityPhase phase) => switch (phase) {
  SubagentActivityPhase.requested => s.subagentActivityRequested,
  SubagentActivityPhase.running => s.subagentActivityRunning,
  SubagentActivityPhase.thinking => s.subagentActivityThinking,
  SubagentActivityPhase.tool => s.subagentActivityTool,
  SubagentActivityPhase.completed => s.subagentActivityCompleted,
  SubagentActivityPhase.failed => s.subagentActivityFailed,
  SubagentActivityPhase.cancelled => s.subagentActivityCancelled,
  SubagentActivityPhase.unknown => s.subagentActivityUnknown,
};

class ActivitySubagentsSection extends StatelessWidget {
  const ActivitySubagentsSection({
    required this.snapshot,
    required this.actions,
    required this.now,
    super.key,
  });

  final ActivitySnapshot snapshot;
  final ActivityPanelActions actions;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final activities = snapshot.subagents;
    final allEnded = activities.isNotEmpty && snapshot.subagentLive == 0;
    return Column(
      key: const ValueKey('activity-subagents-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ActivitySectionHeader(
          title: s.liveSectionSubagents,
          keyName: 'activity-subagents-title',
          trailing: allEnded && actions.dismissSubagents != null
              ? TextButton(
                  key: const ValueKey('activity-subagents-dismiss'),
                  onPressed: actions.dismissSubagents,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: colors.textSecondary,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: Text(s.inAppDismiss),
                )
              : null,
        ),
        if (activities.isEmpty)
          _ItemCard(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6, top: 2),
              child: Text(
                snapshot.subagentCount == 0
                    ? s.chaBackgroundWorkTitle
                    : s.liveSubagentsWorking(snapshot.subagentCount),
                style: TextStyle(fontSize: 13, color: colors.textPrimary),
              ),
            ),
          ),
        for (var i = 0; i < activities.length; i++)
          _subagentRow(context, colors, s, activities[i], i + 1),
      ],
    );
  }

  Widget _subagentRow(
    BuildContext context,
    HermesThemeColors colors,
    Strings s,
    SubagentActivity activity,
    int index,
  ) {
    final terminal = activity.isTerminal;
    final failed = activity.phase == SubagentActivityPhase.failed;
    final elapsed =
        activity.details.durationSeconds ??
        (activity.details.startedAt == null
            ? null
            : (activity.details.completedAt ?? now.toUtc())
                  .difference(activity.details.startedAt!)
                  .inSeconds
                  .toDouble());
    final facts = <String>[
      _phaseWord(s, activity.phase),
      if (elapsed != null && elapsed >= 0)
        formatTurnElapsed(Duration(seconds: elapsed.round())),
      if (activity.progress case final progress?)
        s.subagentActivityProgress(
          progress.displayTaskIndex,
          progress.taskCount,
        ),
    ];
    final open = actions.openSubagent;
    return Semantics(
      container: true,
      button: open != null,
      label: '${s.subagentActivityItem(index)}, ${facts.join(', ')}',
      hint: open == null ? null : s.liveSubagentControl,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: colors.surfaceVariant.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: colors.divider, width: 0.8),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('activity-subagent-${activity.key.stableId}'),
            onTap: open == null ? null : () => open(activity),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  children: [
                    Icon(
                      failed
                          ? Icons.error_outline
                          : terminal
                          ? Icons.check_circle_outline_rounded
                          : Icons.account_tree_outlined,
                      size: 16,
                      color: failed
                          ? colors.error
                          : terminal
                          ? colors.success
                          : colors.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.subagentActivityItem(index),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: colors.textPrimary,
                            ),
                          ),
                          Text(
                            facts.join(' · '),
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (open != null)
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
