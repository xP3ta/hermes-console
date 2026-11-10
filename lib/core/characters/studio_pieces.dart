import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'bot_character.dart';
import 'studio_catalog.dart';

/// The drawing of one kind of piece, in local units centred on (0, 0) and
/// facing up. One unit is one unit of the 100 x 100 canvas at scale 1.
final class PieceArt {
  /// Main fill.
  final Path? fill;

  /// Second tone laid over the fill (inner ear, highlight, centre).
  final Path? detail;

  /// A stroked line in the main colour (tail, stem, spiral).
  final Path? line;
  final double lineWidth;

  /// Fixed colour of the piece; null takes the body's colour.
  final String? mainHex;

  /// Fixed colour of the detail; null shades the main colour.
  final String? detailHex;

  /// Drawn before the body so that its base hides behind it.
  final bool behind;

  /// Box that holds the piece, used for the selection frame.
  final Rect bounds;

  const PieceArt({
    this.fill,
    this.detail,
    this.line,
    this.lineWidth = 3,
    this.mainHex,
    this.detailHex,
    this.behind = false,
    required this.bounds,
  });
}

/// Builds and caches the art of every [BotPieceKind].
abstract final class StudioPieces {
  static final Map<BotPieceKind, PieceArt> _cache = {};

  static PieceArt of(BotPieceKind kind) => _cache[kind] ??= _build(kind);

  /// The frame of [piece] on the 100 x 100 canvas: its four corners, in
  /// order top-left, top-right, bottom-right, bottom-left after the turn,
  /// size and flip of the piece.
  static List<Offset> corners(BotPiece piece) {
    final box = of(piece.kind).bounds;
    return [
      for (final corner in [
        box.topLeft,
        box.topRight,
        box.bottomRight,
        box.bottomLeft,
      ])
        toCanvas(piece, corner),
    ];
  }

  /// A point in the local units of [piece] on the 100 x 100 canvas.
  static Offset toCanvas(BotPiece piece, Offset local) {
    final angle = piece.rotation * math.pi / 180;
    final sx = (piece.flip ? -1 : 1) * piece.scale * local.dx;
    final sy = piece.scale * local.dy;
    return Offset(
      piece.x * 100 + sx * math.cos(angle) - sy * math.sin(angle),
      piece.y * 100 + sx * math.sin(angle) + sy * math.cos(angle),
    );
  }

  /// The inverse of [toCanvas].
  static Offset toLocal(BotPiece piece, Offset canvasPoint) {
    final angle = piece.rotation * math.pi / 180;
    final dx = canvasPoint.dx - piece.x * 100;
    final dy = canvasPoint.dy - piece.y * 100;
    final ux = dx * math.cos(angle) + dy * math.sin(angle);
    final uy = -dx * math.sin(angle) + dy * math.cos(angle);
    return Offset(ux / (piece.scale * (piece.flip ? -1 : 1)), uy / piece.scale);
  }

  /// True when [canvasPoint] falls inside the frame of [piece].
  static bool hits(BotPiece piece, Offset canvasPoint) =>
      of(piece.kind).bounds.inflate(1.5).contains(toLocal(piece, canvasPoint));

  /// Paints [piece] in canvas units. [body] is the colour of body-toned
  /// pieces.
  static void paint(Canvas canvas, BotPiece piece, Color body) {
    final art = of(piece.kind);
    final main = art.mainHex == null ? body : colorFromHex(art.mainHex!);
    final detail = art.detailHex != null
        ? colorFromHex(art.detailHex!)
        : Color.lerp(
            main,
            main.computeLuminance() > 0.35
                ? const Color.fromARGB(255, 0, 0, 0)
                : const Color.fromARGB(255, 255, 255, 255),
            0.26,
          )!;
    canvas.save();
    canvas.translate(piece.x * 100, piece.y * 100);
    canvas.rotate(piece.rotation * math.pi / 180);
    canvas.scale(piece.flip ? -piece.scale : piece.scale, piece.scale);
    final line = art.line;
    if (line != null) {
      canvas.drawPath(
        line,
        Paint()
          ..color = main
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = art.lineWidth,
      );
    }
    final fill = art.fill;
    if (fill != null) {
      canvas.drawPath(fill, Paint()..color = main);
    }
    final extra = art.detail;
    if (extra != null) {
      canvas.drawPath(extra, Paint()..color = detail);
    }
    canvas.restore();
  }

  static PieceArt _build(BotPieceKind kind) {
    switch (kind) {
      case BotPieceKind.catEars:
        return PieceArt(
          behind: true,
          fill: Path()
            ..addPath(_poly([_p(-27, 9), _p(-19, -14), _p(-6, 3)]), Offset.zero)
            ..addPath(_poly([_p(27, 9), _p(19, -14), _p(6, 3)]), Offset.zero),
          detail: Path()
            ..addPath(_poly([_p(-23, 4), _p(-19, -7), _p(-11, 1)]), Offset.zero)
            ..addPath(_poly([_p(23, 4), _p(19, -7), _p(11, 1)]), Offset.zero),
          bounds: const Rect.fromLTRB(-28, -15, 28, 10),
        );
      case BotPieceKind.bearEars:
        return PieceArt(
          behind: true,
          fill: Path()
            ..addOval(
              Rect.fromCircle(center: const Offset(-20, 0), radius: 9.5),
            )
            ..addOval(
              Rect.fromCircle(center: const Offset(20, 0), radius: 9.5),
            ),
          detail: Path()
            ..addOval(
              Rect.fromCircle(center: const Offset(-20, 0), radius: 4.8),
            )
            ..addOval(
              Rect.fromCircle(center: const Offset(20, 0), radius: 4.8),
            ),
          bounds: const Rect.fromLTRB(-30, -10, 30, 10),
        );
      case BotPieceKind.bunnyEars:
        return PieceArt(
          behind: true,
          fill: Path()
            ..addPath(_ellipse(-9, 0, 6.5, 17, -10), Offset.zero)
            ..addPath(_ellipse(9, 0, 6.5, 17, 10), Offset.zero),
          detail: Path()
            ..addPath(_ellipse(-9, 1, 3.2, 12, -10), Offset.zero)
            ..addPath(_ellipse(9, 1, 3.2, 12, 10), Offset.zero),
          bounds: const Rect.fromLTRB(-18, -18, 18, 18),
        );
      case BotPieceKind.crown:
        return PieceArt(
          mainHex: '#fbbf24',
          detailHex: '#f59e0b',
          fill: _poly([
            _p(-16, 10),
            _p(-18, -8),
            _p(-9, 0),
            _p(0, -12),
            _p(9, 0),
            _p(18, -8),
            _p(16, 10),
          ]),
          detail: _poly([_p(-16.6, 4), _p(16.6, 4), _p(16, 10), _p(-16, 10)]),
          bounds: const Rect.fromLTRB(-19, -13, 19, 11),
        );
      case BotPieceKind.horn:
        return PieceArt(
          mainHex: '#fde68a',
          detailHex: '#fcd34d',
          fill: Path()
            ..moveTo(-7, 12)
            ..quadraticBezierTo(-5, -4, 3, -17)
            ..quadraticBezierTo(8, -3, 7, 12)
            ..close(),
          detail: Path()
            ..moveTo(-2, 10)
            ..quadraticBezierTo(-1, -2, 3, -12)
            ..quadraticBezierTo(3, 0, 3, 10)
            ..close(),
          bounds: const Rect.fromLTRB(-8, -18, 9, 13),
        );
      case BotPieceKind.halo:
        return PieceArt(
          mainHex: '#fde047',
          fill: Path()
            ..fillType = PathFillType.evenOdd
            ..addOval(
              Rect.fromCenter(center: Offset.zero, width: 40, height: 12),
            )
            ..addOval(
              Rect.fromCenter(center: Offset.zero, width: 28, height: 5),
            ),
          bounds: const Rect.fromLTRB(-21, -7, 21, 7),
        );
      case BotPieceKind.swirl:
        final spiral = Path()..moveTo(0.5, 0);
        for (var i = 1; i <= 52; i++) {
          final angle = i * 0.42;
          final radius = 0.5 + i * 0.27;
          spiral.lineTo(radius * math.cos(angle), radius * math.sin(angle));
        }
        return PieceArt(
          mainHex: '#8b5cf6',
          line: spiral,
          lineWidth: 3,
          bounds: const Rect.fromLTRB(-16, -16, 16, 16),
        );
      case BotPieceKind.sprout:
        return PieceArt(
          behind: true,
          mainHex: '#22c55e',
          line: Path()
            ..moveTo(0, 16)
            ..quadraticBezierTo(2, 4, 0, -6),
          lineWidth: 3,
          fill: Path()
            ..addPath(_ellipse(-8, -9, 8, 4, -35), Offset.zero)
            ..addPath(_ellipse(8, -9, 8, 4, 35), Offset.zero),
          bounds: const Rect.fromLTRB(-17, -18, 17, 17),
        );
      case BotPieceKind.leaf:
        return PieceArt(
          mainHex: '#4ade80',
          detailHex: '#16a34a',
          fill: Path()
            ..moveTo(0, 16)
            ..quadraticBezierTo(-17, 2, 0, -16)
            ..quadraticBezierTo(17, 2, 0, 16)
            ..close(),
          detail: _poly([
            _p(-0.8, 14),
            _p(0.8, 14),
            _p(0.8, -12),
            _p(-0.8, -12),
          ]),
          bounds: const Rect.fromLTRB(-13, -17, 13, 17),
        );
      case BotPieceKind.wing:
        return PieceArt(
          mainHex: '#f1f5f9',
          detailHex: '#cbd5e1',
          fill: Path()
            ..moveTo(10, 10)
            ..cubicTo(8, -6, -6, -16, -22, -14)
            ..cubicTo(-18, -8, -18, -4, -14, -2)
            ..cubicTo(-14, 2, -10, 4, -8, 6)
            ..cubicTo(-6, 8, 2, 10, 10, 10)
            ..close(),
          detail: Path()
            ..moveTo(6, 8)
            ..cubicTo(4, -2, -6, -9, -16, -9)
            ..cubicTo(-12, -5, -10, -2, -8, 2)
            ..cubicTo(-6, 5, 0, 7, 6, 8)
            ..close(),
          bounds: const Rect.fromLTRB(-23, -17, 11, 12),
        );
      case BotPieceKind.tail:
        return PieceArt(
          behind: true,
          line: Path()
            ..moveTo(-12, 14)
            ..cubicTo(-16, 0, 0, -6, 12, -14),
          lineWidth: 8,
          fill: Path()
            ..addOval(
              Rect.fromCircle(center: const Offset(12, -14), radius: 5.5),
            ),
          bounds: const Rect.fromLTRB(-17, -20, 18, 18),
        );
      case BotPieceKind.star:
        return PieceArt(
          mainHex: '#fbbf24',
          fill: _star(16, 6.8),
          bounds: const Rect.fromLTRB(-16, -16, 16, 15),
        );
      case BotPieceKind.heart:
        return PieceArt(
          mainHex: '#fb7185',
          detailHex: '#fecdd3',
          fill: Path()
            ..moveTo(0, 14)
            ..cubicTo(-22, 0, -14, -16, 0, -6)
            ..cubicTo(14, -16, 22, 0, 0, 14)
            ..close(),
          detail: _ellipse(-8, -6, 3.4, 2, -40),
          bounds: const Rect.fromLTRB(-16, -13, 16, 15),
        );
      case BotPieceKind.bow:
        return PieceArt(
          mainHex: '#f472b6',
          detailHex: '#db2777',
          fill: Path()
            ..addPath(_poly([_p(0, 0), _p(-19, -11), _p(-19, 11)]), Offset.zero)
            ..addPath(_poly([_p(0, 0), _p(19, -11), _p(19, 11)]), Offset.zero),
          detail: Path()
            ..addOval(Rect.fromCircle(center: Offset.zero, radius: 4.6)),
          bounds: const Rect.fromLTRB(-20, -12, 20, 12),
        );
      case BotPieceKind.paw:
        return PieceArt(
          mainHex: '#f9a8d4',
          fill: Path()
            ..addOval(
              Rect.fromCenter(
                center: const Offset(0, 6),
                width: 18,
                height: 15,
              ),
            )
            ..addOval(
              Rect.fromCircle(center: const Offset(-12, -5), radius: 4.2),
            )
            ..addOval(
              Rect.fromCircle(center: const Offset(-4, -11), radius: 4.2),
            )
            ..addOval(
              Rect.fromCircle(center: const Offset(4, -11), radius: 4.2),
            )
            ..addOval(
              Rect.fromCircle(center: const Offset(12, -5), radius: 4.2),
            ),
          bounds: const Rect.fromLTRB(-16, -15, 16, 14),
        );
      case BotPieceKind.fin:
        return PieceArt(
          fill: Path()
            ..moveTo(-4, 14)
            ..cubicTo(-12, 0, -8, -12, 4, -18)
            ..cubicTo(6, -8, 12, 4, 8, 14)
            ..close(),
          detail: Path()
            ..moveTo(-1, 10)
            ..cubicTo(-5, 0, -3, -8, 3, -12)
            ..cubicTo(3, -4, 6, 2, 5, 10)
            ..close(),
          bounds: const Rect.fromLTRB(-12, -19, 11, 15),
        );
      case BotPieceKind.bolt:
        return PieceArt(
          mainHex: '#facc15',
          fill: _poly([
            _p(4, -18),
            _p(-10, 2),
            _p(-1, 2),
            _p(-5, 18),
            _p(11, -4),
            _p(2, -4),
          ]),
          bounds: const Rect.fromLTRB(-11, -19, 12, 19),
        );
      case BotPieceKind.flower:
        final petals = Path();
        for (var i = 0; i < 5; i++) {
          final angle = -math.pi / 2 + i * 2 * math.pi / 5;
          petals.addOval(
            Rect.fromCircle(
              center: Offset(8.5 * math.cos(angle), 8.5 * math.sin(angle)),
              radius: 6.2,
            ),
          );
        }
        return PieceArt(
          mainHex: '#f472b6',
          detailHex: '#fde047',
          fill: petals,
          detail: Path()
            ..addOval(Rect.fromCircle(center: Offset.zero, radius: 4.6)),
          bounds: const Rect.fromLTRB(-15, -15, 15, 15),
        );
      case BotPieceKind.moon:
        return PieceArt(
          mainHex: '#fde68a',
          fill: Path.combine(
            PathOperation.difference,
            Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: 15)),
            Path()..addOval(
              Rect.fromCircle(center: const Offset(7, -4), radius: 12.5),
            ),
          ),
          bounds: const Rect.fromLTRB(-16, -16, 12, 16),
        );
      case BotPieceKind.drop:
        return PieceArt(
          mainHex: '#38bdf8',
          detailHex: '#bae6fd',
          fill: Path()
            ..moveTo(0, -16)
            ..cubicTo(8, -4, 13, 2, 13, 7)
            ..cubicTo(13, 14, 7, 18, 0, 18)
            ..cubicTo(-7, 18, -13, 14, -13, 7)
            ..cubicTo(-13, 2, -8, -4, 0, -16)
            ..close(),
          detail: _ellipse(-5, 6, 2.2, 4.2, 15),
          bounds: const Rect.fromLTRB(-14, -17, 14, 19),
        );
    }
  }

  static Offset _p(double x, double y) => Offset(x, y);

  static Path _poly(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    return path..close();
  }

  static Path _ellipse(
    double cx,
    double cy,
    double rx,
    double ry,
    double degrees,
  ) {
    final angle = degrees * math.pi / 180;
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    final matrix = Float64List(16)
      ..[0] = cosA
      ..[1] = sinA
      ..[4] = -sinA
      ..[5] = cosA
      ..[10] = 1
      ..[12] = cx
      ..[13] = cy
      ..[15] = 1;
    return (Path()..addOval(
          Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
        ))
        .transform(matrix);
  }

  static Path _star(double outer, double inner) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? outer : inner;
      final angle = -math.pi / 2 + i * math.pi / 5;
      final x = radius * math.cos(angle);
      final y = radius * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }
}
