import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/agent_profile.dart';
import '../services/active_profile_scope.dart';
import '../services/bot_roster_store.dart';
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

/// Display name of profile [name] (empty = default), the same one the
/// switcher lists: the roster's `display_name` when the profile is known
/// (Desktop `profileLabel`: `display_name || name`), else its name.
String activeProfileDisplayLabel(
  Strings strings,
  String name,
  Iterable<AgentProfile> roster,
) {
  final owner = name.trim();
  final isDefault = owner.isEmpty || owner == 'default';
  for (final profile in roster) {
    if (isDefault ? profile.isDefault : profile.name == owner) {
      return profileDisplayLabel(strings, profile);
    }
  }
  return ProfileScopeLabel.display(strings, owner);
}

/// Name of [profile] as listed: its `display_name`, else its name.
String profileDisplayLabel(Strings strings, AgentProfile profile) {
  final display = profile.displayName.trim();
  if (display.isNotEmpty) return display;
  return ProfileScopeLabel.display(strings, profile.name);
}

/// States which profile a screen reads and edits ("Profile: ana"). Kept
/// plain on purpose: the visual redesign restyles it through its key.
///
/// With [connectionId] the name follows that connection's roster, so the
/// label reads like the profile switcher ("Hermes" rather than "Default").
class ProfileScopeLabel extends StatelessWidget {
  const ProfileScopeLabel({
    required this.profile,
    this.connectionId,
    super.key = const ValueKey('profile-scope-label'),
  });

  /// Profile name; empty means the default profile.
  final String profile;
  final String? connectionId;

  static String display(Strings strings, String profile) {
    final name = profile.trim();
    return name.isEmpty || name == 'default'
        ? strings.profileScopeDefault
        : name;
  }

  @override
  Widget build(BuildContext context) {
    final id = connectionId;
    if (id == null) {
      return _text(context, display(Strings.of(context), profile));
    }
    final roster = BotRosterRegistry.shared.store(id);
    return ListenableBuilder(
      listenable: roster,
      builder: (context, _) => _text(
        context,
        activeProfileDisplayLabel(
          Strings.of(context),
          profile,
          roster.profiles,
        ),
      ),
    );
  }

  Widget _text(BuildContext context, String name) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Text(
      strings.chaProfileChip(name),
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
    this.connectionId,
    super.key,
  });

  final String title;
  final String profile;
  final String? connectionId;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(title),
      ProfileScopeLabel(profile: profile, connectionId: connectionId),
    ],
  );
}
