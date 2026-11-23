import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How much the app talks to its Hermes server, kept on the phone only.
///
/// Per hour and split by whether the app was on screen: requests and body
/// bytes per route (the route's shape only: `GET /api/sessions/:id/messages`),
/// WebSocket messages and bytes, connections, reconnections and how often a
/// conversation was read again from the server. No address, no identifier,
/// no query string, no header and no content is ever kept: a path segment
/// that is not a fixed word of the API is written `:id`.
///
/// It leaves the phone only inside the diagnostic report the user exports
/// by hand (Settings › Diagnostics), where it can be read before sharing.
///
/// What it counts is what crosses [OriginBoundHttpClient] (every REST call
/// to a Hermes server) and the gateway and Kanban WebSockets. Bytes are
/// those of bodies as the app reads and writes them: headers, TLS and
/// compression on the wire are not in them.
final class TrafficCounter {
  TrafficCounter._();

  static final TrafficCounter instance = TrafficCounter._();

  /// Hours kept. Older ones are dropped as new ones start.
  static const int windowHours = 48;

  /// Distinct routes kept per hour and side; the rest add up under [other].
  static const int maxRoutes = 24;
  static const String other = 'other';

  static const String _prefsKeyApp = 'traffic_counter_v1.app';
  static const String _prefsKeyService = 'traffic_counter_v1.service';

  /// Counts are written at most this often while traffic goes on, and when
  /// the app leaves the screen.
  static const Duration _saveEvery = Duration(minutes: 2);

  SharedPreferences? _prefs;
  bool _service = false;
  bool _foreground = false;
  DateTime Function() _now = DateTime.now;
  DateTime? _savedAt;
  bool _dirty = false;

  final Map<int, TrafficHour> _hours = {};
  final TrafficSide _launchForeground = TrafficSide();
  final TrafficSide _launchBackground = TrafficSide();
  DateTime? _launchedAt;

  /// Where the counts are kept between runs. The notification service runs
  /// in its own isolate and keeps its own counts ([service]), always as
  /// background traffic.
  void attach(SharedPreferences prefs, {bool service = false}) {
    _prefs = prefs;
    _service = service;
    _launchedAt ??= _now();
    try {
      final raw = prefs.getString(service ? _prefsKeyService : _prefsKeyApp);
      if (raw != null) _merge(_hours, _decode(raw));
    } catch (_) {
      // Unreadable counts are counts lost, nothing else.
    }
    _prune();
  }

  /// The app is on screen (false: in the background, or the service).
  set foreground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (!value) save();
  }

  bool get foreground => _foreground && !_service;

  TrafficSide get _launchSide =>
      foreground ? _launchForeground : _launchBackground;

  TrafficSide _side() {
    _launchedAt ??= _now();
    final hour = _now().millisecondsSinceEpoch ~/ Duration.millisecondsPerHour;
    var bucket = _hours[hour];
    if (bucket == null) {
      bucket = _hours[hour] = TrafficHour();
      _prune();
    }
    _dirty = true;
    return foreground ? bucket.foreground : bucket.background;
  }

  void _prune() {
    final oldest =
        _now().millisecondsSinceEpoch ~/ Duration.millisecondsPerHour -
        windowHours +
        1;
    _hours.removeWhere((hour, _) => hour < oldest);
  }

  void _maybeSave() {
    final saved = _savedAt;
    final now = _now();
    if (saved != null && now.difference(saved) < _saveEvery) return;
    if (saved == null) {
      // The first count of a run starts the clock; nothing to write yet.
      _savedAt = now;
      return;
    }
    save();
  }

  /// Writes the counts now (leaving the screen, building a report).
  void save() {
    final prefs = _prefs;
    if (prefs == null || !_dirty) return;
    _dirty = false;
    _savedAt = _now();
    try {
      final written = prefs.setString(
        _service ? _prefsKeyService : _prefsKeyApp,
        jsonEncode(_encode(_hours)),
      );
      written.catchError((Object _) => false);
    } catch (_) {
      // Not written: the counts stay in memory.
    }
  }

  // ---- REST --------------------------------------------------------------

  /// One request is leaving: counted now, its bytes as they move. Returns
  /// the tallies of its route for this hour and since launch.
  TrafficFlow request(String method, String path, {int? requestBytes}) {
    final key = '${_safeMethod(method)} ${normalizePath(path)}';
    final flow = TrafficFlow._(
      _side().route(key),
      _launchSide.route(key),
    );
    flow._hour[0]++;
    flow._launch[0]++;
    if (requestBytes != null && requestBytes > 0) flow.sent(requestBytes);
    _maybeSave();
    return flow;
  }

  // ---- WebSocket ---------------------------------------------------------

  /// A socket was opened; [again] when this client had been connected
  /// before (a reconnection).
  void socketOpened({required bool again}) {
    for (final side in [_side(), _launchSide]) {
      side.connects++;
      if (again) side.reconnects++;
    }
    _maybeSave();
  }

  void socketReceived(Object? frame) {
    final bytes = _frameBytes(frame);
    for (final side in [_side(), _launchSide]) {
      side.messagesIn++;
      side.bytesIn += bytes;
    }
    _maybeSave();
  }

  void socketSent(Object? frame) {
    final bytes = _frameBytes(frame);
    for (final side in [_side(), _launchSide]) {
      side.messagesOut++;
      side.bytesOut += bytes;
    }
    _maybeSave();
  }

  /// UTF-16 units of a text frame (its bytes when it is plain ASCII, as
  /// JSON mostly is; a little under for other text), bytes of a binary one.
  static int _frameBytes(Object? frame) => switch (frame) {
    String text => text.length,
    List<int> bytes => bytes.length,
    _ => 0,
  };

  // ---- Reading a conversation again --------------------------------------

  /// A conversation was read again from the server for [reason], one of
  /// [rehydrationReasons] (anything else counts under [other]).
  void rehydration(String reason) {
    final key = rehydrationReasons.contains(reason) ? reason : other;
    for (final side in [_side(), _launchSide]) {
      side.rehydrations[key] = (side.rehydrations[key] ?? 0) + 1;
    }
    _maybeSave();
  }

  static const Set<String> rehydrationReasons = {
    'runtime',
    'canonical',
    'in_place',
    'stored_page',
  };

  // ---- Report ------------------------------------------------------------

  /// The counts as they go in the diagnostic report: totals of the last 24
  /// and [windowHours] hours and since the app was started, per side, with
  /// the routes that moved most; and one line per hour without routes.
  /// [prefs], reloaded, also brings in what the notification service wrote.
  Future<Map<String, dynamic>> report({SharedPreferences? prefs}) async {
    save();
    final all = <int, TrafficHour>{};
    _merge(all, _hours);
    final store = prefs ?? _prefs;
    if (store != null && !_service) {
      try {
        await store.reload();
        final raw = store.getString(_prefsKeyService);
        if (raw != null) _merge(all, _decode(raw));
      } catch (_) {
        // The service's counts are missing from this report.
      }
    }
    final nowHour =
        _now().millisecondsSinceEpoch ~/ Duration.millisecondsPerHour;
    Map<String, dynamic> window(int hours) {
      final foreground = TrafficSide();
      final background = TrafficSide();
      for (final MapEntry(key: hour, :value) in all.entries) {
        if (hour <= nowHour - hours || hour > nowHour) continue;
        foreground.add(value.foreground);
        background.add(value.background);
      }
      return {
        'foreground': foreground.toReport(),
        'background': background.toReport(),
      };
    }

    final hours = all.keys.where((hour) => hour > nowHour - windowHours).toList()
      ..sort();
    return {
      'note':
          'Body bytes only (no headers, TLS or wire compression). Routes '
          'are shapes: no ids, queries, headers or content.',
      'windowHours': windowHours,
      'last24h': window(24),
      'window': window(windowHours),
      'sinceLaunch': {
        'startedAt': _launchedAt?.toUtc().toIso8601String(),
        'foreground': _launchForeground.toReport(),
        'background': _launchBackground.toReport(),
      },
      'hourly': [
        for (final hour in hours)
          {
            'hour': DateTime.fromMillisecondsSinceEpoch(
              hour * Duration.millisecondsPerHour,
              isUtc: true,
            ).toIso8601String(),
            'foreground': all[hour]!.foreground.toTotals(),
            'background': all[hour]!.background.toTotals(),
          },
      ],
    };
  }

  // ---- Shapes ------------------------------------------------------------

  static const Set<String> _methods = {
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
  };

  static String _safeMethod(String method) {
    final upper = method.toUpperCase();
    return _methods.contains(upper) ? upper : 'OTHER';
  }

  /// The fixed words of the Hermes HTTP API. A segment that is not one of
  /// them (a profile, a session, a file, a provider) is written `:id`.
  static const Set<String> _words = {
    'actions', 'analytics', 'api', 'api_key', 'assets', 'attachments',
    'audio', 'auth', 'authorize', 'backup', 'boards', 'bots', 'branch',
    'browse', 'cache', 'catalog', 'chat', 'check', 'comments',
    'completions', 'config', 'config-migrate', 'credentials', 'cron',
    'dashboard', 'default-cwd', 'defaults', 'display', 'done', 'download',
    'download-browsed', 'eject', 'env', 'events', 'files', 'flush', 'fs',
    'gateway', 'git', 'graph', 'health', 'hermes', 'hermes-update', 'hub',
    'images', 'info', 'insights', 'jobs', 'kanban', 'keys', 'learning',
    'links', 'list', 'local-models', 'logs', 'mcp', 'me', 'media', 'memory',
    'messages', 'messaging', 'mkdir', 'model', 'models', 'native', 'node',
    'oauth', 'ops', 'options', 'orchestration', 'password-login', 'pause',
    'platforms', 'plugins', 'poll', 'pool', 'pr-list', 'prepare',
    'profiles', 'providers', 'pull-requests', 'raw', 'read', 'read-text',
    'refresh', 'reset', 'responses', 'restart', 'resume', 'review', 'rooms',
    'runs', 'runtime', 'schema', 'search', 'server', 'servers', 'sessions',
    'skills', 'snapshot', 'soul', 'start', 'status', 'switch', 'tags',
    'tasks', 'token', 'tools', 'toolsets', 'tree', 'update', 'upload',
    'usage', 'v1', 'version', 'write-text', 'ws', 'ws-ticket', //
  };

  /// [path] with every segment that is not a fixed API word as `:id`, at
  /// most eight segments, no query.
  static String normalizePath(String path) {
    final cut = path.indexOf('?');
    final bare = cut < 0 ? path : path.substring(0, cut);
    final out = <String>[
      for (final segment in bare.split('/').where((s) => s.isNotEmpty).take(8))
        _words.contains(segment) ? segment : ':id',
    ];
    return '/${out.join('/')}';
  }

  // ---- Storage -----------------------------------------------------------

  static Map<String, dynamic> _encode(Map<int, TrafficHour> hours) => {
    for (final MapEntry(key: hour, :value) in hours.entries)
      '$hour': {
        'f': value.foreground.toStore(),
        'b': value.background.toStore(),
      },
  };

  static Map<int, TrafficHour> _decode(String raw) {
    final decoded = jsonDecode(raw);
    final out = <int, TrafficHour>{};
    if (decoded is! Map) return out;
    for (final MapEntry(:key, :value) in decoded.entries) {
      final hour = int.tryParse('$key');
      if (hour == null || value is! Map) continue;
      out[hour] = TrafficHour()
        ..foreground.addStored(value['f'])
        ..background.addStored(value['b']);
    }
    return out;
  }

  static void _merge(Map<int, TrafficHour> into, Map<int, TrafficHour> from) {
    for (final MapEntry(key: hour, :value) in from.entries) {
      final bucket = into[hour] ??= TrafficHour();
      bucket.foreground.add(value.foreground);
      bucket.background.add(value.background);
    }
  }

  @visibleForTesting
  void resetForTesting({DateTime Function()? now}) {
    _prefs = null;
    _service = false;
    _foreground = false;
    _now = now ?? DateTime.now;
    _savedAt = null;
    _dirty = false;
    _hours.clear();
    _launchForeground.clear();
    _launchBackground.clear();
    _launchedAt = null;
  }
}

/// The two sides of one hour.
final class TrafficHour {
  final TrafficSide foreground = TrafficSide();
  final TrafficSide background = TrafficSide();
}

/// The bytes of one request, added to its route as they move.
final class TrafficFlow {
  TrafficFlow._(this._hour, this._launch);

  // [requests, bytes sent, bytes received]
  final List<int> _hour;
  final List<int> _launch;

  void sent(int bytes) {
    _hour[1] += bytes;
    _launch[1] += bytes;
  }

  void received(int bytes) {
    _hour[2] += bytes;
    _launch[2] += bytes;
  }
}

/// Counts of one side (on screen, or not) over some time.
final class TrafficSide {
  /// Route → [requests, bytes sent, bytes received].
  final Map<String, List<int>> routes = {};
  int connects = 0;
  int reconnects = 0;
  int messagesIn = 0;
  int messagesOut = 0;
  int bytesIn = 0;
  int bytesOut = 0;
  final Map<String, int> rehydrations = {};

  List<int> route(String key) {
    final known = routes[key];
    if (known != null) return known;
    if (routes.length >= TrafficCounter.maxRoutes) {
      return routes[TrafficCounter.other] ??= [0, 0, 0];
    }
    return routes[key] = [0, 0, 0];
  }

  void clear() {
    routes.clear();
    rehydrations.clear();
    connects = reconnects = messagesIn = messagesOut = bytesIn = bytesOut = 0;
  }

  void add(TrafficSide from) {
    for (final MapEntry(:key, :value) in from.routes.entries) {
      // Summed over many hours every route keeps its own line.
      final mine = routes[key] ??= [0, 0, 0];
      for (var i = 0; i < 3; i++) {
        mine[i] += value[i];
      }
    }
    connects += from.connects;
    reconnects += from.reconnects;
    messagesIn += from.messagesIn;
    messagesOut += from.messagesOut;
    bytesIn += from.bytesIn;
    bytesOut += from.bytesOut;
    for (final MapEntry(:key, :value) in from.rehydrations.entries) {
      rehydrations[key] = (rehydrations[key] ?? 0) + value;
    }
  }

  static int _int(Object? value) => value is int && value > 0 ? value : 0;

  void addStored(Object? stored) {
    if (stored is! Map) return;
    final r = stored['r'];
    if (r is Map) {
      for (final MapEntry(:key, :value) in r.entries) {
        if (key is! String || value is! List || value.length != 3) continue;
        final mine = route(key);
        for (var i = 0; i < 3; i++) {
          mine[i] += _int(value[i]);
        }
      }
    }
    final w = stored['w'];
    if (w is List && w.length == 6) {
      connects += _int(w[0]);
      reconnects += _int(w[1]);
      messagesIn += _int(w[2]);
      messagesOut += _int(w[3]);
      bytesIn += _int(w[4]);
      bytesOut += _int(w[5]);
    }
    final h = stored['h'];
    if (h is Map) {
      for (final MapEntry(:key, :value) in h.entries) {
        if (key is! String) continue;
        final name = TrafficCounter.rehydrationReasons.contains(key)
            ? key
            : TrafficCounter.other;
        rehydrations[name] = (rehydrations[name] ?? 0) + _int(value);
      }
    }
  }

  Map<String, dynamic> toStore() => {
    if (routes.isNotEmpty) 'r': routes,
    if (connects + messagesIn + messagesOut > 0)
      'w': [connects, reconnects, messagesIn, messagesOut, bytesIn, bytesOut],
    if (rehydrations.isNotEmpty) 'h': rehydrations,
  };

  Map<String, dynamic> toTotals() {
    var requests = 0;
    var sent = 0;
    var received = 0;
    for (final value in routes.values) {
      requests += value[0];
      sent += value[1];
      received += value[2];
    }
    var rereads = 0;
    for (final value in rehydrations.values) {
      rereads += value;
    }
    return {
      'requests': requests,
      'requestBytes': sent,
      'responseBytes': received,
      'wsConnects': connects,
      'wsReconnects': reconnects,
      'wsMessagesIn': messagesIn,
      'wsMessagesOut': messagesOut,
      'wsBytesIn': bytesIn,
      'wsBytesOut': bytesOut,
      'rehydrations': rereads,
    };
  }

  /// Totals, the forty routes that moved most bytes, and the re-reads by
  /// reason.
  Map<String, dynamic> toReport() {
    final sorted = routes.entries.toList()
      ..sort((a, b) {
        final byBytes = (b.value[1] + b.value[2]).compareTo(
          a.value[1] + a.value[2],
        );
        return byBytes != 0 ? byBytes : b.value[0].compareTo(a.value[0]);
      });
    final shown = sorted.take(40).toList();
    final rest = sorted.skip(40).fold<List<int>>([0, 0, 0], (sum, entry) {
      for (var i = 0; i < 3; i++) {
        sum[i] += entry.value[i];
      }
      return sum;
    });
    return {
      ...toTotals(),
      'rehydrationsByReason': Map<String, int>.of(rehydrations),
      'routes': [
        for (final entry in shown)
          {
            'route': entry.key,
            'requests': entry.value[0],
            'requestBytes': entry.value[1],
            'responseBytes': entry.value[2],
          },
        if (rest[0] > 0)
          {
            'route': 'other (${sorted.length - 40} more)',
            'requests': rest[0],
            'requestBytes': rest[1],
            'responseBytes': rest[2],
          },
      ],
    };
  }
}
