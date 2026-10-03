import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/active_profile_scope.dart';
import '../theme/app_theme.dart';

/// The [ActiveProfileScope] of [connectionId] for screens that reach the
/// connection manager through the app state.
ActiveProfileScope? appActiveProfileScope(
  BuildContext context,
  String connectionId,
) {
  final manager = context
      .findAncestorStateOfType<HermesAppState>()
      ?.connManager;
  return manager == null ? null : ActiveProfileScope.of(manager, connectionId);
}

/// A per-profile screen (model, SOUL, skills, memory…) either edits one fixed
/// profile (opened from a bot card) or follows the active profile. When it
/// follows, a switch calls [onActiveProfileChanged] so the screen re-reads
/// for the new profile, and [profileReadTicket] lets every async read drop
/// its late answer if the profile changed meanwhile.
mixin ActiveProfileFollower<T extends StatefulWidget> on State<T> {
  ActiveProfileScope? _followedScope;
  String? _fixedProfile;

  /// Starts (or moves) the follow. [fixedProfile] wins when non-null.
  void followActiveProfile(ActiveProfileScope? scope, {String? fixedProfile}) {
    final fixed = fixedProfile?.trim();
    _fixedProfile = fixed;
    final next = fixed == null ? scope : null;
    if (identical(next, _followedScope)) return;
    _followedScope?.removeListener(_onFollowedProfileChanged);
    _followedScope = next;
    next?.addListener(_onFollowedProfileChanged);
  }

  /// Profile this screen edits right now (empty = default profile).
  String get scopedProfileName =>
      _fixedProfile ?? _followedScope?.name.trim() ?? '';

  /// Whether the screen is pinned to a profile given by its caller.
  bool get followsFixedProfile => _fixedProfile != null;

  /// Captures the profile a read starts with.
  ProfileReadTicket profileReadTicket() =>
      _followedScope?.capture() ?? ProfileReadTicket.fixed(scopedProfileName);

  /// Called after the active profile changed (never for a fixed profile).
  void onActiveProfileChanged();

  void _onFollowedProfileChanged() {
    if (mounted) onActiveProfileChanged();
  }

  @override
  void dispose() {
    _followedScope?.removeListener(_onFollowedProfileChanged);
    _followedScope = null;
    super.dispose();
  }
}

/// States which profile a screen reads and edits ("Profile: ana"). Kept
/// plain on purpose: the visual redesign restyles it through its key.
class ProfileScopeLabel extends StatelessWidget {
  const ProfileScopeLabel({
    required this.profile,
    super.key = const ValueKey('profile-scope-label'),
  });

  /// Profile name; empty means the default profile.
  final String profile;

  static String display(Strings strings, String profile) {
    final name = profile.trim();
    return name.isEmpty || name == 'default'
        ? strings.profileScopeDefault
        : name;
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Text(
      strings.chaProfileChip(display(strings, profile)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: colors.accent),
    );
  }
}

/// Title with the profile line under it, for per-profile app bars.
class ProfileScopedTitle extends StatelessWidget {
  const ProfileScopedTitle({
    required this.title,
    required this.profile,
    super.key,
  });

  final String title;
  final String profile;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(title),
      ProfileScopeLabel(profile: profile),
    ],
  );
}
