import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart' show releaseTextFocusIfKeyboardHidden;
import '../theme/app_theme.dart';

/// Distance (logical px) past which releasing a downward drag closes a
/// status-pill sheet.
const double kStatusSheetCloseDistance = 100;

/// Downward release speed (px/s) that closes a status-pill sheet even when
/// it moved less than [kStatusSheetCloseDistance] (0.55 px/ms).
const double kStatusSheetCloseVelocity = 550;

/// Opens one of the status pill's floating sheets (context, model and
/// session, permissions) anchored above the bottom edge.
///
/// * Closes on the X, on a tap outside, on system Back / Esc, and by dragging
///   it down: from the header always, from the content only once its scroll
///   is at the top. Releasing past [kStatusSheetCloseDistance] or faster than
///   [kStatusSheetCloseVelocity] closes it; otherwise it springs back.
/// * The content scrolls inside the sheet.
/// * Closing never brings back a keyboard the user had already hidden.
/// * Reduced motion: no open/close transition and no spring back.
/// * [onRoute] hands the pushed route to its owner, so a screen that goes
///   away can remove the sheet it opened instead of leaving it orphaned.
Future<T?> showStatusPillSheet<T>({
  required BuildContext context,
  required Key surfaceKey,
  required String title,
  required WidgetBuilder builder,
  String? subtitle,
  double maxHeightFactor = 0.85,
  ValueChanged<Route<T>>? onRoute,
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  // QA 9490: the chat route gives focus back to the composer when a route on
  // top pops, and a focused field shows the keyboard again by itself.
  releaseTextFocusIfKeyboardHidden(context);
  final route = _StatusSheetRoute<T>(
    surfaceKey: surfaceKey,
    title: title,
    subtitle: subtitle,
    builder: builder,
    maxHeightFactor: maxHeightFactor,
    reduceMotion: reduceMotion,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  );
  onRoute?.call(route);
  return Navigator.of(context).push<T>(route);
}

class _StatusSheetRoute<T> extends PopupRoute<T> {
  _StatusSheetRoute({
    required this.surfaceKey,
    required this.title,
    required this.subtitle,
    required this.builder,
    required this.maxHeightFactor,
    required this.reduceMotion,
    required this.barrierLabel,
  });

  final Key surfaceKey;
  final String title;
  final String? subtitle;
  final WidgetBuilder builder;
  final double maxHeightFactor;
  final bool reduceMotion;
  final FocusScopeNode _focusScopeNode = FocusScopeNode(
    debugLabel: 'StatusPillSheet',
  );

  @override
  final String barrierLabel;

  @override
  bool get barrierDismissible => true;

  // The scrim is painted by the frame so it can lighten while dragging; the
  // transparent barrier still takes the outside tap.
  @override
  Color? get barrierColor => null;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 240);

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return FocusScope(
      node: _focusScopeNode,
      child: _StatusSheetFrame(
        animation: animation,
        surfaceKey: surfaceKey,
        title: title,
        subtitle: subtitle,
        maxHeightFactor: maxHeightFactor,
        reduceMotion: reduceMotion,
        onClose: () => Navigator.of(context).maybePop(),
        child: Builder(builder: builder),
      ),
    );
  }

  @override
  bool didPop(T? result) {
    _focusScopeNode.unfocus(disposition: UnfocusDisposition.scope);
    return super.didPop(result);
  }

  @override
  void dispose() {
    _focusScopeNode.dispose();
    super.dispose();
  }
}

class _StatusSheetFrame extends StatefulWidget {
  const _StatusSheetFrame({
    required this.animation,
    required this.surfaceKey,
    required this.title,
    required this.subtitle,
    required this.maxHeightFactor,
    required this.reduceMotion,
    required this.onClose,
    required this.child,
  });

  final Animation<double> animation;
  final Key surfaceKey;
  final String title;
  final String? subtitle;
  final double maxHeightFactor;
  final bool reduceMotion;
  final VoidCallback onClose;
  final Widget child;

  @override
  State<_StatusSheetFrame> createState() => _StatusSheetFrameState();
}

class _StatusSheetFrameState extends State<_StatusSheetFrame>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _drag = ValueNotifier(0);
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_onSettleTick);
  double _settleFrom = 0;
  bool _closing = false;

  @override
  void dispose() {
    _settle.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _onSettleTick() {
    _drag.value =
        _settleFrom * (1 - Curves.easeOutCubic.transform(_settle.value));
  }

  void _dragBy(double dy) {
    if (_closing) return;
    if (_settle.isAnimating) _settle.stop();
    _drag.value = math.max(0, _drag.value + dy);
  }

  void _release(double velocity) {
    if (_closing) return;
    if (_drag.value <= 0) return;
    if (_drag.value > kStatusSheetCloseDistance ||
        velocity > kStatusSheetCloseVelocity) {
      _closing = true;
      widget.onClose();
      return;
    }
    if (widget.reduceMotion) {
      _drag.value = 0;
      return;
    }
    _settleFrom = _drag.value;
    _settle.forward(from: 0);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        notification.overscroll < 0) {
      // Pulling down with the content already at its top moves the sheet.
      _dragBy(-notification.overscroll);
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        _drag.value > 0 &&
        (notification.scrollDelta ?? 0) > 0) {
      // Dragging back up first returns the sheet to its place.
      _dragBy(-(notification.scrollDelta ?? 0));
    } else if (notification is ScrollEndNotification) {
      _release(notification.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final bottomInset = math.max(media.padding.bottom, media.viewInsets.bottom);
    final free = media.size.height - media.padding.top - bottomInset - 24;
    final maxHeight = math.max(0.0, free * widget.maxHeightFactor);
    final width = math.min(560.0, media.size.width - 20);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 8, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: colors.divider,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          widget.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      if (widget.subtitle != null)
                        Text(
                          widget.subtitle!,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('status-sheet-close'),
                tooltip: strings.commonClose,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ],
      ),
    );

    final surface = Material(
      key: widget.surfaceKey,
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: .5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: colors.divider.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The header always drags the sheet.
            GestureDetector(
              key: const ValueKey('status-sheet-handle'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) => _dragBy(d.delta.dy),
              onVerticalDragEnd: (d) => _release(d.velocity.pixelsPerSecond.dy),
              onVerticalDragCancel: () => _release(0),
              child: header,
            ),
            Flexible(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: SingleChildScrollView(
                  key: const ValueKey('status-sheet-scroll'),
                  primary: false,
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                  child: widget.child,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final slide = widget.reduceMotion
        ? widget.animation
        : CurvedAnimation(
            parent: widget.animation,
            curve: Curves.easeOutBack,
            reverseCurve: Curves.easeInCubic,
          );
    return Stack(
      children: [
        // Scrim: lightens while the sheet is dragged away. Taps pass through
        // to the route's dismissible barrier.
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge([widget.animation, _drag]),
              builder: (context, _) {
                final progress = (_drag.value / 300).clamp(0.0, 1.0);
                final opacity =
                    0.45 *
                    widget.animation.value.clamp(0.0, 1.0) *
                    (1 - progress);
                return ColoredBox(
                  color: Colors.black.withValues(alpha: opacity),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(10, 0, 10, bottomInset + 10),
          child: Align(
            alignment: Alignment.bottomCenter,
            // Content-sized sheet; the outer drag covers content that does
            // not scroll (an unscrollable body never claims the gesture).
            child: GestureDetector(
              onVerticalDragUpdate: (d) => _dragBy(d.delta.dy),
              onVerticalDragEnd: (d) => _release(d.velocity.pixelsPerSecond.dy),
              onVerticalDragCancel: () => _release(0),
              child: AnimatedBuilder(
                animation: Listenable.merge([slide, _drag]),
                builder: (context, child) {
                  final hidden = 1 - slide.value;
                  final progress = (_drag.value / 400).clamp(0.0, 1.0);
                  return FractionalTranslation(
                    translation: Offset(0, hidden.clamp(-0.2, 1.0) * 0.6),
                    child: Transform.translate(
                      offset: Offset(0, _drag.value),
                      child: Transform.scale(
                        scale: 1 - 0.1 * progress,
                        alignment: Alignment.bottomCenter,
                        child: child,
                      ),
                    ),
                  );
                },
                child: surface,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
