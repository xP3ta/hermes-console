import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../models/subagent_activity.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'activity_pill.dart' show ActivityTicker, formatTurnElapsed;

/// One timer, confined to the capsule. The roster owns counts and state;
/// reconnects never create a new clock origin or a terminal outcome.
class SubagentWorkPill extends StatefulWidget {
  const SubagentWorkPill({
    super.key,
    required this.working,
    this.unconfirmed = false,
    this.count = SubagentGroupCount.none,
    this.startedAt,
    this.clock,
    this.active = true,
    this.hidden = false,
    this.onTap,
    this.showCount = true,
    this.statusLabel,
    this.queuedCount = 0,
    this.queuePaused = false,
    this.onResumeQueue,
    this.processCount = 0,
    this.agentIcon = false,
    this.waitingForUser = false,
    this.onStop,
    this.showCompletion = true,
  });

  final int processCount;
  final bool agentIcon;
  final bool waitingForUser;
  final VoidCallback? onStop;
  final bool showCompletion;
  final int queuedCount;
  final bool queuePaused;
  final VoidCallback? onResumeQueue;

  final bool working;
  final bool unconfirmed;
  final SubagentGroupCount count;
  final DateTime? startedAt;
  final DateTime Function()? clock;
  final bool active;
  final bool hidden;
  final VoidCallback? onTap;
  final bool showCount;
  final String? statusLabel;

  @override
  State<SubagentWorkPill> createState() => _SubagentWorkPillState();
}

class _SubagentWorkPillState extends State<SubagentWorkPill> {
  DateTime? _finishedAt;
  DateTime? _observedStart;
  bool _hadWork = false;

  bool get _finished =>
      !widget.working &&
      !widget.unconfirmed &&
      widget.count.total > 0 &&
      widget.count.finished == widget.count.total;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SubagentWorkPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.working && widget.showCount && widget.count.total > 0) {
      _hadWork = true;
      final now = (widget.clock ?? DateTime.now)();
      final source = widget.startedAt;
      // Reject stale clock origins (e.g. a retained prior turn / epoch).
      _observedStart ??=
          source != null &&
              !source.isAfter(now) &&
              now.difference(source) < const Duration(days: 1)
          ? source
          : now;
    } else if (!widget.unconfirmed) {
      _observedStart = null;
      if (!_finished) _hadWork = false;
    }
    if (!_finished || !_hadWork) {
      _finishedAt = null;
    } else {
      _finishedAt ??= (widget.clock ?? DateTime.now)();
    }
  }

  @override
  Widget build(BuildContext context) => ActivityTicker(
    active:
        widget.active &&
        widget.showCount &&
        widget.count.total > 0 &&
        !widget.hidden &&
        !widget.unconfirmed &&
        (widget.working || _finishedAt != null),
    clock: widget.clock,
    until: _finishedAt?.add(HermesMotion.breath),
    builder: (context, now) {
      final s = Strings.of(context);
      final chrome = HermesChrome.of(Theme.of(context).hermes);
      final done = _finishedAt;
      final visible =
          !widget.hidden &&
          (widget.queuedCount > 0 ||
              widget.working ||
              widget.unconfirmed ||
              (widget.showCompletion &&
                  done != null &&
                  now.difference(done) < HermesMotion.breath));
      if (!visible) {
        return const SizedBox.shrink(key: ValueKey('subagent-card-hidden'));
      }
      final queueOnly =
          !widget.working && !widget.unconfirmed && widget.queuedCount > 0;
      final hasCount = !queueOnly && widget.showCount && widget.count.total > 0;
      final processLabel =
          widget.processCount > 0 &&
          !hasCount &&
          !widget.waitingForUser &&
          !widget.unconfirmed;
      final label = widget.waitingForUser
          ? widget.statusLabel ?? s.liveWaitingForUser
          : widget.unconfirmed
          ? s.subagentUiStatusUnconfirmed
          : widget.statusLabel ??
                (processLabel
                    ? s.activityProcessCount(widget.processCount)
                    : _finished
                    ? s.subagentUiStatusDone
                    : s.subagentPillWorking);
      final time = _observedStart == null
          ? null
          : formatTurnElapsed(now.difference(_observedStart!));
      final text = [
        queueOnly ? s.queuePillCount(widget.queuedCount) : label,
        if (widget.working && hasCount && time != null && !widget.unconfirmed)
          time,
      ].join(' ');
      final count = widget.count;
      final ink = widget.waitingForUser
          ? Theme.of(context).hermes.warning
          : widget.unconfirmed
          ? chrome.mutedInk
          : chrome.ink;
      final style = HermesType.caption.copyWith(
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        color: ink,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      final quiet = style.copyWith(color: chrome.mutedInk);
      final large =
          MediaQuery.textScalerOf(context).scale(HermesType.captionSize) >
          HermesType.captionSize * 1.5;
      Widget words(String value, {Key? key}) => ExcludeSemantics(
        child: Text(value, key: key, style: quiet),
      );
      final status = ExcludeSemantics(
        child: Text(
          text,
          key: const ValueKey('subagent-work-clock'),
          maxLines: large ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      );
      Widget actionButton(bool centered, {bool resume = false}) => TextButton(
        key: ValueKey(resume ? 'subagent-work-resume' : 'subagent-work-stop'),
        onPressed: resume ? widget.onResumeQueue : widget.onStop,
        style: TextButton.styleFrom(
          minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
          padding: const EdgeInsets.only(bottom: HermesSpace.x1),
          alignment: centered ? Alignment.center : Alignment.bottomCenter,
          foregroundColor: chrome.ink,
          textStyle: Theme.of(context).textTheme.labelLarge?.merge(style),
        ),
        child: Text(resume ? s.chaGoalActionResume : s.activityStop),
      );
      final details = <Widget>[
        if (widget.onStop != null) actionButton(large),
        if (hasCount && !widget.agentIcon) words('·'),
        if (hasCount)
          ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.agentIcon) ...[
                  Icon(
                    Icons.group_outlined,
                    size: HermesSpace.x3,
                    color: chrome.mutedInk,
                  ),
                  const SizedBox(width: HermesSpace.x1),
                ],
                Text(
                  '${count.finished}/${count.total}',
                  key: const ValueKey('subagent-work-count'),
                  style: quiet,
                ),
              ],
            ),
          ),
        if (widget.processCount > 0 && !processLabel)
          words(
            s.activityProcessCount(widget.processCount),
            key: const ValueKey('subagent-work-processes'),
          ),
        if (widget.queuedCount > 0 && !queueOnly)
          words(
            s.queuePillCount(widget.queuedCount),
            key: const ValueKey('subagent-work-queue'),
          ),
        if (widget.queuedCount > 0 && widget.queuePaused) ...[
          words(s.queuePillPaused),
          if (widget.onResumeQueue != null) actionButton(large, resume: true),
        ],
      ];
      final spoken = [
        if (!queueOnly) label,
        if (widget.queuedCount > 0) s.queuePillCount(widget.queuedCount),
        if (widget.queuedCount > 0 && widget.queuePaused) s.queuePillPaused,
        if (hasCount) s.subFTitle(count.finished, count.total),
        if (widget.processCount > 0 && !processLabel)
          s.activityProcessCount(widget.processCount),
      ].join(' · ');
      final main = Material(
        key: widget.queuedCount > 0
            ? const ValueKey('chat-queue-toggle')
            : null,
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('subagent-work-hit-target'),
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: HermesSpace.tap,
              minWidth: HermesSpace.tap,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                double widthOf(String text) {
                  final painter = TextPainter(
                    text: TextSpan(
                      text: text,
                      style: DefaultTextStyle.of(context).style.merge(quiet),
                    ),
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                    maxLines: 1,
                  )..layout();
                  final width = painter.width;
                  painter.dispose();
                  return width;
                }

                // Only stack when the fixed controls themselves cannot fit.
                // The normal line stays 28 dp; narrow/large-type panes wrap
                // rather than clipping Stop or shrinking its 48 dp target.
                final fixed = large || constraints.maxWidth >= 400
                    ? 0.0
                    : HermesSpace.x2 * 2 +
                          details.length * HermesSpace.x1 +
                          (widget.onStop != null
                              ? widthOf(
                                  s.activityStop,
                                ).clamp(HermesSpace.tap, double.infinity)
                              : 0) +
                          (hasCount
                              ? widthOf('${count.finished}/${count.total}') +
                                    (widget.agentIcon
                                        ? HermesSpace.x4
                                        : widthOf('·') + HermesSpace.x1)
                              : 0) +
                          (widget.processCount > 0 && !processLabel
                              ? widthOf(
                                  s.activityProcessCount(widget.processCount),
                                )
                              : 0) +
                          (widget.queuedCount > 0 && !queueOnly
                              ? widthOf(s.queuePillCount(widget.queuedCount))
                              : 0) +
                          (widget.queuedCount > 0 && widget.queuePaused
                              ? widthOf(s.queuePillPaused) +
                                    (widget.onResumeQueue != null
                                        ? widthOf(s.chaGoalActionResume).clamp(
                                            HermesSpace.tap,
                                            double.infinity,
                                          )
                                        : 0)
                              : 0);
                final stacked = large || fixed > constraints.maxWidth;
                return Stack(
                  children: [
                    Positioned.fill(
                      top: stacked ? 0 : HermesSpace.x5,
                      child: Material(
                        key: const ValueKey('subagent-work-pill'),
                        color: chrome.opaque,
                        shape: const StadiumBorder(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HermesSpace.x2,
                      ),
                      child: stacked
                          ? Padding(
                              padding: const EdgeInsets.all(HermesSpace.x1),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  status,
                                  if (details.isNotEmpty)
                                    Wrap(
                                      spacing: HermesSpace.x1,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        for (final detail in details)
                                          detail is TextButton
                                              ? actionButton(
                                                  true,
                                                  resume:
                                                      detail.key ==
                                                      const ValueKey(
                                                        'subagent-work-resume',
                                                      ),
                                                )
                                              : detail,
                                      ],
                                    ),
                                ],
                              ),
                            )
                          : ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: HermesSpace.tap,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                // Words only: no dot before the state.
                                children: [
                                  Flexible(
                                    child: Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: HermesSpace.x1,
                                      ),
                                      child: status,
                                    ),
                                  ),
                                  for (final detail in details) ...[
                                    const SizedBox(width: HermesSpace.x1),
                                    if (detail is TextButton)
                                      detail
                                    else
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: HermesSpace.x1,
                                        ),
                                        child: detail,
                                      ),
                                  ],
                                ],
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      return Align(
        alignment: Alignment.center,
        heightFactor: 1,
        child: Semantics(
          key: const ValueKey('subagent-work-status'),
          container: true,
          explicitChildNodes: true,
          liveRegion: widget.working,
          button: widget.onTap != null,
          onTap: widget.onTap,
          label: spoken,
          child: KeyedSubtree(
            key: const ValueKey('activity-pill'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(child: main),
                if (widget.onTap != null) ...[
                  const SizedBox(width: HermesSpace.x1),
                  Semantics(
                    button: true,
                    label: s.activitySheetTitle,
                    onTap: widget.onTap,
                    excludeSemantics: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: const ValueKey('subagent-work-chevron'),
                        onTap: widget.onTap,
                        customBorder: const CircleBorder(),
                        child: const SizedBox(
                          width: HermesSpace.tap,
                          height: HermesSpace.tap,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: _ActivityChevron(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ActivityChevron extends StatelessWidget {
  const _ActivityChevron();
  @override
  Widget build(BuildContext context) => Material(
    color: HermesChrome.of(Theme.of(context).hermes).opaque,
    shape: const CircleBorder(),
    child: SizedBox.square(
      dimension: HermesSpace.x6,
      child: Icon(
        Icons.keyboard_arrow_down_rounded,
        size: HermesSpace.x4,
        color: HermesChrome.of(Theme.of(context).hermes).mutedInk,
      ),
    ),
  );
}
