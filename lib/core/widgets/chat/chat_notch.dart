import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

import '../../design/tokens.dart';
import '../../services/global_activity_aggregate.dart';
import '../../theme/app_theme.dart';
import '../../theme/scroll_behavior.dart';
import '../pill_morph.dart';

/// The notch's slot on the composer's top edge (54×22 dp). pm1215 (owner,
/// QA 9494): no chevron tab any more; the slot holds a calm grabber
/// ([kChatNotchGrabberWidth]×[kChatNotchGrabberHeight], muted, like the
/// iOS one) on the composer's top edge, inside a 72×48 dp touch target.
const double kChatNotchWidth = 54;
const double kChatNotchHeight = 22;

/// The drawn grabber bar.
const double kChatNotchGrabberWidth = 32;
const double kChatNotchGrabberHeight = 4;

/// Its distance from the bottom of the notch's touch target (which sits on
/// the composer's top edge).
const double kChatNotchGrabberLift = 6;

/// Where the grabber is drawn inside the notch's touch target [notch]: the
/// rect the notch sheet grows out of and shrinks back into.
Rect chatNotchGrabberRect(Rect notch) => Rect.fromLTWH(
  notch.center.dx - kChatNotchGrabberWidth / 2,
  notch.bottom - kChatNotchGrabberLift - kChatNotchGrabberHeight,
  kChatNotchGrabberWidth,
  kChatNotchGrabberHeight,
);

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

/// Sheet motion: the shared pill morph (critically damped, no overshoot),
/// growing out of the grabber and shrinking back into it.
const Duration kChatNotchSheetOpen = kPillMorphOpen;
const Duration kChatNotchSheetClose = kPillMorphClose;

/// Share of the free height the sheet may take.
const double kChatNotchSheetMaxHeightFactor = 0.85;

/// Drag-to-close: the shared pill-morph thresholds.
const double kChatNotchDismissDistance = kPillMorphDismissDistance;
const double kChatNotchDismissVelocity = kPillMorphDismissVelocity;

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
    final bar = open
        ? colors.accent.withValues(alpha: 0.8)
        : colors.textSecondary.withValues(alpha: 0.45);
    final label = widget.attention && widget.attentionLabel != null
        ? '${widget.semanticLabel}. ${widget.attentionLabel}'
        : widget.semanticLabel;

    final tab = SizedBox(
      key: const ValueKey('chat-notch-tab'),
      width: kChatNotchWidth,
      height: kChatNotchHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          // Sits on the composer's top edge.
          Positioned(
            bottom: kChatNotchGrabberLift,
            child: AnimatedContainer(
              key: const ValueKey('chat-notch-grabber'),
              duration: _reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              width: kChatNotchGrabberWidth,
              height: kChatNotchGrabberHeight,
              decoration: BoxDecoration(
                color: bar,
                borderRadius: BorderRadius.circular(kChatNotchGrabberHeight),
              ),
            ),
          ),
          if (widget.attention)
            Positioned(
              bottom: 3,
              right: (kChatNotchWidth - kChatNotchGrabberWidth) / 2 - 10,
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
/// screen that grows out of the grabber ([origin]) as a pill morph and
/// shrinks back into it when it closes. No ✕: it closes on an outside tap,
/// Back, the screen reader's dismiss action or a drag down (from the
/// grabber, or from the content once it is scrolled to the top).
///
/// It never brings the keyboard back: the focused field is released before
/// the route opens, so popping it cannot restore focus to the composer.
Future<T?> showChatNotchSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Rect? origin,
  Rect? Function()? liveOrigin,
  Key surfaceKey = const ValueKey('chat-control-dialog'),
  double maxWidth = 560,
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final focused = FocusManager.instance.primaryFocus;
  if (focused?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
    focused!.unfocus();
  }
  final dismissLabel = MaterialLocalizations.of(
    context,
  ).modalBarrierDismissLabel;
  return Navigator.of(context).push<T>(
    PillMorphRoute<T>(
      reduceMotion: reduceMotion,
      dismissLabel: dismissLabel,
      builder: (routeContext, animation) {
        final media = MediaQuery.of(routeContext);
        final colors = Theme.of(routeContext).hermes;
        final bottomInset = math.max(
          media.padding.bottom,
          media.viewInsets.bottom,
        );
        // Content-sized, capped like the app's other floating surfaces so
        // the conversation stays visible above it.
        final maxHeight = math.max(
          0.0,
          (media.size.height - media.padding.top - bottomInset - 24) *
              kChatNotchSheetMaxHeightFactor,
        );
        return PillMorphSurface(
          animation: animation,
          origin: liveOrigin ?? () => origin,
          edge: PillMorphEdge.bottom,
          color: HermesChrome.of(colors).opaque,
          borderColor: HermesChrome.of(colors).line,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          radius: HermesRadius.floating + 6,
          scrimOpacity: HermesChrome.scrimSheet,
          reduceMotion: reduceMotion,
          dismissLabel: dismissLabel,
          surfaceKey: surfaceKey,
          onDismiss: () => Navigator.of(routeContext).maybePop(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: const ValueKey('chat-notch-sheet-grabber'),
                height: 20,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.textSecondary.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: const SizedBox(
                      width: kChatNotchGrabberWidth,
                      height: kChatNotchGrabberHeight,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: HermesModalScrollScope(child: Builder(builder: builder)),
              ),
            ],
          ),
        );
      },
    ),
  );
}
