// The constellation itself: a 3D star map of the learning graph, drawn with
// a CustomPainter. Drag to turn it, pinch to zoom, tap a star to bring it to
// the front and light its lines. It slowly turns by itself unless the system
// asks for no animations.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../theme/constellation_tokens.dart';
import 'constellation_graph.dart';

/// The colour of a kind of star, on the constellation's night background.
Color constellationColorOf(ConstellationKind kind) {
  switch (kind) {
    case ConstellationKind.memory:
      return ConstellationTokens.memory;
    case ConstellationKind.skill:
      return ConstellationTokens.skill;
    case ConstellationKind.other:
      return ConstellationTokens.other;
  }
}

/// The night the stars sit on, also the page colour around the map.
const Color constellationNight = ConstellationTokens.night;

double _unit(double value) => value < 0 ? 0 : (value > 1 ? 1 : value);

/// Lets the page around the map ask it to come back to its first view.
class ConstellationViewController {
  _ConstellationViewState? _state;

  void recenter() => _state?._recenter();
}

class ConstellationView extends StatefulWidget {
  const ConstellationView({
    required this.graph,
    required this.visibleKinds,
    required this.onSelected,
    this.controller,
    super.key,
  });

  final ConstellationGraph graph;

  /// Kinds shown in full light; the others stay as faint dust.
  final Set<ConstellationKind> visibleKinds;

  /// Called with the star the user focused, or null when focus is cleared.
  final ValueChanged<ConstellationNode?> onSelected;
  final ConstellationViewController? controller;

  @override
  State<ConstellationView> createState() => _ConstellationViewState();
}

class _Camera {
  double ry = 0.6;
  double rx = -0.2;
  double zoom = 1;

  /// Spin left over from the last drag, easing back to the idle drift.
  double vy = _idleSpin;
  double vx = 0;
  double time = 0;
  double? targetRy;
  double targetRx = 0;
  ConstellationNode? selected;
  final Map<String, TextPainter> labels = {};
}

const double _idleSpin = 0.0016;

class _Projected {
  const _Projected(this.x, this.y, this.z, this.perspective);

  final double x;
  final double y;

  /// Towards the viewer is positive.
  final double z;
  final double perspective;

  Offset get offset => Offset(x, y);
}

_Projected _project(ConstellationNode node, _Camera camera, Size size) {
  final cy = math.cos(camera.ry);
  final sy = math.sin(camera.ry);
  final cx = math.cos(camera.rx);
  final sx = math.sin(camera.rx);
  final x1 = node.x * cy + node.z * sy;
  final z1 = -node.x * sy + node.z * cy;
  final y1 = node.y * cx - z1 * sx;
  final z2 = node.y * sx + z1 * cx;
  final perspective = 1 + z2 * 0.28;
  final scale = math.min(size.width, size.height) * 0.4 * camera.zoom;
  return _Projected(
    size.width / 2 + x1 * scale * perspective,
    size.height / 2 + y1 * scale * perspective,
    z2,
    perspective,
  );
}

class _Star {
  const _Star(this.x, this.y, this.size, this.phase, this.depth);

  final double x;
  final double y;
  final double size;
  final double phase;
  final double depth;
}

List<_Star> _makeStars() {
  final random = math.Random(17);
  return [
    for (var i = 0; i < 150; i++)
      _Star(
        random.nextDouble(),
        random.nextDouble(),
        random.nextDouble() * 1.3 + 0.3,
        random.nextDouble() * 6.28,
        random.nextDouble(),
      ),
  ];
}

class _ConstellationViewState extends State<ConstellationView>
    with SingleTickerProviderStateMixin {
  final _Camera _camera = _Camera();
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final List<_Star> _stars = _makeStars();
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  Size _size = Size.zero;
  double _baseZoom = 1;
  bool _dragging = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
      _repaint.value++;
    } else if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(ConstellationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
    _repaint.value++;
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = math.min(0.05, (elapsed - _last).inMicroseconds / 1e6);
    _last = elapsed;
    final camera = _camera;
    camera.time = elapsed.inMicroseconds / 1e6;
    final k = dt * 60;
    if (!_dragging) {
      final target = camera.targetRy;
      if (target != null) {
        final ease = math.min(1.0, 0.08 * k);
        final d = target - camera.ry;
        camera.ry += math.atan2(math.sin(d), math.cos(d)) * ease;
        camera.rx += (camera.targetRx - camera.rx) * ease;
        camera.vy = 0;
        camera.vx = 0;
      } else {
        camera.ry += camera.vy * k;
        camera.rx += camera.vx * k;
        camera.vx *= math.pow(0.95, k).toDouble();
        camera.vy += (_idleSpin - camera.vy) * math.min(1.0, 0.02 * k);
      }
    }
    camera.rx = camera.rx < -1.1 ? -1.1 : (camera.rx > 1.1 ? 1.1 : camera.rx);
    _repaint.value++;
  }

  void _recenter() {
    _camera.zoom = 1;
    _select(null);
  }

  void _select(ConstellationNode? node) {
    final camera = _camera;
    camera.selected = node;
    if (node == null) {
      camera.targetRy = null;
    } else {
      final flat = math.sqrt(node.x * node.x + node.z * node.z);
      camera.targetRy = math.atan2(-node.x, node.z);
      camera.targetRx = math.atan2(node.y, flat) * 0.9;
      if (_reduceMotion) {
        // Nothing ticks to ease the turn, so it is done at once.
        camera.ry = camera.targetRy!;
        camera.rx = camera.targetRx;
      }
    }
    widget.onSelected(node);
    _repaint.value++;
  }

  void _pick(Offset point) {
    if (_size.isEmpty) return;
    ConstellationNode? best;
    var bestDistance = 26.0;
    for (final node in widget.graph.nodes) {
      if (!widget.visibleKinds.contains(node.kind)) continue;
      final projected = _project(node, _camera, _size);
      final distance = (projected.offset - point).distance - projected.z * 4;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = node;
      }
    }
    final current = _camera.selected;
    _select(best == null || best.id == current?.id ? null : best);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _dragging = true;
    _baseZoom = _camera.zoom;
    _camera.targetRy = null;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final delta = details.focalPointDelta;
    _camera.ry += delta.dx * 0.006;
    _camera.rx += delta.dy * 0.006;
    _camera.vy = delta.dx * 0.0014;
    _camera.vx = delta.dy * 0.0014;
    if (details.pointerCount > 1) {
      final zoom = _baseZoom * details.scale;
      _camera.zoom = zoom < 0.7 ? 0.7 : (zoom > 2.4 ? 2.4 : zoom);
    }
    if (_reduceMotion) _repaint.value++;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _dragging = false;
  }

  @override
  Widget build(BuildContext context) {
    final baseText = DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          onTapUp: (details) => _pick(details.localPosition),
          child: ClipRect(
            child: SizedBox.expand(
              child: CustomPaint(
                isComplex: true,
                painter: _ConstellationPainter(
                  graph: widget.graph,
                  camera: _camera,
                  stars: _stars,
                  visibleKinds: widget.visibleKinds,
                  baseText: baseText,
                  repaint: _repaint,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ConstellationPainter extends CustomPainter {
  _ConstellationPainter({
    required this.graph,
    required this.camera,
    required this.stars,
    required this.visibleKinds,
    required this.baseText,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final ConstellationGraph graph;
  final _Camera camera;
  final List<_Star> stars;
  final Set<ConstellationKind> visibleKinds;
  final TextStyle baseText;

  void _nebula(
    Canvas canvas,
    Size size,
    double fx,
    double fy,
    Color color,
    double radius,
  ) {
    final center = Offset(size.width * fx, size.height * fy);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Offset.zero & size, paint);
  }

  Path _polygon(Offset center, double radius, int sides, double start) {
    final path = Path();
    for (var i = 0; i < sides; i++) {
      final angle = start + 2 * math.pi * i / sides;
      final x = center.dx + math.cos(angle) * radius;
      final y = center.dy + math.sin(angle) * radius;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  Path _shape(ConstellationKind kind, Offset center, double radius) {
    switch (kind) {
      case ConstellationKind.skill:
        return _polygon(center, radius * 1.05, 6, math.pi / 6);
      case ConstellationKind.memory:
        return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
      case ConstellationKind.other:
        return _polygon(center, radius * 1.15, 4, 0);
    }
  }

  TextPainter _label(String text, bool strong, int level) {
    final key = '$text|${strong ? 1 : 0}|$level';
    final cached = camera.labels[key];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: baseText.copyWith(
          fontSize: strong ? 11 : 9.5,
          fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
          color: Colors.white.withValues(alpha: level / 4),
          decoration: TextDecoration.none,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: strong ? 190 : 110);
    if (camera.labels.length > 800) camera.labels.clear();
    camera.labels[key] = painter;
    return painter;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = camera.time;
    canvas.drawRect(Offset.zero & size, Paint()..color = constellationNight);

    // Night: three slow clouds and a field of twinkling dust.
    _nebula(
      canvas,
      size,
      0.25 + 0.08 * math.sin(t * 0.2),
      0.3,
      ConstellationTokens.nebulaViolet,
      math.max(size.width, size.height) * 0.7,
    );
    _nebula(
      canvas,
      size,
      0.78,
      0.62 + 0.06 * math.cos(t * 0.17),
      ConstellationTokens.nebulaMagenta,
      math.max(size.width, size.height) * 0.65,
    );
    _nebula(
      canvas,
      size,
      0.5,
      0.9,
      ConstellationTokens.nebulaTeal,
      math.max(size.width, size.height) * 0.6,
    );
    final dust = Paint();
    for (final star in stars) {
      final x =
          ((star.x * size.width + camera.ry * 40 * star.depth) % size.width +
              size.width) %
          size.width;
      final y = star.y * size.height + camera.rx * 20 * star.depth;
      final alpha =
          0.25 + 0.55 * math.sin(t * (0.6 + star.depth) + star.phase).abs();
      dust.color = ConstellationTokens.dust.withValues(alpha: _unit(alpha));
      canvas.drawRect(Rect.fromLTWH(x, y, star.size, star.size), dust);
    }
    final cycle = t % 9;
    if (cycle < 0.75) {
      final k = cycle / 0.75;
      final lane = (t ~/ 9) % 5;
      final head = Offset(
        size.width * (0.05 + 0.12 * lane) + k * size.width * 0.5,
        size.height * 0.1 + k * size.height * 0.3,
      );
      final tail = head - const Offset(70, 42);
      final streak = Paint()
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            ConstellationTokens.streakTail,
            Color.fromRGBO(220, 230, 255, _unit(1 - k)),
          ],
        ).createShader(Rect.fromPoints(tail, head));
      canvas.drawLine(tail, head, streak);
    }

    final nodes = graph.nodes;
    final count = nodes.length;
    if (count == 0) return;
    final projected = List<_Projected>.generate(
      count,
      (i) => _project(nodes[i], camera, size),
    );
    final focus = camera.selected;
    var focusIndex = -1;
    if (focus != null) {
      for (var i = 0; i < count; i++) {
        if (nodes[i].id == focus.id) {
          focusIndex = i;
          break;
        }
      }
    }
    final neighbours = <int>{};
    if (focusIndex >= 0) {
      for (final edge in graph.edges) {
        if (edge.a == focusIndex) neighbours.add(edge.b);
        if (edge.b == focusIndex) neighbours.add(edge.a);
      }
    }
    bool shown(int i) => visibleKinds.contains(nodes[i].kind);

    // Lines first, so the stars sit on top of them.
    final line = Paint()..style = PaintingStyle.stroke;
    for (final edge in graph.edges) {
      final pa = projected[edge.a];
      final pb = projected[edge.b];
      final lit =
          focusIndex >= 0 && (edge.a == focusIndex || edge.b == focusIndex);
      var alpha = 0.1 + 0.14 * ((pa.z + pb.z) / 2 + 1) / 2;
      if (!(shown(edge.a) && shown(edge.b))) alpha *= 0.25;
      if (lit) {
        alpha = 0.85;
      } else if (focusIndex >= 0) {
        alpha *= 0.45;
      }
      line.strokeWidth = lit ? 1.5 : 0.7;
      line.color =
          (lit ? ConstellationTokens.lineLit : ConstellationTokens.line)
              .withValues(alpha: _unit(alpha));
      canvas.drawLine(pa.offset, pb.offset, line);
      if (lit) {
        final k = (t * 0.9 + (edge.a + edge.b) * 0.13) % 1;
        final outwards = edge.a == focusIndex;
        final pulse = Offset.lerp(
          outwards ? pa.offset : pb.offset,
          outwards ? pb.offset : pa.offset,
          k,
        );
        if (pulse != null) {
          canvas.drawCircle(
            pulse,
            5,
            Paint()..color = ConstellationTokens.sparkGlow,
          );
          canvas.drawCircle(
            pulse,
            2,
            Paint()..color = ConstellationTokens.sparkCore,
          );
        }
      }
    }

    // Far stars first.
    final order = List<int>.generate(count, (i) => i)
      ..sort((a, b) => projected[a].z.compareTo(projected[b].z));
    final placed = <Rect>[];
    for (final i in order) {
      final node = nodes[i];
      final p = projected[i];
      final isFocus = i == focusIndex;
      final inFilter = shown(i);
      var alpha = 0.5 + 0.5 * (p.z + 1.2) / 2.4;
      if (focusIndex >= 0 && !isFocus && !neighbours.contains(i)) alpha *= 0.42;
      if (!inFilter) alpha *= 0.18;
      alpha = _unit(alpha);

      final color = constellationColorOf(node.kind);
      final pulse = isFocus ? 1 + 0.08 * math.sin(t * 5) : 1.0;
      final base = 4.6 + math.min(5.0, math.sqrt(node.weight) * 0.75);
      final zoomed = math.min(1.3, math.max(0.8, camera.zoom));
      final radius = base * p.perspective * pulse * zoomed;
      final center = p.offset;

      canvas.drawCircle(
        center,
        radius * 2.7,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.4 * alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius * 2.7)),
      );
      final body = _shape(node.kind, center, radius);
      final fill = ConstellationTokens.starBody.withValues(
        alpha: _unit(alpha + 0.2),
      );
      canvas.drawPath(body, Paint()..color = fill);
      canvas.drawPath(
        body,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..color = color.withValues(alpha: alpha),
      );
      canvas.drawCircle(
        center,
        radius * 0.22,
        Paint()..color = Colors.white.withValues(alpha: _unit(alpha + 0.25)),
      );
      if (isFocus) {
        canvas.drawCircle(
          center,
          radius + 5 + 2 * math.sin(t * 4),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.white.withValues(alpha: 0.9),
        );
      }

      final wantLabel =
          isFocus ||
          (inFilter && p.z > 0.2 && (focusIndex < 0 || neighbours.contains(i)));
      if (wantLabel) {
        final level = (alpha * 4).round().clamp(1, 4).toInt();
        final text = _label(node.label, isFocus, isFocus ? 4 : level);
        final at = Offset(center.dx - text.width / 2, center.dy + radius + 4);
        final box = (at & text.size).inflate(3);
        if (isFocus || !placed.any((other) => other.overlaps(box))) {
          placed.add(box);
          text.paint(canvas, at);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ConstellationPainter oldDelegate) => true;
}

/// A ball of dust that turns while the graph loads.
class ConstellationLoader extends StatefulWidget {
  const ConstellationLoader({this.size = 150, super.key});

  final double size;

  @override
  State<ConstellationLoader> createState() => _ConstellationLoaderState();
}

class _ConstellationLoaderState extends State<ConstellationLoader>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _time = ValueNotifier<double>(0);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _time.value = elapsed.inMicroseconds / 1e6;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(painter: _SpherePainter(_time)),
    );
  }
}

final List<List<double>> _spherePoints = [
  for (var i = 0; i < 520; i++)
    () {
      final y = 1 - 2 * (i + 0.5) / 520;
      final r = math.sqrt(1 - y * y);
      final a = i * 2.39996;
      return <double>[math.cos(a) * r, y, math.sin(a) * r];
    }(),
];

class _SpherePainter extends CustomPainter {
  _SpherePainter(this.time) : super(repaint: time);

  final ValueNotifier<double> time;

  @override
  void paint(Canvas canvas, Size size) {
    final k = time.value;
    final pulse = 1 + 0.06 * math.sin(k * 4);
    final ca = math.cos(k * 1.1);
    final sa = math.sin(k * 1.1);
    final radius = size.width * 0.35 * pulse;
    final center = size.center(Offset.zero);
    final paint = Paint();
    for (final point in _spherePoints) {
      final x = point[0] * ca + point[2] * sa;
      final z = -point[0] * sa + point[2] * ca;
      final depth = (z + 1) / 2;
      paint.color = Color.fromRGBO(
        110 + (90 * depth).round(),
        120 + (80 * depth).round(),
        255,
        0.25 + 0.6 * depth,
      );
      final dot = 1.6 * (0.7 + 0.3 * depth);
      canvas.drawRect(
        Rect.fromLTWH(
          center.dx + x * radius,
          center.dy + point[1] * radius,
          dot,
          dot,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpherePainter oldDelegate) => false;
}
