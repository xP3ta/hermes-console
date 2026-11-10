import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../models/activity_snapshot.dart' show MemoryWrite, measuredActivityDuration;
import '../../theme/hermes_tokens.dart';
import '../../theme/readable_ink.dart';
import '../activity_pill.dart' show ActivityTicker;
import '../chat_turn_activity.dart' show LiveTurnScope, TurnType, thinkingTime;
import 'chat_live_icon.dart';
import 'live_motion.dart';
import 'tool_steps_summary.dart';
import 'turn_step_motion.dart';
import '../../feedback/haptics.dart';

/// What a step of the turn is, for its card.
enum TurnStepCardKind { thought, tool, outcome }

/// One step of the turn as a card (Q9-CHAT5 v2).
@immutable
final class TurnStepCardEntry {
  const TurnStepCardEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.semanticsLabel,
    this.detail,
    this.failed = false,
    this.icon,
    this.opened,
    this.attachment,
    this.initiallyOpen = false,
    this.toolName,
    this.running = false,
    this.durationText,
    this.duration,
    this.text,
    this.startedAt,
    this.clock,
    this.memory,
  });

  final String id;
  final TurnStepCardKind kind;

  /// Said first and in bold («Ejecutó», «Pensamiento», «Detenido»).
  final String title;

  /// The command or the target, in the code face.
  final String? detail;
  final bool failed;

  /// The glyph of an [TurnStepCardKind.outcome] card.
  final IconData? icon;

  /// What the card opens under itself (the tool's output, the thought).
  /// Null: nothing to open, and no chevron.
  final Widget? opened;

  /// What the step left that is always shown under its card (a generated
  /// image or file). A step that has one is never folded away.
  final Widget? attachment;

  /// Live reasoning follows the reader's existing disclosure preference.
  final bool initiallyOpen;

  /// The card's whole reading for a screen reader (state, detail, time).
  final String semanticsLabel;

  /// The tool's name as the gateway sent it. A step that has one (and every
  /// [TurnStepCardKind.tool]) belongs to the turn's summary bar; unknown names
  /// are counted as «otras».
  final String? toolName;

  /// The call has no result yet (a thought: it is still being written).
  final bool running;

  /// How long the step took, said short («0,8 s»), once it is over.
  final String? durationText;

  /// The same, as a value: a folded line adds up its thoughts' time.
  final Duration? duration;

  /// A thought still being written: its text so far. The folded row never
  /// shows it; it only tells the row there is something to open.
  final String? text;
  final DateTime? startedAt;
  final DateTime Function()? clock;

  /// What a memory tool's call/result says it wrote (null for other tools).
  final MemoryWrite? memory;

  bool get isToolStep => kind == TurnStepCardKind.tool || toolName != null;
}

/// What one slot of the turn is: everything already done as ONE folded line
/// (`work`, or its recent thoughts/actions while live), or an outcome card.
/// One persistent work slot prevents duplicate thoughts during handoffs.
enum _UnitKind { work, card }

class _Unit {
  _Unit(this.kind, this.steps);

  final _UnitKind kind;
  final List<TurnStepCardEntry> steps;
}

/// Recent actions are at most three quiet rows while the turn runs. Once
/// settled, the same block folds to a measured, descriptive summary. Safe
/// targets, status and per-step timings remain available on disclosure.
class TurnStepCards extends StatelessWidget {
  const TurnStepCards({
    required this.entries,
    this.animateInitial = false,
    this.live = false,
    this.detailsOnly = false,
    this.showAttachments = true,
    this.duration,
    super.key,
  });

  final List<TurnStepCardEntry> entries;
  final bool animateInitial;

  /// The turn is still running: show at most three recent actions.
  final bool live;
  final bool detailsOnly;
  final bool showAttachments;

  /// How long the turn worked, for the folded line.
  final Duration? duration;

  /// The folded line's own height: compact, never the roomy tap row.
  static const double lineHeight = 44;

  // Only the painted capsule gets slimmer; the transparent target stays 48 dp.
  static const double cardHeight = 32;
  static const double iconColumn = 24;
  // The 16 dp glyph is already 4 dp into its 24 dp column: six more
  // gives the approved 10 dp visible inset and a 38 dp text reference.
  static const double contentInset = 6;
  static const double textIndent = contentInset + iconColumn + HermesSpace.x2;
  static const double transcriptIndent = iconColumn + HermesSpace.x2;

  static List<_Unit> _group(List<TurnStepCardEntry> entries) {
    final work = <TurnStepCardEntry>[];
    final cards = <TurnStepCardEntry>[];
    for (final entry in entries) {
      final isThought = entry.kind == TurnStepCardKind.thought;
      if (!isThought && !entry.isToolStep) {
        cards.add(entry);
      } else {
        work.add(entry);
      }
    }
    return [
      if (work.isNotEmpty) _Unit(_UnitKind.work, work),
      for (final entry in cards) _Unit(_UnitKind.card, [entry]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final units = _group(entries);
    final reduceMotion = HermesMotion.reduced(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep four touch targets' width for an outcome card in narrow windows.
        final indent = constraints.hasBoundedWidth
            ? (constraints.maxWidth - HermesSpace.tap * 4).clamp(
                0.0,
                transcriptIndent,
              )
            : transcriptIndent;
        return TurnStepMotion(
          key: const ValueKey('turn-step-cards'),
          animateInitial: animateInitial,
          entries: [
            for (final unit in units)
              (
                id: switch (unit.kind) {
                  _UnitKind.work => ('line', unit.steps.first.id),
                  _UnitKind.card => ('step', unit.steps.first.id),
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    switch (unit.kind) {
                      _UnitKind.work =>
                        (detailsOnly ||
                                unit.steps.any((step) => step.isToolStep))
                            ? _TurnLine(
                                key: ValueKey(
                                  'turn-line-${unit.steps.first.id}',
                                ),
                                steps: unit.steps,
                                folded: !live,
                                detailsOnly: detailsOnly,
                                duration: live ? null : duration,
                                reduceMotion: reduceMotion,
                              )
                            : _ThoughtLine(
                                key: ValueKey(
                                  'turn-thought-${unit.steps.first.id}',
                                ),
                                steps: unit.steps,
                                duration: live ? null : duration,
                              ),
                      _UnitKind.card => Padding(
                        padding: EdgeInsetsDirectional.only(start: indent),
                        child: _StepCard(
                          key: ValueKey(
                            'turn-step-card-${unit.steps.first.id}',
                          ),
                          entry: unit.steps.first,
                        ),
                      ),
                    },
                    if (showAttachments)
                      for (final step in unit.steps) ?step.attachment,
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A row of the grid: icon column, text, chevron column at the right end.
class _GridRow extends StatelessWidget {
  const _GridRow({
    required this.icon,
    required this.text,
    required this.chevron,
  });

  final Widget icon;
  final Widget text;

  /// Null: no chevron (nothing to open), its column stays.
  final Widget? chevron;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: TurnStepCards.iconColumn,
        child: Center(child: icon),
      ),
      const SizedBox(width: HermesSpace.x2),
      Expanded(child: text),
      SizedBox(
        width: TurnStepCards.iconColumn,
        child: Center(child: chevron),
      ),
    ],
  );
}

/// One caret for every row (Desktop's DisclosureCaret): › closed, ⌄ open.
class _Caret extends StatelessWidget {
  const _Caret({required this.open, required this.reduceMotion});

  final bool open;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: open ? 0 : -0.25,
    duration: reduceMotion ? Duration.zero : HermesMotion.fast,
    child: Icon(
      Icons.expand_more,
      size: HermesIcon.sm,
      color: Theme.of(context).hermes.textSecondary,
    ),
  );
}

/// An outcome of the turn (stopped, failed, recovered): a card of its own that
/// says it in words and tint; there is nothing under it to open.
class _StepCard extends StatelessWidget {
  const _StepCard({required this.entry, super.key});

  final TurnStepCardEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final tint = entry.failed
        ? colors.error.withValues(alpha: 0.12)
        : chrome.fill;
    final edge = entry.failed
        ? colors.error.withValues(alpha: 0.28)
        : chrome.line;
    final glyph = Icon(
      entry.failed
          ? Icons.error_outline_rounded
          : entry.icon ?? Icons.info_outline_rounded,
      size: HermesIcon.sm,
      color: entry.failed ? colors.error : colors.textSecondary,
    );
    // The text keeps 4.5:1 on the card's tint (Ola 8).
    final muted = readableInkOnTint(colors.textSecondary, tint, colors);
    final card = Material(
      color: entry.failed ? tint : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.tag),
        side: BorderSide(
          color: entry.failed ? edge : Colors.transparent,
          width: entry.failed || MediaQuery.highContrastOf(context) ? 1 : 0.75,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: TurnStepCards.contentInset,
          end: HermesSpace.x2,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: TurnStepCards.cardHeight,
          ),
          child: _GridRow(
            icon: glyph,
            text: Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TurnType.row,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
            ),
            chevron: null,
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      label: entry.semanticsLabel,
      excludeSemantics: true,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: 1,
        child: IntrinsicWidth(child: card),
      ),
    );
  }
}

/// Only a press tints a row of the turn: no hover, focus or highlight fill
/// stays on it afterwards.
WidgetStateProperty<Color?> _pressOnly(BuildContext context) {
  final colors = Theme.of(context).hermes;
  return WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.pressed)
        ? colors.textSecondary.withValues(alpha: 0.12)
        : Colors.transparent,
  );
}

/// Tool steps as a vertical timeline. [folded]: everything the turn has done
/// so far (thoughts and tools in order) is ONE line, «Trabajó · Leyó 3 archivos ›» (the
/// quiet outline check, the outline error sign when a step failed), opened by a tap; open or
/// closed is remembered by [StepsBarMemory] under the first step's id (stable
/// for the life of the turn); each row keeps its own open state here. Not
/// [folded]: the steps in hand, open, no header, the one in hand turning.
class _TurnLine extends StatefulWidget {
  const _TurnLine({
    required this.steps,
    required this.folded,
    this.detailsOnly = false,
    required this.duration,
    required this.reduceMotion,
    super.key,
  });

  final List<TurnStepCardEntry> steps;
  final bool folded;
  final bool detailsOnly;
  final Duration? duration;
  final bool reduceMotion;

  @override
  State<_TurnLine> createState() => _TurnLineState();
}

class _TurnLineState extends State<_TurnLine>
    with SingleTickerProviderStateMixin, LiveClockMixin<_TurnLine> {
  // Closed unless the reader remembered it open.
  late bool _open = StepsBarMemory.isOpenOr(
    widget.steps.first.id,
    fallback: widget.steps.any((step) => step.initiallyOpen),
  );
  final Map<String, bool> _rows = {};

  /// The steps there from the first build: they do not come in again.
  late final Set<String> _present = {for (final step in widget.steps) step.id};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncLiveClock(active: _ticking);
  }

  @override
  void didUpdateWidget(_TurnLine old) {
    super.didUpdateWidget(old);
    if (!old.folded && widget.folded) {
      _open = StepsBarMemory.isOpen(widget.steps.first.id);
    }
    syncLiveClock(active: _ticking);
  }

  bool get _ticking =>
      !widget.folded && widget.steps.any((s) => s.isToolStep && s.running);

  @override
  void dispose() {
    disposeLiveClock();
    super.dispose();
  }

  void _toggle() {
    HermesHaptics.selection();
    setState(() => _open = !_open);
    StepsBarMemory.set(widget.steps.first.id, _open);
  }

  void _toggleRow(TurnStepCardEntry step) {
    HermesHaptics.selection();
    setState(() => _rows[step.id] = !(_rows[step.id] ?? step.initiallyOpen));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final steps = widget.steps;
    final folded = widget.folded;
    final failed = steps.any((step) => step.failed);
    final summary = turnLineSummary(s, [
      for (final step in steps)
        if (step.isToolStep)
          (
            tool: step.toolName,
            target: step.detail,
            failed: step.failed,
            duration: step.duration,
          ),
    ], duration: widget.duration);
    final label = summary.label;
    final ink = failed
        ? readableInkOnTint(colors.warning, colors.background, colors)
        : colors.textSecondary;
    final semanticsLabel = summary.semanticsLabel;
    final seconds = liveSeconds;
    final shown = widget.detailsOnly || !folded || _open;
    final visibleSteps = folded || widget.detailsOnly
        ? steps
        : steps.skip((steps.length - 3).clamp(0, steps.length));
    final rows = Column(
      key: const ValueKey('turn-line-group'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final step in visibleSteps)
          _Entrance(
            key: ValueKey('turn-row-${step.id}'),
            animate: !_present.contains(step.id) && !widget.reduceMotion,
            child: step.kind == TurnStepCardKind.thought
                ? step.running
                      ? _ThoughtLine(
                          key: ValueKey('turn-thought-${step.id}'),
                          steps: [step],
                        )
                      : _InnerThought(
                          entry: step,
                          open: _rows[step.id] ?? step.initiallyOpen,
                          onTap: () => _toggleRow(step),
                        )
                : _LineStep(
                    entry: step,
                    seconds: seconds,
                    compact: !folded,
                    open: _rows[step.id] ?? step.initiallyOpen,
                    onTap: !folded || step.opened == null
                        ? null
                        : () => _toggleRow(step),
                  ),
          ),
      ],
    );
    final header = widget.detailsOnly || !folded
        ? null
        : Semantics(
            container: true,
            button: true,
            expanded: _open,
            label: semanticsLabel,
            onTap: _toggle,
            onTapHint: _open ? s.stepsBarWorkedHide : s.stepsBarWorkedShow,
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(HermesRadius.control),
              overlayColor: _pressOnly(context),
              onTap: _toggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: TurnStepCards.lineHeight,
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: TurnStepCards.contentInset,
                    end: HermesSpace.x2,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: TurnStepCards.iconColumn,
                        child: Center(
                          child: LiveResultMark(
                            key: const ValueKey('turn-line-mark'),
                            ok: !failed,
                          ),
                        ),
                      ),
                      const SizedBox(width: HermesSpace.x2),
                      Expanded(
                        child: Text(
                          label,
                          key: const ValueKey('turn-line-label'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: TurnType.row,
                            height: 1.3,
                            fontWeight: FontWeight.w500,
                            color: ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: HermesSpace.x2),
                      _Caret(open: _open, reduceMotion: widget.reduceMotion),
                    ],
                  ),
                ),
              ),
            ),
          );
    final body = SizedBox(
      width: double.infinity,
      child: shown
          ? Padding(
              padding: const EdgeInsetsDirectional.only(top: HermesSpace.x1),
              child: rows,
            )
          : null,
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [?header, body],
    );
    return widget.reduceMotion
        ? content
        : AnimatedSize(
            duration: HermesMotion.base,
            curve: HermesMotion.size,
            alignment: AlignmentDirectional.topStart,
            child: content,
          );
  }
}

/// A thought inside the opened line: «Pensó 3 s ›», brain still and dim; a
/// tap opens what it thought right under it.
class _InnerThought extends StatelessWidget {
  const _InnerThought({
    required this.entry,
    required this.open,
    required this.onTap,
  });

  final TurnStepCardEntry entry;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final label = _thoughtLabel(s, [entry]);
    final openable = entry.opened != null;
    final row = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: openable ? HermesSpace.tap : TurnStepCards.cardHeight,
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: TurnStepCards.contentInset,
          end: HermesSpace.x2,
        ),
        child: Row(
          children: [
            SizedBox(
              width: TurnStepCards.iconColumn,
              child: Center(child: const LiveBrain(seconds: null, quiet: true)),
            ),
            const SizedBox(width: HermesSpace.x2),
            Expanded(
              child: Text(
                label,
                key: ValueKey('turn-inner-thought-label-${entry.id}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: TurnType.row,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  color: colors.textSecondary,
                ),
              ),
            ),
            if (openable) ...[
              const SizedBox(width: HermesSpace.x2),
              _Caret(open: open, reduceMotion: HermesMotion.reduced(context)),
            ],
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          key: ValueKey('turn-inner-thought-${entry.id}'),
          container: true,
          button: openable,
          expanded: openable ? open : null,
          label: label,
          onTap: openable ? onTap : null,
          excludeSemantics: true,
          child: InkWell(
            overlayColor: _pressOnly(context),
            onTap: openable ? onTap : null,
            child: row,
          ),
        ),
        if (open && openable)
          Padding(
            key: ValueKey('turn-step-opened-${entry.id}'),
            padding: const EdgeInsetsDirectional.only(
              start: TurnStepCards.textIndent,
              end: HermesSpace.x2,
              bottom: HermesSpace.x1,
            ),
            child: entry.opened,
          ),
      ],
    );
  }
}

/// «Pensó 3 s», «Pensó 3 veces» or plain «Pensó»: what a thought line says
/// once it is over. The time is the sum of what is known.
String _thoughtLabel(Strings s, List<TurnStepCardEntry> steps) {
  var total = Duration.zero;
  var known = false;
  for (final step in steps) {
    final value = measuredActivityDuration(step.duration);
    if (value != null && value >= const Duration(seconds: 1)) {
      total += value;
      known = true;
    }
  }
  if (known) return s.livePThought(thinkingTime(s, total));
  if (steps.length > 1) return s.turnFlowThoughtCount(steps.length);
  final only = steps.first;
  if (only.durationText != null) return s.livePThought(only.durationText!);
  return only.title;
}

/// A block that slides up a little while it fades in; a still one is just
/// there. Only rows that come in after the first build use it. The slide is
/// clipped to the row's own box: rows that come in a frame apart are at
/// different points of it, and an unclipped one painted over its neighbour.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.animate, required this.child, super.key});

  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!animate) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: HermesMotion.enter,
      curve: HermesMotion.emphasized,
      child: child,
      builder: (context, t, child) => ClipRect(
        child: Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, HermesSpace.x2 * (1 - t)),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// One thought, on ONE line of the same height and style as «Trabajó · N
/// pasos ›»: the brain and a noun for what it holds («Pensamiento ›», never a
/// second «Pensando» beside the header's own), closed, and a tap opens the
/// thought in the chat's reading size; once over it is «Pensó 2 s ›» with the
/// brain still. No fragment of the text shows while it is folded.
class _ThoughtLine extends StatefulWidget {
  const _ThoughtLine({required this.steps, this.duration, super.key});

  final Duration? duration;

  /// The consecutive thoughts of the line; the last may still be written.
  final List<TurnStepCardEntry> steps;

  @override
  State<_ThoughtLine> createState() => _ThoughtLineState();
}

class _ThoughtLineState extends State<_ThoughtLine>
    with SingleTickerProviderStateMixin, LiveClockMixin<_ThoughtLine> {
  // What the reader chose, else the reasoning setting: a thought is not a
  // row of the tool timeline, so [StepsBarMemory.openByDefault] (the rows'
  // test switch) does not open it.
  // A thought being written starts folded whatever the setting says: the
  // header's pill already tells it is thinking.
  late bool _open =
      StepsBarMemory.recorded(widget.steps.first.id) ??
      (!widget.steps.last.running &&
          widget.steps.any((step) => step.initiallyOpen));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncLiveClock(active: widget.steps.last.running);
  }

  @override
  void didUpdateWidget(_ThoughtLine old) {
    super.didUpdateWidget(old);
    syncLiveClock(active: widget.steps.last.running);
  }

  @override
  void dispose() {
    disposeLiveClock();
    super.dispose();
  }

  void _toggle() {
    HermesHaptics.selection();
    setState(() => _open = !_open);
    StepsBarMemory.set(widget.steps.first.id, _open);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final steps = widget.steps;
    final entry = steps.last;
    final running = entry.running;
    final seconds = liveSeconds;
    final reduceMotion = HermesMotion.reduced(context);
    final opened = [
      for (final step in steps)
        if (step.opened != null) step.opened!,
    ];
    final openable = opened.isNotEmpty;
    final measured = measuredActivityDuration(widget.duration);
    final thoughtTime =
        measured ??
        steps.fold<Duration?>(null, (total, step) {
          final value = measuredActivityDuration(step.duration);
          return value == null ? total : (total ?? Duration.zero) + value;
        });
    final settledLabel = thoughtTime == null
        ? _thoughtLabel(s, steps)
        : turnLineSummary(s, const [], duration: thoughtTime).label;
    // The header's pill says «Pensando» while the turn thinks: the row says
    // what it holds, in the folded line's own ink and weight.
    final liveLabel = s.litThoughtRow;
    final style = TextStyle(
      fontSize: TurnType.row,
      height: 1.3,
      fontWeight: FontWeight.w500,
      color: colors.textSecondary,
    );
    final word = running
        ? LiveSheen(
            key: const ValueKey('turn-thought-sheen'),
            seconds: seconds,
            base: colors.textSecondary,
            peak: colors.textPrimary,
            child: Text(
              liveLabel,
              key: const ValueKey('turn-thought-label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          )
        : Text(
            settledLabel,
            key: const ValueKey('turn-thought-label'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
    final onTap = openable ? _toggle : null;
    final head = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: onTap == null
            ? TurnStepCards.cardHeight
            : TurnStepCards.lineHeight,
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: TurnStepCards.contentInset,
          end: HermesSpace.x2,
        ),
        child: Row(
          children: [
            SizedBox(
              width: TurnStepCards.iconColumn,
              child: Center(
                child: LiveBrain(
                  key: const ValueKey('turn-thought-brain'),
                  seconds: seconds,
                  quiet: !running,
                ),
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            Expanded(child: word),
            if (onTap != null) ...[
              const SizedBox(width: HermesSpace.x2),
              _Caret(open: _open, reduceMotion: reduceMotion),
            ],
          ],
        ),
      ),
    );
    // Folded, nothing of the text shows, written or not; opened it is the
    // thought itself.
    final Widget? below = _open && openable
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: opened)
        : null;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          key: ValueKey('turn-thought-card-${steps.first.id}'),
          container: true,
          button: onTap != null,
          expanded: onTap == null ? null : _open,
          label: running ? liveLabel : settledLabel,
          onTap: onTap,
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(HermesRadius.control),
            overlayColor: _pressOnly(context),
            onTap: onTap,
            child: head,
          ),
        ),
        if (below != null)
          Padding(
            key: ValueKey('turn-step-opened-${steps.first.id}'),
            padding: const EdgeInsetsDirectional.only(
              start: TurnStepCards.textIndent,
              end: HermesSpace.x2,
              bottom: HermesSpace.x1,
            ),
            child: below,
          ),
      ],
    );
    return reduceMotion
        ? column
        : AnimatedSize(
            duration: HermesMotion.base,
            curve: HermesMotion.emphasized,
            alignment: AlignmentDirectional.topStart,
            child: column,
          );
  }
}

/// One step of the timeline: its mark, the verb in bold, a small chip with
/// the target, and at the right how long it took (or that it failed); tappable
/// when it holds a detail, which opens right under it.
class _LineStep extends StatelessWidget {
  const _LineStep({
    required this.entry,
    required this.open,
    required this.onTap,
    required this.seconds,
    this.compact = false,
  });

  final TurnStepCardEntry entry;
  final bool open;
  final VoidCallback? onTap;
  final Animation<double>? seconds;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final status = stepsBarStatus(
      anyRunning: entry.running,
      anyFailed: entry.failed,
    );
    final mark = switch (status) {
      StepsBarStatus.running => LiveMarkState.running,
      StepsBarStatus.failed => LiveMarkState.failed,
      StepsBarStatus.done => LiveMarkState.ok,
    };
    final measured = entry.duration == null
        ? entry.durationText
        : turnLineDuration(entry.duration);
    final statusText = entry.failed
        ? Strings.of(context).stepsBarStatusFailed
        : null;
    final timeStyle = HermesType.support.copyWith(
      color: colors.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget time(String value) => Text(value, style: timeStyle);
    final started = entry.startedAt;
    final Widget? elapsed = entry.running && started != null
        ? ActivityTicker(
            active: true,
            clock: entry.clock ?? LiveTurnScope.maybeOf(context)?.clock,
            builder: (context, now) {
              final value = turnLineDuration(now.difference(started));
              return value == null ? const SizedBox.shrink() : time(value);
            },
          )
        : measured == null
        ? null
        : time(statusText == null ? measured : '· $measured');
    final statusAndTime = Wrap(
      spacing: HermesSpace.x1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (statusText != null) Text(statusText, style: timeStyle),
        ?elapsed,
      ],
    );
    // At larger accessibility scales, give the complete failure state and
    // time the target's full width rather than squeezing either into a flex.
    final stackStatus =
        entry.failed &&
        MediaQuery.textScalerOf(context).scale(HermesType.support.fontSize!) >
            HermesType.support.fontSize!;
    Widget withStatus(Widget target) => stackStatus
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [target, statusAndTime],
          )
        : target;
    final detail = entry.detail;
    final row = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: onTap == null ? TurnStepCards.cardHeight : HermesSpace.tap,
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: TurnStepCards.contentInset,
          end: HermesSpace.x2,
        ),
        child: Row(
          children: [
            SizedBox(
              width: TurnStepCards.iconColumn,
              child: Center(
                child: LiveStepMark(
                  key: ValueKey('turn-step-mark-${entry.id}'),
                  state: mark,
                  seconds: seconds,
                  // What the step was, in the chat's icon family: the same
                  // terminal / wrench the live row and its pills show.
                  glyph: chatLiveGlyphForTool(entry.toolName),
                ),
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            Expanded(
              flex: 4,
              child: withStatus(
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: TurnType.row,
                          height: 1.3,
                          fontWeight: compact
                              ? FontWeight.w500
                              : FontWeight.w700,
                          color: compact
                              ? colors.textSecondary
                              : colors.textPrimary,
                        ),
                      ),
                    ),
                    if (detail != null && detail.isNotEmpty) ...[
                      const SizedBox(width: HermesSpace.x2),
                      Flexible(
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HermesType.support.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (!stackStatus && (elapsed != null || statusText != null)) ...[
              const SizedBox(width: HermesSpace.x2),
              Flexible(flex: 4, child: statusAndTime),
            ],
            if (onTap != null) ...[
              const SizedBox(width: HermesSpace.x2),
              _Caret(open: open, reduceMotion: HermesMotion.reduced(context)),
            ],
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          key: ValueKey('turn-step-card-${entry.id}'),
          container: true,
          button: onTap != null,
          expanded: onTap == null ? null : open,
          label: [?measured, entry.semanticsLabel].join(', '),
          onTap: onTap,
          excludeSemantics: true,
          child: InkWell(onTap: onTap, child: row),
        ),
        if (open && entry.opened != null)
          Padding(
            key: ValueKey('turn-step-opened-${entry.id}'),
            padding: const EdgeInsetsDirectional.only(
              start: TurnStepCards.textIndent,
              end: HermesSpace.x2,
              bottom: HermesSpace.x1,
            ),
            child: entry.opened,
          ),
      ],
    );
  }
}
