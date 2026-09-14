import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../models/agent_profile.dart';
import '../theme/app_theme.dart';
import 'hermes_bot_face.dart';

typedef MissionAvatarLoader =
    Future<AgentProfileAvatar?> Function(String profileName);

/// Caché de avatares por conexión/pantalla con concurrencia acotada.
///
/// Los widgets perezosos de listas grandes comparten el mismo Future por
/// profile. Así 50 agentes no abren 50 lecturas simultáneas ni repiten el
/// payload cuando un avatar aparece en Rooms, Team y Work.
final class MissionProfileAvatarCache {
  final MissionAvatarLoader _loader;
  final int maxEntries;
  final int maxConcurrent;
  final LinkedHashMap<String, Future<AgentProfileAvatar?>> _entries =
      LinkedHashMap();
  final Queue<_AvatarLoadJob> _queue = Queue();
  int _active = 0;

  factory MissionProfileAvatarCache({
    required MissionAvatarLoader loader,
    int maxEntries = 64,
    int maxConcurrent = 4,
  }) => MissionProfileAvatarCache._(loader, maxEntries, maxConcurrent);

  MissionProfileAvatarCache._(this._loader, this.maxEntries, this.maxConcurrent)
    : assert(maxEntries > 0),
      assert(maxConcurrent > 0),
      super();

  Future<AgentProfileAvatar?> load(String profileName) {
    final profile = profileName.trim();
    if (profile.isEmpty) return Future.value();
    final cached = _entries.remove(profile);
    if (cached != null) {
      _entries[profile] = cached;
      return cached;
    }
    while (_entries.length >= maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    final completer = Completer<AgentProfileAvatar?>();
    final future = completer.future;
    _entries[profile] = future;
    _queue.add(_AvatarLoadJob(profile, completer));
    _pump();
    return future;
  }

  void clear() => _entries.clear();

  void _pump() {
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active++;
      Future<AgentProfileAvatar?>.sync(() => _loader(job.profileName))
          .then(
            job.completer.complete,
            onError: (_) => job.completer.complete(),
          )
          .whenComplete(() {
            _active--;
            _pump();
          });
    }
  }
}

final class _AvatarLoadJob {
  final String profileName;
  final Completer<AgentProfileAvatar?> completer;

  const _AvatarLoadJob(this.profileName, this.completer);
}

/// Identidad estática profile-aware para listas, cabeceras y member stacks.
///
/// No anima spritesheets: Bot Mode persiste el frame elegido como el asset
/// `avatar`, que es exactamente la representación ligera que necesita Android.
class MissionProfileAvatar extends StatelessWidget {
  final String profileName;
  final bool hasAvatar;
  final MissionProfileAvatarCache? cache;
  final double size;
  final bool manager;
  final String? shape;
  final String? colorHex;
  final String? imageKind;
  final bool privacySafeElementKeys;

  const MissionProfileAvatar({
    super.key,
    required this.profileName,
    required this.hasAvatar,
    required this.cache,
    this.size = 40,
    this.manager = false,
    this.shape,
    this.colorHex,
    this.imageKind,
    this.privacySafeElementKeys = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Desktop may publish a 160px PNG backfill for procedural faces. It is an
    // interoperability asset, not the selected identity: shape metadata must
    // continue through the native Blobatar renderer instead of becoming a
    // frozen raster in Android.
    final shouldLoadAvatar =
        hasAvatar && cache != null && imageKind?.toLowerCase() != 'shape';
    final content = shouldLoadAvatar
        ? FutureBuilder<AgentProfileAvatar?>(
            future: cache!.load(profileName),
            builder: (context, snapshot) => _AvatarFace(
              profileName: profileName,
              size: size,
              avatar: snapshot.data,
              shape: shape,
              colorHex: colorHex,
              privacySafeElementKeys: privacySafeElementKeys,
            ),
          )
        : _AvatarFace(
            profileName: profileName,
            size: size,
            shape: shape,
            colorHex: colorHex,
            privacySafeElementKeys: privacySafeElementKeys,
          );
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        padding: manager ? const EdgeInsets.all(2) : EdgeInsets.zero,
        decoration: manager
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: colors.warning.withValues(alpha: 0.82),
                  width: 1.25,
                ),
              )
            : null,
        child: content,
      ),
    );
  }
}

class _AvatarFace extends StatelessWidget {
  final String profileName;
  final double size;
  final AgentProfileAvatar? avatar;
  final String? shape;
  final String? colorHex;
  final bool privacySafeElementKeys;

  const _AvatarFace({
    required this.profileName,
    required this.size,
    this.avatar,
    this.shape,
    this.colorHex,
    this.privacySafeElementKeys = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final visual = _faceVisual();
    final fallback = visual != null
        ? HermesBotFace(
            key: ValueKey(
              privacySafeElementKeys
                  ? 'mission-avatar-geometry'
                  : 'mission-avatar-geometry-$profileName',
            ),
            visual: visual,
            size: size,
          )
        : ClipOval(
            child: ColoredBox(
              color: colors.surfaceVariant,
              child: Center(
                child: Text(
                  profileName.isEmpty
                      ? '?'
                      : profileName.characters.first.toUpperCase(),
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: size * 0.38,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
    final loaded = avatar;
    if (loaded == null) return fallback;
    return ClipOval(
      child: Image.memory(
        loaded.bytes,
        width: size,
        height: size,
        // Decodificar acotado al tamaño mostrado (×3 de DPR): los avatares
        // subidos pueden ser PNG grandes y el widget nunca pasa de `size` dp.
        cacheWidth: (size * 3).round(),
        cacheHeight: (size * 3).round(),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }

  HermesBotFaceVisual? _faceVisual() {
    final shapeWire = shape;
    final blobatar = shapeWire == null
        ? null
        : HermesBlobatarFaceVisual.tryParse(
            shapeWire: shapeWire,
            profileName: profileName,
          );
    if (blobatar != null) return blobatar;
    // Classic shape/color metadata remains readable for rollback and Desktop
    // compatibility, but Console presents a single face system: Blobatar.
    return HermesBlobatarFaceVisual.tryParse(
      shapeWire: 'blobatar',
      profileName: profileName,
    );
  }
}
