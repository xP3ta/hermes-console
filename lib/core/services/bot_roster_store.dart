import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/agent_profile.dart';
import '../models/connection.dart';
import 'bot_roster_cache.dart';

/// One connection's bot roster as last accepted by [BotRosterRegistry].
@immutable
final class BotRosterSnapshot {
  final String label;
  final List<AgentProfile> profiles;

  /// Order stamp of the read or mutation that produced it; 0 when restored
  /// from the offline cache (any live read wins over it).
  final int ticket;
  final bool fromCache;

  const BotRosterSnapshot({
    required this.label,
    required this.profiles,
    required this.ticket,
    required this.fromCache,
  });
}

/// Shared roster of one connection. Screens listen to it instead of keeping
/// their own copy, so a bot created, renamed or deleted on one screen shows
/// up on every other screen in the same frame.
final class BotRosterStore extends ChangeNotifier {
  BotRosterStore._(this.connectionId);

  final String connectionId;
  BotRosterSnapshot? _snapshot;

  BotRosterSnapshot? get snapshot => _snapshot;
  List<AgentProfile> get profiles => _snapshot?.profiles ?? const [];

  /// True once a server read (or a confirmed mutation) has landed; a
  /// cache-only snapshot is display data, not a live roster.
  bool get isLive => _snapshot != null && !_snapshot!.fromCache;
  int get ticket => _snapshot?.ticket ?? 0;

  AgentProfile? profile(String name) {
    for (final profile in profiles) {
      if (profile.name == name) return profile;
    }
    return null;
  }

  void _set(BotRosterSnapshot? snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }
}

/// Per-connection [BotRosterStore]s plus the ordering clock every reader
/// uses. It never reads the network itself: readers call [beginRead] before
/// their request and [publish] the result. A response is accepted only when
/// it started after the last accepted read or confirmed mutation and after
/// the connection was last forgotten, so a late, older response can never
/// overwrite newer data (same rule as Desktop's profile list epoch).
final class BotRosterRegistry extends ChangeNotifier {
  BotRosterRegistry();

  static final shared = BotRosterRegistry();

  int _clock = 0;
  final Map<String, BotRosterStore> _stores = {};
  final Map<String, int> _floor = {};
  final Map<String, SavedConnection> _connections = {};
  SharedPreferences? _prefs;

  /// Store for [connectionId], created empty on first use.
  BotRosterStore store(String connectionId) =>
      _stores.putIfAbsent(connectionId, () => BotRosterStore._(connectionId));

  /// Existing store, without creating one.
  BotRosterStore? peek(String connectionId) => _stores[connectionId];

  Iterable<BotRosterStore> get stores => _stores.values;

  /// Stamp for a read that is about to start. Pass it to [publish].
  int beginRead(String connectionId) => ++_clock;

  /// Lets accepted rosters persist through [BotRosterCache] and restores
  /// the cached roster of every connection that has nothing loaded yet.
  void attachPersistence(
    SharedPreferences prefs,
    Iterable<SavedConnection> connections,
  ) {
    _prefs = prefs;
    for (final connection in connections) {
      hydrate(connection);
    }
  }

  /// Registers [connection] for persistence and, when nothing is loaded for
  /// it yet, shows its cached roster (cold start).
  void hydrate(SavedConnection connection, {SharedPreferences? prefs}) {
    if (prefs != null) _prefs ??= prefs;
    _connections[connection.id] = connection;
    final store = this.store(connection.id);
    final storage = _prefs;
    if (store.snapshot != null || storage == null) return;
    final cached = BotRosterCache(storage).read(connection);
    if (cached.isEmpty) return;
    store._set(
      BotRosterSnapshot(
        label: connection.label,
        profiles: List.unmodifiable(cached),
        ticket: 0,
        fromCache: true,
      ),
    );
    notifyListeners();
  }

  /// Offers a server read. Returns false (and changes nothing) when a newer
  /// read or mutation already landed, or the connection was forgotten after
  /// the read started. Without [ticket] the roster counts as newest.
  bool publish(
    String connectionId,
    String label,
    List<AgentProfile> profiles, {
    int? ticket,
  }) {
    final stamp = ticket ?? ++_clock;
    final store = this.store(connectionId);
    if (stamp <= (_floor[connectionId] ?? 0) || stamp <= store.ticket) {
      return false;
    }
    _commit(store, label, profiles, stamp);
    return true;
  }

  /// Server confirmed a new profile: show it now, before the next read.
  void profileCreated(String connectionId, AgentProfile profile) =>
      _mutate(connectionId, (profiles) {
        if (profiles.any((p) => p.name == profile.name)) return null;
        return [...profiles, profile];
      });

  /// Server confirmed a rename.
  void profileRenamed(String connectionId, String from, String to) =>
      _mutate(connectionId, (profiles) {
        if (!profiles.any((p) => p.name == from)) return null;
        return [
          for (final p in profiles)
            if (p.name == from) _renamed(p, to) else if (p.name != to) p,
        ];
      });

  /// Server confirmed a deletion.
  void profileDeleted(String connectionId, String name) =>
      _mutate(connectionId, (profiles) {
        if (!profiles.any((p) => p.name == name)) return null;
        return [
          for (final p in profiles)
            if (p.name != name) p,
        ];
      });

  /// Drops the roster of a removed or re-pointed connection; reads that
  /// started before this can no longer publish.
  void forget(String connectionId) {
    _floor[connectionId] = ++_clock;
    // The endpoint may have changed: persist again only once a screen
    // registers the current connection through [hydrate].
    _connections.remove(connectionId);
    final store = _stores[connectionId];
    if (store?.snapshot != null) {
      store!._set(null);
      notifyListeners();
    }
  }

  /// Test reset; production code calls [forget] per connection.
  void clear() {
    for (final store in _stores.values) {
      store._set(null);
    }
    _floor.clear();
    _connections.clear();
    _prefs = null;
    notifyListeners();
  }

  /// A confirmed mutation outranks every read that started before it, even
  /// when nothing is loaded yet to edit.
  void _mutate(
    String connectionId,
    List<AgentProfile>? Function(List<AgentProfile>) edit,
  ) {
    final stamp = ++_clock;
    _floor[connectionId] = stamp;
    final store = this.store(connectionId);
    final current = store.snapshot;
    if (current == null) return;
    final next = edit(current.profiles);
    if (next == null) return;
    _commit(store, current.label, next, stamp, fromCache: current.fromCache);
  }

  void _commit(
    BotRosterStore store,
    String label,
    List<AgentProfile> profiles,
    int stamp, {
    bool fromCache = false,
  }) {
    final frozen = List<AgentProfile>.unmodifiable(profiles);
    store._set(
      BotRosterSnapshot(
        label: label,
        profiles: frozen,
        ticket: stamp,
        fromCache: fromCache,
      ),
    );
    notifyListeners();
    final prefs = _prefs;
    final connection = _connections[store.connectionId];
    if (prefs != null && connection != null) {
      // Storage failure must never hide a live roster.
      unawaited(
        BotRosterCache(
          prefs,
        ).write(connection, frozen).catchError((Object _) {}),
      );
    }
  }
}

AgentProfile _renamed(AgentProfile p, String name) => AgentProfile(
  name: name,
  path: p.path,
  isDefault: p.isDefault,
  model: p.model,
  provider: p.provider,
  hasEnv: p.hasEnv,
  skillCount: p.skillCount,
  gatewayRunning: p.gatewayRunning,
  description: p.description,
  displayName: p.displayName,
  // A handle equal to the old name was derived from it.
  mentionHandle: p.mentionHandle == p.name ? '' : p.mentionHandle,
  mentionTitle: p.mentionTitle,
  botChatSessionId: p.botChatSessionId,
  botModeUiMeta: p.botModeUiMeta,
  botModeMetadataPublished: p.botModeMetadataPublished,
  hasInvalidBotModeMetadata: p.hasInvalidBotModeMetadata,
  hasAvatar: p.hasAvatar,
  lastSession: p.lastSession,
  preferredSession: p.preferredSession,
  canonicalSession: p.canonicalSession,
  workerSession: p.workerSession,
  distributionName: p.distributionName,
  distributionVersion: p.distributionVersion,
  distributionSource: p.distributionSource,
  hasAlias: p.hasAlias,
  roomMirror: p.roomMirror,
  groupsProjection: p.groupsProjection,
);
