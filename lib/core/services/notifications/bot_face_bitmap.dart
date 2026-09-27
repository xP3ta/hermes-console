import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import '../../widgets/bot_face_identity.dart';
import '../../widgets/hermes_bot_face.dart';

/// Visual state baked into a rasterised face (spec 070 § Notifications and
/// § Widgets). Android cannot animate notification or widget contents, so
/// every state gets its own static expression plus a small badge:
///
/// - idle: eyes open, no badge;
/// - working: eyes aside (reading) + blue typing pill (three dots);
/// - done: content look up + green dot;
/// - needsYou: looking at you + amber dot;
/// - failed: closed / crossed eyes + red dot.
///
/// The badge sits on the face's top-left with a black ring, like the Grok
/// Bot reference; the face itself comes from [BotFaceIdentity].
enum BotFaceBitmapState { idle, working, done, needsYou, failed }

/// State palette shared by widgets and notifications (dark surfaces).
abstract final class BotStateColors {
  static const working = Color(0xFF2F7CF6);
  static const done = Color(0xFF32D74B);
  static const needsYou = Color(0xFFF5A623);
  static const failed = Color(0xFFEF4D4D);
  static const idle = Color(0xFF8A8580);

  static Color of(BotFaceBitmapState state) => switch (state) {
    BotFaceBitmapState.idle => idle,
    BotFaceBitmapState.working => working,
    BotFaceBitmapState.done => done,
    BotFaceBitmapState.needsYou => needsYou,
    BotFaceBitmapState.failed => failed,
  };
}

/// Static expression per state and frame. Frames rotate on each widget
/// update (widgets cannot animate), so a working face looks left, down and
/// right across consecutive redraws.
HermesBotFaceMotionSnapshot botFacePose(BotFaceBitmapState state, int frame) {
  final f = frame % botFaceFrameCount(state);
  const base = HermesBotFaceMotionSnapshot.staticFrame;
  HermesBotFaceMotionSnapshot pose({
    double x = 0,
    double y = 0,
    double sx = 1,
    double sy = 1,
    double tilt = 0,
    HermesBotFaceEyeGlyph glyph = HermesBotFaceEyeGlyph.open,
    double brows = 0,
  }) => HermesBotFaceMotionSnapshot(
    breatheScaleX: base.breatheScaleX,
    breatheScaleY: base.breatheScaleY,
    bobY: 0,
    blinkScaleY: 1,
    eyeOffsetX: x,
    eyeOffsetY: y,
    eyeScaleX: sx,
    eyeScaleY: sy,
    headTiltRadians: tilt,
    eyeGlyph: glyph,
    brows: brows,
  );
  return switch (state) {
    BotFaceBitmapState.idle => switch (f) {
      0 => pose(y: -.2),
      1 => pose(x: -1.6, y: -.2, tilt: -.01),
      _ => pose(x: 1.6, y: .2, tilt: .01),
    },
    BotFaceBitmapState.working => switch (f) {
      0 => pose(x: 2.4, y: 1.1, sx: 1.04, sy: .9, tilt: .02),
      1 => pose(x: -2.4, y: 1.1, sx: 1.04, sy: .9, tilt: -.02),
      _ => pose(x: 0, y: 1.8, sx: 1.04, sy: .82),
    },
    BotFaceBitmapState.done => switch (f) {
      0 => pose(y: -2.2, glyph: HermesBotFaceEyeGlyph.happy, tilt: .03),
      _ => pose(x: 1.2, y: -2.6, sy: 1.04, tilt: -.02),
    },
    BotFaceBitmapState.needsYou => switch (f) {
      0 => pose(y: -1, sx: 1.12, sy: 1.12, brows: 1),
      _ => pose(x: -1.2, y: -1.2, sx: 1.12, sy: 1.12, brows: 1),
    },
    BotFaceBitmapState.failed => pose(
      y: .6,
      glyph: HermesBotFaceEyeGlyph.cross,
      brows: -1,
      tilt: -.04,
    ),
  };
}

int botFaceFrameCount(BotFaceBitmapState state) => switch (state) {
  BotFaceBitmapState.idle => 3,
  BotFaceBitmapState.working => 3,
  BotFaceBitmapState.done => 2,
  BotFaceBitmapState.needsYou => 2,
  BotFaceBitmapState.failed => 1,
};

/// Grok-style sphere eye pose in the 100×100 face box: two identical
/// capsule eyes (width [w], height [h], centre spacing [sp]) around
/// ([cx], [cy]), rotated [rot] degrees. Off-centre on purpose: the gaze is
/// the expression.
typedef SphereEyePose = ({
  double cx,
  double cy,
  double rot,
  double sp,
  double w,
  double h,
});

/// Sphere expression per state and frame (frames rotate on each widget
/// update: the only "animation" a widget gets).
SphereEyePose sphereEyePose(BotFaceBitmapState state, int frame) {
  final f = frame % botFaceFrameCount(state);
  SphereEyePose p(
    double cx,
    double cy, {
    double rot = 0,
    double sp = 15,
    double w = 8,
    double h = 18,
  }) => (cx: cx, cy: cy, rot: rot, sp: sp, w: w, h: h);
  return switch (state) {
    BotFaceBitmapState.idle => switch (f) {
      0 => p(56, 40, rot: -10),
      1 => p(44, 40, rot: 10),
      _ => p(52, 36),
    },
    BotFaceBitmapState.working => switch (f) {
      0 => p(40, 44),
      1 => p(60, 44),
      _ => p(50, 48, h: 16),
    },
    BotFaceBitmapState.done => switch (f) {
      0 => p(62, 28, rot: -28, sp: 17, w: 10, h: 13),
      _ => p(38, 28, rot: 28, sp: 17, w: 10, h: 13),
    },
    BotFaceBitmapState.needsYou => switch (f) {
      0 => p(50, 40, sp: 16, h: 19),
      _ => p(50, 38, sp: 16, w: 8.5, h: 20),
    },
    BotFaceBitmapState.failed => p(50, 52, sp: 17, w: 10, h: 5),
  };
}

/// Paints the Grok-style sphere (no plate, no badge) into a 100×100 box
/// already scaled onto [canvas]: circle r=42 with a vertical gradient
/// (light top → base → darker bottom), two black capsule eyes. No mouth,
/// cheeks, brows, outline or specular highlight.
void paintBotSphere(
  Canvas canvas,
  String palette,
  SphereEyePose pose, {
  double blink = 1,
}) {
  final colors =
      BotSpherePalette.colors[palette] ?? BotSpherePalette.colors['grey']!;
  const rect = Rect.fromLTWH(8, 8, 84, 84);
  canvas.drawCircle(
    const Offset(50, 50),
    42,
    Paint()
      ..shader = ui.Gradient.linear(
        rect.topCenter,
        rect.bottomCenter,
        [colors.$1, colors.$2, colors.$3],
        const [0, .55, 1],
      ),
  );
  final eye = Paint()..color = const Color(0xFF101114);
  final h = math.max(pose.h * blink, 3.0);
  canvas.save();
  canvas.translate(pose.cx, pose.cy);
  canvas.rotate(pose.rot * math.pi / 180);
  for (final dx in [-pose.sp / 2, pose.sp / 2]) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(dx, 0), width: pose.w, height: h),
        Radius.circular(math.min(pose.w, h) / 2),
      ),
      eye,
    );
  }
  canvas.restore();
}

/// Renders Bot faces to small PNG files in app storage.
///
/// Files are content-addressed (profile + identity + state + frame + size),
/// so the same face is rendered once and every notification/widget refers
/// to it by path. Rendering is pure Dart (`PictureRecorder`), so it also
/// works in the background listener isolate, which has no widget tree.
class BotFaceBitmapCache {
  BotFaceBitmapCache({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;
  final Map<String, Future<String?>> _inFlight = {};

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/bot_faces');
  }

  /// Renderer revision: bump to invalidate every cached PNG.
  static const revision = 5;

  static String fileKey({
    required String profile,
    required String? identityKey,
    required BotFaceBitmapState state,
    required int size,
    int frame = 0,
    bool plate = false,
    String? imageDigest,
  }) {
    final digest = sha256
        .convert(
          utf8.encode(
            'r$revision\u0000$profile\u0000${identityKey ?? ''}\u0000$size'
            '\u0000${plate ? 1 : 0}\u0000${imageDigest ?? ''}',
          ),
        )
        .toString()
        .substring(0, 20);
    final f = frame % botFaceFrameCount(state);
    return 'face_${digest}_${state.name}_$f.png';
  }

  /// Path of the PNG for [profile]; `null` when rendering is unavailable.
  ///
  /// [identity] comes from [BotFaceIdentity.resolve] (defaults to the
  /// unconfigured sphere). [plate] draws a dark circular plate behind the
  /// face (notification Person icons, which the system crops to a circle).
  /// Widgets use the transparent face so the state glow shows through.
  /// [image] is the configured raster avatar of an [BotFaceSource.avatar]
  /// identity: it is cropped to a circle and gets the state badge.
  Future<String?> pathFor({
    required String profile,
    BotFaceIdentity? identity,
    BotFaceBitmapState state = BotFaceBitmapState.idle,
    int size = 128,
    int frame = 0,
    bool plate = true,
    Uint8List? image,
  }) {
    final id = identity ?? BotFaceIdentity.resolve(profile: profile);
    final photo = id.source == BotFaceSource.avatar ? image : null;
    final imageDigest = photo == null
        ? null
        : sha256.convert(photo).toString().substring(0, 16);
    final key = fileKey(
      profile: profile,
      identityKey: id.cacheKey,
      state: state,
      size: size,
      frame: frame,
      plate: plate,
      imageDigest: imageDigest,
    );
    return _inFlight[key] ??= _render(key, id, state, size, frame, plate, photo)
        .timeout(const Duration(seconds: 3), onTimeout: () => null)
        .catchError((Object _) => null)
        .whenComplete(() {
          // Block body: returning the removed Future would make
          // whenComplete await itself and never complete.
          _inFlight.remove(key);
        });
  }

  Future<String?> _render(
    String key,
    BotFaceIdentity identity,
    BotFaceBitmapState state,
    int size,
    int frame,
    bool plate,
    Uint8List? image,
  ) async {
    final dir = await _directory();
    final file = File('${dir.path}/$key');
    if (await file.exists() && await file.length() > 0) return file.path;
    List<int>? bytes;
    if (image != null) {
      bytes = await renderAvatarPng(
        image,
        state: state,
        size: size,
        plate: plate,
      );
    }
    bytes ??= await renderIdentityPng(
      identity,
      state: state,
      size: size,
      frame: frame,
      plate: plate,
    );
    if (bytes == null) return null;
    await _write(dir, file, bytes);
    return file.path;
  }

  static Future<void> _write(Directory dir, File file, List<int> bytes) async {
    await dir.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  /// Face of [identity] without an image: the configured procedural face,
  /// else the sphere. An avatar identity whose image is unavailable falls
  /// back to its procedural shape (when configured) or the sphere.
  static Future<List<int>?> renderIdentityPng(
    BotFaceIdentity identity, {
    BotFaceBitmapState state = BotFaceBitmapState.idle,
    int size = 128,
    int frame = 0,
    bool plate = true,
  }) {
    final procedural =
        identity.source == BotFaceSource.procedural ||
        (identity.source == BotFaceSource.avatar && identity.shapeWire != null);
    return procedural
        ? renderPng(
            identity.visual,
            state: state,
            size: size,
            frame: frame,
            plate: plate,
          )
        : renderSpherePng(
            identity.sphere,
            state: state,
            size: size,
            frame: frame,
            plate: plate,
          );
  }

  /// Room conversation avatar (same as the app roster): a dark rounded
  /// square with up to four member faces in a non-overlapping 2x2 grid and
  /// "+n" in the last cell. Used as the room's shortcut / Person icon.
  Future<String?> roomTilePath({
    required String roomKey,
    required List<BotFaceIdentity> members,
    int size = 128,
  }) {
    final shown = members.take(4).toList();
    final digest = sha256
        .convert(
          utf8.encode(
            'tile\u0000r$revision\u0000$roomKey\u0000$size\u0000'
            '${members.length}\u0000'
            '${shown.map((m) => '${m.profile}:${m.cacheKey}').join(',')}',
          ),
        )
        .toString()
        .substring(0, 20);
    final key = 'tile_$digest.png';
    return _inFlight[key] ??=
        () async {
              final dir = await _directory();
              final file = File('${dir.path}/$key');
              if (await file.exists() && await file.length() > 0) {
                return file.path;
              }
              final bytes = await renderRoomTilePng(members, size: size);
              if (bytes == null) return null;
              await _write(dir, file, bytes);
              return file.path;
            }()
            .timeout(const Duration(seconds: 3), onTimeout: () => null)
            .catchError((Object _) => null)
            .whenComplete(() {
              _inFlight.remove(key);
            });
  }

  static Future<List<int>?> renderRoomTilePng(
    List<BotFaceIdentity?> members, {
    int size = 128,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final s = size.toDouble();
    // The shade crops conversation avatars to a circle and draws them on a
    // near-black card: a visible slate disc (lighter top) makes the room one
    // object instead of loose faces, and every face stays inside the
    // inscribed circle.
    canvas.drawCircle(
      Offset(s / 2, s / 2),
      s / 2,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(s / 2, 0),
          Offset(s / 2, s),
          const [Color(0xFF3A3F48), Color(0xFF23262C)],
        ),
    );
    final overflow = members.length > 4;
    final faces = overflow
        ? members.take(3).toList()
        : members.take(4).toList();
    final count = faces.length + (overflow ? 1 : 0);
    // 1: one big face; 2: a centred row; 3-4: a 2x2 grid in the circle.
    final cell = count <= 1
        ? s * .62
        : count == 2
        ? s * .42
        : s * .34;
    final gap = s * .02;
    for (var i = 0; i < count; i++) {
      final col = i % 2;
      final row = count <= 2 ? 0 : i ~/ 2;
      final rows = count <= 2 ? 1 : 2;
      final cols = count <= 1 ? 1 : 2;
      final gridW = cols * cell + (cols - 1) * gap;
      final gridH = rows * cell + (rows - 1) * gap;
      // A lone last face in a 3-grid is centred on its row.
      final rowCols = (count == 3 && row == 1) ? 1 : cols;
      final rowW = rowCols * cell + (rowCols - 1) * gap;
      final x0 = (s - (rowCols == cols ? gridW : rowW)) / 2;
      final origin = Offset(
        x0 + (rowCols == 1 ? 0 : col) * (cell + gap),
        (s - gridH) / 2 + row * (cell + gap),
      );
      if (i < faces.length) {
        final identity = faces[i];
        if (identity == null) continue;
        canvas.save();
        canvas.translate(origin.dx, origin.dy);
        _paintIdentityFace(canvas, cell, identity, BotFaceBitmapState.idle, 0);
        canvas.restore();
      } else {
        final tp = TextPainter(
          text: TextSpan(
            text: '+${members.length - 3}',
            style: TextStyle(
              color: const Color(0xFFF3F0E8),
              fontSize: cell * .38,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          origin + Offset((cell - tp.width) / 2, (cell - tp.height) / 2),
        );
      }
    }
    return _encode(recorder, size);
  }

  /// Face of [identity] (no badge) filling a [side]×[side] box.
  static void _paintIdentityFace(
    Canvas canvas,
    double side,
    BotFaceIdentity identity,
    BotFaceBitmapState state,
    int frame,
  ) {
    final procedural =
        identity.source == BotFaceSource.procedural ||
        (identity.source == BotFaceSource.avatar && identity.shapeWire != null);
    if (procedural) {
      final inset = side * .02;
      canvas.save();
      canvas.translate(inset, inset);
      paintHermesBotFaceFrame(
        canvas,
        Size(side - inset * 2, side - inset * 2),
        identity.visual,
        pose: botFacePose(state, frame),
      );
      canvas.restore();
      return;
    }
    canvas.save();
    canvas.scale(side / 100);
    paintBotSphere(canvas, identity.sphere, sphereEyePose(state, frame));
    canvas.restore();
  }

  /// Procedural face for [profile]: the Desktop shape wire when valid, else
  /// the name-derived Blobatar.
  static HermesBotFaceVisual? visualFor(String profile, String? shape) =>
      HermesBlobatarFaceVisual.tryParse(
        shapeWire: shape ?? 'blobatar',
        profileName: profile,
      ) ??
      HermesBlobatarFaceVisual.tryParse(
        shapeWire: 'blobatar',
        profileName: profile,
      );

  /// Configured procedural face with the state expression and badge.
  static Future<List<int>?> renderPng(
    HermesBotFaceVisual visual, {
    BotFaceBitmapState state = BotFaceBitmapState.idle,
    int size = 128,
    int frame = 0,
    bool plate = true,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final s = size.toDouble();
    _begin(canvas, s, plate);
    // Blobatar bodies fill ~80 % of their box: draw the box slightly larger
    // than the sphere's r=42 circle so both read at the same size.
    const inset = -2.0;
    canvas.save();
    canvas.translate(inset, inset + 2);
    paintHermesBotFaceFrame(
      canvas,
      const Size(100 - inset * 2, 100 - inset * 2),
      visual,
      pose: botFacePose(state, frame),
    );
    canvas.restore();
    paintBotStateBadge(canvas, state);
    canvas.restore();
    return _encode(recorder, size);
  }

  /// Grok-style sphere in [palette] with the state gaze and badge.
  static Future<List<int>?> renderSpherePng(
    String palette, {
    BotFaceBitmapState state = BotFaceBitmapState.idle,
    int size = 128,
    int frame = 0,
    bool plate = true,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    _begin(canvas, size.toDouble(), plate);
    paintBotSphere(canvas, palette, sphereEyePose(state, frame));
    paintBotStateBadge(canvas, state);
    canvas.restore();
    return _encode(recorder, size);
  }

  /// Starts a face canvas in 100×100 face units. With [plate] a dark disc
  /// fills the image and the face is inset so a circular crop keeps the
  /// badge. Callers balance with one `canvas.restore()`.
  static void _begin(Canvas canvas, double s, bool plate) {
    if (plate) {
      canvas.drawCircle(
        Offset(s / 2, s / 2),
        s / 2,
        Paint()..color = const Color(0xFF15171B),
      );
    }
    canvas.save();
    final inset = plate ? s * .13 : 0.0;
    canvas.translate(inset, inset);
    canvas.scale((s - inset * 2) / 100);
  }

  /// Configured raster avatar cropped to the face circle, with the badge.
  static Future<List<int>?> renderAvatarPng(
    Uint8List image, {
    BotFaceBitmapState state = BotFaceBitmapState.idle,
    int size = 128,
    bool plate = false,
  }) async {
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      codec = await ui.instantiateImageCodec(
        image,
        targetWidth: size,
        targetHeight: size,
      );
      decoded = (await codec.getNextFrame()).image;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      _begin(canvas, size.toDouble(), plate);
      const rect = Rect.fromLTWH(8, 8, 84, 84);
      canvas.save();
      canvas.clipPath(Path()..addOval(rect));
      canvas.drawImageRect(
        decoded,
        Rect.fromLTWH(
          0,
          0,
          decoded.width.toDouble(),
          decoded.height.toDouble(),
        ),
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      paintBotStateBadge(canvas, state);
      canvas.restore();
      return await _encode(recorder, size);
    } catch (_) {
      return null;
    } finally {
      decoded?.dispose();
      codec?.dispose();
    }
  }

  /// Neutral avatar for events without a Bot owner (Cron, Kanban, normal
  /// chats): the monochrome ">_" glyph on a dark disc in the same geometry
  /// as a face, with the state badge — never the app portrait.
  Future<String?> neutralGlyphPath({
    int size = 128,
    BotFaceBitmapState state = BotFaceBitmapState.idle,
  }) {
    final key = 'glyph_r${revision}_${size}_${state.name}.png';
    return _inFlight[key] ??=
        () async {
              final dir = await _directory();
              final file = File('${dir.path}/$key');
              if (await file.exists() && await file.length() > 0) {
                return file.path;
              }
              final bytes = await renderNeutralGlyphPng(
                size: size,
                state: state,
              );
              if (bytes == null) return null;
              await _write(dir, file, bytes);
              return file.path;
            }()
            .timeout(const Duration(seconds: 3), onTimeout: () => null)
            .catchError((Object _) => null)
            .whenComplete(() {
              _inFlight.remove(key);
            });
  }

  static Future<List<int>?> renderNeutralGlyphPng({
    int size = 128,
    BotFaceBitmapState state = BotFaceBitmapState.idle,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    _begin(canvas, size.toDouble(), false);
    canvas.drawCircle(
      const Offset(50, 50),
      42,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(50, 8),
          const Offset(50, 92),
          const [Color(0xFF2A2D33), Color(0xFF16181C)],
        ),
    );
    final stroke = Paint()
      ..color = const Color(0xFFE9EAEE)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 6.5;
    canvas.drawPath(
      Path()
        ..moveTo(32, 38)
        ..lineTo(45, 50)
        ..lineTo(32, 62),
      stroke,
    );
    canvas.drawLine(const Offset(52, 62), const Offset(68, 62), stroke);
    paintBotStateBadge(canvas, state);
    canvas.restore();
    return _encode(recorder, size);
  }

  static Future<List<int>?> _encode(
    ui.PictureRecorder recorder,
    int size,
  ) async {
    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
}

/// State badge on the face's top-left in 100×100 face units (Grok Bot
/// reference): a blue "•••" pill while working, a plain green / amber / red
/// dot otherwise, each with a black ring. Idle has no badge.
void paintBotStateBadge(Canvas canvas, BotFaceBitmapState state) {
  if (state == BotFaceBitmapState.idle) return;
  final ring = Paint()
    ..color = const Color(0xFF07080A)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.5;
  final fill = Paint()..color = BotStateColors.of(state);
  if (state == BotFaceBitmapState.working) {
    final pill = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4, 8, 26, 16),
      const Radius.circular(8),
    );
    canvas
      ..drawRRect(pill, ring)
      ..drawRRect(pill, fill);
    final dot = Paint()..color = const Color(0xFFFFFFFF);
    for (final x in const [11.5, 17.0, 22.5]) {
      canvas.drawCircle(Offset(x, 16), 2, dot);
    }
    return;
  }
  canvas
    ..drawCircle(const Offset(16, 17), 8, ring)
    ..drawCircle(const Offset(16, 17), 8, fill);
}
