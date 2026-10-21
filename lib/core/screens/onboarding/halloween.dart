import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'onboarding_motion.dart';

/// The seasonal look of the logo. One function, one injectable clock.
enum Season { none, halloween, christmas }

/// The phone's local time; tests replace it, nothing else reads the clock.
DateTime Function() seasonClock = DateTime.now;

/// Halloween: 25 Oct 00:00 – 2 Nov 23:59. Christmas: 20 Dec 00:00 – 6 Jan
/// 23:59 (it crosses the year). Anything else: the logo of every day.
Season seasonOf(DateTime now) {
  final (m, d) = (now.month, now.day);
  if (m == 10 && d >= 25 || m == 11 && d <= 2) return Season.halloween;
  if (m == 12 && d >= 20 || m == 1 && d <= 6) return Season.christmas;
  return Season.none;
}

bool isHalloweenSeason(DateTime now) => seasonOf(now) == Season.halloween;

(Color, double)? seasonGlow(Season s) => switch (s) {
  Season.halloween => (const Color(0xFFFF8C28), .28),
  Season.christmas => (const Color(0xFFAAC8FF), .18),
  Season.none => null,
};

double? ambientSeconds(Animation<double>? a) => a == null || !a.isAnimating
    ? null
    : a.value * OnboardingMotion.ambientSpan.inMilliseconds / 1000;

Path svgPath(String d) {
  final it = RegExp(
    r'[MLQZ]|-?\d+\.?\d*',
  ).allMatches(d).map((m) => m[0]!).toList();
  final p = Path();
  var i = 0, cmd = '';
  double n() => double.parse(it[i++]);
  while (i < it.length) {
    if (RegExp('[A-Z]').hasMatch(it[i])) cmd = it[i++];
    switch (cmd) {
      case 'M':
        p.moveTo(n(), n());
        cmd = 'L';
      case 'L':
        p.lineTo(n(), n());
      case 'Q':
        p.quadraticBezierTo(n(), n(), n(), n());
      default:
        p.close();
    }
  }
  return p;
}

final _gajos = [
  svgPath('M460 150 Q330 500 460 850 Q395 500 460 150Z'),
  svgPath('M210 260 Q150 500 230 760 Q190 500 260 250Z'),
];
final _face = Path()
  ..addPath(svgPath('M338 470 L418 400 L436 478 Z'), Offset.zero)
  ..addPath(svgPath('M582 470 L502 400 L484 478 Z'), Offset.zero)
  ..addPath(svgPath('M460 486 L440 530 L480 530 Z'), Offset.zero)
  ..addPath(
    svgPath(
      'M318 548 L352 566 L370 546 L398 572 L420 548 L446 578 L474 548 '
      'L500 578 L522 548 L548 572 L568 546 L588 566 L602 548 '
      'Q580 650 460 660 Q340 650 318 548Z',
    ),
    Offset.zero,
  );
final _leaf = svgPath('M480 120 Q540 70 590 110 Q540 150 480 128Z');
final _antlers = [
  svgPath(
    'M380 200 Q350 120 300 80 M352 140 Q300 140 270 110 M370 180 Q410 120 400 70',
  ),
  svgPath(
    'M540 196 Q580 120 640 90 M576 136 Q620 140 650 120 M556 170 Q520 110 535 64',
  ),
];
final _bat = svgPath(
  'M22 8 Q18 2 2 4 Q10 8 8 14 Q14 10 18 14 Q20 10 22 12 Q24 10 26 14 '
  'Q30 10 36 14 Q34 8 42 4 Q26 2 22 8Z',
);

/// Candle flicker (1 → .7 → 1 → .85, 1.7 s) and the nose pulse (1.4 s).
double flickerAt(double? t) {
  if (t == null) return 1;
  final p = (t % 1.7) / 1.7;
  const k = [(0.0, 1.0), (.45, .7), (.6, 1.0), (.75, .85), (1.0, 1.0)];
  for (var i = 1; i < k.length; i++) {
    if (p <= k[i].$1) {
      final f = (p - k[i - 1].$1) / (k[i].$1 - k[i - 1].$1);
      return k[i - 1].$2 + (k[i].$2 - k[i - 1].$2) * f;
    }
  }
  return 1;
}

double pulseAt(double? t) =>
    t == null ? 1 : .775 + .225 * math.cos(2 * math.pi * t / 1.4);

Paint _fill(Color c, double a) => Paint()..color = c.withValues(alpha: a);

/// Paints the seasonal mark in the space of the logo ([shown] is the arc so
/// far); the plain mark never comes through here.
void paintSeasonMark(
  Canvas c,
  Season s,
  Path shown,
  double arc,
  double bar,
  double? t,
) {
  final a = arc.clamp(0.0, 1.0), b = bar.clamp(0.0, 1.0);
  Paint stroke(Color col, double w) => Paint()
    ..color = col
    ..style = PaintingStyle.stroke
    ..strokeWidth = w;
  if (s == Season.christmas) {
    final horn = stroke(const Color(0xFF8A5A3C).withValues(alpha: a), 30)
      ..strokeCap = StrokeCap.round;
    for (final p in _antlers) {
      if (a > 0) c.drawPath(p, horn);
    }
    if (a > 0) c.drawPath(shown, stroke(kMarkColor, kMarkStroke));
    c.save();
    c.translate(600, 300);
    c.rotate(-35 * math.pi / 180);
    c.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 104, height: 60),
      _fill(const Color(0xFFC2603F), a),
    );
    c.restore();
    c.drawCircle(const Offset(560, 400), 22, _fill(const Color(0xFF1D1B20), a));
    c.drawCircle(const Offset(567, 393), 7, _fill(Colors.white, a));
    if (b > 0) {
      c.drawCircle(
        const Offset(760, 500),
        120,
        _fill(const Color(0xFFFF3B3B), .25 * pulseAt(t) * b),
      );
      c.drawCircle(
        const Offset(750, 500),
        74,
        _fill(const Color(0xFFE02B2B), b),
      );
      c.drawCircle(
        const Offset(728, 478),
        18,
        _fill(const Color(0xFFFF8A8A), b),
      );
    }
    return;
  }
  final f = flickerAt(t);
  const mid = Offset(460, 500);
  c.drawCircle(
    mid,
    208,
    Paint()
      ..shader = ui.Gradient.radial(mid, 208, [
        const Color(0xFF5A230C).withValues(alpha: a * f),
        const Color(0xFF220C04).withValues(alpha: a * f),
      ]),
  );
  if (b > 0) {
    final glow = _fill(const Color(0xFFFFAA28), .75 * b * f)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    c.drawPath(_face, glow);
    c.drawPath(_face, _fill(const Color(0xFFFFC94A), b * f));
  }
  final barRect = RRect.fromRectAndRadius(
    Rect.fromCenter(
      center: kMarkBar.center,
      width: kMarkBar.width,
      height: kMarkBar.height * b,
    ),
    const Radius.circular(26),
  );
  c.saveLayer(null, Paint());
  const skin = Color(0xFFE9772F);
  if (a > 0) c.drawPath(shown, stroke(skin, kMarkStroke));
  if (b > 0) c.drawRRect(barRect, _fill(skin, b));
  final light = Paint()
    ..color = const Color(0xFFF59A4A)
    ..blendMode = BlendMode.srcATop;
  for (final g in _gajos) {
    c.drawPath(g, light);
  }
  c.drawRect(const Rect.fromLTWH(694, 398, 34, 204), light);
  c.restore();
  if (a > 0) {
    c.save();
    c.translate(463, 132);
    c.rotate(8 * math.pi / 180);
    c.translate(-463, -132);
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(446, 92, 34, 80),
        const Radius.circular(14),
      ),
      _fill(const Color(0xFF4F7A3A), a),
    );
    c.restore();
    c.drawPath(_leaf, _fill(const Color(0xFF6FA14A), a));
  }
}

/// Bats (Halloween) or snow (Christmas) drifting over the top half. It sits
/// under the content, so it is never over a button or a line of text.
class SeasonFxPainter extends CustomPainter {
  SeasonFxPainter(this.season, this.ambient) : super(repaint: ambient);
  final Season season;
  final Animation<double> ambient;

  // (width dp, seconds, delay, top dp) as in the approved mock.
  static const _bats = [
    (40.0, 7.0, -1.0, 120.0),
    (28.0, 9.0, -4.0, 175.0),
    (22.0, 11.0, -6.5, 80.0),
  ];
  static const _flakes = [
    (.08, 4.0, 7.0, 0.0),
    (.19, 3.0, 8.0, 3.0),
    (.31, 5.0, 9.0, 1.5),
    (.42, 3.5, 6.5, 4.5),
    (.55, 6.0, 8.5, 2.0),
    (.66, 3.0, 7.5, 5.5),
    (.77, 4.5, 6.0, 1.0),
    (.88, 3.5, 9.0, 6.0),
    (.95, 5.0, 7.0, 3.5),
  ];

  /// Elements it draws: 3 bats or 9 flakes.
  int get count => season == Season.halloween ? _bats.length : _flakes.length;

  @override
  void paint(Canvas canvas, Size size) {
    final t = ambientSeconds(ambient);
    if (t == null) return;
    final fade = 1 - ivl(ambient.value, .94, 1);
    if (season == Season.halloween) {
      final paint = _fill(const Color(0xFF100D14), fade);
      for (final (w, secs, delay, top) in _bats) {
        final p = ((t - delay) % secs) / secs;
        final s = w * (.8 + .3 * p) / 44;
        final flap = 1 - .65 * (.5 - .5 * math.cos(2 * math.pi * t / .26));
        canvas
          ..save()
          ..translate(-80 + p * (size.width + 170), top + 40 - 110 * p + 10 * s)
          ..scale(s, s * flap)
          ..translate(0, -10)
          ..drawPath(_bat, paint)
          ..restore();
      }
    } else {
      final paint = _fill(Colors.white, .85 * fade);
      for (final (fx, d, secs, delay) in _flakes) {
        final p = ((t + delay) % secs) / secs;
        canvas.drawCircle(
          Offset(
            fx * size.width + 10 * math.sin(2 * math.pi * (p * 1.5 + fx)),
            -6 + p * (size.height * .5 + 6),
          ),
          d / 2,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(SeasonFxPainter old) => old.season != season;
}
