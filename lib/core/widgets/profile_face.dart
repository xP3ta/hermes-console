import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/agent_profile.dart';
import '../services/connection_manager.dart';
import '../services/shared_gateway_pool.dart';
import '../theme/app_theme.dart';
import 'mission_profile_avatar.dart';

/// A profile's own face, small and still, for the drawer's profile row and
/// the profile switcher, so profiles are recognisable at a glance.
///
/// Priority: the profile's custom image when the user set one (a photo or
/// an image without face metadata, see [AgentProfile.botPaintsPhoto]), else
/// the bot's own procedural face (its Blobatar shape, name-derived when it
/// has none). Never a generic icon.
///
/// Static on purpose: no [LivingBotFace], no ticker, no blink. A working
/// profile shows a small status dot instead of motion. The active profile
/// wears a ring in the accent colour.
///
/// App Lock: while [locked] (or [appLocked]) is true no avatar is read or
/// decoded; the bot face stands in until unlock.
class ProfileFace extends StatelessWidget {
  /// Outer size, ring included: the leading slot of a list row.
  static const double defaultSize = 30;

  /// Ring stroke and the gap between ring and face.
  static const double ringWidth = 2;
  static const double ringGap = 1;

  /// The App Lock state, wired once at startup (like the mascot and the
  /// media prefetcher). [locked] overrides it.
  static ValueListenable<bool>? appLocked;

  final String profileName;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final bool active;
  final bool working;
  final double size;
  final ValueListenable<bool>? locked;

  const ProfileFace({
    required this.profileName,
    this.profile,
    this.avatarCache,
    this.active = false,
    this.working = false,
    this.size = defaultSize,
    this.locked,
    super.key,
  });

  /// Avatar cache shared by the drawer row and the switcher sheet of
  /// [connection]: one read per profile, renewed when the roster is re-read
  /// ([rosterTicket] changes) so an avatar changed elsewhere shows up.
  static MissionProfileAvatarCache cacheFor(
    SavedConnection connection, {
    required int rosterTicket,
    MissionAvatarLoader? loader,
  }) {
    final entry = _caches[connection.id];
    if (entry != null && entry.ticket == rosterTicket) return entry.cache;
    final cache = MissionProfileAvatarCache(
      connectionId: connection.id,
      maxEntries: 32,
      loader: loader ?? (name) => _gatewayAvatar(connection, name),
    );
    _caches[connection.id] = (ticket: rosterTicket, cache: cache);
    return cache;
  }

  static final Map<String, ({int ticket, MissionProfileAvatarCache cache})>
  _caches = {};

  @visibleForTesting
  static void debugResetAvatarCaches() => _caches.clear();

  static Future<AgentProfileAvatar?> _gatewayAvatar(
    SavedConnection connection,
    String profileName,
  ) async {
    final lease = SharedGatewayPool.instance.acquire(connection);
    try {
      return await lease.client.profileAvatar(profileName);
    } finally {
      lease.release();
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = locked ?? appLocked;
    if (lock == null) return _face(context, isLocked: false);
    return ValueListenableBuilder<bool>(
      valueListenable: lock,
      builder: (context, isLocked, _) => _face(context, isLocked: isLocked),
    );
  }

  Widget _face(BuildContext context, {required bool isLocked}) {
    final colors = Theme.of(context).hermes;
    final profile = this.profile;
    final cache = avatarCache;
    final photo =
        !isLocked && profile != null && profile.botPaintsPhoto && cache != null;
    final inner = size - 2 * (ringWidth + ringGap);
    final dot = (size * 0.3).clamp(7.0, 10.0);
    return ExcludeSemantics(
      child: SizedBox.square(
        key: ValueKey('profile-face-$profileName'),
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            DecoratedBox(
              key: ValueKey('profile-face-ring-$profileName'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: active ? colors.accent : Colors.transparent,
                  width: ringWidth,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(ringWidth + ringGap),
                child: MissionProfileAvatar(
                  allowPet: !isLocked,
                  profileName: profile?.name ?? profileName,
                  hasAvatar: photo,
                  cache: photo ? cache : null,
                  size: inner,
                  shape: profile?.botFaceShape,
                  colorHex: profile?.botFaceColorHex,
                  imageKind: profile?.botImageKind,
                ),
              ),
            ),
            if (working)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  key: ValueKey('profile-face-working-$profileName'),
                  width: dot,
                  height: dot,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.success,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
