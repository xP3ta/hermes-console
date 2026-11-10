import 'dart:async';

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

  /// The socket never reached `ready` on this client and its first dials are
  /// failing: a cold start against a slow server or a network not yet
  /// validated. Nothing was lost, so it is not a reconnect.
  connecting,
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

/// A socket that also remembers whether it ever reached `ready`. A failing
/// dial before that is `connecting`, not `reconnecting`. Optional, like
/// [ServerStartingLinkSource]: a source without it counts as having been up.
abstract interface class LinkHistorySource {
  bool get linkHasBeenUp;
}

/// Pure derivation. A ready socket is `connected` whatever REST says; REST
/// only tells «no server» from «reconnecting» while the socket is down.
/// [linkHasBeenUp] false turns a plain `reconnecting` into `connecting`: the
/// first dials of a socket that never was up are a start, not a loss.
ConnectionStatus deriveConnectionStatus({
  required bool socketReady,
  required bool authRejected,
  required bool networkLost,
  bool serverStarting = false,
  bool? restReachable,
  bool linkHasBeenUp = true,
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
      : linkHasBeenUp
      ? ConnectionStatusKind.reconnecting
      : ConnectionStatusKind.connecting;
  return ConnectionStatus(kind, attempt: attempt, nextAt: nextAt, since: since);
}

/// Single source of the connection state: one status per connection, derived
/// from the socket of its chat lane (and that socket's single owner, N3). The
/// REST probe is auxiliary and can never say «connected» over a down socket.
/// `current` is null while no socket proves anything (nothing dialled, parked,
/// closed): screens then fall back to their own REST probe.
///
/// A loss whose first redial is still running is not published for
/// [quietWindow]: the screens without their own grace (Home, the drawer, the
/// list header) keep the last good state, and only a redial that is taking
/// longer, a second failed attempt, or a real failure (credential refused,
/// no network, no server, server booting) changes the word. [currentRaw]
/// bypasses the window for the chat, which has its own grace.
class ConnectionStatusRegistry {
  ConnectionStatusRegistry({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _changes.onListenersChanged = _onListenersChanged;
  }

  static final ConnectionStatusRegistry instance = ConnectionStatusRegistry();

  /// How long a first redial may run before its loss is shown. The usual
  /// redial (jitter, ticket, upgrade, `ready`) ends well inside it.
  static const quietWindow = Duration(seconds: 2, milliseconds: 500);

  final DateTime Function() _clock;
  final Map<String, Set<ConnectionLinkSource>> _sources = {};
  final Map<String, ConnectionStatus?> _current = {};
  final Map<String, ConnectionStatus?> _raw = {};
  final Map<String, bool> _rest = {};
  final Map<String, DateTime> _downSince = {};
  final Map<String, Timer> _quietTimers = {};

  /// Connections whose quiet window already ran out (its timer fired): the
  /// loss is shown from then on, whatever the clock says.
  final Set<String> _quietSpent = {};
  final ConnectionSignal _changes = ConnectionSignal();
  bool _networkLost = false;

  /// Fires when any connection's status (published or raw) changes.
  Listenable get changes => _changes;

  /// The status every screen shows: the derived one, except inside the quiet
  /// window of a fresh loss, where it stays what it was (connected, or null
  /// when nothing had proven anything yet).
  ConnectionStatus? current(String connectionId) {
    // With nobody listening no timer ends the window: a read settles it
    // (nobody is notified, so a read during a build is safe).
    if (!_changes.hasListeners && _inQuietWindow(connectionId)) {
      _recompute(connectionId);
    }
    return _current[connectionId];
  }

  bool _inQuietWindow(String connectionId) {
    final raw = _raw[connectionId];
    return raw != null && !raw.isConnected && _current[connectionId] != raw;
  }

  /// The window's timer only exists to repaint a listener: without one it
  /// is not armed (a disposed screen leaves nothing pending), and the first
  /// listener to arrive settles the windows that were left open.
  void _onListenersChanged(bool hasListeners) {
    if (hasListeners) {
      // Not inside addListener (a screen subscribes while it builds).
      scheduleMicrotask(() {
        if (!_changes.hasListeners) return;
        for (final id in _raw.keys.toList()) {
          if (_inQuietWindow(id)) _recompute(id);
        }
      });
      return;
    }
    for (final timer in _quietTimers.values) {
      timer.cancel();
    }
    _quietTimers.clear();
  }

  /// The derived status without the quiet window, for a consumer with its
  /// own grace (the chat's connection row).
  ConnectionStatus? currentRaw(String connectionId) => _raw[connectionId];

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
    final now = _clock();
    ConnectionStatus? raw;
    if (sources.any((source) => source.isConnected)) {
      raw = const ConnectionStatus(ConnectionStatusKind.connected);
    } else {
      final down = sources.where(
        (source) =>
            !source.linkParked &&
            (source.linkAuthRejected || source.linkReconnectAt != null),
      );
      if (down.isNotEmpty) {
        final first = down.first;
        final since = _downSince[connectionId] ??= now;
        raw = deriveConnectionStatus(
          socketReady: false,
          authRejected: down.every((source) => source.linkAuthRejected),
          networkLost: _networkLost,
          serverStarting: down.any(
            (source) =>
                source is ServerStartingLinkSource &&
                (source as ServerStartingLinkSource).linkServerStarting,
          ),
          restReachable: _rest[connectionId],
          linkHasBeenUp: down.any(
            (source) =>
                source is! LinkHistorySource ||
                (source as LinkHistorySource).linkHasBeenUp,
          ),
          attempt: first.linkReconnectAttempt,
          nextAt: first.linkReconnectAt,
          since: since,
        );
      }
    }
    if (raw == null || raw.isConnected) {
      _downSince.remove(connectionId);
      _quietSpent.remove(connectionId);
    }
    final rawChanged = _raw[connectionId] != raw;
    _raw[connectionId] = raw;

    ConnectionStatus? next = raw;
    final previous = _current[connectionId];
    if (raw != null && !raw.isConnected) {
      final elapsed = now.difference(_downSince[connectionId] ?? now);
      final remaining = quietWindow - elapsed;
      final quiet =
          (previous == null || previous.isConnected) &&
          _isQuietKind(raw.kind) &&
          raw.attempt <= 1 &&
          !_quietSpent.contains(connectionId) &&
          remaining > Duration.zero;
      if (quiet) {
        next = previous;
        if (_changes.hasListeners) {
          _quietTimers[connectionId] ??= Timer(remaining, () {
            _quietTimers.remove(connectionId);
            _quietSpent.add(connectionId);
            _recompute(connectionId);
          });
        }
      }
    }
    if (next != previous || raw == null || raw.isConnected) {
      _quietTimers.remove(connectionId)?.cancel();
    }
    if (previous == next) {
      if (rawChanged) _changes.notify();
      return;
    }
    _current[connectionId] = next;
    _changes.notify();
  }

  /// Only a plain redial is quiet; every other state is a fact the user
  /// should see at once.
  static bool _isQuietKind(ConnectionStatusKind kind) =>
      kind == ConnectionStatusKind.reconnecting ||
      kind == ConnectionStatusKind.connecting;

  @visibleForTesting
  void reset() {
    for (final timer in _quietTimers.values) {
      timer.cancel();
    }
    _quietTimers.clear();
    _quietSpent.clear();
    _sources.clear();
    _current.clear();
    _raw.clear();
    _rest.clear();
    _downSince.clear();
    _networkLost = false;
  }
}

/// Minimal [Listenable] with nothing to dispose (it holds no resources).
final class ConnectionSignal implements Listenable {
  final Set<VoidCallback> _listeners = <VoidCallback>{};

  /// Fires with `true` when the first listener arrives and with `false`
  /// when the last one leaves.
  void Function(bool hasListeners)? onListenersChanged;

  bool get hasListeners => _listeners.isNotEmpty;

  @override
  void addListener(VoidCallback listener) {
    final wasEmpty = _listeners.isEmpty;
    _listeners.add(listener);
    if (wasEmpty && _listeners.isNotEmpty) onListenersChanged?.call(true);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_listeners.remove(listener) && _listeners.isEmpty) {
      onListenersChanged?.call(false);
    }
  }

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
      ConnectionStatusKind.connecting => s.qrcConnecting,
    };
