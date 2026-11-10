import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Radio con el que un círculo centrado en [origin] cubre todo [size].
double themeRevealMaxRadius(Size size, Offset origin) {
  double dist(Offset corner) => (corner - origin).distance;
  return [
    dist(Offset.zero),
    dist(Offset(size.width, 0)),
    dist(Offset(0, size.height)),
    dist(Offset(size.width, size.height)),
  ].reduce((a, b) => a > b ? a : b);
}

/// Todo [size] menos el círculo de [radius] en [origin]: lo que aún enseña la
/// captura del tema anterior mientras el nuevo se abre por el agujero.
Path themeRevealClipPath(Size size, Offset origin, double radius) {
  return Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addOval(Rect.fromCircle(center: origin, radius: radius));
}

class _RevealClipper extends CustomClipper<Path> {
  const _RevealClipper(this.origin, this.radius);

  final Offset origin;
  final double radius;

  @override
  Path getClip(Size size) => themeRevealClipPath(size, origin, radius);

  @override
  bool shouldReclip(_RevealClipper old) =>
      old.origin != origin || old.radius != radius;
}

/// Envuelve la app para poder cambiar de tema con un círculo que se expande
/// desde el último toque: se captura la pantalla con el tema anterior, se
/// aplica el cambio y la captura se recorta con un [ClipPath] cada vez más
/// agujereado hasta desaparecer.
///
/// Siempre activo (ya no hay ajuste), salvo que «reducir movimiento» esté
/// pedido; en ese caso, o si la captura falla, el cambio es inmediato. Ver [HermesThemeReveal.run].
class HermesThemeRevealHost extends StatefulWidget {
  const HermesThemeRevealHost({required this.child, super.key});

  final Widget child;

  @override
  State<HermesThemeRevealHost> createState() => HermesThemeRevealHostState();
}

class HermesThemeRevealHostState extends State<HermesThemeRevealHost>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boundaryKey = GlobalKey();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  Offset _lastPointer = Offset.zero;
  bool _hasPointer = false;
  ui.Image? _snapshot;
  Offset _origin = Offset.zero;
  bool _running = false;

  /// Hay un revelado en curso (la captura está encima de la app).
  bool get revealing => _snapshot != null;

  /// Ejecuta [change] (el cambio de tema) con el círculo si procede, o sin él.
  Future<void> reveal(Future<void> Function() change) async {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion || _running) {
      await change();
      return;
    }
    _running = true;
    try {
      ui.Image? image;
      try {
        final boundary =
            _boundaryKey.currentContext?.findRenderObject()
                as RenderRepaintBoundary?;
        if (boundary != null && !boundary.debugNeedsPaint) {
          image = await boundary.toImage(
            pixelRatio: MediaQuery.devicePixelRatioOf(context),
          );
        }
      } catch (error) {
        debugPrint('[motion] theme capture failed: $error');
      }
      await change();
      if (image == null) return;
      if (!mounted) {
        image.dispose();
        return;
      }
      final size = MediaQuery.sizeOf(context);
      setState(() {
        _snapshot = image;
        _origin = _hasPointer ? _lastPointer : size.center(Offset.zero);
      });
      try {
        await _controller.forward(from: 0);
      } on TickerCanceled {
        // Disposed mid-animation.
      }
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _snapshot = null);
      image.dispose();
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _lastPointer = event.position;
        _hasPointer = true;
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          RepaintBoundary(key: _boundaryKey, child: widget.child),
          if (snapshot != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final size = MediaQuery.sizeOf(context);
                    final radius =
                        themeRevealMaxRadius(size, _origin) *
                        Curves.easeInOutCubic.transform(_controller.value);
                    return ClipPath(
                      clipper: _RevealClipper(_origin, radius),
                      child: RawImage(
                        image: snapshot,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.low,
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Punto de entrada para quien cambia el tema.
abstract final class HermesThemeReveal {
  /// Ejecuta [change] dentro del revelado circular si hay un
  /// [HermesThemeRevealHost] por encima y no se pide «reducir movimiento»; si
  /// no, solo lo ejecuta.
  static Future<void> run(
    BuildContext context,
    Future<void> Function() change,
  ) {
    final host = context.findAncestorStateOfType<HermesThemeRevealHostState>();
    if (host == null) return change();
    return host.reveal(change);
  }
}
