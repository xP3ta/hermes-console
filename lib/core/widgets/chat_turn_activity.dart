import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;

import '../../l10n/app_localizations.dart';
import '../models/activity_snapshot.dart';
import '../models/agent_task_list.dart';
import '../models/subagent_activity.dart';
import '../models/tool_label.dart';
import '../models/tool_name.dart';
import '../services/reasoning_disclosure_prefs.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../theme/readable_ink.dart';
import '../utils/plain_preview.dart';
import '../utils/reasoning_plain.dart' show structureReasoning;
import 'activity_pill.dart';
import 'chat/chat_markdown_body.dart' show chatCodeTextStyle;
import 'chat/live_turn_window.dart' show LiveRingCheck, LiveSpinnerRing;
import 'chat/turn_step_motion.dart' show TurnStepMotion;
import 'compact_markdown.dart';
import '../theme/live_turn_tokens.dart';
import 'thinking_glyph.dart';
import '../feedback/haptics.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ct1215 · The turn inside the transcript («C1 — como Desktop»)
//
// What Hermes is doing is told where the reply will be, under its name, in
// loose lines: one status line, the thinking as a quoted block, the tool in
// hand, the task list. When the turn ends they fold into at most two quiet
// lines the reader can open. No card, no bubble.
// ─────────────────────────────────────────────────────────────────────────────

/// Type sizes of the turn's lines: readable next to a 15 pt reply, never the
/// header pill's.
abstract final class TurnType {
  static const double status = 13;
  static const double row = 13.5;

  /// A thought: small, quiet and italic, a notch under the chat's reading
  /// size (9 nov 2026, on the approved live look; Desktop's
  /// `message-parts.tsx:326,346` sets the body at the tool font size, 11-12 px,
  /// tertiary ink). It replaces the 15 sp of APK 9801.
  static const double reasoning = HermesType.supportSize;
  static const double fold = 13;
}

/// What the live turn is doing, in the terms of the status line. Compared by
/// value, so the line only rebuilds when what it says changes: a reasoning
/// delta does not touch it.
@immutable
final class LiveTurnStatus {
  const LiveTurnStatus({
    this.active = false,
    this.startedAt,
    this.headline,
    this.waitingForUser = false,
    this.noActivityHint = false,
    this.step,
    this.tasks,
    this.delegatedCount = 0,
    this.subagents = const [],
  });

  static const LiveTurnStatus idle = LiveTurnStatus();

  /// The same snapshot the header pill is painted from.
  factory LiveTurnStatus.of(ActivitySnapshot snapshot) {
    if (!snapshot.turnActive) return idle;
    final current = snapshot.current;
    return LiveTurnStatus(
      active: true,
      delegatedCount: !snapshot.subagentsStale && snapshot.subagentsRunning
          ? snapshot.subagentCount
          : 0,
      startedAt: snapshot.turnStartedAt,
      headline: snapshot.headline,
      waitingForUser: snapshot.waitingForUser,
      noActivityHint: snapshot.noActivityHint,
      step: current != null && current.kind != ActivityStepKind.reasoning
          ? current
          : null,
      tasks: snapshot.showTasks ? snapshot.tasks : null,
      // Design B: one card per delegated child in the live turn. Stale or
      // unconfirmed rosters draw none (they never claim progress).
      subagents: snapshot.subagentsStale ? const [] : snapshot.subagents,
    );
  }

  final bool active;
  final DateTime? startedAt;

  /// Pipeline line when no tool runs («Pensando…», «Respondiendo…», a
  /// provider wait).
  final String? headline;
  final bool waitingForUser;
  final bool noActivityHint;

  /// The tool or skill in hand.
  final ActivityStep? step;

  /// The plan in flight, when there is one.
  final AgentTaskList? tasks;
  final int delegatedCount;

  /// The delegated children of the live turn, for their cards in the chat.
  final List<SubagentActivity> subagents;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveTurnStatus &&
          active == other.active &&
          delegatedCount == other.delegatedCount &&
          startedAt == other.startedAt &&
          headline == other.headline &&
          waitingForUser == other.waitingForUser &&
          noActivityHint == other.noActivityHint &&
          step?.id == other.step?.id &&
          step?.label == other.step?.label &&
          step?.kind == other.step?.kind &&
          step?.title == other.step?.title &&
          _sameSubagents(subagents, other.subagents) &&
          _sameTasks(tasks, other.tasks);

  @override
  int get hashCode => Object.hash(
    active,
    delegatedCount,
    startedAt,
    headline,
    waitingForUser,
    noActivityHint,
    step?.id,
    step?.label,
    tasks?.revision,
    tasks?.done,
    tasks?.total,
    subagents.length,
  );

  static bool _sameSubagents(List<SubagentActivity> a, List<SubagentActivity> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.key != y.key ||
          x.phase != y.phase ||
          x.details.activeToolName != y.details.activeToolName ||
          x.details.activeToolPreview != y.details.activeToolPreview ||
          x.details.summaryPreview != y.details.summaryPreview ||
          x.details.detailPreview != y.details.detailPreview ||
          x.details.goalPreview != y.details.goalPreview ||
          x.details.startedAt != y.details.startedAt ||
          x.details.durationSeconds != y.details.durationSeconds ||
          x.progress?.displayFraction != y.progress?.displayFraction) {
        return false;
      }
    }
    return true;
  }

  static bool _sameTasks(AgentTaskList? a, AgentTaskList? b) =>
      identical(a, b) || (a != null && b != null && a.sameContentAs(b));
}

/// Hands the live turn's state to the transcript rows that paint it, without
/// threading it through every message wrapper.
class LiveTurnScope extends InheritedWidget {
  const LiveTurnScope({
    required this.status,
    required this.clock,
    this.compactSteps = false,
    this.inlineActivity = false,
    this.approvalTool,
    this.approvalChoice,
    required super.child,
    super.key,
  });

  final LiveTurnStatus status;
  final bool compactSteps;
  final bool inlineActivity;
  final String? approvalTool;
  final String? approvalChoice;

  /// The clock the chat measures the turn with.
  final DateTime Function() clock;

  static LiveTurnScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiveTurnScope>();

  @override
  bool updateShouldNotify(LiveTurnScope oldWidget) =>
      oldWidget.status != status ||
      oldWidget.compactSteps != compactSteps ||
      oldWidget.inlineActivity != inlineActivity ||
      oldWidget.approvalTool != approvalTool ||
      oldWidget.approvalChoice != approvalChoice;
}

/// The plan in flight of the live turn, for a turn that has nothing else to
/// show yet.
class LiveTurnTasks extends StatelessWidget {
  const LiveTurnTasks({super.key});

  @override
  Widget build(BuildContext context) {
    final tasks = LiveTurnScope.maybeOf(context)?.status.tasks;
    return tasks == null || tasks.isEmpty
        ? const SizedBox.shrink()
        : TurnTasksLive(tasks: tasks);
  }
}

String _trimStatus(String value) {
  var clean = value.trim();
  while (clean.endsWith('.') || clean.endsWith('…')) {
    clean = clean.substring(0, clean.length - 1).trimRight();
  }
  return clean.isEmpty ? value.trim() : clean;
}

/// The words of the status line: the state, and the step in hand when a tool
/// or a skill runs.
({String state, String? step}) turnStatusWords(
  Strings s,
  LiveTurnStatus status, {
  String? fallbackState,
}) {
  if (status.noActivityHint) return (state: s.chaTurnStillWorking, step: null);
  if (status.waitingForUser) return (state: s.liveWaitingForUser, step: null);
  final step = status.step;
  if (step != null) {
    return (
      state: _trimStatus(s.liveHeaderWorking),
      step: step.kind == ActivityStepKind.skill
          ? step.label
          : toolOrSkillStepTitle(
              s,
              step.label,
              running: true,
              gatewayTitle: step.title,
            ),
    );
  }
  return (
    state: _trimStatus(
      status.headline ?? fallbackState ?? s.chaPipelineThinking,
    ),
    step: null,
  );
}

/// Whether the status line would only say «Pensando»: no tool in hand, no
/// wait for the user, no «still working». A live thought's own line (mock
/// 137 A) already says it, with its time (QA 9709: both showed at once).
bool turnStatusOnlyThinking(
  Strings s,
  LiveTurnStatus status, {
  String? fallbackState,
}) {
  final words = turnStatusWords(s, status, fallbackState: fallbackState);
  return words.step == null &&
      words.state == _trimStatus(s.chaPipelineThinking);
}

/// «Trabajando · Ejecutando comando · 7s»: the one line that says the turn
/// is alive, what it is on and for how long. A polite live region: a screen
/// reader hears the state change, never the seconds.
class TurnStatusLine extends StatelessWidget {
  const TurnStatusLine({this.fallbackState, this.toolDetail, super.key});

  /// State word when no chat describes the turn (the card on its own).
  final String? fallbackState;

  /// Bounded display target while a remembered tool has no transcript row yet.
  final String? toolDetail;

  @override
  Widget build(BuildContext context) {
    final scope = LiveTurnScope.maybeOf(context);
    final status = scope?.status ?? LiveTurnStatus.idle;
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final words = turnStatusWords(s, status, fallbackState: fallbackState);
    final detail = toolDetail?.trim();
    final step = words.step == null
        ? null
        : [
            words.step!,
            if (detail != null && detail.isNotEmpty) detail,
          ].join(' · ');
    final startedAt = status.active ? status.startedAt : null;
    final waiting = status.waitingForUser && !status.noActivityHint;
    final base = TextStyle(
      fontSize: TurnType.status,
      height: 1.3,
      color: colors.textSecondary,
    );
    Widget line(DateTime? now) {
      final elapsed = startedAt == null || now == null
          ? null
          : now.difference(startedAt);
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: words.state,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: waiting ? colors.warning : colors.textPrimary,
              ),
            ),
            // No-break spaces: when the line wraps, a separator goes down
            // with what follows it and the timer with the last word; neither
            // is ever left alone on a line.
            if (step != null) TextSpan(text: ' ·\u00A0$step'),
            if (elapsed != null)
              TextSpan(
                text: '\u00A0·\u00A0${formatActivityElapsed(elapsed)}',
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
        key: const ValueKey('turn-status-text'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }

    return Semantics(
      key: const ValueKey('turn-status-line'),
      container: true,
      liveRegion: true,
      label: [words.state, ?step].join(', '),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 5, end: 7),
              child: TurnStatusPulse(
                color: waiting ? colors.warning : colors.accent,
              ),
            ),
            Expanded(
              child: startedAt == null
                  ? line(null)
                  : ActivityTicker(
                      active: true,
                      clock: scope?.clock,
                      builder: (context, now) => line(now),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One clock for every pulsing mark, as Hermes Desktop's `StatusPulse`
/// (`components/ui/status-pulse.tsx`): a 400 ms beat every 5 s, played by
/// all marks at once, and nothing drawn between beats. The first mark plays
/// at once and starts the clock; a later one waits for the next beat. The
/// clock stops with the last mark and while the app is in the background.
final class TurnPulseClock with WidgetsBindingObserver {
  TurnPulseClock._();

  static final TurnPulseClock instance = TurnPulseClock._();

  static const Duration beat = Duration(milliseconds: 400);
  static const Duration period = Duration(seconds: 5);

  final Map<Object, ({VoidCallback play, VoidCallback cancel})> _marks = {};
  Timer? _timer;
  bool _observing = false;
  AppLifecycleState? _lifecycle;

  bool get _paused =>
      _lifecycle != null && _lifecycle != AppLifecycleState.resumed;

  @visibleForTesting
  int get marks => _marks.length;

  @visibleForTesting
  bool get running => _timer != null;

  void subscribe(
    Object owner, {
    required VoidCallback play,
    required VoidCallback cancel,
  }) {
    _marks[owner] = (play: play, cancel: cancel);
    if (!_observing) {
      final binding = WidgetsBinding.instance;
      binding.addObserver(this);
      _observing = true;
      _lifecycle = binding.lifecycleState;
    }
    if (_timer == null && !_paused) {
      play();
      _timer = Timer(period, _beat);
    }
  }

  void unsubscribe(Object owner) {
    _marks.remove(owner);
    if (_marks.isNotEmpty) return;
    _timer?.cancel();
    _timer = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  void _beat() {
    _timer = null;
    if (_paused || _marks.isEmpty) return;
    for (final mark in _marks.values.toList()) {
      mark.play();
    }
    _timer = Timer(period, _beat);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _timer?.cancel();
    _timer = null;
    if (_paused) {
      // Hidden: stop a beat nobody sees.
      for (final mark in _marks.values.toList()) {
        mark.cancel();
      }
    } else {
      _beat();
    }
  }
}

/// The status line's square, beating with every other live mark on
/// [TurnPulseClock]. Still with reduced motion.
class TurnStatusPulse extends StatefulWidget {
  const TurnStatusPulse({required this.color, super.key});

  final Color color;

  @override
  State<TurnStatusPulse> createState() => _TurnStatusPulseState();
}

class _TurnStatusPulseState extends State<TurnStatusPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: TurnPulseClock.beat,
  );

  /// Desktop's keyframes: opacity 1, 0.5, 1, ease-in-out.
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: 0.5), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 0.5, end: 1), weight: 1),
  ]).animate(CurvedAnimation(parent: _beat, curve: Curves.easeInOut));

  bool _subscribed = false;

  void _play() {
    if (mounted) _beat.forward(from: 0);
  }

  void _cancel() {
    if (mounted) _beat.reset();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still && _subscribed) {
      TurnPulseClock.instance.unsubscribe(this);
      _subscribed = false;
      _beat.reset();
    } else if (!still && !_subscribed) {
      _subscribed = true;
      TurnPulseClock.instance.subscribe(this, play: _play, cancel: _cancel);
    }
  }

  @override
  void dispose() {
    if (_subscribed) TurnPulseClock.instance.unsubscribe(this);
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    key: const ValueKey('turn-status-pulse'),
    opacity: _opacity,
    child: _StatusMark(color: widget.color),
  );
}

/// A block of the turn comes in when it happens (mock 138 v2, «cada cosa
/// entra cuando ocurre»): from 10 dp below, fading in, 200 ms on the
/// emphasized curve (the mock's 220 ms on the motion token), transform and
/// opacity only, no blur. Hermes Desktop does the same with transform only
/// (`lib/use-enter-animation.ts`, 180 ms, 6 dp). It plays once per
/// [animationKey], only when [enabled] (a block that appears in a turn
/// already on screen), and never with reduced motion. A key seen once never
/// plays again, so a row scrolled out and back does not slide in twice.
class TurnEnter extends StatefulWidget {
  const TurnEnter({
    required this.animationKey,
    required this.enabled,
    required this.child,
    super.key,
  });

  final String animationKey;
  final bool enabled;
  final Widget child;

  static const Duration duration = HermesMotion.base;
  static const double offset = 10;
  static const Curve curve = HermesMotion.emphasized;

  /// The fade is done by 70 % of the slide, as in the mock's keyframes.
  static const Curve fade = Interval(0, 0.7, curve: Curves.easeOut);
  static const int _maxKeys = 2048;

  static final Set<String> _seen = {};
  static final List<String> _order = [];

  static void _remember(String key) {
    if (!_seen.add(key)) return;
    _order.add(key);
    if (_order.length > _maxKeys) _seen.remove(_order.removeAt(0));
  }

  @visibleForTesting
  static void debugForget() {
    _seen.clear();
    _order.clear();
  }

  @override
  State<TurnEnter> createState() => _TurnEnterState();
}

class _TurnEnterState extends State<TurnEnter>
    with SingleTickerProviderStateMixin {
  AnimationController? _slide;
  bool _decided = false;
  bool _in = false;

  /// Keeps the child's state when the slide's wrappers go away.
  final GlobalKey _child = GlobalKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final play =
        widget.enabled &&
        !still &&
        !TurnEnter._seen.contains(widget.animationKey);
    TurnEnter._remember(widget.animationKey);
    if (play) {
      _slide = AnimationController(vsync: this, duration: TurnEnter.duration)
        ..addStatusListener(_settled)
        ..forward();
    }
  }

  /// Once in, the block is drawn as if it had always been there: an
  /// Opacity left behind would keep a layer of its own.
  void _settled(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() => _in = true);
  }

  @override
  void dispose() {
    _slide?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _child, child: widget.child);
    final slide = _slide;
    if (slide == null || _in) return child;
    return AnimatedBuilder(
      animation: slide,
      child: child,
      builder: (context, child) => Transform.translate(
        key: const ValueKey('turn-enter-slide'),
        offset: Offset(
          0,
          TurnEnter.offset * (1 - TurnEnter.curve.transform(slide.value)),
        ),
        child: Opacity(
          key: const ValueKey('turn-enter-fade'),
          opacity: TurnEnter.fade.transform(slide.value),
          child: child,
        ),
      ),
    );
  }
}

/// The small square that opens the status line.
class _StatusMark extends StatelessWidget {
  const _StatusMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
    child: const SizedBox.square(dimension: 8),
  );
}

/// A thought that only grows, cut into blocks that never change again and
/// the one still being written.
///
/// A block ends at a blank line (outside a code fence, and not in the middle
/// of a list whose items are spaced out). A passage that goes on without one
/// is cut at a line or a sentence once it is longer than [sealAfter], so the
/// block still being written stays that small however long the thought gets.
/// Feeding it the text as it grows costs one prefix comparison and a scan of
/// the new lines: nothing already cut is read again.
final class ThoughtBlocks {
  /// An unbroken passage is cut once it is longer than this.
  static const int sealAfter = 1200;

  /// The finished blocks, oldest first. [tight] ones continue the passage
  /// of the next block: no paragraph gap after them.
  final List<({String text, bool tight})> sealed = [];

  String _text = '';

  /// Where the block being written starts.
  int _start = 0;

  /// Start of the first line that is not complete yet.
  int _line = 0;

  /// Start of the blank line that may end the block being written.
  int _blank = -1;
  bool _fence = false;
  bool _list = false;

  static final RegExp _fenceMark = RegExp(r'^ {0,3}(?:```|~~~)');
  static final RegExp _listMark = RegExp(r'^\s*(?:[-*+]|\d{1,3}[.)])\s');

  /// The block being written.
  String get open => _text.substring(_start).trimRight();

  /// Takes the thought as it is now. Returns true when it is not the text
  /// seen before with more at its end, and so was cut again from its start.
  bool update(String text) {
    final restarted = !text.startsWith(_text);
    if (restarted) {
      sealed.clear();
      _start = 0;
      _line = 0;
      _blank = -1;
      _fence = false;
      _list = false;
    }
    _text = text;
    while (true) {
      final end = text.indexOf('\n', _line);
      if (end < 0) break;
      _examine(_line, text.substring(_line, end));
      _line = end + 1;
    }
    // A paragraph is one long line: do not wait for its end to close the
    // block before it.
    if (_blank >= 0 && text.length - _line >= 8) {
      final head = text.substring(_line, _line + 8);
      if (head.trim().isNotEmpty) _afterBlank(_line, head);
    }
    _cutLongPassage();
    return restarted;
  }

  void _examine(int at, String line) {
    if (_fence) {
      if (_fenceMark.hasMatch(line)) _fence = false;
      return;
    }
    if (line.trim().isEmpty) {
      if (at <= _start || _text.substring(_start, at).trim().isEmpty) {
        if (at >= _start) _start = at + line.length + 1;
      } else if (_blank < 0) {
        _blank = at;
      }
      return;
    }
    if (_blank >= 0) _afterBlank(at, line);
    if (_fenceMark.hasMatch(line)) _fence = true;
    _list =
        _listMark.hasMatch(line) ||
        (_list && (line.startsWith('  ') || line.startsWith('\t')));
  }

  /// A blank line was followed by [line]: the block ends there unless a
  /// spaced-out list goes on.
  void _afterBlank(int at, String line) {
    final listGoesOn =
        _list &&
        (_listMark.hasMatch(line) ||
            line.startsWith('  ') ||
            line.startsWith('\t'));
    if (!listGoesOn) {
      sealed.add((
        text: _text.substring(_start, _blank).trimRight(),
        tight: false,
      ));
      _start = at;
      _list = false;
    }
    _blank = -1;
  }

  void _cutLongPassage() {
    while (!_fence && _blank < 0 && _text.length - _start > sealAfter) {
      final limit = _start + sealAfter;
      final floor = _start + sealAfter ~/ 2;
      var cut = _text.lastIndexOf('\n', limit - 1) + 1;
      if (cut <= floor) {
        cut = -1;
        for (final mark in const ['. ', '? ', '! ', '… ']) {
          final at = _text.lastIndexOf(mark, limit - mark.length);
          if (at >= floor && at + mark.length > cut) cut = at + mark.length;
        }
      }
      if (cut <= floor) cut = _text.lastIndexOf(' ', limit - 1) + 1;
      if (cut <= floor) cut = limit;
      sealed.add((text: _text.substring(_start, cut).trimRight(), tight: true));
      _start = cut;
    }
  }
}

/// The thought being written, whole: every finished block is built once and
/// kept, and only the block still growing is parsed and laid out again when
/// more of it arrives.
class _LiveThought extends StatefulWidget {
  const _LiveThought({required this.text});

  final String text;

  @override
  State<_LiveThought> createState() => _LiveThoughtState();
}

class _LiveThoughtState extends State<_LiveThought> {
  final ThoughtBlocks _blocks = ThoughtBlocks();

  /// One widget per finished block, the same instance on every build: a
  /// block that is done is never rebuilt, parsed or laid out again.
  final List<Widget> _sealed = [];

  @override
  Widget build(BuildContext context) {
    if (_blocks.update(widget.text)) _sealed.clear();
    for (var index = _sealed.length; index < _blocks.sealed.length; index++) {
      final block = _blocks.sealed[index];
      _sealed.add(
        Padding(
          key: ValueKey('turn-thought-block-$index'),
          // The gap a paragraph leaves inside one Markdown body.
          padding: EdgeInsets.only(bottom: block.tight ? 0 : 6),
          child: CompactMarkdown(
            data: block.text,
            fontSize: TurnType.reasoning,
            tone: CompactMarkdownTone.quiet,
          ),
        ),
      );
    }
    final open = _blocks.open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ..._sealed,
        if (open.isNotEmpty)
          CompactMarkdown(
            key: const ValueKey('turn-thought-open'),
            data: open,
            fontSize: TurnType.reasoning,
            tone: CompactMarkdownTone.quiet,
            streaming: true,
          ),
      ],
    );
  }
}

/// A long thought scrolls in its own box, [maxHeight] tall at most.
class _CappedThought extends StatefulWidget {
  const _CappedThought({
    required this.follow,
    required this.maxHeight,
    required this.child,
  });

  final bool follow; // streaming: keeps the end in view until scrolled up
  final double maxHeight;
  final Widget child;

  @override
  State<_CappedThought> createState() => _CappedThoughtState();
}

class _CappedThoughtState extends State<_CappedThought> {
  final ScrollController _scroll = ScrollController();
  bool _following = true;
  bool _overflows = false;
  bool _atTop = true;
  bool _atEnd = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification note) {
    if (note.depth == 0) {
      final atEnd = note.metrics.extentAfter < 1;
      if (note is ScrollUpdateNotification && note.dragDetails != null) {
        _following = atEnd;
      } else if (note is ScrollEndNotification && atEnd) {
        _following = true;
      }
      _sync(note.metrics);
    }
    return true; // the chat list never hears of this scroll
  }

  void _sync(ScrollMetrics m) {
    final overflows = m.maxScrollExtent > 0;
    final atTop = m.extentBefore < 1;
    final atEnd = m.extentAfter < 1;
    if (overflows == _overflows && atTop == _atTop && atEnd == _atEnd) return;
    void apply() => mounted
        ? setState(() {
            _overflows = overflows;
            _atTop = atTop;
            _atEnd = atEnd;
          })
        : null;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _afterLayout() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (widget.follow && _following && position.extentAfter >= 1) {
      position.jumpTo(position.maxScrollExtent);
    }
    _sync(position);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterLayout());
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        // Only the edge fades say there is more: no scrollbar thumb, which
        // drew a white bar inside the thought (audit 2.2, P1).
        child: EdgeFade(
          top: _overflows && !_atTop,
          bottom: _overflows && !_atEnd,
          child: SingleChildScrollView(
            controller: _scroll,
            physics: const ClampingScrollPhysics(),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// The model's thinking as a quoted block: a rule on the left, no surface,
/// at a size meant to be read. It is what a [ThinkingLine] opens.
///
/// [live] is the thought being written now: it is shown whole, from its
/// first word, and grows with it ([_LiveThought] keeps what each new word
/// costs small). Finished, it is the whole text in one piece.
///
/// [lines] caps it to that many lines in a box of its own (mock 137 A: 6),
/// which follows the newest words while [live] unless the reader scrolled
/// up; null shows the whole thought.
class TurnReasoningQuote extends StatelessWidget {
  const TurnReasoningQuote({
    required this.text,
    this.live = false,
    this.lines,
    super.key,
  });

  final String text;
  final bool live;
  final int? lines;

  /// Line height of the thought's text.
  static const double lineHeight = 1.45;

  /// The rule on the left of a quoted thought: a hairline now (9 nov
  /// 2026: «sin barra gruesa»; Desktop draws none, `message-parts.tsx:346`).
  static const double ruleWidth = 1;

  static Color ruleColor(HermesThemeColors colors) =>
      colors.textSecondary.withValues(alpha: 0.3);

  static bool _blank(String text) {
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (unit != 0x20 && unit != 0x0A && unit != 0x0D && unit != 0x09) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final Widget body;
    if (live) {
      // Stops at the first word: never a pass over the whole thought.
      if (_blank(text)) return const SizedBox.shrink();
      body = _LiveThought(text: structureReasoning(text));
    } else {
      final shown = text.trim();
      if (shown.isEmpty) return const SizedBox.shrink();
      body = CompactMarkdown(
        data: structureReasoning(shown),
        fontSize: TurnType.reasoning,
        tone: CompactMarkdownTone.quiet,
      );
    }
    return Semantics(
      container: true,
      label: Strings.of(context).rt1215Thinking,
      child: Padding(
        key: const ValueKey('turn-reasoning'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(color: ruleColor(colors), width: ruleWidth),
            ),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12),
            child: SizedBox(
              width: double.infinity,
              child: switch (lines) {
                final int lines => _CappedThought(
                  follow: live,
                  maxHeight:
                      MediaQuery.textScalerOf(context)
                          .scale(TurnType.reasoning) *
                      lineHeight *
                      lines,
                  child: body,
                ),
                null => body,
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Mock 137, variant A (the owner, 1.4.0): the model's thinking as one thin
/// line that never loads the screen. Live it says «Pensando… · 12 s» with a
/// live dot and the last sentence cut to fit; a tap opens six lines that
/// follow the newest words, another the whole thought, a third folds it
/// back. Finished, the same line says «Pensamiento · 12 s» and a tap opens
/// it whole. The line's height never changes while it thinks: only its
/// words and its time do.
///
/// Like Hermes Desktop's `ThinkingDisclosure`
/// (`apps/desktop/src/components/assistant-ui/thread/message-parts.tsx`,
/// l.219-362): the labels of l.264-275, and what the reader opened stays
/// open (`open = userOpen ?? showPreview`, l.256). The default is the
/// local setting ([ReasoningDisclosurePrefs]): one line (the owner's default),
/// or open at six lines while it thinks (Console before 1.4.0).
///
/// The same line serves the chat's trace and the activity view
/// ([ReasoningPanel]).
class ThinkingLine extends StatefulWidget {
  const ThinkingLine({
    required this.text,
    this.live = false,
    this.startedAt,
    this.duration,
    this.clock,
    this.timeLabel,
    this.bodyKey,
    this.initiallyOpen = false,
    super.key,
  });

  final String text;
  final bool live;

  /// A finished thought shown whole until the reader folds it: the reader
  /// opened the turn it belongs to to read what happened (gint48: folded
  /// again inside the opened turn, its text was out of the tree, so out of
  /// reach of TalkBack and of a reader who had already asked to see it).
  final bool initiallyOpen;

  /// When the thought began (live: the time counts up from it).
  final DateTime? startedAt;

  /// How long it took (finished).
  final Duration? duration;

  /// The turn's clock (tests and the turn's own timer); `DateTime.now`
  /// otherwise.
  final DateTime Function()? clock;

  /// A time already worded by the caller, in place of [duration].
  final String? timeLabel;

  /// Key of the opened body (the activity view keeps its own).
  final Key? bodyKey;

  /// Lines of the first opening (mock 137 A).
  static const int previewLines = 6;

  @override
  State<ThinkingLine> createState() => _ThinkingLineState();
}

class _ThinkingLineState extends State<ThinkingLine> {
  /// 0: the line; 1: six lines; 2: the whole thought. Null until the
  /// reader taps: then the setting decides.
  int? _userLevel;

  /// A thought shown open while live stays open once it is over: folding it
  /// then would make the turn jump. Desktop's `sawLivePreview` latch
  /// (`message-parts.tsx:242-255`): the folded setting outranks it.
  bool _sawLive = false;

  int _level(bool collapsedByDefault) {
    if (widget.live && !collapsedByDefault) _sawLive = true;
    final preview = !collapsedByDefault && (widget.live || _sawLive);
    return _userLevel ?? (widget.initiallyOpen ? 2 : (preview ? 1 : 0));
  }

  void _tap(int current) {
    HermesHaptics.selection();
    setState(() {
      // Live: line → six → whole → line. Finished: line → whole → line.
      _userLevel = widget.live ? (current + 1) % 3 : (current == 0 ? 2 : 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (TurnReasoningQuote._blank(widget.text)) return const SizedBox.shrink();
    final prefs = ReasoningDisclosurePrefs.shared;
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final level = _level(prefs.collapsedByDefault);
        final reduceMotion =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        final Widget? body = switch (level) {
          1 => TurnReasoningQuote(
            key: widget.bodyKey,
            text: widget.text,
            live: widget.live,
            lines: ThinkingLine.previewLines,
          ),
          2 => TurnReasoningQuote(
            key: widget.bodyKey,
            text: widget.text,
            live: widget.live,
          ),
          _ => null,
        };
        final opened = SizedBox(width: double.infinity, child: body);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _ThinkingLineRow(
              live: widget.live,
              expanded: level > 0,
              text: widget.text,
              startedAt: widget.startedAt,
              duration: widget.duration,
              clock: widget.clock,
              timeLabel: widget.timeLabel,
              snippet: widget.live && level == 0,
              onTap: () => _tap(level),
            ),
            // Opened by the reader: it unfolds downwards from its line.
            if (reduceMotion)
              opened
            else
              AnimatedSize(
                duration: HermesMotion.base,
                curve: HermesMotion.emphasized,
                alignment: AlignmentDirectional.topStart,
                child: opened,
              ),
          ],
        );
      },
    );
  }
}

/// The line itself: a 48 dp target of fixed height.
class _ThinkingLineRow extends StatelessWidget {
  const _ThinkingLineRow({
    required this.live,
    required this.expanded,
    required this.text,
    required this.startedAt,
    required this.duration,
    required this.clock,
    required this.timeLabel,
    required this.snippet,
    required this.onTap,
  });

  final bool live;
  final bool expanded;
  final String text;
  final DateTime? startedAt;
  final Duration? duration;
  final DateTime Function()? clock;
  final String? timeLabel;
  final bool snippet;
  final VoidCallback onTap;

  /// The last sentence of the thought, as one plain line.
  static String lastSentence(String text) {
    final flat = plainPreview(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    final from = flat.length - 2;
    if (from < 0) return flat;
    var start = 0;
    for (final mark in const ['. ', '? ', '! ', '… ', ': ']) {
      final at = flat.lastIndexOf(mark, from);
      if (at >= 0 && at + mark.length > start) start = at + mark.length;
    }
    return flat.substring(start);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final base = HermesType.value.copyWith(color: colors.textSecondary);
    final finished = !live && duration != null;
    final brief = finished && duration! < const Duration(seconds: 1);
    final label = live
        ? strings.chatActivityThinking
        : brief
        ? strings.tk140ThoughtBrief
        : strings.rt1215Thinking;
    final Widget? time = live && startedAt != null
        ? _ThinkingElapsed(startedAt: startedAt!, clock: clock, style: base)
        : timeLabel != null
        ? Text(timeLabel!, maxLines: 1, style: base)
        : finished && !brief
        ? Text(thinkingTime(strings, duration!), maxLines: 1, style: base)
        : null;
    final seconds = live && startedAt != null
        ? (clock?.call() ?? DateTime.now()).difference(startedAt!).inSeconds
        : duration?.inSeconds;
    final semanticsLabel = brief || seconds == null
        ? label
        : live
        ? strings.tk140ThinkingFor(seconds < 0 ? 0 : seconds)
        : strings.tk140ThoughtFor(seconds);
    final row = SizedBox(
      height: HermesSpace.tap,
      child: Row(
        children: [
          if (live)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 3, end: 2),
              child: TurnStatusPulse(color: colors.accent),
            )
          else
            ThinkingGlyph(size: HermesIcon.sm, color: base.color),
          const SizedBox(width: HermesSpace.x2),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (time != null) ...[Text(' · ', style: base), time],
          if (snippet) ...[
            Text(' · ', style: base),
            // The last sentence gives way first: «Pensando… · 12 s» and the
            // arrow always fit.
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  lastSentence(text),
                  key: const ValueKey('turn-thought-snippet'),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: base,
                ),
              ),
            ),
          ] else
            const Spacer(),
          const SizedBox(width: HermesSpace.x1),
          AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: reduceMotion ? Duration.zero : HermesMotion.fast,
            child: Icon(
              Icons.expand_more,
              size: HermesIcon.sm,
              color: base.color,
            ),
          ),
        ],
      ),
    );
    return Semantics(
      container: true,
      button: true,
      expanded: expanded,
      label: semanticsLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('turn-thought-toggle'),
        borderRadius: BorderRadius.circular(HermesRadius.control),
        onTap: onTap,
        child: row,
      ),
    );
  }
}

/// A thought's time in whole seconds, as the turn's row and Desktop word it
/// (mock 137 A: «12 s», «1:05»): a live count never flickers a decimal.
String thinkingTime(Strings strings, Duration value) {
  final seconds = value.isNegative ? 0 : value.inSeconds;
  if (seconds < 60) return strings.i18n131DurationSeconds('$seconds');
  return formatTurnElapsed(Duration(seconds: seconds));
}

/// The live thought's seconds: the only part of the line that changes once
/// a second, so nothing else rebuilds for it.
class _ThinkingElapsed extends StatefulWidget {
  const _ThinkingElapsed({
    required this.startedAt,
    required this.clock,
    required this.style,
  });

  final DateTime startedAt;
  final DateTime Function()? clock;
  final TextStyle style;

  @override
  State<_ThinkingElapsed> createState() => _ThinkingElapsedState();
}

class _ThinkingElapsedState extends State<_ThinkingElapsed> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && TickerMode.valuesOf(context).enabled) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.clock?.call() ?? DateTime.now();
    return Text(
      thinkingTime(Strings.of(context), now.difference(widget.startedAt)),
      maxLines: 1,
      style: widget.style.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Icon of a tool row, by what the tool does.
IconData turnToolIcon(ActivityStep step) {
  if (step.kind == ActivityStepKind.skill) return Icons.auto_awesome_rounded;
  final name = canonicalToolName(step.label);
  if (isSkillActivityTool(name)) return Icons.auto_awesome_rounded;
  if (isMemoryTool(name)) return Icons.psychology_outlined;
  if (toolAppActionLabel(name) != null) return Icons.extension_outlined;
  return switch (name) {
    'terminal' ||
    'execute_code' ||
    'process_manage' ||
    'process' => Icons.terminal_rounded,
    'read_file' => Icons.description_outlined,
    'edit_file' || 'patch' || 'write_file' => Icons.edit_outlined,
    'list_files' => Icons.folder_open_outlined,
    'search_files' ||
    'web_search' ||
    'session_search_recall' ||
    'session_search' ||
    'x_search' => Icons.search_rounded,
    'clarify' || 'setup_choose' => Icons.help_outline_rounded,
    'cronjob' || 'cronjob_manage' => Icons.schedule_rounded,
    'image_generate' || 'browser_take_screenshot' => Icons.image_outlined,
    'vision_analyze' => Icons.visibility_outlined,
    'start_chat' => Icons.chat_bubble_outline_rounded,
    // A subagent is the app's agent everywhere (the island's card too).
    'delegate_task' => Icons.smart_toy_outlined,
    'todo' || 'todo_list' => Icons.checklist_rounded,
    _ =>
      name.startsWith('browser_') || name.startsWith('web_')
          ? Icons.public_rounded
          : name.startsWith('kanban_')
          ? Icons.checklist_rounded
          : Icons.build_outlined,
  };
}

/// One tool of the turn as a round pill of one line (mock 138 v2): what it
/// does · its target in mono · how long. Preparing (no start yet) its ring
/// is grey and there is no timer; running, the ring is the accent and the
/// pill counts its own seconds; done, the pill is tinted and says how long
/// it took; failed, the tint is the error's.
class TurnToolRow extends StatelessWidget {
  const TurnToolRow({required this.step, this.clock, super.key});

  final ActivityStep step;
  final DateTime Function()? clock;

  /// The pill's height (mock 138 v2: 32 dp). Larger text grows it.
  static const double pillHeight = 32;

  /// The glyph's round seat, and how far it sits from the pill's edge.
  static const double glyphSize = 22;
  static const double glyphInset = 5;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final failed = step.status == ActivityStepStatus.failed;
    final done = step.status == ActivityStepStatus.done;
    final running = step.isRunning;
    final startedAt = step.startedAt;
    final preparing = running && startedAt == null;
    final title = activityStepTitle(s, step);
    final status = switch (step.status) {
      ActivityStepStatus.done => s.liveStepDone,
      ActivityStepStatus.failed => s.liveStepFailed,
      ActivityStepStatus.running => s.liveStepRunning,
    };
    final Color? tint = done
        ? colors.success.withValues(alpha: 0.12)
        : failed
        ? colors.error.withValues(alpha: 0.12)
        : null;
    // Ola 8: the quiet ink keeps 4.5:1 on a done or failed pill's tint.
    final muted = switch (tint) {
      final pill? => readableInkOnTint(colors.textSecondary, pill, colors),
      null => colors.textSecondary,
    };
    final quiet = HermesType.support.copyWith(color: muted);
    Widget time(String text) => Padding(
      padding: const EdgeInsetsDirectional.only(start: HermesSpace.x2),
      child: Text(
        text,
        maxLines: 1,
        style: quiet.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final Widget? trailing;
    if (running && startedAt != null) {
      trailing = ActivityTicker(
        active: true,
        clock: clock,
        builder: (context, now) {
          final elapsed = now.difference(startedAt);
          return time(formatActivityElapsed(elapsed));
        },
      );
    } else if (!running && step.duration != null) {
      trailing = time(formatStepDuration(step.duration!, languageCode: lang));
    } else {
      trailing = null;
    }
    final duration = !running && step.duration != null
        ? formatStepDuration(step.duration!, languageCode: lang)
        : null;
    return Semantics(
      container: true,
      label: [title, ?step.detail, status, ?duration].join(', '),
      excludeSemantics: true,
      child: Padding(
        key: ValueKey('turn-tool-${step.id}'),
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: DecoratedBox(
          key: const ValueKey('turn-tool-pill'),
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            color: tint,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: pillHeight),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                start: glyphInset,
                end: HermesSpace.inset,
              ),
              child: Row(
                children: [
                  // The ring's turn repaints the glyph, not the live bubble
                  // (REVIEW-T2-A).
                  RepaintBoundary(
                    child: _ToolGlyph(
                      key: const ValueKey('turn-tool-glyph'),
                      state: failed
                          ? _ToolState.failed
                          : done
                          ? _ToolState.done
                          : preparing
                          ? _ToolState.preparing
                          : _ToolState.running,
                    ),
                  ),
                  const SizedBox(width: HermesSpace.x2),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: title,
                            style: TextStyle(
                              fontWeight: preparing
                                  ? FontWeight.w500
                                  : FontWeight.w600,
                              color: preparing ? muted : colors.textPrimary,
                            ),
                          ),
                          if (step.detail case final detail?) ...[
                            TextSpan(
                              text: ' · ',
                              style: TextStyle(color: muted),
                            ),
                            TextSpan(
                              text: detail,
                              style: chatCodeTextStyle(
                                muted,
                                fontSize: HermesType.support.fontSize!,
                              ),
                            ),
                          ],
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: TurnType.row,
                        height: 1.3,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ToolState { preparing, running, done, failed }

/// Mock 138 v2's ring: three quarters of a 2 dp circle. Not a progress
/// spinner: it turns only on the beat (see [_ToolGlyph]).
class _ToolRingPainter extends CustomPainter {
  const _ToolRingPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      rect,
      0,
      1.5 * math.pi,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ToolRingPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The pill's glyph on its round seat: a ring while it prepares (grey) or
/// runs (the accent, turning once on each beat of [TurnPulseClock], so a
/// running tool never keeps the screen drawing), a check when done, a
/// warning when it failed. Still with reduced motion.
class _ToolGlyph extends StatefulWidget {
  const _ToolGlyph({required this.state, super.key});

  final _ToolState state;

  @override
  State<_ToolGlyph> createState() => _ToolGlyphState();
}

class _ToolGlyphState extends State<_ToolGlyph>
    with SingleTickerProviderStateMixin {
  /// Mock 138 v2: one turn in 0.9 s.
  static const Duration _turn = Duration(milliseconds: 900);

  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: _turn,
  );
  bool _subscribed = false;

  void _play() {
    if (mounted) _spin.forward(from: 0);
  }

  void _cancel() {
    if (mounted) _spin.reset();
  }

  void _follow() {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final turns = widget.state == _ToolState.running && !still;
    if (turns && !_subscribed) {
      _subscribed = true;
      TurnPulseClock.instance.subscribe(this, play: _play, cancel: _cancel);
    } else if (!turns && _subscribed) {
      _subscribed = false;
      TurnPulseClock.instance.unsubscribe(this);
      _spin.reset();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(_ToolGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _follow();
  }

  @override
  void dispose() {
    if (_subscribed) TurnPulseClock.instance.unsubscribe(this);
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    Widget ring(Color color) => CustomPaint(
      size: const Size.square(11),
      painter: _ToolRingPainter(color),
    );
    final (Color? seat, Widget glyph) = switch (widget.state) {
      _ToolState.preparing => (
        colors.surfaceVariant,
        Opacity(opacity: 0.6, child: ring(colors.textSecondary)),
      ),
      _ToolState.running => (
        colors.accent.withValues(alpha: 0.16),
        RotationTransition(
          key: const ValueKey('turn-tool-spin'),
          turns: _spin,
          child: ring(colors.accent),
        ),
      ),
      _ToolState.done => (
        null,
        Icon(Icons.done_rounded, size: 13, color: colors.success),
      ),
      _ToolState.failed => (
        null,
        Icon(Icons.error_outline_rounded, size: 13, color: colors.error),
      ),
    };
    return SizedBox.square(
      dimension: TurnToolRow.glyphSize,
      child: DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: seat),
        child: Center(child: glyph),
      ),
    );
  }
}

String _taskStatusWord(Strings s, AgentTaskStatus status) => switch (status) {
  AgentTaskStatus.pending => s.agentTasksStatusPending,
  AgentTaskStatus.inProgress => s.agentTasksStatusInProgress,
  AgentTaskStatus.completed => s.agentTasksStatusCompleted,
  AgentTaskStatus.cancelled => s.agentTasksStatusCancelled,
};

/// One task of the turn's plan.
class _TurnTaskRow extends StatelessWidget {
  const _TurnTaskRow({
    required this.item,
    required this.depth,
    this.history = false,
  });

  final AgentTaskItem item;
  final int depth;

  /// The turn ended: nothing is in progress, what stayed open is marked.
  final bool history;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final notDone = history && item.isOpen;
    final Widget icon = switch (item.status) {
      AgentTaskStatus.completed => Icon(
        Icons.check_rounded,
        size: 16,
        color: history ? colors.success.withValues(alpha: 0.8) : colors.success,
      ),
      AgentTaskStatus.inProgress when !history && !reduceMotion => SizedBox(
        width: 13,
        height: 13,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: colors.accent,
        ),
      ),
      AgentTaskStatus.inProgress when !history => Icon(
        Icons.play_circle_outline_rounded,
        size: 16,
        color: colors.accent,
      ),
      AgentTaskStatus.cancelled => Icon(
        Icons.block_rounded,
        size: 15,
        color: colors.textSecondary,
      ),
      _ => Icon(
        Icons.radio_button_unchecked_rounded,
        size: 15,
        color: colors.textSecondary,
      ),
    };
    final style = switch (item.status) {
      AgentTaskStatus.completed => TextStyle(color: colors.textSecondary),
      AgentTaskStatus.cancelled => TextStyle(
        color: colors.textSecondary,
        fontStyle: FontStyle.italic,
      ),
      AgentTaskStatus.inProgress when !history => TextStyle(
        color: colors.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      _ => TextStyle(color: colors.textPrimary),
    };
    return Semantics(
      container: true,
      label: notDone
          ? '${item.content}: ${s.ctTaskNotDone}'
          : '${_taskStatusWord(s, item.status)}: ${item.content}',
      excludeSemantics: true,
      child: Padding(
        key: ValueKey('turn-task-${item.id}'),
        padding: EdgeInsetsDirectional.only(
          start: (depth > 3 ? 3 : depth) * 14.0,
          top: 3,
          bottom: 3,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: TurnType.row * 1.3,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: icon,
              ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: plainPreview(item.content)),
                    if (notDone)
                      TextSpan(
                        text: ' · ${s.ctTaskNotDone}',
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                  ],
                ),
                style: style.copyWith(fontSize: TurnType.row, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The plan in flight, as the look approved on 9 nov (mock
/// `turno3.html`): «Tareas 3/5» with a thin bar, and under it only the
/// last task done (struck through, dim), the one in hand (a ring turning)
/// and the next two (fainter). The rest of the done ones fold into «n
/// anteriores completadas ›». Rows come and go on the same clock as the
/// actions' window, so advancing the plan is a glide, not a jump.
class TurnTasksLive extends StatefulWidget {
  const TurnTasksLive({required this.tasks, super.key});

  final AgentTaskList tasks;

  @override
  State<TurnTasksLive> createState() => _TurnTasksLiveState();
}

enum _TaskSlot { done, current, next }

class _TurnTasksLiveState extends State<TurnTasksLive> {
  bool _showDone = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final tasks = widget.tasks;
    final rows = tasks.rows;
    final current = rows
        .where((row) => row.item.status == AgentTaskStatus.inProgress)
        .firstOrNull;
    final doneRows = [
      for (final row in rows)
        if (row.item.status == AgentTaskStatus.completed) row,
    ];
    // The last one done before the one in hand (else the last done).
    final pivot = current == null ? rows.length : rows.indexOf(current);
    final lastDone =
        doneRows.where((row) => rows.indexOf(row) < pivot).lastOrNull ??
        doneRows.lastOrNull;
    final next = [
      for (final row in rows)
        if (row.item.status == AgentTaskStatus.pending) row,
    ].take(HermesLiveTurn.tasksNext).toList();
    final earlier = [
      for (final row in doneRows)
        if (row.item.id != lastDone?.item.id) row,
    ];
    final visible = <({AgentTaskRow row, _TaskSlot slot, int rank})>[
      if (_showDone)
        for (final row in earlier) (row: row, slot: _TaskSlot.done, rank: -1),
      if (lastDone != null) (row: lastDone, slot: _TaskSlot.done, rank: 0),
      if (current != null) (row: current, slot: _TaskSlot.current, rank: 0),
      for (var i = 0; i < next.length; i++)
        (row: next[i], slot: _TaskSlot.next, rank: i),
    ];
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: HermesSurfaces.group(colors),
        borderRadius: BorderRadius.circular(HermesRadius.control),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpace.inset,
          vertical: HermesSpace.x2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              container: true,
              header: true,
              label: s.agentTasksSummary(tasks.done, tasks.total),
              excludeSemantics: true,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      end: HermesSpace.x2,
                    ),
                    child: Icon(
                      Icons.checklist_rounded,
                      size: HermesIcon.sm,
                      color: colors.textSecondary,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      s.agentTasksPillTitle(tasks.done, tasks.total),
                      key: const ValueKey('turn-tasks-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TurnType.row,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: HermesSpace.gap),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(HermesRadius.chip),
                      child: LinearProgressIndicator(
                        key: const ValueKey('turn-tasks-progress'),
                        value: tasks.progress,
                        minHeight: HermesLiveTurn.progressHeight,
                        backgroundColor: colors.divider,
                        color: tasks.isFinished
                            ? colors.success
                            : colors.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            TurnStepMotion(
              key: const ValueKey('turn-tasks-window'),
              entries: [
                for (final entry in visible)
                  (
                    id: 'task-${entry.row.item.id}',
                    child: _LiveTaskRow(
                      item: entry.row.item,
                      depth: entry.row.depth,
                      slot: entry.slot,
                      rank: entry.rank,
                    ),
                  ),
              ],
            ),
            if (earlier.isNotEmpty)
              TurnFoldLine(
                key: const ValueKey('turn-tasks-done-toggle'),
                label: s.liveTasksEarlierDone(earlier.length),
                expanded: _showDone,
                leading: Icons.check_rounded,
                leadingColor: colors.success,
                onTap: () => setState(() => _showDone = !_showDone),
              ),
            if (tasks.omitted > 0)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: HermesSpace.x6,
                  top: HermesSpace.x1,
                ),
                child: Text(
                  s.agentTasksMore(tasks.omitted),
                  style: TextStyle(
                    fontSize: HermesType.supportSize,
                    color: colors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return KeyedSubtree(key: const ValueKey('turn-tasks-live'), child: surface);
  }
}

/// One task of the live window: done (ring and check, struck through, dim),
/// in hand (a ring turning) or next (an empty ring, fainter the further it is).
class _LiveTaskRow extends StatelessWidget {
  const _LiveTaskRow({
    required this.item,
    required this.depth,
    required this.slot,
    required this.rank,
  });

  final AgentTaskItem item;
  final int depth;
  final _TaskSlot slot;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final opacity = switch (slot) {
      _TaskSlot.done => rank < 0 ? 1.0 : HermesLiveTurn.doneOpacity,
      _TaskSlot.current => 1.0,
      _TaskSlot.next =>
        HermesLiveTurn.nextOpacity[rank.clamp(
          0,
          HermesLiveTurn.nextOpacity.length - 1,
        )],
    };
    final Widget icon = switch (slot) {
      _TaskSlot.done => const LiveRingCheck(),
      _TaskSlot.current => const LiveSpinnerRing(),
      _TaskSlot.next => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: colors.textSecondary,
            width: HermesLiveTurn.connectorWidth,
          ),
        ),
        child: const SizedBox.square(dimension: HermesLiveTurn.ringSize),
      ),
    };
    final style = TextStyle(
      fontSize: HermesType.supportSize,
      height: 1.3,
      fontWeight: slot == _TaskSlot.current ? FontWeight.w500 : null,
      color: slot == _TaskSlot.current
          ? colors.textPrimary
          : colors.textSecondary,
      decoration: slot == _TaskSlot.done ? TextDecoration.lineThrough : null,
      decorationColor: colors.textTertiary,
    );
    return Semantics(
      container: true,
      label: '${_taskStatusWord(s, item.status)}: ${item.content}',
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: opacity,
        duration: HermesMotion.duration(context, HermesMotion.base),
        child: Padding(
          key: ValueKey('turn-task-${item.id}'),
          padding: EdgeInsetsDirectional.only(
            start: math.min(depth, 3) * HermesSpace.rowH,
            top: HermesSpace.x1,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: HermesSpace.x2),
                child: icon,
              ),
              Expanded(
                child: Text(
                  plainPreview(item.content),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The plan of a finished turn, opened: every task with its final state,
/// the ones left open marked «sin hacer».
class TurnTasksHistory extends StatelessWidget {
  const TurnTasksHistory({required this.tasks, super.key});

  final AgentTaskList tasks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Column(
      key: const ValueKey('turn-tasks-history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in tasks.rows)
          _TurnTaskRow(item: row.item, depth: row.depth, history: true),
        if (tasks.omitted > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 24, top: 2),
            child: Text(
              s.agentTasksMore(tasks.omitted),
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}

/// «Tareas 4 de 5 · 1 sin hacer»: the folded line of a finished turn's plan.
String turnTasksFoldLabel(Strings s, AgentTaskList tasks) {
  final open = tasks.openCount;
  final base = s.ctTasksOfTotal(tasks.done, tasks.total);
  return open == 0 ? base : '$base · ${s.ctTasksNotDone(open)}';
}

/// A quiet line that opens what it names: a button with its expanded state,
/// a chevron at its end.
class TurnFoldLine extends StatelessWidget {
  const TurnFoldLine({
    required this.label,
    required this.expanded,
    this.onTap,
    this.leading,
    this.leadingColor,
    this.semanticsLabel,
    this.lead,
    this.maxLines = 2,
    super.key,
  });

  final String label;
  final bool expanded;

  /// Said first and in bold, before [label] (mock 138 v2: «Trabajó 12 s ·
  /// 3 comandos», «2 herramientas · 7s»).
  final String? lead;

  /// Lines the label may take before it is cut with an ellipsis.
  final int maxLines;

  /// Null when there is nothing to open: the line is then plain text.
  final VoidCallback? onTap;
  final IconData? leading;
  final Color? leadingColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // A 48 dp target (audit 2.2, T8: «8 comandos ›» and «Pensamiento» were
    // 30 dp), the height of the thought's line too (mock 137 A), so the live
    // thought and the turn's summary swap at the turn's end without a jump.
    final style = TextStyle(
      fontSize: TurnType.fold,
      height: 1.3,
      color: colors.textSecondary,
    );
    final line = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: HermesSpace.tap),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading case final icon?)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Icon(
                icon,
                size: 16,
                color: leadingColor ?? colors.textSecondary,
              ),
            ),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  if (lead case final lead?)
                    TextSpan(
                      text: label.isEmpty ? lead : '$lead · ',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  if (label.isNotEmpty) TextSpan(text: label),
                ],
              ),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            // Desktop's DisclosureCaret: points right when closed, turns
            // down when open, 150 ms.
            AnimatedRotation(
              turns: expanded ? 0 : -0.25,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 150),
              child: Icon(
                Icons.expand_more,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
    final spoken =
        semanticsLabel ??
        (lead == null || label.isEmpty ? lead ?? label : '$lead · $label');
    if (onTap == null) {
      return Semantics(
        container: true,
        label: spoken,
        excludeSemantics: true,
        child: line,
      );
    }
    // excludeSemantics drops the InkWell's tap: the node carries it so a
    // screen reader can open the line (REVIEW-F0-F1 P1-2's pattern).
    return Semantics(
      container: true,
      button: true,
      expanded: expanded,
      label: spoken,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: line,
      ),
    );
  }
}
