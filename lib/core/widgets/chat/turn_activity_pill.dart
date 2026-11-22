import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../activity_pill.dart' show ActivityTicker;
import '../chat_turn_activity.dart' show TurnType;
import 'chat_live_icon.dart';
import 'live_motion.dart';
import 'live_turn_window.dart' show LiveSpinnerRing;
import 'turn_receipt_pill.dart';
import '../../theme/live_turn_tokens.dart';
import '../../feedback/haptics.dart';

/// Live, one 48 dp target: it paints the «Trabajando» card of the look
/// approved on 9 nov (mock `turno3.html`): ring, word, the turn's clock and
/// the tool count, always visible (the earlier v4 video showed only a count;
/// the approved mock supersedes it). A settled turn is a quiet receipt row
/// that opens the tool history. Only the live text repaints with the sheen.
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
    this.shortLabel,
    this.failed = false,
    this.glyph,
    this.startedAt,
    this.clock,
    super.key,
  });

  /// The height of the settled row at the default text size: that of the
  /// memory receipt.
  static const double capsuleHeight = TurnReceiptPill.height;

  /// The size the settled line shrinks to before it gives anything up.
  static const double tightFontSize = 12;

  /// [label] with its counts abbreviated, same order and same numbers, for
  /// when the whole line does not fit («Trabajó · 6 cmd · 51 herr.» for
  /// «Trabajó · 6 comandos · Usó 51 herramientas»).
  final String? shortLabel;

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
    final s = Strings.of(context);
    return Semantics(
      key: const ValueKey('chat-inline-activity'),
      container: true,
      button: true,
      expanded: widget.open,
      liveRegion: widget.live,
      label:
          '${widget.spokenLabel ?? widget.label}, ${s.chatLiveSteps(widget.steps)}',
      onTap: _tap,
      onTapHint: widget.open ? s.stepsBarWorkedHide : s.stepsBarWorkedShow,
      excludeSemantics: true,
      child: widget.live ? _runningCard(context) : _settledCapsule(context),
    );
  }

  void _tap() {
    HermesHaptics.selection();
    widget.onTap();
  }

  Widget _caret(BuildContext context, Color color, {double size = 13}) =>
      AnimatedRotation(
        turns: widget.open ? .5 : 0,
        duration: HermesMotion.duration(context, HermesMotion.fast),
        child: Icon(HIcons.expand_more_rounded, size: size, color: color),
      );

  /// The settled turn: the quiet receipt row of the memory receipt and the
  /// self-improvement notice, with the outcome before the line and the
  /// caret that opens the steps after it. No capsule around it.
  Widget _settledCapsule(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final ink = TurnReceiptPill.inkOf(context);
    // In a host that stretches it, the whole width still opens the steps.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _tap,
      child: _settledRow(context, colors, ink),
    );
  }

  Widget _settledRow(
    BuildContext context,
    HermesThemeColors colors,
    Color ink,
  ) {
    return TurnReceiptPill(
      inkKey: const ValueKey('chat-inline-activity-surface'),
      semantics: false,
      onTap: _tap,
      leading: widget.failed
          ? ChatLiveIcon(
              ChatLiveGlyph.error,
              size: HermesIcon.sm,
              color: colors.error,
            )
          : Icon(HIcons.done_rounded, size: HermesIcon.sm, color: ink),
      text: _settledLine(context),
      trailing: _caret(context, ink, size: HermesIcon.sm),
    );
  }

  /// The settled summary, always on one line. It was allowed two and made
  /// the capsule tall and wide beside the reply's actions. Short of room it
  /// first tightens its size, then abbreviates its counts, and only if that
  /// does not fit either ends in an ellipsis; the spoken label keeps the
  /// whole line.
  Widget _settledLine(BuildContext context) {
    final style = TurnReceiptPill.styleOf(context);
    final tight = style.copyWith(fontSize: TurnInlineActivity.tightFontSize);
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        // Measured as the Text below is drawn: over the inherited style.
        final inherited = DefaultTextStyle.of(context).style;
        bool fits(String text, TextStyle style) {
          if (!constraints.maxWidth.isFinite) return true;
          final painter = TextPainter(
            text: TextSpan(text: text, style: inherited.merge(style)),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final fit = painter.width.ceilToDouble() <= constraints.maxWidth;
          painter.dispose();
          return fit;
        }

        final short = widget.shortLabel;
        final (text, chosen) = fits(widget.label, style)
            ? (widget.label, style)
            : fits(widget.label, tight)
            ? (widget.label, tight)
            : (short ?? widget.label, tight);
        return Text(
          text,
          key: const ValueKey('chat-inline-activity-text'),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: chosen,
        );
      },
    );
  }

  Widget _runningCard(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final metaStyle = TextStyle(
      fontSize: 12,
      color: colors.success,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return InkWell(
      onTap: _tap,
      borderRadius: BorderRadius.circular(HermesRadius.control),
      child: SizedBox(
        height: HermesSpace.tap,
        child: Padding(
          // The painted card hugs the bottom of the touch target.
          padding: const EdgeInsets.only(
            top: HermesSpace.tap - HermesLiveTurn.cardHeight,
          ),
          child: DecoratedBox(
            key: const ValueKey('live-turn-card'),
            decoration: BoxDecoration(
              color: colors.success.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(HermesRadius.tag),
              border: Border.all(color: colors.success.withValues(alpha: 0.45)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x3),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final room = constraints.maxWidth;
                  final scaled =
                      room / MediaQuery.textScalerOf(context).scale(1);
                  final showClock =
                      (kInlineActivityShowsClock ||
                          widget.open ||
                          debugInlineClockWhenFolded) &&
                      widget.startedAt != null &&
                      scaled >= HermesLiveTurn.metaWithClock;
                  return Row(
                    children: [
                      const LiveSpinnerRing(),
                      const SizedBox(width: HermesSpace.x2),
                      Expanded(
                        child: RepaintBoundary(
                          child: LiveSheen(
                            seconds: liveSeconds,
                            base: colors.textPrimary.withValues(alpha: 0.8),
                            peak: colors.textPrimary,
                            child: Text(
                              widget.label,
                              key: const ValueKey('chat-inline-activity-text'),
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
                        ),
                      ),
                      // Clock and count may take at most 60% of the card.
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: room * 0.6),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerEnd,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (showClock) ...[
                                const SizedBox(width: HermesSpace.x2),
                                ActivityTicker(
                                  active: true,
                                  clock: widget.clock,
                                  builder: (context, now) => Text(
                                    formatTurnClock(
                                      now.difference(widget.startedAt!),
                                    ),
                                    key: const ValueKey(
                                      'chat-inline-activity-clock',
                                    ),
                                    style: metaStyle,
                                  ),
                                ),
                                Text(' · ', style: metaStyle),
                              ],
                              Text(
                                scaled >= HermesLiveTurn.metaWithWords
                                    ? s.tk140ToolsCount(widget.steps)
                                    : '${widget.steps}',
                                key: const ValueKey(
                                  'chat-inline-activity-count',
                                ),
                                style: metaStyle,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: HermesSpace.x2),
                      _caret(context, colors.success),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// At the end of an answer, keep the history at the message's leading
/// edge. On small screens the actions move above it, leaving the summary
/// directly over its tool list.
class TurnActivityFooter extends StatelessWidget {
  const TurnActivityFooter({
    required this.summary,
    required this.details,
    required this.actions,
    super.key,
  });

  final Widget summary;
  final Widget details;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final controls = Row(
      key: const ValueKey('assistant-footer-actions'),
      mainAxisSize: MainAxisSize.min,
      children: actions,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _FooterHead(children: [summary, controls]),
        details,
      ],
    );
  }
}

/// The summary and the reply's actions: on one row when the summary fits
/// whole beside them, otherwise the actions on a row of their own above and
/// the summary under them with the whole width. A fixed width decided it
/// before, so on a phone a long summary was squeezed beside the actions and
/// lost its end.
class _FooterHead extends MultiChildRenderObjectWidget {
  const _FooterHead({required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFooterHead(Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderFooterHead renderObject,
  ) => renderObject.textDirection = Directionality.of(context);
}

class _FooterHeadParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFooterHead extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FooterHeadParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FooterHeadParentData> {
  _RenderFooterHead(this._textDirection);

  static const double _gap = HermesSpace.x2;

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FooterHeadParentData) {
      child.parentData = _FooterHeadParentData();
    }
  }

  @override
  void performLayout() {
    final summary = firstChild!;
    final controls = childAfter(summary)!;
    final loose = BoxConstraints(maxWidth: constraints.maxWidth);
    // The summary at the whole width says how wide its whole line is.
    summary.layout(loose, parentUsesSize: true);
    controls.layout(loose, parentUsesSize: true);
    final s = summary.size;
    final c = controls.size;
    final ltr = _textDirection != TextDirection.rtl;
    final summaryData = summary.parentData! as _FooterHeadParentData;
    final controlsData = controls.parentData! as _FooterHeadParentData;
    if (s.width + _gap + c.width <= constraints.maxWidth) {
      final height = s.height > c.height ? s.height : c.height;
      final width = s.width + _gap + c.width;
      summaryData.offset = Offset(
        ltr ? 0 : width - s.width,
        (height - s.height) / 2,
      );
      controlsData.offset = Offset(
        ltr ? s.width + _gap : 0,
        (height - c.height) / 2,
      );
      size = constraints.constrain(Size(width, height));
    } else {
      final width = s.width > c.width ? s.width : c.width;
      controlsData.offset = Offset(ltr ? 0 : width - c.width, 0);
      summaryData.offset = Offset(ltr ? 0 : width - s.width, c.height);
      size = constraints.constrain(Size(width, c.height + s.height));
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
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
                HIcons.expand_more_rounded,
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
