import 'package:flutter/widgets.dart';

/// Scroll controller for a reversed transcript built as two slivers around
/// a center: the history the reader has (center sliver, growing up) and
/// everything newer than its last row (the sliver before the center,
/// growing down). Content changes below the center never move the history
/// on screen; this controller adds the two layout-time rules the screens
/// would otherwise apply with post-frame jumps (one visible frame late, and
/// the source of the "scrolls down, then up" jitter):
///
/// * **Stick to the bottom** while [following] and no finger is on the
///   list: when the content extent changes, the position is corrected to
///   the new bottom inside the same layout. Reading back is not following:
///   the screen says so as soon as the reader leaves the bottom.
/// * **Land** at the center boundary: [requestLanding] puts the boundary
///   [context] pixels below the top of the viewport (or at the bottom while
///   what is below it is shorter than the screen) and HOLDS it there in
///   every later layout, so rows that finish their layout late (previews,
///   rich text, the list's own extent estimates) never shift the divider.
///   The hold ends at the first scroll that is not this correction: a
///   finger on the list, a fling, an animation or a jump.
class AnchoredTranscriptScrollController extends ScrollController {
  AnchoredTranscriptScrollController({this.following = _alwaysFollow});

  static bool _alwaysFollow() => true;

  /// Whether the reader follows the newest content (not reading back).
  bool Function() following;

  double? _landingContext;

  /// Lands at the center boundary on the next layout and holds it there
  /// until the reader scrolls.
  void requestLanding({double context = 56}) => _landingContext = context;

  /// Whether a landing is still held (requested and not scrolled away).
  bool get landingPending => _landingContext != null;

  /// Ends the landing hold (the reader or another scroll took over).
  void releaseLanding() => _landingContext = null;

  bool _followPending = false;

  /// New content arrived while following: pin the next layout to the bottom
  /// even if the reader sits a little above it (e.g. after the open anchor
  /// revealed a run header). Without a request only a reader already at the
  /// bottom (or a change at the bottom edge) is pinned, so a lazy
  /// re-estimate of the far (oldest) edge never undoes that anchor.
  void requestFollow() => _followPending = true;

  bool _takeFollow() {
    final value = _followPending;
    _followPending = false;
    return value;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _AnchoredTranscriptPosition(
    owner: this,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _AnchoredTranscriptPosition extends ScrollPositionWithSingleContext {
  _AnchoredTranscriptPosition({
    required this.owner,
    required super.physics,
    required super.context,
    super.oldPosition,
    super.debugLabel,
  });

  final AnchoredTranscriptScrollController owner;

  bool get _fingerDown => activity is DragScrollActivity;

  // Any scroll other than the hold's own correction ends the landing: a
  // touch (hold, drag), a fling, an animation. Idle is what a layout or a
  // jump settles into, so it never releases by itself.
  @override
  void beginActivity(ScrollActivity? newActivity) {
    if (newActivity != null && newActivity is! IdleScrollActivity) {
      owner.releaseLanding();
    }
    super.beginActivity(newActivity);
  }

  @override
  void jumpTo(double value) {
    owner.releaseLanding();
    super.jumpTo(value);
  }

  @override
  void pointerScroll(double delta) {
    owner.releaseLanding();
    super.pointerScroll(delta);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final hadDimensions = hasContentDimensions && hasPixels;
    final oldMin = hadDimensions ? this.minScrollExtent : null;
    final oldMax = hadDimensions ? this.maxScrollExtent : null;
    final settled = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (!hasViewportDimension) return settled;
    final landing = owner._landingContext;
    if (landing != null) {
      final target = (-(viewportDimension - landing)).clamp(
        minScrollExtent,
        maxScrollExtent,
      );
      if ((pixels - target).abs() > 0.01) {
        correctPixels(target);
        return false;
      }
      return settled;
    }
    final changed =
        oldMin == null ||
        (oldMin - minScrollExtent).abs() > 0.01 ||
        (oldMax! - maxScrollExtent).abs() > 0.01;
    final follow = owner._takeFollow();
    final atOldBottom = oldMin == null || (pixels - oldMin).abs() <= 0.01;
    final bottomMoved =
        oldMin != null && (oldMin - minScrollExtent).abs() > 0.01;
    if ((follow || (changed && (atOldBottom || bottomMoved))) &&
        owner.following() &&
        !_fingerDown &&
        (pixels - minScrollExtent).abs() > 0.01) {
      correctPixels(minScrollExtent);
      return false;
    }
    return settled;
  }
}
