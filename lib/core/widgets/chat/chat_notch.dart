import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

import '../../design/tokens.dart';
import '../../services/global_activity_aggregate.dart';
import '../../theme/app_theme.dart';
import '../../theme/scroll_behavior.dart';

/// Drawn size of the notch tab (owner design: 54×22 dp glass tab).
const double kChatNotchWidth = 54;
const double kChatNotchHeight = 22;

/// Touch target around the tab: it reaches up from the composer's top edge
/// into the transcript. The scroll arrow, painted later, keeps its own taps
/// where the two meet.
const double kChatNotchTargetWidth = 72;

/// Whether a horizontal swipe on the notch is safe on a screen of [size]
/// with [gestureInsets] (`MediaQuery.systemGestureInsets`): the centred
/// touch target must stay clear of the system back-gesture edges, otherwise
/// the swipe would fight the OS gesture.
bool chatNotchHorizontalSwipeSafe(Size size, EdgeInsets gestureInsets) {
  final left = (size.width - kChatNotchTargetWidth) / 2;
  final right = left + kChatNotchTargetWidth;
  return left >= gestureInsets.left &&
      right <= size.width - gestureInsets.right;
}

const double kChatNotchSlotHeight = 48;

/// Air between the drawn tab and the composer's top edge: none, the tab sits
/// right on it (owner decision; the activity pill lives in the header).
const double kChatNotchComposerGap = 0;

/// "Breathing": the tab rises this much and back once, so it gets noticed
/// when the chat appears, after its sheet closes and when the amber dot
/// lights up. Then it rests: an idle chat never keeps a ticker alive (the
/// mock's endless loop would repaint an idle chat forever).
const double kChatNotchBreath = 2.5;
const Duration kChatNotchBreathPeriod = Duration(milliseconds: 2000);
const int kChatNotchBreathCycles = 1;

/// Sheet motion (GUIA-CHAT §9): spring open 0.5–0.8 s, close 240–340 ms.
const Duration kChatNotchSheetOpen = Duration(milliseconds: 620);
const Duration kChatNotchSheetClose = Duration(milliseconds: 280);

/// Share of the free height the sheet may take.
const double kChatNotchSheetMaxHeightFactor = 0.85;

/// Drag-to-close: past ~100 px or faster than 0.55 px/ms.
const double kChatNotchDismissDistance = 100;
const double kChatNotchDismissVelocity = 550;

/// Upward travel on the tab that counts as "drag up to open".
const double _kOpenDragDistance = 12;

/// The "Ir a" destinations: the four dock sections plus the global chat
/// search (the conversation list opened with its search field focused).
enum ChatNotchDestination { chats, home, projects, settings, searchChats }

/// Same glyphs as the dock / drawer for each destination.
IconData chatNotchDestinationIcon(ChatNotchDestination destination) =>
    switch (destination) {
      ChatNotchDestination.chats => Icons.forum_outlined,
      ChatNotchDestination.home => Icons.home_outlined,
      ChatNotchDestination.projects => Icons.folder_copy_outlined,
      ChatNotchDestination.settings => Icons.settings_outlined,
      ChatNotchDestination.searchChats => Icons.manage_search_rounded,
    };

/// True when some OTHER conversation is waiting for the user (an exact,
/// live, non-stale "requires action" from the shared activity aggregate).
/// The open chat shows its own handoff in place, so it never lights the dot.
bool chatNotchNeedsYouElsewhere(
  Iterable<GlobalActivity> activities, {
  required String connectionId,
  required Set<String> currentSessionIds,
}) {
  for (final activity in activities) {
    if (!activity.requiresAction || !activity.active || activity.stale) {
      continue;
    }
    final scope = activity.scope;
    if (scope.connectionId == connectionId &&
        currentSessionIds.contains(scope.durableSessionId)) {
      continue;
    }
    return true;
  }
  return false;
}

/// Localized labels for the discoverable notch gesture dock.
class ChatNotchGestureLabels {
  const ChatNotchGestureLabels({
    required this.goTo,
    required this.findInChat,
    required this.previousChat,
    required this.nextChat,
  });

  final String goTo;
  final String findInChat;
  final String previousChat;
  final String nextChat;
}

/// The glass gesture dock above the composer. Gestures are attached only here,
/// never to the input or transcript.
class ChatNotch extends StatefulWidget {
  const ChatNotch({
    required this.open,
    required this.semanticLabel,
    required this.onOpen,
    this.onOpenGoTo,
    this.onFindInChat,
    this.onPreviousChat,
    this.onNextChat,
    this.horizontalSwipeEnabled = true,
    this.gestureLabels,
    this.attention = false,
    this.attentionLabel,
    super.key,
  });

  /// The sheet it opens is showing: accent tint, no breathing.
  final bool open;

  /// Something needs the user in another conversation: amber dot.
  final bool attention;
  final String semanticLabel;
  final String? attentionLabel;
  final VoidCallback onOpen;
  final VoidCallback? onOpenGoTo;
  final VoidCallback? onFindInChat;
  final VoidCallback? onPreviousChat;
  final VoidCallback? onNextChat;

  /// False when this dock target intersects an Android edge gesture inset.
  final bool horizontalSwipeEnabled;
  final ChatNotchGestureLabels? gestureLabels;

  @override
  State<ChatNotch> createState() => _ChatNotchState();
}

class _ChatNotchState extends State<ChatNotch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: kChatNotchBreathPeriod,
  );
  bool _reduceMotion = false;
  bool _started = false;
  double _dragUp = 0;
  bool _dragOpened = false;
  double _dragHorizontal = 0;
  bool _horizontalHandled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!_started || reduce != _reduceMotion) {
      final first = !_started;
      _started = true;
      _reduceMotion = reduce;
      _syncBreath(restart: first);
    }
  }

  @override
  void didUpdateWidget(ChatNotch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open) {
      // Closing the sheet lets it breathe again for a moment.
      _syncBreath(restart: !widget.open);
    } else if (widget.attention && !oldWidget.attention) {
      _syncBreath(restart: true);
    }
  }

  void _syncBreath({bool restart = false}) {
    if (_reduceMotion || widget.open) {
      _breath
        ..stop()
        ..value = 0;
      return;
    }
    if (!restart) return;
    _breath.value = 0;
    // A bounded number of breaths: the future completes and the controller
    // stops ticking, so an idle chat does not repaint forever.
    _breath
        .repeat(count: kChatNotchBreathCycles)
        .orCancel
        .then((_) {
          if (mounted) _breath.value = 0;
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  void _open() => widget.onOpen();

  void _openGoTo() => (widget.onOpenGoTo ?? widget.onOpen)();

  void _findInChat() => widget.onFindInChat?.call();

  void _previousChat() {
    if (widget.onPreviousChat == null) return;
    HapticFeedback.selectionClick();
    widget.onPreviousChat!();
  }

  void _nextChat() {
    if (widget.onNextChat == null) return;
    HapticFeedback.selectionClick();
    widget.onNextChat!();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final open = widget.open;
    final fill = open
        ? colors.accent.withValues(alpha: 0.18)
        : colors.surfaceVariant.withValues(alpha: 0.86);
    final border = open
        ? colors.accent.withValues(alpha: 0.55)
        : colors.divider.withValues(alpha: 0.7);
    final iconColor = open ? colors.accent : colors.textSecondary;
    final label = widget.attention && widget.attentionLabel != null
        ? '${widget.semanticLabel}. ${widget.attentionLabel}'
        : widget.semanticLabel;

    final tab = SizedBox(
      key: const ValueKey('chat-notch-tab'),
      width: kChatNotchWidth,
      height: kChatNotchHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(kChatNotchHeight / 2),
                border: Border.all(color: border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: _reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack,
                  child: Icon(
                    Icons.expand_less_rounded,
                    size: 18,
                    color: iconColor,
                  ),
                ),
              ),
            ),
          ),
          if (widget.attention)
            Positioned(
              top: -2,
              right: -2,
              child: DecoratedBox(
                key: const ValueKey('chat-notch-attention'),
                decoration: BoxDecoration(
                  color: colors.warning,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.background, width: 1.5),
                ),
                child: const SizedBox.square(dimension: 9),
              ),
            ),
        ],
      ),
    );

    final labels = widget.gestureLabels;
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (labels != null) CustomSemanticsAction(label: labels.goTo): _openGoTo,
      if (labels != null && widget.onFindInChat != null)
        CustomSemanticsAction(label: labels.findInChat): _findInChat,
      if (labels != null && widget.onPreviousChat != null)
        CustomSemanticsAction(label: labels.previousChat): _previousChat,
      if (labels != null && widget.onNextChat != null)
        CustomSemanticsAction(label: labels.nextChat): _nextChat,
    };
    return Semantics(
      key: const ValueKey('chat-notch'),
      container: true,
      button: true,
      enabled: true,
      label: label,
      onTap: _open,
      customSemanticsActions: actions,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          onLongPress: _findInChat,
          onVerticalDragStart: (_) {
            _dragUp = 0;
            _dragOpened = false;
          },
          onVerticalDragUpdate: (details) {
            _dragUp -= details.delta.dy;
            if (!_dragOpened && _dragUp >= _kOpenDragDistance) {
              _dragOpened = true;
              _openGoTo();
            }
          },
          onHorizontalDragStart: widget.horizontalSwipeEnabled
              ? (_) {
                  _dragHorizontal = 0;
                  _horizontalHandled = false;
                }
              : null,
          onHorizontalDragUpdate: widget.horizontalSwipeEnabled
              ? (details) {
                  _dragHorizontal += details.delta.dx;
                  if (_horizontalHandled || _dragHorizontal.abs() < 12) return;
                  _horizontalHandled = true;
                  if (_dragHorizontal > 0) _previousChat();
                  if (_dragHorizontal < 0) _nextChat();
                }
              : null,
          child: SizedBox(
            width: kChatNotchTargetWidth,
            height: kChatNotchSlotHeight,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: kChatNotchComposerGap),
                child: AnimatedBuilder(
                  animation: _breath,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(
                      0,
                      -kChatNotchBreath * math.sin(math.pi * _breath.value),
                    ),
                    child: child,
                  ),
                  child: tab,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [builder] as the notch's sheet: a floating card at the bottom of the
/// screen that grows out of the notch with a spring, closes in ~280 ms, and
/// closes on outside tap, Back, or a drag down (from the grabber, or from the
/// content once it is scrolled to the top).
///
/// It never brings the keyboard back: the focused field is released before
/// the route opens, so popping it cannot restore focus to the composer.
Future<T?> showChatNotchSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Rect? origin,
  Key surfaceKey = const ValueKey('chat-control-dialog'),
  double maxWidth = 560,
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final focused = FocusManager.instance.primaryFocus;
  if (focused?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
    focused!.unfocus();
  }
  return Navigator.of(context).push<T>(
    _ChatNotchSheetRoute<T>(
      builder: builder,
      origin: origin,
      surfaceKey: surfaceKey,
      maxWidth: maxWidth,
      reduceMotion: reduceMotion,
      barrierLabelText: MaterialLocalizations.of(
        context,
      ).modalBarrierDismissLabel,
    ),
  );
}

/// CSS `cubic-bezier(.2,1.2,.3,1)` from the mock: a soft overshoot.
const Curve _kSpring = Cubic(0.2, 1.2, 0.3, 1);

class _ChatNotchSheetRoute<T> extends PopupRoute<T> {
  _ChatNotchSheetRoute({
    required this.builder,
    required this.origin,
    required this.surfaceKey,
    required this.maxWidth,
    required this.reduceMotion,
    required this.barrierLabelText,
  });

  final WidgetBuilder builder;
  final Rect? origin;
  final Key surfaceKey;
  final double maxWidth;
  final bool reduceMotion;
  final String barrierLabelText;
  final ValueNotifier<double> _dragProgress = ValueNotifier(0);

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => barrierLabelText;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : kChatNotchSheetOpen;

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : kChatNotchSheetClose;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _ChatNotchSheetFrame(
    animation: animation,
    origin: origin,
    surfaceKey: surfaceKey,
    maxWidth: maxWidth,
    dragProgress: _dragProgress,
    child: Builder(builder: builder),
  );

  @override
  void dispose() {
    _dragProgress.dispose();
    super.dispose();
  }
}

class _ChatNotchSheetFrame extends StatefulWidget {
  const _ChatNotchSheetFrame({
    required this.animation,
    required this.origin,
    required this.surfaceKey,
    required this.maxWidth,
    required this.dragProgress,
    required this.child,
  });

  final Animation<double> animation;
  final Rect? origin;
  final Key surfaceKey;
  final double maxWidth;
  final ValueNotifier<double> dragProgress;
  final Widget child;

  @override
  State<_ChatNotchSheetFrame> createState() => _ChatNotchSheetFrameState();
}

class _ChatNotchSheetFrameState extends State<_ChatNotchSheetFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_onSettle);
  double _drag = 0;
  double _settleFrom = 0;
  bool _closing = false;

  void _onSettle() {
    _setDrag(_settleFrom * (1 - Curves.easeOutCubic.transform(_settle.value)));
  }

  void _setDrag(double value) {
    final next = math.max(0.0, value);
    if (next == _drag) return;
    setState(() => _drag = next);
    widget.dragProgress.value = (next / (kChatNotchDismissDistance * 2)).clamp(
      0.0,
      1.0,
    );
  }

  void _dragBy(double dy) {
    if (_closing) return;
    _settle.stop();
    _setDrag(_drag + dy);
  }

  void _release(double velocity) {
    if (_closing) return;
    if (_drag > kChatNotchDismissDistance ||
        velocity > kChatNotchDismissVelocity) {
      _closing = true;
      Navigator.of(context).maybePop();
      return;
    }
    if (_drag == 0) return;
    _settleFrom = _drag;
    _settle.forward(from: 0);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        notification.overscroll < 0) {
      _dragBy(-notification.overscroll);
    } else if (notification is ScrollUpdateNotification &&
        _drag > 0 &&
        notification.dragDetails != null &&
        (notification.scrollDelta ?? 0) > 0) {
      // Pulling back up while the sheet is displaced shrinks the drag first.
      _dragBy(-(notification.scrollDelta ?? 0));
    } else if (notification is ScrollEndNotification) {
      final velocity = notification.dragDetails?.primaryVelocity ?? 0;
      _release(velocity);
    }
    return false;
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).hermes;
    final theme = Theme.of(context);
    final keyboard = media.viewInsets.bottom;
    final bottomInset = math.max(media.padding.bottom, keyboard);
    final width = math.min(widget.maxWidth, media.size.width - 24);
    final left = (media.size.width - width) / 2;
    // Content-sized, capped like the app's other floating surfaces so the
    // conversation stays visible above it.
    final maxHeight = math.max(
      0.0,
      (media.size.height - media.padding.top - bottomInset - 24) *
          kChatNotchSheetMaxHeightFactor,
    );
    final origin = widget.origin;
    // Grow out of the notch: scale around its centre, projected onto the
    // sheet's bottom edge.
    final alignX = origin == null || width <= 0
        ? 0.0
        : (((origin.center.dx - left) / width) * 2 - 1).clamp(-1.0, 1.0);

    final surface = Material(
      key: widget.surfaceKey,
      color: theme.dialogTheme.backgroundColor ?? colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 14,
      shadowColor: Colors.black.withValues(alpha: .5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.floating + 6),
      ),
      clipBehavior: Clip.antiAlias,
      // Drags that the content does not take (the grabber, the headers, or a
      // list that fits without scrolling) move the sheet itself. A list that
      // scrolls wins the gesture and reports its pull past the top instead
      // (see [_onScroll]).
      child: GestureDetector(
        onVerticalDragUpdate: (d) => _dragBy(d.delta.dy),
        onVerticalDragEnd: (d) => _release(d.primaryVelocity ?? 0),
        onVerticalDragCancel: () => _release(0),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: const ValueKey('chat-notch-sheet-grabber'),
                height: 24,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const SizedBox(width: 38, height: 5),
                  ),
                ),
              ),
              Flexible(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: HermesModalScrollScope(child: widget.child),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Stack(
      children: [
        // Own scrim so it can lighten while the sheet is dragged away.
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                widget.animation,
                widget.dragProgress,
              ]),
              builder: (context, _) => ColoredBox(
                color: Colors.black.withValues(
                  alpha:
                      0.45 *
                      widget.animation.value.clamp(0.0, 1.0) *
                      (1 - widget.dragProgress.value),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: left,
          width: width,
          bottom: bottomInset + 12,
          child: AnimatedBuilder(
            animation: widget.animation,
            builder: (context, child) {
              final status = widget.animation.status;
              final reversing =
                  status == AnimationStatus.reverse ||
                  status == AnimationStatus.dismissed;
              final t = reversing
                  ? Curves.easeInCubic.transform(widget.animation.value)
                  : _kSpring.transform(widget.animation.value);
              final dragShrink = 1 - 0.1 * widget.dragProgress.value;
              final scale = (0.86 + 0.14 * t) * dragShrink;
              return Opacity(
                opacity: Curves.easeOut.transform(
                  (widget.animation.value * 3).clamp(0.0, 1.0),
                ),
                child: Transform.translate(
                  offset: Offset(0, (1 - t) * 24 + _drag),
                  child: Transform.scale(
                    scale: scale,
                    alignment: Alignment(alignX, 1),
                    child: child,
                  ),
                ),
              );
            },
            child: surface,
          ),
        ),
      ],
    );
  }
}
