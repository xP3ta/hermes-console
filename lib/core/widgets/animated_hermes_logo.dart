import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Logo de marca de Hermes (emblema circular dorado, fondo transparente).
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
  static const _assetAccent = Color(0xFFF0A848);

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

  ColorFilter _themeTint(Color accent) {
    final sourceHue = HSVColor.fromColor(_assetAccent).hue;
    final targetHue = HSVColor.fromColor(accent).hue;
    final angle = (targetHue - sourceHue) * math.pi / 180;
    final cosine = math.cos(angle);
    final sine = math.sin(angle);
    // Matriz hue-rotate de SVG/CSS. A diferencia de un duotono, conserva los
    // grises y la luminosidad del retrato; solo desplaza el dorado al matiz del
    // tema. La fila alfa identidad evita cualquier fondo cuadrado.
    return ColorFilter.matrix([
      0.213 + cosine * 0.787 - sine * 0.213,
      0.715 - cosine * 0.715 - sine * 0.715,
      0.072 - cosine * 0.072 + sine * 0.928,
      0,
      0,
      0.213 - cosine * 0.213 + sine * 0.143,
      0.715 + cosine * 0.285 + sine * 0.140,
      0.072 - cosine * 0.072 - sine * 0.283,
      0,
      0,
      0.213 - cosine * 0.213 - sine * 0.787,
      0.715 - cosine * 0.715 + sine * 0.715,
      0.072 + cosine * 0.928 + sine * 0.072,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
  }

  Widget _emblem(double scale, double glow, Color accent) {
    final emblemSize = widget.size * 0.82;
    final isLight = Theme.of(context).brightness == Brightness.light;

    Widget asset(String layer, String path) => Image.asset(
      path,
      key: ValueKey('animated_hermes_logo_asset_$layer'),
      width: emblemSize,
      height: emblemSize,
      // Decodificar acotado al tamaño mostrado (×3 de DPR): el master es
      // 1024×1024 y el emblema nunca supera `size` dp.
      cacheWidth: (emblemSize * 3).round(),
      cacheHeight: (emblemSize * 3).round(),
      fit: BoxFit.contain,
      excludeFromSemantics: true,
      // El master es 1024×1024: con high queda nítido al escalar a tamaños
      // grandes (splash), sin el desenfoque de medium.
      filterQuality: FilterQuality.high,
    );

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
        // Un único master dimensional evita que claro y oscuro presenten
        // retratos o encuadres distintos. Su transparencia real deja que cada
        // superficie aporte el fondo; el filtro solo desplaza el dorado al
        // matiz del tema sin alterar sombras, luces ni alfa.
        child: ColorFiltered(
          key: isLight
              ? const Key('animated_hermes_logo_light_artwork')
              : const Key('animated_hermes_logo_tint'),
          colorFilter: _themeTint(accent),
          child: asset(
            isLight ? 'light-dimensional-cutout' : 'dark-dimensional-cutout',
            'assets/branding/hermes_logo_light.png',
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
      label: 'Hermes',
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
