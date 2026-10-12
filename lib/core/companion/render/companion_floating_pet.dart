import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../widgets/mascot/float/mascot_sources.dart';
import '../../widgets/mascot/mascot_identity.dart';
import '../../widgets/mascot/mascot_sprite.dart';
import '../../widgets/mascot/mascot_state.dart';
import '../models/companion.dart';
import '../models/companion_animation_state.dart';
import '../models/companion_mood.dart';
import '../models/companion_presence_level.dart';
import '../state/companion_controller.dart';
import 'companion_view.dart';
import 'spritesheet_renderer.dart';

/// The active profile's pet as the floating mascot: the companion the
/// Mascotas screen has selected (or the profile's own face when it has
/// none), shown outside chats while the presence is "En toda la app".
class CompanionFloatingPet implements MascotPet {
  CompanionFloatingPet(this.controller, {this.fallbackName = 'Hermes'});

  final CompanionController controller;
  final String fallbackName;

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  bool get shown =>
      controller.isInitialized &&
      controller.enabled &&
      controller.presence.showsEverywhere;

  @override
  String get name {
    final pet = controller.activeCompanion?.name.trim();
    if (pet != null && pet.isNotEmpty) return pet;
    final profile = controller.scope?.profileId.trim() ?? '';
    return profile.isEmpty || profile == 'default' ? fallbackName : profile;
  }

  @override
  double get scale => controller.sizeMultiplier;

  @override
  Widget build(
    BuildContext context, {
    required MascotState state,
    required double size,
    required bool asleep,
    required int look,
    bool airborne = false,
  }) => CompanionFloatingBody(
    controller: controller,
    state: state,
    size: size,
    asleep: asleep,
    look: look,
    airborne: airborne,
  );

  /// "Ocultar": it stays on the chat's island only.
  @override
  Future<void> hide() =>
      controller.setVisibilityLevel(CompanionPresenceLevel.chat);
}

/// A movement of the whole sprite that stands in for a drawing the pet
/// does not have.
enum PetReaction {
  none,

  /// Thinking: a slow sway.
  sway,

  /// Working: a steady bob.
  bob,

  /// Needs you: a hop every couple of seconds.
  hops,

  /// Done, or a look around: one hop.
  hop,

  /// Something failed: one short shake.
  shake,
}

/// What a pet shows for a mascot state with the drawings it really has.
@immutable
final class PetPlan {
  const PetPlan({
    required this.row,
    this.loop,
    this.still = false,
    this.reaction = PetReaction.none,
    this.dim = false,
  });

  /// Which of its animations it plays.
  final CompanionAnimationState row;

  /// Forces a loop or a single run; null leaves it as the pet declares it.
  final bool? loop;

  /// Its resting drawing, one frame, with no clock.
  final bool still;
  final PetReaction reaction;

  /// Away: drawn faded.
  final bool dim;

  @override
  bool operator ==(Object other) =>
      other is PetPlan &&
      other.row == row &&
      other.loop == loop &&
      other.still == still &&
      other.reaction == reaction &&
      other.dim == dim;

  @override
  int get hashCode => Object.hash(row, loop, still, reaction, dim);
}

/// The plan for [state]. A Petdex sheet may carry idle, run, review,
/// waiting, wave, jump and failed; only idle is guaranteed. Each state uses
/// its own drawing when the pet has it, the closest one otherwise, and for a
/// pet with only its idle sheet a movement of the whole sprite:
///
/// | state     | drawing              | without it                     |
/// |-----------|----------------------|--------------------------------|
/// | idle      | idle loop            | –                              |
/// | a look    | review, once         | idle + one hop                 |
/// | thinking  | review, looped       | idle + sway                    |
/// | working   | run, looped          | idle + bob                     |
/// | needs you | waiting, looped      | jump looped, or idle + hops    |
/// | done      | wave, once           | jump once, or idle + one hop   |
/// | error     | failed, once         | idle + one shake               |
/// | offline   | idle, still, faded   | the same                       |
/// | asleep    | idle, still          | the same                       |
/// | in the air| jump, looped         | idle (the fall moves it)       |
PetPlan petPlanFor(
  Companion pet,
  MascotState state, {
  bool asleep = false,
  bool looking = false,
  bool airborne = false,
}) {
  bool has(CompanionAnimationState s) => pet.states.containsKey(s);
  const idle = CompanionAnimationState.idle;
  if (state == MascotState.offline) {
    return const PetPlan(row: idle, still: true, dim: true);
  }
  if (asleep) return const PetPlan(row: idle, still: true);
  if (airborne) {
    // Falling to the dock, as Desktop's pet shows its jump while it drops.
    return has(CompanionAnimationState.jump)
        ? const PetPlan(row: CompanionAnimationState.jump, loop: true)
        : const PetPlan(row: idle);
  }
  switch (state) {
    case MascotState.idle:
      if (!looking) return const PetPlan(row: idle);
      return has(CompanionAnimationState.review)
          ? const PetPlan(row: CompanionAnimationState.review, loop: false)
          : const PetPlan(row: idle, reaction: PetReaction.hop);
    case MascotState.thinking:
      return has(CompanionAnimationState.review)
          ? const PetPlan(row: CompanionAnimationState.review, loop: true)
          : const PetPlan(row: idle, reaction: PetReaction.sway);
    case MascotState.tool:
      return has(CompanionAnimationState.run)
          ? const PetPlan(row: CompanionAnimationState.run, loop: true)
          : const PetPlan(row: idle, reaction: PetReaction.bob);
    case MascotState.needsYou:
      if (has(CompanionAnimationState.waiting)) {
        return const PetPlan(row: CompanionAnimationState.waiting, loop: true);
      }
      return has(CompanionAnimationState.jump)
          ? const PetPlan(row: CompanionAnimationState.jump, loop: true)
          : const PetPlan(row: idle, reaction: PetReaction.hops);
    case MascotState.done:
      if (has(CompanionAnimationState.wave)) {
        return const PetPlan(row: CompanionAnimationState.wave, loop: false);
      }
      return has(CompanionAnimationState.jump)
          ? const PetPlan(row: CompanionAnimationState.jump, loop: false)
          : const PetPlan(row: idle, reaction: PetReaction.hop);
    case MascotState.error:
      return has(CompanionAnimationState.failed)
          ? const PetPlan(row: CompanionAnimationState.failed, loop: false)
          : const PetPlan(row: idle, reaction: PetReaction.shake);
    case MascotState.offline:
      return const PetPlan(row: idle, still: true, dim: true);
  }
}

/// How much of a pet's cell is empty under its feet. A Petdex cell leaves
/// air around the drawing, and how much is each pet's own: without this a
/// pet "on the dock" hovers a few pixels above it.
///
/// Measured once per sheet, from the first frame of its resting drawing, on
/// a small decode that is dropped afterwards.
abstract final class PetFootline {
  static final Map<String, double> _known = <String, double>{};
  static final Map<String, Future<double>> _measuring =
      <String, Future<double>>{};

  /// Nothing above this fraction of the cell is taken for air: a sheet whose
  /// first frame is empty does not sink the pet out of its box.
  static const double maxGap = 0.4;

  static String _keyOf(Companion pet) =>
      '${pet.origin.name}:${pet.spritesheetAsset}:${pet.cols}x${pet.rows}';

  /// The fraction of the cell's height under the feet; null until measured.
  static double? of(Companion pet) => _known[_keyOf(pet)];

  static Future<double> measure(Companion pet, {ImageProvider? source}) {
    final key = _keyOf(pet);
    return _measuring[key] ??= _measure(pet, source).then((gap) {
      _known[key] = gap;
      return gap;
    });
  }

  static Future<double> _measure(Companion pet, ImageProvider? source) async {
    final row = pet.states[CompanionAnimationState.idle];
    if (row == null || pet.cols <= 0 || pet.rows <= 0) return 0;
    final provider = ResizeImage(
      source ??
          (pet.isFileBacked
              ? FileImage(File(pet.spritesheetAsset))
              : AssetImage(pet.spritesheetAsset) as ImageProvider),
      width: pet.cols * 64,
    );
    final done = Completer<ImageInfo?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) done.complete(info);
      },
      onError: (_, _) {
        if (!done.isCompleted) done.complete(null);
      },
    );
    stream.addListener(listener);
    final info = await done.future;
    stream.removeListener(listener);
    if (info == null) return 0;
    try {
      final image = info.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return 0;
      final cellWidth = image.width ~/ pet.cols;
      final cellHeight = image.height ~/ pet.rows;
      if (cellWidth <= 0 || cellHeight <= 0) return 0;
      final top = row.row * cellHeight;
      for (var y = top + cellHeight - 1; y >= top; y--) {
        for (var x = 0; x < cellWidth; x++) {
          // Alpha of the pixel: anything you can see is the pet.
          if (data.getUint8((y * image.width + x) * 4 + 3) > 24) {
            final gap = (top + cellHeight - 1 - y) / cellHeight;
            return gap > maxGap ? 0 : gap;
          }
        }
      }
      return 0;
    } catch (_) {
      return 0;
    } finally {
      info.dispose();
      unawaited(provider.evict());
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _known.clear();
    _measuring.clear();
  }
}

/// The mood the profile's own face shows for a mascot state.
CompanionMood petMoodFor(MascotState state) => switch (state) {
  MascotState.idle => CompanionMood.idle,
  MascotState.thinking || MascotState.tool => CompanionMood.thinking,
  MascotState.needsYou => CompanionMood.waiting,
  MascotState.done => CompanionMood.success,
  MascotState.error => CompanionMood.error,
  MascotState.offline => CompanionMood.offline,
};

/// The pet in a [size] box, standing on its bottom edge. It rebuilds with
/// the controller (another pet, another speed).
class CompanionFloatingBody extends StatefulWidget {
  const CompanionFloatingBody({
    required this.controller,
    required this.state,
    required this.size,
    required this.asleep,
    required this.look,
    this.airborne = false,
    super.key,
  });

  final CompanionController controller;
  final MascotState state;
  final double size;
  final bool asleep;
  final int look;

  /// Falling (or springing up) to its place on the dock.
  final bool airborne;

  @override
  State<CompanionFloatingBody> createState() => _CompanionFloatingBodyState();
}

class _CompanionFloatingBodyState extends State<CompanionFloatingBody> {
  /// How long a look around lasts when the pet has no drawing for it.
  static const Duration _lookFor = Duration(milliseconds: 1400);

  Timer? _lookTimer;
  bool _looking = false;
  int _replay = 0;

  /// How far [pet]'s drawing is moved down for its feet to stand on the
  /// box's bottom edge. Zero until its sheet has been measured.
  double _sink(Companion pet, double size) {
    final gap = PetFootline.of(pet);
    if (gap == null) {
      unawaited(
        PetFootline.measure(pet).then((_) {
          if (mounted) setState(() {});
        }),
      );
      return 0;
    }
    // The cell is fitted whole into the box, centred.
    final scale = math.min(size / pet.frameWidth, size / pet.frameHeight);
    final drawn = pet.frameHeight * scale;
    return (size - drawn) / 2 + gap * drawn;
  }

  @override
  void didUpdateWidget(covariant CompanionFloatingBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resting = widget.state == MascotState.idle && !widget.asleep;
    if (!resting) {
      _endLook();
    } else if (widget.look != oldWidget.look) {
      _startLook();
    }
    if (widget.state != oldWidget.state) _replay++;
  }

  void _startLook() {
    final pet = widget.controller.activeCompanion;
    final row = pet?.states[CompanionAnimationState.review];
    final fps = (pet?.fps ?? 8) * widget.controller.animationSpeed;
    final lasts = row == null || fps <= 0
        ? _lookFor
        : Duration(milliseconds: (row.frameCount / fps * 1000).round() + 200);
    _lookTimer?.cancel();
    _looking = true;
    _replay++;
    _lookTimer = Timer(lasts, () {
      _lookTimer = null;
      if (mounted) setState(() => _looking = false);
    });
  }

  void _endLook() {
    _lookTimer?.cancel();
    _lookTimer = null;
    _looking = false;
  }

  @override
  void dispose() {
    _lookTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final size = widget.size;
        final pet = controller.activeCompanion;
        if (pet == null) {
          final profile = controller.scope?.profileId.trim() ?? '';
          if (profile.isEmpty || profile == 'default') {
            // No pet and no profile of its own: Hermes' sprite, the one
            // that stands on this chat's island.
            return MascotSprite(
              key: const ValueKey('floating-pet-hermes'),
              state: widget.state,
              still: widget.asleep,
              identity: MascotIdentity.hermes,
              size: size,
              excludeSemantics: true,
            );
          }
          // A profile without a pet: its own face, as in its chats.
          return SizedBox.square(
            key: const ValueKey('floating-pet-face'),
            dimension: size,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Opacity(
                opacity: widget.state == MascotState.offline ? 0.5 : 1,
                child: CompanionProfileFace(
                  controller: controller,
                  mood: petMoodFor(widget.state),
                  size: size * 0.8,
                  animate: !widget.asleep,
                ),
              ),
            ),
          );
        }
        final plan = petPlanFor(
          pet,
          widget.state,
          asleep: widget.asleep,
          looking: _looking,
          airborne: widget.airborne,
        );
        final row = pet.rowFor(plan.row);
        final loop = plan.loop;
        Widget sprite = SpritesheetRenderer(
          key: const ValueKey('floating-pet-sprite'),
          companion: pet,
          state: plan.row,
          overrideRow: row == null || loop == null || row.loop == loop
              ? null
              : row.copyWith(loop: loop),
          size: size,
          replayToken: _replay,
          animate: !plan.still,
          speedMultiplier: controller.animationSpeed,
        );
        if (plan.dim) sprite = Opacity(opacity: 0.5, child: sprite);
        sprite = Transform.translate(
          key: const ValueKey('floating-pet-feet'),
          offset: Offset(0, _sink(pet, size)),
          child: sprite,
        );
        return PetReactionMotion(
          reaction: plan.reaction,
          replay: _replay,
          extent: size,
          child: sprite,
        );
      },
    );
  }
}

/// Moves [child] as a whole for a [PetReaction]. One low-rate timer while a
/// reaction runs, none otherwise; it stops with the route, in the
/// background and with reduced motion.
class PetReactionMotion extends StatefulWidget {
  const PetReactionMotion({
    required this.reaction,
    required this.extent,
    required this.child,
    this.replay = 0,
    super.key,
  });

  final PetReaction reaction;
  final double extent;
  final int replay;
  final Widget child;

  /// 15 frames a second.
  static const Duration frame = Duration(milliseconds: 66);

  @override
  State<PetReactionMotion> createState() => _PetReactionMotionState();
}

class _PetReactionMotionState extends State<PetReactionMotion>
    with WidgetsBindingObserver {
  final ValueNotifier<double> _t = ValueNotifier<double>(0); // seconds
  Timer? _timer;
  bool _enabled = true;

  bool get _loops => switch (widget.reaction) {
    PetReaction.sway || PetReaction.bob || PetReaction.hops => true,
    PetReaction.none || PetReaction.hop || PetReaction.shake => false,
  };

  double get _length => switch (widget.reaction) {
    PetReaction.hop => 0.45,
    PetReaction.shake => 0.5,
    _ => double.infinity,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync(restart: false);
  }

  @override
  void didUpdateWidget(covariant PetReactionMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(
      restart:
          oldWidget.reaction != widget.reaction ||
          oldWidget.replay != widget.replay,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _sync(restart: false);

  void _sync({required bool restart}) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _enabled =
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        TickerMode.valuesOf(context).enabled &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (restart) _t.value = 0;
    final run =
        _enabled &&
        widget.reaction != PetReaction.none &&
        (_loops || _t.value < _length);
    if (!run) {
      _timer?.cancel();
      _timer = null;
      // At rest it stands straight: a loop that may not run goes back to
      // its start, a single movement to its end.
      _t.value = _loops || widget.reaction == PetReaction.none ? 0 : _length;
      return;
    }
    _timer ??= Timer.periodic(PetReactionMotion.frame, (_) {
      final next = _t.value + PetReactionMotion.frame.inMicroseconds / 1e6;
      if (!_loops && next >= _length) {
        _timer?.cancel();
        _timer = null;
        _t.value = _length;
        return;
      }
      _t.value = next;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _t.dispose();
    super.dispose();
  }

  Matrix4 _matrix(double t) {
    final lift = widget.extent * 0.14;
    switch (widget.reaction) {
      case PetReaction.none:
        return Matrix4.identity();
      case PetReaction.sway:
        return Matrix4.rotationZ(math.sin(t * 2.4) * 0.07);
      case PetReaction.bob:
        return Matrix4.translationValues(
          0,
          -(1 - math.cos(t * 9)) / 2 * lift * 0.45,
          0,
        );
      case PetReaction.hops:
        final phase = t % 2.2;
        return Matrix4.translationValues(
          0,
          phase < 0.45 ? -math.sin(phase / 0.45 * math.pi) * lift : 0,
          0,
        );
      case PetReaction.hop:
        final k = (t / _length).clamp(0.0, 1.0);
        return Matrix4.translationValues(0, -math.sin(k * math.pi) * lift, 0);
      case PetReaction.shake:
        final k = (t / _length).clamp(0.0, 1.0);
        return Matrix4.translationValues(
          math.sin(k * math.pi * 6) * (1 - k) * widget.extent * 0.07,
          0,
          0,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Always the same wrapper, so the sprite under it is never remounted
    // when a reaction starts or ends.
    return ValueListenableBuilder<double>(
      valueListenable: _t,
      builder: (context, t, child) => Transform(
        key: const ValueKey('floating-pet-reaction'),
        alignment: Alignment.bottomCenter,
        transform: _matrix(t),
        child: child,
      ),
      child: widget.child,
    );
  }
}
