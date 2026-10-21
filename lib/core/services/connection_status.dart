import 'package:flutter/foundation.dart';

import '../../l10n/app_localizations.dart';

/// What a connection is doing, as every screen says it (the Desktop status bar
/// reads the socket state the same way: `use-statusbar-items.tsx`).
enum ConnectionStatusKind {
  connected,
  reconnecting,
  noNetwork,
  authRequired,
  noServer,

  /// The Dashboard answers 502/503/504: it is booting (Desktop
  /// `backend-health.ts`), not refusing the credential.
  starting,
}

/// A reconnect that keeps failing this long earns one persistent notice
/// (Desktop `use-gateway-boot.ts`).
const connectionPersistentNoticeAfter = Duration(minutes: 5);

@immutable
final class ConnectionStatus {
  const ConnectionStatus(
    this.kind, {
    this.attempt = 0,
    this.nextAt,
    this.since,
  });

  final ConnectionStatusKind kind;

  /// Reconnect attempts made in this outage.
  final int attempt;

  /// When the owner redials next (null when connected or unknown).
  final DateTime? nextAt;

  /// When the connection stopped being `connected`.
  final DateTime? since;

  bool get isConnected => kind == ConnectionStatusKind.connected;

  /// Still failing after [connectionPersistentNoticeAfter].
  bool failingLong(DateTime now) =>
      !isConnected &&
      since != null &&
      now.difference(since!) >= connectionPersistentNoticeAfter;

  @override
  bool operator ==(Object other) =>
      other is ConnectionStatus &&
      other.kind == kind &&
      other.attempt == attempt &&
      other.nextAt == nextAt &&
      other.since == since;

  @override
  int get hashCode => Object.hash(kind, attempt, nextAt, since);
}

/// The socket of a connection's chat lane, as seen by the status registry.
/// Implemented by `TuiGatewayClient`.
abstract interface class ConnectionLinkSource {
  /// Fires on every socket edge (ready, lost, backoff scheduled, auth, close).
  Listenable get linkListenable;
  bool get isConnected;
  bool get isClosed;

  /// The Dashboard refused the credential on the last dial.
  bool get linkAuthRejected;

  /// End of the current backoff gap; null before the first loss.
  DateTime? get linkReconnectAt;
  int get linkReconnectAttempt;

  /// Deliberately parked while idle in the background: not an outage.
  bool get linkParked;
}

/// A socket that also knows its last ticket failed with 502/503/504. Kept
/// apart from [ConnectionLinkSource] so a source without the signal stays
/// valid.
abstract interface class ServerStartingLinkSource {
  bool get linkServerStarting;
}

/// Pure derivation. A ready socket is `connected` whatever REST says; REST
/// only tells «no server» from «reconnecting» while the socket is down.
ConnectionStatus deriveConnectionStatus({
  required bool socketReady,
  required bool authRejected,
  required bool networkLost,
  bool serverStarting = false,
  bool? restReachable,
  int attempt = 0,
  DateTime? nextAt,
  DateTime? since,
}) {
  if (socketReady) {
    return const ConnectionStatus(ConnectionStatusKind.connected);
  }
  final kind = authRejected
      ? ConnectionStatusKind.authRequired
      : networkLost
      ? ConnectionStatusKind.noNetwork
      : serverStarting
      ? ConnectionStatusKind.starting
      : restReachable == false
      ? ConnectionStatusKind.noServer
      : ConnectionStatusKind.reconnecting;
  return ConnectionStatus(kind, attempt: attempt, nextAt: nextAt, since: since);
}

/// Single source of the connection state: one status per connection, derived
/// from the socket of its chat lane (and that socket's single owner, N3). The
/// REST probe is auxiliary and can never say «connected» over a down socket.
/// `current` is null while no socket proves anything (nothing dialled, parked,
/// closed): screens then fall back to their own REST probe.
class ConnectionStatusRegistry {
  ConnectionStatusRegistry({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static final ConnectionStatusRegistry instance = ConnectionStatusRegistry();

  final DateTime Function() _clock;
  final Map<String, Set<ConnectionLinkSource>> _sources = {};
  final Map<String, ConnectionStatus?> _current = {};
  final Map<String, bool> _rest = {};
  final Map<String, DateTime> _downSince = {};
  final ConnectionSignal _changes = ConnectionSignal();
  bool _networkLost = false;

  /// Fires when any connection's status changes.
  Listenable get changes => _changes;

  ConnectionStatus? current(String connectionId) => _current[connectionId];

  void bind(String connectionId, ConnectionLinkSource source) {
    final sources = _sources.putIfAbsent(connectionId, () => {});
    if (!sources.add(source)) return;
    source.linkListenable.addListener(() => _recompute(connectionId));
    _recompute(connectionId);
  }

  /// The platform lost / regained its default network (`MainActivity`).
  void setNetworkLost(bool lost) {
    if (_networkLost == lost) return;
    _networkLost = lost;
    for (final id in _sources.keys.toList()) {
      _recompute(id);
    }
  }

  /// The auxiliary REST probe of [connectionId] answered.
  void reportRest(String connectionId, {required bool reachable}) {
    if (_rest[connectionId] == reachable) return;
    _rest[connectionId] = reachable;
    _recompute(connectionId);
  }

  void _recompute(String connectionId) {
    final sources = _sources[connectionId];
    if (sources == null) return;
    sources.removeWhere((source) => source.isClosed);
    ConnectionStatus? next;
    if (sources.any((source) => source.isConnected)) {
      next = const ConnectionStatus(ConnectionStatusKind.connected);
    } else {
      final down = sources.where(
        (source) =>
            !source.linkParked &&
            (source.linkAuthRejected || source.linkReconnectAt != null),
      );
      if (down.isNotEmpty) {
        final first = down.first;
        final since = _downSince[connectionId] ??= _clock();
        next = deriveConnectionStatus(
          socketReady: false,
          authRejected: down.every((source) => source.linkAuthRejected),
          networkLost: _networkLost,
          serverStarting: down.any(
            (source) =>
                source is ServerStartingLinkSource &&
                (source as ServerStartingLinkSource).linkServerStarting,
          ),
          restReachable: _rest[connectionId],
          attempt: first.linkReconnectAttempt,
          nextAt: first.linkReconnectAt,
          since: since,
        );
      }
    }
    if (next == null || next.isConnected) _downSince.remove(connectionId);
    if (_current[connectionId] == next) return;
    _current[connectionId] = next;
    _changes.notify();
  }

  @visibleForTesting
  void reset() {
    _sources.clear();
    _current.clear();
    _rest.clear();
    _downSince.clear();
    _networkLost = false;
  }
}

/// Minimal [Listenable] with nothing to dispose (it holds no resources).
final class ConnectionSignal implements Listenable {
  final Set<VoidCallback> _listeners = <VoidCallback>{};

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}

/// Shared wording for [kind] (title case; Desktop's five states).
String connectionStatusWord(Strings s, ConnectionStatusKind kind) =>
    switch (kind) {
      ConnectionStatusKind.connected => s.hwServerOnline,
      ConnectionStatusKind.reconnecting => s.islandReconnecting,
      ConnectionStatusKind.noNetwork => s.connStatusNoNetwork,
      ConnectionStatusKind.authRequired => s.connStatusAuthRequired,
      ConnectionStatusKind.noServer => s.connStatusNoServer,
      ConnectionStatusKind.starting => s.serverStartingTitle,
    };
