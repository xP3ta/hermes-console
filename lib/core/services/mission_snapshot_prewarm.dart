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
  }) : _cache = cache ?? MissionSnapshotCache.shared,
       _sourceFactory = sourceFactory ?? MissionControlRepository.forConnection;

  static final shared = MissionSnapshotPrewarm();

  final MissionSnapshotCache _cache;
  final MissionPrewarmSourceFactory _sourceFactory;
  final Duration idleDelay;

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
  void schedule({
    required SharedPreferences prefs,
    required SavedConnection connection,
    required bool Function() stillIdle,
  }) {
    final key = MissionSnapshotCache.keyOf(connection);
    if (_done.contains(key)) return;
    if (_timerKey == key && _timer != null) return;
    if (!wasOpened(prefs, connection.id)) return;
    if (_cache.read(connection) != null) return;
    cancel();
    _timerKey = key;
    _timer = Timer(idleDelay, () {
      _timer = null;
      _timerKey = null;
      if (!stillIdle()) return;
      _start(connection, key);
    });
  }

  void _start(SavedConnection connection, String key) {
    if (_done.contains(key) || _cache.read(connection) != null) return;
    _done.add(key);
    final source = _sourceFactory(connection);
    final warm = _Warm(key, source);
    _warm = warm;
    warm.future = source
        .load()
        .then((snapshot) {
          if (!warm.cancelled) _cache.write(connection, snapshot);
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
