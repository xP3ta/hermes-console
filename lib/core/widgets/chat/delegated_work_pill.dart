import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/activity_snapshot.dart';
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
    super.key,
  });

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

  bool get _unknown =>
      (widget.snapshot.subagentsStale &&
          widget.snapshot.hasSubagents &&
          !_childrenSettled) ||
      (widget.snapshot.processesStale && widget.snapshot.backgroundCount > 0) ||
      widget.snapshot.subagents.any(
        (a) => a.phase == SubagentActivityPhase.unknown,
      );
  bool get _working =>
      !_unknown &&
      (widget.snapshot.subagentGroupCount.finished <
              widget.snapshot.subagentCount ||
          widget.snapshot.backgroundCount > 0);

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
      _elapsedAtDone = began == null
          ? null
          : (widget.clock ?? DateTime.now)().difference(began);
      _started = null;
      if (_failures.isEmpty) {
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
  Widget _capsule(BuildContext context, Strings s, HermesThemeColors colors) {
    final snapshot = widget.snapshot;
    final failed = _failures.isNotEmpty;
    final state = _unknown
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
        return s.delegatedCapsuleDone(
          formatTurnClock(_elapsedAtDone ?? Duration.zero),
          _lastTotal,
        );
      }
      if (_settledStale) {
        return s.delegatedCapsuleFinished(snapshot.subagentCount);
      }
      final since = _started;
      final clock = since == null || now == null
          ? '0:00'
          : formatTurnClock(now.difference(since));
      final agents = snapshot.subagentCount;
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
        child: SizedBox(
          height: 48,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _open,
            child: Center(
              child: DelegatedWorkEffect(
                active: _working,
                child: HermesFloatingSurface(
                  shadow: false,
                  child: SizedBox(
                    height: 36,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
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
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
        (_unknown && snapshot.hasNonTurnActivity);
    if (widget.capsule) {
      if (widget.hidden || !visible) return const SizedBox.shrink();
      return _capsule(context, s, colors);
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
      if (_done) s.chatLiveReady(_lastTotal),
      if (!_done && _settledStale)
        s.delegatedCapsuleFinished(snapshot.subagentCount),
      if (!_done && !_settledStale && snapshot.subagentCount > 0)
        s.chatLiveAgents(snapshot.subagentCount),
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
                                  ? Icons.check_rounded
                                  : Icons.account_tree_outlined,
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
