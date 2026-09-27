import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/agent_profile.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/bot_avatar_motion.dart';
import '../../../widgets/hermes_bot_face.dart';
import '../../../widgets/mission_profile_avatar.dart';

/// The one state signal a bot face shows (spec 070 § S1/§ Motion).
///
/// No presence dot and no unread dot: the face itself says idle, thinking,
/// working, speaking or "needs you".
enum BotFaceSignal { idle, thinking, working, speaking, attention }

extension BotFaceSignalMotion on BotFaceSignal {
  /// Pose reused from [HermesBotFace]: working reads a line (eye scan),
  /// attention looks at the user (listening + nudge), thinking looks around.
  HermesBotFaceMotionState get motionState => switch (this) {
    BotFaceSignal.idle => HermesBotFaceMotionState.idle,
    BotFaceSignal.thinking => HermesBotFaceMotionState.thinking,
    BotFaceSignal.working => HermesBotFaceMotionState.working,
    BotFaceSignal.speaking => HermesBotFaceMotionState.speaking,
    BotFaceSignal.attention => HermesBotFaceMotionState.listening,
  };

  bool get hasRing =>
      this == BotFaceSignal.working || this == BotFaceSignal.attention;
}

/// Test switch: when true every [LivingBotFace] paints its static frame
/// (exactly as with reduced motion) so widget tests of whole screens can
/// `pumpAndSettle`. Set for the whole suite in `flutter_test_config.dart`;
/// motion tests switch it off.
@visibleForTesting
bool debugLivingBotFacesStill = false;

/// Test hook: number of [LivingBotFace] clocks currently ticking.
@visibleForTesting
int get livingBotFaceActiveTickers => _LivingBotFaceState._active;

/// A living bot face: continuous idle breath with seeded blinks and
/// glances, thinking look-around, working scan (eyes read a line) with a
/// soft pulsing ring, attention nudge every few seconds, speaking while a
/// reply streams, and an entrance on first appearance.
///
/// Exactly ONE [AnimationController] per visible face drives the Blobatar
/// motion, the ring, the nudge and raster-avatar breathing
/// ([HermesBotFace.clock] / [BotAvatarMotion.clock]). Faces are alive for
/// as long as they are on screen; the clock stops when the face is
/// disposed (scrolled off a lazy list), sits in a background route
/// ([TickerMode]) or reduced motion is on ([MediaQuery.disableAnimationsOf]).
/// The face then paints a static frame that still carries the state (the
/// ring stays, no motion).
class LivingBotFace extends StatefulWidget {
  final String profileName;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final BotFaceSignal signal;
  final double size;
  final String? semanticLabel;

  /// Plays the scale/fade entrance the first time this face is built.
  final bool entrance;

  /// Motion amplitude. Defaults by size: large (pinned, profile hero)
  /// faces are the most expressive.
  final double? expressiveness;

  const LivingBotFace({
    super.key,
    required this.profileName,
    required this.signal,
    this.profile,
    this.avatarCache,
    this.size = 44,
    this.semanticLabel,
    this.entrance = true,
    this.expressiveness,
  });

  /// Amplitude used for a face of [size] dp: small faces need more relative
  /// motion to read at all, big ones get their personality from detail.
  static double expressivenessFor(double size) => size >= 56 ? 1.3 : 1.2;

  /// Eyes move more than the body: a glance or a scan is what makes a
  /// 44-60 dp face read as alive, while breath stays at 2-3 %.
  static double eyeGainFor(double expressiveness) => expressiveness * 2.5;

  @override
  State<LivingBotFace> createState() => _LivingBotFaceState();
}

class _LivingBotFaceState extends State<LivingBotFace>
    with SingleTickerProviderStateMixin {
  static int _active = 0;
  static const _entranceMs = 420;

  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: HermesBotFace.clockDuration,
  );
  bool _counted = false;
  bool _motion = false;
  bool _entered = false;
  double? _entranceStartMs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant LivingBotFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    _motion =
        !debugLivingBotFacesStill &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (_motion && !_entered) {
      _entered = true;
      if (widget.entrance) _entranceStartMs = _nowMs;
    }
    _run(_motion);
  }

  double get _nowMs =>
      _clock.value * HermesBotFace.clockDuration.inMilliseconds;

  void _run(bool on) {
    if (on) {
      if (!_clock.isAnimating) _clock.repeat();
      if (!_counted) {
        _counted = true;
        _active++;
      }
    } else {
      // Stopping keeps the current value: the face freezes on its last pose
      // and resumes from it, never snapping back to a neutral frame.
      _clock.stop();
      if (_counted) {
        _counted = false;
        _active--;
      }
    }
  }

  @override
  void dispose() {
    if (_counted) _active--;
    _clock.dispose();
    super.dispose();
  }

  /// Seeded per-face phase so a roster never moves in lockstep.
  late final int _phaseMs = widget.profileName.codeUnits.fold<int>(
    7,
    (hash, unit) => (hash * 31 + unit) & 0xffff,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final signal = widget.signal;
    final size = widget.size;
    final gain = widget.expressiveness ?? LivingBotFace.expressivenessFor(size);
    final face = _Face(
      profileName: widget.profileName,
      profile: widget.profile,
      avatarCache: widget.avatarCache,
      size: size,
      clock: _clock,
      motion: _motion,
      signal: signal,
      gain: gain,
    );
    final ringColor = signal == BotFaceSignal.attention
        ? colors.warning
        : colors.accent;
    final label = widget.semanticLabel;
    final body = AnimatedBuilder(
      animation: _clock,
      child: face,
      builder: (context, child) {
        final ms = _nowMs;
        // Entrance: scale 0.6→1 and fade in over the first 420 ms.
        final start = _entranceStartMs;
        final entrance = start == null || !_motion
            ? 1.0
            : Curves.easeOutBack.transform(
                ((ms - start) / _entranceMs).clamp(0.0, 1.0),
              );
        // Attention: every 3.2 s a gentle hop with a two-beat wiggle, so a
        // face that needs the user asks for it without shaking constantly.
        var dy = 0.0;
        var turn = 0.0;
        if (_motion && signal == BotFaceSignal.attention) {
          final t = ((ms + _phaseMs) % 3200) / 3200;
          if (t < .28) {
            final k = t / .28;
            dy = -math.sin(k * math.pi) * size * .07;
            turn = math.sin(k * math.pi * 4) * .09 * (1 - k);
          }
        }
        final pulse = _motion && signal.hasRing
            ? (math.sin((ms + _phaseMs) / 1300 * 2 * math.pi) + 1) / 2
            : .5;
        return Opacity(
          opacity: entrance.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: .6 + .4 * entrance,
            child: SizedBox.square(
              dimension: size,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  if (signal.hasRing)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Transform.scale(
                          scale: 1.02 + .06 * pulse,
                          child: DecoratedBox(
                            key: ValueKey('living-face-ring-${signal.name}'),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: ringColor.withValues(
                                alpha: .06 + .08 * pulse,
                              ),
                              border: Border.all(
                                color: ringColor.withValues(
                                  alpha: .35 + .5 * pulse,
                                ),
                                width: size >= 56 ? 2.5 : 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: ringColor.withValues(
                                    alpha: .08 + .22 * pulse,
                                  ),
                                  blurRadius: 4 + 8 * pulse,
                                  spreadRadius: 1 + 2 * pulse,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Transform.translate(
                    offset: Offset(0, dy),
                    child: Transform.rotate(angle: turn, child: child),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return Semantics(
      image: label != null,
      label: label,
      excludeSemantics: true,
      child: RepaintBoundary(
        key: ValueKey('living-face-${widget.profileName}-${signal.name}'),
        child: body,
      ),
    );
  }
}

/// Procedural Blobatar or raster avatar, both driven by the shared clock.
class _Face extends StatelessWidget {
  final String profileName;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final double size;
  final Animation<double> clock;
  final bool motion;
  final BotFaceSignal signal;
  final double gain;

  const _Face({
    required this.profileName,
    required this.profile,
    required this.avatarCache,
    required this.size,
    required this.clock,
    required this.motion,
    required this.signal,
    required this.gain,
  });

  @override
  Widget build(BuildContext context) {
    final profile = this.profile;
    final cache = avatarCache;
    final raster = profile != null && profile.botPaintsPhoto && cache != null;
    if (raster) {
      final busy =
          signal == BotFaceSignal.working || signal == BotFaceSignal.speaking;
      return BotAvatarMotion(
        enabled: motion,
        clock: clock,
        externalPeriod: busy
            ? const Duration(milliseconds: 1300)
            : const Duration(milliseconds: 3800),
        depth: busy ? .045 : .03,
        lift: size * (busy ? .05 : .035) * gain / 1.2,
        child: MissionProfileAvatar(
          profileName: profileName,
          hasAvatar: true,
          cache: cache,
          size: size,
          shape: profile.botShape,
          colorHex: profile.botColorHex,
          imageKind: profile.botImageKind,
        ),
      );
    }
    final visual =
        HermesBlobatarFaceVisual.tryParse(
          shapeWire: profile?.botFaceShape ?? 'blobatar',
          profileName: profileName,
        ) ??
        HermesBlobatarFaceVisual.tryParse(
          shapeWire: 'blobatar',
          profileName: profileName,
        )!;
    return HermesBotFace(
      visual: visual,
      size: size,
      animate: motion,
      clock: clock,
      motionState: signal.motionState,
      motionGain: gain,
      eyeGain: LivingBotFace.eyeGainFor(gain),
    );
  }
}
