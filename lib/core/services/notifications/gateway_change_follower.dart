// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:clock/clock.dart';

import '../tui_gateway_client.dart';

/// Follows one change signal of the gateway socket the background listener
/// already keeps open, the way Hermes Desktop demotes its polls once the
/// backend announces `change_events` on `gateway.ready`
/// (`apps/desktop/src/app/contrib/hooks/use-background-sync.ts`: a
/// `cron.changed` tick refreshes the cron list, the timer is only a slow
/// backstop, and a hidden window does not poll at all). The server
/// broadcasts these signals to every connected socket
/// (`tui_gateway/change_watcher.py` `_broadcast_watched_changes`), so the
/// listener's socket hears them without asking.
///
/// A read is due when the socket is not up or announces no change events
/// (an older server: every tick, as before), when the signal or a link edge
/// (lost, redialled: whatever was broadcast meanwhile is gone) came after
/// the last read, when the last read happened without a live socket, or
/// after [backstop].
class GatewayChangeFollower {
  GatewayChangeFollower({required this.eventType, required this.backstop});

  /// The global event this follower listens for (`cron.changed`, …).
  final String eventType;
  final Duration backstop;
  final Map<String, _ChangeWatch> _watches = {};

  /// Whether [key] has to be read now. [client] is the socket that would
  /// carry the signal; null when the listener holds none for it.
  bool needsRead(String key, TuiGatewayClient? client) {
    final watch = _watchFor(key, client);
    if (watch == null || !_live(client!)) return true;
    final readAt = watch.readAt;
    if (watch.dirty || !watch.readWhileLive || readAt == null) return true;
    return clock.now().difference(readAt) >= backstop;
  }

  /// A read of [key] starts now: a signal from here on is past it.
  void reading(String key, TuiGatewayClient? client) {
    final watch = _watchFor(key, client);
    if (watch == null) return;
    watch
      ..dirty = false
      ..readAt = clock.now()
      ..readWhileLive = _live(client!);
  }

  /// The read of [key] failed: the next tick reads again.
  void readFailed(String key) => _watches[key]?.dirty = true;

  /// Stops following every key not in [keys].
  void retain(Set<String> keys) {
    for (final key in _watches.keys.toList()) {
      if (!keys.contains(key)) _watches.remove(key)!.cancel();
    }
  }

  void close() => retain(const {});

  static bool _live(TuiGatewayClient client) =>
      !client.isClosed && client.isConnected && client.changeEventsAvailable;

  _ChangeWatch? _watchFor(String key, TuiGatewayClient? client) {
    final current = _watches[key];
    if (client == null || client.isClosed) {
      _watches.remove(key)?.cancel();
      return null;
    }
    if (current != null && identical(current.client, client)) return current;
    current?.cancel();
    final watch = _ChangeWatch(client);
    watch.subscription = client.events.listen(
      (event) {
        if (event.type == eventType) watch.dirty = true;
      },
      // A dropped socket: what it would have carried is lost.
      onError: (Object _) => watch.dirty = true,
    );
    client.linkListenable.addListener(watch.onLinkEdge);
    return _watches[key] = watch;
  }
}

class _ChangeWatch {
  _ChangeWatch(this.client);

  final TuiGatewayClient client;
  StreamSubscription<TuiGatewayEvent>? subscription;

  /// Never read on this socket yet.
  bool dirty = true;
  DateTime? readAt;
  bool readWhileLive = false;

  void onLinkEdge() => dirty = true;

  void cancel() {
    client.linkListenable.removeListener(onLinkEdge);
    unawaited(subscription?.cancel());
    subscription = null;
  }
}
