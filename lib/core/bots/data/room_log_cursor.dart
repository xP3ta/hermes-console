import 'dart:async';

import '../../models/hosted_groups.dart';

/// Reads one `groups.log` page after [sinceSeq] (contract `GroupsLogParams`).
typedef RoomLogPageLoader =
    Future<HostedGroupLogPage> Function({
      required int sinceSeq,
      required int limit,
    });

/// Result of one [RoomLogCursor.pull].
final class RoomLogDelta {
  /// Events new since the previous pull, in sequence order.
  final List<HostedGroupEvent> added;

  /// The accumulated, gap-free log after this pull.
  final HostedGroupLogPage log;

  /// True when the authority rotated or the log rewound and the cursor
  /// restarted from sequence 0 (callers must replace, not append).
  final bool reset;

  const RoomLogDelta({
    required this.added,
    required this.log,
    required this.reset,
  });

  bool get changed => reset || added.isNotEmpty;
}

/// Incremental reader for one hosted room log.
///
/// The first pull pages from `since_seq = 0` until `has_more == false`; later
/// pulls only ask for `since_seq = cursor`, so a quiet room costs one tiny
/// frame instead of re-reading the whole transcript on every tick (#46).
final class RoomLogCursor {
  final String roomId;
  final RoomLogPageLoader load;
  final int pageLimit;
  final int maxPagesPerPull;
  final int maxEvents;

  HostedGroupLogPage? _log;
  Future<RoomLogDelta>? _flight;

  /// [initial] resumes from a log this client already read (e.g. the last
  /// snapshot of a screen that was closed): the first pull asks only for
  /// `since_seq = initial.cursor`. A rotated authority or rewound log still
  /// restarts from zero, exactly like a live cursor.
  RoomLogCursor({
    required this.roomId,
    required this.load,
    this.pageLimit = 100,
    this.maxPagesPerPull = 64,
    this.maxEvents = 2000,
    HostedGroupLogPage? initial,
  }) : _log = initial;

  HostedGroupLogPage? get log => _log;

  /// Highest sequence already applied (0 before the first pull).
  int get cursor => _log?.cursor ?? 0;

  /// Concurrent callers share one in-flight read.
  Future<RoomLogDelta> pull() => _flight ??= _pull().whenComplete(() {
    _flight = null;
  });

  void reset() => _log = null;

  Future<RoomLogDelta> _pull() async {
    final previous = _log;
    try {
      final delta = await _readFrom(previous);
      return delta;
    } on FormatException {
      if (previous == null) rethrow;
      // Authority takeover or a rewound log invalidates the prefix: restart
      // once from zero instead of splicing two histories together.
      _log = null;
      final fresh = await _readFrom(null);
      return RoomLogDelta(added: fresh.added, log: fresh.log, reset: true);
    }
  }

  Future<RoomLogDelta> _readFrom(HostedGroupLogPage? previous) async {
    var accumulated = previous;
    final added = <HostedGroupEvent>[];
    var since = previous?.cursor ?? 0;
    for (var page = 0; page < maxPagesPerPull; page++) {
      final result = await load(sinceSeq: since, limit: pageLimit);
      if (accumulated != null && result.latestSeq < accumulated.latestSeq) {
        throw const FormatException('room log rewound');
      }
      accumulated = accumulated == null
          ? HostedGroupLogPage.append(
              _emptyLike(result),
              result,
              maxEvents: maxEvents,
            )
          : HostedGroupLogPage.append(
              accumulated,
              result,
              maxEvents: maxEvents,
            );
      added.addAll(result.events);
      if (!result.hasMore) break;
      if (result.cursor <= since) {
        throw const FormatException('non-advancing log continuation');
      }
      since = result.cursor;
    }
    _log = accumulated;
    return RoomLogDelta(
      added: List.unmodifiable(added),
      log: accumulated!,
      reset: false,
    );
  }

  static HostedGroupLogPage _emptyLike(HostedGroupLogPage page) =>
      HostedGroupLogPage.fromJson(
        {
          'events': const <Object?>[],
          'cursor': 0,
          'latest_seq': 0,
          'has_more': false,
          'authority': {
            'gateway_id': page.authority.gatewayId,
            'epoch': page.authority.epoch,
          },
        },
        expectedRoomId: '_',
        sinceSeq: 0,
      );
}

/// Poll cadence for a visible room: 3 s while the driver works or the log
/// just changed, doubling to a 15 s ceiling while idle (plan.md § Rules).
final class RoomPollBackoff {
  final Duration fast;
  final Duration slow;
  Duration _current;

  RoomPollBackoff({
    this.fast = const Duration(seconds: 3),
    this.slow = const Duration(seconds: 15),
  }) : _current = fast;

  Duration get current => _current;

  Duration next({required bool working, required bool changed}) {
    if (working || changed) {
      _current = fast;
    } else {
      final doubled = _current * 2;
      _current = doubled > slow ? slow : doubled;
    }
    return _current;
  }

  void resetFast() => _current = fast;
}

typedef RoomPollTimerFactory =
    Timer Function(Duration delay, void Function() callback);

/// Drives a [RoomLogCursor] only while the room is visible and the app is in
/// the foreground. Paused pollers hold no timer.
final class RoomLogPoller {
  final Future<({RoomLogDelta delta, bool working})> Function() tick;
  final void Function(RoomLogDelta delta)? onDelta;
  final void Function(Object error)? onError;
  final RoomPollBackoff backoff;
  final RoomPollTimerFactory _timer;

  Timer? _pending;
  bool _visible = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _running = false;

  RoomLogPoller({
    required this.tick,
    this.onDelta,
    this.onError,
    RoomPollBackoff? backoff,
    RoomPollTimerFactory? timer,
  }) : backoff = backoff ?? RoomPollBackoff(),
       _timer = timer ?? Timer.new;

  bool get isScheduled => _pending != null;
  bool get active => _visible && _foreground && !_disposed;

  void setVisible(bool visible) {
    _visible = visible;
    _reschedule(immediate: visible);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    _reschedule(immediate: foreground);
  }

  void _reschedule({required bool immediate}) {
    _pending?.cancel();
    _pending = null;
    if (!active) return;
    if (immediate) backoff.resetFast();
    _pending = _timer(immediate ? Duration.zero : backoff.current, _fire);
  }

  Future<void> _fire() async {
    _pending = null;
    if (!active || _running) return;
    _running = true;
    var working = false;
    var changed = false;
    try {
      final result = await tick();
      working = result.working;
      changed = result.delta.changed;
      if (changed) onDelta?.call(result.delta);
    } catch (error) {
      onError?.call(error);
    } finally {
      _running = false;
    }
    if (!active) return;
    _pending = _timer(backoff.next(working: working, changed: changed), _fire);
  }

  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _pending = null;
  }
}
