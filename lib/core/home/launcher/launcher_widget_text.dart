// Typesetting of a launcher widget: every text is measured before it is
// painted and never leaves its box.
//
// [LwTypesetter.fit] lays a text out in a box with explicit rules: a number
// of lines, an ellipsis at the end when allowed, a controlled shrink down to
// a legible minimum, and a refusal (null) when the text still does not fit,
// so the painter simplifies the widget instead of letting things collide.
// Everything painted is logged ([LwPaintLog]) for the tests that prove it.
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'launcher_widget_geometry.dart';

/// A text style in widget terms: a size in sp and a role.
class LwType {
  const LwType({
    required this.sp,
    this.weight = FontWeight.w400,
    this.letterSpacing = 0,
    this.tabular = false,
    this.uppercase = false,
    this.lineHeight = 1.2,
  });

  final double sp;
  final FontWeight weight;
  final double letterSpacing;
  final bool tabular;
  final bool uppercase;

  /// Line height as a multiple of the size.
  final double lineHeight;

  /// The same role for live Flutter widgets. MediaQuery owns text scaling;
  /// raster callers continue to measure with [LwTypesetter].
  TextStyle style({required String fontFamily, required Color color}) =>
      TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: const ['Inter', 'Roboto', 'sans-serif'],
        fontSize: sp,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color,
        height: lineHeight,
        leadingDistribution: TextLeadingDistribution.even,
        fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
        decoration: TextDecoration.none,
      );

  LwType at(double sp) => LwType(
    sp: sp,
    weight: weight,
    letterSpacing: letterSpacing,
    tabular: tabular,
    uppercase: uppercase,
    lineHeight: lineHeight,
  );

  static const eyebrow = LwType(
    sp: LwGrid.eyebrow,
    weight: FontWeight.w500,
    letterSpacing: 0.5,
    uppercase: true,
    lineHeight: 1.0,
  );
  static const caption = LwType(sp: LwGrid.caption, lineHeight: 1.1);
  static const captionTabular = LwType(
    sp: LwGrid.caption,
    tabular: true,
    lineHeight: 1.1,
  );
  static const line = LwType(sp: LwGrid.line);
  static const rowLine = LwType(sp: LwGrid.rowLine);
  static const rowTitle = LwType(
    sp: LwGrid.rowTitle,
    weight: FontWeight.w600,
    letterSpacing: -0.15,
  );
  static const title = LwType(
    sp: LwGrid.title,
    weight: FontWeight.w600,
    letterSpacing: -0.4,
    lineHeight: 1.15,
  );
  static const titleSmall = LwType(
    sp: LwGrid.titleSmall,
    weight: FontWeight.w600,
    letterSpacing: -0.3,
    lineHeight: 1.15,
  );
  static const big = LwType(
    sp: LwGrid.big,
    weight: FontWeight.w700,
    letterSpacing: -1.6,
    tabular: true,
    lineHeight: 1.0,
  );
  static const kpi = LwType(
    sp: LwGrid.kpi,
    weight: FontWeight.w700,
    letterSpacing: -1.4,
    tabular: true,
    lineHeight: 1.0,
  );
  static const button = LwType(
    sp: LwGrid.button_,
    weight: FontWeight.w600,
    lineHeight: 1.0,
  );
}

/// A measured text: ready to paint at a known size, never bigger than the
/// box it was fitted to.
class LwTextBox {
  LwTextBox._(this.painter, this.sp, this.truncated, this.text, this.type);

  final TextPainter painter;

  /// The style it was asked in ([sp] may be smaller than [LwType.sp]).
  final LwType type;

  /// It was set smaller than its style's size to fit.
  bool get shrunk => sp < type.sp - 1e-6;

  /// The size it ended at, in sp (after shrinking, if any).
  final double sp;

  /// It ended with an ellipsis.
  final bool truncated;
  final String text;

  double get width => painter.width;
  double get height => painter.height;
  Size get size => painter.size;

  /// Distance from the top of the box to the first baseline.
  double get baseline =>
      painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
}

/// One thing painted, for the tests: where it went and what it was.
class LwPainted {
  const LwPainted(
    this.kind,
    this.rect, {
    this.text,
    this.truncated = false,
    this.shrunk = false,
  });

  /// `text`, `face`, `icon`, `button`, `bar`, `dot`.
  final String kind;

  /// In dp from the widget's top-left corner.
  final Rect rect;
  final String? text;
  final bool truncated;

  /// Set smaller than its style's size (a text) to fit.
  final bool shrunk;

  @override
  String toString() =>
      '$kind ${rect.left.toStringAsFixed(1)},${rect.top.toStringAsFixed(1)} '
      '${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)}'
      '${text == null ? '' : ' "$text"'}${truncated ? ' …' : ''}';
}

class LwPaintLog {
  final List<LwPainted> items = [];

  Iterable<LwPainted> get texts => items.where((p) => p.kind == 'text');

  void add(LwPainted painted) => items.add(painted);
}

/// Measures and paints text for one widget drawing.
class LwTypesetter {
  LwTypesetter({
    required this.fontFamily,
    required this.fontScale,
    required this.textDirection,
    this.locale,
  });

  final String fontFamily;

  /// The system font scale: sp become dp through it.
  final double fontScale;
  final TextDirection textDirection;
  final ui.Locale? locale;

  /// [sp] in dp at the current font scale.
  double dp(double sp) => sp * fontScale;

  TextStyle _style(LwType type, Color color, double sp) => type
      .style(fontFamily: fontFamily, color: color)
      .copyWith(
        fontSize: dp(sp),
        letterSpacing: type.letterSpacing * (sp / type.sp),
      );

  /// Lays [text] out in a box [maxWidth] wide and, when given, [maxHeight]
  /// tall.
  ///
  /// Rules, in order: the text is tried at its own size; when it needs more
  /// than [maxLines] lines (or is taller than [maxHeight]) it is tried a step
  /// smaller, down to [minSp] (by default it does not shrink: the rows of a
  /// list keep one size); at the smallest size it is cut with an ellipsis
  /// when [ellipsis] is allowed (the owner's data: titles, names), never
  /// when it is not (the app's own words, times, figures: whole or absent).
  /// A cut keeps at least [minVisibleEm] ems of text before the ellipsis, and
  /// a word of a script written with spaces is never broken across lines.
  /// Null when it still does not fit: the caller then simplifies the
  /// drawing. A text that fits is never wider than [maxWidth] nor taller
  /// than [maxHeight].
  LwTextBox? fit(
    String text,
    LwType type, {
    required Color color,
    required double maxWidth,
    double? maxHeight,
    int maxLines = 1,
    bool ellipsis = true,
    double? minSp,
    double? shrinkStep,
    double minVisibleEm = 3,
  }) {
    if (text.isEmpty) return null;
    if (maxWidth <= 0 || (maxHeight != null && maxHeight <= 0)) return null;
    final shown = type.uppercase ? text.toUpperCase() : text;
    final least = (minSp ?? type.sp).clamp(1.0, type.sp).toDouble();
    final step = shrinkStep ?? 1.0;
    for (var sp = type.sp; sp >= least - 1e-6; sp -= step) {
      final size = sp < least ? least : sp;
      final style = _style(type, color, size);
      final painter = TextPainter(
        text: TextSpan(text: shown, style: style),
        textDirection: textDirection,
        locale: locale,
        maxLines: maxLines,
        ellipsis: ellipsis ? '…' : null,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: maxWidth);
      final tooTall = maxHeight != null && painter.height > maxHeight + 0.01;
      final tooWide = painter.width > maxWidth + 0.01;
      final cut = painter.didExceedMaxLines;
      final atLeast = size <= least + 1e-6;
      final whole = !cut || (ellipsis && atLeast);
      final legible =
          !_breaksAWord(painter, shown, style, maxWidth) &&
          (!cut ||
              _visibleBeforeEllipsis(painter, style) >=
                  minVisibleEm * dp(size));
      if (!tooTall && !tooWide && whole && legible) {
        return LwTextBox._(painter, size, cut, shown, type);
      }
      if (atLeast) break;
    }
    return null;
  }

  /// Scripts written without spaces between words: a line may end anywhere.
  static final _unspaced = RegExp('[぀-ヿ㐀-䶿一-鿿豈-﫿ｦ-ﾟ]');

  /// True when a laid-out text of more than one line had to split a word
  /// (a word wider than the box): "conver-/sación" is never drawn.
  bool _breaksAWord(
    TextPainter painter,
    String text,
    TextStyle style,
    double maxWidth,
  ) {
    if (painter.computeLineMetrics().length < 2) return false;
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty || _unspaced.hasMatch(word)) continue;
      final one = TextPainter(
        text: TextSpan(text: word, style: style),
        textDirection: textDirection,
        locale: locale,
        maxLines: 1,
        textScaler: TextScaler.noScaling,
      )..layout();
      final wide = one.width > maxWidth + 0.01;
      one.dispose();
      if (wide) return true;
    }
    return false;
  }

  /// How much text, in dp, a one-line cut keeps before its ellipsis (for a
  /// cut of more lines, the full width of its first line).
  double _visibleBeforeEllipsis(TextPainter painter, TextStyle style) {
    final lines = painter.computeLineMetrics();
    if (lines.length > 1) return lines.first.width;
    final dots = TextPainter(
      text: TextSpan(text: '…', style: style),
      textDirection: textDirection,
      textScaler: TextScaler.noScaling,
    )..layout();
    final visible = painter.width - dots.width;
    dots.dispose();
    return visible;
  }

  /// Paints [box] with its top-left at [at] and logs where it went.
  void paint(
    Canvas canvas,
    LwTextBox box,
    Offset at, {
    required LwPaintLog log,
  }) {
    box.painter.paint(canvas, at);
    log.add(
      LwPainted(
        'text',
        Rect.fromLTWH(at.dx, at.dy, box.width, box.height),
        text: box.text,
        truncated: box.truncated,
        shrunk: box.shrunk,
      ),
    );
  }
}
