import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/theme_contrast.dart';

// The island: the small pill at the top centre of every chat surface (plain
// chats, bot chats, rooms). At rest it carries the NAME and ONE status dot,
// with the still sprite standing on it. When something happens it grows in
// place to say it in ONE line with at most ONE action, and shrinks back.
// The app's notices are shown in it too; on screens without an island they
// keep their top lane, drawn as the same island event.

/// What the island's dot says. Screen readers get the same as words.
enum IslandStatus {
  /// Connected, nothing running.
  idle,

  /// A turn (or background work) is running.
  working,

  /// An approval or a question is waiting.
  needsYou,

  /// The connection dropped and is being recovered.
  reconnecting,

  /// No connection.
  offline,

  /// The last turn failed.
  error,
}

/// How an event is framed. [needsYou] and [error] outrank the rest.
enum IslandTone { info, success, warning, error, needsYou }

extension IslandToneRank on IslandTone {
  /// Who shows first when two events want the island.
  int get rank => switch (this) {
    IslandTone.needsYou => 3,
    IslandTone.error => 2,
    IslandTone.warning => 1,
    IslandTone.success || IslandTone.info => 0,
  };

  /// Announced at once (the others wait for the reader to pause).
  bool get assertive => this == IslandTone.needsYou || this == IslandTone.error;
}

/// The one button of an event.
@immutable
class IslandAction {
  const IslandAction({
    required this.label,
    required this.onPressed,
    this.closes = true,
    this.key,
  });

  /// Key of the drawn button; the island's own when null.
  final Key? key;
  final String label;

  /// Null draws the button disabled.
  final VoidCallback? onPressed;

  /// Whether acting also retires the event (the default).
  final bool closes;
}

/// One thing the island says: a line, and at most one action.
@immutable
class IslandEvent {
  const IslandEvent({
    required this.id,
    required this.line,
    this.detail,
    this.more,
    this.tone = IslandTone.info,
    this.weight,
    this.icon,
    this.tint,
    this.busy = false,
    this.action,
    this.secondary,
    this.trailing,
    this.sticky = false,
    this.duration,
    this.onTap,
    this.onDismissed,
    this.revision = 0,
    this.speaksTone = false,
    this.showDismiss = false,
    this.dismissLabel,
    this.key,
  });

  /// Stable while the same thing is being said (the text may change).
  final String id;

  /// Key of the drawn event, for whoever looks for it by name.
  final Key? key;

  /// What happened, in bold.
  final String line;

  /// What it is about, after a «·», quieter.
  final String? detail;

  /// The rest, shown only when the event is opened with a tap.
  final String? more;
  final IslandTone tone;

  /// Who shows first when two events want the island; the [tone]'s own
  /// rank when null.
  final int? weight;

  /// Glyph in the leading disc; by [tone] when null.
  final IconData? icon;

  /// Colour of the leading disc; by [tone] when null.
  final Color? tint;

  /// The leading disc shows work in progress (reconnecting, a retry).
  final bool busy;
  final IslandAction? action;

  /// A second action, reachable only by opening the event.
  final IslandAction? secondary;

  /// Sits at the end of the line instead of an action (a timer).
  final Widget? trailing;

  /// Stays until acted on or dismissed.
  final bool sticky;

  /// How long a non-sticky event stays; by [tone] when null.
  final Duration? duration;

  /// Tap on the event itself (not its action).
  final VoidCallback? onTap;

  /// The user swiped it away.
  final VoidCallback? onDismissed;

  /// Bump to say again something that was dismissed or had expired.
  final int revision;

  /// Screen readers hear the severity before the line («Error», «Aviso»):
  /// for the app's notices, whose line does not say it.
  final bool speaksTone;

  /// Draws its own way out (a ✕ that says [dismissLabel]) next to the
  /// action: for what stays until answered, where a swipe nobody was told
  /// about is not enough. With an action too, a line that cannot hold the
  /// title, the action and the ✕ whole becomes two (see [IslandEventTile]).
  final bool showDismiss;
  final String? dismissLabel;

  /// Whether [onTap] or opening the event answers a tap.
  bool get opens => more != null || secondary != null;

  /// Who shows first: needs-you, then what failed, then the rest.
  int get rank => weight ?? tone.rank;

  Duration get stay =>
      duration ??
      (action != null
          ? const Duration(seconds: 8)
          : switch (tone) {
              IslandTone.success => const Duration(seconds: 3),
              IslandTone.info => const Duration(seconds: 4),
              IslandTone.warning ||
              IslandTone.error ||
              IslandTone.needsYou => const Duration(seconds: 6),
            });

  /// What a screen reader hears, without having to open the event: the
  /// severity when [speaksTone], the line and all the rest of it.
  String spoken(Strings? strings) => [
    if (speaksTone) ?_toneWord(strings, tone),
    line,
    ?(more ?? detail),
  ].join('. ');
}

String? _toneWord(Strings? strings, IslandTone tone) => switch (tone) {
  IslandTone.success => strings?.noticeKindSuccess ?? 'Success',
  IslandTone.warning => strings?.noticeKindWarning ?? 'Warning',
  IslandTone.error => strings?.noticeKindError ?? 'Error',
  IslandTone.info || IslandTone.needsYou => null,
};

/// The app's strings, or null under an app that did not install them (the
/// notices also show there, with their words in English).
Strings? _strings(BuildContext context) =>
    Localizations.of<Strings>(context, Strings);

/// Sizes shared by every island shape.
abstract final class IslandMetrics {
  /// The pill at rest: name and dot.
  static const double restHeight = 36;

  /// The island's line as the first line of the card it opens.
  static const double flatHeight = 44;

  /// An event: one line and one action (a 48 dp target).
  static const double eventHeight = 48;
  static const double minWidth = 78;
  static const double radius = 24;
  static const double maxWidth = 520;

  /// How far the one waiting behind peeks out below.
  static const double peek = 6;
}

/// The island's surface: the one tone of everything that floats in front
/// of the page ([HermesChrome]). Every island shape (rest, event, the one
/// waiting behind, the notice lane) is painted through here and nowhere
/// else.
({Color fill, Color solid, Color line, List<BoxShadow> shadow}) _islandSurface(
  HermesThemeColors colors,
) {
  final chrome = HermesChrome.of(colors);
  return (
    fill: chrome.fill,
    solid: chrome.opaque,
    line: chrome.line,
    shadow: chrome.shadow,
  );
}

Color _toneColor(HermesThemeColors colors, IslandTone tone) => switch (tone) {
  IslandTone.info => colors.accent,
  IslandTone.success => colors.success,
  IslandTone.warning || IslandTone.needsYou => colors.warning,
  IslandTone.error => colors.error,
};

/// The dot's colour for each state, from the theme's own tokens.
Color islandStatusColor(HermesThemeColors colors, IslandStatus status) =>
    switch (status) {
      IslandStatus.idle => colors.success,
      IslandStatus.working => colors.accent,
      IslandStatus.needsYou || IslandStatus.reconnecting => colors.warning,
      IslandStatus.offline || IslandStatus.error => colors.error,
    };

/// The dot's meaning in words, for screen readers.
String islandStatusLabel(Strings? strings, IslandStatus status) =>
    switch (status) {
      IslandStatus.idle => strings?.commonConnected ?? 'Connected',
      IslandStatus.working => strings?.roomStateWorking ?? 'Working',
      IslandStatus.needsYou => strings?.roomStateNeedsYou ?? 'Needs you',
      IslandStatus.reconnecting =>
        strings?.islandReconnecting ?? 'Reconnecting…',
      IslandStatus.offline => strings?.fh1215Offline ?? 'No connection',
      IslandStatus.error => strings?.noticeKindError ?? 'Error',
    };

/// The rounded floating shape of the island and of every event.
class IslandSurface extends StatelessWidget {
  const IslandSurface({
    required this.child,
    this.tone,
    this.raised = false,
    this.behind = false,
    this.marked = false,
    super.key,
  });

  final Widget child;

  /// Frames the shape: amber when it needs you, red when something failed.
  final IslandTone? tone;

  /// It has something to open: its hairline takes the accent.
  final bool marked;

  /// An event is solid: nothing of the conversation shows through its
  /// line. At rest the island is as translucent as every floating piece.
  final bool raised;

  /// The one waiting behind: flatter and quieter.
  final bool behind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final surface = _islandSurface(colors);
    final framed = switch (tone) {
      IslandTone.needsYou => colors.warning.withValues(alpha: 0.7),
      IslandTone.error => colors.error.withValues(alpha: 0.6),
      _ => marked ? colors.accent.withValues(alpha: 0.55) : null,
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(IslandMetrics.radius),
    );
    // The soft shadow is the chrome's own, static: it never animates.
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: behind ? null : surface.shadow,
      ),
      child: Material(
        color: behind
            ? Color.alphaBlend(
                colors.background.withValues(alpha: 0.35),
                surface.solid,
              )
            : (raised ? surface.solid : surface.fill),
        surfaceTintColor: Colors.transparent,
        animationDuration: Motion.duration(context, Motion.base),
        clipBehavior: Clip.antiAlias,
        shape: shape.copyWith(
          side: BorderSide(
            color: framed ?? surface.line,
            width: framed == null ? 1 : 1.2,
          ),
        ),
        child: child,
      ),
    );
  }
}

/// The state dot. Reconnecting is a ring, so it is told from «needs you»
/// without relying on colour.
class IslandStatusDot extends StatelessWidget {
  const IslandStatusDot({required this.status, this.size = 8, super.key});

  final IslandStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = islandStatusColor(Theme.of(context).hermes, status);
    final ring = status == IslandStatus.reconnecting;
    return SizedBox.square(
      key: ValueKey('island-dot-${status.name}'),
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: ring ? null : color,
          border: ring ? Border.all(color: color, width: 2) : null,
        ),
      ),
    );
  }
}

/// One event, drawn: its disc, its line and its action. A tap opens it when
/// there is more to read or a second action; a swipe up dismisses it.
///
/// It has no surface of its own: the island (or the notice lane) gives it
/// one and animates the size around it.
class IslandEventTile extends StatefulWidget {
  const IslandEventTile({
    required this.event,
    this.onDismiss,
    this.onPlainTap,
    this.onLongPress,
    this.onActed,
    this.onHold,
    this.waiting = 0,
    this.actionKey = const ValueKey('island-action'),
    super.key,
  });

  final IslandEvent event;

  /// Swiped up, or the screen reader's dismiss action.
  final VoidCallback? onDismiss;

  /// Tapped, with nothing of its own to open.
  final VoidCallback? onPlainTap;
  final VoidCallback? onLongPress;

  /// An action that closes the event was pressed.
  final VoidCallback? onActed;

  /// Opened (true) or closed again (false): an owner that expires the event
  /// waits while it is being read.
  final ValueChanged<bool>? onHold;

  /// Events waiting behind this one, for the spoken label.
  final int waiting;
  final Key actionKey;

  @override
  State<IslandEventTile> createState() => IslandEventTileState();
}

class IslandEventTileState extends State<IslandEventTile> {
  bool _open = false;
  bool _cut = false;
  bool _announced = false;
  double _pulled = 0;

  /// Whether the event is opened (its whole text, its second action).
  bool get isOpen => _open;

  bool get _canOpen => widget.event.opens || _cut;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_announced) return;
    _announced = true;
    final event = widget.event;
    if (!event.tone.assertive) return;
    // Needs-you and errors interrupt; the rest are a polite live region.
    final view = View.maybeOf(context);
    if (view == null) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        event.spoken(_strings(context)),
        Directionality.of(context),
        assertiveness: Assertiveness.assertive,
      ),
    );
  }

  void _setOpen(bool value) {
    if (_open == value) return;
    setState(() => _open = value);
    widget.onHold?.call(value);
  }

  void _tap() {
    final event = widget.event;
    if (_open) return _setOpen(false);
    if (event.onTap != null) return event.onTap!();
    if (_canOpen) return _setOpen(true);
    widget.onPlainTap?.call();
  }

  void _act(IslandAction action) {
    action.onPressed?.call();
    if (action.closes) widget.onActed?.call();
  }

  void _dragEnd(DragEndDetails details) {
    final up = _pulled;
    _pulled = 0;
    if (widget.onDismiss == null) return;
    if (up < -24 || (details.primaryVelocity ?? 0) < -250) {
      widget.onDismiss!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final strings = _strings(context);
    final event = widget.event;
    final scaler = MediaQuery.textScalerOf(context);
    final bigText = scaler.scale(13.5) / 13.5 > 1.3;
    final tint = event.tint ?? _toneColor(colors, event.tone);
    final surface = _islandSurface(colors);
    final discFill = Color.alphaBlend(
      tint.withValues(alpha: 0.16),
      surface.solid,
    );
    final glyph = ThemeContrast.adjustForContrast(tint, [
      discFill,
    ], minimum: 3.0);
    final disc = _EventDisc(
      fill: discFill,
      glyph: glyph,
      icon: event.icon ?? _toneIcon(event.tone),
      busy: event.busy,
    );
    final lineStyle = TextStyle(
      fontSize: 13.5,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: colors.textPrimary,
    );
    final quiet = lineStyle.copyWith(
      fontWeight: FontWeight.w400,
      color: colors.textSecondary,
    );
    final span = TextSpan(
      style: lineStyle,
      children: [
        TextSpan(text: event.line),
        if (event.detail != null)
          TextSpan(text: ' · ${event.detail}', style: quiet),
      ],
    );
    final action = event.action;
    final rest = event.more ?? event.detail;
    final waiting = widget.waiting;
    final label = [
      event.spoken(strings),
      if (waiting > 0) strings?.islandWaiting(waiting) ?? '+$waiting',
    ].join('. ');
    final dismiss = widget.onDismiss;
    final dismissLabel =
        event.dismissLabel ?? strings?.inAppDismiss ?? 'Dismiss';

    // The words are ONE node (a live region; needs-you and errors were
    // announced at once instead); each button is its own node next to it.
    Widget spoken(Widget child) => Semantics(
      container: true,
      liveRegion: !event.tone.assertive,
      button: true,
      label: label,
      onTap: _tap,
      excludeSemantics: true,
      child: child,
    );

    Widget button(
      IslandAction a, {
      required bool lead,
      Key? key,
      double maxWidth = 190,
      bool whole = false,
    }) => _EventButton(
      key: key,
      action: a,
      maxWidth: maxWidth,
      whole: whole,
      emphasised: lead && event.tone == IslandTone.needsYou,
      onPressed: a.onPressed == null ? null : () => _act(a),
    );

    // An event that offers its own way out draws it, always within reach.
    final Widget? dismissControl = event.showDismiss && dismiss != null
        ? _EventDismiss(label: dismissLabel, onPressed: dismiss)
        : null;

    final Widget body;
    if (_open) {
      // Opened it shows the whole text, in the room there is: never down
      // to the composer, whatever the text size or the keyboard.
      final media = MediaQuery.of(context);
      final room = (media.size.height - media.viewInsets.bottom) * 0.36;
      final hasButtons =
          action != null || event.secondary != null || dismissControl != null;
      final chrome = 17.0 + (hasButtons ? 48 : 5);
      final fits = ((room - chrome) / (scaler.scale(13.5) * 1.3)).floor();
      final lines = math.max(2, math.min(12, fits));
      final lineRows = rest == null ? lines : math.min(2, lines - 1);
      body = Padding(
        padding: const EdgeInsets.fromLTRB(11, 11, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                disc,
                const SizedBox(width: 9),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3, right: 6),
                    child: spoken(
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.line,
                            key: const ValueKey('island-event-line'),
                            maxLines: lineRows,
                            overflow: TextOverflow.ellipsis,
                            style: lineStyle,
                          ),
                          if (rest != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              rest,
                              key: const ValueKey('island-event-more'),
                              maxLines: lines - lineRows,
                              overflow: TextOverflow.ellipsis,
                              style: quiet,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (hasButtons)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (event.secondary case final second?)
                      button(
                        second,
                        lead: false,
                        key: second.key ?? const ValueKey('island-secondary'),
                      ),
                    if (action != null)
                      button(
                        action,
                        lead: true,
                        key: action.key ?? widget.actionKey,
                      ),
                    ?dismissControl,
                  ],
                ),
              )
            else
              const SizedBox(height: 5),
          ],
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, box) {
          // Little room and large text: the disc gives way first, then the
          // line ellipsises. The action is never the one that disappears.
          final tight = bigText && box.maxWidth < 320;
          // Its title, its action and its own way out: when the three do
          // not fit whole on one line the island grows a second one (the
          // title above, the action and the ✕ below) instead of cutting the
          // title or the action's label. What it is about stays a tap away.
          final fitsOneLine =
              dismissControl == null ||
              action == null ||
              _fitsOneLine(
                context,
                title: event.line,
                titleStyle: lineStyle,
                label: action.label,
                lead: tight ? 14 : 11 + 26 + 9,
                maxWidth: box.maxWidth,
                scaler: scaler,
              );
          if (!fitsOneLine) {
            _cut = rest != null;
            return Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(11, 9, 2, 0),
              child: Column(
                key: const ValueKey('island-event-two-lines'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!tight) ...[disc, const SizedBox(width: 9)],
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(
                            top: 3,
                            end: 9,
                          ),
                          child: spoken(
                            Text(
                              event.line,
                              key: const ValueKey('island-event-line'),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: lineStyle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        button(
                          action,
                          lead: true,
                          key: action.key ?? widget.actionKey,
                          maxWidth: box.maxWidth.isFinite
                              ? box.maxWidth - 13
                              : 320,
                          whole: true,
                        ),
                        dismissControl,
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: IslandMetrics.eventHeight,
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: tight ? 14 : 11,
                end: action != null || dismissControl != null ? 2 : 16,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!tight) ...[disc, const SizedBox(width: 9)],
                  Flexible(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // Measured as it will be drawn (the page's own
                        // font): a line that does not fit opens with a tap.
                        final painter = TextPainter(
                          text: TextSpan(
                            style: DefaultTextStyle.of(context).style,
                            children: [span],
                          ),
                          maxLines: 1,
                          textScaler: scaler,
                          textDirection: Directionality.of(context),
                        )..layout(maxWidth: constraints.maxWidth);
                        _cut = painter.didExceedMaxLines;
                        painter.dispose();
                        const key = ValueKey('island-event-line');
                        return spoken(
                          event.detail == null
                              ? Text(
                                  event.line,
                                  key: key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: lineStyle,
                                )
                              : Text.rich(
                                  span,
                                  key: key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        );
                      },
                    ),
                  ),
                  if (event.trailing case final trailing?) ...[
                    const SizedBox(width: 9),
                    ExcludeSemantics(child: trailing),
                  ],
                  // There is more behind a tap: its text, a second action.
                  if (event.opens && event.onTap == null)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 2),
                      child: Icon(
                        Icons.expand_more_rounded,
                        key: const ValueKey('island-event-opens'),
                        size: 18,
                        color: colors.textSecondary,
                      ),
                    ),
                  if (action != null) ...[
                    const SizedBox(width: 3),
                    button(
                      action,
                      lead: true,
                      key: action.key ?? widget.actionKey,
                      // With its ✕ it is on this line only because it
                      // fits whole.
                      maxWidth: dismissControl != null
                          ? (box.maxWidth.isFinite ? box.maxWidth : 320)
                          : box.maxWidth.isFinite
                          ? math.max(72.0, box.maxWidth * 0.55)
                          : 190,
                    ),
                  ],
                  ?dismissControl,
                ],
              ),
            ),
          );
        },
      );
    }

    return Semantics(
      container: true,
      explicitChildNodes: true,
      onDismiss: dismiss,
      customSemanticsActions: dismiss == null
          ? null
          : {CustomSemanticsAction(label: dismissLabel): dismiss},
      child: GestureDetector(
        key: const ValueKey('island-event'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _tap,
        onLongPress: widget.onLongPress,
        onVerticalDragUpdate: (d) => _pulled += d.delta.dy,
        onVerticalDragEnd: _dragEnd,
        onVerticalDragCancel: () => _pulled = 0,
        child: body,
      ),
    );
  }
}

/// Whether [title], the action's [label] and the ✕ fit whole on one line
/// [maxWidth] wide, measured as they will be drawn.
bool _fitsOneLine(
  BuildContext context, {
  required String title,
  required TextStyle titleStyle,
  required String label,
  required double lead,
  required double maxWidth,
  required TextScaler scaler,
}) {
  if (!maxWidth.isFinite) return true;
  final base = DefaultTextStyle.of(context).style;
  final direction = Directionality.of(context);
  double wide(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: base.merge(style)),
      maxLines: 1,
      textScaler: scaler,
      textDirection: direction,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  final action = math.max(
    48.0,
    wide(label, _EventButton.labelStyle) + _EventButton.chrome,
  );
  // The gap before the action, the ✕ and the line's end inset.
  return lead +
          wide(title, titleStyle) +
          3 +
          action +
          _EventDismiss.extent +
          2 <=
      maxWidth;
}

IconData _toneIcon(IslandTone tone) => switch (tone) {
  IslandTone.info => Icons.info_outline_rounded,
  IslandTone.success => Icons.check_rounded,
  IslandTone.warning => Icons.warning_amber_rounded,
  IslandTone.error => Icons.error_outline_rounded,
  IslandTone.needsYou => Icons.help_outline_rounded,
};

class _EventDisc extends StatelessWidget {
  const _EventDisc({
    required this.fill,
    required this.glyph,
    required this.icon,
    required this.busy,
  });

  final Color fill;
  final Color glyph;
  final IconData icon;
  final bool busy;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      key: const ValueKey('island-event-disc'),
      dimension: 26,
      child: DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: fill),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (busy)
              Positioned.fill(
                child: CircularProgressIndicator(
                  // Reduced motion: a still arc instead of a turning one.
                  value: Motion.reduced(context) ? 0.28 : null,
                  strokeWidth: 1.8,
                  color: glyph,
                ),
              ),
            Icon(icon, size: 15, color: glyph),
          ],
        ),
      ),
    ),
  );
}

/// An event's button: a compact pill inside a 48 dp target.
class _EventButton extends StatelessWidget {
  const _EventButton({
    required this.action,
    required this.emphasised,
    required this.onPressed,
    this.maxWidth = 190,
    this.whole = false,
    super.key,
  });

  /// The label as it is drawn (its colour apart), for whoever measures it.
  static const TextStyle labelStyle = TextStyle(
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w700,
  );

  /// What the pill and its target add around the label, on both sides.
  static const double chrome = 2 * (4 + 13);

  final IslandAction action;
  final bool emphasised;
  final VoidCallback? onPressed;
  final double maxWidth;

  /// Never cut: a label wider than [maxWidth] takes a second line.
  final bool whole;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final enabled = onPressed != null;
    final ink = !enabled
        ? colors.textDisabled
        : emphasised
        ? colors.onAccent
        : colors.textPrimary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: action.label,
      excludeSemantics: true,
      onTap: onPressed,
      child: InkWell(
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 48,
            minHeight: 48,
            maxWidth: math.max(48, maxWidth),
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: const StadiumBorder(),
                  color: emphasised && enabled
                      ? colors.accent
                      : colors.surfaceVariant,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 7,
                  ),
                  child: Text(
                    action.label,
                    maxLines: whole ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle.copyWith(color: ink),
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

/// An event's own way out: a quiet ✕ in a 48 dp target.
class _EventDismiss extends StatelessWidget {
  const _EventDismiss({required this.label, required this.onPressed});

  static const double extent = 48;

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: InkWell(
        key: const ValueKey('island-event-dismiss'),
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: extent,
          child: Icon(
            Icons.close_rounded,
            size: 18,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// The app's notices, as the island sees them. Implemented by the notice
/// lane, which keeps owning their queue, priorities and timers.
abstract interface class IslandNoticeFeed implements Listenable {
  /// The notice to show now, or null.
  IslandEvent? get current;

  /// Notices waiting behind [current].
  int get waiting;

  /// Wraps the drawn event in the app's notice widget.
  Widget present(BuildContext context, IslandEvent event, Widget tile);

  void dismiss(IslandEvent event);

  /// The reader opened [event] (true) or closed it again.
  void hold(IslandEvent event, bool held);
}

/// The islands on screen that show the app's notices. While one of them is
/// in view (its route on top) the notice lane draws nothing of its own.
abstract final class IslandPresenters {
  static final List<(Object, bool Function())> _claims = [];

  /// Bumps when an island comes, goes, or is covered or uncovered. Never in
  /// the middle of a frame: islands claim and release while the tree is
  /// being built, and the listeners (the lane, the other islands) rebuild.
  static final ValueNotifier<int> revision = ValueNotifier(0);
  static bool _telling = false;

  static void claim(Object owner, bool Function() inView) {
    _claims
      ..removeWhere((c) => identical(c.$1, owner))
      ..add((owner, inView));
    changed();
  }

  static void release(Object owner) {
    final before = _claims.length;
    _claims.removeWhere((c) => identical(c.$1, owner));
    if (_claims.length != before) changed();
  }

  /// An island's view changed (covered by a route, uncovered).
  static void changed() {
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.idle) {
      revision.value++;
      return;
    }
    if (_telling) return;
    _telling = true;
    binding.addPostFrameCallback((_) {
      _telling = false;
      revision.value++;
    });
  }

  static Object? get _presenter {
    for (final claim in _claims.reversed) {
      if (claim.$2()) return claim.$1;
    }
    return null;
  }

  /// Whether some island is showing the notices now.
  static bool get any => _presenter != null;

  /// Whether [owner] is the island showing them (the newest one in view).
  static bool presents(Object owner) => identical(_presenter, owner);

  @visibleForTesting
  static void resetForTesting() => _claims.clear();
}

/// The room an island leaves above itself for the face that stands on it.
/// That room answers the island's tap too. Set by the floating header.
class IslandHeadroom extends InheritedWidget {
  const IslandHeadroom({required this.height, required super.child, super.key});

  final double height;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IslandHeadroom>()?.height ?? 0;

  @override
  bool updateShouldNotify(IslandHeadroom oldWidget) =>
      height != oldWidget.height;
}

/// The island of a chat surface.
///
/// At rest: [name] after one [status] dot. A tap (also on the face that
/// stands on it, see [headroom]) calls [onTap]. While an event shows, the
/// island is that event: the events of this conversation ([events], in the
/// caller's order of importance) and the app's notices ([notices]) share it
/// one at a time, the rest waiting behind with a «+1».
class ChatIsland extends StatefulWidget {
  const ChatIsland({
    required this.name,
    required this.status,
    this.events = const [],
    this.notices,
    this.statusDetail,
    this.trailing,
    this.headroom,
    this.onTap,
    this.onLongPress,
    this.hint,
    this.restKey,
    this.semanticsName,
    this.mark,
    this.open = false,
    this.flat = false,
    super.key,
  });

  final String name;
  final IslandStatus status;

  /// What the island has to open, in a few words after the name («4 en
  /// marcha»), with a chevron: the invitation to tap it. Null: it is only
  /// the name.
  final String? mark;

  /// What [mark] announces is open: the chevron points back up.
  final bool open;

  /// Only the line, with no shape of its own: the first line of the card
  /// the island opens, which repeats it (and gives it to a notice that
  /// arrives meanwhile).
  final bool flat;

  /// Spoken after the state at rest: what is running, for a screen reader.
  final String? statusDetail;

  /// What this conversation has to say now. An event stays in this list for
  /// as long as it is true; the island decides when its words have been
  /// shown long enough.
  final List<IslandEvent> events;

  /// The app's notices; null keeps them out of this island.
  final IslandNoticeFeed? notices;

  /// After the name at rest (the running turn's timer).
  final Widget? trailing;

  /// Height above the pill that also answers a tap: where the face stands.
  /// Null takes the [IslandHeadroom] around it.
  final double? headroom;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? hint;

  /// Key of the row at rest.
  final Key? restKey;

  /// Spoken instead of [name] (a room adds who is in it).
  final String? semanticsName;

  /// The island pill's rect (without its headroom) under [root], in global
  /// coordinates; null when there is no island there.
  static Rect? surfaceRectIn(BuildContext? root) {
    if (root is! Element) return null;
    Rect? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget is IslandSurface &&
          element.widget.key == _surfaceKey) {
        final box = element.renderObject;
        if (box is RenderBox && box.hasSize && box.attached) {
          found = box.localToGlobal(Offset.zero) & box.size;
        }
        return;
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  static const Key _surfaceKey = ValueKey('island');

  @override
  State<ChatIsland> createState() => ChatIslandState();
}

class ChatIslandState extends State<ChatIsland> {
  /// Events already said (expired or dismissed): id → revision.
  final Map<String, int> _said = {};
  Timer? _expiry;
  IslandEvent? _front;
  bool _frontIsNotice = false;
  String? _frontKey;
  int _waiting = 0;
  bool _inView = false;
  bool _held = false;

  /// The notice the reader opened here: its lane waits for it until it is
  /// closed again, or until this island stops showing it.
  IslandEvent? _heldNotice;

  /// The event shown now, or null at rest.
  IslandEvent? get front => _front;

  /// How many wait behind [front].
  int get waiting => _waiting;

  @override
  void initState() {
    super.initState();
    final notices = widget.notices;
    if (notices != null) {
      IslandPresenters.claim(this, () => _inView);
      notices.addListener(_onChange);
    }
    IslandPresenters.revision.addListener(_onChange);
    _reconcile();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inView =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (inView == _inView) return;
    _inView = inView;
    // Covered by a route or back on top: the notices move to the top lane
    // or into this island.
    if (widget.notices != null) IslandPresenters.changed();
    _reconcile();
  }

  @override
  void didUpdateWidget(ChatIsland oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = oldWidget.notices, now = widget.notices;
    if (!identical(was, now)) {
      was?.removeListener(_onChange);
      now?.addListener(_onChange);
      if (now == null) {
        IslandPresenters.release(this);
      } else if (was == null) {
        IslandPresenters.claim(this, () => _inView);
      }
    }
    _reconcile();
  }

  @override
  void dispose() {
    _inView = false;
    _expiry?.cancel();
    _releaseHeldNotice();
    widget.notices?.removeListener(_onChange);
    IslandPresenters.revision.removeListener(_onChange);
    // The lane takes the notices back.
    IslandPresenters.release(this);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(_reconcile);
  }

  static String _keyOf(IslandEvent e, {required bool notice}) =>
      '${notice ? 'n' : 'e'}:${e.id}#${e.revision}';

  /// Picks what the island shows. One at a time: the app's notice unless a
  /// sticky event of this conversation outranks a sticky notice; what stays
  /// waits behind.
  void _reconcile() {
    final events = widget.events;
    _said.removeWhere(
      (id, revision) =>
          !events.any((e) => e.id == id && e.revision == revision),
    );
    final own = [
      for (final e in events)
        if (_said[e.id] != e.revision) e,
    ];
    IslandEvent? top;
    for (final e in own) {
      if (top == null || e.rank > top.rank) top = e;
    }
    final feed = widget.notices;
    final presenting = feed != null && IslandPresenters.presents(this);
    final notice = presenting ? feed.current : null;
    final IslandEvent? front;
    final bool isNotice;
    if (notice != null &&
        (top == null ||
            !notice.sticky ||
            !top.sticky ||
            notice.rank >= top.rank)) {
      front = notice;
      isNotice = true;
    } else {
      front = top;
      isNotice = false;
    }
    // A passing line of this conversation («Trabajando», who replies in a
    // room) is said when it comes or not at all: it never queues up behind
    // something else to be said late. What stays does wait its turn.
    var behind = 0;
    for (final e in own) {
      if (identical(e, front)) continue;
      if (e.sticky) {
        behind++;
      } else {
        _said[e.id] = e.revision;
      }
    }
    if (notice != null) {
      behind += (isNotice ? 0 : 1) + (presenting ? feed.waiting : 0);
    }
    _waiting = front == null ? 0 : behind;
    _front = front;
    _frontIsNotice = isNotice;
    final key = front == null ? null : _keyOf(front, notice: isNotice);
    if (key == _frontKey) return;
    _frontKey = key;
    _held = false;
    _releaseHeldNotice();
    _armExpiry();
  }

  /// Something else has the island now: the notice that was being read
  /// goes back to its own clock. After the frame, because its lane rebuilds.
  void _releaseHeldNotice() {
    final held = _heldNotice;
    final feed = widget.notices;
    _heldNotice = null;
    if (held == null || feed == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => feed.hold(held, false));
  }

  /// An event of this conversation that does not stay expires here; the
  /// app's notices are timed by their own lane.
  void _armExpiry() {
    _expiry?.cancel();
    _expiry = null;
    final front = _front;
    if (front == null || _frontIsNotice || front.sticky || _held) return;
    final key = _frontKey;
    _expiry = Timer(front.stay, () {
      if (!mounted || key != _frontKey) return;
      setState(() {
        _said[front.id] = front.revision;
        _reconcile();
      });
    });
  }

  void _dismiss() {
    final front = _front;
    if (front == null) return;
    if (_frontIsNotice) {
      widget.notices?.dismiss(front);
      return;
    }
    setState(() {
      _said[front.id] = front.revision;
      _reconcile();
    });
    front.onDismissed?.call();
  }

  void _acted() {
    final front = _front;
    if (front == null || _frontIsNotice) return;
    setState(() {
      _said[front.id] = front.revision;
      _reconcile();
    });
  }

  void _hold(bool held) {
    final front = _front;
    if (front == null) return;
    if (_frontIsNotice) {
      _heldNotice = held ? front : null;
      widget.notices?.hold(front, held);
      return;
    }
    _held = held;
    _armExpiry();
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings(context);
    final front = _front;

    final Widget content;
    if (front == null) {
      content = _IslandRest(
        key: widget.restKey ?? const ValueKey('island-rest'),
        name: widget.name,
        status: widget.status,
        trailing: widget.trailing,
        mark: widget.mark,
        open: widget.open,
      );
    } else {
      final tile = IslandEventTile(
        key: ValueKey(_frontKey),
        event: front,
        waiting: _waiting,
        onDismiss: _dismiss,
        onPlainTap: _frontIsNotice ? _dismiss : widget.onTap,
        onLongPress: widget.onLongPress,
        onActed: _acted,
        onHold: _hold,
        actionKey: _frontIsNotice
            ? const ValueKey('hermes-notice-action')
            : const ValueKey('island-action'),
      );
      content = _frontIsNotice
          ? widget.notices!.present(context, front, tile)
          : front.key == null
          ? tile
          : KeyedSubtree(key: front.key, child: tile);
    }

    final pill = IslandShell(
      surfaceKey: ChatIsland._surfaceKey,
      contentKey: ValueKey(_frontKey ?? 'rest'),
      tone: front?.tone,
      raised: front != null,
      marked: front == null && widget.mark != null,
      waiting: _waiting,
      child: content,
    );

    final name = widget.semanticsName ?? widget.name;
    final statusLabel = islandStatusLabel(strings, widget.status);
    final rest = front == null;
    final tappable = widget.onTap != null;
    final restLabel = [
      name,
      statusLabel,
      ?widget.statusDetail,
      ?widget.mark,
    ].join(', ');

    if (widget.flat) {
      return Semantics(
        container: true,
        explicitChildNodes: !rest,
        header: rest,
        button: rest && tappable,
        label: rest ? restLabel : null,
        hint: rest && tappable ? widget.hint : null,
        onTap: rest ? widget.onTap : null,
        excludeSemantics: rest,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: rest ? widget.onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: IslandMetrics.flatHeight,
            ),
            child: Center(heightFactor: 1, child: content),
          ),
        ),
      );
    }

    // At rest the whole box is ONE button: the pill and the room above it
    // where the face stands. While an event shows, the pill is the event
    // (its own nodes and gestures) and only the face answers [onTap]. The
    // widgets around the pill are the same in both cases, so the pill keeps
    // its state and its size animates from one to the other.
    final headroom = widget.headroom ?? IslandHeadroom.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: IslandMetrics.maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (headroom > 0)
            GestureDetector(
              key: const ValueKey('island-headroom'),
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              child: SizedBox(width: IslandMetrics.minWidth, height: headroom),
            ),
          Semantics(
            container: true,
            explicitChildNodes: !rest,
            header: rest,
            button: rest && tappable,
            label: rest ? restLabel : null,
            hint: rest && tappable ? widget.hint : null,
            onTap: rest ? widget.onTap : null,
            onLongPress: rest ? widget.onLongPress : null,
            excludeSemantics: rest,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: rest ? widget.onTap : null,
              onLongPress: rest ? widget.onLongPress : null,
              child: pill,
            ),
          ),
        ],
      ),
    );
  }
}

/// The island's shape around [child]: the surface, whose size follows the
/// content in ONE motion (with animations off it just switches), the next
/// event peeking out behind it and the «+1» that counts who waits.
class IslandShell extends StatelessWidget {
  const IslandShell({
    required this.child,
    required this.contentKey,
    this.tone,
    this.raised = false,
    this.marked = false,
    this.waiting = 0,
    this.surfaceKey,
    super.key,
  });

  final Widget child;

  /// Changes when the island has something else to show: the new content
  /// fades in while the surface takes its size.
  final Key contentKey;
  final IslandTone? tone;
  final bool raised;
  final bool marked;
  final int waiting;
  final Key? surfaceKey;

  @override
  Widget build(BuildContext context) {
    final reduce = Motion.reduced(context);
    final colors = Theme.of(context).hermes;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: IslandMetrics.minWidth),
      child: _FadeIn(
        key: contentKey,
        duration: reduce ? Duration.zero : Motion.base,
        child: child,
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        if (waiting > 0)
          const Positioned(
            left: 12,
            right: 12,
            top: 10,
            bottom: -IslandMetrics.peek,
            child: IgnorePointer(
              child: IslandSurface(
                key: ValueKey('island-behind'),
                behind: true,
                child: SizedBox.expand(),
              ),
            ),
          ),
        IslandSurface(
          key: surfaceKey,
          tone: tone,
          raised: raised,
          marked: marked,
          // With animations off the surface simply IS its content's size:
          // no size animation at all (not one of zero length).
          child: reduce
              ? content
              : AnimatedSize(
                  duration: Motion.base,
                  curve: Motion.size,
                  alignment: Alignment.topCenter,
                  child: content,
                ),
        ),
        if (waiting > 0)
          Positioned(
            right: 18,
            bottom: -10,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: _WaitingBadge(count: waiting, colors: colors),
              ),
            ),
          ),
      ],
    );
  }
}

/// The island at rest: the dot, the name and, while a turn runs, its timer.
class _IslandRest extends StatelessWidget {
  const _IslandRest({
    required this.name,
    required this.status,
    this.trailing,
    this.mark,
    this.open = false,
    super.key,
  });

  final String name;
  final IslandStatus status;
  final Widget? trailing;
  final String? mark;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final mark = this.mark;
    if (mark != null) {
      // The count never gives way to the name: where the two do not fit,
      // the name is cut first and then the count is drawn a little smaller,
      // whole. Never an overflow.
      return LayoutBuilder(
        builder: (context, constraints) => _row(
          colors,
          markRoom: constraints.maxWidth.isFinite
              ? (constraints.maxWidth - _restPadding * 2 - 28).clamp(
                  0.0,
                  double.infinity,
                )
              : null,
        ),
      );
    }
    return _row(colors);
  }

  static const double _restPadding = 14;

  Widget _row(HermesThemeColors colors, {double? markRoom}) {
    final mark = this.mark;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: IslandMetrics.restHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _restPadding,
          vertical: 4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IslandStatusDot(status: status),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                name,
                key: const ValueKey('island-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            if (mark != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: markRoom ?? double.infinity,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.textSecondary.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const SizedBox.square(dimension: 3),
                        ),
                      ),
                      Text(
                        mark,
                        key: const ValueKey('island-mark'),
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: colors.accentText,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        open
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        key: const ValueKey('island-chevron'),
                        size: 18,
                        color: colors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// «+1»: how many events wait behind the one shown.
class _WaitingBadge extends StatelessWidget {
  const _WaitingBadge({required this.count, required this.colors});

  final int count;
  final HermesThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final surface = _islandSurface(colors);
    return Container(
      key: const ValueKey('island-waiting'),
      height: 19,
      constraints: const BoxConstraints(minWidth: 26),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: Color.alphaBlend(
          colors.surfaceVariant.withValues(alpha: 0.9),
          surface.solid,
        ),
        shape: StadiumBorder(side: BorderSide(color: surface.line)),
      ),
      child: Text(
        '+$count',
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: 11.5,
          height: 1,
          fontWeight: FontWeight.w700,
          color: colors.textPrimary,
        ),
      ),
    );
  }
}

/// Fades its child in once. A new key (a new thing to show) fades again;
/// the old content is gone at once, so only one is ever in the tree.
class _FadeIn extends StatefulWidget {
  const _FadeIn({required this.duration, required this.child, super.key});

  final Duration duration;
  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.duration == Duration.zero ? 1 : 0,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Motion.enter,
  );

  @override
  void initState() {
    super.initState();
    if (_controller.value < 1) _controller.forward();
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _curve, child: widget.child);
}
