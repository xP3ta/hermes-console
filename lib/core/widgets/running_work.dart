import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/list.dart' show HermesSectionHeader;
import '../design/tokens.dart';
import '../models/activity_snapshot.dart';
import '../models/session_activity.dart';
import '../models/subagent_activity.dart';
import '../screens/subagent_detail_screen.dart'
    show subagentElapsed, subagentHumanStatus, subagentTitle;
import '../theme/app_theme.dart';
import 'activity_pill.dart' show ActivityTicker, formatTurnElapsed;
import 'chat/chat_markdown_body.dart' show chatCodeTextStyle;

// ─────────────────────────────────────────────────────────────────────────────
// «En marcha» · what a conversation still has alive outside its turn
//
// Subagents, background processes, loops and the goal. One widget, with its
// rows, their actions and its own clock; it knows nothing of where it is
// shown and draws nothing while nothing is alive. What the TURN does is told
// in the transcript, never here.
// ─────────────────────────────────────────────────────────────────────────────

/// What can be done from a row of [RunningWork]. A null action is not
/// offered. Steering a turn is typing in the composer while it runs.
class RunningWorkActions {
  const RunningWorkActions({
    this.goalDetails,
    this.pauseGoal,
    this.resumeGoal,
    this.openSubagent,
    this.dismissSubagents,
    this.stopProcess,
  });

  static const RunningWorkActions none = RunningWorkActions();

  /// Opens the goal: what it is, and where it is cleared.
  final VoidCallback? goalDetails;
  final VoidCallback? pauseGoal;
  final VoidCallback? resumeGoal;

  /// Opens the subagent's detail page; `null` = the first one.
  final void Function(SubagentActivity? activity)? openSubagent;

  /// Clears the subagents that ended.
  final VoidCallback? dismissSubagents;

  /// Stops one background process.
  final void Function(SessionActivityProcess process)? stopProcess;
}

/// Type and room of a row: read at the size of a reply, never a footnote.
abstract final class _Run {
  static const double title = 15;
  static const double mono = 13.5;
  static const double meta = 13.5;
  static const double icon = 20;
  static const double iconBox = 36;
  static const double minHeight = 66;
}

/// «En marcha»: the background processes, subagents, loops and goal of a
/// conversation, one roomy row each: an icon anyone recognises, what it is
/// in full, its kind in words with how it is going, and the one thing that
/// can be done to it ([actions]). What is running comes first.
///
/// It follows [snapshot] on its own and ticks its own timers, so its host
/// only places it. While nothing is alive it is an empty box.
class RunningWork extends StatelessWidget {
  const RunningWork({
    required this.snapshot,
    this.actions = RunningWorkActions.none,
    this.clock,
    this.padding = EdgeInsets.zero,
    this.title = true,
    super.key,
  });

  final ValueListenable<ActivitySnapshot> snapshot;
  final RunningWorkActions actions;

  /// The clock the conversation measures its work with.
  final DateTime Function()? clock;

  /// Around the section; not applied while it is empty.
  final EdgeInsetsGeometry padding;

  /// Whether it says «En marcha» above its rows (a host that already says
  /// it leaves it out).
  final bool title;

  /// Whether [snapshot] has anything this section shows.
  static bool hasContent(ActivitySnapshot snapshot) =>
      snapshot.hasNonTurnActivity;

  /// How many things are alive: processes, subagents still working, loops
  /// and the goal. Subagents that ended wait to be cleared and are content,
  /// but none of them is running.
  static int aliveCount(ActivitySnapshot snapshot) {
    final subagents = snapshot.subagents.isEmpty
        ? (snapshot.subagentCount > 0
              ? snapshot.subagentCount
              : (snapshot.passiveRemote ? 1 : 0))
        : snapshot.subagentLive;
    return snapshot.processes.length +
        subagents +
        snapshot.schedules.length +
        (snapshot.goal == null ? 0 : 1);
  }

  /// How many subagents ended and wait to be cleared: still to be seen
  /// when nothing is alive any more.
  static int endedCount(ActivitySnapshot snapshot) => snapshot.subagentEnded;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ActivitySnapshot>(
        valueListenable: snapshot,
        builder: (context, value, _) {
          if (!hasContent(value)) {
            return const SizedBox.shrink(key: ValueKey('running-work-empty'));
          }
          return Semantics(
            container: true,
            explicitChildNodes: true,
            child: Padding(
              key: const ValueKey('running-work'),
              padding: padding,
              child: ActivityTicker(
                active: true,
                clock: clock,
                builder: (context, now) => _rows(context, value, now),
              ),
            ),
          );
        },
      );

  Widget _rows(BuildContext context, ActivitySnapshot value, DateTime now) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final ended = [
      for (final a in value.subagents)
        if (a.isTerminal) a,
    ];
    // What could not be read again says so on its own rows: a stale count
    // of subagents does not put in doubt a process just confirmed alive.
    final staleWork = value.processesStale
        ? s.chaBackgroundActivityStale
        : null;
    final staleAgents = value.subagentsStale
        ? s.chaBackgroundActivityStale
        : null;
    final dismiss = ended.isNotEmpty && value.subagentLive == 0
        ? actions.dismissSubagents
        : null;
    final rows = [
      for (final process in value.processes)
        _process(s, process, now, staleWork),
      for (final activity in value.subagents)
        if (!activity.isTerminal)
          _subagent(s, colors, activity, now, staleAgents),
      // Subagents known only by their number.
      if (value.subagents.isEmpty && value.hasSubagents)
        _RunningRow(
          key: const ValueKey('running-subagents-count'),
          icon: Icons.smart_toy_outlined,
          kind: s.runKindSubagent,
          live: true,
          title: value.subagentCount == 0
              ? s.chaBackgroundWorkTitle
              : s.liveSubagentsWorking(value.subagentCount),
          meta: s.runKindSubagent,
          stale: staleAgents,
        ),
      for (final (index, schedule) in value.schedules.indexed)
        _schedule(context, s, schedule, index, staleWork),
      if (value.goal case final goal?) _goal(s, goal, staleWork),
      for (final activity in ended) _subagent(s, colors, activity, now, null),
    ];
    final line = Divider(
      height: 1,
      thickness: 1,
      color: colors.divider.withValues(alpha: 0.5),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title)
          HermesSectionHeader(
            s.runTitle,
            key: const ValueKey('running-work-title'),
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
          ),
        for (final (index, row) in rows.indexed) ...[if (index > 0) line, row],
        if (dismiss != null)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 12, bottom: 4),
              child: _RowAction(
                key: const ValueKey('running-subagents-dismiss'),
                label: s.inAppDismiss,
                onPressed: dismiss,
              ),
            ),
          ),
      ],
    );
  }

  Widget _process(
    Strings s,
    SessionActivityProcess process,
    DateTime now,
    String? stale,
  ) {
    final started = process.startedAt;
    final since = started == null
        ? null
        : now.toUtc().difference(started.toUtc());
    final stop = actions.stopProcess;
    final command = process.command.trim();
    final more = [
      if (process.watchHit) s.chaBackgroundWatchHit,
      if (process.watchPatterns.isNotEmpty)
        '${s.chaBackgroundWatchPatterns}: ${process.watchPatterns.join(', ')}',
      if (process.notifyOnComplete) s.chaBackgroundProcessWillNotify,
    ];
    return _RunningRow(
      key: ValueKey('running-process-${process.id}'),
      // The icon the transcript gives a command that runs.
      icon: Icons.terminal_rounded,
      kind: s.runKindProcess,
      live: true,
      title: command.isEmpty ? s.chaBackgroundProcessRunning : command,
      mono: command.isNotEmpty,
      meta: [
        s.runKindProcess,
        if (since != null)
          formatTurnElapsed(since.isNegative ? Duration.zero : since),
      ].join(' · '),
      more: more.isEmpty ? null : more.join(' · '),
      stale: stale,
      action: stop == null
          ? null
          : _RowAction(
              key: ValueKey('running-process-stop-${process.id}'),
              label: s.chaBackgroundActionStop,
              about: command.isEmpty ? s.runKindProcess : command,
              onPressed: () => stop(process),
            ),
    );
  }

  Widget _subagent(
    Strings s,
    HermesThemeColors colors,
    SubagentActivity activity,
    DateTime now,
    String? stale,
  ) {
    final status = subagentHumanStatus(s, activity);
    final elapsed = subagentElapsed(activity, now);
    final ended = activity.isTerminal;
    final open = actions.openSubagent;
    return _RunningRow(
      key: ValueKey('running-subagent-${activity.key.stableId}'),
      // The app's icon for an agent (the Bots tab, Mission Control).
      icon: Icons.smart_toy_outlined,
      kind: s.runKindSubagent,
      live: !ended,
      muted: ended,
      title: subagentTitle(s, activity, maxChars: 120),
      meta: [
        s.runKindSubagent,
        status.label,
        if (elapsed != null) formatTurnElapsed(elapsed),
        if (activity.progress case final progress?)
          s.subagentActivityProgress(
            progress.displayTaskIndex,
            progress.taskCount,
          ),
      ].join(' · '),
      metaColor: status.tone == HermesStatusTone.error ? colors.error : null,
      stale: stale,
      onTap: open == null ? null : () => open(activity),
      action: open == null
          ? null
          : _RowAction(
              key: ValueKey('running-subagent-open-${activity.key.stableId}'),
              label: s.islandSee,
              about: s.runKindSubagent,
              onPressed: () => open(activity),
            ),
    );
  }

  Widget _schedule(
    BuildContext context,
    Strings s,
    SessionActivitySchedule schedule,
    int index,
    String? stale,
  ) {
    final loc = MaterialLocalizations.of(context);
    String time(DateTime value) =>
        loc.formatTimeOfDay(TimeOfDay.fromDateTime(value.toLocal()));
    final isLoop = schedule.kind == SessionActivityScheduleKind.loop;
    final name = isLoop ? s.chaBackgroundLoop : s.chaBackgroundHeartbeat;
    // Only what explains why it is not simply running.
    final more = [
      if (schedule.status != 'active') _statusWord(s, schedule.status),
      if (schedule.awaitingResponse) s.chaBackgroundAwaitingResponse,
      if (schedule.deferredByGoal) s.chaBackgroundDeferredByGoal,
    ];
    return _RunningRow(
      key: ValueKey('running-${isLoop ? 'loop' : 'heartbeat'}-$index'),
      // The clock of everything scheduled (Cron, the drawer, the dock).
      icon: Icons.schedule_rounded,
      kind: name,
      title: name,
      meta: [
        s.chaBackgroundInterval(_every(schedule.interval)),
        if (schedule.nextDueAt case final next?) s.runNextDue(time(next)),
      ].join(' · '),
      more: more.isEmpty ? null : more.join(' · '),
      stale: stale,
    );
  }

  Widget _goal(Strings s, SessionActivityGoal goal, String? stale) {
    final details = actions.goalDetails;
    final (label, act) = switch (goal.status) {
      'paused' when actions.resumeGoal != null => (
        s.chaGoalActionResume,
        actions.resumeGoal,
      ),
      'active' when actions.pauseGoal != null => (
        s.chaGoalActionPause,
        actions.pauseGoal,
      ),
      _ => (s.islandSee, details),
    };
    return _RunningRow(
      key: const ValueKey('running-goal'),
      // The flag of the goal's notices.
      icon: Icons.flag_outlined,
      kind: s.runKindGoal,
      title: goal.title.trim().isEmpty ? s.chaGoalSheetTitle : goal.title,
      meta: '${s.runKindGoal} · ${_statusWord(s, goal.status).toLowerCase()}',
      stale: stale,
      onTap: details,
      action: act == null
          ? null
          : _RowAction(
              key: const ValueKey('running-goal-action'),
              label: label,
              about: s.runKindGoal,
              onPressed: act,
            ),
    );
  }

  static String _statusWord(Strings s, String value) => switch (value) {
    'active' => s.chaBackgroundStatusActive,
    'paused' => s.chaBackgroundStatusPaused,
    'waiting' => s.chaBackgroundStatusWaiting,
    'done' => s.chaBackgroundStatusDone,
    _ => value,
  };

  static String _every(Duration value) {
    if (value.inHours > 0 && value.inMinutes % 60 == 0) {
      return '${value.inHours} h';
    }
    if (value.inMinutes > 0) return '${value.inMinutes} min';
    return '${value.inSeconds} s';
  }
}

/// One thing that is alive: an icon in its own square, what it is in full,
/// its kind in words with how it is going and, at the end, the one thing
/// that can be done to it. Nothing is cut at a phone's width: words wrap.
class _RunningRow extends StatelessWidget {
  const _RunningRow({
    required this.icon,
    required this.kind,
    required this.title,
    required this.meta,
    this.live = false,
    this.muted = false,
    this.mono = false,
    this.metaColor,
    this.more,
    this.stale,
    this.action,
    this.onTap,
    super.key,
  });

  final IconData icon;

  /// What the icon stands for, in words (read by a screen reader).
  final String kind;

  /// It is running now: the icon and a dot take the accent.
  final bool live;

  /// It ended: its name steps back.
  final bool muted;
  final String title;

  /// A command: set in the code face.
  final bool mono;

  /// The kind in words and how it is going.
  final String meta;
  final Color? metaColor;

  /// What else is known of it, on a line of its own.
  final String? more;

  /// Said when this is only the last state known of it.
  final String? stale;

  final Widget? action;

  /// The whole row opens what there is to see of it.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final quiet = TextStyle(
      fontSize: _Run.meta,
      height: 1.35,
      color: colors.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // With large text the action goes under the words instead of
    // squeezing them into a sliver beside it.
    final stacked =
        action != null && MediaQuery.textScalerOf(context).scale(10) >= 14;
    final tap = onTap;
    final said = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _Run.minHeight - 20),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: live
                  ? colors.accent.withValues(alpha: 0.16)
                  : colors.textPrimary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox.square(
              dimension: _Run.iconBox,
              child: Icon(
                icon,
                size: _Run.icon,
                color: live ? colors.accentText : colors.textSecondary,
                semanticLabel: kind,
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: mono
                      // The code face of the transcript.
                      ? chatCodeTextStyle(
                          colors.textPrimary,
                          fontSize: _Run.mono,
                        ).copyWith(height: 1.35, fontWeight: FontWeight.w600)
                      : TextStyle(
                          fontSize: _Run.title,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: muted
                              ? colors.textSecondary
                              : colors.textPrimary,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (live)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsetsDirectional.only(end: 6),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.accent,
                                  shape: BoxShape.circle,
                                ),
                                child: const SizedBox.square(dimension: 6),
                              ),
                            ),
                          ),
                        TextSpan(text: meta),
                      ],
                    ),
                    style: quiet.copyWith(color: metaColor),
                  ),
                ),
                if (more != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(more!, style: quiet.copyWith(fontSize: 13)),
                  ),
                if (stale != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      stale!,
                      style: quiet.copyWith(
                        fontSize: 13,
                        color: colors.warning,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    // What the row says is ONE node for a screen reader (its kind, its
    // name, how it is going); its action is a button of its own beside it.
    final words = MergeSemantics(
      child: tap == null
          ? said
          : InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: tap,
              child: said,
            ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _Run.minHeight),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 12, 10),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  words,
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: _Run.iconBox + 13,
                    ),
                    child: action,
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(child: words),
                  if (action != null)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 8),
                      child: action,
                    ),
                ],
              ),
      ),
    );
  }
}

/// The one action of a row: a named pill, 36 dp tall in a 48 dp target.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.label,
    required this.onPressed,
    this.about,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  /// What it acts on, said after [label] to a screen reader («Detener,
  /// npm run dev»).
  final String? about;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      container: true,
      button: true,
      label: [label, ?about].join(', '),
      onTap: onPressed,
      excludeSemantics: true,
      child: _button(context, colors),
    );
  }

  Widget _button(BuildContext context, HermesThemeColors colors) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(64, 36),
        tapTargetSize: MaterialTapTargetSize.padded,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: const StadiumBorder(),
        backgroundColor: colors.textPrimary.withValues(alpha: 0.08),
        foregroundColor: colors.textPrimary,
        // The app's own face (a bare TextStyle would drop it).
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: Text(label),
    );
  }
}

/// What of the running work a change is about.
enum RunningWorkKind { subagent, process, loop, goal }

/// What happened to it.
enum RunningWorkEvent { started, ended, failed }

/// One thing worth saying about the running work: something started, ended
/// or failed between two snapshots.
@immutable
final class RunningWorkChange {
  const RunningWorkChange(this.event, {required this.kind, this.name});

  final RunningWorkEvent event;
  final RunningWorkKind kind;

  /// What it is called (a command, a goal's title, a subagent's task).
  final String? name;

  /// The most telling difference between what was alive [before] and what is
  /// alive [after]: a failure first, then an end, then a start. Null when
  /// nothing of it changed. [before] is null for the first look at a
  /// conversation, which is not news: its count says what is alive.
  static RunningWorkChange? between(
    ActivitySnapshot? before,
    ActivitySnapshot after,
    Strings strings,
  ) {
    if (before == null) return null;
    RunningWorkChange? started;
    RunningWorkChange? ended;

    String? named(String value) => value.trim().isEmpty ? null : value.trim();

    // Subagents, one by one where they are known.
    final known = {for (final a in before.subagents) a.key: a};
    for (final a in after.subagents) {
      final was = known[a.key];
      if (a.phase == SubagentActivityPhase.failed) {
        if (was?.phase != SubagentActivityPhase.failed) {
          return RunningWorkChange(
            RunningWorkEvent.failed,
            kind: RunningWorkKind.subagent,
            name: named(subagentTitle(strings, a, maxChars: 60)),
          );
        }
      } else if (a.isTerminal) {
        if (was == null || !was.isTerminal) {
          ended ??= RunningWorkChange(
            RunningWorkEvent.ended,
            kind: RunningWorkKind.subagent,
            name: named(subagentTitle(strings, a, maxChars: 60)),
          );
        }
      } else if (was == null && a.phase != SubagentActivityPhase.unknown) {
        started ??= RunningWorkChange(
          RunningWorkEvent.started,
          kind: RunningWorkKind.subagent,
          name: named(subagentTitle(strings, a, maxChars: 60)),
        );
      }
    }
    // Subagents known only by their number.
    if (before.subagents.isEmpty && after.subagents.isEmpty) {
      if (!before.subagentsRunning && after.subagentsRunning) {
        started ??= const RunningWorkChange(
          RunningWorkEvent.started,
          kind: RunningWorkKind.subagent,
        );
      } else if (before.subagentsRunning && !after.subagentsRunning) {
        ended ??= const RunningWorkChange(
          RunningWorkEvent.ended,
          kind: RunningWorkKind.subagent,
        );
      }
    }

    // Background processes.
    final ran = {for (final p in before.processes) p.id};
    final runs = {for (final p in after.processes) p.id};
    for (final p in before.processes) {
      if (!runs.contains(p.id)) {
        ended ??= RunningWorkChange(
          RunningWorkEvent.ended,
          kind: RunningWorkKind.process,
          name: named(p.command),
        );
      }
    }
    for (final p in after.processes) {
      if (!ran.contains(p.id)) {
        started ??= RunningWorkChange(
          RunningWorkEvent.started,
          kind: RunningWorkKind.process,
          name: named(p.command),
        );
      }
    }

    // Loops have no name of their own: their number says it.
    if (after.schedules.length < before.schedules.length) {
      ended ??= const RunningWorkChange(
        RunningWorkEvent.ended,
        kind: RunningWorkKind.loop,
      );
    } else if (after.schedules.length > before.schedules.length) {
      started ??= const RunningWorkChange(
        RunningWorkEvent.started,
        kind: RunningWorkKind.loop,
      );
    }

    // The goal.
    final goalBefore = before.goal;
    final goalAfter = after.goal;
    if (goalBefore != null && goalAfter == null) {
      ended ??= RunningWorkChange(
        RunningWorkEvent.ended,
        kind: RunningWorkKind.goal,
        name: named(goalBefore.title),
      );
    } else if (goalBefore == null && goalAfter != null) {
      started ??= RunningWorkChange(
        RunningWorkEvent.started,
        kind: RunningWorkKind.goal,
        name: named(goalAfter.title),
      );
    }
    return ended ?? started;
  }

  /// The change in one line.
  String line(Strings s) => switch ((kind, event)) {
    (RunningWorkKind.subagent, RunningWorkEvent.started) =>
      s.runSubagentStarted,
    (RunningWorkKind.subagent, RunningWorkEvent.ended) => s.runSubagentEnded,
    (RunningWorkKind.subagent, RunningWorkEvent.failed) => s.runSubagentFailed,
    (RunningWorkKind.process, RunningWorkEvent.started) => s.runProcessStarted,
    (RunningWorkKind.process, _) => s.runProcessEnded,
    (RunningWorkKind.loop, RunningWorkEvent.started) => s.runLoopStarted,
    (RunningWorkKind.loop, _) => s.runLoopEnded,
    (RunningWorkKind.goal, RunningWorkEvent.started) => s.runGoalStarted,
    (RunningWorkKind.goal, _) => s.runGoalEnded,
  };

  @override
  bool operator ==(Object other) =>
      other is RunningWorkChange &&
      other.event == event &&
      other.kind == kind &&
      other.name == name;

  @override
  int get hashCode => Object.hash(event, kind, name);
}
