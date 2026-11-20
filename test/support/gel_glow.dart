import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/gel_surface.dart';
import 'package:hermes_android/core/design/tokens.dart';

/// The boxes that cast an accent gel's glow under [scope]: the decorated box
/// of a [HermesGelSurface] whose shape casts the glow shadow (its blur is
/// [HermesGel.glowBlur], or half of it while pressed).
List<RenderBox> glowingGels(WidgetTester tester, Finder scope) {
  final glows = find.descendant(
    of: scope,
    matching: find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      return decoration is ShapeDecoration &&
          (decoration.shadows ?? const []).any(
            (shadow) =>
                shadow.blurRadius == HermesGel.glowBlur ||
                shadow.blurRadius == HermesGel.glowBlur / 2,
          );
    }),
  );
  return [
    for (final element in glows.evaluate())
      if (element.findAncestorWidgetOfExactType<HermesGelSurface>() != null)
        element.renderObject! as RenderBox,
  ];
}

/// The glow of [gel] on screen: its box grown by the glow's blur plus its
/// drop, through every transform above it.
Rect glowRectOf(RenderBox gel) => MatrixUtils.transformRect(
  gel.getTransformTo(null),
  (Offset.zero & gel.size).inflate(HermesGel.glowBlur + HermesGel.glowDrop),
);

bool _holds(Rect outer, Rect inner) =>
    outer.left <= inner.left + 0.5 &&
    outer.top <= inner.top + 0.5 &&
    outer.right >= inner.right - 0.5 &&
    outer.bottom >= inner.bottom - 0.5;

/// Every ancestor of [gel], up to the screen, that paints it into a layer of
/// its own (a repaint boundary: a visible fade, a `RepaintBoundary`; an
/// `Opacity` between 0 and 1) or clips it (a `Clip*`, a `Stack` or an
/// `AnimatedSize` that is clipping now, a viewport) and whose box does not
/// hold the whole glow. [surfaceEdges] are the ancestors whose edge is the
/// intended edge of the surface the gel sits on; each is named by the test.
///
/// A layer or clip that is exactly the [screen] (the route's own layer) only
/// ever cuts what lies outside the screen, which nobody sees: it is not a cut.
List<String> glowCuts(
  RenderBox gel, {
  Set<RenderObject> surfaceEdges = const {},
  Rect? screen,
}) {
  final glow = glowRectOf(gel);
  final cuts = <String>[];
  RenderObject child = gel;
  var node = gel.parent;
  while (node != null && node is! RenderView) {
    Rect? box;
    String? why;
    final clip = node.describeApproximatePaintClip(child);
    if (clip != null) {
      box = clip;
      why = 'clips';
    } else if (node is RenderAnimatedSize &&
        node.clipBehavior != Clip.none &&
        node.child != null &&
        (node.child!.size.width > node.size.width ||
            node.child!.size.height > node.size.height)) {
      // It clips only while its child overflows it, mid-resize.
      box = node.paintBounds;
      why = 'clips while it resizes';
    } else if (node.isRepaintBoundary) {
      box = node.paintBounds;
      why = 'paints into its own layer';
    } else if (node is RenderOpacity && node.opacity > 0 && node.opacity < 1) {
      box = node.paintBounds;
      why = 'paints into an opacity layer';
    }
    if (box != null && !surfaceEdges.contains(node)) {
      final onScreen = MatrixUtils.transformRect(
        node.getTransformTo(null),
        box,
      );
      final isScreen =
          screen != null &&
          (onScreen.left - screen.left).abs() < 0.5 &&
          (onScreen.top - screen.top).abs() < 0.5 &&
          (onScreen.right - screen.right).abs() < 0.5 &&
          (onScreen.bottom - screen.bottom).abs() < 0.5;
      if (!isScreen && !_holds(onScreen, glow)) {
        cuts.add(
          '${node.runtimeType} $why to $onScreen, smaller than the glow '
          '$glow (created by ${node.debugCreator})',
        );
      }
    }
    child = node;
    node = node.parent;
  }
  return cuts;
}

/// [glowCuts] for every glowing gel under [scope], which must hold
/// [expected] of them.
void expectGlowsUncut(
  WidgetTester tester,
  Finder scope, {
  required int expected,
  Set<RenderObject> surfaceEdges = const {},
  String? reason,
}) {
  final gels = glowingGels(tester, scope);
  expect(gels, hasLength(expected), reason: reason);
  final view = tester.view;
  final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  for (final gel in gels) {
    expect(
      glowCuts(gel, surfaceEdges: surfaceEdges, screen: screen),
      isEmpty,
      reason: reason,
    );
  }
}
