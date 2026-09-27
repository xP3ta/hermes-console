import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import '../../widgets/hermes_bot_face.dart';

/// Visual state baked into a rasterised face (spec 070 § Notifications and
/// § Widgets). Android does not animate notification or widget contents, so
/// the state is carried by a thin ring around the static face.
enum BotFaceBitmapState { idle, working, needsYou, failed }

/// Renders Bot faces to small circular PNG files in app storage.
///
/// Files are content-addressed (profile + shape + state + size), so the same
/// face is rendered once and every notification/widget refers to it by path.
/// Rendering is pure Dart (`PictureRecorder`), so it also works in the
/// background listener isolate, which has no widget tree.
class BotFaceBitmapCache {
  BotFaceBitmapCache({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;
  final Map<String, Future<String?>> _inFlight = {};

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/bot_faces');
  }

  static const Map<BotFaceBitmapState, Color> ringColors = {
    BotFaceBitmapState.idle: Color(0x00000000),
    BotFaceBitmapState.working: Color(0xFFE8821C),
    BotFaceBitmapState.needsYou: Color(0xFFFFC66A),
    BotFaceBitmapState.failed: Color(0xFFFF8A80),
  };

  static String fileKey({
    required String profile,
    required String? shape,
    required BotFaceBitmapState state,
    required int size,
  }) {
    final digest = sha256
        .convert(utf8.encode('$profile\u0000${shape ?? ''}\u0000$size'))
        .toString()
        .substring(0, 20);
    return 'face_${digest}_${state.name}.png';
  }

  /// Path of the PNG for [profile]; `null` when rendering is unavailable.
  Future<String?> pathFor({
    required String profile,
    String? shape,
    BotFaceBitmapState state = BotFaceBitmapState.idle,
    int size = 128,
  }) {
    final key = fileKey(profile: profile, shape: shape, state: state, size: size);
    return _inFlight[key] ??= _render(key, profile, shape, state, size)
        .timeout(const Duration(seconds: 3), onTimeout: () => null)
        .catchError((Object _) => null)
        .whenComplete(() {
          // Block body: returning the removed Future would make whenComplete
          // await itself and never complete.
          _inFlight.remove(key);
        });
  }

  Future<String?> _render(
    String key,
    String profile,
    String? shape,
    BotFaceBitmapState state,
    int size,
  ) async {
    final dir = await _directory();
    final file = File('${dir.path}/$key');
    if (await file.exists() && await file.length() > 0) return file.path;
    final visual =
        HermesBlobatarFaceVisual.tryParse(
          shapeWire: shape ?? 'blobatar',
          profileName: profile,
        ) ??
        HermesBlobatarFaceVisual.tryParse(
          shapeWire: 'blobatar',
          profileName: profile,
        );
    if (visual == null) return null;
    final bytes = await renderPng(visual, state: state, size: size);
    if (bytes == null) return null;
    await dir.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return file.path;
  }

  /// Circular dark plate + face + optional state ring.
  static Future<List<int>?> renderPng(
    HermesBotFaceVisual visual, {
    BotFaceBitmapState state = BotFaceBitmapState.idle,
    int size = 128,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final s = size.toDouble();
    final center = Offset(s / 2, s / 2);
    canvas.drawCircle(center, s / 2, Paint()..color = const Color(0xFF1A191D));
    final inset = s * 0.14;
    canvas.save();
    canvas.translate(inset, inset);
    paintHermesBotFaceFrame(
      canvas,
      Size(s - inset * 2, s - inset * 2),
      visual,
      motionState: state == BotFaceBitmapState.working
          ? HermesBotFaceMotionState.thinking
          : HermesBotFaceMotionState.idle,
    );
    canvas.restore();
    final ring = ringColors[state]!;
    if (ring.a > 0) {
      canvas.drawCircle(
        center,
        s / 2 - s * 0.03,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.06
          ..color = ring,
      );
    }
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
