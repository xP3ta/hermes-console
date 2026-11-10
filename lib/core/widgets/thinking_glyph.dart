import 'package:flutter/widgets.dart';

/// The thinking symbol, a brain (QA 9709, the owner: «un cerebro», not the head
/// with a question mark of `Icons.psychology_alt_rounded`). Material has no
/// brain and the project carries no symbol font, so it is drawn: two
/// hemispheres with three folds each, on Material's 24 grid and about the
/// line of its outlined icons, so it stays crisp from 14 dp up. Hermes
/// Desktop marks a saved memory with a brain too (`tool-icon.tsx`).
///
/// Used like an [Icon]: the [IconTheme]'s size, colour and opacity unless
/// given, and silent for a screen reader unless it has a [semanticLabel].
class ThinkingGlyph extends StatelessWidget {
  const ThinkingGlyph({
    this.size,
    this.color,
    this.semanticLabel,
    this.shadows,
    super.key,
  });

  final double? size;
  final Color? color;
  final String? semanticLabel;

  /// Painted under the glyph, as [Icon.shadows].
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? _grid;
    var ink = color ?? theme.color!;
    final opacity = theme.opacity;
    if (color == null && opacity != null && opacity < 1) {
      ink = ink.withValues(alpha: ink.a * opacity);
    }
    final glyph = ExcludeSemantics(
      child: SizedBox.square(
        dimension: side,
        child: CustomPaint(painter: _BrainPainter(ink, shadows)),
      ),
    );
    final label = semanticLabel;
    return label == null ? glyph : Semantics(label: label, child: glyph);
  }
}

/// The grid the brain is drawn on.
const double _grid = 24;

class _BrainPainter extends CustomPainter {
  _BrainPainter(this.color, this.shadows);

  final Color color;
  final List<Shadow>? shadows;

  /// The line, in grid units.
  static const double _line = 1.9;

  static final Path _brain = _draw();

  static Path _draw() {
    // The left hemisphere: its outline from the top of the middle, round
    // its three lobes, down to the bottom of the middle; then its folds,
    // each from where two lobes meet.
    final half = Path()
      ..moveTo(12, 5.2)
      ..cubicTo(11.2, 3.4, 7.6, 3.0, 6.8, 5.8)
      ..cubicTo(4.2, 6.2, 3.0, 9.4, 4.4, 11.6)
      ..cubicTo(2.8, 13.6, 3.8, 17.2, 6.6, 17.4)
      ..cubicTo(7.4, 20.2, 11.0, 20.6, 12, 18.8)
      ..moveTo(6.8, 5.8)
      ..cubicTo(6.9, 7.2, 7.8, 8.2, 9.2, 8.4)
      ..moveTo(4.4, 11.6)
      ..cubicTo(5.4, 12.6, 7.2, 12.8, 8.4, 12.0)
      ..moveTo(6.6, 17.4)
      ..cubicTo(7.2, 16.4, 8.2, 15.8, 9.4, 15.8);
    // The right one is its mirror; the middle line parts them.
    final mirror = Matrix4.diagonal3Values(-1, 1, 1)
      ..setTranslationRaw(_grid, 0, 0);
    return Path()
      ..addPath(half, Offset.zero)
      ..addPath(half.transform(mirror.storage), Offset.zero)
      ..moveTo(12, 5.2)
      ..lineTo(12, 18.8);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _grid;
    final path = _brain.transform(
      Matrix4.diagonal3Values(scale, scale, 1).storage,
    );
    Paint stroke(Color ink) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _line * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..color = ink;
    for (final shadow in shadows ?? const <Shadow>[]) {
      canvas.drawPath(
        path.shift(shadow.offset),
        stroke(shadow.color)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blurSigma),
      );
    }
    canvas.drawPath(path, stroke(color));
  }

  @override
  bool shouldRepaint(_BrainPainter oldDelegate) =>
      oldDelegate.color != color || !_sameShadows(oldDelegate.shadows);

  bool _sameShadows(List<Shadow>? other) {
    final mine = shadows;
    if (identical(mine, other)) return true;
    if (mine == null || other == null || mine.length != other.length) {
      return false;
    }
    for (var i = 0; i < mine.length; i++) {
      if (mine[i] != other[i]) return false;
    }
    return true;
  }
}
