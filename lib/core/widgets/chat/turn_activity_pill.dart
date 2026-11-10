import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../activity_pill.dart' show ActivityTicker;
import '../chat_turn_activity.dart' show TurnType;
import 'chat_live_icon.dart';
import 'live_motion.dart';
import 'live_turn_window.dart' show LiveRingCheck, LiveSpinnerRing;
import '../../theme/live_turn_tokens.dart';
import '../../feedback/haptics.dart';

/// One 48 dp target. Live, it paints the «Trabajando» card of the look
/// approved on 9 nov (mock `turno3.html`): ring, word, the turn's clock and
/// the tool count, always visible (the earlier v4 video showed only a count;
/// the approved mock supersedes it). Settled, a thin unboxed row with the green
/// ring and its check. Only the live text repaints with the sheen.
const bool kInlineActivityShowsClock = true;

/// The tests that pin the clock's behaviour (QA 9715: it survives leaving the
/// chat and follows the host clock) read it without opening the row.
@visibleForTesting
bool debugInlineClockWhenFolded = false;

class TurnInlineActivity extends StatefulWidget {
  const TurnInlineActivity({
    required this.label,
    required this.live,
    required this.steps,
    required this.open,
    required this.onTap,
    this.spokenLabel,
    this.failed = false,
    this.glyph,
    this.startedAt,
    this.clock,
    super.key,
  });

  /// What the live row is doing, as one of the chat's ten icons; settled it
  /// shows the outcome (check, or error when it failed).
  final ChatLiveGlyph? glyph;
  final String label;

  /// What a screen reader says instead of [label], when [label] is shorter
  /// than what the row is doing («Trabajando» for «Ejecutando df»).
  final String? spokenLabel;
  final bool live;
  final DateTime? startedAt;
  final DateTime Function()? clock;
  final bool failed;
  final int steps;
  final bool open;
  final VoidCallback onTap;

  @override
  State<TurnInlineActivity> createState() => _TurnInlineActivityState();
}

class _TurnInlineActivityState extends State<TurnInlineActivity>
    with SingleTickerProviderStateMixin, LiveClockMixin<TurnInlineActivity> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncLiveClock(active: widget.live);
  }

  @override
  void didUpdateWidget(TurnInlineActivity oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncLiveClock(active: widget.live);
  }

  @override
  void dispose() {
    disposeLiveClock();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final live = widget.live;
    final text = Text(
      widget.label,
      key: const ValueKey('chat-inline-activity-text'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: TurnType.row,
        height: 1.3,
        // Live: the «Trabajando» card of the approved look, in bold.
        fontWeight: live ? FontWeight.w600 : null,
        color: live ? colors.textPrimary : colors.textSecondary,
      ),
    );
    final metaStyle = TextStyle(
      fontSize: 12,
      color: live ? colors.success : colors.textTertiary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget rowFor(double room) {
      // The meta shrinks with the room it has: «1:15 · 12 herramientas», then
      // «1:15 · 12», then only the number (a narrow header never overflows).
      final scaled = room / MediaQuery.textScalerOf(context).scale(1);
      final showClock =
          (kInlineActivityShowsClock || widget.open || debugInlineClockWhenFolded) &&
          live &&
          widget.startedAt != null &&
          scaled >= HermesLiveTurn.metaWithClock;
      final countWords = scaled >= HermesLiveTurn.metaWithWords;
      return Row(
      children: [
        if (live)
          const LiveSpinnerRing()
        else
          widget.failed
              ? ChatLiveIcon(
                  ChatLiveGlyph.error,
                  size: 18,
                  color: colors.error,
                )
              // A settled turn: the green ring with its check inside.
              : const LiveRingCheck(size: HermesIcon.md),
        const SizedBox(width: HermesSpace.x2),
        Expanded(
          child: RepaintBoundary(
            child: live
                ? LiveSheen(
                    seconds: liveSeconds,
                    base: colors.textPrimary.withValues(alpha: 0.8),
                    peak: colors.textPrimary,
                    child: text,
                  )
                : text,
          ),
        ),
        if (showClock) ...[
          const SizedBox(width: HermesSpace.x2),
          ActivityTicker(
            active: true,
            clock: widget.clock,
            builder: (context, now) => Text(
              formatTurnClock(now.difference(widget.startedAt!)),
              key: const ValueKey('chat-inline-activity-clock'),
              style: metaStyle,
            ),
          ),
        ],
        if (live) ...[
          if (showClock) Text(' · ', style: metaStyle),
          Text(
            countWords ? s.tk140ToolsCount(widget.steps) : '${widget.steps}',
            key: const ValueKey('chat-inline-activity-count'),
            style: metaStyle,
          ),
        ],
        const SizedBox(width: HermesSpace.x2),
        AnimatedRotation(
          turns: widget.open ? .5 : 0,
          duration: HermesMotion.duration(context, HermesMotion.fast),
          child: Icon(
            Icons.expand_more,
            size: 16,
            color: live ? colors.success : colors.textTertiary,
          ),
        ),
      ],
    );
    }

    final row = LayoutBuilder(
      builder: (context, constraints) => rowFor(constraints.maxWidth),
    );
    return Semantics(
      key: const ValueKey('chat-inline-activity'),
      container: true,
      button: true,
      expanded: widget.open,
      liveRegion: widget.live,
      label: '${widget.spokenLabel ?? widget.label}, ${s.chatLiveSteps(widget.steps)}',
      onTap: widget.onTap,
      onTapHint: widget.open ? s.stepsBarWorkedHide : s.stepsBarWorkedShow,
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(HermesRadius.control),
        child: SizedBox(
          height: HermesSpace.tap,
          child: live
              // The 48 dp target stays; only the card is painted, hugging
              // the bottom so the connector hangs straight from it.
              ? Padding(
                  padding: const EdgeInsets.only(
                    top: HermesSpace.tap - HermesLiveTurn.cardHeight,
                  ),
                  child: DecoratedBox(
                    key: const ValueKey('live-turn-card'),
                    decoration: BoxDecoration(
                      color: colors.success.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(
                        HermesRadius.control,
                      ),
                      border: Border.all(
                        color: colors.success.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HermesSpace.x3,
                      ),
                      child: row,
                    ),
                  ),
                )
              : row,
        ),
      ),
    );
  }
}

/// Keeps the header outside the height animation so its hit target never moves.
class TurnInlineDisclosure extends StatelessWidget {
  const TurnInlineDisclosure({
    required this.open,
    required this.child,
    super.key,
  });
  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final body = SizedBox(width: double.infinity, child: open ? child : null);
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

/// «1:05»: minutes and two-digit seconds, the way the live clock counts.
String formatTurnClock(Duration elapsed) {
  final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Seconds each activity word stays before the next one.
const int kTurnActivityWordSeconds = 4;

/// The rotating word of the pill for [elapsed], from the language's own list.
String turnActivityWord(Strings s, Duration elapsed) {
  final words = [
    s.stepsBarWord1,
    s.stepsBarWord2,
    s.stepsBarWord3,
    s.stepsBarWord4,
    s.stepsBarWord5,
    s.stepsBarWord6,
  ];
  final index =
      (elapsed.isNegative ? 0 : elapsed.inSeconds) ~/ kTurnActivityWordSeconds;
  return words[index % words.length];
}

Widget _capsule(
  BuildContext context, {
  required Widget child,
  VoidCallback? onTap,
}) {
  final colors = Theme.of(context).hermes;
  final chrome = HermesChrome.of(colors);
  return Align(
    alignment: AlignmentDirectional.centerStart,
    widthFactor: 1,
    heightFactor: 1,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: onTap == null ? 0 : HermesSpace.tap,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: 1,
        child: Material(
          color: chrome.fill,
          shape: StadiumBorder(side: BorderSide(color: chrome.line)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3,
                vertical: HermesSpace.x1,
              ),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

/// While the turn runs: a small pill under the bot's name with an activity
/// word that changes every few seconds and the turn's clock, «Pensando · 0:12».
/// Words only, no icon.
class TurnActivityPill extends StatelessWidget {
  const TurnActivityPill({required this.startedAt, this.clock, super.key});

  final DateTime startedAt;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return ActivityTicker(
      active: true,
      clock: clock,
      builder: (context, now) {
        final elapsed = now.difference(startedAt);
        final word = turnActivityWord(s, elapsed);
        final time = formatTurnClock(elapsed);
        return Semantics(
          container: true,
          label: '$word, $time',
          excludeSemantics: true,
          child: _capsule(
            context,
            child: Text(
              '$word · $time',
              key: const ValueKey('turn-activity-pill-text'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TurnType.status,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// When the turn is over: «Trabajó 1:12», which folds and unfolds the turn's
/// steps under it. The chevron turns 180° as the only affordance.
class TurnWorkedPill extends StatelessWidget {
  const TurnWorkedPill({
    required this.label,
    required this.open,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    void tap() {
      HermesHaptics.selection();
      onTap();
    }

    return Semantics(
      container: true,
      button: true,
      expanded: open,
      label: label,
      onTap: tap,
      onTapHint: open ? s.stepsBarWorkedHide : s.stepsBarWorkedShow,
      excludeSemantics: true,
      child: _capsule(
        context,
        onTap: tap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                key: const ValueKey('turn-worked-pill-text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: TurnType.status,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: colors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: HermesSpace.x1),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: HermesMotion.reduced(context)
                  ? Duration.zero
                  : HermesMotion.fast,
              child: Icon(
                Icons.expand_more,
                size: HermesIcon.sm,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
