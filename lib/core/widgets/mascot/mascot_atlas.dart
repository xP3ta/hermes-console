import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mascot_identity.dart';
import 'mascot_state.dart';

/// Geometry of the mascot atlases built by `tool/mascot/build_atlas.py`:
/// 8 columns x 4 rows of [cellWidth] x [cellHeight] px, white bodies with
/// dark eyes (tinted at paint time).
abstract final class MascotAtlas {
  static const int columns = 8;
  static const int rows = 4;
  static const double cellWidth = 140;
  static const double cellHeight = 134;

  /// Source rectangle of every cell, built once: painting never allocates
  /// a rect for the source.
  static final List<ui.Rect> cellRects = List<ui.Rect>.unmodifiable(
    List<ui.Rect>.generate(columns * rows, (index) {
      final left = (index % columns) * cellWidth;
      final top = (index ~/ columns) * cellHeight;
      return ui.Rect.fromLTWH(left, top, cellWidth, cellHeight);
    }),
  );

  static final Map<MascotSpriteKind, Future<ui.Image>> _loading =
      <MascotSpriteKind, Future<ui.Image>>{};
  static final Map<MascotSpriteKind, ui.Image> _ready =
      <MascotSpriteKind, ui.Image>{};

  /// The decoded atlas of [kind], or null until [load] finished.
  static ui.Image? cached(MascotSpriteKind kind) => _ready[kind];

  /// Decodes the atlas of [kind] once per process and keeps it: every
  /// mascot of that sprite shares one GPU image.
  static Future<ui.Image> load(MascotSpriteKind kind, {AssetBundle? bundle}) {
    final ready = _ready[kind];
    if (ready != null) return SynchronousFuture<ui.Image>(ready);
    return _loading[kind] ??= () async {
      try {
        final data = await (bundle ?? rootBundle).load(kind.asset);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        final frame = await codec.getNextFrame();
        codec.dispose();
        return _ready[kind] = frame.image;
      } catch (_) {
        _loading.remove(kind);
        rethrow;
      }
    }();
  }

  /// Test hook: installs [image] as the decoded atlas of [kind] (null
  /// forgets it).
  @visibleForTesting
  static void debugSetImage(MascotSpriteKind kind, ui.Image? image) {
    _loading.remove(kind);
    if (image == null) {
      _ready.remove(kind);
    } else {
      _ready[kind] = image;
    }
  }
}

/// Cells of the atlas, by meaning.
abstract final class MascotCell {
  static const int bob = 0; // 0..7: idle bob
  static const int sway = 8; // 8..15: working sway
  static const int wave = 16; // 16..23: wave
  static const int eyesOpen = 24;
  static const int eyesClosed = 25;
  static const int errorA = 26;
  static const int errorB = 27;
}

/// One frame of an animation: a cell held for [hold].
@immutable
final class MascotStep {
  const MascotStep(this.cell, this.hold);

  final int cell;
  final Duration hold;
}

/// The animation of one [MascotState]. Frame times follow the owner's
/// sprite guide (idle/thinking/waiting 170 ms, work 110 ms, wave 140 ms), so
/// every state stays far below its cap: idle ≤ 6 fps, active ≤ 30 fps.
@immutable
final class MascotProgram {
  const MascotProgram(this.steps, {required this.loop});

  final List<MascotStep> steps;

  /// One-shot programs hold their last cell (error) or hand over to idle
  /// (the done wave).
  final bool loop;

  static const Duration idleFrame = Duration(milliseconds: 170);
  static const Duration workFrame = Duration(milliseconds: 110);
  static const Duration waveFrame = Duration(milliseconds: 140);

  /// Shortest rest between two idle blinks; the real pause is seeded per
  /// mascot (4.2-8 s) so a room never blinks in lockstep.
  static const Duration minIdleRest = Duration(milliseconds: 4200);

  /// Crossfade between two states: [fadeSteps] repaints, one every
  /// [fadeFrame] (~30 fps, 200 ms).
  static const Duration fadeFrame = Duration(milliseconds: 33);
  static const int fadeSteps = 6;

  static Duration idleRest(int seed, int blinks) => Duration(
    milliseconds:
        minIdleRest.inMilliseconds + (seed * 7 + blinks * 1931) % 3800,
  );

  static List<MascotStep> _row(int first, Duration hold) =>
      List<MascotStep>.generate(8, (i) => MascotStep(first + i, hold));

  static final MascotProgram thinking = MascotProgram(
    _row(MascotCell.bob, idleFrame),
    loop: true,
  );
  static final MascotProgram tool = MascotProgram(
    _row(MascotCell.sway, workFrame),
    loop: true,
  );
  static final MascotProgram needsYou = MascotProgram(<MascotStep>[
    ..._row(MascotCell.bob, workFrame),
    const MascotStep(MascotCell.eyesOpen, Duration(milliseconds: 600)),
    const MascotStep(MascotCell.eyesClosed, idleFrame),
  ], loop: true);
  static final MascotProgram done = MascotProgram(
    _row(MascotCell.wave, waveFrame),
    loop: false,
  );
  static const MascotProgram error = MascotProgram(<MascotStep>[
    MascotStep(MascotCell.errorA, waveFrame),
    MascotStep(MascotCell.errorB, Duration.zero),
  ], loop: false);
  static const MascotProgram offline = MascotProgram(<MascotStep>[
    MascotStep(MascotCell.bob, Duration.zero),
  ], loop: false);

  /// Idle: rest with open eyes, then one blink. The rest is the only long
  /// hold of the whole engine; an idle mascot repaints twice per blink.
  static MascotProgram idle(int seed, int blinks) => MascotProgram(<MascotStep>[
    MascotStep(MascotCell.bob, idleRest(seed, blinks)),
    const MascotStep(MascotCell.eyesClosed, idleFrame),
  ], loop: true);

  static MascotProgram of(MascotState state, {int seed = 0, int blinks = 0}) =>
      switch (state) {
        MascotState.idle => idle(seed, blinks),
        MascotState.thinking => thinking,
        MascotState.tool => tool,
        MascotState.needsYou => needsYou,
        MascotState.done => done,
        MascotState.offline => offline,
        MascotState.error => error,
      };

  /// The still pose of [state] (reduced motion, or a static test frame).
  static int staticCell(MascotState state) => switch (state) {
    MascotState.idle || MascotState.thinking => MascotCell.bob,
    MascotState.offline => MascotCell.bob,
    MascotState.tool => MascotCell.sway,
    MascotState.needsYou => MascotCell.eyesOpen,
    MascotState.done => MascotCell.wave + 3,
    MascotState.error => MascotCell.errorB,
  };
}
