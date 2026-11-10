import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/hermes_bot_face.dart';
import 'bot_character.dart';
import 'studio_catalog.dart';
import 'studio_painter.dart';

/// A [BotCharacter] drawn with the existing face renderer (or, for a studio
/// character, the studio renderer): the Blobatar
/// silhouette, seed, colour and eyes of [HermesBotFace], plus the top
/// ornament painted above the head. With no ornament it is exactly one
/// [HermesBotFace] of [size].
class CharacterFace extends StatelessWidget {
  /// Share of the box the head takes when an ornament sits above it.
  static const double headShare = .84;

  final String profileName;
  final BotCharacter character;
  final double size;
  final bool animate;
  final HermesBotFaceMotionState motionState;
  final String? semanticLabel;

  /// Pass-through to [HermesBotFace] for roster faces on a shared clock.
  final Animation<double>? clock;
  final double motionGain;
  final double? eyeGain;
  final HermesBotFaceFinish finish;

  /// Preview state of a studio character; null follows [motionState].
  final BotStudioState? studioState;

  const CharacterFace({
    super.key,
    required this.profileName,
    required this.character,
    this.size = 48,
    this.animate = false,
    this.motionState = HermesBotFaceMotionState.idle,
    this.semanticLabel,
    this.clock,
    this.motionGain = 1,
    this.eyeGain,
    this.finish = HermesBotFaceFinish.flat,
    this.studioState,
  });

  @override
  Widget build(BuildContext context) {
    // A studio character is drawn by the studio renderer; any other one
    // keeps the first-generation face exactly as it was.
    if (character.isStudio) {
      return StudioCharacterFace(
        character: character,
        profileName: profileName,
        size: size,
        animate: animate,
        state: studioState,
        motionState: motionState,
        clock: clock,
        motionGain: motionGain,
        eyeGain: eyeGain,
        semanticLabel: semanticLabel,
      );
    }
    final visual = character.visual(profileName);
    final hasTopper = character.topper != BotCharacterTopper.none;
    final head = hasTopper ? size * headShare : size;
    final face = HermesBotFace(
      visual: visual,
      size: head,
      animate: animate,
      motionState: motionState,
      eyeStyle: character.eyes,
      clock: clock,
      motionGain: motionGain,
      eyeGain: eyeGain,
      finish: finish,
      semanticLabel: hasTopper ? null : semanticLabel,
    );
    if (!hasTopper) return face;
    final colors = Theme.of(context).hermes;
    final stack = SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              key: ValueKey('character-topper-paint-${character.topper.name}'),
              painter: _TopperPainter(
                topper: character.topper,
                body: visual.headColor,
                accent: colors.accent,
              ),
            ),
          ),
          Align(alignment: Alignment.bottomCenter, child: face),
        ],
      ),
    );
    return semanticLabel == null
        ? ExcludeSemantics(child: stack)
        : Semantics(image: true, label: semanticLabel, child: stack);
  }
}

/// Paints the same still character as [CharacterFace] directly on a canvas.
void paintCharacterFaceFrame(
  Canvas canvas,
  Size size, {
  required BotCharacter character,
  required String profileName,
  required Color accent,
}) {
  final visual = character.visual(profileName);
  if (character.isStudio) {
    StudioCharacterPainter(
      character: character,
      seed: visual.seed,
      seededColor: visual.headColor,
    ).paint(canvas, size);
    return;
  }
  final hasTopper = character.topper != BotCharacterTopper.none;
  final head = hasTopper ? size.width * CharacterFace.headShare : size.width;
  if (hasTopper) {
    _TopperPainter(
      topper: character.topper,
      body: visual.headColor,
      accent: accent,
    ).paint(canvas, size);
  }
  canvas.save();
  canvas.translate((size.width - head) / 2, size.height - head);
  paintHermesBotFaceFrame(
    canvas,
    Size.square(head),
    visual,
    eyeStyle: character.eyes,
  );
  canvas.restore();
}

/// Paints one ornament in a 100x100 box whose head top sits near y = 29.
final class _TopperPainter extends CustomPainter {
  final BotCharacterTopper topper;
  final Color body;
  final Color accent;

  const _TopperPainter({
    required this.topper,
    required this.body,
    required this.accent,
  });

  static const double _base = 30;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final fill = Paint()..color = body;
    final accentFill = Paint()..color = accent;
    final stroke = Paint()
      ..color = body
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    switch (topper) {
      case BotCharacterTopper.none:
        break;
      case BotCharacterTopper.antenna:
        canvas.drawLine(const Offset(50, _base), const Offset(50, 12), stroke);
        canvas.drawCircle(const Offset(50, 9), 5.5, accentFill);
      case BotCharacterTopper.sprout:
        canvas.drawPath(
          Path()
            ..moveTo(50, _base)
            ..quadraticBezierTo(49, 20, 50, 14),
          stroke,
        );
        for (final side in const [-1.0, 1.0]) {
          canvas.save();
          canvas.translate(50, 15);
          canvas.rotate(side * .7);
          canvas.drawOval(
            Rect.fromCenter(center: Offset(side * 8, -3), width: 16, height: 8),
            accentFill,
          );
          canvas.restore();
        }
      case BotCharacterTopper.crown:
        canvas.drawPath(
          Path()
            ..moveTo(33, _base)
            ..lineTo(30, 12)
            ..lineTo(41, 20)
            ..lineTo(50, 8)
            ..lineTo(59, 20)
            ..lineTo(70, 12)
            ..lineTo(67, _base)
            ..close(),
          fill,
        );
        canvas.drawCircle(const Offset(50, 22), 3, accentFill);
      case BotCharacterTopper.halo:
        canvas.drawOval(
          Rect.fromCenter(center: const Offset(50, 17), width: 46, height: 12),
          stroke
            ..color = accent
            ..strokeWidth = 3.5,
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TopperPainter old) =>
      old.topper != topper || old.body != body || old.accent != accent;
}
