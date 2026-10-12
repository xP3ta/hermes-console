import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/agent_profile.dart';
import '../../../models/profile_identity.dart';
import '../../../widgets/profile_pet_avatar.dart';
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

/// Look of a [LivingBotFace]: [classic] (pulsing ring, flat face) or
/// [dots] (Bots home, owner variant C): matte volume, larger eyes, a thin
/// orbit ring with one travelling dot while busy and
/// a static amber ring plus dot while the bot waits for the user. Both share
/// the same clock rules (idle never ticks, busy ≤ ~30 fps, covered,
/// background or reduced motion paint a static frame).
///
/// [calm] (Bots home, owner polish after QA 9493): the [dots] face with no
/// ring, orbit or glow; the state is one small soft dot on the face's
/// lower edge (accent while busy, amber while it waits for the user).
enum LivingBotFaceStyle { classic, dots, calm }

/// Test switch: when true every [LivingBotFace] paints its static frame
/// (exactly as with reduced motion) so widget tests of whole screens can
/// `pumpAndSettle`. Set for the whole suite in `flutter_test_config.dart`;
/// motion tests switch it off.
@visibleForTesting
bool debugLivingBotFacesStill = false;

/// Test hook: faces riding the shared busy clock (continuous state motion).
@visibleForTesting
int get livingBotFaceActiveTickers => _FaceClocks.busy.faces;

/// Test hook: idle faces riding the shared idle clock.
@visibleForTesting
int get livingBotFaceIdleFaces => _FaceClocks.idle.faces;

/// Test hook: frame timers running for ALL living faces together: 0, 1
/// (idle or busy) or 2, whatever the number of faces on screen.
@visibleForTesting
int get livingBotFaceClockTimers =>
    (_FaceClocks.idle.running ? 1 : 0) + (_FaceClocks.busy.running ? 1 : 0);

/// Test hook: the shared clocks, to count their ticks.
@visibleForTesting
Animation<double> get livingBotFaceIdleClock => _FaceClocks.idle;
@visibleForTesting
Animation<double> get livingBotFaceBusyClock => _FaceClocks.busy;

/// A capped frame clock shared by every living face of one kind.
///
/// One periodic [Timer] for all the faces that ride it, never a vsync
/// ticker per face: N faces on screen cost one wake-up per frame interval
/// and one repaint each (their painters listen to this clock), never N
/// timers. It holds no timer while no face rides it or while the app is
/// not in the foreground.
///
/// Its value is in [HermesBotFace.clockDuration] units, like a face's own
/// clock, so seeded breath/blink/glance periods stay continuous.
final class _FaceClock extends Animation<double>
    with
        AnimationEagerListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  _FaceClock(this.interval)
    : _step =
          interval.inMicroseconds / HermesBotFace.clockDuration.inMicroseconds;

  final Duration interval;
  final double _step;
  final Set<Object> _faces = <Object>{};
  Timer? _timer;
  double _value = 0;

  int get faces => _faces.length;
  bool get running => _timer != null;

  @override
  double get value => _value;

  @override
  AnimationStatus get status => AnimationStatus.forward;

  void join(Object face) {
    if (_faces.add(face)) sync();
  }

  void leave(Object face) {
    if (_faces.remove(face)) sync();
  }

  void sync() {
    if (_faces.isNotEmpty) _AppForeground.watch();
    if (_faces.isNotEmpty && _AppForeground.resumed) {
      _timer ??= Timer.periodic(interval, (_) {
        _value = (_value + _step) % 1.0;
        notifyListeners();
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }
}

abstract final class _FaceClocks {
  /// Idle faces: breath, blinks, glances (seeded per face, so a roster
  /// never moves in lockstep) at a few frames per second.
  static final idle = _FaceClock(LivingBotFace.idleFrameInterval);

  /// Busy faces (thinking, working, speaking, needs you): ~30 fps.
  static final busy = _FaceClock(LivingBotFace.motionFrameInterval);
}

/// Stops both clocks while the app is not resumed and restarts them on
/// return. Registered once, the first time a face rides a clock.
final class _AppForeground with WidgetsBindingObserver {
  _AppForeground._();

  static _AppForeground? _instance;

  static void watch() {
    if (_instance != null) return;
    WidgetsBinding.instance.addObserver(_instance = _AppForeground._());
  }

  static bool get resumed {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _FaceClocks.idle.sync();
    _FaceClocks.busy.sync();
  }
}

/// A living bot face: idle breath, blinks and glances; thinking
/// look-around, working scan (eyes read a line) with a soft pulsing ring,
/// attention nudge every few seconds, speaking while a reply streams, and
/// an entrance on first appearance.
///
/// Motion policy (#163 budget, QA 9495 "the faces must move"):
/// * a visible face in the foreground is ALIVE: idle faces breathe, blink
///   and look around on the shared idle clock (one [Timer] at
///   [LivingBotFace.idleFrameInterval] for every idle face on screen);
///   busy faces move on the shared busy clock (one [Timer] at
///   [LivingBotFace.motionFrameInterval] for every busy face). A screen
///   full of faces therefore runs at most two timers, never a vsync
///   ticker per face;
/// * a clock tick repaints the faces only (their painters listen to it);
///   it rebuilds nothing, except the small ring/hop frame of a busy face
///   whose mark moves;
/// * everything stops when the face is disposed (scrolled off a lazy
///   list), sits in a background route ([TickerMode]), the app is not
///   resumed, reduced motion is on ([MediaQuery.disableAnimationsOf]) or
///   [animate] is false; the face then paints a static frame that still
///   carries the state (the ring stays, no motion).
class LivingBotFace extends StatefulWidget {
  final String profileName;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;

  /// The connection the profile belongs to, when the face has no avatar
  /// cache to say it (a chat of another instance than the active one).
  final String? connectionId;
  final BotFaceSignal signal;
  final double size;
  final String? semanticLabel;

  /// Plays the scale/fade entrance the first time this face is built.
  final bool entrance;

  /// Motion amplitude. Defaults by size: large (pinned, profile hero)
  /// faces are the most expressive.
  final double? expressiveness;

  final LivingBotFaceStyle style;

  /// False paints a still face whatever the state (history rows, pickers).
  final bool animate;

  /// Draws the style's state mark (ring, orbit, calm dot). Hosts that mark
  /// the state themselves (a status dot of their own) turn it off; the
  /// face still MOVES with its state.
  final bool stateMark;

  const LivingBotFace({
    super.key,
    required this.profileName,
    required this.signal,
    this.profile,
    this.avatarCache,
    this.connectionId,
    this.size = 44,
    this.semanticLabel,
    this.entrance = true,
    this.expressiveness,
    this.style = LivingBotFaceStyle.classic,
    this.animate = true,
    this.stateMark = true,
  });

  /// Frame interval of continuous (busy) motion: ~30 fps, well under the
  /// display rate, so a working face costs a fraction of a vsync ticker.
  static const motionFrameInterval = Duration(milliseconds: 33);

  /// Frame interval of idle motion: 12.5 fps. Breath (2.8 s) and glances
  /// read smoothly at this rate and a blink (≥ 98 ms) always lands on at
  /// least one frame; a Bots home of a dozen idle faces stays a small,
  /// steady cost.
  static const idleFrameInterval = Duration(milliseconds: 80);

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
  static const _entranceMs = 420;
  static const _stopped = AlwaysStoppedAnimation<double>(0);

  /// One-shot entrance (scale/fade in); 1 when it does not play.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _entranceMs),
    value: 1,
  );

  /// The shared clock this face rides now; null while it is still.
  _FaceClock? _clock;

  /// Motion is allowed (visible route, no reduced motion, not a test still).
  bool _motion = false;
  bool _entered = false;

  /// Continuous state motion only while the bot is doing something.
  bool get _continuous => _motion && widget.signal != BotFaceSignal.idle;

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
        widget.animate &&
        !debugLivingBotFacesStill &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (_motion && !_entered) {
      _entered = true;
      if (widget.entrance) _entrance.forward(from: 0);
    } else if (!_motion && _entrance.isAnimating) {
      _entrance
        ..stop()
        ..value = 1;
    }
    _ride(
      !_motion
          ? null
          : _continuous
          ? _FaceClocks.busy
          : _FaceClocks.idle,
    );
  }

  void _ride(_FaceClock? clock) {
    if (identical(clock, _clock)) return;
    _clock?.leave(this);
    _clock = clock;
    clock?.join(this);
  }

  @override
  void dispose() {
    _ride(null);
    _entrance.dispose();
    super.dispose();
  }

  double get _nowMs =>
      (_clock?.value ?? 0) * HermesBotFace.clockDuration.inMilliseconds;

  bool get _busy =>
      widget.signal == BotFaceSignal.working ||
      widget.signal == BotFaceSignal.thinking ||
      widget.signal == BotFaceSignal.speaking;

  /// Whether the frame around the face (ring pulse, orbit dot, attention
  /// hop) changes with the clock. Only then does a tick rebuild that small
  /// frame; otherwise a tick only repaints the face.
  bool get _frameMoves {
    if (!_continuous) return false;
    if (widget.signal == BotFaceSignal.attention) return true;
    if (!widget.stateMark) return false;
    return switch (widget.style) {
      LivingBotFaceStyle.classic => widget.signal.hasRing,
      LivingBotFaceStyle.dots => _busy,
      LivingBotFaceStyle.calm => false,
    };
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
    final clock = _clock;
    final face = _Face(
      profileName: widget.profileName,
      profile: widget.profile,
      avatarCache: widget.avatarCache,
      connectionId: widget.connectionId,
      size: size,
      clock: clock ?? _stopped,
      motion: clock != null,
      signal: signal,
      gain: gain,
      matte: widget.style != LivingBotFaceStyle.classic,
    );
    final dots = widget.style != LivingBotFaceStyle.classic;
    final ringColor = signal == BotFaceSignal.attention
        ? colors.warning
        : colors.accent;
    final label = widget.semanticLabel;
    final body = AnimatedBuilder(
      animation: _frameMoves && clock != null
          ? Listenable.merge([_entrance, clock])
          : _entrance,
      child: face,
      builder: (context, child) {
        final ms = _nowMs;
        // Entrance: scale 0.6→1 and fade in over the first 420 ms.
        final entrance = Curves.easeOutBack.transform(_entrance.value);
        // Attention: every 3.2 s a gentle hop with a two-beat wiggle, so a
        // face that needs the user asks for it without shaking constantly.
        var dy = 0.0;
        var turn = 0.0;
        if (_continuous && signal == BotFaceSignal.attention) {
          final t = ((ms + _phaseMs) % 3200) / 3200;
          if (t < .28) {
            final k = t / .28;
            dy = -math.sin(k * math.pi) * size * .07;
            turn = math.sin(k * math.pi * 4) * .09 * (1 - k);
          }
        }
        if (dots) {
          return Opacity(
            opacity: entrance.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: .6 + .4 * entrance,
              child: _dotsFrame(colors, ms, child!, dy, turn),
            ),
          );
        }
        final pulse = _continuous && signal.hasRing
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
                  if (widget.stateMark && signal.hasRing)
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

extension on _LivingBotFaceState {
  /// Dots look: contact shadow, the face, then the state mark (orbit while
  /// busy, amber ring and dot while waiting, nothing when idle).
  Widget _dotsFrame(
    HermesThemeColors colors,
    double ms,
    Widget face,
    double dy,
    double turn,
  ) {
    final signal = widget.signal;
    final size = widget.size;
    final busy =
        signal == BotFaceSignal.working ||
        signal == BotFaceSignal.thinking ||
        signal == BotFaceSignal.speaking;
    final waiting = signal == BotFaceSignal.attention;
    final marked = widget.stateMark && (busy || waiting);
    // One lap every 2.6 s while the clock runs; a fixed top position in the
    // static frame (reduced motion, covered route, tests).
    final angle = _continuous
        ? ((ms + _phaseMs) % 2600) / 2600 * 2 * math.pi - math.pi / 2
        : -math.pi / 2;
    final dotSize = math.max(7.0, size * .13);
    final ring = size * .56;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // No contact shadow under any face (QA 9494, face_marks.dart): on
          // light pages and cards it read as a dark smudge around the face.
          Transform.translate(
            offset: Offset(0, dy),
            child: Transform.rotate(angle: turn, child: face),
          ),
          if (marked && widget.style == LivingBotFaceStyle.calm)
            _calmDot(colors, size, signal, waiting)
          else if (marked)
            Positioned.fill(
              // Same identity as the classic ring: "this face shows a state".
              key: ValueKey('living-face-ring-${signal.name}'),
              child: IgnorePointer(
                child: CustomPaint(
                  key: ValueKey(busy ? 'dots-face-orbit' : 'dots-face-ring'),
                  painter: _DotsRingPainter(
                    color: waiting ? colors.warning : colors.accent,
                    radius: ring,
                    width: size >= 56 ? 1.6 : 1.3,
                    // A waiting ring carries no travelling dot.
                    dotAngle: busy ? angle : null,
                    dotRadius: dotSize / 2,
                  ),
                ),
              ),
            ),
          if (widget.stateMark &&
              waiting &&
              widget.style == LivingBotFaceStyle.dots)
            Positioned(
              key: const ValueKey('dots-face-waiting-dot'),
              left: size / 2 + ring * math.cos(-math.pi / 4) - dotSize / 2,
              top: size / 2 + ring * math.sin(-math.pi / 4) - dotSize / 2,
              width: dotSize,
              height: dotSize,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.warning,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Diameter of the [LivingBotFaceStyle.calm] status dot for a face of
/// [size] dp: about a sixth of the face, 8–11 dp.
double calmStatusDotSize(double size) => (size * .17).clamp(8.0, 11.0);

/// The calm state mark: one small static dot at the face's lower right,
/// plain, with no ring (shared face rule in face_marks.dart: a ring in the
/// page colour read as a black halo on cards and sheets). Keyed like the
/// other styles' ring ("this face shows a state") so callers keep one
/// identity for it.
Widget _calmDot(
  HermesThemeColors colors,
  double size,
  BotFaceSignal signal,
  bool waiting,
) {
  final dot = calmStatusDotSize(size);
  return Positioned(
    key: ValueKey('living-face-ring-${signal.name}'),
    left: size * .84 - dot / 2,
    top: size * .84 - dot / 2,
    width: dot,
    height: dot,
    child: IgnorePointer(
      child: DecoratedBox(
        key: ValueKey('calm-face-dot-${signal.name}'),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (waiting ? colors.warning : colors.accent).withValues(
            alpha: .85,
          ),
        ),
      ),
    ),
  );
}

/// Thin ring around a Dots face, with an optional dot on it.
final class _DotsRingPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double width;
  final double? dotAngle;
  final double dotRadius;

  const _DotsRingPainter({
    required this.color,
    required this.radius,
    required this.width,
    required this.dotAngle,
    required this.dotRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color.withValues(alpha: .62),
    );
    final angle = dotAngle;
    if (angle == null) return;
    canvas.drawCircle(
      center + Offset(math.cos(angle), math.sin(angle)) * radius,
      dotRadius,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DotsRingPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.width != width ||
      old.dotAngle != dotAngle ||
      old.dotRadius != dotRadius;
}

/// Procedural Blobatar or raster avatar, both driven by the face's shared
/// clock (idle or busy); [motion] false paints the still frame.
class _Face extends StatelessWidget {
  final String profileName;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final String? connectionId;
  final double size;
  final Animation<double> clock;
  final bool motion;
  final BotFaceSignal signal;
  final double gain;
  final bool matte;

  const _Face({
    required this.profileName,
    required this.profile,
    required this.avatarCache,
    required this.connectionId,
    required this.size,
    required this.clock,
    required this.motion,
    required this.signal,
    required this.gain,
    this.matte = false,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ProfileIdentities.instance,
    builder: (context, _) => _buildIdentity(context),
  );

  Widget _buildIdentity(BuildContext context) {
    final profile = this.profile;
    final cache = avatarCache;
    final connection = cache?.connectionId ?? connectionId;
    ProfileIdentities.instance.requestAfterPaint(connection, profileName);
    final identity = profileIdentityFor(
      profileName: profileName,
      profile: profile,
      connectionId: connection,
    );
    if (identity.pet case final pet?) {
      return ProfilePetAvatar(pet: pet, size: size);
    }
    final raster =
        profile != null &&
        identity.kind == ProfileIdentityKind.image &&
        cache != null;
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
          colorHex: profile.botFaceColorHex,
          imageKind: profile.botImageKind,
        ),
      );
    }
    final visual =
        HermesBlobatarFaceVisual.tryParse(
          shapeWire: profile?.botFaceShape ?? 'blobatar',
          profileName: profileName,
          colorHex: profile?.botFaceColorHex,
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
      finish: matte ? HermesBotFaceFinish.matte : HermesBotFaceFinish.flat,
    );
  }
}
