import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../models/activity_snapshot.dart'
    show MemoryWrite, isSkillLoadTool, measuredActivityDuration;
import '../../models/tool_label.dart'
    show ToolRunCategory, toolRunCategory, toolStepTitle;
import '../../models/tool_name.dart' show canonicalToolName;
import '../../theme/hermes_tokens.dart';
import '../../theme/live_turn_tokens.dart';
import '../../theme/readable_ink.dart';
import '../activity_pill.dart' show ActivityTicker;
import '../chat_turn_activity.dart'
    show LiveTurnScope, TurnType, thinkingTime, turnToolIconFor;
import 'live_motion.dart';
import 'live_turn_window.dart'
    show LiveTurnBranch, LiveTurnRow, LiveTurnRowPill;
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
    this.progress,
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

  /// A running call's live progress (`42% · refining mesh`), said beside its
  /// timer as Desktop's `ToolRunningMeta` does.
  final String? progress;

  bool get isToolStep => kind == TurnStepCardKind.tool || toolName != null;
}

// ─────────────────────────────────────────────────────────────────────────────
// The opened list, organised: consecutive calls of one kind as one row
// ─────────────────────────────────────────────────────────────────────────────

/// What consecutive calls of the opened list have in common, so they fold
/// into one row. The families are Hermes Desktop's run categories
/// (`components/assistant-ui/tool/run-summary.ts` `TOOL_CATEGORY`), with a
/// skill load apart from a read of one of its resources, as Desktop words
/// them (`skill-activity.ts`). Desktop's «other» clause («Used 3 tools»)
/// would hide which tool it was, so [TurnFeedFamily.tool] keeps any other
/// tool apart by its registered name.
enum TurnFeedFamily {
  skill,
  skillResource,
  explore,
  search,
  read,
  browse,
  interact,
  analyze,
  run,
  tool,
}

/// The family of a call and, for [TurnFeedFamily.tool], its tool.
typedef TurnFeedKey = ({TurnFeedFamily family, String? tool});

/// Calls Desktop never folds into a run (`lib/tool-render-class.ts`
/// `isCardTool`): the tools that draw a card of their own and the file
/// edits, whose diff is the point of the turn.
const Set<String> _feedStandalone = {
  'clarify',
  'delegate_task',
  'image_generate',
  'manage_catalog',
  'manage_connections',
  'set_theme',
  'setup_beat',
  'edit_file',
  'patch',
  'write_file',
};

const Map<ToolRunCategory, TurnFeedFamily> _feedFamilies = {
  ToolRunCategory.explore: TurnFeedFamily.explore,
  ToolRunCategory.search: TurnFeedFamily.search,
  ToolRunCategory.read: TurnFeedFamily.read,
  ToolRunCategory.browse: TurnFeedFamily.browse,
  ToolRunCategory.interact: TurnFeedFamily.interact,
  ToolRunCategory.analyze: TurnFeedFamily.analyze,
  ToolRunCategory.run: TurnFeedFamily.run,
};

/// The key a call of the opened list folds by, or null when it always
/// stands on its own: a thought, an outcome, a card tool or file edit, a
/// connector call (Desktop's `toolGroupKey` makes it a card), and a call
/// that left something to show (an attachment, a memory write).
TurnFeedKey? turnFeedKey(TurnStepCardEntry entry) {
  if (entry.kind != TurnStepCardKind.tool) return null;
  if (entry.attachment != null || entry.memory != null) return null;
  final raw = entry.toolName;
  if (raw == null) return null;
  final name = canonicalToolName(raw);
  if (name.isEmpty ||
      _feedStandalone.contains(name) ||
      name.startsWith('connectors__')) {
    return null;
  }
  if (isSkillLoadTool(name)) {
    final resource = entry.detail?.contains(' → ') ?? false;
    return (
      family: resource ? TurnFeedFamily.skillResource : TurnFeedFamily.skill,
      tool: null,
    );
  }
  final family = _feedFamilies[toolRunCategory(name)];
  return family == null
      ? (family: TurnFeedFamily.tool, tool: name)
      : (family: family, tool: null);
}

/// The opened list in rows, in order: each run of consecutive calls with
/// the same [turnFeedKey] is one list, everything else a list of one. One
/// pass over the list already held. Whatever comes between two calls (a
/// thought, another kind of call, a card) ends the run, as a card or a
/// thought ends Desktop's (`fallback.tsx` `splitRunItems`); a call still
/// running stays in its run, as in Desktop's `ToolRun`.
List<List<TurnStepCardEntry>> turnFeedGroups(
  Iterable<TurnStepCardEntry> entries,
) {
  final groups = <List<TurnStepCardEntry>>[];
  TurnFeedKey? open;
  for (final entry in entries) {
    final key = turnFeedKey(entry);
    if (key != null && key == open) {
      groups.last.add(entry);
    } else {
      groups.add([entry]);
      open = key;
    }
  }
  return groups;
}

/// What a group of calls did, counted in Desktop's clause words
/// (`run-summary.ts` `CATEGORY_COPY`): «5 skills cargadas», «3 búsquedas»,
/// «2 comandos»; another tool by its title, «Omh Memory · 3 veces».
String turnFeedGroupLabel(Strings s, List<TurnStepCardEntry> group) =>
    turnFeedRunLabel(s, group.first, group.length);

/// [turnFeedGroupLabel] of a run known by its first call and its size (the
/// live window keeps no more of a run).
String turnFeedRunLabel(Strings s, TurnStepCardEntry first, int count) {
  final key = turnFeedKey(first);
  return switch (key?.family) {
    TurnFeedFamily.skill => s.turnFeedSkillsLoaded(count),
    TurnFeedFamily.skillResource => s.turnFeedSkillResourcesRead(count),
    TurnFeedFamily.explore => s.ctRunExplored(count),
    TurnFeedFamily.search => s.ctRunSearches(count),
    TurnFeedFamily.read => s.ctRunRead(count),
    TurnFeedFamily.browse => s.ctRunOpened(count),
    TurnFeedFamily.interact => s.ctRunBrowserActions(count),
    TurnFeedFamily.analyze => s.ctRunAnalyzed(count),
    TurnFeedFamily.run => s.ctRunCommands(count),
    TurnFeedFamily.tool || null => s.turnFeedRepeated(
      count,
      toolStepTitle(s, key?.tool ?? first.title, running: false),
    ),
  };
}

/// What the calls of a group acted on, each once, in order («a, b, c»);
/// null when none says.
String? turnFeedGroupDetail(List<TurnStepCardEntry> group) {
  final seen = <String>{};
  for (final entry in group) {
    final detail = entry.detail?.trim();
    if (detail != null && detail.isNotEmpty) seen.add(detail);
  }
  return seen.isEmpty ? null : seen.join(', ');
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
    // The pill's opened list is one column on one connector, thoughts and
    // outcomes included; elsewhere an outcome is a card of its own.
    final units = detailsOnly
        ? [if (entries.isNotEmpty) _Unit(_UnitKind.work, entries)]
        : _group(entries);
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
      HIcons.expand_more,
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
          ? HIcons.error_outline_rounded
          : entry.icon ?? HIcons.info_outline_rounded,
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

  bool _rowOpen(TurnStepCardEntry step) =>
      _rows[step.id] ?? step.initiallyOpen;

  /// Where a group's open state is remembered: by its first call, which a
  /// growing group keeps, across the pill closing and the turn settling.
  static String _groupMemory(TurnStepCardEntry first) =>
      'turn-feed-${first.id}';

  /// Desktop's `ToolRun`: open if the reader opened it, else if one of its
  /// calls is open (`persistedOpen ?? rowOpen`).
  bool _groupOpen(List<TurnStepCardEntry> group) => StepsBarMemory.isOpenOr(
    _groupMemory(group.first),
    fallback: group.any(_rowOpen),
  );

  void _toggleGroup(List<TurnStepCardEntry> group) {
    HermesHaptics.selection();
    final open = !_groupOpen(group);
    setState(() => StepsBarMemory.set(_groupMemory(group.first), open));
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
    VoidCallback? rowTap(TurnStepCardEntry step) =>
        !folded || step.opened == null ? null : () => _toggleRow(step);
    Widget single(TurnStepCardEntry step) {
      if (step.kind != TurnStepCardKind.thought) {
        return _LineStep(
          entry: step,
          seconds: seconds,
          compact: !folded,
          open: _rowOpen(step),
          onTap: rowTap(step),
        );
      }
      if (step.running) {
        return _ThoughtLine(
          key: ValueKey('turn-thought-${step.id}'),
          steps: [step],
        );
      }
      return _InnerThought(
        entry: step,
        open: _rowOpen(step),
        onTap: () => _toggleRow(step),
      );
    }

    // The pill's opened list folds each run of calls of one kind into one
    // row; elsewhere every step keeps its own.
    final units = widget.detailsOnly
        ? turnFeedGroups(visibleSteps)
        : visibleSteps.map((step) => [step]).toList();
    final rows = Column(
      key: const ValueKey('turn-line-group'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // A row is keyed by its first call: a call that a second one of its
        // kind turns into a group keeps its place and does not come in again.
        for (final unit in units)
          _Entrance(
            key: ValueKey('turn-row-${unit.first.id}'),
            animate: !_present.contains(unit.first.id) && !widget.reduceMotion,
            child: !widget.detailsOnly
                ? single(unit.single)
                : _FeedBranch(
                    steps: unit,
                    last: identical(unit, units.last),
                    open: unit.length > 1
                        ? _groupOpen(unit)
                        : _rowOpen(unit.single),
                    onToggle: unit.length > 1
                        ? () => _toggleGroup(unit)
                        : rowTap(unit.single),
                    rowOpen: _rowOpen,
                    rowTap: rowTap,
                    special: single,
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
              // The opened list hangs from the pill: its connector starts
              // right under it.
              padding: EdgeInsetsDirectional.only(
                top: widget.detailsOnly ? 0 : HermesSpace.x1,
              ),
              child: widget.detailsOnly
                  ? Align(
                      alignment: AlignmentDirectional.topStart,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: HermesLiveTurn.historyWidth,
                        ),
                        child: rows,
                      ),
                    )
                  : rows,
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

/// Of a row's width, the most its label takes before it is ellipsized; the
/// detail has the rest.
const double _labelShare = 0.6;

/// Of a row's width, the most its status, progress and time take.
const double _trailingShare = 0.45;

/// The grid every row of the opened list shares, Desktop's scaffold line
/// (`components/chat/disclosure-row.tsx`, `scaffold-row.tsx`): the glyph in
/// its fixed cell; the label; the detail in the secondary ink, taking all
/// the width left and ellipsized only at its end; the time in tabular
/// figures at the trailing edge; and the caret's column, which every row
/// keeps (empty when nothing opens), so the times of all rows line up. The
/// live window under the pill draws its rows on it too, without the caret's
/// column (nothing opens there).
class TurnStepGridLine extends StatelessWidget {
  const TurnStepGridLine({
    required this.mark,
    required this.label,
    required this.labelStyle,
    required this.openable,
    required this.open,
    this.labelKey,
    this.detail,
    this.detailKey,
    this.trailing,
    this.under,
    this.caretColumn = true,
    super.key,
  });

  final Widget mark;
  final String label;
  final TextStyle labelStyle;
  final Key? labelKey;
  final String? detail;
  final Key? detailKey;

  /// The status and the time, at the trailing edge.
  final Widget? trailing;

  /// The status and the time stacked under the label (large text).
  final Widget? under;
  final bool openable;
  final bool open;

  /// Keep the caret's column (the opened list) or end at the trailing slot.
  final bool caretColumn;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final text = Text(
      label,
      key: labelKey,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textWidthBasis: TextWidthBasis.longestLine,
      style: labelStyle,
    );
    final shown = detail?.trim() ?? '';
    final Widget words = shown.isEmpty
        // No detail, no gap: the label alone.
        ? Align(
            alignment: AlignmentDirectional.centerStart,
            heightFactor: 1,
            child: text,
          )
        : LayoutBuilder(
            builder: (context, box) => Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: box.maxWidth * _labelShare,
                  ),
                  child: text,
                ),
                const SizedBox(width: HermesSpace.x2),
                Expanded(
                  child: Text(
                    shown,
                    key: detailKey,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          );
    return LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          SizedBox(
            width: TurnStepCards.iconColumn,
            child: Center(child: mark),
          ),
          const SizedBox(width: HermesSpace.x2),
          Expanded(
            child: under == null
                ? words
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [words, under!],
                  ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: HermesSpace.x2),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: box.maxWidth * _trailingShare,
              ),
              child: trailing,
            ),
          ],
          if (caretColumn) ...[
            const SizedBox(width: HermesSpace.x1),
            SizedBox(
              width: TurnStepCards.iconColumn,
              child: openable
                  ? Center(
                      child: _Caret(
                        open: open,
                        reduceMotion: HermesMotion.reduced(context),
                      ),
                    )
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// The label's weight and ink: regular, or the quiet medium of the live
/// timeline's recent rows; only a call still running stands out.
TextStyle turnStepLabelStyle(
  HermesThemeColors colors, {
  required bool running,
  bool compact = false,
}) => TextStyle(
  fontSize: TurnType.row,
  height: 1.3,
  fontWeight: compact
      ? FontWeight.w500
      : running
      ? FontWeight.w600
      : FontWeight.w400,
  color: compact ? colors.textSecondary : colors.textPrimary,
);

/// The time of a row, in tabular figures.
TextStyle turnStepTimeStyle(HermesThemeColors colors) =>
    HermesType.support.copyWith(
      color: colors.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// One row of the pill's opened list, in the live turn's own look: each
/// step its own small outlined pill ([LiveTurnRowPill], the closed window's)
/// hanging from the connector down the side ([LiveTurnBranch]). A run of
/// consecutive calls of one kind is ONE pill, «Skill cargada ×5», with what
/// they acted on, their time together and the state ring of the run; a tap
/// shows its calls as pills of their own one level in, on a connector of
/// their own (Desktop folds a run under one line the same way, `fallback.tsx`
/// `ToolRun`). A thought or an outcome keeps its own look, on the same
/// connector.
class _FeedBranch extends StatelessWidget {
  const _FeedBranch({
    required this.steps,
    required this.last,
    required this.open,
    required this.onToggle,
    required this.rowOpen,
    required this.rowTap,
    required this.special,
  });

  final List<TurnStepCardEntry> steps;
  final bool last;
  final bool open;
  final VoidCallback? onToggle;
  final bool Function(TurnStepCardEntry step) rowOpen;
  final VoidCallback? Function(TurnStepCardEntry step) rowTap;

  /// A thought, as the list draws it everywhere.
  final Widget Function(TurnStepCardEntry step) special;

  @override
  Widget build(BuildContext context) {
    final first = steps.first;
    if (steps.length == 1) {
      if (first.kind == TurnStepCardKind.thought) {
        // A thought's line is a tap's height when it opens.
        final height = first.opened == null
            ? TurnStepCards.cardHeight
            : HermesSpace.tap;
        return LiveTurnBranch(
          history: true,
          last: last,
          elbow: height / 2,
          child: special(first),
        );
      }
      if (first.kind == TurnStepCardKind.outcome && first.toolName == null) {
        return LiveTurnBranch(
          history: true,
          last: last,
          elbow: TurnStepCards.cardHeight / 2,
          child: _StepCard(
            key: ValueKey('turn-step-card-${first.id}'),
            entry: first,
          ),
        );
      }
      return _FeedCall(entry: first, last: last, open: open, onTap: onToggle);
    }
    final s = Strings.of(context);
    final running = steps.where((step) => step.running).lastOrNull;
    final failed = steps.where((step) => step.failed).length;
    Duration? total;
    for (final step in steps) {
      final measured = measuredActivityDuration(step.duration);
      if (measured != null) total = (total ?? Duration.zero) + measured;
    }
    final row = LiveTurnRow(
      // Its own id: the group's pill and its first call's are both shown
      // once it is open.
      id: 'group-${first.id}',
      toolName: first.toolName,
      title: first.title,
      detail: turnFeedGroupDetail(steps),
      count: steps.length,
      running: running != null,
      failed: failed > 0,
      startedAt: running?.startedAt,
      clock: running?.clock ?? first.clock,
      duration: total,
    );
    final took = turnLineDuration(total);
    final spoken = [
      row.name,
      ?row.detail,
      if (running != null) s.stepsBarStatusRunning,
      if (failed > 0) s.turnLineFailed(failed),
      if (running == null) ?took,
    ].join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          key: ValueKey('turn-feed-group-${first.id}'),
          container: true,
          button: true,
          expanded: open,
          label: spoken,
          onTap: onToggle,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: LiveTurnBranch(
              history: true,
              paintKey: ValueKey('turn-feed-group-elbow-${first.id}'),
              last: last,
              child: LiveTurnRowPill(
                key: ValueKey('turn-feed-group-pill-${first.id}'),
                row: row,
                showTime: true,
                open: open,
              ),
            ),
          ),
        ),
        // What it unfolds, like a dropdown: one level in, the quieter
        // pills on a hairline connector, opening with a soft expand.
        _Unfold(
          child: !open
              ? null
              : LiveTurnBranch(
                history: true,
                  key: ValueKey('turn-feed-group-rows-${first.id}'),
                  tick: false,
                  last: last,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final step in steps)
                        _FeedCall(
                          key: ValueKey('turn-feed-row-${step.id}'),
                          entry: step,
                          last: identical(step, steps.last),
                          open: rowOpen(step),
                          onTap: rowTap(step),
                          quiet: true,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// What an opened row unfolds, as a soft expand downwards from the row
/// ([HermesMotion.base]); at once with reduced motion.
class _Unfold extends StatelessWidget {
  const _Unfold({required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final body = SizedBox(width: double.infinity, child: child);
    return HermesMotion.reduced(context)
        ? body
        : AnimatedSize(
            duration: HermesMotion.base,
            curve: HermesMotion.size,
            alignment: AlignmentDirectional.topStart,
            child: body,
          );
  }
}

/// One call of the opened list as its pill on the connector; what it left
/// to review opens under it, beside the connector going on.
class _FeedCall extends StatelessWidget {
  const _FeedCall({
    required this.entry,
    required this.last,
    required this.open,
    required this.onTap,
    this.quiet = false,
    super.key,
  });

  final TurnStepCardEntry entry;
  final bool last;
  final bool open;
  final VoidCallback? onTap;

  /// One of the calls an opened run unfolds ([LiveTurnRowPill.quiet]).
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final openable = onTap != null && entry.opened != null;
    final measured = entry.duration == null
        ? entry.durationText
        : turnLineDuration(entry.duration);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          key: ValueKey('turn-step-card-${entry.id}'),
          container: true,
          button: openable,
          expanded: openable ? open : null,
          label: [?measured, entry.semanticsLabel].join(', '),
          onTap: openable ? onTap : null,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: openable ? onTap : null,
            child: LiveTurnBranch(
              history: true,
              paintKey: ValueKey('turn-feed-elbow-${entry.id}'),
              last: last,
              quiet: quiet,
              child: LiveTurnRowPill(
                key: ValueKey('turn-feed-pill-${entry.id}'),
                row: LiveTurnRow.of(entry),
                showTime: true,
                open: openable ? open : null,
                quiet: quiet,
                progress: entry.running ? entry.progress : null,
                markKey: ValueKey('turn-step-mark-${entry.id}'),
              ),
            ),
          ),
        ),
        if (openable && open)
          LiveTurnBranch(
            history: true,
            tick: false,
            last: last,
            child: Padding(
              key: ValueKey('turn-step-opened-${entry.id}'),
              padding: const EdgeInsetsDirectional.only(
                start: HermesSpace.x3,
                top: HermesSpace.x1,
                bottom: HermesSpace.x1,
              ),
              child: entry.opened,
            ),
          ),
      ],
    );
  }
}

/// One step of the timeline on the shared grid ([TurnStepGridLine]): what it
/// was (its family's icon; the ring while it runs, the error sign if it
/// failed), the verb, the target and, at the trailing edge, how long it
/// took (or that it failed); tappable when it holds a detail, which opens
/// right under it.
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
    final timeStyle = turnStepTimeStyle(colors);
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
    final progress = entry.running ? entry.progress : null;
    // At larger accessibility scales, give the complete failure state and
    // time the target's full width rather than squeezing either into a flex.
    final stackStatus =
        entry.failed &&
        MediaQuery.textScalerOf(context).scale(HermesType.support.fontSize!) >
            HermesType.support.fontSize!;
    final statusAndTime = Wrap(
      spacing: HermesSpace.x1,
      // At the trailing edge, a part that does not fit goes under the
      // others, still against that edge.
      alignment: stackStatus ? WrapAlignment.start : WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (statusText != null) Text(statusText, style: timeStyle),
        if (progress != null)
          Text(
            progress,
            key: ValueKey('turn-step-progress-${entry.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: timeStyle,
          ),
        ?elapsed,
      ],
    );
    final hasTrailing =
        elapsed != null || statusText != null || progress != null;
    final row = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: onTap == null ? TurnStepCards.cardHeight : HermesSpace.tap,
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: TurnStepCards.contentInset,
          end: HermesSpace.x2,
        ),
        child: TurnStepGridLine(
          mark: LiveStepMark(
            key: ValueKey('turn-step-mark-${entry.id}'),
            state: mark,
            seconds: seconds,
            // What the step was, by its family (Desktop's tool icons).
            icon: turnToolIconFor(entry.toolName ?? ''),
          ),
          label: entry.title,
          labelKey: ValueKey('turn-step-label-${entry.id}'),
          labelStyle: turnStepLabelStyle(
            colors,
            running: entry.running,
            compact: compact,
          ),
          detail: entry.detail,
          detailKey: ValueKey('turn-step-detail-${entry.id}'),
          trailing: !stackStatus && hasTrailing ? statusAndTime : null,
          under: stackStatus ? statusAndTime : null,
          openable: onTap != null,
          open: open,
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
