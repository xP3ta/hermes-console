// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io' show WebSocketException;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../../models/kanban.dart';
import '../connection_manager.dart';
import '../kanban_client.dart';

/// Opens the `task_events` stream of a board from [since], calling [onOpen]
/// once the socket is up.
typedef KanbanEventsOpen =
    Stream<KanbanEvent> Function(
      SavedConnection connection,
      DashboardClient dashboard, {
      required int since,
      required String? board,
      required void Function() onOpen,
    });

/// Follows a board's `task_events` the way Desktop's Kanban plugin does
/// (`apps/desktop/src/plugins/kanban/api.ts`: one
/// `/api/plugins/kanban/events?since=` socket per board, opened at the
/// snapshot's `latest_event_id`; a frame is what makes the board stale). The
/// background listener then reads the whole board only when something moved
/// since its last read, instead of on every tick.
///
/// The board must be read when no socket is up (first tick, a dropped
/// socket, a server without the route), when an event past the last read
/// arrived, or after [backstop] (Desktop keeps its board poll as the
/// fallback of the socket; this is that fallback, slower).
class KanbanEventsFollower {
  KanbanEventsFollower({
    KanbanEventsOpen? open,
    this.backstop = const Duration(minutes: 10),
  }) : _open = open ?? _kanbanClientEvents;

  static Stream<KanbanEvent> _kanbanClientEvents(
    SavedConnection connection,
    DashboardClient dashboard, {
    required int since,
    required String? board,
    required void Function() onOpen,
  }) => KanbanClient(
    connection,
    dashboardClient: dashboard,
  ).events(since: since, board: board, onOpen: onOpen);

  final KanbanEventsOpen _open;
  final Duration backstop;
  final Map<String, _Follow> _follows = {};

  /// Whether the board of [key] (connection and board) has to be read now.
  bool needsRead(String key) {
    final follow = _follows[key];
    if (follow == null || !follow.live) return true;
    final readAt = follow.readAt;
    if (readAt == null || clock.now().difference(readAt) >= backstop) {
      return true;
    }
    return follow.seen > follow.readEventId;
  }

  /// The board of [key] was just read at [latestEventId]: from now on an
  /// event past it is what makes it stale. Opens the stream at that cursor
  /// when none is open; a server that refuses the upgrade (no such route)
  /// keeps the plain read on every tick, asking again after [backstop].
  void boardRead(
    String key, {
    required SavedConnection connection,
    required DashboardClient dashboard,
    required String? board,
    required int latestEventId,
  }) {
    final follow = _follows[key] ??= _Follow();
    follow.readEventId = latestEventId;
    follow.readAt = clock.now();
    if (follow.seen < latestEventId) follow.seen = latestEventId;
    if (follow.subscription != null) return;
    final refusedAt = follow.refusedAt;
    if (refusedAt != null && clock.now().difference(refusedAt) < backstop) {
      return;
    }
    final generation = ++follow.generation;
    bool current() => follow.generation == generation;
    follow.subscription =
        _open(
          connection,
          dashboard,
          since: latestEventId,
          board: board,
          onOpen: () {
            if (current()) follow.live = true;
          },
        ).listen(
          (event) {
            if (!current()) return;
            if (event.id > follow.seen) {
              follow.seen = event.id;
            } else if (follow.seen <= follow.readEventId) {
              // An event without a usable id still says the board moved.
              follow.seen = follow.readEventId + 1;
            }
          },
          onError: (Object error) {
            if (!current()) return;
            // An unknown socket path is answered 403 or 404.
            if (_refusedUpgrade(error)) follow.refusedAt = clock.now();
            if (kDebugMode) {
              debugPrint('[hermes-notif] kanban events (${error.runtimeType})');
            }
            follow.drop();
          },
          onDone: () {
            if (current()) follow.drop();
          },
          cancelOnError: true,
        );
  }

  static bool _refusedUpgrade(Object error) {
    final status = error is WebSocketException ? error.httpStatusCode : null;
    return status == 403 || status == 404;
  }

  /// Closes the streams of every key not in [keys].
  void retain(Set<String> keys) {
    for (final key in _follows.keys.toList()) {
      if (!keys.contains(key)) _follows.remove(key)!.drop();
    }
  }

  void close() => retain(const {});
}

class _Follow {
  StreamSubscription<KanbanEvent>? subscription;
  int generation = 0;

  /// The socket is up: until it ends, no event means nothing moved.
  bool live = false;

  /// When the server last refused the upgrade.
  DateTime? refusedAt;

  /// `latest_event_id` of the last board read, and when it happened.
  int readEventId = 0;
  DateTime? readAt;

  /// Highest event id the stream delivered.
  int seen = 0;

  void drop() {
    generation++;
    live = false;
    unawaited(subscription?.cancel());
    subscription = null;
  }
}
