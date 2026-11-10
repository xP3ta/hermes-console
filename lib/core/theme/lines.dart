// The lines of a theme: the divider between two rows, the contour of a box,
// the outline of a control, the ink of a disabled label.
//
// None of them is a fixed alpha any more. A fixed alpha of white (or of the
// ink) reads differently on every page: 35 % of a dark divider over a
// charcoal body came out at 1.1:1, invisible in a capture, while the same
// alpha on a black page was fine. Each line is searched, per theme and per
// body it sits on, for the least opacity that reaches its target:
//
//  * a divider: [dividerRatio] against the body it splits (a decorative
//    separator only has to be seen);
//  * a contour: [contourRatio] against the page outside the box (a box is
//    also set apart by its solid body, so its contour needs less than a
//    control's);
//  * the edge of a floating piece (the dock, a header pill, a back button,
//    a menu): [edgeRatio], a component's boundary, against the page;
//  * a control's outline: [controlRatio], WCAG 1.4.11, against the body the
//    control sits on and against the page;
//  * a disabled label: [disabledRatio], so a disabled button still says
//    what it would do.
//
// On a dark page the line is the page's light (white, or the page's own
// tinted light, [HermesPageTint.veil]); on a light page it is the main ink.
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'box_fill.dart';
import 'theme_contrast.dart';

@immutable
final class HermesLines {
  const HermesLines._({
    required this.dark,
    required this.page,
    required this.colors,
    required this.divider,
    required this.bareDivider,
    required this.control,
    required this.disabledInk,
  });

  /// Contour of a box (a group, a card, a floating piece) against the page.
  static const double contourRatio = 2.0;

  /// Divider between the rows of a list, against the body it splits.
  static const double dividerRatio = 1.5;

  /// Edge of a floating piece (the dock, a header pill, a back button, a
  /// menu) against the page: the boundary of a component, WCAG 1.4.11. It
  /// floats over any content, so its edge carries the shape on its own.
  static const double edgeRatio = 3.0;

  /// Outline of a control (a field, a switch's track, a chip): WCAG 1.4.11.
  static const double controlRatio = 3.0;

  /// A disabled label on its fill.
  static const double disabledRatio = 3.0;

  /// The least alpha a line is ever painted at: below it the 8-bit rounding
  /// of the compositor eats the difference.
  static const double leastAlpha = 0.06;

  final bool dark;
  final Color page;
  final HermesThemeColors colors;

  /// The divider between two rows on the body of a group.
  final Color divider;

  /// The divider a bare `Divider()` paints, wherever it lands: the strongest
  /// of the lines that reach [dividerRatio] on the page, on the surface and
  /// on the body of a group (a line tuned on the lifted body alone fell to
  /// 1.37:1 on a near-black page).
  final Color bareDivider;

  /// The outline of a control on the body of a group (and on the page).
  final Color control;

  /// The ink of a disabled label on the body of a group.
  final Color disabledInk;

  static final Expando<HermesLines> _cache = Expando('HermesLines');

  static HermesLines of(HermesThemeColors colors) =>
      _cache[colors] ??= _derive(colors);

  static HermesLines _derive(HermesThemeColors colors) {
    final fill = HermesBoxFill.of(colors);
    final dark = fill.dark;
    final page = fill.page;
    Color ink(double alpha) => dark
        ? HermesPageTint.veil(page, alpha)
        : colors.textPrimary.withValues(alpha: alpha);
    final surface = ThemeContrast.composite(colors.surface, page);
    Color dividerOn(Color body) => HermesLineSearch.reach(
      ink: ink,
      body: body,
      against: [body],
      ratio: dividerRatio,
    );
    final divider = dividerOn(fill.group);
    final bare = [
      divider,
      dividerOn(page),
      dividerOn(surface),
    ].reduce((a, b) => a.a >= b.a ? a : b);
    return HermesLines._(
      dark: dark,
      page: page,
      colors: colors,
      divider: divider,
      bareDivider: bare,
      control: HermesLineSearch.reach(
        ink: ink,
        body: fill.group,
        against: [fill.group, page, fill.card],
        ratio: controlRatio,
      ),
      disabledInk: ThemeContrast.adjustForContrast(colors.textDisabled, [
        fill.group,
        fill.card,
        page,
      ], minimum: disabledRatio),
    );
  }

  Color _ink(double alpha) => dark
      ? HermesPageTint.veil(page, alpha)
      : colors.textPrimary.withValues(alpha: alpha);

  /// The divider between two rows on [body].
  Color dividerOn(Color body) => HermesLineSearch.reach(
    ink: _ink,
    body: body,
    against: [body],
    ratio: dividerRatio,
  );

  /// The outline of a control on [body].
  Color controlOn(Color body) => HermesLineSearch.reach(
    ink: _ink,
    body: body,
    against: [body, page],
    ratio: controlRatio,
  );

  /// The contour of a box whose body is [body], against the page outside.
  Color contourOn(Color body) => HermesLineSearch.reach(
    ink: _ink,
    body: body,
    against: [page],
    ratio: contourRatio,
  );

  /// The edge of a floating piece whose body is [body], against the page.
  Color edgeOn(Color body) => HermesLineSearch.reach(
    ink: _ink,
    body: body,
    against: [page],
    ratio: edgeRatio,
  );

  /// The outline of a text field: a control's.
  Color get fieldBorder => control;

  /// The ink of a disabled label on [body].
  Color disabledInkOn(Color body) => ThemeContrast.adjustForContrast(
    colors.textDisabled,
    [body],
    minimum: disabledRatio,
  );
}

/// The search every line shares: the least alpha, from [floor] up in steps
/// of one per cent, at which [ink] laid over [body] reaches [ratio] (plus
/// [margin], for the 8-bit rounding of the painted pixel) against every
/// colour of [against]. Opaque ink when none does.
abstract final class HermesLineSearch {
  /// A little over the target: the painted alpha is quantised to 8 bits.
  static const double margin = 0.02;

  static Color reach({
    required Color Function(double alpha) ink,
    required Color body,
    required List<Color> against,
    required double ratio,
    double floor = HermesLines.leastAlpha,
  }) {
    for (var percent = (floor * 100).round(); percent <= 100; percent++) {
      final line = ink(percent / 100);
      final pixel = ThemeContrast.composite(line, body);
      var ok = true;
      for (final back in against) {
        if (ThemeContrast.ratio(pixel, back) + 1e-9 < ratio + margin) {
          ok = false;
          break;
        }
      }
      if (ok) return line;
    }
    return ink(1);
  }
}
