import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/latex/latex_layout.dart';
import '../../utils/latex/latex_parser.dart';

const int _boxCacheLimit = 64;

/// Laid out formulas, least recently used first. The markdown renderer gives
/// every paragraph a new key whenever it re-parses, so a widget state cannot
/// hold the layout: a streaming answer would lay every formula out again on
/// each token, and one scrolling back into view would too.
final Map<Object, LatexBox> _boxCache = <Object, LatexBox>{};

LatexBox _cachedBox(
  String source,
  bool display,
  TextStyle base,
  double size,
  Color color,
) {
  final key = (
    source,
    display,
    size,
    color,
    base.fontFamily,
    base.fontFamilyFallback?.join(','),
  );
  final hit = _boxCache.remove(key);
  if (hit != null) {
    _boxCache[key] = hit;
    return hit;
  }
  final box = layoutLatex(
    tryParseLatex(source)!,
    LatexLayoutStyle(
      fontSize: size,
      color: color,
      fontFamily: base.fontFamily,
      fontFamilyFallback: base.fontFamilyFallback,
      display: display,
    ),
  );
  _boxCache[key] = box;
  if (_boxCache.length > _boxCacheLimit) {
    _boxCache.remove(_boxCache.keys.first);
  }
  return box;
}

/// A TeX formula painted natively (no web view, no package).
///
/// [source] is the TeX between the delimiters. When it cannot be parsed the
/// widget shows the source as plain text, so a bad formula never breaks the
/// message. The size and colour come from [style] over the ambient text style,
/// scaled by the system text scale; [display] is `$$...$$` (centered, scrolls
/// sideways when wider than its slot).
///
/// Selecting and copying work like text: an invisible run holding the source
/// (`$...$` or `$$...$$`) sits under the formula and is what a selection
/// covers and copies.
class LatexView extends StatelessWidget {
  const LatexView({
    super.key,
    required this.source,
    this.display = false,
    this.style,
    this.scaleText = true,
  });

  final String source;
  final bool display;
  final TextStyle? style;

  /// Applies the system text scale to the size. An inline formula inside a
  /// `WidgetSpan` passes false: the paragraph already scales its inline
  /// widgets, and doing it twice would make the formula too big.
  final bool scaleText;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    if (tryParseLatex(source) == null) {
      return Text(source, style: base);
    }
    final fontSize = base.fontSize ?? 14.0;
    final size = scaleText
        ? MediaQuery.textScalerOf(context).scale(fontSize)
        : fontSize;
    final color = base.color ?? Theme.of(context).colorScheme.onSurface;
    final box = _cachedBox(source, display, base, size, color);
    final copyText = display ? '\$\$$source\$\$' : '\$$source\$';
    final label =
        Localizations.of<Strings>(
          context,
          Strings,
        )?.latexFormulaLabel(source) ??
        source;
    final formula = Semantics(
      label: label,
      excludeSemantics: true,
      child: LatexFormula(
        box: box,
        child: FittedBox(
          fit: BoxFit.fill,
          child: Text(
            copyText,
            softWrap: false,
            maxLines: 1,
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              color: color.withValues(alpha: 0),
              fontSize: size,
              fontFamily: base.fontFamily,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
    if (!display) return formula;
    final pad = size * 0.3;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: pad),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
            ),
            child: Center(child: formula),
          ),
        ),
      ),
    );
  }
}

/// Paints a laid out [LatexBox]. Its baseline is the formula baseline, so an
/// inline `WidgetSpan` with baseline alignment sits on the line of text. The
/// optional [child] (the invisible selectable run) is stretched over the box.
class LatexFormula extends SingleChildRenderObjectWidget {
  const LatexFormula({super.key, required this.box, super.child});

  final LatexBox box;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderLatexFormula(box);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderLatexFormula renderObject,
  ) {
    renderObject.box = box;
  }
}

class RenderLatexFormula extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  RenderLatexFormula(this._box);

  LatexBox _box;

  /// Factor the formula was shrunk by to fit the width it was given.
  double _scale = 1;

  LatexBox get box => _box;

  set box(LatexBox value) {
    if (identical(value, _box)) return;
    _box = value;
    markNeedsLayout();
  }

  /// A formula wider than its slot (an inline one at a large text size)
  /// shrinks to fit rather than losing its end. A display formula is laid out
  /// without a width limit inside its scroll view, so it keeps its size.
  double _fitFor(BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth || _box.width <= constraints.maxWidth) {
      return 1;
    }
    return constraints.maxWidth / _box.width;
  }

  Size _sizeFor(BoxConstraints constraints) {
    final fit = _fitFor(constraints);
    return constraints.constrain(Size(_box.width * fit, _box.height * fit));
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _box.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _box.width;

  @override
  double computeMinIntrinsicHeight(double width) => _box.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _box.height;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _sizeFor(constraints);

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) => _box.ascent * _fitFor(constraints);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      _box.ascent * _scale;

  @override
  void performLayout() {
    _scale = _fitFor(constraints);
    size = _sizeFor(constraints);
    child?.layout(BoxConstraints.tight(size));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      child?.hitTest(result, position: position) ?? false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final run = child;
    if (run != null) context.paintChild(run, offset);
    final canvas = context.canvas;
    if (_scale == 1) {
      _box.paint(canvas, offset + Offset(0, _box.ascent));
      return;
    }
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..scale(_scale);
    _box.paint(canvas, Offset(0, _box.ascent));
    canvas.restore();
  }
}
