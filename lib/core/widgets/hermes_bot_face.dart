import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/bot_visual_identity.dart';

const hermesClassicFaceShapes = ClassicFaceIdentity.shapes;
const hermesClassicFaceColors = ClassicFaceIdentity.colors;
const hermesBlobatarKinds = BlobatarShapeWire.kinds;

sealed class HermesBotFaceVisual {
  const HermesBotFaceVisual();
}

final class HermesBlobatarFaceVisual extends HermesBotFaceVisual {
  final String shapeWire;
  final String seed;
  final String seedPart;
  final String? pinnedKind;

  const HermesBlobatarFaceVisual._({
    required this.shapeWire,
    required this.seed,
    required this.seedPart,
    required this.pinnedKind,
  });

  static HermesBlobatarFaceVisual? tryParse({
    required String shapeWire,
    required String profileName,
  }) {
    final parsed = BlobatarShapeWire.tryParse(shapeWire);
    if (parsed == null) return null;
    final normalizedName = profileName.trim().toLowerCase();
    final effectiveName =
        RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(normalizedName)
        ? normalizedName
        : 'agent';
    return HermesBlobatarFaceVisual._(
      shapeWire: parsed.wire,
      seed: parsed.seed.isEmpty ? effectiveName : parsed.seed,
      seedPart: parsed.seed,
      pinnedKind: parsed.kind,
    );
  }

  static String? buildWire({String seedPart = '', String? kind}) {
    try {
      return BlobatarShapeWire.parse(
        kind == null
            ? (seedPart.isEmpty ? 'blobatar' : 'blobatar:$seedPart')
            : 'blobatar:$seedPart:$kind',
      ).wire;
    } on FormatException {
      return null;
    }
  }

  String get resolvedKind => _BlobatarLayout.create(seed, pinnedKind).shape;
}

final class HermesClassicFaceVisual extends HermesBotFaceVisual {
  final String shape;
  final String colorHex;

  const HermesClassicFaceVisual._({
    required this.shape,
    required this.colorHex,
  });

  static HermesClassicFaceVisual? tryParse({
    required String shape,
    required String colorHex,
  }) {
    final normalizedShape = shape.trim().toLowerCase();
    final normalizedColor = colorHex.trim().toLowerCase();
    if (!hermesClassicFaceShapes.contains(normalizedShape) ||
        !hermesClassicFaceColors.contains(normalizedColor)) {
      return null;
    }
    return HermesClassicFaceVisual._(
      shape: normalizedShape,
      colorHex: normalizedColor,
    );
  }
}

/// Expressive pose for an animated Blobatar preview.
///
/// This is intentionally independent from the persisted visual identity: a
/// bot can change activity while keeping the exact same Blobatar silhouette.
enum HermesBotFaceMotionState { idle, listening, thinking, speaking }

class HermesBotFace extends StatefulWidget {
  final HermesBotFaceVisual visual;
  final double size;
  final String? semanticLabel;
  final bool animate;
  final HermesBotFaceMotionState motionState;

  const HermesBotFace({
    super.key,
    required this.visual,
    this.size = 48,
    this.semanticLabel,
    this.animate = false,
    this.motionState = HermesBotFaceMotionState.idle,
  }) : assert(size > 0);

  @override
  State<HermesBotFace> createState() => _HermesBotFaceState();
}

class _HermesBotFaceState extends State<HermesBotFace>
    with SingleTickerProviderStateMixin {
  // A long shared clock keeps all independently seeded periods smooth while
  // still bounding controller values. Resetting once a day is outside any
  // realistic preview session.
  static const _clockDuration = Duration(days: 1);

  static const _stoppedClock = AlwaysStoppedAnimation<double>(0);

  AnimationController? _clock;
  bool _motionEnabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant HermesBotFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final enabled =
        widget.animate &&
        widget.visual is HermesBlobatarFaceVisual &&
        !reduceMotion &&
        TickerMode.valuesOf(context).enabled;
    _motionEnabled = enabled;
    if (enabled) {
      final clock = _clock ??= AnimationController(
        vsync: this,
        duration: _clockDuration,
      );
      if (!clock.isAnimating) clock.repeat();
    } else {
      final clock = _clock;
      clock?.stop();
      if (clock != null && clock.value != 0) clock.value = 0;
    }
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final face = RepaintBoundary(
      key: const ValueKey('hermes-bot-face-repaint-boundary'),
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          key: const ValueKey('hermes-controlled-bot-face'),
          painter: _HermesBotFacePainter(
            widget.visual,
            clock: _clock ?? _stoppedClock,
            motionEnabled: _motionEnabled,
            clockDuration: _clockDuration,
            motionState: widget.motionState,
          ),
        ),
      ),
    );
    final label = widget.semanticLabel;
    return label == null
        ? ExcludeSemantics(child: face)
        : Semantics(image: true, label: label, child: face);
  }
}

final class _HermesBotFacePainter extends CustomPainter {
  final HermesBotFaceVisual visual;
  final Animation<double> clock;
  final bool motionEnabled;
  final Duration clockDuration;
  final HermesBotFaceMotionState motionState;
  final _BlobatarLayout? _blobatarLayout;
  final _BlobatarMotionProfile? _motionProfile;

  _HermesBotFacePainter(
    this.visual, {
    required this.clock,
    required this.motionEnabled,
    required this.clockDuration,
    required this.motionState,
  }) : _blobatarLayout = switch (visual) {
         final HermesBlobatarFaceVisual face => _BlobatarLayout.create(
           face.seed,
           face.pinnedKind,
         ),
         _ => null,
       },
       _motionProfile = switch ((visual, motionEnabled)) {
         (final HermesBlobatarFaceVisual face, true) =>
           _BlobatarMotionProfile.fromSeed(face.seed),
         _ => null,
       },
       super(repaint: motionEnabled ? clock : null);

  @override
  void paint(Canvas canvas, Size size) {
    switch (visual) {
      case HermesBlobatarFaceVisual():
        final frame = motionEnabled
            ? _motionProfile!.sample(
                Duration(
                  microseconds: (clockDuration.inMicroseconds * clock.value)
                      .round(),
                ),
                state: motionState,
              )
            : HermesBotFaceMotionSnapshot.staticFrame;
        _paintBlobatar(canvas, size, _blobatarLayout!, frame);
      case final HermesClassicFaceVisual face:
        _paintClassic(canvas, size, face);
    }
  }

  @override
  bool shouldRepaint(_HermesBotFacePainter oldDelegate) =>
      !_sameVisual(oldDelegate.visual, visual) ||
      oldDelegate.motionEnabled != motionEnabled ||
      oldDelegate.motionState != motionState;
}

bool _sameVisual(HermesBotFaceVisual a, HermesBotFaceVisual b) =>
    switch ((a, b)) {
      (final HermesBlobatarFaceVisual x, final HermesBlobatarFaceVisual y) =>
        x.shapeWire == y.shapeWire && x.seed == y.seed,
      (final HermesClassicFaceVisual x, final HermesClassicFaceVisual y) =>
        x.shape == y.shape && x.colorHex == y.colorHex,
      _ => false,
    };

// ---------------------------------------------------------------------------
// Blobatar 2.0.0 native port. The package viewBox is exactly 100 x 100.

void _paintBlobatar(
  Canvas canvas,
  Size size,
  _BlobatarLayout layout,
  HermesBotFaceMotionSnapshot motion,
) {
  canvas.save();
  canvas.scale(size.width / 100, size.height / 100);
  canvas
    ..translate(50, 50 + motion.bobY)
    ..rotate(motion.headTiltRadians)
    ..scale(motion.breatheScaleX, motion.breatheScaleY)
    ..translate(-50, -50);
  final head = Paint()
    ..color = _colorFromHex(layout.headHex)
    ..style = PaintingStyle.fill;
  for (final petal in layout.petals) {
    canvas.drawCircle(Offset(petal.cx, petal.cy), petal.r, head);
  }
  for (final extra in layout.extra) {
    canvas.drawPath(extra.path, head);
  }
  canvas.drawPath(layout.bodyPath.path, head);

  final eye = Paint()
    ..color = _colorFromHex(layout.eyeHex)
    ..style = PaintingStyle.fill;
  for (final value in layout.eyes) {
    canvas.drawPath(
      _superellipse(
        _BlobEye(
          value.cx + motion.eyeOffsetX,
          value.cy + motion.eyeOffsetY,
          value.rx * motion.eyeScaleX,
          value.ry * motion.eyeScaleY * motion.blinkScaleY,
          value.n,
          value.rot,
        ),
      ).path,
      eye,
    );
  }
  canvas.restore();
}

/// Observable frame of the Blobatar motion layer.
///
/// The renderer applies these values only when [HermesBotFace.animate] is true.
/// Keeping the snapshot public and test-only lets motion be verified without
/// exposing painter internals or relying on fragile golden timing.
@visibleForTesting
final class HermesBotFaceMotionSnapshot {
  final double breatheScaleX;
  final double breatheScaleY;
  final double bobY;
  final double blinkScaleY;
  final double eyeOffsetX;
  final double eyeOffsetY;
  final double eyeScaleX;
  final double eyeScaleY;
  final double headTiltRadians;

  const HermesBotFaceMotionSnapshot({
    required this.breatheScaleX,
    required this.breatheScaleY,
    required this.bobY,
    required this.blinkScaleY,
    required this.eyeOffsetX,
    required this.eyeOffsetY,
    required this.eyeScaleX,
    required this.eyeScaleY,
    required this.headTiltRadians,
  });

  static const staticFrame = HermesBotFaceMotionSnapshot(
    breatheScaleX: 1,
    breatheScaleY: 1,
    bobY: 0,
    blinkScaleY: 1,
    eyeOffsetX: 0,
    eyeOffsetY: 0,
    eyeScaleX: 1,
    eyeScaleY: 1,
    headTiltRadians: 0,
  );
}

/// Samples the same seeded expressive channels used by [HermesBotFace].
@visibleForTesting
HermesBotFaceMotionSnapshot hermesBlobatarMotionSnapshot(
  String seed,
  Duration elapsed, {
  HermesBotFaceMotionState state = HermesBotFaceMotionState.idle,
}) => _BlobatarMotionProfile.fromSeed(seed).sample(elapsed, state: state);

final class _BlobatarMotionProfile {
  final int breathePhaseMs;
  final int bobPhaseMs;
  final int blinkDurationMs;
  final int blinkPhaseMs;
  final int saccadeDurationMs;
  final int saccadePhaseMs;
  final double lookX;
  final double lookY;

  const _BlobatarMotionProfile({
    required this.breathePhaseMs,
    required this.bobPhaseMs,
    required this.blinkDurationMs,
    required this.blinkPhaseMs,
    required this.saccadeDurationMs,
    required this.saccadePhaseMs,
    required this.lookX,
    required this.lookY,
  });

  factory _BlobatarMotionProfile.fromSeed(String seed) {
    final traits = _BlobatarTraits(seed);
    final blink = traits.num('motion.blink', 3500, 6500).round();
    final saccade = traits.num('motion.saccade', 4200, 7600).round();
    final lookXMagnitude = traits.num('motion.lookX', 1, 2.2);
    final lookYMagnitude = traits.num('motion.lookY', 0.8, 1.7);
    return _BlobatarMotionProfile(
      breathePhaseMs: traits.num('motion.phase', 0, 2800).round(),
      bobPhaseMs: traits.num('motion.bob', 0, 3400).round(),
      blinkDurationMs: blink,
      blinkPhaseMs: traits.num(
        'motion.blinkPhase',
        0,
        blink.toDouble(),
      ).round(),
      saccadeDurationMs: saccade,
      saccadePhaseMs: traits.num(
        'motion.saccadePhase',
        0,
        saccade.toDouble(),
      ).round(),
      lookX: _round2(
        lookXMagnitude * (traits('motion.lookXFlip') < 0.5 ? -1.0 : 1.0),
      ),
      lookY: _round2(
        lookYMagnitude * (traits('motion.lookYFlip') < 0.5 ? -1.0 : 1.0),
      ),
    );
  }

  HermesBotFaceMotionSnapshot sample(
    Duration elapsed, {
    required HermesBotFaceMotionState state,
  }) {
    final elapsedMs = elapsed.inMicroseconds / 1000;
    final breathe = Curves.easeInOut.transform(
      _alternateProgress(elapsedMs + breathePhaseMs, 2800),
    );
    final bob = Curves.easeInOut.transform(
      _alternateProgress(elapsedMs + bobPhaseMs, 3400),
    );
    final blink = _blinkScale(
      _cycleProgress(elapsedMs + blinkPhaseMs, blinkDurationMs),
    );
    final glanceProgress = _cycleProgress(
      elapsedMs + saccadePhaseMs,
      saccadeDurationMs,
    );
    final glance = _saccadeOffset(glanceProgress, lookX, lookY);
    // The eyes arrive first and the head follows one beat later. That tiny
    // offset is the character's signature; it reads as attention, not drift.
    final followedGlance = _saccadeOffset(
      _cycleProgress(elapsedMs + saccadePhaseMs - 180, saccadeDurationMs),
      lookX,
      lookY,
    );
    final speakingPulse = Curves.easeInOut.transform(
      _alternateProgress(elapsedMs + breathePhaseMs, 420),
    );
    return switch (state) {
      HermesBotFaceMotionState.idle => HermesBotFaceMotionSnapshot(
        breatheScaleX: 1 + 0.022 * breathe,
        breatheScaleY: 1 - 0.018 * breathe,
        bobY: -1.1 * bob,
        blinkScaleY: blink,
        eyeOffsetX: glance.dx,
        eyeOffsetY: glance.dy,
        eyeScaleX: 1,
        eyeScaleY: 1,
        headTiltRadians: followedGlance.dx * 0.008,
      ),
      HermesBotFaceMotionState.listening => HermesBotFaceMotionSnapshot(
        breatheScaleX: 1 + 0.012 * breathe,
        breatheScaleY: 1 - 0.008 * breathe,
        bobY: -0.45 * bob,
        blinkScaleY: blink,
        eyeOffsetX: glance.dx * 0.22,
        eyeOffsetY: glance.dy * 0.16,
        eyeScaleX: 1.06,
        eyeScaleY: 1.06,
        headTiltRadians: followedGlance.dx * 0.004,
      ),
      HermesBotFaceMotionState.thinking => HermesBotFaceMotionSnapshot(
        breatheScaleX: 1 + 0.015 * breathe,
        breatheScaleY: 1 - 0.012 * breathe,
        bobY: -0.65 * bob,
        blinkScaleY: blink,
        eyeOffsetX: lookX * 0.78 + glance.dx * 0.18,
        eyeOffsetY: -lookY.abs() * 0.78 + glance.dy * 0.1,
        eyeScaleX: 1,
        eyeScaleY: 0.9,
        headTiltRadians:
            (lookX.isNegative ? -1 : 1) * 0.035 + followedGlance.dx * 0.003,
      ),
      HermesBotFaceMotionState.speaking => HermesBotFaceMotionSnapshot(
        breatheScaleX: 1 + 0.014 * speakingPulse,
        breatheScaleY: 1 - 0.02 * speakingPulse,
        bobY: -0.35 * bob - 0.35 * speakingPulse,
        blinkScaleY: blink,
        eyeOffsetX: glance.dx * 0.2,
        eyeOffsetY: glance.dy * 0.12,
        eyeScaleX: 1.02,
        eyeScaleY: 1 - 0.08 * speakingPulse,
        headTiltRadians:
            (lookX.isNegative ? -1 : 1) * (speakingPulse - 0.5) * 0.018,
      ),
    };
  }
}

double _round2(double value) => (value * 100).round() / 100;

double _cycleProgress(double elapsedMs, int durationMs) =>
    (elapsedMs % durationMs) / durationMs;

double _alternateProgress(double elapsedMs, int oneWayDurationMs) {
  final cycle = oneWayDurationMs * 2;
  final value = elapsedMs % cycle;
  return value <= oneWayDurationMs
      ? value / oneWayDurationMs
      : (cycle - value) / oneWayDurationMs;
}

double _blinkScale(double progress) {
  if (progress <= 0.972) return 1;
  if (progress <= 0.986) {
    final closing = (progress - 0.972) / 0.014;
    return 1 - 0.92 * Curves.easeIn.transform(closing);
  }
  final opening = (progress - 0.986) / 0.014;
  return 0.08 + 0.92 * Curves.easeOut.transform(opening.clamp(0, 1));
}

Offset _saccadeOffset(double progress, double lookX, double lookY) {
  const stops = <(double, double, double)>[
    (0, 0, 0),
    (0.15, 0, 0),
    (0.165, -0.8, -0.9),
    (0.31, -0.8, -0.9),
    (0.325, 1, 0.1),
    (0.47, 1, 0.1),
    (0.485, -0.15, 0.85),
    (0.63, -0.15, 0.85),
    (0.645, 0.75, -0.8),
    (0.79, 0.75, -0.8),
    (0.805, -1, -0.15),
    (0.985, -1, -0.15),
    (1, 0, 0),
  ];
  for (var index = 1; index < stops.length; index++) {
    final next = stops[index];
    if (progress <= next.$1) {
      final previous = stops[index - 1];
      final span = next.$1 - previous.$1;
      final t = span == 0 ? 1.0 : (progress - previous.$1) / span;
      return Offset(
        (previous.$2 + (next.$2 - previous.$2) * t) * lookX,
        (previous.$3 + (next.$3 - previous.$3) * t) * lookY,
      );
    }
  }
  return Offset.zero;
}

final class _BlobatarLayout {
  static const _bands = <(String, double)>[
    ('round', 0.22),
    ('organic', 0.48),
    ('boxy', 0.60),
    ('capsule', 0.70),
    ('nub', 0.79),
    ('cloud', 0.86),
    ('droplet', 0.915),
    ('hexagon', 0.95),
    ('sun', 0.98),
    ('triangle', 1),
  ];

  final String normalizedSeed;
  final String? pinnedKind;
  final String shape;
  final _BlobBody body;
  final List<_Circle> petals;
  final List<_PathData> extra;
  final List<_BlobEye> eyes;
  final String headHex;
  final String eyeHex;
  final _PathData bodyPath;

  const _BlobatarLayout._({
    required this.normalizedSeed,
    required this.pinnedKind,
    required this.shape,
    required this.body,
    required this.petals,
    required this.extra,
    required this.eyes,
    required this.headHex,
    required this.eyeHex,
    required this.bodyPath,
  });

  // Un layout es inmutable una vez construido (los `..` sobre `body` de
  // `_build` ocurren solo ahí) y deriva por completo de (seed, pinnedKind),
  // así que se memoriza. `_HermesBotFacePainter` lo pedía en cada build de
  // cada avatar (~40 hashes de rasgos + construcción de paths), y una lista de
  // bots se reconstruye a menudo (refresco en vivo de Mission Control,
  // scroll). Acotado: el orden de inserción del Map hace de FIFO simple.
  static final Map<(String, String?), _BlobatarLayout> _layoutCache = {};
  static const _layoutCacheLimit = 128;

  factory _BlobatarLayout.create(String seed, String? pinnedKind) {
    final key = (seed, pinnedKind);
    final cached = _layoutCache[key];
    if (cached != null) return cached;
    final layout = _BlobatarLayout._build(seed, pinnedKind);
    if (_layoutCache.length >= _layoutCacheLimit) {
      _layoutCache.remove(_layoutCache.keys.first);
    }
    _layoutCache[key] = layout;
    return layout;
  }

  factory _BlobatarLayout._build(String seed, String? pinnedKind) {
    final traits = _BlobatarTraits(seed);
    final selected = pinnedKind ?? _pickShape(traits('shape'));
    if (!hermesBlobatarKinds.contains(selected)) {
      throw StateError('Blobatar kind crossed the allowlist: $selected');
    }

    final core = switch (selected) {
      'round' => 1.0,
      'organic' => 0.98,
      'boxy' => 0.86,
      'capsule' => 1.02,
      'nub' => 0.88,
      'cloud' => 0.78,
      'droplet' => 0.78,
      'hexagon' => 1.05,
      'sun' => 0.70,
      'triangle' => 1.15,
      _ => throw StateError('Unknown Blobatar kind: $selected'),
    };
    final r = traits.num('body.r', 31, 38) * core;
    final body = _BlobBody(
      cx: 50 + traits.jitter('body.x', 1.5),
      cy: 50 + traits.jitter('body.y', 1.5),
      rx: r,
      ry: r * traits.num('body.ratio', 0.92, 1.08),
      n: traits.num('body.n', 1.9, 2.5),
      rot: 0,
      radii: List.generate(
        traits.intValue('body.pts', 6, 8),
        (index) => 1 + traits.jitter('body.r$index', 0.16),
        growable: false,
      ),
    );

    switch (selected) {
      case 'boxy':
        body
          ..n = traits.num('body.n', 3.4, 6)
          ..rot = traits.num('body.rot', -20, 20);
      case 'capsule':
        body.ry *= traits.num('capsule.squat', 0.55, 0.68);
      case 'droplet':
        body
          ..cy += 0.22 * body.ry
          ..n = 2;
      case 'hexagon':
        body
          ..sides = 6
          ..rot = traits.num('body.rot', -12, 12)
          ..round = traits.num('poly.round', 0.24, 0.5);
      case 'triangle':
        body
          ..sides = 3
          ..rot = traits.num('body.rot', -5, 5)
          ..round = traits.num('poly.round', 0.24, 0.5);
    }

    final face = switch (selected) {
      'organic' ||
      'cloud' => _ellipseScale(body, body.radii.reduce(math.min) * 0.95),
      'capsule' => _ellipseScale(body, 0.94),
      'droplet' => _BlobEllipse(
        body.cx,
        body.cy + body.ry * 0.05,
        body.rx * 0.88,
        body.ry * 0.88,
      ),
      'hexagon' => _ellipseScale(body, 0.84),
      'triangle' => _BlobEllipse(
        body.cx,
        body.cy + body.ry * 0.1,
        body.rx * 0.54,
        body.ry * 0.36,
      ),
      _ => _BlobEllipse(body.cx, body.cy, body.rx, body.ry),
    };

    final petals = <_Circle>[];
    final extra = <_PathData>[];
    switch (selected) {
      case 'capsule':
        for (final sign in const [-1.0, 1.0]) {
          petals.add(
            _Circle(body.cx + sign * (body.rx - body.ry), body.cy, body.ry),
          );
        }
      case 'nub':
        final count = traits.intValue('nub.n', 1, 2);
        for (var index = 0; index < count; index++) {
          final angle = traits.num('nub.a$index', 0, 2 * math.pi);
          petals.add(
            _Circle(
              body.cx + math.cos(angle) * body.rx * 0.88,
              body.cy + math.sin(angle) * body.rx * 0.88,
              body.rx * traits.num('nub.r$index', 0.24, 0.4),
            ),
          );
        }
      case 'cloud':
        final count = traits.intValue('cloud.n', 4, 6);
        for (var index = 0; index < count; index++) {
          final angle = math.pi + math.pi * (index + 0.5) / count;
          petals.add(
            _Circle(
              body.cx + math.cos(angle) * body.rx * 0.8,
              body.cy + math.sin(angle) * body.rx * 0.5,
              body.rx * traits.num('cloud.r$index', 0.44, 0.62),
            ),
          );
        }
      case 'droplet':
        extra.add(
          _taper(
            body.cx,
            body.cy,
            body.rx,
            body.ry,
            traits.num('droplet.tip', 1.4, 1.65),
          ),
        );
      case 'sun':
        final count = traits.intValue('sun.n', 6, 9);
        final distance = body.rx * traits.num('sun.dist', 1, 1.08);
        final radius = body.rx * traits.num('sun.r', 0.2, 0.26);
        final offset = traits.num('sun.rot', 0, 2 * math.pi);
        for (var index = 0; index < count; index++) {
          final angle = offset + 2 * math.pi * index / count;
          petals.add(
            _Circle(
              body.cx + math.cos(angle) * distance,
              body.cy + math.sin(angle) * distance,
              radius,
            ),
          );
        }
    }

    final eyes = _fitEyes(traits, body, face);
    final palette = _blobatarPalette(traits.num('hue', 0, 360), traits('tone'));
    final bodyPath = switch (selected) {
      'organic' || 'cloud' => _blobPath(body),
      'capsule' => _box(body.cx, body.cy, body.rx - body.ry, body.ry),
      'hexagon' || 'triangle' => _blobPolygon(body),
      _ => _superellipse(body),
    };
    return _BlobatarLayout._(
      normalizedSeed: traits.normalizedSeed,
      pinnedKind: pinnedKind,
      shape: selected,
      body: body,
      petals: List.unmodifiable(petals),
      extra: List.unmodifiable(extra),
      eyes: List.unmodifiable(eyes),
      headHex: palette.$1,
      eyeHex: palette.$2,
      bodyPath: bodyPath,
    );
  }

  static String _pickShape(double value) =>
      _bands.firstWhere((entry) => value < entry.$2).$1;
}

final class _BlobatarTraits {
  static const _mask32 = 0xffffffff;
  final String normalizedSeed;
  final int _state;

  factory _BlobatarTraits(String seed) {
    final normalized = _normalizeSeed(seed);
    return _BlobatarTraits._(
      normalized,
      _feed(
        (1779033703 ^ normalized.length) & _mask32,
        utf8.encode(normalized),
      ),
    );
  }

  const _BlobatarTraits._(this.normalizedSeed, this._state);

  double call(String key) =>
      _finalize(_feed(_feed(_state, const [0xff]), utf8.encode(key))) /
      4294967296;

  double num(String key, double min, double max) =>
      min + this(key) * (max - min);

  int intValue(String key, int min, int max) =>
      min + (this(key) * (max - min + 1)).floor();

  double jitter(String key, double amount) => (this(key) * 2 - 1) * amount;

  static int _feed(int initial, List<int> bytes) {
    var hash = initial & _mask32;
    for (final byte in bytes) {
      hash = _imul32(hash ^ byte, 3432918353);
      hash = ((hash << 13) | (hash >> 19)) & _mask32;
    }
    return hash;
  }

  static int _finalize(int value) {
    var hash = _imul32(value ^ (value >> 16), 2246822507);
    hash = _imul32(hash ^ (hash >> 13), 3266489909);
    return (hash ^ (hash >> 16)) & _mask32;
  }

  static int _imul32(int a, int b) => (a * b) & _mask32;
}

// Official wire seeds are ASCII slugs. The small composition pass additionally
// keeps the common Latin NFC cases byte-identical to TextEncoder in Blobatar.
String _normalizeSeed(String seed) {
  var value = seed.trim().toLowerCase();
  const composed = <String, String>{
    'a\u0300': 'à',
    'a\u0301': 'á',
    'a\u0302': 'â',
    'a\u0303': 'ã',
    'a\u0308': 'ä',
    'a\u030a': 'å',
    'c\u0327': 'ç',
    'e\u0300': 'è',
    'e\u0301': 'é',
    'e\u0302': 'ê',
    'e\u0308': 'ë',
    'i\u0300': 'ì',
    'i\u0301': 'í',
    'i\u0302': 'î',
    'i\u0308': 'ï',
    'n\u0303': 'ñ',
    'o\u0300': 'ò',
    'o\u0301': 'ó',
    'o\u0302': 'ô',
    'o\u0303': 'õ',
    'o\u0308': 'ö',
    'u\u0300': 'ù',
    'u\u0301': 'ú',
    'u\u0302': 'û',
    'u\u0308': 'ü',
    'y\u0301': 'ý',
    'y\u0308': 'ÿ',
  };
  for (final entry in composed.entries) {
    value = value.replaceAll(entry.key, entry.value);
  }
  return value;
}

final class _BlobEllipse {
  double cx;
  double cy;
  double rx;
  double ry;

  _BlobEllipse(this.cx, this.cy, this.rx, this.ry);
}

final class _BlobBody extends _BlobEllipse {
  double n;
  double rot;
  final List<double> radii;
  int? sides;
  double? round;

  _BlobBody({
    required double cx,
    required double cy,
    required double rx,
    required double ry,
    required this.n,
    required this.rot,
    required this.radii,
  }) : super(cx, cy, rx, ry);
}

final class _BlobEye {
  final double cx;
  final double cy;
  final double rx;
  final double ry;
  final double n;
  final double rot;

  const _BlobEye(this.cx, this.cy, this.rx, this.ry, this.n, this.rot);
}

final class _Circle {
  final double cx;
  final double cy;
  final double r;

  const _Circle(this.cx, this.cy, this.r);
}

_BlobEllipse _ellipseScale(_BlobBody body, double scale) =>
    _BlobEllipse(body.cx, body.cy, body.rx * scale, body.ry * scale);

List<_BlobEye> _fitEyes(
  _BlobatarTraits traits,
  _BlobBody body,
  _BlobEllipse face,
) {
  final rx = body.rx;
  final er0 = traits.num('eye.rx', 0.075, 0.105) * rx;
  final ratio = traits.num('eye.ratio', 1.9, 3.2);
  final scale = traits.num('eye.scale', 0.78, 1.24);
  final stretch = traits.num('eye.stretch', 0.85, 1.18);
  final clearance = traits.num('eye.gap', 0.1, 0.24) * rx;
  final wide = er0 * math.max(1, scale);
  final tall = er0 * ratio * math.max(1, scale * stretch);
  final gap0 = wide + rx * 0.03 + clearance;

  final gx = traits.jitter('gaze.x', 0.09) * face.rx;
  final gy = traits.num('gaze.y', -0.2, 0.08) * face.ry;
  final dy = traits.jitter('eye.dy', 0.04) * face.ry;
  final reach = math.sqrt(wide * wide + tall * tall);
  final nx = (gx.abs() + gap0 + reach) / face.rx;
  final ny = (gy.abs() + dy.abs() + reach) / face.ry;
  final need = math.sqrt(nx * nx + ny * ny);
  final fit = need > 0.9 ? 0.9 / need : 1.0;

  final er = er0 * fit;
  final eyeRy = er * ratio;
  final gap = gap0 * fit;
  final room = math.max(0.0, math.min(1.0, clearance / tall));
  final bound = math.min(12.0, math.asin(room) * 180 / math.pi);
  final lean = traits.num('eye.lean', -1, 1) * bound;
  final lean2 = math.max(
    -12.0,
    math.min(12.0, lean + traits.jitter('eye.lean2', 3.5)),
  );
  final cx = face.cx + gx * fit;
  final cy = face.cy + gy * fit;
  final n = traits.num('eye.n', 3.5, 6);
  return [
    _BlobEye(cx - gap, cy, er, eyeRy, n, lean),
    _BlobEye(
      cx + gap,
      cy + dy * fit,
      er * scale,
      eyeRy * scale * stretch,
      n,
      lean2,
    ),
  ];
}

final class _PathData {
  final Path path;
  final String data;

  const _PathData(this.path, this.data);
}

_PathData _superellipse(dynamic value) {
  final double cx = value.cx;
  final double cy = value.cy;
  final double rx = value.rx;
  final double ry = value.ry;
  final double n = value.n;
  final double rot = value.rot;
  final k = math.min(1.0, (8 * math.pow(2, -1 / n) - 4) / 3);
  final points = <Offset>[
    Offset(rx, 0),
    Offset(rx, ry * k),
    Offset(rx * k, ry),
    Offset(0, ry),
    Offset(-rx * k, ry),
    Offset(-rx, ry * k),
    Offset(-rx, 0),
    Offset(-rx, -ry * k),
    Offset(-rx * k, -ry),
    Offset(0, -ry),
    Offset(rx * k, -ry),
    Offset(rx, -ry * k),
    Offset(rx, 0),
  ];
  final radians = rot * math.pi / 180;
  final cos = math.cos(radians);
  final sin = math.sin(radians);
  Offset at(int index) {
    final point = points[index];
    return Offset(
      cx + point.dx * cos - point.dy * sin,
      cy + point.dx * sin + point.dy * cos,
    );
  }

  final first = at(0);
  final path = Path()..moveTo(first.dx, first.dy);
  final data = StringBuffer('M${_point(first)}');
  for (var index = 1; index < 13; index += 3) {
    final a = at(index);
    final b = at(index + 1);
    final c = at(index + 2);
    path.cubicTo(a.dx, a.dy, b.dx, b.dy, c.dx, c.dy);
    data.write('C${_point(a)} ${_point(b)} ${_point(c)}');
  }
  path.close();
  data.write('Z');
  return _PathData(path, data.toString());
}

_PathData _blobPath(_BlobBody body) {
  final count = body.radii.length;
  final rotation = body.rot * math.pi / 180;
  final points = List.generate(count, (index) {
    final angle = rotation + 2 * math.pi * index / count;
    return Offset(
      body.cx + body.rx * body.radii[index] * math.cos(angle),
      body.cy + body.ry * body.radii[index] * math.sin(angle),
    );
  });
  Offset at(int index) => points[((index % count) + count) % count];
  final first = at(0);
  final path = Path()..moveTo(first.dx, first.dy);
  final data = StringBuffer('M${_point(first)}');
  for (var index = 0; index < count; index++) {
    final p0 = at(index - 1);
    final p1 = at(index);
    final p2 = at(index + 1);
    final p3 = at(index + 2);
    final c1 = p1 + (p2 - p0) / 6;
    final c2 = p2 - (p3 - p1) / 6;
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    data.write('C${_point(c1)} ${_point(c2)} ${_point(p2)}');
  }
  path.close();
  data.write('Z');
  return _PathData(path, data.toString());
}

_PathData _blobPolygon(_BlobBody body) {
  final sides = body.sides!;
  final round = body.round!;
  final cutRatio = round > 0 ? (round < 1 ? round / 2 : 0.5) : 0.0;
  final rotation = body.rot * math.pi / 180 - math.pi / 2;
  final vertices = List.generate(sides, (index) {
    final angle = rotation + 2 * math.pi * index / sides;
    return Offset(
      body.cx + body.rx * math.cos(angle),
      body.cy + body.ry * math.sin(angle),
    );
  });
  Offset at(int index) => vertices[((index % sides) + sides) % sides];
  Offset cut(int from, int to) => at(from) + (at(to) - at(from)) * cutRatio;
  final first = cut(0, -1);
  final path = Path()..moveTo(first.dx, first.dy);
  final data = StringBuffer('M${_point(first)}');
  for (var index = 0; index < sides; index++) {
    final vertex = at(index);
    final outgoing = cut(index, index + 1);
    path.quadraticBezierTo(vertex.dx, vertex.dy, outgoing.dx, outgoing.dy);
    data.write('Q${_point(vertex)} ${_point(outgoing)}');
    if (cutRatio < 0.5) {
      final incoming = cut(index + 1, index);
      path.lineTo(incoming.dx, incoming.dy);
      data.write('L${_point(incoming)}');
    }
  }
  path.close();
  data.write('Z');
  return _PathData(path, data.toString());
}

_PathData _box(double cx, double cy, double rx, double ry) {
  final left = cx - rx;
  final right = cx + rx;
  final top = cy - ry;
  final bottom = cy + ry;
  final path = Path()
    ..moveTo(left, top)
    ..lineTo(right, top)
    ..lineTo(right, bottom)
    ..lineTo(left, bottom)
    ..close();
  return _PathData(
    path,
    'M${_r2(left)} ${_r2(top)}H${_r2(right)}V${_r2(bottom)}H${_r2(left)}Z',
  );
}

_PathData _taper(double cx, double cy, double rx, double ry, double tip) {
  final t = math.max(1.05, tip);
  final tx = rx * math.sqrt(1 - 1 / (t * t));
  final ty = cy - ry / t;
  final apex = cy - t * ry;
  final px = tx * 0.14;
  final py = ty + 0.86 * (apex - ty);
  final path = Path()
    ..moveTo(cx - tx, ty)
    ..lineTo(cx - px, py)
    ..quadraticBezierTo(cx, apex, cx + px, py)
    ..lineTo(cx + tx, ty)
    ..close();
  return _PathData(
    path,
    'M${_r2(cx - tx)} ${_r2(ty)}'
    'L${_r2(cx - px)} ${_r2(py)}'
    'Q${_r2(cx)} ${_r2(apex)} ${_r2(cx + px)} ${_r2(py)}'
    'L${_r2(cx + tx)} ${_r2(ty)}Z',
  );
}

String _point(Offset point) => '${_r2(point.dx)} ${_r2(point.dy)}';

String _r2(double value) {
  final rounded = (value * 100).round() / 100;
  if (rounded == 0) return '0';
  return rounded == rounded.truncateToDouble()
      ? rounded.toInt().toString()
      : rounded.toString();
}

// ---------------------------------------------------------------------------
// Blobatar 2 authored OKLCh palette.

final class _Oklch {
  double l;
  final double c;
  final double h;

  _Oklch(this.l, this.c, this.h);

  _Oklch copy() => _Oklch(l, c, h);
}

const _surfaceFloor = 1.5;
final _darkSurface = _Oklch(0.145, 0, 0);

(String, String) _blobatarPalette(double hue, double tone) {
  final swatch = switch (tone) {
    < 0.20 => (0.86, 0.085),
    < 0.36 => (0.90, 0.028),
    < 0.62 => (0.73, 0.135),
    < 0.80 => (0.62, 0.165),
    < 0.93 => (0.87, 0.160),
    _ => (0.34, 0.035),
  };
  final bg = _Oklch(0.965, 0.01, hue);
  var head = _ensureContrast(
    _Oklch(swatch.$1, swatch.$2, hue),
    _darkSurface,
    _surfaceFloor,
  );
  var eye = head.l >= 0.5 ? _Oklch(0.17, 0.02, hue) : _Oklch(0.97, 0.012, hue);
  head = _ensureContrast(head, bg, 1.25);
  eye = _ensureContrast(eye, head, 4.5);
  return (_toHex(head), _toHex(eye));
}

List<double> _toLinear(_Oklch color) {
  final radians = color.h * math.pi / 180;
  final a = color.c * math.cos(radians);
  final b = color.c * math.sin(radians);
  final l = color.l + 0.3963377774 * a + 0.2158037573 * b;
  final m = color.l - 0.1055613458 * a - 0.0638541728 * b;
  final s = color.l - 0.0894841775 * a - 1.291485548 * b;
  final ll = l * l * l;
  final mm = m * m * m;
  final ss = s * s * s;
  return [
    4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss,
    -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss,
    -0.0041960863 * ll - 0.7034186147 * mm + 1.707614701 * ss,
  ];
}

List<double> _resolveColor(_Oklch color) {
  var rgb = _toLinear(color);
  bool inGamut(List<double> values) =>
      values.every((value) => value >= -1e-4 && value <= 1 + 1e-4);
  if (!inGamut(rgb)) {
    var low = 0.0;
    var high = color.c;
    for (var index = 0; index < 12; index++) {
      final mid = (low + high) / 2;
      if (inGamut(_toLinear(_Oklch(color.l, mid, color.h)))) {
        low = mid;
      } else {
        high = mid;
      }
    }
    rgb = _toLinear(_Oklch(color.l, low, color.h));
  }
  return rgb.map((value) => math.min(1.0, math.max(0.0, value))).toList();
}

double _luminance(_Oklch color) {
  final rgb = _resolveColor(color);
  return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
}

double _contrast(_Oklch a, _Oklch b) {
  final x = _luminance(a);
  final y = _luminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

_Oklch _ensureContrast(_Oklch foreground, _Oklch background, double minimum) {
  if (_contrast(foreground, background) >= minimum) return foreground;
  final lean = foreground.l >= background.l ? 1.0 : -1.0;
  for (final direction in [lean, -lean]) {
    final probe = foreground.copy();
    for (var index = 0; index < 60; index++) {
      probe.l = math.min(1.0, math.max(0.0, probe.l + direction * 0.02));
      if (_contrast(probe, background) >= minimum) return probe;
      if (probe.l == 0 || probe.l == 1) break;
    }
  }
  final black = _Oklch(0, 0, foreground.h);
  final white = _Oklch(1, 0, foreground.h);
  return _contrast(black, background) >= _contrast(white, background)
      ? black
      : white;
}

String _toHex(_Oklch color) {
  final bytes = _resolveColor(color).map((value) {
    final encoded = value <= 0.0031308
        ? 12.92 * value
        : 1.055 * math.pow(value, 1 / 2.4) - 0.055;
    return (encoded * 255).round().clamp(0, 255);
  });
  return '#${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Compact numeric signature generated from the same values painted above.
/// Tests pin this against npm `blobatar@2.0.0` `_layout` output.
@visibleForTesting
String hermesBlobatarV2ReferenceFixture(String seed, {String? pinnedKind}) {
  final layout = _BlobatarLayout.create(seed, pinnedKind);
  num r6(double value) {
    final rounded = (value * 1000000).round() / 1000000;
    return rounded == rounded.truncateToDouble() ? rounded.toInt() : rounded;
  }

  return jsonEncode({
    'seed': layout.normalizedSeed,
    'pin': layout.pinnedKind,
    'shape': layout.shape,
    'palette': {'head': layout.headHex, 'eye': layout.eyeHex},
    'body': {
      'cx': r6(layout.body.cx),
      'cy': r6(layout.body.cy),
      'rx': r6(layout.body.rx),
      'ry': r6(layout.body.ry),
      'n': r6(layout.body.n),
      'rot': r6(layout.body.rot),
      'radii': layout.body.radii.map(r6).toList(),
      'sides': layout.body.sides,
      'round': layout.body.round == null ? null : r6(layout.body.round!),
    },
    'petals': [
      for (final petal in layout.petals)
        {'cx': r6(petal.cx), 'cy': r6(petal.cy), 'r': r6(petal.r)},
    ],
    'extra': layout.extra.map((path) => path.data).toList(),
    'bodyPath': layout.bodyPath.data,
    'eyes': [
      for (final eye in layout.eyes)
        {
          'cx': r6(eye.cx),
          'cy': r6(eye.cy),
          'rx': r6(eye.rx),
          'ry': r6(eye.ry),
          'n': r6(eye.n),
          'rot': r6(eye.rot),
        },
    ],
  });
}

// ---------------------------------------------------------------------------
// Existing classic renderer (Desktop's classic allowlisted shape + color).

void _paintClassic(Canvas canvas, Size size, HermesClassicFaceVisual face) {
  final color = _colorFromHex(face.colorHex);
  final bodyRect = (Offset.zero & size).deflate(size.shortestSide * 0.08);
  final path = _classicPath(face.shape, bodyRect);
  canvas
    ..drawPath(path, Paint()..color = color)
    ..drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.24)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, size.shortestSide * 0.035),
    );
  _paintClassicEyes(canvas, size, color);
}

void _paintClassicEyes(Canvas canvas, Size size, Color bodyColor) {
  final shortest = size.shortestSide;
  final eyeColor = bodyColor.computeLuminance() < 0.34
      ? const Color(0xfffafaf9)
      : const Color(0xff292524);
  final eyePaint = Paint()..color = eyeColor;
  for (final direction in const [-1.0, 1.0]) {
    final center = Offset(
      size.width * 0.5 + size.width * 0.135 * direction,
      size.height * 0.47,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: shortest * 0.122,
        height: shortest * 0.142,
      ),
      eyePaint,
    );
    final catchlight = eyeColor.computeLuminance() > 0.6
        ? Colors.black.withValues(alpha: 0.58)
        : Colors.white.withValues(alpha: 0.86);
    canvas.drawCircle(
      center.translate(-shortest * 0.017, -shortest * 0.021),
      math.max(0.7, shortest * 0.012),
      Paint()..color = catchlight,
    );
  }
  if (shortest >= 28) {
    canvas.drawLine(
      Offset(size.width * 0.45, size.height * 0.66),
      Offset(size.width * 0.55, size.height * 0.66),
      Paint()
        ..color = eyeColor.withValues(alpha: 0.72)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(1, shortest * 0.025),
    );
  }
}

Path _classicPath(String shape, Rect rect) {
  final path = Path();
  final center = rect.center;
  switch (shape) {
    case 'circle':
      return path..addOval(rect);
    case 'pill':
      return path..addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height * 0.5)),
      );
    case 'triangle':
      return path
        ..moveTo(center.dx, rect.top)
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..close();
    case 'hexagon':
      return _classicPolygonPath(rect, 6, -math.pi / 2);
    case 'cloud':
      return path
        ..moveTo(rect.left, center.dy + rect.height * 0.22)
        ..cubicTo(
          rect.left,
          center.dy - rect.height * 0.12,
          rect.left + rect.width * 0.2,
          center.dy - rect.height * 0.22,
          rect.left + rect.width * 0.34,
          center.dy - rect.height * 0.13,
        )
        ..cubicTo(
          rect.left + rect.width * 0.42,
          rect.top,
          rect.left + rect.width * 0.72,
          rect.top,
          rect.left + rect.width * 0.77,
          center.dy - rect.height * 0.08,
        )
        ..cubicTo(
          rect.right,
          center.dy - rect.height * 0.12,
          rect.right,
          center.dy + rect.height * 0.2,
          rect.right - rect.width * 0.08,
          center.dy + rect.height * 0.28,
        )
        ..lineTo(rect.left + rect.width * 0.12, rect.bottom)
        ..close();
    case 'drop':
      return path
        ..moveTo(center.dx, rect.top)
        ..cubicTo(
          rect.right,
          center.dy,
          rect.right,
          rect.bottom,
          center.dx,
          rect.bottom,
        )
        ..cubicTo(
          rect.left,
          rect.bottom,
          rect.left,
          center.dy,
          center.dx,
          rect.top,
        )
        ..close();
    case 'blob':
      return _classicOrganicPath(rect, const [
        0.93,
        0.8,
        0.96,
        0.84,
        0.92,
        0.79,
        0.95,
        0.82,
      ]);
    case 'squircle':
      return path..addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.width * 0.28)),
      );
  }
  throw StateError('Classic shape crossed the allowlist boundary: $shape');
}

Path _classicPolygonPath(Rect rect, int sides, double rotation) {
  final radius = math.min(rect.width, rect.height) / 2;
  final path = Path();
  for (var index = 0; index < sides; index++) {
    final angle = rotation + math.pi * 2 * index / sides;
    final point =
        rect.center + Offset(math.cos(angle), math.sin(angle)) * radius;
    if (index == 0) {
      path.moveTo(point.dx, point.dy);
    } else {
      path.lineTo(point.dx, point.dy);
    }
  }
  return path..close();
}

Path _classicOrganicPath(Rect rect, List<double> radii) {
  final points = <Offset>[];
  for (var index = 0; index < 8; index++) {
    final angle = -math.pi / 2 + math.pi * 2 * index / 8;
    final radius = radii[index % radii.length];
    points.add(
      rect.center +
          Offset(
            math.cos(angle) * rect.width * 0.5 * radius,
            math.sin(angle) * rect.height * 0.5 * radius,
          ),
    );
  }
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (var index = 0; index < points.length; index++) {
    final current = points[index];
    final next = points[(index + 1) % points.length];
    path.quadraticBezierTo(
      current.dx,
      current.dy,
      (current.dx + next.dx) / 2,
      (current.dy + next.dy) / 2,
    );
  }
  return path..close();
}

Color _colorFromHex(String value) =>
    Color(0xff000000 | int.parse(value.substring(1), radix: 16));
