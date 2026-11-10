// Local identity reads for a single launcher redraw. No reader starts network
// work; decoded images belong to the publication and are released afterwards.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../../characters/bot_character.dart';
import '../../characters/character_face.dart';
import '../../characters/profile_identity_resolver.dart';
import '../../companion/models/companion.dart';
import '../../companion/models/companion_animation_state.dart';
import '../../services/bot_roster_store.dart';
import '../../models/agent_profile.dart';
import '../../widgets/bot_face_identity.dart';
import '../../widgets/mission_profile_avatar.dart';

/// The same list name as the drawer and Bots, with the previous fallback
/// when the connection's roster has not arrived yet.
String lwProfileName(
  String? connection,
  String profile, {
  String? fallback,
  AgentProfile? identity,
}) {
  final known =
      identity ??
      (connection == null
          ? null
          : BotRosterRegistry.shared.store(connection).profile(profile));
  if (known != null) return known.botListName;
  final id = profile.trim();
  return fallback ?? (id.isEmpty ? id : id[0].toUpperCase() + id.substring(1));
}

/// A ready-to-paint identity. Raster data is decoded before recording a frame.
class LwAvatar {
  LwAvatar({
    required this.fallback,
    this.character,
    this.image,
    this.fit = BoxFit.contain,
  });

  final BotFaceIdentity fallback;
  final BotCharacter? character;
  final ui.Image? image;
  final BoxFit fit;

  /// Paints within the caller's circular clip, or returns false for a sphere.
  bool paint(ui.Canvas canvas, ui.Size size, ui.Color accent) {
    final raster = image;
    if (raster != null) {
      paintImage(
        canvas: canvas,
        rect: ui.Offset.zero & size,
        image: raster,
        fit: fit,
        filterQuality: FilterQuality.medium,
      );
      return true;
    }
    final saved = character;
    if (saved == null) return false;
    paintCharacterFaceFrame(
      canvas,
      size,
      character: saved,
      profileName: fallback.profile,
      accent: accent,
    );
    return true;
  }

  void dispose() => image?.dispose();
}

/// Transient bounds, independent of the output bitmap's pixel budget.
const lwAvatarEdge = 256;
const _maxAtlasEdge = 1024;
const _maxEncodedBytes = 16 * 1024 * 1024;

Future<Uint8List> _petBytes(Companion pet) async {
  if (pet.isFileBacked) {
    final file = await File(pet.spritesheetAsset).open();
    try {
      if (await file.length() > _maxEncodedBytes) {
        throw const FormatException('Sprite exceeds byte budget');
      }
      return await file.read(_maxEncodedBytes + 1);
    } finally {
      await file.close();
    }
  }
  final data = await rootBundle.load(pet.spritesheetAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Loads only local files/assets and already cached photos, on the UI isolate.
/// An unavailable photo lets the resolver choose the character beneath it.
/// Any actual load/decode failure retains the existing sphere.
Future<LwAvatar> lwLoadAvatar(String? connection, String name) async {
  final profile = connection == null
      ? null
      : BotRosterRegistry.shared.store(connection).profile(name);
  final fallback = BotFaceIdentity.ofProfile(profile, name: name);
  if (connection == null || connection.isEmpty) {
    return LwAvatar(fallback: fallback);
  }
  try {
    final photo = MissionProfileAvatarCache.cachedAvatar(connection, name);
    final identity = resolveProfileIdentity(
      profileName: name,
      connectionId: connection,
      profile: profile,
      canLoadPhoto: photo != null,
    );
    switch (identity.source) {
      case ProfileIdentitySource.character:
        return LwAvatar(fallback: fallback, character: identity.character);
      case ProfileIdentitySource.face:
        return LwAvatar(fallback: fallback);
      case ProfileIdentitySource.photo:
        return LwAvatar(
          fallback: fallback,
          image: await _decode(photo!.bytes),
          fit: BoxFit.cover,
        );
      case ProfileIdentitySource.pet:
        final pet = identity.pet!;
        return LwAvatar(
          fallback: fallback,
          image: await _decode(await _petBytes(pet), pet: pet),
        );
    }
  } catch (_) {
    return LwAvatar(fallback: fallback);
  }
}

Future<ui.Image> _decode(Uint8List bytes, {Companion? pet}) async {
  if (bytes.isEmpty || bytes.length > _maxEncodedBytes) {
    throw const FormatException('Invalid raster byte budget');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? atlas;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final cols = pet?.cols ?? 1;
    final rows = pet?.rows ?? 1;
    final row = pet?.rowFor(CompanionAnimationState.idle)?.row ?? 0;
    if (cols < 1 || rows < 1 || row < 0 || row >= rows) {
      throw const FormatException('Invalid sprite grid');
    }
    final edge = pet == null ? lwAvatarEdge : _maxAtlasEdge;
    final ratio = math.min(
      1.0,
      edge / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * ratio).floor()),
      targetHeight: math.max(1, (descriptor.height * ratio).floor()),
    );
    atlas = (await codec.getNextFrame()).image;
    final width = atlas.width ~/ cols;
    final height = atlas.height ~/ rows;
    if (width < 1 || height < 1) {
      throw const FormatException('Empty sprite cell');
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final scale = math.min(1.0, lwAvatarEdge / math.max(width, height));
    final outWidth = math.max(1, (width * scale).floor());
    final outHeight = math.max(1, (height * scale).floor());
    canvas.drawImageRect(
      atlas,
      ui.Rect.fromLTWH(
        0,
        (row * height).toDouble(),
        width.toDouble(),
        height.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(outWidth, outHeight);
    } finally {
      picture.dispose();
    }
  } finally {
    atlas?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
