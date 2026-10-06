import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Console brand mark: terracotta «C» with a cursor bar (transparent PNG).
const kConsoleMarkAsset = 'assets/branding/console_mark.png';

/// Console app icon (graphite rounded square + mark), for identity rows.
const kConsoleIconAsset = 'assets/branding/console_icon.png';

/// Logo de marca de Console (la «C» terracota con cursor, fondo transparente).
///
/// Identificador de MARCA de la app (splash, estados de carga), distinto del
/// `HermesSparkMascot`, que se reserva como mascota/companion.
///
/// - `animate`: respiración (escala) + glow ámbar pulsante.
/// - `orbit`: además, un anillo que gira alrededor (la "esfera" exterior).
/// - `glow`: halo iluminado detrás del emblema (desactivable para un look nítido).
/// Respeta `MediaQuery.disableAnimations` (reduce-motion).
class AnimatedHermesLogo extends StatefulWidget {
  final double size;
  final bool animate;
  final bool orbit;
  final bool glow;
  final Color? color;

  const AnimatedHermesLogo({
    super.key,
    this.size = 96,
    this.animate = true,
    this.orbit = false,
    this.glow = true,
    this.color,
  });

  @override
  State<AnimatedHermesLogo> createState() => _AnimatedHermesLogoState();
}

class _AnimatedHermesLogoState extends State<AnimatedHermesLogo>
    with TickerProviderStateMixin {
  late final AnimationController _breath;
  late final AnimationController _orbit;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _orbit = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(AnimatedHermesLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!widget.animate || reduceMotion) {
      _breath
        ..stop()
        ..value = 0.5;
      _orbit
        ..stop()
        ..value = 0;
      return;
    }
    if (!_breath.isAnimating) _breath.repeat(reverse: true);
    if (widget.orbit) {
      if (!_orbit.isAnimating) _orbit.repeat();
    } else if (_orbit.isAnimating) {
      _orbit.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    _orbit.dispose();
    super.dispose();
  }

  Widget _emblem(double scale, double glow, Color accent) {
    final emblemSize = widget.size * 0.82;

    return Transform.scale(
      scale: scale,
      child: Container(
        key: const Key('animated_hermes_logo_emblem'),
        width: emblemSize,
        height: emblemSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: widget.glow
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: glow),
                    blurRadius: widget.size * 0.18,
                    spreadRadius: widget.size * 0.01,
                  ),
                ]
              : null,
        ),
        // The Console mark is the app identity, identical on every theme
        // (same as the launcher icon): only the orbit and glow follow the
        // theme accent; the mark itself is never re-tinted.
        child: Padding(
          padding: EdgeInsets.all(emblemSize * 0.12),
          child: Image.asset(
            kConsoleMarkAsset,
            key: const Key('animated_hermes_logo_mark'),
            fit: BoxFit.contain,
            // Decode bounded to the displayed size (x3 DPR).
            cacheWidth: (emblemSize * 3).round(),
            excludeFromSemantics: true,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final still = !widget.animate || reduceMotion;
    final theme = Theme.of(context);
    final accent = widget.color ?? theme.hermes.accentText;
    final lightSurface = theme.brightness == Brightness.light;

    return Semantics(
      label: 'Console',
      image: true,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.orbit && !still)
              AnimatedBuilder(
                animation: _orbit,
                builder: (context, _) => CustomPaint(
                  size: Size(widget.size, widget.size),
                  painter: _OrbitPainter(
                    _orbit.value,
                    accent,
                    highContrast: lightSurface,
                  ),
                ),
              ),
            if (still)
              _emblem(1, 0.26, accent)
            else
              AnimatedBuilder(
                animation: _breath,
                builder: (context, _) {
                  final t = Curves.easeInOut.transform(_breath.value);
                  return _emblem(0.97 + 0.06 * t, 0.16 + 0.30 * t, accent);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Anillo tenue + dos puntos orbitando, para dar sensación de "esfera activa".
class _OrbitPainter extends CustomPainter {
  final double progress; // 0..1
  final Color accent;
  final bool highContrast;

  _OrbitPainter(this.progress, this.accent, {required this.highContrast});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.47;
    final angle = progress * 2 * math.pi;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Anillo base tenue (la circunferencia completa de la "esfera").
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = highContrast ? 1.8 : 1.4
        ..color = accent.withValues(alpha: highContrast ? 0.34 : 0.14),
    );

    // Arco luminoso que recorre el anillo: da la sensación de la esfera
    // exterior girando (loader orbital). Gradiente sweep que se desvanece.
    final sweep = math.pi * 0.7; // longitud del arco brillante
    // Dos tramos sólidos producen la misma lectura de estela sin compilar un
    // SweepGradient en el primer frame animado (ese shader provocaba un tirón
    // visible en Vulkan durante el splash).
    final tailPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 2.8 : 2.4
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: highContrast ? 0.26 : 0.14);
    final headPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 2.8 : 2.4
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: 0.82);
    canvas.drawArc(rect, angle, sweep * 0.58, false, tailPaint);
    canvas.drawArc(rect, angle + sweep * 0.52, sweep * 0.48, false, headPaint);

    // Punto guía brillante en la cabeza del arco.
    final head = Offset(
      center.dx + radius * math.cos(angle + sweep),
      center.dy + radius * math.sin(angle + sweep),
    );
    canvas.drawCircle(
      head,
      size.width * 0.022,
      Paint()..color = accent.withValues(alpha: 0.95),
    );
    canvas.drawCircle(
      head,
      size.width * 0.05,
      Paint()..color = accent.withValues(alpha: 0.2),
    );
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.progress != progress ||
      old.accent != accent ||
      old.highContrast != highContrast;
}
