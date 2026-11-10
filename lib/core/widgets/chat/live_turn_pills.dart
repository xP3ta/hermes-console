import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/activity_snapshot.dart';
import '../../models/tool_label.dart' show activityStepTitle;
import '../../models/tool_name.dart' show canonicalToolName;
import '../../services/reasoning_disclosure_prefs.dart';
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../activity_pill.dart' show ActivityTicker, formatTurnElapsed;
import 'chat_markdown_body.dart' show chatCodeTextStyle;
import 'live_motion.dart';
import '../chat_turn_activity.dart' show TurnReasoningQuote, TurnType;
import '../frosted_backdrop.dart';
import '../thinking_glyph.dart';
import '../../feedback/haptics.dart';

/// Q9-CHAT5 v2 (the owner, the reference video): the live turn, above the
/// composer and to its left, as ONE status pill that replaces itself —
/// the face (the brain while it thinks), a short verb, the tool in hand in
/// the code face and the turn's clock, the only one on screen — and, while
/// a tool runs, the step in hand in a fainter, wider pill above it. Nothing
/// piles up: what is done becomes a card in the transcript.
///
/// The verb turns over every [verbPeriod] through Hermes Desktop's own
/// lists (`components/pet/pet-bubble.tsx`), starting from the plain one; a
/// screen reader only hears the state, never the turn of phrase, and never
/// the seconds. While it thinks the thought being written opens above the
/// pills (mock 137 A's reading): at once when the reader turned «show the
/// thought while it thinks» on (`ReasoningDisclosurePrefs`), with a tap
/// otherwise.
class LiveTurnPills extends StatefulWidget {
  const LiveTurnPills({
    required this.snapshot,
    required this.avatar,
    this.clock,
    super.key,
  }) : headerNow = null,
       name = null,
       mark = null,
       doneElapsed = null,
       onDone = null;

  /// QA9715: the existing header island owns phase, clock and work count.
  /// The host already ticks; this adds neither a surface nor another clock.
  ///
  /// [doneElapsed] set (and no turn running): the turn ended well, and the
  /// capsule says «Listo» with the turn's final clock for [doneHold], then
  /// calls [onDone] so the island goes back to the profile's name.
  const LiveTurnPills.header({
    required this.snapshot,
    required DateTime now,
    this.mark,
    this.name,
    this.doneElapsed,
    this.onDone,
    super.key,
  }) : headerNow = now,
       avatar = const SizedBox.shrink(),
       clock = null;

  /// The turn's final clock when it just ended well (header only).
  final Duration? doneElapsed;

  /// The «Listo» hold is over (header only).
  final VoidCallback? onDone;

  /// How long «Listo» stays before the name comes back.
  static const Duration doneHold = Duration(seconds: 2);

  /// The capsule is never wider than this.
  static const double maxPillWidth = 210;

  final DateTime? headerNow;
  final String? mark;

  /// The profile's name the capsule belongs to (spoken with «Listo»).
  final String? name;

  /// The same snapshot the island is painted from.
  final ActivitySnapshot snapshot;

  /// This chat's face, [avatarSize] square.
  final Widget avatar;

  /// The turn's clock (tests and the chat's own); `DateTime.now` otherwise.
  final DateTime Function()? clock;

  /// How long a verb stays (the owner: at least 3 s).
  static const Duration verbPeriod = Duration(seconds: 4);

  static const double pillHeight = 36;
  static const double avatarSize = 24;

  /// The status pill's text keeps clear of the face by this much.
  static const double _gap = HermesSpace.x2;

  @override
  State<LiveTurnPills> createState() => _LiveTurnPillsState();
}

/// What the turn is doing, in the pills' terms. [said]: a state of its own
/// the pipeline names (replying, connecting, waiting on the provider), said
/// as it comes, never turned over.
enum _Phase { thinking, tool, writing, coordinating, waiting, quiet, said }

class _LiveTurnPillsState extends State<LiveTurnPills> {
  /// What the reader chose with a tap; null: the setting decides.
  bool? _userOpen;
  bool _thoughtOpen = false;

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final doneElapsed = widget.doneElapsed;
    if (!snapshot.turnActive &&
        doneElapsed != null &&
        widget.headerNow != null) {
      _userOpen = null;
      final s = Strings.of(context);
      return TweenAnimationBuilder<double>(
        key: const ValueKey('live-turn-done-hold'),
        tween: Tween<double>(begin: 0, end: 1),
        duration: LiveTurnPills.doneHold,
        onEnd: widget.onDone,
        builder: (context, _, child) => child!,
        child: _HeaderStatus(
          kind: _PillKind.done,
          semanticsKey: const ValueKey('live-turn-done'),
          verb: s.livePDone,
          spoken: s.livePDone,
          elapsed: formatTurnElapsed(doneElapsed),
        ),
      );
    }
    if (!snapshot.turnActive) {
      _userOpen = null;
      return const SizedBox.shrink(key: ValueKey('live-turn-pills-none'));
    }
    final s = Strings.of(context);
    final step = snapshot.current;
    final tool =
        step != null &&
            step.kind != ActivityStepKind.reasoning &&
            step.isRunning
        ? step
        : null;
    final headline = snapshot.headline?.trim() ?? '';
    final thinkingHeadline =
        headline.isEmpty ||
        _plain(headline) == _plain(s.chaPipelineThinking) ||
        _plain(headline) == _plain(s.chatActivityThinking);
    // The header capsule has words of its own for writing and coordinating.
    final inHeader = widget.headerNow != null;
    final writing =
        inHeader &&
        headline.isNotEmpty &&
        _plain(headline) == _plain(s.chaPipelineStreaming);
    final agents = _AgentCount.of(snapshot);
    final phase = snapshot.waitingForUser
        ? _Phase.waiting
        : snapshot.noActivityHint
        ? _Phase.quiet
        : writing
        ? _Phase.writing
        : inHeader && agents.running > 0
        ? _Phase.coordinating
        : tool != null
        ? _Phase.tool
        : thinkingHeadline
        ? _Phase.thinking
        : _Phase.said;
    final thought = snapshot.liveReasoning?.trim() ?? '';
    final canOpen = phase == _Phase.thinking && thought.isNotEmpty;
    // A new thought opens by the setting again.
    if (!canOpen) _userOpen = null;
    _thoughtOpen =
        canOpen &&
        (_userOpen ?? !ReasoningDisclosurePrefs.shared.collapsedByDefault);
    final verbs = switch (phase) {
      _Phase.tool => _verbs(s.q9TurnVerbsWork),
      _Phase.thinking => _verbs(s.q9TurnVerbsThink),
      _Phase.writing => [s.livePWriting],
      _Phase.coordinating => [s.livePCoordinating],
      _Phase.waiting => [s.liveWaitingForUser],
      _Phase.quiet => [s.chaTurnStillWorking],
      _Phase.said => [headline],
    };
    // The tool in the status line only while it is what the turn is doing:
    // waiting on the user it stays the step above, and the line says the
    // wait alone (gint67: «Esperando tu respuesta, terminal»).
    final toolName = phase == _Phase.tool
        ? canonicalToolName(tool!.label)
        : null;
    // A screen reader hears the state: the plain verb, and the tool.
    final spoken = [_plain(verbs.first), ?toolName].join(', ');
    if (widget.headerNow case final now?) {
      final started = snapshot.turnStartedAt;
      final elapsed = started == null ? null : now.difference(started);
      final age = elapsed == null || elapsed.isNegative
          ? Duration.zero
          : elapsed;
      // The capsule says the state in ONE word (the verb of the tool in
      // hand while one runs); the long phrases are the pills' (not here).
      final toolVerb = phase == _Phase.tool && tool != null
          ? activityStepTitle(s, tool)
          : null;
      final word = switch (phase) {
        _Phase.tool when toolVerb != null => _ellipsis(toolVerb),
        _Phase.thinking => s.turnLineThinking,
        _Phase.waiting => s.livePNeedsPermission,
        _ => _plain(verbs.first),
      };
      final detail = phase == _Phase.tool ? (tool!.detail ?? toolName) : null;
      final stepLabel = phase == _Phase.tool
          ? [toolVerb ?? word, ?detail].join(' · ')
          : null;
      return _HeaderStatus(
        kind: switch (phase) {
          _Phase.thinking => _PillKind.thinking,
          _Phase.waiting => _PillKind.waiting,
          _Phase.coordinating => _PillKind.coordinating,
          _ => _PillKind.working,
        },
        phase: age.inSeconds.toDouble(),
        verb: word,
        agents: phase == _Phase.coordinating
            ? s.livePAgents(agents.done, agents.total)
            : null,
        spoken: [
          stepLabel ?? word,
          if (phase == _Phase.coordinating)
            s.livePAgents(agents.done, agents.total),
          ?widget.mark,
        ].join(', '),
        elapsed: elapsed == null ? null : formatTurnElapsed(age),
        stepLabel: stepLabel,
      );
    }
    return Column(
      key: const ValueKey('live-turn-pills'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_thoughtOpen)
          Padding(
            padding: const EdgeInsets.only(bottom: HermesSpace.x2),
            child: FrostedBackdrop.glass(
              key: const ValueKey('live-turn-thought'),
              zone: FrostedZone.bottom,
              borderRadius: BorderRadius.circular(HermesRadius.card),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.inset,
                  HermesSpace.x2,
                  HermesSpace.inset,
                  HermesSpace.x2,
                ),
                child: TurnReasoningQuote(
                  text: thought,
                  live: true,
                  lines: _thoughtLines,
                ),
              ),
            ),
          ),
        if (tool != null)
          Padding(
            padding: const EdgeInsets.only(bottom: HermesSpace.x2),
            child: _StepPill(
              avatar: widget.avatar,
              title: activityStepTitle(s, tool),
              detail: tool.detail,
            ),
          ),
        Semantics(
          key: const ValueKey('live-turn-status'),
          container: true,
          liveRegion: true,
          button: canOpen,
          expanded: canOpen ? _thoughtOpen : null,
          label: spoken,
          onTap: canOpen ? _toggleThought : null,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: canOpen ? _toggleThought : null,
            child: ConstrainedBox(
              // The pill is 36; its target is the 48 of every control.
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: 1,
                child: FrostedBackdrop.glass(
                  key: const ValueKey('live-turn-status-pill'),
                  // the owner's rule 2: one blur at the foot, this one; the step
                  // and the thought above it keep the translucent veil.
                  zone: FrostedZone.bottom,
                  zonePriority: 1,
                  borderRadius: BorderRadius.circular(
                    LiveTurnPills.pillHeight / 2,
                  ),
                  child: _StatusRow(
                    phase: phase,
                    avatar: widget.avatar,
                    verbs: verbs,
                    toolName: toolName,
                    startedAt: snapshot.turnStartedAt,
                    clock: widget.clock,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _toggleThought() {
    HermesHaptics.selection();
    setState(() => _userOpen = !_thoughtOpen);
  }

  /// Lines of the thought opened from the pill (mock 137 A's first level).
  static const int _thoughtLines = 6;

  static List<String> _verbs(String joined) {
    final verbs = [
      for (final verb in joined.split('|'))
        if (verb.trim().isNotEmpty) verb.trim(),
    ];
    return verbs.isEmpty ? [joined] : verbs;
  }

  /// «Buscando en la web» said as a step in hand: «Buscando en la web…».
  static String _ellipsis(String verb) {
    final clean = _plain(verb);
    return clean.isEmpty ? verb : '$clean…';
  }

  /// «Pensando…» said as a state: «Pensando».
  static String _plain(String verb) {
    var clean = verb.trim();
    while (clean.endsWith('…') || clean.endsWith('.')) {
      clean = clean.substring(0, clean.length - 1).trimRight();
    }
    return clean.isEmpty ? verb.trim() : clean;
  }
}

/// The status pill's one line: face or brain, verb, tool, clock.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.phase,
    required this.avatar,
    required this.verbs,
    required this.toolName,
    required this.startedAt,
    required this.clock,
  });

  final _Phase phase;
  final Widget avatar;
  final List<String> verbs;
  final String? toolName;
  final DateTime? startedAt;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final quiet = TextStyle(
      fontSize: TurnType.row,
      height: 1.3,
      color: colors.textSecondary,
    );
    Widget line(DateTime? now) {
      final elapsed = startedAt == null || now == null
          ? null
          : now.difference(startedAt!);
      final seconds = elapsed == null || elapsed.isNegative
          ? 0
          : elapsed.inSeconds;
      final verb =
          verbs[(seconds ~/ LiveTurnPills.verbPeriod.inSeconds) % verbs.length];
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: LiveTurnPills.avatarSize,
            child: Center(
              child: phase == _Phase.thinking
                  ? ThinkingGlyph(
                      key: const ValueKey('live-turn-brain'),
                      size: HermesIcon.md,
                      color: colors.accentText,
                    )
                  : avatar,
            ),
          ),
          const SizedBox(width: LiveTurnPills._gap),
          // The verb changes in place, with the clock (ct1215: the mark is
          // still, nothing of it animates).
          Flexible(
            child: Text(
              verb,
              key: ValueKey('live-turn-verb-$verb'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: quiet.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (toolName case final name?) ...[
            const SizedBox(width: HermesSpace.x1),
            Flexible(
              child: Text(
                name,
                key: const ValueKey('live-turn-tool'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: chatCodeTextStyle(
                  colors.textSecondary,
                  fontSize: HermesType.support.fontSize!,
                ),
              ),
            ),
          ],
          if (elapsed != null) ...[
            const SizedBox(width: HermesSpace.x2),
            Text(
              formatTurnElapsed(elapsed.isNegative ? Duration.zero : elapsed),
              key: const ValueKey('live-turn-clock'),
              maxLines: 1,
              style: quiet.copyWith(
                color: colors.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: LiveTurnPills.pillHeight),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: HermesSpace.x1,
          end: HermesSpace.inset,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          heightFactor: 1,
          child: startedAt == null
              ? line(null)
              : ActivityTicker(
                  active: true,
                  clock: clock,
                  builder: (context, now) => line(now),
                ),
        ),
      ),
    );
  }
}

/// The subagents of the snapshot, as the «n/N agentes» count.
class _AgentCount {
  const _AgentCount(this.done, this.total);

  factory _AgentCount.of(ActivitySnapshot snapshot) {
    if (snapshot.subagentsStale) return const _AgentCount(0, 0);
    var total = snapshot.subagents.length;
    var done = snapshot.subagents.where((agent) => agent.isTerminal).length;
    // Known only by count: they are all still running.
    if (total == 0) total = snapshot.subagentGenericCount;
    done = done.clamp(0, total);
    return _AgentCount(done, total);
  }

  final int done;
  final int total;
  int get running => total - done;
}

/// What the capsule is doing, for its mark and its colours.
enum _PillKind { thinking, working, coordinating, waiting, done }

/// The live turn as the header's ONE capsule: a mark (the brain that beats
/// while it thinks, the ring that turns while it works, an amber dot when it
/// waits for you, the green check when it is done), the state word with a
/// sheen over its letters, and the turn's clock (or «n/N agentes»). The
/// island around it is the glass capsule and keeps the tap that opens the
/// running work; it grows and shrinks with this content, never wider than
/// [LiveTurnPills.maxPillWidth]. When room is short only the word shortens
/// with an ellipsis; the mark and the clock always show.
class _HeaderStatus extends StatelessWidget {
  const _HeaderStatus({
    required this.kind,
    required this.verb,
    required this.spoken,
    this.phase = 0,
    this.elapsed,
    this.agents,
    this.stepLabel,
    this.semanticsKey = const ValueKey('live-turn-status'),
  });
  final _PillKind kind;

  /// Names the spoken node; «Listo» has its own so nothing that looks live
  /// is left once the turn is over.
  final Key semanticsKey;
  final String verb;
  final String spoken;

  /// Whole seconds of the turn: the host's tick that drives the marks.
  final double phase;
  final String? elapsed;
  final String? agents;
  final String? stepLabel;

  static const double _mark = HermesIcon.md;
  static const double _gap = HermesSpace.x2;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final animated = kind != _PillKind.done && kind != _PillKind.waiting;
    final verbStyle = TextStyle(
      fontSize: TurnType.row,
      height: 1.2,
      fontWeight: FontWeight.w700,
      color: kind == _PillKind.done || kind == _PillKind.waiting
          ? colors.textPrimary
          : colors.accentText,
    );
    final trailingStyle = TextStyle(
      fontSize: HermesType.support.fontSize,
      height: 1.2,
      color: chrome.mutedInk,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    double width(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final result = painter.width;
      painter.dispose();
      return result;
    }

    final trailing = agents ?? elapsed;
    final separated = agents != null;

    return Semantics(
      key: semanticsKey,
      container: true,
      liveRegion: true,
      label: spoken,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) {
          const padding = HermesSpace.x3;
          final limit = math.min(box.maxWidth, LiveTurnPills.maxPillWidth);
          final room = math.max(0.0, limit - padding * 2);
          final trailingWidth = trailing == null
              ? 0.0
              : width(trailing, trailingStyle) +
                    _gap +
                    (separated ? _gap + 1 : 0);
          final fixed = _mark + _gap + trailingWidth;
          final inner = math.min(room, fixed + width(verb, verbStyle));
          Widget lineFor(Animation<double>? seconds) {
            Widget markWidget() => SizedBox.square(
              key: const ValueKey('live-turn-face'),
              dimension: _mark,
              child: Center(
                child: switch (kind) {
                  _PillKind.thinking => LiveBrain(
                    key: const ValueKey('live-turn-brain'),
                    seconds: seconds,
                  ),
                  _PillKind.done => const LiveResultMark(ok: true),
                  _PillKind.waiting => DecoratedBox(
                    key: const ValueKey('live-turn-waiting-dot'),
                    decoration: BoxDecoration(
                      color: colors.warning,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox.square(dimension: HermesSpace.x3),
                  ),
                  _ => LiveRing(
                    key: const ValueKey('live-turn-ring'),
                    running: true,
                    seconds: seconds,
                  ),
                },
              ),
            );
            Widget word() {
              final text = Text(
                verb,
                key: ValueKey('live-turn-verb-$verb'),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: verbStyle,
              );
              if (seconds == null || !animated) return text;
              return LiveSheen(
                key: const ValueKey('live-turn-shimmer'),
                seconds: seconds,
                base: colors.accentText,
                peak: colors.textPrimary,
                child: text,
              );
            }

            Widget tail() => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (separated) ...[
                  const SizedBox(width: _gap),
                  SizedBox(
                    width: 1,
                    height: HermesSpace.x4,
                    child: ColoredBox(color: chrome.line),
                  ),
                ],
                const SizedBox(width: _gap),
                Text(
                  trailing!,
                  key: ValueKey(
                    separated ? 'live-turn-agents' : 'live-turn-clock',
                  ),
                  maxLines: 1,
                  softWrap: false,
                  style: trailingStyle,
                ),
              ],
            );

            final Widget line = inner - fixed >= 24
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      markWidget(),
                      const SizedBox(width: _gap),
                      Flexible(child: word()),
                      if (trailing != null) tail(),
                    ],
                  )
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [markWidget(), if (trailing != null) tail()],
                    ),
                  );
            return line;
          }

          final clocked = _PhaseClock(
            phase: phase,
            animated: animated,
            builder: (context, seconds) => lineFor(seconds),
          );
          return SizedBox(
            width: inner + padding * 2,
            child: ConstrainedBox(
              key: const ValueKey('live-turn-pills'),
              // The capsule is the island's tap: a 48 dp target.
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: padding),
                child: Center(
                  child: stepLabel == null
                      ? clocked
                      : Semantics(
                          key: const ValueKey('live-turn-step'),
                          label: stepLabel,
                          excludeSemantics: true,
                          child: clocked,
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The host's whole-second tick, made continuous: [builder] gets a clock of
/// seconds that glides from this tick to the next in one second, so the ring
/// turns and the word shines smoothly while nothing here owns a repeating
/// controller (a screen full of tests still settles). Null while [animated]
/// is false or motion is reduced: every mark is then still.
class _PhaseClock extends StatefulWidget {
  const _PhaseClock({
    required this.phase,
    required this.animated,
    required this.builder,
  });

  final double phase;
  final bool animated;
  final Widget Function(BuildContext context, Animation<double>? seconds)
  builder;

  @override
  State<_PhaseClock> createState() => _PhaseClockState();
}

class _PhaseClockState extends State<_PhaseClock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );
  late Animation<double> _seconds = _glide();

  Animation<double> _glide() => Tween<double>(
    begin: widget.phase,
    end: widget.phase + 1,
  ).animate(_controller);

  @override
  void initState() {
    super.initState();
    if (widget.animated) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(_PhaseClock old) {
    super.didUpdateWidget(old);
    if (widget.phase != old.phase) {
      _seconds = _glide();
      if (widget.animated) _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    widget.animated && !HermesMotion.reduced(context) ? _seconds : null,
  );
}

/// The step in hand, faint and wide, with the face beside it.
class _StepPill extends StatelessWidget {
  const _StepPill({required this.avatar, required this.title, this.detail});

  final Widget avatar;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final text = [title, ?detail].join(' · ');
    return Semantics(
      key: const ValueKey('live-turn-step'),
      container: true,
      label: text,
      excludeSemantics: true,
      child: Row(
        children: [
          SizedBox.square(dimension: LiveTurnPills.avatarSize, child: avatar),
          const SizedBox(width: HermesSpace.x2),
          Expanded(
            child: FrostedBackdrop.glass(
              key: const ValueKey('live-turn-step-pill'),
              zone: FrostedZone.bottom,
              borderRadius: BorderRadius.circular(LiveTurnPills.pillHeight / 2),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: LiveTurnPills.pillHeight,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.inset,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    heightFactor: 1,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '··· ',
                            style: TextStyle(color: colors.textTertiary),
                          ),
                          TextSpan(
                            text: text,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TurnType.row,
                        height: 1.3,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
