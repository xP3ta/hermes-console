import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection.dart';
import '../models/mission_control.dart';
import 'mission_control_repository.dart';
import 'mission_snapshot_cache.dart';

typedef MissionPrewarmSourceFactory =
    MissionControlDataSource Function(SavedConnection connection);

/// One background Bot Mode read per app process, so the first entry into Bot
/// Mode paints a roster instead of a cold "loading" state.
///
/// It only runs for a connection on which the user has opened Bot Mode
/// before (a plain boolean in preferences, no server data), after Home has
/// been idle for [idleDelay] in the foreground. The result goes to the
/// in-memory [MissionSnapshotCache] only; nothing is written to disk. Bot
/// Mode opened while the read is in flight reuses it ([claim]) instead of
/// starting a second one, and still refreshes once painted.
final class MissionSnapshotPrewarm {
  MissionSnapshotPrewarm({
    MissionSnapshotCache? cache,
    MissionPrewarmSourceFactory? sourceFactory,
    this.idleDelay = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _cache = cache ?? MissionSnapshotCache.shared,
       _sourceFactory = sourceFactory ?? MissionControlRepository.forConnection,
       _now = now ?? DateTime.now;

  static final shared = MissionSnapshotPrewarm();

  final MissionSnapshotCache _cache;
  final MissionPrewarmSourceFactory _sourceFactory;
  final Duration idleDelay;
  final DateTime Function() _now;

  /// Connections already warmed (or opened) in this process: never twice.
  final Set<String> _done = {};
  Timer? _timer;
  String? _timerKey;
  _Warm? _warm;

  static String flagKey(String connectionId) =>
      'mission_control_opened_v1.$connectionId';

  static bool wasOpened(SharedPreferences prefs, String connectionId) =>
      prefs.getBool(flagKey(connectionId)) == true;

  static Future<void> markOpened(
    SharedPreferences prefs,
    String connectionId,
  ) async {
    if (wasOpened(prefs, connectionId)) return;
    await prefs.setBool(flagKey(connectionId), true);
  }

  /// Arms the one-shot idle timer for [connection]. [stillIdle] is checked
  /// when it fires (foreground, Home on top, same connection).
  ///
  /// [homeNeedsIt]: the Home board has a Bots or Rooms widget, which paints
  /// from this read, so it must not wait for the user to open Bot Mode first.
  void schedule({
    required SharedPreferences prefs,
    required SavedConnection connection,
    required bool Function() stillIdle,
    bool homeNeedsIt = false,
  }) {
    final key = MissionSnapshotCache.keyOf(connection);
    if (_done.contains(key)) return;
    if (_timerKey == key && _timer != null) return;
    // Home calls this and then [refreshForHome] on every refresh: a read
    // already in flight for this connection must be left to finish, not
    // cancelled and relaunched (a slow server would never complete).
    if (_liveFor(key)) return;
    if (!homeNeedsIt && !wasOpened(prefs, connection.id)) return;
    if (_cache.read(connection) != null) return;
    // One limiter for both paths: a read started (or failed) less than
    // [homeReadMinAge] ago is not retried by the idle timer either.
    if (_recentlyRead(key, _now())) return;
    cancel();
    _timerKey = key;
    _timer = Timer(idleDelay, () {
      _timer = null;
      _timerKey = null;
      if (!stillIdle()) return;
      _start(connection, key);
    });
  }

  /// Last read started per connection (idle timer or Home, success or
  /// not), so the board's ~10 s refresh cadence never turns into a read
  /// every 10 s, whichever path asks.
  final Map<String, DateTime> _readAt = {};

  /// The longest a read waits before the next one.
  static const homeReadMinAge = Duration(minutes: 1);

  /// Home paints its Bots and Rooms widgets from this read and never made
  /// one itself, so they stayed a placeholder until Bot Mode was visited.
  /// Reads Bot Mode now for [connection] unless a snapshot younger than
  /// [minAge] is already cached, a read is in flight, or one was started
  /// less than [minAge] ago. Writes the in-memory cache only.
  void refreshForHome({
    required SavedConnection connection,
    Duration minAge = homeReadMinAge,
    DateTime Function()? now,
  }) {
    final key = MissionSnapshotCache.keyOf(connection);
    final clock = (now ?? _now)();
    if (_liveFor(key)) return;
    final cached = _cache.read(connection);
    if (cached != null && clock.difference(cached.loadedAt) < minAge) return;
    if (_recentlyRead(key, clock, minAge)) return;
    if (_timerKey == key) {
      _timer?.cancel();
      _timer = null;
      _timerKey = null;
    }
    _begin(connection, key, clock);
  }

  bool _liveFor(String key) {
    final warm = _warm;
    return warm != null && warm.key == key && !warm.cancelled;
  }

  bool _recentlyRead(
    String key,
    DateTime clock, [
    Duration minAge = homeReadMinAge,
  ]) {
    final last = _readAt[key];
    return last != null && clock.difference(last) < minAge;
  }

  void _start(SavedConnection connection, String key) {
    if (_done.contains(key) || _cache.read(connection) != null) return;
    if (_liveFor(key)) return;
    final clock = _now();
    if (_recentlyRead(key, clock)) return;
    _begin(connection, key, clock);
  }

  void _begin(SavedConnection connection, String key, DateTime clock) {
    _readAt[key] = clock;
    final source = _sourceFactory(connection);
    final warm = _Warm(key, source);
    _warm = warm;
    warm.future = source
        .load()
        .then((snapshot) {
          if (!warm.cancelled) {
            _cache.write(connection, snapshot);
            // Only a read that landed counts as "warmed": a failure or a
            // cancellation (app to background) leaves the next try open.
            _done.add(key);
          }
          return snapshot;
        })
        .whenComplete(() {
          source.close();
          if (identical(_warm, warm)) _warm = null;
        });
    // An unclaimed failure is simply dropped; Bot Mode reads again on open.
    unawaited(warm.future.then((_) {}, onError: (_) {}));
  }

  /// Bot Mode is opening on [connection]: stop any pending timer and hand
  /// over the in-flight read, if any, so it is not issued twice.
  Future<MissionBackendSnapshot>? claim(SavedConnection connection) {
    final key = MissionSnapshotCache.keyOf(connection);
    _done.add(key);
    if (_timerKey == key) {
      _timer?.cancel();
      _timer = null;
      _timerKey = null;
    }
    final warm = _warm;
    if (warm == null || warm.key != key || warm.cancelled) return null;
    warm.claimed = true;
    return warm.future;
  }

  /// App went to background or the active connection changed.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _timerKey = null;
    final warm = _warm;
    if (warm == null || warm.claimed) return;
    warm.cancelled = true;
    _warm = null;
    // A cancelled read is not a read: the next Home refresh may retry now.
    _readAt.remove(warm.key);
    warm.source.close();
  }
}

final class _Warm {
  _Warm(this.key, this.source);
  final String key;
  final MissionControlDataSource source;
  late final Future<MissionBackendSnapshot> future;
  bool claimed = false;
  bool cancelled = false;
}
