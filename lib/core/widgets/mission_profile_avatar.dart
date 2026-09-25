import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../models/agent_profile.dart';
import '../theme/app_theme.dart';
import 'hermes_bot_face.dart';
import 'bot_avatar_motion.dart';

typedef MissionAvatarLoader =
    Future<AgentProfileAvatar?> Function(String profileName);

/// Caché de avatares por conexión/pantalla con concurrencia acotada.
///
/// Los widgets perezosos de listas grandes comparten el mismo Future por
/// profile. Así 50 agentes no abren 50 lecturas simultáneas ni repiten el
/// payload cuando un avatar aparece en Rooms, Team y Work.
final class MissionProfileAvatarCache {
  final MissionAvatarLoader _loader;
  final String? connectionId;
  final int maxEntries;
  final int maxConcurrent;
  final LinkedHashMap<String, Future<AgentProfileAvatar?>> _entries =
      LinkedHashMap();
  // Resultados ya entregados, legibles de forma síncrona desde `build` (ver
  // [resolved]). Se expulsan a la vez que su Future en [_entries].
  final Map<String, AgentProfileAvatar?> _resolved = {};
  final Queue<_AvatarLoadJob> _queue = Queue();
  int _active = 0;

  factory MissionProfileAvatarCache({
    required MissionAvatarLoader loader,
    String? connectionId,
    int maxEntries = 64,
    int maxConcurrent = 4,
  }) => MissionProfileAvatarCache._(
    loader,
    maxEntries,
    maxConcurrent,
    connectionId,
  );

  MissionProfileAvatarCache._(
    this._loader,
    this.maxEntries,
    this.maxConcurrent,
    this.connectionId,
  ) : assert(maxEntries > 0),
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
      _evict(_entries.keys.first);
    }
    final completer = Completer<AgentProfileAvatar?>();
    final future = completer.future;
    _entries[profile] = future;
    // Solo se recuerda si la entrada sigue siendo esta misma carga: una
    // expulsión (o `clear`) intermedia no debe resucitar el valor.
    unawaited(
      future.then((avatar) {
        if (identical(_entries[profile], future)) _resolved[profile] = avatar;
      }),
    );
    _queue.add(_AvatarLoadJob(profile, completer));
    _pump();
    return future;
  }

  /// `true` si la carga de [profileName] ya terminó y su resultado (aunque
  /// sea "sin avatar") sigue en caché: [resolved] puede leerse en `build` sin
  /// pasar por un `FutureBuilder`.
  bool hasResolved(String profileName) =>
      _resolved.containsKey(profileName.trim());

  /// Resultado ya cargado de [profileName], o `null`. Cuenta como uso reciente
  /// igual que [load], para que un avatar visible no sea el primero en salir.
  AgentProfileAvatar? resolved(String profileName) {
    final profile = profileName.trim();
    final entry = _entries.remove(profile);
    if (entry != null) _entries[profile] = entry;
    return _resolved[profile];
  }

  void clear() {
    _entries.clear();
    _resolved.clear();
  }

  void _evict(String profile) {
    _entries.remove(profile);
    _resolved.remove(profile);
  }

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
  final bool working;

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
    this.working = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Desktop may publish a 160px PNG backfill for procedural faces. It is an
    // interoperability asset, not the selected identity: shape metadata must
    // continue through the native Blobatar renderer instead of becoming a
    // frozen raster in Android.
    final avatarCache = cache;
    final shouldLoadAvatar =
        hasAvatar && avatarCache != null && imageKind?.toLowerCase() != 'shape';
    final Widget content;
    if (!shouldLoadAvatar) {
      content = _AvatarFace(
        profileName: profileName,
        size: size,
        shape: shape,
        colorHex: colorHex,
        privacySafeElementKeys: privacySafeElementKeys,
        working: working,
      );
    } else if (avatarCache.hasResolved(profileName)) {
      // Ya en caché: se pinta en este mismo frame. Con `FutureBuilder` hasta
      // un Future ya completado tarda un microtask en entregar su valor, así
      // que cada fila que una lista materializaba (scroll, refresco en vivo)
      // pintaba primero el Blobatar de reserva y un frame después la imagen:
      // un parpadeo visible y un layout+paint desperdiciados por fila.
      content = _AvatarFace(
        profileName: profileName,
        size: size,
        avatar: avatarCache.resolved(profileName),
        shape: shape,
        colorHex: colorHex,
        privacySafeElementKeys: privacySafeElementKeys,
        working: working,
      );
    } else {
      content = FutureBuilder<AgentProfileAvatar?>(
        future: avatarCache.load(profileName),
        builder: (context, snapshot) => _AvatarFace(
          profileName: profileName,
          size: size,
          avatar: snapshot.data,
          shape: shape,
          colorHex: colorHex,
          privacySafeElementKeys: privacySafeElementKeys,
          working: working,
        ),
      );
    }
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
        child: BotAvatarMotion(
          enabled: working && shouldLoadAvatar,
          child: content,
        ),
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
  final bool working;

  const _AvatarFace({
    required this.profileName,
    required this.size,
    this.avatar,
    this.shape,
    this.colorHex,
    this.privacySafeElementKeys = false,
    this.working = false,
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
            animate: working,
            motionState: HermesBotFaceMotionState.thinking,
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
        // Solo UN lado: con ambos el decoder no conserva la proporción y un
        // avatar no cuadrado llega achatado antes de que `cover` lo recorte.
        cacheWidth: (size * 3).round(),
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
