/// Layout and painting of the TeX syntax tree, with `TextPainter` and canvas
/// paths only (no extra package).
///
/// Every node becomes a [LatexBox]: a width, the height above the baseline,
/// the depth below it and a paint callback. Boxes are built once per
/// (formula, size, colour); painting only replays them.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'latex_ast.dart';
import 'latex_symbols.dart';

/// What a formula is painted with. [fontSize] is the final size in logical
/// pixels (text scale already applied by the caller).
class LatexLayoutStyle {
  const LatexLayoutStyle({
    required this.fontSize,
    required this.color,
    this.fontFamily,
    this.fontFamilyFallback,
    this.display = false,
  });

  final double fontSize;
  final Color color;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;

  /// Display style (`$$...$$`): big operators stack their limits and
  /// fractions are taller.
  final bool display;
}

/// A laid out piece of a formula. Positions are relative to the left end of
/// the baseline: [paint] takes that point.
class LatexBox {
  const LatexBox(this.width, this.ascent, this.descent, this._paint);

  final double width;
  final double ascent;
  final double descent;
  final void Function(Canvas canvas, Offset origin) _paint;

  double get height => ascent + descent;

  void paint(Canvas canvas, Offset origin) => _paint(canvas, origin);
}

/// Lays out [node] for [style].
LatexBox layoutLatex(LatexNode node, LatexLayoutStyle style) =>
    _Layouter(style).layout(node, _Ctx.root(style.fontSize, style.display));

/// Glyph ascent/descent assumed for a text run, in em.
const double _textAscent = 0.74;
const double _textDescent = 0.22;

/// Height of the math axis (centre of `+`, fraction rules) above the baseline.
const double _axisHeight = 0.25;

const double _thin = 0.1667;
const double _medium = 0.2222;
const double _thick = 0.2778;

const double _ruleThickness = 0.06;

class _Ctx {
  const _Ctx({
    required this.size,
    required this.rootSize,
    required this.level,
    required this.display,
    this.font,
  });

  factory _Ctx.root(double size, bool display) =>
      _Ctx(size: size, rootSize: size, level: 0, display: display);

  final double size;
  final double rootSize;
  final int level;
  final bool display;
  final LatexFontStyle? font;

  _Ctx script() {
    final next = level + 1;
    return _Ctx(
      size: rootSize * (next == 1 ? 0.7 : 0.5),
      rootSize: rootSize,
      level: next,
      display: false,
      font: font,
    );
  }

  /// Same level, another size (fraction terms, accents).
  _Ctx scaled(double factor) => _Ctx(
    size: size * factor,
    rootSize: rootSize,
    level: level,
    display: false,
    font: font,
  );

  _Ctx withFont(LatexFontStyle style) => _Ctx(
    size: size,
    rootSize: rootSize,
    level: level,
    display: display,
    font: style,
  );
}

enum _Atom { ord, bin, rel, open, close, punct, op }

class _Layouter {
  _Layouter(this.style);

  final LatexLayoutStyle style;

  Paint _stroke(double width) => Paint()
    ..color = style.color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint get _fill => Paint()
    ..color = style.color
    ..style = PaintingStyle.fill;

  LatexBox layout(LatexNode node, _Ctx c) {
    switch (node) {
      case LatexSymbol():
        return _symbol(node, c);
      case LatexRow():
        return _row(node.children, c);
      case LatexText():
        return _glyphBox(
          node.text,
          size: c.size,
          italic: node.italic,
          bold: node.bold,
        );
      case LatexOperator():
        return _operator(node, c);
      case LatexStyled():
        return layout(node.body, c.withFont(node.style));
      case LatexFrac():
        return _frac(node, c);
      case LatexSqrt():
        return _sqrt(node, c);
      case LatexScripts():
        return _scripts(node, c);
      case LatexDelimited():
        return _wrap(node.left, layout(node.body, c), node.right, c);
      case LatexAccent():
        return _accent(node.kind, layout(node.body, c), c);
      case LatexSpace():
        return LatexBox(node.em * c.size, 0, 0, (_, _) {});
      case LatexGrid():
        return _grid(node, c);
    }
  }

  // Glyphs ---------------------------------------------------------------

  LatexBox _glyphBox(
    String text, {
    required double size,
    bool italic = false,
    bool bold = false,
    String? family,
    double? ascent,
    double? descent,
    double lift = 0,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: style.color,
          fontSize: size,
          fontFamily: family ?? style.fontFamily,
          fontFamilyFallback: style.fontFamilyFallback,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          height: 1.0,
          letterSpacing: 0,
          wordSpacing: 0,
          decoration: TextDecoration.none,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final baseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final width = painter.width + (italic ? size * 0.04 : 0);
    return LatexBox(
      width,
      ascent ?? size * _textAscent,
      descent ?? size * _textDescent,
      (canvas, o) =>
          painter.paint(canvas, Offset(o.dx, o.dy - lift - baseline)),
    );
  }

  LatexBox _symbol(LatexSymbol node, _Ctx c) {
    var text = node.text;
    var italic = node.italic;
    var bold = false;
    String? family;
    switch (c.font) {
      case null:
        break;
      case LatexFontStyle.roman:
      case LatexFontStyle.sans:
        italic = false;
      case LatexFontStyle.bold:
        italic = false;
        bold = true;
      case LatexFontStyle.italic:
      case LatexFontStyle.calligraphic:
        italic = true;
      case LatexFontStyle.boldItalic:
        italic = true;
        bold = true;
      case LatexFontStyle.blackboard:
        final mapped = kLatexBlackboard[text];
        if (mapped != null) {
          text = mapped;
          italic = false;
        } else {
          italic = false;
          bold = true;
        }
      case LatexFontStyle.mono:
        italic = false;
        family = 'monospace';
    }
    return _glyphBox(
      text,
      size: c.size,
      italic: italic,
      bold: bold,
      family: family,
    );
  }

  // Rows -----------------------------------------------------------------

  _Atom? _atomOf(LatexNode node) => switch (node) {
    LatexSymbol(:final kind) => switch (kind) {
      LatexAtomKind.ord => _Atom.ord,
      LatexAtomKind.bin => _Atom.bin,
      LatexAtomKind.rel => _Atom.rel,
      LatexAtomKind.open => _Atom.open,
      LatexAtomKind.close => _Atom.close,
      LatexAtomKind.punct => _Atom.punct,
    },
    LatexOperator() => _Atom.op,
    LatexSpace() => null,
    LatexScripts(:final base) => base is LatexOperator ? _Atom.op : _Atom.ord,
    _ => _Atom.ord,
  };

  double _gap(_Atom a, _Atom b, _Ctx c) {
    if (c.level > 0) return 0;
    switch (a) {
      case _Atom.ord:
      case _Atom.close:
        return switch (b) {
          _Atom.op => _thin,
          _Atom.bin => _medium,
          _Atom.rel => _thick,
          _ => 0,
        };
      case _Atom.op:
        return switch (b) {
          _Atom.ord || _Atom.op => _thin,
          _Atom.rel => _thick,
          _ => 0,
        };
      case _Atom.bin:
        return _medium;
      case _Atom.rel:
        return switch (b) {
          _Atom.rel || _Atom.punct || _Atom.close => 0,
          _ => _thick,
        };
      case _Atom.open:
        return 0;
      case _Atom.punct:
        return _thin;
    }
  }

  LatexBox _row(List<LatexNode> nodes, _Ctx c) {
    final atoms = <_Atom?>[for (final n in nodes) _atomOf(n)];
    // A binary sign that starts a group or follows another operator, or is
    // followed by a relation/closer, is an ordinary sign (`-x`, `(a-)`).
    for (var k = 0; k < atoms.length; k++) {
      if (atoms[k] != _Atom.bin) continue;
      _Atom? before;
      for (var p = k - 1; p >= 0; p--) {
        if (atoms[p] != null) {
          before = atoms[p];
          break;
        }
      }
      _Atom? after;
      for (var n = k + 1; n < atoms.length; n++) {
        if (atoms[n] != null) {
          after = atoms[n];
          break;
        }
      }
      final unary =
          before == null ||
          before == _Atom.bin ||
          before == _Atom.rel ||
          before == _Atom.open ||
          before == _Atom.punct ||
          before == _Atom.op;
      final dangling =
          after == null ||
          after == _Atom.rel ||
          after == _Atom.close ||
          after == _Atom.punct;
      if (unary || dangling) atoms[k] = _Atom.ord;
    }
    final boxes = <LatexBox>[];
    final offsets = <double>[];
    var x = 0.0;
    var ascent = 0.0;
    var descent = 0.0;
    _Atom? previous;
    for (var k = 0; k < nodes.length; k++) {
      final box = layout(nodes[k], c);
      final atom = atoms[k];
      if (atom != null) {
        if (previous != null) x += _gap(previous, atom, c) * c.size;
        previous = atom;
      }
      boxes.add(box);
      offsets.add(x);
      x += box.width;
      ascent = math.max(ascent, box.ascent);
      descent = math.max(descent, box.descent);
    }
    if (boxes.length == 1) return boxes.single;
    return LatexBox(x, ascent, descent, (canvas, o) {
      for (var k = 0; k < boxes.length; k++) {
        boxes[k].paint(canvas, Offset(o.dx + offsets[k], o.dy));
      }
    });
  }

  // Operators ------------------------------------------------------------

  LatexBox _operator(LatexOperator node, _Ctx c) {
    if (!node.large) {
      return _glyphBox(node.name, size: c.size, family: null);
    }
    final integral = '∫∬∭∮'.contains(node.name);
    final opSize = c.size * (c.display ? (integral ? 1.7 : 1.4) : 1.1);
    final glyphHeight = opSize * (integral ? 1.0 : 0.85);
    final axis = c.size * _axisHeight;
    return _glyphBox(
      node.name,
      size: opSize,
      ascent: axis + glyphHeight / 2,
      descent: math.max(0.0, glyphHeight / 2 - axis),
      lift: axis - opSize * 0.3,
    );
  }

  // Fractions ------------------------------------------------------------

  LatexBox _frac(LatexFrac node, _Ctx c) {
    final inner = c.scaled(c.display ? 0.92 : 0.78);
    final top = layout(node.numerator, inner);
    final bottom = layout(node.denominator, inner);
    final size = c.size;
    final axis = size * _axisHeight;
    final rule = node.bar ? math.max(1.0, size * _ruleThickness) : 0.0;
    final clearance = size * (c.display ? 0.2 : 0.12);
    final pad = size * 0.1;
    final width = math.max(top.width, bottom.width) + pad * 2;
    // Baselines of the two terms, measured upwards from the row baseline.
    final topBaseline = axis + rule / 2 + clearance + top.descent;
    final bottomBaseline = axis - rule / 2 - clearance - bottom.ascent;
    final ascent = topBaseline + top.ascent;
    final descent = math.max(0.0, bottom.descent - bottomBaseline);
    final stroke = rule > 0 ? _stroke(rule) : null;
    return LatexBox(width, ascent, descent, (canvas, o) {
      canvas.save();
      canvas.translate(o.dx, o.dy);
      top.paint(canvas, Offset((width - top.width) / 2, -topBaseline));
      bottom.paint(canvas, Offset((width - bottom.width) / 2, -bottomBaseline));
      if (stroke != null) {
        canvas.drawLine(
          Offset(pad / 2, -axis),
          Offset(width - pad / 2, -axis),
          stroke,
        );
      }
      canvas.restore();
    });
  }

  // Roots ----------------------------------------------------------------

  LatexBox _sqrt(LatexSqrt node, _Ctx c) {
    final body = layout(node.body, c);
    final size = c.size;
    final thickness = math.max(1.0, size * _ruleThickness);
    final clearance = size * 0.12;
    final signWidth = size * 0.75;
    final index = node.index == null
        ? null
        : layout(node.index!, _Ctx.root(c.rootSize * 0.5, false));
    final bodyAscent = body.ascent + clearance + thickness;
    final bodyDescent = body.descent;
    final height = bodyAscent + bodyDescent;
    final indexLeft = index == null
        ? 0.0
        : math.max(0.0, index.width - signWidth * 0.35);
    final indexBaseline = index == null
        ? 0.0
        : -bodyDescent + height * 0.5 + index.descent;
    final ascent = index == null
        ? bodyAscent
        : math.max(bodyAscent, indexBaseline + index.ascent);
    final width = indexLeft + signWidth + body.width + size * 0.05;
    final stroke = _stroke(thickness);
    return LatexBox(width, ascent, bodyDescent, (canvas, o) {
      final left = o.dx + indexLeft;
      final topY = o.dy - bodyAscent + thickness / 2;
      final bottomY = o.dy + bodyDescent;
      final h = bottomY - topY;
      final path = Path()
        ..moveTo(left, topY + h * 0.58)
        ..lineTo(left + signWidth * 0.14, topY + h * 0.52)
        ..lineTo(left + signWidth * 0.38, bottomY)
        ..lineTo(left + signWidth, topY)
        ..lineTo(left + signWidth + body.width + size * 0.05, topY);
      canvas.drawPath(path, stroke);
      body.paint(canvas, Offset(left + signWidth, o.dy));
      if (index != null) {
        index.paint(
          canvas,
          Offset(left + signWidth * 0.35 - index.width, o.dy - indexBaseline),
        );
      }
    });
  }

  // Scripts --------------------------------------------------------------

  LatexBox _scripts(LatexScripts node, _Ctx c) {
    final base = layout(node.base, c);
    final inner = c.script();
    final sup = node.sup == null ? null : layout(node.sup!, inner);
    final sub = node.sub == null ? null : layout(node.sub!, inner);
    final size = c.size;
    final baseNode = node.base;
    final stacked =
        node.limits == LatexLimits.limits ||
        (node.limits == LatexLimits.auto &&
            baseNode is LatexOperator &&
            baseNode.limitsByDefault &&
            c.display);
    if (stacked) return _limits(base, sub, sup, size);
    final simple = node.base is LatexSymbol || node.base is LatexText;
    final script = inner.size;
    var up = 0.0;
    var down = 0.0;
    if (sup != null) {
      up = simple
          ? size * 0.38
          : math.max(size * 0.38, base.ascent - script * 0.3);
    }
    if (sub != null) {
      down = simple
          ? size * 0.18
          : math.max(size * 0.18, base.descent + script * 0.2);
    }
    if (sup != null && sub != null) {
      final supBottom = up - sup.descent;
      final subTop = sub.ascent - down;
      final gap = size * 0.2;
      if (supBottom - subTop < gap) down += gap - (supBottom - subTop);
    }
    final kern = size * 0.03;
    final tail = math.max(sup?.width ?? 0.0, sub?.width ?? 0.0);
    final width = base.width + kern + tail + size * 0.04;
    final ascent = math.max(base.ascent, sup == null ? 0.0 : up + sup.ascent);
    final descent = math.max(
      base.descent,
      sub == null ? 0.0 : down + sub.descent,
    );
    return LatexBox(width, ascent, descent, (canvas, o) {
      base.paint(canvas, o);
      final x = o.dx + base.width + kern;
      sup?.paint(canvas, Offset(x, o.dy - up));
      sub?.paint(canvas, Offset(x, o.dy + down));
    });
  }

  LatexBox _limits(LatexBox base, LatexBox? sub, LatexBox? sup, double size) {
    final gap = size * 0.12;
    final width = math.max(
      base.width,
      math.max(sup?.width ?? 0.0, sub?.width ?? 0.0),
    );
    final supBaseline = sup == null ? 0.0 : base.ascent + gap + sup.descent;
    final subBaseline = sub == null ? 0.0 : base.descent + gap + sub.ascent;
    final ascent = sup == null ? base.ascent : supBaseline + sup.ascent;
    final descent = sub == null ? base.descent : subBaseline + sub.descent;
    return LatexBox(width, ascent, descent, (canvas, o) {
      base.paint(canvas, Offset(o.dx + (width - base.width) / 2, o.dy));
      sup?.paint(
        canvas,
        Offset(o.dx + (width - sup.width) / 2, o.dy - supBaseline),
      );
      sub?.paint(
        canvas,
        Offset(o.dx + (width - sub.width) / 2, o.dy + subBaseline),
      );
    });
  }

  // Delimiters -----------------------------------------------------------

  /// [left] and [right] around [body]; the delimiters grow with it.
  LatexBox _wrap(String left, LatexBox body, String right, _Ctx c) {
    if (left == '.' && right == '.') return body;
    final axis = c.size * _axisHeight;
    final half = math.max(body.ascent - axis, body.descent + axis);
    final span = math.max(2 * half + c.size * 0.1, c.size * 1.1);
    final l = _delimiter(left, true, span, c);
    final r = _delimiter(right, false, span, c);
    final width = l.width + body.width + r.width;
    return LatexBox(
      width,
      math.max(body.ascent, math.max(l.ascent, r.ascent)),
      math.max(body.descent, math.max(l.descent, r.descent)),
      (canvas, o) {
        l.paint(canvas, o);
        body.paint(canvas, Offset(o.dx + l.width, o.dy));
        r.paint(canvas, Offset(o.dx + l.width + body.width, o.dy));
      },
    );
  }

  LatexBox _delimiter(String d, bool isLeft, double span, _Ctx c) {
    if (d == '.') return LatexBox(0, 0, 0, (_, _) {});
    final size = c.size;
    final axis = size * _axisHeight;
    if (span <= size * 1.35 && '()[]{}|'.contains(d)) {
      return _glyphBox(d, size: size);
    }
    final ascent = axis + span / 2;
    final descent = math.max(0.0, span / 2 - axis);
    final thickness = math.max(1.0, size * 0.065);
    final stroke = _stroke(thickness);
    final double w = switch (d) {
      '{' || '}' => size * 0.42,
      '|' => size * 0.2,
      '‖' => size * 0.3,
      _ => size * 0.32,
    };
    return LatexBox(w, ascent, descent, (canvas, o) {
      final top = o.dy - ascent;
      final bottom = o.dy + descent;
      final h = bottom - top;
      final mid = (top + bottom) / 2;
      double x(double v) => o.dx + (isLeft ? v : w - v);
      final path = Path();
      switch (d) {
        case '(' || ')':
          path
            ..moveTo(x(w * 0.8), top)
            ..cubicTo(
              x(w * 0.1),
              top + h * 0.28,
              x(w * 0.1),
              top + h * 0.72,
              x(w * 0.8),
              bottom,
            );
        case '[' || ']':
          path
            ..moveTo(x(w * 0.8), top)
            ..lineTo(x(w * 0.25), top)
            ..lineTo(x(w * 0.25), bottom)
            ..lineTo(x(w * 0.8), bottom);
        case '{' || '}':
          final r = math.min(w * 0.4, h * 0.1);
          final a = x(w * 0.85);
          final b = x(w * 0.55);
          final tip = x(w * 0.15);
          path
            ..moveTo(a, top)
            ..quadraticBezierTo(b, top, b, top + r)
            ..lineTo(b, mid - r)
            ..quadraticBezierTo(b, mid, tip, mid)
            ..quadraticBezierTo(b, mid, b, mid + r)
            ..lineTo(b, bottom - r)
            ..quadraticBezierTo(b, bottom, a, bottom);
        case '|':
          path
            ..moveTo(x(w * 0.5), top)
            ..lineTo(x(w * 0.5), bottom);
        case '‖':
          path
            ..moveTo(x(w * 0.3), top)
            ..lineTo(x(w * 0.3), bottom)
            ..moveTo(x(w * 0.7), top)
            ..lineTo(x(w * 0.7), bottom);
        case '⟨' || '⟩':
          path
            ..moveTo(x(w * 0.8), top)
            ..lineTo(x(w * 0.2), mid)
            ..lineTo(x(w * 0.8), bottom);
        case '⌊' || '⌋':
          path
            ..moveTo(x(w * 0.25), top)
            ..lineTo(x(w * 0.25), bottom)
            ..lineTo(x(w * 0.8), bottom);
        case '⌈' || '⌉':
          path
            ..moveTo(x(w * 0.25), bottom)
            ..lineTo(x(w * 0.25), top)
            ..lineTo(x(w * 0.8), top);
        default:
          return;
      }
      canvas.drawPath(path, stroke);
    });
  }

  // Accents --------------------------------------------------------------

  LatexBox _accent(LatexAccentKind kind, LatexBox body, _Ctx c) {
    final size = c.size;
    final thickness = math.max(1.0, size * 0.055);
    final stroke = _stroke(thickness);
    final fill = _fill;
    final under = kind == LatexAccentKind.underline;
    final tall = switch (kind) {
      LatexAccentKind.overline || LatexAccentKind.bar => 0.14,
      _ => 0.26,
    };
    final ascent = under ? body.ascent : body.ascent + size * tall;
    final descent = under ? body.descent + size * 0.14 : body.descent;
    final wide =
        kind == LatexAccentKind.overline ||
        kind == LatexAccentKind.underline ||
        kind == LatexAccentKind.wideHat ||
        kind == LatexAccentKind.wideTilde ||
        kind == LatexAccentKind.overRightArrow;
    final markWidth = wide
        ? math.max(body.width, size * 0.4)
        : math.min(math.max(body.width, size * 0.3), size * 0.55);
    final width = math.max(body.width, markWidth);
    return LatexBox(width, ascent, descent, (canvas, o) {
      final shift = (width - body.width) / 2;
      body.paint(canvas, Offset(o.dx + shift, o.dy));
      final cx = o.dx + width / 2;
      final left = cx - markWidth / 2;
      final right = cx + markWidth / 2;
      final y = o.dy - body.ascent - size * 0.06;
      switch (kind) {
        case LatexAccentKind.underline:
          final yy = o.dy + body.descent + size * 0.08;
          canvas.drawLine(Offset(left, yy), Offset(right, yy), stroke);
        case LatexAccentKind.overline:
        case LatexAccentKind.bar:
          canvas.drawLine(
            Offset(left, y - size * 0.04),
            Offset(right, y - size * 0.04),
            stroke,
          );
        case LatexAccentKind.hat:
        case LatexAccentKind.wideHat:
          canvas.drawPath(
            Path()
              ..moveTo(left, y)
              ..lineTo(cx, y - size * 0.15)
              ..lineTo(right, y),
            stroke,
          );
        case LatexAccentKind.tilde:
        case LatexAccentKind.wideTilde:
          final w = right - left;
          canvas.drawPath(
            Path()
              ..moveTo(left, y)
              ..quadraticBezierTo(
                left + w * 0.25,
                y - size * 0.22,
                cx,
                y - size * 0.08,
              )
              ..quadraticBezierTo(
                left + w * 0.75,
                y + size * 0.06,
                right,
                y - size * 0.1,
              ),
            stroke,
          );
        case LatexAccentKind.vec:
        case LatexAccentKind.overRightArrow:
          final yy = y - size * 0.06;
          final head = size * 0.1;
          canvas.drawLine(Offset(left, yy), Offset(right, yy), stroke);
          canvas.drawLine(
            Offset(right, yy),
            Offset(right - head, yy - head * 0.7),
            stroke,
          );
          canvas.drawLine(
            Offset(right, yy),
            Offset(right - head, yy + head * 0.7),
            stroke,
          );
        case LatexAccentKind.dot:
          canvas.drawCircle(Offset(cx, y - size * 0.05), size * 0.045, fill);
        case LatexAccentKind.ddot:
          canvas.drawCircle(
            Offset(cx - size * 0.1, y - size * 0.05),
            size * 0.045,
            fill,
          );
          canvas.drawCircle(
            Offset(cx + size * 0.1, y - size * 0.05),
            size * 0.045,
            fill,
          );
      }
    });
  }

  // Grids ----------------------------------------------------------------

  LatexBox _grid(LatexGrid node, _Ctx c) {
    final size = c.size;
    final cells = <List<LatexBox>>[
      for (final row in node.rows)
        [for (final cell in row) layout(cell, c.scaled(1))],
    ];
    var columns = 0;
    for (final row in cells) {
      columns = math.max(columns, row.length);
    }
    final widths = List<double>.filled(columns, 0);
    for (final row in cells) {
      for (var j = 0; j < row.length; j++) {
        widths[j] = math.max(widths[j], row[j].width);
      }
    }
    final aligns = <String>[
      for (var j = 0; j < columns; j++)
        node.aligns != null && j < node.aligns!.length
            ? node.aligns![j]
            : switch (node.kind) {
                LatexGridKind.matrix => 'c',
                LatexGridKind.cases => 'l',
                LatexGridKind.aligned => j.isEven ? 'r' : 'l',
              },
    ];
    double gapAfter(int j) => switch (node.kind) {
      LatexGridKind.aligned => j.isEven ? 0.0 : size * 2,
      _ => size,
    };
    final xs = List<double>.filled(columns, 0);
    var x = 0.0;
    for (var j = 0; j < columns; j++) {
      xs[j] = x;
      x += widths[j] + (j < columns - 1 ? gapAfter(j) : 0);
    }
    final width = x;
    final rowAscent = <double>[];
    final rowDescent = <double>[];
    for (final row in cells) {
      var a = size * 0.75;
      var d = size * 0.25;
      for (final box in row) {
        a = math.max(a, box.ascent);
        d = math.max(d, box.descent);
      }
      rowAscent.add(a);
      rowDescent.add(d);
    }
    final rowGap = size * 0.3;
    var total = 0.0;
    for (var r = 0; r < cells.length; r++) {
      total += rowAscent[r] + rowDescent[r];
      if (r < cells.length - 1) total += rowGap;
    }
    final axis = size * _axisHeight;
    final top = axis + total / 2;
    final baselines = <double>[];
    var cursor = top;
    for (var r = 0; r < cells.length; r++) {
      cursor -= rowAscent[r];
      baselines.add(cursor);
      cursor -= rowDescent[r] + rowGap;
    }
    final body = LatexBox(width, top, math.max(0.0, total / 2 - axis), (
      canvas,
      o,
    ) {
      for (var r = 0; r < cells.length; r++) {
        for (var j = 0; j < cells[r].length; j++) {
          final box = cells[r][j];
          final free = widths[j] - box.width;
          final dx = switch (aligns[j]) {
            'l' => 0.0,
            'r' => free,
            _ => free / 2,
          };
          box.paint(canvas, Offset(o.dx + xs[j] + dx, o.dy - baselines[r]));
        }
      }
    });
    return _wrap(node.left, body, node.right, c);
  }
}
