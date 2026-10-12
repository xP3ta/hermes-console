import 'package:flutter/material.dart';

/// Marks a subtree hosted by a floating modal surface. Scrollables inside it
/// clamp instead of bouncing: a picker whose content fits must not wobble.
class HermesModalScrollScope extends InheritedWidget {
  const HermesModalScrollScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context
          .getElementForInheritedWidgetOfExactType<HermesModalScrollScope>() !=
      null;

  @override
  bool updateShouldNotify(HermesModalScrollScope oldWidget) => false;
}

/// Comportamiento de scroll de toda la app: física con **inercia** (coasting)
/// estilo iOS/Telegram. Un "flick" rápido del dedo sigue rodando y frena solo
/// cuando se le acaba el impulso, en vez del frenazo seco del scroll Material
/// por defecto (`ClampingScrollPhysics`).
///
/// Spec 080: `AlwaysScrollableScrollPhysics` applies only to **page-level**
/// vertical scrollables (no enclosing vertical scrollable), so pull-to-refresh
/// keeps working on short pages. Inner blocks and horizontal strips scroll
/// only when their content overflows — they never bounce when everything
/// fits — and scrollables inside floating modal surfaces clamp.
class MomentumScrollBehavior extends MaterialScrollBehavior {
  const MomentumScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (HermesModalScrollScope.of(context)) {
      return const ClampingScrollPhysics();
    }
    final widget = context.widget;
    final vertical =
        widget is! Scrollable ||
        axisDirectionToAxis(widget.axisDirection) == Axis.vertical;
    if (vertical && isPageLevelScrollable(context)) {
      return const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      );
    }
    return const BouncingScrollPhysics();
  }

  /// A page's list that scrolls under the floating header does not clip
  /// itself (`clipBehavior: Clip.none`), so its rows keep painting past its
  /// upper edge. It still has to end somewhere: at its sides, at its lower
  /// edge (rows waiting below must not show behind what follows the list)
  /// and at the top of the screen. That is also what a screen reader is
  /// told: a row under the header is on screen, the ones above the screen
  /// or below the list are hidden until scrolled to.
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final built = super.buildOverscrollIndicator(context, child, details);
    if (details.decorationClipBehavior != Clip.none ||
        axisDirectionToAxis(details.direction) != Axis.vertical) {
      return built;
    }
    return ClipRect(
      clipper: UnderHeaderClipper(
        MediaQuery.viewPaddingOf(context).top + kToolbarHeight,
      ),
      child: built,
    );
  }

  /// True when no vertical [Scrollable] encloses [context]. Routes live as
  /// siblings in the Overlay, so a pushed page never sees the page below.
  static bool isPageLevelScrollable(BuildContext context) {
    var nested = false;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Scrollable &&
          axisDirectionToAxis(widget.axisDirection) == Axis.vertical) {
        nested = true;
        return false;
      }
      return true;
    });
    return !nested;
  }
}

/// The area a list that scrolls under the floating header may paint in: its
/// own box, opened upwards by [reach] (the header: status bar and toolbar).
class UnderHeaderClipper extends CustomClipper<Rect> {
  const UnderHeaderClipper(this.reach);

  /// How far above the list its rows are still painted.
  final double reach;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, -reach, size.width, size.height);

  @override
  Rect getApproximateClipRect(Size size) => getClip(size);

  @override
  bool shouldReclip(UnderHeaderClipper oldClipper) => oldClipper.reach != reach;
}
