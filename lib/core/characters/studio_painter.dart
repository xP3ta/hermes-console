import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import '../widgets/hermes_bot_face.dart';
import 'blob_shape.dart';
import 'bot_character.dart';
import 'bot_motion.dart';
import 'studio_catalog.dart';
import 'studio_eyes.dart';
import 'studio_motion.dart';
import 'studio_pieces.dart';

const Rect _canvasBox = Rect.fromLTWH(0, 0, 100, 100);
const Color _white = Color.fromARGB(255, 255, 255, 255);
const Color _black = Color.fromARGB(255, 0, 0, 0);

/// The colour of a studio body for contrast purposes (eyes, pieces, fur):
/// the solid colour, or the mean of the gradient's stops.
Color studioBodyColor(BotCharacter character, Color seeded) {
  final gradient = botGradientById(character.gradient);
  if (gradient != null) {
    var r = 0.0;
    var g = 0.0;
    var b = 0.0;
    for (final stop in gradient.stops) {
      final c = colorFromHex(stop);
      r += c.r;
      g += c.g;
      b += c.b;
    }
    final n = gradient.stops.length;
    return Color.from(alpha: 1, red: r / n, green: g / n, blue: b / n);
  }
  final hex = character.bodyColor ?? character.colorHex;
  return hex == null ? seeded : colorFromHex(hex);
}

/// Soft, wide shading of the "soft" finish and the base of "matte".
final ui.Shader _matteShader = ui.Gradient.radial(
  const Offset(38, 32),
  62,
  const [
    Color.fromARGB(51, 255, 255, 255),
    Color.fromARGB(0, 255, 255, 255),
    Color.fromARGB(41, 0, 0, 0),
  ],
  const [0, 0.5, 1],
);

final ui.Shader _softShader = ui.Gradient.radial(
  const Offset(42, 30),
  70,
  const [
    Color.fromARGB(89, 255, 255, 255),
    Color.fromARGB(0, 255, 255, 255),
    Color.fromARGB(64, 0, 0, 0),
  ],
  const [0, 0.55, 1],
);

final ui.Shader _glossShader = ui.Gradient.linear(
  const Offset(0, -6),
  const Offset(0, 6),
  const [Color.fromARGB(166, 255, 255, 255), Color.fromARGB(0, 255, 255, 255)],
);

Path? _heartPath;
Path get _heart => _heartPath ??= Path()
  ..moveTo(0, 6)
  ..cubicTo(-10, -1, -7, -9, 0, -4)
  ..cubicTo(7, -9, 10, -1, 0, 6)
  ..close();

const List<String> _confettiHex = [
  '#f472b6',
  '#facc15',
  '#38bdf8',
  '#4ade80',
  '#a78bfa',
];

/// Paints a studio [BotCharacter] on a 100 x 100 canvas scaled to the size
/// it is given.
///
/// Body, pieces, eyes, finish and fur come from the character; the pose
/// comes from the one motion engine ([StudioPoseSampler]), driven by
/// [clock] when [moving]. It repaints with the clock only; a new character
/// needs a new painter.
final class StudioCharacterPainter extends CustomPainter {
  final BotCharacter character;
  final String seed;

  /// The seeded body colour when the character sets none.
  final Color seededColor;
  final BotStudioState state;
  final Animation<double>? clock;
  final bool moving;
  final Duration clockDuration;
  final double gain;
  final double eyeGain;

  /// Ink of the letters and drops of the overlays.
  final Color overlayInk;

  late final StudioPoseSampler _sampler = StudioPoseSampler(seed);

  StudioCharacterPainter({
    required this.character,
    required this.seed,
    required this.seededColor,
    this.state = BotStudioState.idle,
    this.clock,
    this.moving = false,
    this.clockDuration = HermesBotFace.clockDuration,
    this.gain = 1,
    double? eyeGain,
    this.overlayInk = _black,
  }) : eyeGain = eyeGain ?? gain,
       super(repaint: moving ? clock : null);

  @override
  void paint(Canvas canvas, Size size) {
    final live = moving && clock != null;
    final pose = _sampler.sample(
      state,
      live
          ? Duration(
              microseconds: (clockDuration.inMicroseconds * clock!.value)
                  .round(),
            )
          : Duration.zero,
      moving: live,
      gain: gain,
      eyeGain: eyeGain,
    );
    final form = character.form ?? BotForm.round;
    final body = BlobShape.body(
      form: form,
      range: character.range,
      strength: character.strength,
      seed: seed,
    );
    final main = studioBodyColor(character, seededColor);
    final face = pose.face;

    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    canvas.save();
    canvas.translate(50 + pose.dx, 50 + face.bobY + pose.dy);
    canvas.rotate(face.headTiltRadians + pose.rotation);
    canvas.scale(
      face.breatheScaleX * pose.scaleX,
      face.breatheScaleY * pose.scaleY,
    );
    canvas.translate(-50, -50);

    for (final piece in character.pieces) {
      if (StudioPieces.of(piece.kind).behind) {
        StudioPieces.paint(canvas, piece, main);
      }
    }

    final gradient = botGradientById(character.gradient);
    final bodyPaint = Paint()..isAntiAlias = true;
    if (gradient == null) {
      bodyPaint.color = main;
    } else {
      bodyPaint.shader = ui.Gradient.linear(
        const Offset(16, 12),
        const Offset(84, 88),
        [for (final stop in gradient.stops) colorFromHex(stop)],
        gradient.stops.length == 3 ? const [0, 0.5, 1] : null,
      );
    }
    canvas.drawPath(body, bodyPaint);

    if (character.finish != BotFinish.flat || character.fur) {
      canvas.save();
      canvas.clipPath(body);
      _paintFinish(canvas, body);
      if (character.fur) {
        canvas.drawPath(
          BlobShape.fur(
            form: form,
            range: character.range,
            strength: character.strength,
            seed: seed,
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 1.1
            ..color = (main.computeLuminance() > 0.5 ? _black : _white)
                .withValues(alpha: 0.2),
        );
      }
      canvas.restore();
    }

    final eyeColor = character.eyeColor != null
        ? colorFromHex(character.eyeColor!)
        : ThemeContrast.bestBlackOrWhite(main);
    paintStudioEyes(
      canvas,
      style: character.eyeStyle,
      color: eyeColor,
      size: character.eyeSize,
      face: face,
      mood: pose.mood,
      spacing: form == BotForm.rectangle ? 17 : StudioEyeLayout.spacing,
    );

    for (final piece in character.pieces) {
      if (!StudioPieces.of(piece.kind).behind) {
        StudioPieces.paint(canvas, piece, main);
      }
    }
    canvas.restore();

    if (pose.overlay != BotOverlay.none) _paintOverlay(canvas, pose);
    canvas.restore();
  }

  void _paintFinish(Canvas canvas, Path body) {
    switch (character.finish) {
      case BotFinish.flat:
        break;
      case BotFinish.matte:
        canvas.drawRect(_canvasBox, Paint()..shader = _matteShader);
      case BotFinish.soft:
        canvas.drawRect(_canvasBox, Paint()..shader = _softShader);
      case BotFinish.glossy:
        canvas.drawRect(_canvasBox, Paint()..shader = _matteShader);
        canvas.drawPath(
          body,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.4
            ..color = _white.withValues(alpha: 0.2),
        );
        canvas.save();
        canvas.translate(36, 27);
        canvas.rotate(-0.5);
        canvas.drawOval(
          Rect.fromCenter(center: Offset.zero, width: 26, height: 12),
          Paint()..shader = _glossShader,
        );
        canvas.restore();
        canvas.drawCircle(
          const Offset(25, 40),
          1.6,
          Paint()..color = _white.withValues(alpha: 0.5),
        );
    }
  }

  void _paintOverlay(Canvas canvas, StudioPose pose) {
    final phase = pose.phase;
    switch (pose.overlay) {
      case BotOverlay.none:
        break;
      case BotOverlay.zzz:
        for (var i = 0; i < 3; i++) {
          final t = (phase + i / 3) % 1;
          final s = 2.2 + 2.8 * t;
          final x = 63 + t * 17;
          final y = 38 - t * 34;
          final path = Path()
            ..moveTo(x - s, y - s)
            ..lineTo(x + s, y - s)
            ..lineTo(x - s, y + s)
            ..lineTo(x + s, y + s);
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = 1.6
              ..color = overlayInk.withValues(
                alpha: math.sin(math.pi * t).clamp(0.0, 1.0).toDouble(),
              ),
          );
        }
      case BotOverlay.confetti:
        for (var i = 0; i < 8; i++) {
          final angle = i * math.pi / 4 + phase * 0.6;
          final pulse = math.sin(math.pi * ((phase * 2 + i / 8) % 1));
          final centre = Offset(
            50 + 45 * math.cos(angle),
            50 + 44 * math.sin(angle),
          );
          final r = 1 + 3.6 * pulse;
          canvas.drawPath(
            Path()
              ..moveTo(centre.dx, centre.dy - r)
              ..quadraticBezierTo(
                centre.dx,
                centre.dy,
                centre.dx + r,
                centre.dy,
              )
              ..quadraticBezierTo(
                centre.dx,
                centre.dy,
                centre.dx,
                centre.dy + r,
              )
              ..quadraticBezierTo(
                centre.dx,
                centre.dy,
                centre.dx - r,
                centre.dy,
              )
              ..quadraticBezierTo(
                centre.dx,
                centre.dy,
                centre.dx,
                centre.dy - r,
              )
              ..close(),
            Paint()
              ..color = colorFromHex(_confettiHex[i % _confettiHex.length]),
          );
        }
      case BotOverlay.hearts:
        for (var i = 0; i < 3; i++) {
          final t = (phase + i / 3) % 1;
          canvas.save();
          canvas.translate(
            50 + (i - 1) * 20 + 3 * math.sin(t * 6),
            20 - 18 * t,
          );
          canvas.scale(0.55 + 0.25 * t, 0.55 + 0.25 * t);
          canvas.drawPath(
            _heart,
            Paint()
              ..color = colorFromHex('#fb7185').withValues(
                alpha: math.sin(math.pi * t).clamp(0.0, 1.0).toDouble(),
              ),
          );
          canvas.restore();
        }
      case BotOverlay.sweat:
        final t = phase;
        canvas.save();
        canvas.translate(74, 30 + 10 * t);
        canvas.drawPath(
          Path()
            ..moveTo(0, -5)
            ..cubicTo(3, -1, 4, 1, 4, 2.5)
            ..cubicTo(4, 5, 2, 6, 0, 6)
            ..cubicTo(-2, 6, -4, 5, -4, 2.5)
            ..cubicTo(-4, 1, -3, -1, 0, -5)
            ..close(),
          Paint()
            ..color = colorFromHex(
              '#7dd3fc',
            ).withValues(alpha: (1 - t).clamp(0.2, 1.0).toDouble()),
        );
        canvas.restore();
    }
  }

  @override
  bool shouldRepaint(StudioCharacterPainter old) =>
      old.character != character ||
      old.seed != seed ||
      old.seededColor != seededColor ||
      old.state != state ||
      old.moving != moving ||
      old.gain != gain ||
      old.eyeGain != eyeGain ||
      old.overlayInk != overlayInk ||
      !identical(old.clock, clock);
}

/// A studio character as a widget: one repaint boundary and one painter.
///
/// With [animate] and motion allowed ([botMotionAllowed]: the "Animar bots"
/// setting on and the system not asking for reduced motion) it runs a clock
/// of its own, or follows [clock] when a roster shares one; otherwise it
/// paints the still expression of its state and holds no ticker.
class StudioCharacterFace extends StatefulWidget {
  final BotCharacter character;
  final String profileName;
  final double size;
  final bool animate;

  /// The preview state; null follows [motionState] (the five states of the
  /// face engine).
  final BotStudioState? state;
  final HermesBotFaceMotionState motionState;
  final Animation<double>? clock;
  final double motionGain;
  final double? eyeGain;
  final String? semanticLabel;

  const StudioCharacterFace({
    super.key,
    required this.character,
    required this.profileName,
    this.size = 48,
    this.animate = false,
    this.state,
    this.motionState = HermesBotFaceMotionState.idle,
    this.clock,
    this.motionGain = 1,
    this.eyeGain,
    this.semanticLabel,
  }) : assert(size > 0);

  @override
  State<StudioCharacterFace> createState() => _StudioCharacterFaceState();
}

class _StudioCharacterFaceState extends State<StudioCharacterFace>
    with SingleTickerProviderStateMixin {
  AnimationController? _clock;
  bool _moving = false;

  BotStudioState get _state =>
      widget.state ?? StudioPoseSampler.fromEngine(widget.motionState);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant StudioCharacterFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final enabled =
        widget.animate &&
        _state != BotStudioState.still &&
        botMotionAllowed(context) &&
        TickerMode.valuesOf(context).enabled;
    _moving = enabled;
    // The controller is kept (a State holds one ticker for life) and only
    // stopped, so a face that stops moving holds no running ticker.
    if (widget.clock != null || !enabled) {
      _clock?.stop();
      return;
    }
    final clock = _clock ??= AnimationController(
      vsync: this,
      duration: HermesBotFace.clockDuration,
    );
    if (!clock.isAnimating) clock.repeat();
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visual = widget.character.visual(widget.profileName);
    final ink =
        Theme.of(context).extension<HermesThemeColors>()?.textSecondary ??
        _black;
    final face = RepaintBoundary(
      key: const ValueKey('studio-character-repaint'),
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          key: const ValueKey('studio-character-paint'),
          painter: StudioCharacterPainter(
            character: widget.character,
            seed: visual.seed,
            seededColor: visual.headColor,
            state: _state,
            clock: widget.clock ?? (_moving ? _clock : null),
            moving: _moving,
            gain: widget.motionGain,
            eyeGain: widget.eyeGain,
            overlayInk: ink,
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
