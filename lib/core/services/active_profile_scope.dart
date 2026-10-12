import 'package:flutter/foundation.dart';

import 'connection_manager.dart';

/// The active profile of one connection: the single source every screen
/// reads (chats list, Home recents, model, SOUL, skills, memory…).
///
/// Like Desktop's profile rail, a profile is a whole workspace: switching it
/// re-scopes every per-profile surface of that connection. The value itself
/// stays persisted by [ConnectionManager] under `active_profile_<connId>`;
/// this class only adds one listenable, an epoch per switch and read tickets
/// so a read started for one profile never lands on another.
class ActiveProfileScope extends ChangeNotifier {
  ActiveProfileScope._(this._manager, this.connectionId)
    : _seen = _manager.activeProfileFor(connectionId) {
    _revision = _manager.activeProfileRevisionFor(connectionId)
      ..addListener(_sync);
  }

  static final Expando<Map<String, ActiveProfileScope>> _byManager =
      Expando<Map<String, ActiveProfileScope>>('ActiveProfileScope');

  /// The shared scope of [connectionId] on [manager]. One instance per pair,
  /// alive as long as the manager, so every screen listens to the same one.
  static ActiveProfileScope of(ConnectionManager manager, String connectionId) {
    final byConnection = _byManager[manager] ??= <String, ActiveProfileScope>{};
    return byConnection.putIfAbsent(
      connectionId,
      () => ActiveProfileScope._(manager, connectionId),
    );
  }

  final ConnectionManager _manager;
  final String connectionId;
  late final ValueListenable<int> _revision;
  String _seen;
  int _epoch = 0;

  /// Active profile name; empty means the default profile. Always read fresh
  /// from the persisted value, so a reader never sees a stale cache.
  String get name => _manager.activeProfileFor(connectionId);

  /// Canonical owner key (`default` for the default profile), the same key
  /// sessions and drafts carry.
  String get owner => Session.profileOwner(name);

  bool get isDefault => owner == 'default';

  /// Bumped on every switch. Reads compare it through [ProfileReadTicket].
  int get epoch => _epoch;

  /// Captures the profile a read is about to use.
  ProfileReadTicket capture() => ProfileReadTicket._(this, epoch, owner);

  /// Makes [profile] the active one (empty or `default` = default profile).
  Future<void> switchTo(String profile) =>
      _manager.setActiveProfile(connectionId, profile.trim());

  void _sync() {
    final fresh = _manager.activeProfileFor(connectionId);
    if (fresh == _seen) return;
    _seen = fresh;
    _epoch++;
    notifyListeners();
  }

  @override
  void dispose() {
    _revision.removeListener(_sync);
    super.dispose();
  }
}

/// The profile a read was started for. A late answer must check
/// [isCurrent] before it touches state: after a switch it belongs to the
/// previous profile and is dropped.
@immutable
class ProfileReadTicket {
  const ProfileReadTicket._(this._scope, this.epoch, this.owner);

  /// A read pinned to [profile] (a bot card opening its own settings): it
  /// does not follow the active profile, so a switch never voids it.
  ProfileReadTicket.fixed(String profile)
    : _scope = null,
      epoch = 0,
      owner = Session.profileOwner(profile);

  final ActiveProfileScope? _scope;
  final int epoch;
  final String owner;

  /// Profile name for wire calls (empty for the default profile).
  String get name => owner == 'default' ? '' : owner;

  bool get isCurrent {
    final scope = _scope;
    if (scope == null) return true;
    return scope.epoch == epoch && scope.owner == owner;
  }
}
