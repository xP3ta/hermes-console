// Hermes Console — "Spark": la chispa / entidad energética de la marca.
//
// Dibujada con CustomPaint (sin assets de imagen: no puede faltar ni
// pixelarse) y animada con Flutter nativo: flotación suave, pulso de glow,
// nodos en órbita, trazas de conexión y una estela. NO es un robot ni un búho
// ni un emoji: es una chispa viva, de la misma familia visual que el
// `spark_mark` del branding.
//
// Cada [HermesSparkMood] cambia color del glow, energía/velocidad, nº de nodos
// y la expresión del núcleo, manteniendo el MISMO diseño base. Respeta
// MediaQuery.disableAnimations (accesibilidad) y `animate: false`.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

@visibleForTesting
const hermesSparkFrameInterval = Duration(microseconds: 33334);

/// Estados de ánimo de la chispa. Mapean a estados reales de la app
/// (conexión, chat pensando, diagnóstico, etc.).
enum HermesSparkMood {
  idle,
  thinking,
  connecting,
  success,
  error,
  offline,
  waiting,

  /// Gesto breve de salto (p. ej. al enviar un mensaje). Transitorio.
  jump,
}

class HermesSparkMascot extends StatefulWidget {
  final HermesSparkMood mood;
  final double size;

  /// Si false (o si el sistema pide reducir movimiento) se pinta un fotograma
  /// estático elegante en lugar de animar.
  final bool animate;

  /// Acento base; si es null usa el ámbar de marca (#E8821C).
  final Color? accent;

  @visibleForTesting
  final ValueChanged<double>? onFrameChanged;

  const HermesSparkMascot({
    super.key,
    this.mood = HermesSparkMood.idle,
    this.size = 96,
    this.animate = true,
    this.accent,
    this.onFrameChanged,
  });

  @override
  State<HermesSparkMascot> createState() => _HermesSparkMascotState();
}

class _HermesSparkMascotState extends State<HermesSparkMascot>
    with WidgetsBindingObserver {
  Timer? _frameTimer;

  /// Fase de la animación. El painter la escucha directamente: cada paso solo
  /// repinta la capa de la chispa, sin `setState`. Dentro de la pista del
  /// paseo de Inicio (con su `LayoutBuilder`), un rebuild por frame
  /// repintaba también el contenido del Home que queda debajo.
  final ValueNotifier<double> _phase = ValueNotifier<double>(0.12);
  bool _tickerModeEnabled = true;
  bool _reduceMotion = false;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(covariant HermesSparkMascot old) {
    super.didUpdateWidget(old);
    if (old.animate != widget.animate) _sync();
  }

  void _sync() {
    _frameTimer?.cancel();
    _frameTimer = null;
    if (!widget.animate ||
        _reduceMotion ||
        !_tickerModeEnabled ||
        !_appActive) {
      _phase.value = 0.12; // fotograma estático representativo
      return;
    }
    _frameTimer = Timer.periodic(hermesSparkFrameInterval, (_) {
      if (!mounted) return;
      _phase.value =
          (_phase.value +
              hermesSparkFrameInterval.inMicroseconds /
                  Duration.microsecondsPerSecond /
                  6) %
          1;
      widget.onFrameChanged?.call(_phase.value);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;
    _sync();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameTimer?.cancel();
    _frameTimer = null;
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent ?? const Color(0xFFE8821C);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _SparkPainter(
          phase: _phase,
          mood: widget.mood,
          accent: accent,
        ),
      ),
    );
  }
}

enum _Face { calm, focus, forward, happy, sad, faint, alert }

/// Parámetros visuales por estado. El diseño base es el mismo; solo cambian
/// energía, color del glow, nodos y la expresión.
class _Spec {
  final Color glow;
  final Color body;
  final double energy; // 0..1 brillo/intensidad general
  // Vueltas ENTERAS de órbita por ciclo del controlador. Debe ser entero: el
  // controlador salta de t=1 a t=0 al repetir, así que solo un nº entero de
  // vueltas (ángulo múltiplo de 2π en t=1) empalma sin saltos. Un valor
  // fraccional provocaría un "tirón" visible en cada repetición.
  final int speed;
  final int nodes; // nodos orbitando
  final double floatAmp; // amplitud de flotación (fracción del alto)
  final double sink; // desplazamiento hacia abajo (offline)
  final double jitter; // temblor (error)
  final double trail; // longitud extra de estela
  final bool stream; // flujo de partículas entrando (connecting)
  final bool ring; // anillo de espera expandiéndose (waiting)
  final double pop; // realce de escala (success)
  final _Face face;

  const _Spec({
    required this.glow,
    required this.body,
    required this.energy,
    required this.speed,
    required this.nodes,
    required this.floatAmp,
    required this.face,
    this.sink = 0,
    this.jitter = 0,
    this.trail = 0,
    this.stream = false,
    this.ring = false,
    this.pop = 0,
  });
}

class _SparkPainter extends CustomPainter {
  final ValueListenable<double> phase;
  final HermesSparkMood mood;
  final Color accent;

  _SparkPainter({required this.phase, required this.mood, required this.accent})
    : super(repaint: phase);

  double get t => phase.value; // 0..1

  static const _green = Color(0xFF4FD18B);
  static const _red = Color(0xFFFF6B5C);
  static const _grey = Color(0xFF8A8A93);

  _Spec _spec() {
    switch (mood) {
      case HermesSparkMood.idle:
        return _Spec(
          glow: accent,
          body: accent,
          energy: 0.72,
          speed: 1,
          nodes: 2,
          floatAmp: 0.035,
          trail: 0.22,
          face: _Face.calm,
        );
      case HermesSparkMood.thinking:
        return _Spec(
          glow: accent,
          body: accent,
          energy: 0.95,
          speed: 2,
          nodes: 4,
          floatAmp: 0.02,
          trail: 0.30,
          face: _Face.focus,
        );
      case HermesSparkMood.connecting:
        return _Spec(
          glow: accent,
          body: accent,
          energy: 0.8,
          speed: 2,
          nodes: 3,
          floatAmp: 0.02,
          trail: 0.35,
          stream: true,
          face: _Face.forward,
        );
      // El fallback procedural no tiene pose propia de salto: reusa el aspecto
      // enérgico/feliz de `success`.
      case HermesSparkMood.jump:
      case HermesSparkMood.success:
        return _Spec(
          glow: _green,
          body: accent,
          energy: 1.0,
          speed: 1,
          nodes: 3,
          floatAmp: 0.03,
          trail: 0.25,
          pop: 1.0,
          face: _Face.happy,
        );
      case HermesSparkMood.error:
        return _Spec(
          glow: _red,
          body: accent,
          energy: 0.55,
          speed: 1,
          nodes: 1,
          floatAmp: 0.015,
          jitter: 0.9,
          trail: 0.10,
          face: _Face.sad,
        );
      case HermesSparkMood.offline:
        return _Spec(
          glow: _grey,
          body: _grey,
          energy: 0.18,
          speed: 1,
          nodes: 0,
          floatAmp: 0.012,
          sink: 0.04,
          trail: 0.05,
          face: _Face.faint,
        );
      case HermesSparkMood.waiting:
        return _Spec(
          glow: accent,
          body: accent,
          energy: 0.5,
          speed: 1,
          nodes: 2,
          floatAmp: 0.025,
          trail: 0.18,
          ring: true,
          face: _Face.alert,
        );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = _spec();
    final w = size.width;
    final h = size.height;
    final two = 2 * math.pi;
    final pulse = 0.5 + 0.5 * math.sin(t * two); // 0..1
    final r = w * 0.22; // radio base de la chispa

    // Centro con flotación + leve hundimiento (offline).
    var cx = w / 2;
    var cy = h / 2 + math.sin(t * two) * h * s.floatAmp + h * s.sink;
    // Temblor inestable (error): alta frecuencia, deterministra.
    if (s.jitter > 0) {
      cx += math.sin(t * two * 9) * r * 0.06 * s.jitter;
      cy += math.cos(t * two * 11) * r * 0.05 * s.jitter;
    }
    final c = Offset(cx, cy);

    // Escala con "pop" puntual en success.
    var scale = 1.0;
    if (s.pop > 0) {
      final p = (t * 1.0) % 1.0;
      scale =
          1 + 0.10 * s.pop * math.exp(-p * 6) * math.sin(p * two * 1.5).abs();
    }
    final rr = r * scale;

    // 1) Anillo de espera (waiting): expande y se desvanece.
    if (s.ring) {
      final rp = t % 1.0;
      final ringR = rr * (1.2 + rp * 1.5);
      canvas.drawCircle(
        c,
        ringR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.012
          ..color = s.glow.withValues(alpha: 0.35 * (1 - rp)),
      );
    }

    // 2) Glow / halo.
    final glowR = rr * (1.6 + 0.25 * pulse) * (0.55 + 0.45 * s.energy);
    canvas.drawCircle(
      c,
      glowR,
      Paint()
        ..color = s.glow.withValues(
          alpha: (0.10 + 0.24 * s.energy) * (0.6 + 0.4 * pulse),
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.55),
    );

    // 3) Estela / cola (flama hacia abajo, sugiere movimiento por corriente).
    final tailLen = rr * (0.55 + s.trail);
    final tail = Path()
      ..moveTo(c.dx - rr * 0.16, c.dy + rr * 0.25)
      ..quadraticBezierTo(
        c.dx,
        c.dy + tailLen,
        c.dx + rr * 0.16,
        c.dy + rr * 0.25,
      )
      ..close();
    canvas.drawPath(
      tail,
      Paint()
        ..color = s.glow.withValues(alpha: 0.18 * s.energy)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.18),
    );

    // 4) Flujo de partículas entrando (connecting): por una bezier al núcleo.
    if (s.stream) {
      final start = Offset(c.dx - r * 1.6, c.dy + r * 1.1);
      final ctrl = Offset(c.dx - r * 0.4, c.dy + r * 0.2);
      for (var i = 0; i < 3; i++) {
        final p = ((t * s.speed) + i / 3.0) % 1.0;
        final pos = _bezier(start, ctrl, c, p);
        canvas.drawCircle(
          pos,
          w * 0.018 * (1 - p * 0.5),
          Paint()..color = s.glow.withValues(alpha: 0.8 * (1 - p)),
        );
      }
    }

    // 5) Nodos en órbita + trazas de conexión.
    for (var i = 0; i < s.nodes; i++) {
      final a = t * two * s.speed + i * (two / math.max(1, s.nodes));
      final orbit = rr * 1.45;
      final pos = Offset(
        c.dx + math.cos(a) * orbit,
        c.dy + math.sin(a) * orbit * 0.72, // órbita ligeramente achatada
      );
      canvas.drawLine(
        c,
        pos,
        Paint()
          ..strokeWidth = w * 0.006
          ..color = s.glow.withValues(alpha: 0.22 * s.energy),
      );
      canvas.drawCircle(
        pos,
        w * 0.022,
        Paint()..color = s.glow.withValues(alpha: 0.55 + 0.35 * s.energy),
      );
    }

    // 6) Cuerpo de la chispa (4 puntas, lados cóncavos) con gradiente vertical.
    final path = _spark(c, rr);
    final bright = Color.lerp(s.body, Colors.white, 0.45)!;
    final bodyShader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [bright, s.body],
    ).createShader(Rect.fromCircle(center: c, radius: rr));
    canvas.drawPath(
      path,
      Paint()
        ..shader = bodyShader
        ..color = Colors.white.withValues(alpha: 0.4 + 0.6 * s.energy),
    );

    // 7) Núcleo brillante.
    final nucR = rr * (0.44 * (0.92 + 0.08 * pulse));
    final nucShader = RadialGradient(
      colors: [
        Color.lerp(Colors.white, s.glow, 0.12)!,
        s.body.withValues(alpha: 0),
      ],
    ).createShader(Rect.fromCircle(center: c, radius: nucR));
    canvas.drawCircle(c, nucR, Paint()..shader = nucShader);

    // 8) Expresión del núcleo (mínima, abstracta).
    _drawFace(canvas, c, rr, s.face);
  }

  void _drawFace(Canvas canvas, Offset c, double r, _Face face) {
    final ink = const Color(0xFF1A1206).withValues(alpha: 0.72);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.085
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = ink;
    final fill = Paint()..color = ink;
    final ey = c.dy - r * 0.04;
    final ex = r * 0.22;

    void dotEyes(double rad) {
      canvas.drawCircle(Offset(c.dx - ex, ey), rad, fill);
      canvas.drawCircle(Offset(c.dx + ex, ey), rad, fill);
    }

    switch (face) {
      case _Face.calm:
        // Ojos relajados: líneas cortas horizontales.
        canvas.drawLine(
          Offset(c.dx - ex - r * 0.07, ey),
          Offset(c.dx - ex + r * 0.07, ey),
          p,
        );
        canvas.drawLine(
          Offset(c.dx + ex - r * 0.07, ey),
          Offset(c.dx + ex + r * 0.07, ey),
          p,
        );
      case _Face.focus:
        dotEyes(r * 0.06);
      case _Face.forward:
        // Chevron ">" de avance.
        final path = Path()
          ..moveTo(c.dx - r * 0.06, ey - r * 0.12)
          ..lineTo(c.dx + r * 0.10, ey)
          ..lineTo(c.dx - r * 0.06, ey + r * 0.12);
        canvas.drawPath(path, p);
      case _Face.happy:
        // Arco hacia arriba (satisfacción).
        final path = Path()
          ..moveTo(c.dx - ex, ey + r * 0.02)
          ..quadraticBezierTo(c.dx, ey - r * 0.16, c.dx + ex, ey + r * 0.02);
        canvas.drawPath(path, p);
      case _Face.sad:
        // Arco hacia abajo (preocupación, sin exagerar).
        final path = Path()
          ..moveTo(c.dx - ex, ey + r * 0.04)
          ..quadraticBezierTo(c.dx, ey + r * 0.2, c.dx + ex, ey + r * 0.04);
        canvas.drawPath(path, p);
      case _Face.faint:
        dotEyes(r * 0.04);
      case _Face.alert:
        // Núcleo atento: un punto central.
        canvas.drawCircle(c, r * 0.07, fill);
    }
  }

  /// Chispa de 4 puntas con lados cóncavos (idéntica al `spark_mark`).
  Path _spark(Offset c, double r) {
    final s = r / 110.0;
    Offset o(double x, double y) => Offset(c.dx + x * s, c.dy + y * s);
    return Path()
      ..moveTo(o(0, -110).dx, o(0, -110).dy)
      ..cubicTo(
        o(12, -32).dx,
        o(12, -32).dy,
        o(32, -12).dx,
        o(32, -12).dy,
        o(110, 0).dx,
        o(110, 0).dy,
      )
      ..cubicTo(
        o(32, 12).dx,
        o(32, 12).dy,
        o(12, 32).dx,
        o(12, 32).dy,
        o(0, 110).dx,
        o(0, 110).dy,
      )
      ..cubicTo(
        o(-12, 32).dx,
        o(-12, 32).dy,
        o(-32, 12).dx,
        o(-32, 12).dy,
        o(-110, 0).dx,
        o(-110, 0).dy,
      )
      ..cubicTo(
        o(-32, -12).dx,
        o(-32, -12).dy,
        o(-12, -32).dx,
        o(-12, -32).dy,
        o(0, -110).dx,
        o(0, -110).dy,
      )
      ..close();
  }

  Offset _bezier(Offset a, Offset b, Offset c, double t) {
    final u = 1 - t;
    return Offset(
      u * u * a.dx + 2 * u * t * b.dx + t * t * c.dx,
      u * u * a.dy + 2 * u * t * b.dy + t * t * c.dy,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.phase != phase || old.mood != mood || old.accent != accent;
}
