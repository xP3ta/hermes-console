import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/agent_profile.dart';
import '../models/connection.dart';
import 'bot_roster_cache.dart';
import 'connection_manager.dart' show DashboardHttpException;
import 'tui_gateway_client.dart' show TuiGatewayRpcError;

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
/// it started after the last accepted read and after the connection was last
/// forgotten, so a late, older response can never overwrite newer data (same
/// rule as Desktop's profile list epoch). Confirmed creations, renames and
/// deletions newer than an accepted read are replayed on it, so a read that
/// was on the wire during one can neither undo it nor be lost.
final class BotRosterRegistry extends ChangeNotifier {
  BotRosterRegistry({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final shared = BotRosterRegistry();

  /// Wall clock shared with the background monitor's isolate: it orders the
  /// writes both make to the persisted cache.
  final DateTime Function() _now;

  /// When each read still unanswered started.
  final Map<int, DateTime> _startedAt = {};

  int _clock = 0;
  final Map<String, BotRosterStore> _stores = {};
  final Map<String, int> _forgotAt = {};

  /// Ticket of the last accepted read.
  final Map<String, int> _lastRead = {};

  /// Confirmed mutations not yet covered by an accepted read, oldest first.
  final Map<String, List<_Mutation>> _pending = {};

  /// Ticket of the last read accepted for its session projections.
  final Map<String, int> _sessionsAt = {};
  final Map<String, SavedConnection> _connections = {};
  SharedPreferences? _prefs;

  /// Store for [connectionId], created empty on first use.
  BotRosterStore store(String connectionId) =>
      _stores.putIfAbsent(connectionId, () => BotRosterStore._(connectionId));

  /// Existing store, without creating one.
  BotRosterStore? peek(String connectionId) => _stores[connectionId];

  Iterable<BotRosterStore> get stores => _stores.values;

  /// Stamp for a read that is about to start. Pass it to [publish].
  int beginRead(String connectionId) {
    final ticket = ++_clock;
    _startedAt[ticket] = _now();
    return ticket;
  }

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
  ///
  /// [sessions] is the read's own `include_sessions`: only such a read is
  /// authoritative for session projections (a bot it reports with none is
  /// idle). Any other roster keeps each surviving bot's projections unless
  /// it carries its own. A with-sessions read that lost the roster race to
  /// a newer one without sessions still updates the projections, ordered by
  /// its own clock.
  bool publish(
    String connectionId,
    String label,
    List<AgentProfile> profiles, {
    int? ticket,
    bool sessions = false,
  }) {
    final stamp = ticket ?? ++_clock;
    final store = this.store(connectionId);
    if (stamp <= (_forgotAt[connectionId] ?? 0) ||
        stamp <= (_lastRead[connectionId] ?? 0)) {
      final current = store.snapshot;
      if (sessions &&
          current != null &&
          stamp > (_forgotAt[connectionId] ?? 0) &&
          stamp > (_sessionsAt[connectionId] ?? 0)) {
        _sessionsAt[connectionId] = stamp;
        _commit(
          store,
          current.label,
          _takeSessions(current.profiles, profiles),
          current.ticket,
          fromCache: current.fromCache,
          persist: false,
        );
      }
      return false;
    }
    _lastRead[connectionId] = stamp;
    if (sessions) _sessionsAt[connectionId] = stamp;
    var observedAt = _startedAt[stamp] ?? _now();
    _startedAt.removeWhere((ticket, _) => ticket <= stamp);
    // Mutations confirmed before the read started are already in it.
    final pending = _pending[connectionId]
      ?..removeWhere((m) => m.stamp < stamp);
    var next = profiles;
    for (final mutation in pending ?? const <_Mutation>[]) {
      next = mutation.edit(next) ?? next;
      if (mutation.at.isAfter(observedAt)) observedAt = mutation.at;
    }
    if (pending != null && pending.isEmpty) _pending.remove(connectionId);
    _commit(
      store,
      label,
      sessions ? next : _keepSessions(store.profiles, next),
      stamp > store.ticket ? stamp : store.ticket,
      observedAt: observedAt,
    );
    return true;
  }

  /// A roster that is not authoritative for sessions: each surviving bot
  /// keeps its previous projections unless this roster carries its own.
  static List<AgentProfile> _keepSessions(
    List<AgentProfile> previous,
    List<AgentProfile> incoming,
  ) {
    final byName = {for (final p in previous) p.name: p};
    return [
      for (final p in incoming)
        if (byName[p.name] case final old? when !_hasSessions(p))
          _copy(p, sessionsFrom: old)
        else
          p,
    ];
  }

  /// Projections of an authoritative with-sessions read applied to the bots
  /// it reports; bots it does not know keep theirs.
  static List<AgentProfile> _takeSessions(
    List<AgentProfile> current,
    List<AgentProfile> read,
  ) {
    final byName = {for (final p in read) p.name: p};
    return [
      for (final p in current)
        if (byName[p.name] case final fresh?)
          _copy(p, sessionsFrom: fresh)
        else
          p,
    ];
  }

  static bool _hasSessions(AgentProfile p) =>
      p.lastSession != null ||
      p.preferredSession != null ||
      p.canonicalSession != null ||
      p.workerSession != null;

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
            if (p.name == from) _copy(p, name: to) else if (p.name != to) p,
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

  /// [profiles] with every confirmed mutation not yet covered by an
  /// accepted read replayed on it, for a screen still showing a roster of
  /// its own (a cached one); the same list when none applies.
  List<AgentProfile> withPendingMutations(
    String connectionId,
    List<AgentProfile> profiles,
  ) {
    var next = profiles;
    for (final mutation in _pending[connectionId] ?? const <_Mutation>[]) {
      next = mutation.edit(next) ?? next;
    }
    return next;
  }

  /// True when [error] proves the server has no such route or method
  /// (`profiles.list` missing, Dashboard profile list missing), as opposed
  /// to a network, auth or transient failure.
  static bool isUnsupportedRead(Object? error) => switch (error) {
    TuiGatewayRpcError(:final code) =>
      code == -32601 || code == 404 || code == 405,
    DashboardHttpException(:final statusCode) =>
      statusCode == 404 || statusCode == 405,
    _ => false,
  };

  /// The read stamped [ticket] proved the server cannot list profiles at
  /// all. A cached roster was never confirmed by this server: it stops
  /// showing and leaves the persisted cache (Desktop starts empty too). A
  /// live roster, a newer accepted read or a later [forget] wins.
  void unsupported(String connectionId, {required int ticket}) {
    if (ticket <= (_forgotAt[connectionId] ?? 0) ||
        ticket <= (_lastRead[connectionId] ?? 0)) {
      return;
    }
    final store = _stores[connectionId];
    if (store == null || store.snapshot == null || store.isLive) return;
    store._set(null);
    notifyListeners();
    final prefs = _prefs;
    final connection = _connections[connectionId];
    if (prefs != null && connection != null) {
      unawaited(
        BotRosterCache(prefs).remove(connection).catchError((Object _) {}),
      );
    }
  }

  /// Drops the roster of a removed or re-pointed connection; reads that
  /// started before this can no longer publish.
  void forget(String connectionId) {
    _forgotAt[connectionId] = ++_clock;
    _pending.remove(connectionId);
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
    _forgotAt.clear();
    _lastRead.clear();
    _pending.clear();
    _startedAt.clear();
    _sessionsAt.clear();
    _connections.clear();
    _prefs = null;
    notifyListeners();
  }

  /// A confirmed mutation shows at once and is replayed on every read that
  /// started before it, even when nothing is loaded yet to edit.
  void _mutate(
    String connectionId,
    List<AgentProfile>? Function(List<AgentProfile>) edit,
  ) {
    final stamp = ++_clock;
    final at = _now();
    (_pending[connectionId] ??= []).add(_Mutation(stamp, at, edit));
    final store = this.store(connectionId);
    final current = store.snapshot;
    if (current == null) {
      // Nothing loaded: show the new bot now. The partial roster is display
      // only and never persisted; the read in flight completes it.
      final seeded = edit(const []);
      if (seeded == null || seeded.isEmpty) return;
      _commit(
        store,
        _connections[connectionId]?.label ?? '',
        seeded,
        stamp,
        fromCache: true,
        persist: false,
      );
      return;
    }
    final next = edit(current.profiles);
    if (next == null) return;
    _commit(
      store,
      current.label,
      next,
      stamp,
      fromCache: current.fromCache,
      observedAt: at,
    );
  }

  void _commit(
    BotRosterStore store,
    String label,
    List<AgentProfile> profiles,
    int stamp, {
    bool fromCache = false,
    bool persist = true,
    DateTime? observedAt,
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
    if (persist && prefs != null && connection != null) {
      // Storage failure must never hide a live roster.
      unawaited(
        BotRosterCache(prefs)
            .write(connection, frozen, observedAt: observedAt ?? _now())
            .catchError((Object _) {}),
      );
    }
  }
}

/// A confirmed create, rename or delete. [edit] returns null when it does
/// not apply (already there, or already gone), so replaying it is safe.
final class _Mutation {
  const _Mutation(this.stamp, this.at, this.edit);
  final int stamp;
  final DateTime at;
  final List<AgentProfile>? Function(List<AgentProfile>) edit;
}

AgentProfile _copy(AgentProfile p, {String? name, AgentProfile? sessionsFrom}) {
  final sessions = sessionsFrom ?? p;
  final renamed = name != null && name != p.name;
  return AgentProfile(
    name: name ?? p.name,
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
    mentionHandle: renamed && p.mentionHandle == p.name ? '' : p.mentionHandle,
    mentionTitle: p.mentionTitle,
    botChatSessionId: p.botChatSessionId,
    botModeUiMeta: p.botModeUiMeta,
    botModeMetadataPublished: p.botModeMetadataPublished,
    hasInvalidBotModeMetadata: p.hasInvalidBotModeMetadata,
    hasAvatar: p.hasAvatar,
    lastSession: sessions.lastSession,
    preferredSession: sessions.preferredSession,
    canonicalSession: sessions.canonicalSession,
    workerSession: sessions.workerSession,
    distributionName: p.distributionName,
    distributionVersion: p.distributionVersion,
    distributionSource: p.distributionSource,
    hasAlias: p.hasAlias,
    roomMirror: p.roomMirror,
    groupsProjection: p.groupsProjection,
  );
}
