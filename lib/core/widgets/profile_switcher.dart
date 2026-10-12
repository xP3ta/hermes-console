import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../bots/state/bot_presence.dart';
import '../models/agent_profile.dart';
import '../services/active_profile_scope.dart';
import '../services/bot_roster_store.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import 'hermes_premium_ui.dart';
import 'mission_profile_avatar.dart';
import 'profile_face.dart';
import 'profile_scope.dart';
import 'console_loader.dart';

/// Reads the profile list into the shared roster when no live read has
/// landed yet. One Dashboard read, ordered by the roster clock so it can
/// never overwrite a newer roster.
typedef ProfileRosterReader = Future<List<AgentProfile>> Function();

String _ownerOf(AgentProfile profile) =>
    profile.isDefault ? 'default' : profile.name;

/// The still face of [profile] in the switcher surfaces (drawer row and
/// sheet); see [ProfileFace] for the avatar priority.
Widget _profileFace(
  String owner,
  AgentProfile? profile, {
  required MissionProfileAvatarCache cache,
  required bool active,
  ValueListenable<bool>? locked,
}) => ProfileFace(
  profileName: owner,
  profile: profile,
  avatarCache: cache,
  active: active,
  working:
      profile != null &&
      BotPresence.workerIsFresh(profile.workerSession, DateTime.now()),
  locked: locked,
);

/// The one way to change the active profile (Desktop's profile rail). A
/// switch re-scopes the whole app for [connection]: chats, Home, model,
/// SOUL, skills and memory. Plain on purpose: the redesign restyles it via
/// the `profile-switcher` keys.
class ProfileSwitcherButton extends StatelessWidget {
  const ProfileSwitcherButton({
    required this.connection,
    required this.connManager,
    this.onManage,
    this.compact = false,
    this.rosterRegistry,
    this.readRoster,
    this.avatarLoader,
    this.facesLocked,
    super.key = const ValueKey('profile-switcher'),
  });

  final SavedConnection connection;
  final ConnectionManager connManager;

  /// Opens the profile list (create, edit, delete).
  final VoidCallback? onManage;

  /// App bar form: the active profile's face in a round button, no name.
  final bool compact;
  final BotRosterRegistry? rosterRegistry;
  final ProfileRosterReader? readRoster;

  /// Reads a profile's custom avatar (tests); defaults to the gateway.
  final MissionAvatarLoader? avatarLoader;

  /// App Lock state for the faces (tests); defaults to the app's.
  final ValueListenable<bool>? facesLocked;

  @override
  Widget build(BuildContext context) {
    final scope = ActiveProfileScope.of(connManager, connection.id);
    final roster = (rosterRegistry ?? BotRosterRegistry.shared).store(
      connection.id,
    );
    return ListenableBuilder(
      listenable: Listenable.merge([scope, roster]),
      builder: (context, _) {
        final strings = Strings.of(context);
        final colors = Theme.of(context).hermes;
        final label = activeProfileDisplayLabel(
          strings,
          scope.name,
          roster.profiles,
        );
        void open() => unawaited(
          showProfileSwitcher(
            context,
            connection: connection,
            connManager: connManager,
            onManage: onManage,
            rosterRegistry: rosterRegistry,
            readRoster: readRoster,
            avatarLoader: avatarLoader,
            facesLocked: facesLocked,
          ),
        );
        AgentProfile? active;
        for (final profile in roster.profiles) {
          if (_ownerOf(profile) == scope.owner) active = profile;
        }
        final faces = ProfileFace.cacheFor(
          connection,
          rosterTicket: roster.ticket,
          loader: avatarLoader,
        );
        if (compact) {
          // App bar form: the active profile's own face (custom avatar,
          // else its bot face, else Hermes; never a generic person icon)
          // in a round button, ringed in the accent colour, with a chevron
          // badge on its edge. The name is spoken, not shown, so the tap
          // is declared on the same node that carries it.
          final fill = Color.alphaBlend(
            colors.textPrimary.withValues(alpha: 0.06),
            colors.background,
          );
          return Semantics(
            button: true,
            label: strings.chaProfileChip(label),
            hint: strings.profileSwitcherHint,
            excludeSemantics: true,
            onTap: open,
            child: GestureDetector(
              key: const ValueKey('profile-switcher-compact'),
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: SizedBox.square(
                dimension: 48,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // The face sits straight on the fill: no backing
                    // squircle (QA 9494, face_marks.dart: it read as a
                    // dark square around the face).
                    Container(
                      key: const ValueKey('profile-switcher-avatar'),
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: fill,
                        border: Border.all(color: colors.accent, width: 1.5),
                      ),
                      child: ProfileFace(
                        profileName: scope.owner,
                        profile: active,
                        avatarCache: faces,
                        size: 36,
                        locked: facesLocked,
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        key: const ValueKey('profile-switcher-chevron'),
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: fill,
                          border: Border.all(color: colors.divider),
                        ),
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return HermesListRow(
          key: const ValueKey('profile-switcher-row'),
          leading: _profileFace(
            scope.owner,
            active,
            cache: faces,
            active: true,
            locked: facesLocked,
          ),
          title: strings.chaProfileChip(label),
          semanticHint: strings.profileSwitcherHint,
          trailing: Icon(
            Icons.unfold_more_rounded,
            size: 18,
            color: colors.textDisabled,
          ),
          onTap: open,
        );
      },
    );
  }
}

/// Sheet listing every profile of [connection]; picking one makes it the
/// active profile. Returns the picked name, or null.
Future<String?> showProfileSwitcher(
  BuildContext context, {
  required SavedConnection connection,
  required ConnectionManager connManager,
  VoidCallback? onManage,
  BotRosterRegistry? rosterRegistry,
  ProfileRosterReader? readRoster,
  MissionAvatarLoader? avatarLoader,
  ValueListenable<bool>? facesLocked,
}) {
  final registry = rosterRegistry ?? BotRosterRegistry.shared;
  registry.hydrate(connection);
  return showHermesFloatingSurface<String>(
    context: context,
    surfaceKey: const ValueKey('profile-switcher-sheet'),
    builder: (sheetContext) => _ProfileSwitcherSheet(
      connection: connection,
      scope: ActiveProfileScope.of(connManager, connection.id),
      registry: registry,
      readRoster:
          readRoster ??
          () async {
            final client = DashboardClient.lazy(connection);
            try {
              return await client.getProfiles();
            } finally {
              client.close();
            }
          },
      avatarLoader: avatarLoader,
      facesLocked: facesLocked,
      onManage: onManage == null
          ? null
          : () {
              Navigator.of(sheetContext).pop();
              onManage();
            },
    ),
  );
}

class _ProfileSwitcherSheet extends StatefulWidget {
  const _ProfileSwitcherSheet({
    required this.connection,
    required this.scope,
    required this.registry,
    required this.readRoster,
    required this.onManage,
    this.avatarLoader,
    this.facesLocked,
  });

  final SavedConnection connection;
  final ActiveProfileScope scope;
  final BotRosterRegistry registry;
  final ProfileRosterReader readRoster;
  final VoidCallback? onManage;
  final MissionAvatarLoader? avatarLoader;
  final ValueListenable<bool>? facesLocked;

  @override
  State<_ProfileSwitcherSheet> createState() => _ProfileSwitcherSheetState();
}

class _ProfileSwitcherSheetState extends State<_ProfileSwitcherSheet> {
  late final BotRosterStore _store = widget.registry.store(
    widget.connection.id,
  );
  bool _reading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    widget.scope.addListener(_changed);
    // Like Desktop's dropdown: a list that never came from the server yet
    // is read once on open; a live one is shown as is.
    if (!_store.isLive) unawaited(_read());
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    widget.scope.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    setState(() {
      _reading = true;
      _failed = false;
    });
    final ticket = widget.registry.beginRead(widget.connection.id);
    try {
      final list = await widget.readRoster();
      widget.registry.publish(
        widget.connection.id,
        widget.connection.label,
        list,
        ticket: ticket,
      );
      if (mounted) setState(() => _reading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _reading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _pick(AgentProfile profile) async {
    final navigator = Navigator.of(context);
    await widget.scope.switchTo(profile.isDefault ? '' : profile.name);
    if (navigator.mounted) navigator.pop(profile.name);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final active = widget.scope.owner;
    final profiles = _store.profiles;
    final faces = ProfileFace.cacheFor(
      widget.connection,
      rosterTicket: _store.ticket,
      loader: widget.avatarLoader,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            strings.profileSwitcherTitle,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: colors.textPrimary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            strings.profileSwitcherBody,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ),
        if (profiles.isEmpty && _reading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: ConsoleLoader.medium()),
          ),
        if (profiles.isEmpty && _failed)
          HermesListRow(
            key: const ValueKey('profile-switcher-retry'),
            icon: Icons.refresh_rounded,
            title: strings.profileSwitcherLoadFailed,
            onTap: _read,
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final profile in profiles)
                HermesListRow(
                  key: ValueKey('profile-switcher-option-${profile.name}'),
                  leading: _profileFace(
                    _ownerOf(profile),
                    profile,
                    cache: faces,
                    active: _ownerOf(profile) == active,
                    locked: widget.facesLocked,
                  ),
                  title: profileDisplayLabel(strings, profile),
                  subtitle:
                      profileDisplayLabel(strings, profile) == profile.name
                      ? null
                      : profile.name,
                  selected: _ownerOf(profile) == active,
                  trailing: _ownerOf(profile) == active
                      ? Icon(Icons.check_rounded, color: colors.accent)
                      : null,
                  onTap: () => _pick(profile),
                ),
            ],
          ),
        ),
        if (widget.onManage != null)
          HermesListRow(
            key: const ValueKey('profile-switcher-manage'),
            icon: Icons.tune_rounded,
            title: strings.profileSwitcherManage,
            onTap: widget.onManage,
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}
