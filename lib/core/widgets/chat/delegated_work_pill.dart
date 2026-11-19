import 'package:hermes_android/core/design/hicons.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/activity_snapshot.dart';
import '../../models/agent_task_list.dart';
import '../../design/floating.dart';
import '../../models/subagent_activity.dart';
import '../../theme/app_theme.dart';
import '../activity_pill.dart' show ActivityTicker;
import '../island.dart' show IslandHeadroom;
import 'live_motion.dart';
import 'delegated_icons.dart';
import 'turn_activity_pill.dart' show formatTurnClock;

/// Identity at rest; only delegated work may replace it. Unknown/stale work
/// never claims to be running or completed. Failures wait for acknowledgement.
class DelegatedWorkPill extends StatefulWidget {
  const DelegatedWorkPill({
    required this.name,
    required this.snapshot,
    required this.onOpen,
    this.clock,
    this.idle,
    this.showIdle = false,
    this.hidden = false,
    this.capsule = false,
    this.parentTurnEnded = false,
    this.padding = EdgeInsets.zero,
    this.tasks,
    super.key,
  });

  /// The agent's task list while the capsule carries it (null: it does not).
  final AgentTaskList? tasks;

  /// The parent turn has ended while its children still run: the capsule is
  /// the separate «Ejecutando N subagentes ›» entry (the composer rests).
  final bool parentTurnEnded;

  /// Design B: the capsule above the composer (≈36 dp over a 48 dp target)
  /// instead of the header's identity pill. It draws nothing at rest; the
  /// header stays identity only.
  final bool capsule;

  /// Outside margin of the capsule: the composer's own side insets.
  final EdgeInsetsGeometry padding;
  final String name;
  final Widget? idle;
  final bool showIdle;
  final bool hidden;
  final ActivitySnapshot snapshot;
  final Future<void> Function() onOpen;
  final DateTime Function()? clock;

  @override
  State<DelegatedWorkPill> createState() => _DelegatedWorkPillState();
}

class _DelegatedWorkPillState extends State<DelegatedWorkPill> {
  Timer? _hold;
  bool _done = false;
  bool _hadWork = false;
  int _lastTotal = 0;
  // F1: the exact children (stable keys) this group counted while it worked,
  // and how many of them the end credits. «terminaron» needs server terminal
  // evidence for EACH of them; absence, or terminal rows of another batch,
  // credit nothing.
  final Set<String> _countedIds = {};
  // Terminal evidence (and its completion time) of counted children, kept
  // when seen: a finished child may leave the roster (a new turn retires it)
  // while its siblings still work.
  final Map<String, DateTime?> _countedTerminal = {};
  int _lastBackground = 0;
  bool _countedSubagentWork = false;
  int _creditedTotal = 0;
  DateTime? _started;
  Duration? _elapsedAtDone;
  final Set<String> _acknowledged = {};
  final Set<String> _failures = {};
  final Set<String> _cancelled = {};

  /// Every child of the roster has its outcome from the server (completed,
  /// failed or stopped) and none is known only by its number. A stale roster
  /// flag (a reconnect, a cold resume) cannot put that outcome in doubt: the
  /// group is «✓ N subagentes terminados», never «Sin confirmar».
  bool get _childrenSettled {
    final snapshot = widget.snapshot;
    return snapshot.subagents.isNotEmpty &&
        !snapshot.passiveRemote &&
        snapshot.subagentGenericCount <= snapshot.subagents.length &&
        snapshot.subagents.every((a) => a.isTerminal);
  }

  /// A stale roster whose children all ended and none failed: it says so for
  /// as long as «Sin confirmar» would have stayed, instead of the doubt. A
  /// failure keeps its own «Falló» until it is seen.
  bool get _settledStale =>
      widget.snapshot.subagentsStale &&
      _childrenSettled &&
      widget.snapshot.backgroundCount == 0 &&
      !widget.snapshot.subagents.any(
        (a) => a.phase == SubagentActivityPhase.failed,
      );

  /// S1: confirmed not active by this binding's fenced roster (the row stays,
  /// its outcome is unknown); never counted as occupation.
  bool _absent(SubagentActivity a) =>
      widget.snapshot.subagentsAbsentConfirmed.contains(a.key);
  int get _absentCount => widget.snapshot.subagents.where(_absent).length;

  bool get _unknown =>
      (widget.snapshot.subagentsStale &&
          widget.snapshot.hasSubagents &&
          !_childrenSettled) ||
      (widget.snapshot.processesStale && widget.snapshot.backgroundCount > 0) ||
      widget.snapshot.subagents.any(
        (a) => a.phase == SubagentActivityPhase.unknown && !_absent(a),
      );
  bool get _working =>
      !_unknown &&
      (widget.snapshot.subagentGroupCount.finished <
              widget.snapshot.subagentCount - _absentCount ||
          widget.snapshot.backgroundCount > 0);

  /// S1: nothing live, nothing unconfirmed, and some rows confirmed not
  /// active: «N subagentes · No activos · Resultado final no disponible».
  /// Not busy, no clock, no outcome.
  bool get _absentOnly =>
      !_unknown &&
      !_working &&
      _absentCount > 0 &&
      widget.snapshot.backgroundCount == 0 &&
      widget.snapshot.subagents.every((a) => a.isTerminal || _absent(a));

  String _absentLabel(Strings s) => [
    s.chatLiveAgents(_absentCount),
    s.subagentUiStatusNotActive(_absentCount),
    s.subagentUiResultUnavailable,
  ].join(' · ');

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(DelegatedWorkPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final snapshot = widget.snapshot;
    // Closing the group is a presentation choice, never terminal evidence.
    if (widget.hidden) {
      _hold?.cancel();
      _countedIds.clear();
      _countedTerminal.clear();
      _countedSubagentWork = false;
      _hadWork = _done = false;
      _started = null;
      _acknowledged.addAll(_failures);
      _failures.clear();
      return;
    }
    // Server truth that a child completed retires its latched stop/failure.
    final completed = snapshot.subagents
        .where((a) => a.phase == SubagentActivityPhase.completed)
        .map((a) => a.key.stableId)
        .toSet();
    _failures.removeAll(completed);
    _cancelled.removeAll(completed);
    _cancelled.addAll(
      snapshot.subagents
          .where((a) => a.phase == SubagentActivityPhase.cancelled)
          .map((a) => a.key.stableId),
    );
    _failures.addAll(
      snapshot.subagents
          .where(
            (a) =>
                a.phase == SubagentActivityPhase.failed ||
                a.phase == SubagentActivityPhase.cancelled,
          )
          .map((a) => a.key.stableId)
          .where((id) => !_acknowledged.contains(id)),
    );
    if (_working) {
      _lastTotal = snapshot.subagentCount + snapshot.backgroundCount;
      _lastBackground = snapshot.backgroundCount;
      // Only live subagent work (or a number-only roster) is subagent work;
      // terminal rows of an earlier batch are not.
      _countedSubagentWork =
          _countedSubagentWork ||
          snapshot.subagents.any((a) => !a.isTerminal) ||
          snapshot.subagentGenericCount > snapshot.subagents.length;
      for (final a in snapshot.subagents) {
        final id = a.key.stableId;
        if (!a.isTerminal) {
          _countedIds.add(id);
          _countedTerminal.remove(id);
        } else if (_countedIds.contains(id)) {
          _countedTerminal[id] = a.details.completedAt ?? _countedTerminal[id];
        }
      }
      _started ??=
          snapshot.backgroundStartedAt ??
          snapshot.subagents
              .map((a) => a.details.startedAt)
              .whereType<DateTime>()
              .fold<DateTime?>(
                null,
                (first, at) => first == null || at.isBefore(first) ? at : first,
              ) ??
          (widget.clock ?? DateTime.now)();
      _hadWork = true;
      _done = false;
      _hold?.cancel();
    } else if (_hadWork && !_unknown) {
      _hadWork = false;
      final began = _started;
      _started = null;
      final counted = {..._countedIds};
      final seenTerminal = {..._countedTerminal};
      final subagentWork = _countedSubagentWork;
      _countedIds.clear();
      _countedTerminal.clear();
      _countedSubagentWork = false;
      var credited = true;
      if (subagentWork) {
        // Each counted child needs terminal evidence: a terminal row in this
        // snapshot, or one seen earlier while the group worked.
        final byId = {for (final a in snapshot.subagents) a.key.stableId: a};
        final settled = <String, DateTime?>{
          for (final id in counted)
            if (byId[id] case final a? when a.isTerminal)
              id: a.details.completedAt ?? seenTerminal[id]
            else if (seenTerminal.containsKey(id))
              id: seenTerminal[id],
        };
        credited = counted.isNotEmpty && settled.length == counted.length;
        final ends = [for (final end in settled.values) ?end];
        // The clock runs to the latest server completion, never to «now»;
        // without a completion time for every child there is no clock.
        if (!credited || began == null || ends.length != settled.length) {
          _elapsedAtDone = null;
        } else {
          final last = ends.reduce((a, b) => a.isAfter(b) ? a : b);
          final span = last.difference(began);
          _elapsedAtDone = span.isNegative ? Duration.zero : span;
        }
        _creditedTotal = credited ? counted.length + _lastBackground : 0;
      } else {
        // Background processes only: unchanged.
        _elapsedAtDone = began == null
            ? null
            : (widget.clock ?? DateTime.now)().difference(began);
        _creditedTotal = _lastTotal;
      }
      if (!credited) {
        _done = false;
        _hold?.cancel();
      }
      if (_failures.isEmpty && credited) {
        _done = true;
        _hold?.cancel();
        _hold = Timer(Duration(seconds: widget.capsule ? 3 : 2), () {
          if (mounted) setState(() => _done = false);
        });
      }
    }
  }

  Future<void> _open() async {
    final seen = {..._failures};
    await widget.onOpen();
    if (!mounted) return;
    setState(() {
      _acknowledged.addAll(seen);
      _failures.removeAll(seen);
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  /// «⛓ Delegado a 2 subagentes · 0:04 · 1/2 ›», «✓ 2 subagentes terminaron ·
  /// 0:06 ›» for a moment, «Falló · 2 subagentes ›» until acknowledged. Unknown
  /// or stale work is never shown as progress.
  Widget _capsule(
    BuildContext context,
    Strings s,
    HermesThemeColors colors, {
    required bool delegated,
  }) {
    final snapshot = widget.snapshot;
    final failed = _failures.isNotEmpty;
    final state = _unknown || (_absentOnly && !_done && !failed)
        ? DelegatedIconState.unknown
        : failed
        ? DelegatedIconState.failed
        : _done || _settledStale
        ? DelegatedIconState.done
        : DelegatedIconState.running;
    final tint = switch (state) {
      DelegatedIconState.failed => colors.error,
      DelegatedIconState.unknown => colors.textTertiary,
      _ => colors.accent,
    };
    String label(DateTime? now) {
      if (_unknown) return s.subagentUiStatusUnconfirmed;
      if (failed) {
        return [
          if (_failures.any((id) => !_cancelled.contains(id)))
            s.subagentUiStatusFailed,
          if (_failures.any(_cancelled.contains)) s.subagentUiStatusStopped,
          if (snapshot.subagentCount > 0)
            s.chatLiveAgents(snapshot.subagentCount),
          if (snapshot.backgroundCount > 0)
            s.activityProcessCount(snapshot.backgroundCount),
        ].join(' · ');
      }
      if (_done) {
        final elapsed = _elapsedAtDone;
        return elapsed == null
            ? s.delegatedCapsuleFinished(_creditedTotal)
            : s.delegatedCapsuleDone(formatTurnClock(elapsed), _creditedTotal);
      }
      if (_settledStale) {
        return s.delegatedCapsuleFinished(snapshot.subagentCount);
      }
      if (_absentOnly) return _absentLabel(s);
      final since = _started;
      final clock = since == null || now == null
          ? '0:00'
          : formatTurnClock(now.difference(since));
      final agents = snapshot.subagentCount - _absentCount;
      final processes = snapshot.backgroundCount;
      final running = agents - snapshot.subagentGroupCount.finished;
      if (widget.parentTurnEnded && running > 0) {
        return [
          s.delegatedCapsuleRunningIdle(running),
          if (processes > 0) s.activityProcessCount(processes),
        ].join(' · ');
      }
      return [
        if (agents > 0)
          s.delegatedCapsuleRunning(
            clock,
            agents,
            snapshot.subagentGroupCount.finished,
          ),
        if (processes > 0) s.activityProcessCount(processes),
      ].join(' · ');
    }

    final text = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: colors.textPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final live = _working && !_unknown && !failed;
    // The «not active» state is said whole: at a phone width or with large
    // text it wraps and the capsule grows; it is never cut.
    final whole = _absentOnly && !_done && !failed;
    if (!whole) {
      final tasks = widget.tasks;
      final quiet = TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: colors.textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      Widget sep() => Container(
        width: 1,
        height: 12,
        margin: const EdgeInsets.symmetric(horizontal: 9),
        color: colors.textPrimary.withValues(alpha: 0.14),
      );
      final agents = snapshot.subagentCount - _absentCount;
      final processes = snapshot.backgroundCount;
      final plain =
          state == DelegatedIconState.running && !widget.parentTurnEnded;
      return Padding(
        padding: widget.padding,
        child: Semantics(
          key: const ValueKey('delegates-capsule'),
          container: true,
          button: true,
          liveRegion: true,
          label: [
            if (tasks != null) s.agentTasksSummary(tasks.done, tasks.total),
            if (delegated) label(null),
          ].join(', '),
          onTap: _open,
          excludeSemantics: true,
          child: Center(
            heightFactor: 1,
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: _open,
              child: Padding(
                // 32 dp painted, 48 dp to touch.
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: DelegatedWorkEffect(
                  active: delegated && _working,
                  child: HermesFloatingSurface(
                    shadow: false,
                    child: SizedBox(
                      height: 32,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (tasks != null) ...[
                              SizedBox.square(
                                dimension: 13,
                                child: CircularProgressIndicator(
                                  value: tasks.progress,
                                  strokeWidth: 1.6,
                                  color: tasks.isFinished
                                      ? colors.success
                                      : colors.accent,
                                  backgroundColor: colors.textPrimary
                                      .withValues(alpha: 0.16),
                                ),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                '${tasks.done}/${tasks.total}',
                                key: const ValueKey('delegates-capsule-tasks'),
                                style: quiet,
                              ),
                            ],
                            if (tasks != null && delegated) sep(),
                            if (delegated && plain) ...[
                              if (agents > 0) ...[
                                delegatedCapsuleIcon(
                                  context,
                                  state,
                                  color: tint,
                                  size: 14,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    s.chatLiveAgents(agents),
                                    key: const ValueKey(
                                      'delegates-capsule-text',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: quiet,
                                  ),
                                ),
                                ActivityTicker(
                                  active: live,
                                  clock: widget.clock,
                                  builder: (context, now) => Text(
                                    _started == null
                                        ? ''
                                        : '  ${formatTurnClock(now.difference(_started!))}',
                                    style: quiet.copyWith(
                                      color: colors.textTertiary,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ],
                              if (agents > 0 && processes > 0) sep(),
                              if (processes > 0) ...[
                                Icon(
                                  HIcons.terminal_rounded,
                                  size: 13,
                                  color: colors.textSecondary,
                                ),
                                const SizedBox(width: 5),
                                Text('$processes', style: quiet),
                              ],
                            ],
                            if (delegated && !plain) ...[
                              delegatedCapsuleIcon(
                                context,
                                state,
                                color: tint,
                                size: 14,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: ActivityTicker(
                                  active: live,
                                  clock: widget.clock,
                                  builder: (context, now) => Text(
                                    label(now),
                                    key: const ValueKey(
                                      'delegates-capsule-text',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: quiet,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: widget.padding,
      child: Semantics(
        key: const ValueKey('delegates-capsule'),
        container: true,
        button: true,
        liveRegion: true,
        label: label(null),
        onTap: _open,
        excludeSemantics: true,
        child: _CapsuleBox(
          whole: whole,
          height: 48,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _open,
            child: Center(
              child: DelegatedWorkEffect(
                active: _working,
                child: HermesFloatingSurface(
                  shadow: false,
                  child: _CapsuleBox(
                    whole: whole,
                    height: 36,
                    child: Padding(
                      padding: whole
                          ? const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            )
                          : const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          delegatedCapsuleIcon(context, state, color: tint),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ActivityTicker(
                              active: live,
                              clock: widget.clock,
                              builder: (context, now) => Text(
                                label(now),
                                key: const ValueKey('delegates-capsule-text'),
                                maxLines: whole ? null : 1,
                                overflow: whole ? null : TextOverflow.ellipsis,
                                style: text,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          delegatedCapsuleChevron(
                            context,
                            color: colors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final visible =
        _working ||
        _done ||
        _failures.isNotEmpty ||
        _settledStale ||
        _absentOnly ||
        (_unknown && snapshot.hasNonTurnActivity);
    if (widget.capsule) {
      final tasks = widget.tasks;
      if (widget.hidden || (!visible && (tasks == null || tasks.isEmpty))) {
        return const SizedBox.shrink();
      }
      return _capsule(context, s, colors, delegated: visible);
    }
    if (widget.hidden || widget.showIdle || !visible) {
      return widget.idle ??
          SizedBox(
            height: 48,
            child: Center(
              child: Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
    }
    final label = [
      if (_failures.any((id) => !_cancelled.contains(id)))
        s.subagentUiStatusFailed,
      if (_failures.any(_cancelled.contains)) s.subagentUiStatusStopped,
      if (_unknown) s.subagentUiStatusUnconfirmed,
      if (_done) s.chatLiveReady(_creditedTotal),
      if (!_done && _settledStale)
        s.delegatedCapsuleFinished(snapshot.subagentCount),
      if (!_done && !_settledStale && _absentOnly) _absentLabel(s),
      if (!_done &&
          !_settledStale &&
          !_absentOnly &&
          snapshot.subagentCount - _absentCount > 0)
        s.chatLiveAgents(snapshot.subagentCount - _absentCount),
      if (!_done && snapshot.backgroundCount > 0)
        s.activityProcessCount(snapshot.backgroundCount),
    ].join(' · ');
    return Padding(
      padding: EdgeInsets.only(top: IslandHeadroom.of(context)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Semantics(
          key: const ValueKey('delegates-capsule'),
          container: true,
          button: true,
          liveRegion: true,
          label: label,
          onTap: _open,
          excludeSemantics: true,
          child: DelegatedWorkEffect(
            active: _working,
            child: HermesFloatingSurface(
              shadow: false,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: _open,
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final narrow = box.maxWidth < 190;
                        return Row(
                          children: [
                            Icon(
                              _done || _settledStale
                                  ? HIcons.check_rounded
                                  : HIcons.account_tree_outlined,
                              size: 16,
                              color: _failures.isEmpty
                                  ? colors.accent
                                  : colors.error,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: colors.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: narrow ? 20 : 36,
                              child: Row(
                                children: [
                                  for (final agent in snapshot.subagents.take(
                                    6,
                                  ))
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 1,
                                        ),
                                        child: LinearProgressIndicator(
                                          key: ValueKey(
                                            'delegate-progress-${agent.key.stableId}',
                                          ),
                                          value: _unknown
                                              ? 0
                                              : agent.isTerminal
                                              ? 1
                                              : agent
                                                        .progress
                                                        ?.displayFraction ??
                                                    0,
                                          minHeight: 3,
                                          color:
                                              agent.phase ==
                                                  SubagentActivityPhase.failed
                                              ? colors.error
                                              : colors.accent,
                                          backgroundColor: colors.divider,
                                        ),
                                      ),
                                    ),
                                  for (final process in snapshot.processes.take(
                                    6,
                                  ))
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 1,
                                        ),
                                        child: LinearProgressIndicator(
                                          key: ValueKey(
                                            'delegate-progress-process-${process.id}',
                                          ),
                                          value: 0,
                                          minHeight: 3,
                                          color: colors.accent,
                                          backgroundColor: colors.divider,
                                        ),
                                      ),
                                    ),
                                  if (snapshot.subagents.isEmpty &&
                                      snapshot.processes.isEmpty)
                                    Expanded(
                                      child: LinearProgressIndicator(
                                        value: _done ? 1 : 0,
                                        minHeight: 3,
                                        color: colors.accent,
                                        backgroundColor: colors.divider,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (!_unknown && _working && _started != null) ...[
                              const SizedBox(width: 6),
                              SizedBox(
                                width: narrow ? 34 : 48,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: ActivityTicker(
                                    active: true,
                                    clock: widget.clock,
                                    builder: (context, now) => Text(
                                      '· ${formatTurnClock(now.difference(_started!))}',
                                      key: const ValueKey('delegates-clock'),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.textTertiary,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The border and sprite halo own repaint-only clocks. No layout or text is
/// rebuilt on animation frames. Reduced motion supplies a static accent.
class DelegatedWorkEffect extends StatefulWidget {
  const DelegatedWorkEffect({
    required this.active,
    this.halo = false,
    this.child,
    super.key,
  });
  final bool active;
  final bool halo;
  final Widget? child;
  @override
  State<DelegatedWorkEffect> createState() => _DelegatedWorkEffectState();
}

class _DelegatedWorkEffectState extends State<DelegatedWorkEffect>
    with SingleTickerProviderStateMixin, LiveClockMixin<DelegatedWorkEffect> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncLiveClock(active: widget.active);
  }

  @override
  void didUpdateWidget(DelegatedWorkEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncLiveClock(active: widget.active);
  }

  @override
  void dispose() {
    disposeLiveClock();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      key: ValueKey(widget.halo ? 'delegates-sprite-halo' : 'delegates-border'),
      foregroundPainter: !widget.halo && widget.active
          ? _DelegatePainter(
              Theme.of(context).hermes.accent,
              liveSeconds,
              false,
            )
          : null,
      painter: widget.halo && widget.active
          ? _DelegatePainter(Theme.of(context).hermes.accent, liveSeconds, true)
          : null,
      child: widget.child,
    ),
  );
}

class _DelegatePainter extends CustomPainter {
  _DelegatePainter(this.color, this.seconds, this.halo)
    : super(repaint: seconds);
  final Color color;
  final Animation<double>? seconds;
  final bool halo;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final phase = (seconds?.value ?? 0) / 2.4 * math.pi * 2;
    if (halo) {
      final alpha = .18 + .05 * math.sin(phase);
      canvas.drawOval(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.deflate(.75), const Radius.circular(24)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = SweepGradient(
            colors: [
              color.withValues(alpha: .12),
              color.withValues(alpha: .15),
              color.withValues(alpha: .8),
              color.withValues(alpha: .12),
            ],
            stops: const [0, .7, .92, 1],
            transform: GradientRotation(phase),
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_DelegatePainter old) =>
      color != old.color || seconds != old.seconds || halo != old.halo;
}

/// The capsule's fixed height (a `SizedBox`, as every state has always had),
/// or, only for the «not active» state said whole, at least that height so
/// the label can wrap at a phone width or with large text.
class _CapsuleBox extends StatelessWidget {
  const _CapsuleBox({
    required this.whole,
    required this.height,
    required this.child,
  });

  final bool whole;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => whole
      ? ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: child,
        )
      : SizedBox(height: height, child: child);
}
