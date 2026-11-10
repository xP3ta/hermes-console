import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../widgets/hermes_bot_face.dart';
import 'studio_catalog.dart';

/// How the eyes read in a pose, whatever eye style the character wears.
enum BotEyeMood { open, closed, joy, heart, cross }

/// Little extras drawn around the character in some poses.
enum BotOverlay { none, zzz, confetti, hearts, sweat }

/// One frame of a studio character: the face engine's own snapshot plus the
/// body transform and the mood/overlay of the states the face engine does not
/// have.
@immutable
final class StudioPose {
  /// Breath, bob, blink, glance and tilt, from the face motion engine.
  final HermesBotFaceMotionSnapshot face;
  final double dx;
  final double dy;

  /// Extra turn of the whole body, radians.
  final double rotation;
  final double scaleX;
  final double scaleY;
  final BotEyeMood mood;
  final BotOverlay overlay;

  /// 0..1 loop of the overlay animation.
  final double phase;

  const StudioPose({
    this.face = HermesBotFaceMotionSnapshot.staticFrame,
    this.dx = 0,
    this.dy = 0,
    this.rotation = 0,
    this.scaleX = 1,
    this.scaleY = 1,
    this.mood = BotEyeMood.open,
    this.overlay = BotOverlay.none,
    this.phase = 0.5,
  });

  /// Motionless, neutral.
  static const StudioPose rest = StudioPose();
}

/// Samples the poses of the fourteen preview states.
///
/// The idle, listen, think, work and speak poses ARE the face motion engine's
/// ([HermesBotFaceMotionSampler]); the rest layer a body transform, a mood
/// and an overlay on top of its idle pose, so blinking and glancing carry on
/// underneath. With [moving] false every state is a still expression: no
/// displacement, no turn, only what the state means (closed eyes and the
/// letters of sleep, the hearts of love...). That is the pose for reduced
/// motion.
final class StudioPoseSampler {
  final HermesBotFaceMotionSampler _faces;

  StudioPoseSampler(String seed) : _faces = HermesBotFaceMotionSampler(seed);

  /// Faces of the face engine that a state maps onto, if it has one.
  static HermesBotFaceMotionState? engineState(BotStudioState state) =>
      switch (state) {
        BotStudioState.idle => HermesBotFaceMotionState.idle,
        BotStudioState.listen => HermesBotFaceMotionState.listening,
        BotStudioState.think => HermesBotFaceMotionState.thinking,
        BotStudioState.work => HermesBotFaceMotionState.working,
        BotStudioState.speak => HermesBotFaceMotionState.speaking,
        _ => null,
      };

  /// The preview state of a face-engine state (rosters drive faces with it).
  static BotStudioState fromEngine(HermesBotFaceMotionState state) =>
      switch (state) {
        HermesBotFaceMotionState.idle => BotStudioState.idle,
        HermesBotFaceMotionState.listening => BotStudioState.listen,
        HermesBotFaceMotionState.thinking => BotStudioState.think,
        HermesBotFaceMotionState.speaking => BotStudioState.speak,
        HermesBotFaceMotionState.working => BotStudioState.work,
      };

  StudioPose sample(
    BotStudioState state,
    Duration elapsed, {
    bool moving = true,
    double gain = 1,
    double? eyeGain,
  }) {
    if (!moving) return _expression(state);
    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final engine = engineState(state);
    if (engine != null) {
      return StudioPose(
        face: _faces
            .sample(elapsed, state: engine)
            .scaled(gain, eyeGain: eyeGain),
      );
    }
    if (state == BotStudioState.still) return StudioPose.rest;
    final idle = _faces
        .sample(elapsed, state: HermesBotFaceMotionState.idle)
        .scaled(gain, eyeGain: eyeGain);
    switch (state) {
      case BotStudioState.curious:
        return StudioPose(
          face: _tweak(
            idle,
            eyeOffsetX: 2.2 * math.sin(t * 1.3),
            eyeOffsetY: -0.6,
            eyeScaleX: 1.12,
            eyeScaleY: 1.12,
            headTiltRadians: 0.14 * math.sin(t * 0.9 + 1),
            brows: 0.8,
          ),
        );
      case BotStudioState.celebrate:
        final hop = math.sin(t * 5.5).abs();
        return StudioPose(
          face: idle,
          dy: -7 * hop,
          scaleX: 1 + 0.05 * (1 - hop),
          scaleY: 1 - 0.05 * (1 - hop),
          rotation: 0.08 * math.sin(t * 2.75),
          mood: BotEyeMood.joy,
          overlay: BotOverlay.confetti,
          phase: _loop(t, 1.6),
        );
      case BotStudioState.love:
        final pulse = math.sin(t * 6);
        return StudioPose(
          face: idle,
          scaleX: 1 + 0.035 * pulse,
          scaleY: 1 + 0.035 * pulse,
          rotation: 0.05 * math.sin(t * 1.2),
          mood: BotEyeMood.heart,
          overlay: BotOverlay.hearts,
          phase: _loop(t, 2),
        );
      case BotStudioState.oops:
        final cycle = _loop(t, 2.4);
        final shaking = cycle < 0.35;
        return StudioPose(
          face: _tweak(idle, brows: -1),
          dx: shaking ? math.sin(t * 40) * (1 - cycle / 0.35) * 1.6 : 0,
          mood: shaking ? BotEyeMood.cross : BotEyeMood.open,
          overlay: BotOverlay.sweat,
          phase: cycle,
        );
      case BotStudioState.sleep:
        final breath = math.sin(t * 1.6);
        return StudioPose(
          face: _tweak(idle, blinkScaleY: 1),
          dy: 1.5,
          scaleX: 1 + 0.02 * breath,
          scaleY: 1 - 0.025 * breath,
          rotation: 0.06,
          mood: BotEyeMood.closed,
          overlay: BotOverlay.zzz,
          phase: _loop(t, 2.6),
        );
      case BotStudioState.bounce:
        final hop = math.sin(t * 4.4).abs();
        final squash = (1 - hop) * (1 - hop);
        return StudioPose(
          face: idle,
          dy: -10 * hop,
          scaleX: 1 + 0.09 * squash,
          scaleY: 1 - 0.09 * squash,
        );
      case BotStudioState.dance:
        return StudioPose(
          face: idle,
          dx: 5 * math.sin(t * 3.2),
          dy: -3 * math.sin(t * 6.4).abs(),
          rotation: 0.2 * math.sin(t * 3.2),
          mood: math.sin(t * 1.6) > 0 ? BotEyeMood.joy : BotEyeMood.open,
        );
      case BotStudioState.spin:
        return StudioPose(face: idle, rotation: _loop(t, 1.5) * 2 * math.pi);
      case BotStudioState.still:
      case BotStudioState.idle:
      case BotStudioState.listen:
      case BotStudioState.think:
      case BotStudioState.work:
      case BotStudioState.speak:
        return StudioPose.rest;
    }
  }

  /// The still expression of [state].
  static StudioPose _expression(BotStudioState state) => switch (state) {
    BotStudioState.curious => const StudioPose(
      face: HermesBotFaceMotionSnapshot(
        breatheScaleX: 1,
        breatheScaleY: 1,
        bobY: 0,
        blinkScaleY: 1,
        eyeOffsetX: 0,
        eyeOffsetY: 0,
        eyeScaleX: 1.12,
        eyeScaleY: 1.12,
        headTiltRadians: 0.1,
        brows: 0.8,
      ),
    ),
    BotStudioState.celebrate => const StudioPose(
      mood: BotEyeMood.joy,
      overlay: BotOverlay.confetti,
    ),
    BotStudioState.love => const StudioPose(
      mood: BotEyeMood.heart,
      overlay: BotOverlay.hearts,
    ),
    BotStudioState.oops => const StudioPose(
      face: HermesBotFaceMotionSnapshot(
        breatheScaleX: 1,
        breatheScaleY: 1,
        bobY: 0,
        blinkScaleY: 1,
        eyeOffsetX: 0,
        eyeOffsetY: 0,
        eyeScaleX: 1,
        eyeScaleY: 1,
        headTiltRadians: 0,
        brows: -1,
      ),
      mood: BotEyeMood.cross,
      overlay: BotOverlay.sweat,
    ),
    BotStudioState.sleep => const StudioPose(
      mood: BotEyeMood.closed,
      overlay: BotOverlay.zzz,
      rotation: 0.06,
    ),
    BotStudioState.dance => const StudioPose(mood: BotEyeMood.joy),
    _ => StudioPose.rest,
  };

  static double _loop(double t, double seconds) => (t % seconds) / seconds;

  static HermesBotFaceMotionSnapshot _tweak(
    HermesBotFaceMotionSnapshot base, {
    double? blinkScaleY,
    double? eyeOffsetX,
    double? eyeOffsetY,
    double? eyeScaleX,
    double? eyeScaleY,
    double? headTiltRadians,
    double? brows,
  }) => HermesBotFaceMotionSnapshot(
    breatheScaleX: base.breatheScaleX,
    breatheScaleY: base.breatheScaleY,
    bobY: base.bobY,
    blinkScaleY: blinkScaleY ?? base.blinkScaleY,
    eyeOffsetX: eyeOffsetX ?? base.eyeOffsetX,
    eyeOffsetY: eyeOffsetY ?? base.eyeOffsetY,
    eyeScaleX: eyeScaleX ?? base.eyeScaleX,
    eyeScaleY: eyeScaleY ?? base.eyeScaleY,
    headTiltRadians: headTiltRadians ?? base.headTiltRadians,
    eyeGlyph: base.eyeGlyph,
    brows: brows ?? base.brows,
  );
}
