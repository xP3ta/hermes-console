import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/scroll_behavior.dart';
import '../widgets/pill_morph.dart' show PillMorphDrag;
import 'floating.dart';
import 'tokens.dart';

/// Call right before pushing a sheet or popup route over a screen with a text
/// field. When that field still holds focus but the keyboard is hidden (the
/// user dismissed it with system Back), the field is unfocused, because
/// popping the route restores focus to it and a focused field shows the
/// keyboard again by itself. With the keyboard visible nothing changes and
/// the focus comes back on close as before.
///
/// Reads the raw view insets: inside a Scaffold body `MediaQuery.viewInsets`
/// is always zero.
///
/// QA 9495: a field that had the keyboard when a surface opened gets the
/// focus back when it closes, but the IME takes a moment to report its inset
/// again. Until it does, "focused, no inset" does not mean the user hid the
/// keyboard, so a surface reopened in that moment keeps the field focused
/// (see [_KeyboardHandBack]).
void releaseTextFocusIfKeyboardHidden(BuildContext context) {
  final focused = FocusManager.instance.primaryFocus;
  final focusedContext = focused?.context;
  if (focused == null || focusedContext == null) return;
  if (focusedContext.findAncestorWidgetOfExactType<EditableText>() == null) {
    return;
  }
  final view = View.maybeOf(context);
  if (view == null) return;
  if (view.viewInsets.bottom > 0) {
    _KeyboardHandBack.instance.expect(focused);
    return;
  }
  if (_KeyboardHandBack.instance.pendingFor(focused)) return;
  focused.unfocus();
}

/// The text field whose keyboard was up when a surface opened over it, until
/// the keyboard is seen up again while that field has the focus.
class _KeyboardHandBack with WidgetsBindingObserver {
  _KeyboardHandBack._();

  static final instance = _KeyboardHandBack._();

  WeakReference<FocusNode>? _node;

  void expect(FocusNode node) {
    if (_node == null) WidgetsBinding.instance.addObserver(this);
    _node = WeakReference(node);
  }

  bool pendingFor(FocusNode node) => identical(_node?.target, node);

  @override
  void didChangeMetrics() {
    final node = _node?.target;
    if (node == null) return _clear();
    if (!node.hasFocus) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.any((v) => v.viewInsets.bottom > 0)) _clear();
  }

  void _clear() {
    _node = null;
    WidgetsBinding.instance.removeObserver(this);
  }
}

// ── The ONE modal container ────────────────────────────────────────────────

/// Floating modal surface (spec 080). Never a bottom sheet
/// (`test/no_bottom_sheet_contract_test.dart`).
///
/// * Rounded 22, content-sized, capped at [maxHeightFactor] of the free
///   height (70 % by default: pickers never go full screen).
/// * Anchored popover under/over its origin when [anchorKey] or [originRect]
///   is given, centred otherwise.
/// * Scrim ([scrim]: light under a menu, stronger under a sheet, strongest
///   under a dialog); tap-out dismisses when [barrierDismissible].
/// * It leaves by receding towards where it came from, and a dismissible one
///   can be dragged away with a finger: down, or up when it hangs from
///   something at the top of the screen. The drag follows the finger; let go
///   past the threshold and it goes on from there, short of it and it
///   settles back. One that needs an answer ([barrierDismissible] false)
///   does not move.
/// * IME and safe-area aware; scrollables inside clamp (no bounce).
Future<T?> showHermesSurface<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Key surfaceKey = const ValueKey('hermes-floating-surface'),
  double maxWidth = 560,
  double maxHeightFactor = 0.7,
  bool barrierDismissible = true,
  bool systemDismissible = true,
  bool useRootNavigator = false,
  GlobalKey? anchorKey,
  Rect? originRect,
  HermesScrim scrim = HermesScrim.sheet,
}) {
  assert(maxWidth > 0);
  assert(maxHeightFactor > 0 && maxHeightFactor <= 1);
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final focusScopeNode = FocusScopeNode(debugLabel: 'HermesFloatingSurface');
  releaseTextFocusIfKeyboardHidden(context);
  Rect? origin = originRect;
  if (origin == null && anchorKey != null) {
    final box = anchorKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      origin = box.localToGlobal(Offset.zero) & box.size;
    }
  }
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _HermesSurfaceRoute<T>(
      builder: builder,
      focusScopeNode: focusScopeNode,
      surfaceKey: surfaceKey,
      maxWidth: maxWidth,
      maxHeightFactor: maxHeightFactor,
      barrierDismissible: barrierDismissible,
      systemDismissible: systemDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      reduceMotion: reduceMotion,
      origin: origin,
      scrim: scrim,
    ),
  );
}

/// How much of the page a modal surface dims.
enum HermesScrim {
  /// A menu or popover: what is behind stays readable.
  menu(HermesChrome.scrimMenu),

  /// A sheet, a picker, a panel.
  sheet(HermesChrome.scrimSheet),

  /// A dialog that asks for an answer.
  dialog(HermesChrome.scrimDialog);

  const HermesScrim(this.opacity);

  final double opacity;

  Color get color => Colors.black.withValues(alpha: opacity);
}

/// Global rect of the widget that owns [context] (for anchored surfaces).
Rect? hermesOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _HermesSurfaceRoute<T> extends PageRouteBuilder<T> {
  _HermesSurfaceRoute({
    required WidgetBuilder builder,
    required FocusScopeNode focusScopeNode,
    required Key surfaceKey,
    required double maxWidth,
    required double maxHeightFactor,
    required super.barrierDismissible,
    required bool systemDismissible,
    required String barrierLabel,
    required bool reduceMotion,
    required Rect? origin,
    required HermesScrim scrim,
  }) : _focusScopeNode = focusScopeNode,
       super(
         opaque: false,
         barrierColor: scrim.color,
         barrierLabel: barrierLabel,
         maintainState: true,
         transitionDuration: reduceMotion
             ? Duration.zero
             : const Duration(milliseconds: 200),
         reverseTransitionDuration: reduceMotion
             ? Duration.zero
             : const Duration(milliseconds: 180),
         pageBuilder: (context, animation, secondaryAnimation) =>
             CoveredRouteMediaQueryFreeze(
               child: PopScope(
                 canPop: systemDismissible,
                 child: FocusScope(
                   node: focusScopeNode,
                   child: HermesModalScrollScope(
                     child: _HermesSurfaceFrame(
                       surfaceKey: surfaceKey,
                       maxWidth: maxWidth,
                       maxHeightFactor: maxHeightFactor,
                       reduceMotion: reduceMotion,
                       origin: origin,
                       draggable: barrierDismissible && systemDismissible,
                       child: Builder(builder: builder),
                     ),
                   ),
                 ),
               ),
             ),
         transitionsBuilder: (context, animation, secondaryAnimation, child) {
           if (reduceMotion) return child;
           return _SurfaceMotion(
             animation: animation,
             origin: origin,
             child: child,
           );
         },
       );

  final FocusScopeNode _focusScopeNode;

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

/// Pure geometry of an anchored surface, in global coordinates.
@visibleForTesting
Rect hermesAnchoredSurfaceRect({
  required Size screen,
  required EdgeInsets safe,
  required double keyboard,
  required Rect origin,
  required double width,
  required double height,
  double gap = 8,
  double margin = 12,
}) {
  final top = safe.top + margin;
  final bottom = screen.height - math.max(safe.bottom, keyboard) - margin;
  var left = origin.center.dx - width / 2;
  // Prefer aligning to the origin's leading edge for wide origins (rows).
  if (origin.width >= width) left = origin.left;
  left = left.clamp(margin, math.max(margin, screen.width - width - margin));
  final spaceBelow = bottom - origin.bottom - gap;
  final spaceAbove = origin.top - gap - top;
  double y;
  if (height <= spaceBelow || spaceBelow >= spaceAbove) {
    y = origin.bottom + gap;
  } else {
    y = origin.top - gap - height;
  }
  y = y.clamp(top, math.max(top, bottom - height));
  return Rect.fromLTWH(left, y, width, math.min(height, bottom - top));
}

/// How a floating surface arrives and leaves. It comes forward from its
/// origin (or from the centre) and, leaving, recedes into it: it shrinks and
/// fades back towards where it came from. Closed before it had finished
/// opening, it goes on from what was on screen: neither its opacity nor its
/// size ever jumps or comes back up.
class _SurfaceMotion extends StatefulWidget {
  const _SurfaceMotion({
    required this.animation,
    required this.origin,
    required this.child,
  });

  final Animation<double> animation;
  final Rect? origin;
  final Widget child;

  @override
  State<_SurfaceMotion> createState() => _SurfaceMotionState();
}

class _SurfaceMotionState extends State<_SurfaceMotion> {
  late _RecedingScale _scale = _recede();

  _RecedingScale _recede() =>
      _RecedingScale(widget.animation, widget.origin == null ? 0.97 : 0.92);

  @override
  void didUpdateWidget(_SurfaceMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.animation, widget.animation)) _scale = _recede();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final from = widget.origin?.center;
    final alignment = from == null || size.isEmpty
        ? Alignment.center
        : Alignment(
            (from.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
            (from.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
          );
    return RouteCurves(
      animation: widget.animation,
      builder: (context, curved, child) => FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: _scale,
          alignment: alignment,
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// The size of a surface along its route: it grows to 1 while opening and,
/// from wherever it was when the close began, shrinks to [receded].
class _RecedingScale extends Animation<double>
    with AnimationWithParentMixin<double> {
  _RecedingScale(this.parent, this.start);

  @override
  final Animation<double> parent;

  /// The size it opens from.
  final double start;

  /// How small it gets as it recedes.
  static const double receded = 0.82;

  ({double t, double scale})? _closingFrom;

  double _opening(double t) => start + (1 - start) * Motion.enter.transform(t);

  @override
  double get value {
    final t = parent.value.clamp(0.0, 1.0);
    if (parent.status != AnimationStatus.reverse) {
      _closingFrom = null;
      return _opening(t);
    }
    final from = _closingFrom ??= (t: t, scale: _opening(t));
    if (from.t <= 0) return receded;
    final gone = Curves.easeIn.transform((1 - t / from.t).clamp(0.0, 1.0));
    return from.scale + (receded - from.scale) * gone;
  }
}

class _HermesSurfaceFrame extends StatefulWidget {
  const _HermesSurfaceFrame({
    required this.surfaceKey,
    required this.maxWidth,
    required this.maxHeightFactor,
    required this.reduceMotion,
    required this.origin,
    required this.draggable,
    required this.child,
  });

  final Key surfaceKey;
  final double maxWidth;
  final double maxHeightFactor;
  final bool reduceMotion;
  final Rect? origin;

  /// Whether a finger can drag it away.
  final bool draggable;
  final Widget child;

  @override
  State<_HermesSurfaceFrame> createState() => _HermesSurfaceFrameState();
}

class _HermesSurfaceFrameState extends State<_HermesSurfaceFrame>
    with SingleTickerProviderStateMixin {
  late final PillMorphDrag _drag = PillMorphDrag(
    vsync: this,
    onDismiss: () => Navigator.of(context).maybePop(),
  );

  /// A finger (not a fling) is moving the content's own scrollable.
  bool _fingerScrolls = false;

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  /// The natural way out: up for a surface that hangs from something in the
  /// upper half of the screen, down for everything else. +1 is down.
  double _sign(Size screen) {
    final origin = widget.origin;
    return origin != null && origin.center.dy < screen.height / 2 ? -1 : 1;
  }

  /// Content that scrolls takes the drag; once it is at the end that faces
  /// the way out, the pull moves the surface instead.
  bool _onScroll(ScrollNotification n, double sign) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    // A wheel picker or the text of a field scrolling to its end is not a
    // pull on the surface.
    if (n.metrics is FixedExtentMetrics ||
        n.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    _fingerScrolls = switch (n) {
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      OverscrollNotification(:final dragDetails) => dragDetails != null,
      ScrollEndNotification() => false,
      _ => _fingerScrolls,
    };
    if (n is OverscrollNotification && n.dragDetails != null) {
      final toward = -n.overscroll * sign;
      if (toward > 0) _drag.dragBy(toward);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        _drag.offset > 0) {
      final back = (n.scrollDelta ?? 0) * sign;
      if (back > 0) _drag.dragBy(-back);
    } else if (n is ScrollEndNotification) {
      _drag.release(
        (n.dragDetails?.primaryVelocity ?? 0) * sign,
        reduceMotion: widget.reduceMotion,
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final free =
        media.size.height -
        math.max(media.padding.bottom, keyboard) -
        media.padding.top -
        32;
    final maxHeight = free <= 0 ? 0.0 : free * widget.maxHeightFactor;
    final width = math.min(widget.maxWidth, media.size.width - 32);
    Widget surface = HermesFloatingSurface(
      key: widget.surfaceKey,
      modal: true,
      shape: HermesFloatingSurface.rounded(),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
        child: widget.child,
      ),
    );
    if (widget.draggable) {
      final sign = _sign(media.size);
      surface = NotificationListener<OverscrollIndicatorNotification>(
        onNotification: (n) {
          // The pull moves the surface: the list must not also stretch.
          if (n.depth == 0 && _fingerScrolls && n.leading == (sign > 0)) {
            n.disallowIndicator();
          }
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) => _onScroll(n, sign),
          child: GestureDetector(
            key: const ValueKey('hermes-surface-drag'),
            behavior: HitTestBehavior.translucent,
            onVerticalDragUpdate: (d) => _drag.dragBy(d.delta.dy * sign),
            onVerticalDragEnd: (d) => _drag.release(
              (d.primaryVelocity ?? 0) * sign,
              reduceMotion: widget.reduceMotion,
            ),
            onVerticalDragCancel: () =>
                _drag.release(0, reduceMotion: widget.reduceMotion),
            child: AnimatedBuilder(
              animation: _drag,
              child: surface,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, _drag.offset * sign),
                child: child,
              ),
            ),
          ),
        ),
      );
    }
    final anchor = widget.origin;
    if (anchor == null) {
      return AnimatedPadding(
        duration: widget.reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboard),
        child: SafeArea(
          minimum: const EdgeInsets.all(16),
          child: Center(child: surface),
        ),
      );
    }
    return CustomSingleChildLayout(
      delegate: _AnchoredLayout(
        origin: anchor,
        safe: media.padding,
        keyboard: keyboard,
      ),
      child: surface,
    );
  }
}

class _AnchoredLayout extends SingleChildLayoutDelegate {
  _AnchoredLayout({
    required this.origin,
    required this.safe,
    required this.keyboard,
  });

  final Rect origin;
  final EdgeInsets safe;
  final double keyboard;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      hermesAnchoredSurfaceRect(
        screen: size,
        safe: safe,
        keyboard: keyboard,
        origin: origin,
        width: childSize.width,
        height: childSize.height,
      ).topLeft;

  @override
  bool shouldRelayout(_AnchoredLayout old) =>
      old.origin != origin || old.safe != safe || old.keyboard != keyboard;
}

// ── A caller-built dialog, shown the same way ──────────────────────────────

/// Shows a dialog the caller builds itself ([AlertDialog], [Dialog]) the way
/// every other floating surface is shown: the dialog scrim, the receding
/// exit and, when it can be dismissed, a finger drag down that takes it away.
/// Same contract as Material's `showDialog`; prefer [showHermesDialog] for a
/// plain confirmation.
///
/// [draggable] false keeps the tap outside but not the drag, for a dialog
/// whose own content is dragged (the hand of a clock).
Future<T?> showHermesDialogRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool? draggable,
}) {
  releaseTextFocusIfKeyboardHidden(context);
  return Navigator.of(context, rootNavigator: true).push<T>(
    hermesDialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      draggable: draggable,
    ),
  );
}

/// The route [showHermesDialogRoute] pushes, for a caller that keeps the
/// route to take it away itself. Push it on the root navigator.
Route<T> hermesDialogRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool? draggable,
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );
  return RawDialogRoute<T>(
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: HermesScrim.dialog.color,
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) => themes.wrap(
      SafeArea(
        child: _DragAway(
          enabled: draggable ?? barrierDismissible,
          reduceMotion: reduceMotion,
          child: Builder(builder: builder),
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        reduceMotion
        ? child
        : _SurfaceMotion(animation: animation, origin: null, child: child),
  );
}

/// Lets a finger drag a dismissible surface down and away. The drag follows
/// the finger; let go past the threshold and it goes on from there.
class _DragAway extends StatefulWidget {
  const _DragAway({
    required this.enabled,
    required this.reduceMotion,
    required this.child,
  });

  final bool enabled;
  final bool reduceMotion;
  final Widget child;

  @override
  State<_DragAway> createState() => _DragAwayState();
}

class _DragAwayState extends State<_DragAway>
    with SingleTickerProviderStateMixin {
  late final PillMorphDrag _drag = PillMorphDrag(
    vsync: this,
    onDismiss: () => Navigator.of(context).maybePop(),
  );

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      key: const ValueKey('hermes-dialog-drag'),
      onVerticalDragUpdate: (d) => _drag.dragBy(d.delta.dy),
      onVerticalDragEnd: (d) => _drag.release(
        d.primaryVelocity ?? 0,
        reduceMotion: widget.reduceMotion,
      ),
      onVerticalDragCancel: () =>
          _drag.release(0, reduceMotion: widget.reduceMotion),
      child: AnimatedBuilder(
        animation: _drag,
        child: widget.child,
        builder: (context, child) =>
            Transform.translate(offset: Offset(0, _drag.offset), child: child),
      ),
    );
  }
}

// ── Surface header ─────────────────────────────────────────────────────────

/// Title line of a floating surface (17 w600 textPrimary) with optional close.
class HermesSurfaceHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool showClose;
  final List<Widget> actions;

  const HermesSurfaceHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.showClose = false,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, showClose ? 8 : 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: HermesType.title.copyWith(color: colors.textPrimary),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ...actions,
          if (showClose)
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }
}

// ── Option list ────────────────────────────────────────────────────────────

class HermesOption<T> {
  final T value;
  final String label;
  final String? subtitle;

  /// Group header (for example a provider). Consecutive equal groups share
  /// one header.
  final String? group;
  final IconData? icon;
  final Key? key;
  final bool enabled;

  /// Draws the label in this family: a font offered in its own letters.
  final String? fontFamily;

  const HermesOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.group,
    this.icon,
    this.key,
    this.enabled = true,
    this.fontFamily,
  });
}

/// Floating option list: check on the selected option, optional groups,
/// search when there are more than [searchThreshold] options.
Future<T?> showHermesOptions<T>({
  required BuildContext context,
  required List<HermesOption<T>> options,
  T? selected,
  String? title,
  String? subtitle,
  Key surfaceKey = const ValueKey('hermes-option-surface'),
  GlobalKey? anchorKey,
  Rect? originRect,
  int searchThreshold = 8,
  double maxWidth = 420,
  bool Function(T a, T b)? equals,
}) => showHermesSurface<T>(
  context: context,
  surfaceKey: surfaceKey,
  anchorKey: anchorKey,
  originRect: originRect,
  maxWidth: maxWidth,
  builder: (context) => HermesOptionList<T>(
    options: options,
    selected: selected,
    title: title,
    subtitle: subtitle,
    searchable: options.length > searchThreshold,
    equals: equals,
    onSelected: (value) => Navigator.of(context).pop(value),
  ),
);

class HermesOptionList<T> extends StatefulWidget {
  final List<HermesOption<T>> options;
  final T? selected;
  final String? title;
  final String? subtitle;
  final bool searchable;
  final ValueChanged<T> onSelected;
  final bool Function(T a, T b)? equals;

  const HermesOptionList({
    super.key,
    required this.options,
    required this.onSelected,
    this.selected,
    this.title,
    this.subtitle,
    this.searchable = false,
    this.equals,
  });

  @override
  State<HermesOptionList<T>> createState() => _HermesOptionListState<T>();
}

class _HermesOptionListState<T> extends State<HermesOptionList<T>> {
  String _query = '';

  bool _isSelected(T value) {
    final selected = widget.selected;
    if (selected == null) return false;
    return widget.equals?.call(value, selected) ?? value == selected;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? widget.options
        : widget.options
              .where(
                (o) =>
                    o.label.toLowerCase().contains(q) ||
                    (o.subtitle?.toLowerCase().contains(q) ?? false) ||
                    (o.group?.toLowerCase().contains(q) ?? false),
              )
              .toList();
    final rows = <Widget>[];
    String? lastGroup;
    for (final option in visible) {
      if (option.group != null && option.group != lastGroup) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              option.group!.toUpperCase(),
              style: HermesType.caption.copyWith(color: colors.textSecondary),
            ),
          ),
        );
      }
      lastGroup = option.group;
      final isSelected = _isSelected(option.value);
      rows.add(
        Semantics(
          selected: isSelected,
          button: true,
          child: InkWell(
            key: option.key,
            onTap: option.enabled
                ? () => widget.onSelected(option.value)
                : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 50),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    if (option.icon != null) ...[
                      Icon(option.icon, size: 20, color: colors.textSecondary),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            option.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.body.copyWith(
                              fontFamily: option.fontFamily,
                              color: option.enabled
                                  ? colors.textPrimary
                                  : colors.textDisabled,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          if (option.subtitle != null &&
                              option.subtitle!.isNotEmpty)
                            Text(
                              option.subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: HermesType.support.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 20,
                      child: isSelected
                          ? Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: colors.accentText,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            s.designNoMatches,
            textAlign: TextAlign.center,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.title != null)
          HermesSurfaceHeader(title: widget.title!, subtitle: widget.subtitle),
        if (widget.searchable)
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              widget.title == null ? 14 : 2,
              16,
              6,
            ),
            child: TextField(
              key: const ValueKey('hermes-option-search'),
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: s.designSearch,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                fillColor: colors.surfaceVariant.withValues(alpha: .6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HermesRadius.control),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        Flexible(
          child: ListView(
            key: const ValueKey('hermes-option-list'),
            shrinkWrap: true,
            padding: EdgeInsets.only(
              top: widget.title == null && !widget.searchable ? 8 : 0,
              bottom: 8,
            ),
            children: rows,
          ),
        ),
      ],
    );
  }
}

// ── Action list / menu ─────────────────────────────────────────────────────

class HermesAction<T> {
  final T value;
  final String label;
  final IconData? icon;
  final bool destructive;
  final Key? key;

  /// True marks the action as the one in force (the board shown, the order
  /// in use) with a check at its end; null when it is not a choice.
  final bool? selected;

  /// A small heading drawn above this action, for the first of a group
  /// («Ordenar por»). A hairline separates the group from what is above.
  final String? section;

  /// True draws a hairline above this action: it starts a group of its own.
  final bool divided;

  const HermesAction({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
    this.key,
    this.selected,
    this.section,
    this.divided = false,
  });
}

/// A button that opens [showHermesMenu] from itself: the three dots of a row
/// or of a header. It is how a screen offers a menu — the floating tone, the
/// light scrim, the exit that recedes into the button and the drag away come
/// with it.
class HermesMenuButton<T> extends StatelessWidget {
  const HermesMenuButton({
    required this.actions,
    required this.onSelected,
    this.icon,
    this.tooltip,
    this.iconSize,
    this.iconColor,
    this.padding,
    this.enabled = true,
    this.title,
    this.surfaceKey = const ValueKey('hermes-menu'),
    super.key,
  });

  /// Built when the menu opens, so it reflects the state of that moment.
  final List<HermesAction<T>> Function(BuildContext context) actions;
  final ValueChanged<T> onSelected;
  final Widget? icon;
  final String? tooltip;
  final double? iconSize;
  final Color? iconColor;
  final EdgeInsetsGeometry? padding;
  final bool enabled;
  final String? title;
  final Key surfaceKey;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
    icon: icon ?? const Icon(Icons.more_vert),
    iconSize: iconSize,
    color: iconColor,
    padding: padding,
    onPressed: !enabled
        ? null
        : () async {
            final choices = actions(context);
            if (choices.isEmpty) return;
            final value = await showHermesMenu<T>(
              context: context,
              actions: choices,
              title: title,
              surfaceKey: surfaceKey,
            );
            if (value != null && context.mounted) onSelected(value);
          },
  );
}

/// Popover menu anchored to its button: 48 dp rows, destructive last in red.
/// Intended for ≤ 6 actions.
Future<T?> showHermesMenu<T>({
  required BuildContext context,
  required List<HermesAction<T>> actions,
  GlobalKey? anchorKey,
  Rect? originRect,
  Key surfaceKey = const ValueKey('hermes-menu'),
  String? title,
}) {
  final ordered = [
    ...actions.where((a) => !a.destructive),
    ...actions.where((a) => a.destructive),
  ];
  return showHermesSurface<T>(
    context: context,
    surfaceKey: surfaceKey,
    anchorKey: anchorKey,
    originRect:
        originRect ?? (anchorKey == null ? hermesOriginOf(context) : null),
    maxWidth: 280,
    scrim: HermesScrim.menu,
    builder: (context) {
      final colors = Theme.of(context).hermes;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) HermesSurfaceHeader(title: title),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (var i = 0; i < ordered.length; i++) ...[
                  if (i > 0 &&
                      (ordered[i].divided ||
                          ordered[i].section != null ||
                          (ordered[i].destructive &&
                              !ordered[i - 1].destructive)))
                    Divider(
                      height: 9,
                      indent: 16,
                      endIndent: 16,
                      color: HermesSurfaces.divider(colors),
                    ),
                  if (ordered[i].section case final section?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
                      child: Text(
                        section,
                        style: HermesType.caption.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ),
                  Semantics(
                    // Says «seleccionado» for the choice in force.
                    selected: ordered[i].selected,
                    child: InkWell(
                      key: ordered[i].key,
                      onTap: () => Navigator.of(context).pop(ordered[i].value),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Row(
                            children: [
                              if (ordered[i].icon != null) ...[
                                Icon(
                                  ordered[i].icon,
                                  size: 20,
                                  color: ordered[i].destructive
                                      ? colors.error
                                      : colors.textSecondary,
                                ),
                                const SizedBox(width: 14),
                              ],
                              Expanded(
                                child: Text(
                                  ordered[i].label,
                                  style: HermesType.body.copyWith(
                                    color: ordered[i].destructive
                                        ? colors.error
                                        : colors.textPrimary,
                                  ),
                                ),
                              ),
                              if (ordered[i].selected == true) ...[
                                const SizedBox(width: 12),
                                Icon(
                                  Icons.check_rounded,
                                  size: 20,
                                  color: colors.accent,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    },
  );
}

// ── Dialog ─────────────────────────────────────────────────────────────────

enum HermesDialogActionStyle { cancel, primary, destructive }

class HermesDialogAction<T> {
  final String label;
  final T value;
  final HermesDialogActionStyle style;
  final Key? key;

  const HermesDialogAction({
    required this.label,
    required this.value,
    this.style = HermesDialogActionStyle.primary,
    this.key,
  });
}

/// Confirm/decide only: title 17 w600, message 14, 48 dp pill actions,
/// destructive in red. No long text, no forms.
Future<T?> showHermesDialog<T>({
  required BuildContext context,
  required String title,
  required List<HermesDialogAction<T>> actions,
  String? message,
  Key surfaceKey = const ValueKey('hermes-dialog'),
  bool barrierDismissible = true,
  bool useRootNavigator = false,
}) => showHermesSurface<T>(
  context: context,
  surfaceKey: surfaceKey,
  maxWidth: 400,
  scrim: HermesScrim.dialog,
  // Content-sized; the cap only matters with the keyboard up (small free
  // height), where the actions must stay inside the surface.
  maxHeightFactor: 0.9,
  barrierDismissible: barrierDismissible,
  useRootNavigator: useRootNavigator,
  builder: (context) {
    final colors = Theme.of(context).hermes;
    // Title + message scroll together when space is short (keyboard up,
    // large text); the actions stay pinned and always reachable.
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 18, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: HermesType.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  if (message != null && message.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      message,
                      style: HermesType.text.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final action in actions)
                _DialogPill(
                  key: action.key,
                  label: action.label,
                  style: action.style,
                  onTap: () => Navigator.of(context).pop(action.value),
                ),
            ],
          ),
        ],
      ),
    );
  },
);

class _DialogPill extends StatelessWidget {
  final String label;
  final HermesDialogActionStyle style;
  final VoidCallback? onTap;

  const _DialogPill({
    super.key,
    required this.label,
    required this.style,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final (Color? bg, Color fg) = switch (style) {
      HermesDialogActionStyle.cancel => (null, colors.textPrimary),
      HermesDialogActionStyle.primary => (colors.accent, colors.onAccent),
      HermesDialogActionStyle.destructive => (
        colors.error,
        ThemeData.estimateBrightnessForColor(colors.error) == Brightness.dark
            ? Colors.white
            : Colors.black,
      ),
    };
    final pill = Material(
      color: bg ?? Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          padding: EdgeInsets.symmetric(horizontal: bg == null ? 16 : 22),
          // Shrink-wrap (an aligned Container fills the Wrap's width).
          child: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: bg == null ? FontWeight.w500 : FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
    if (onTap != null) return pill;
    return Semantics(
      enabled: false,
      child: Opacity(opacity: 0.4, child: IgnorePointer(child: pill)),
    );
  }
}

/// Short form dialog (spec 080): the [showHermesDialog] shell with a small
/// stateful body (one field, a checkbox, a short choice). [enabled] decides
/// per action whether it can be tapped; the body calls `setState` to
/// re-evaluate it. Long text never goes here — use a page.
Future<T?> showHermesFormDialog<T>({
  required BuildContext context,
  required String title,
  required List<HermesDialogAction<T>> actions,
  required Widget Function(BuildContext context, StateSetter setState) body,
  String? message,
  bool Function(T value)? enabled,
  Key surfaceKey = const ValueKey('hermes-form-dialog'),
  bool barrierDismissible = true,
  bool useRootNavigator = false,
}) => showHermesSurface<T>(
  context: context,
  surfaceKey: surfaceKey,
  maxWidth: 440,
  scrim: HermesScrim.dialog,
  maxHeightFactor: 0.8,
  barrierDismissible: barrierDismissible,
  useRootNavigator: useRootNavigator,
  builder: (context) {
    final colors = Theme.of(context).hermes;
    return StatefulBuilder(
      builder: (context, setState) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: HermesType.title.copyWith(color: colors.textPrimary),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 10, right: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (message != null && message.isNotEmpty) ...[
                      Text(
                        message,
                        style: HermesType.text.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    body(context, setState),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final action in actions)
                  _DialogPill(
                    key: action.key,
                    label: action.label,
                    style: action.style,
                    onTap: enabled == null || enabled(action.value)
                        ? () => Navigator.of(context).pop(action.value)
                        : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  },
);

// ── Model picker ───────────────────────────────────────────────────────────

/// A provider and its models, the common shape of every model catalog.
class HermesModelGroup {
  final String slug;
  final String name;
  final List<String> models;
  final Set<String> unavailableModels;

  const HermesModelGroup({
    required this.slug,
    required this.name,
    required this.models,
    this.unavailableModels = const {},
  });
}

/// A picked model. [isDefault] means "use the default" (profile/server).
class HermesModelChoice {
  final String provider;
  final String model;
  final bool isDefault;

  const HermesModelChoice(this.provider, this.model) : isDefault = false;
  const HermesModelChoice.defaultModel()
    : provider = '',
      model = '',
      isDefault = true;

  @override
  bool operator ==(Object other) =>
      other is HermesModelChoice &&
      other.isDefault == isDefault &&
      other.provider == provider &&
      other.model == model;

  @override
  int get hashCode => Object.hash(provider, model, isDefault);
}

/// The ONE model picker: floating, search, provider groups, check, optional
/// "Default" row. [keyPrefix] keeps per-screen test keys stable
/// (`$keyPrefix-$provider-$model`).
Future<HermesModelChoice?> showHermesModelPicker({
  required BuildContext context,
  required List<HermesModelGroup> groups,
  HermesModelChoice? current,
  String? defaultLabel,
  String? defaultSubtitle,
  String? title,
  String? subtitle,
  Key surfaceKey = const ValueKey('hermes-model-picker'),
  String keyPrefix = 'hermes-model',
  GlobalKey? anchorKey,
  Rect? originRect,
}) {
  final options = <HermesOption<HermesModelChoice>>[
    if (defaultLabel != null)
      HermesOption(
        key: ValueKey('$keyPrefix-default'),
        value: const HermesModelChoice.defaultModel(),
        label: defaultLabel,
        subtitle: defaultSubtitle,
        icon: Icons.auto_mode_rounded,
      ),
    for (final group in groups)
      for (final model in group.models)
        HermesOption(
          key: ValueKey('$keyPrefix-${group.slug}-$model'),
          value: HermesModelChoice(group.slug, model),
          label: model,
          enabled: !group.unavailableModels.contains(model),
          subtitle: group.unavailableModels.contains(model)
              ? Strings.of(context).chaModelUnavailable
              : null,
          group: group.name.isEmpty ? group.slug : group.name,
        ),
  ];
  return showHermesOptions<HermesModelChoice>(
    context: context,
    options: options,
    selected: current,
    title: title,
    subtitle: subtitle,
    surfaceKey: surfaceKey,
    anchorKey: anchorKey,
    originRect: originRect,
    maxWidth: 480,
    // A model matches on name when the current value has no provider.
    equals: (a, b) =>
        a == b ||
        (!a.isDefault &&
            !b.isDefault &&
            b.provider.isEmpty &&
            a.model == b.model),
  );
}
