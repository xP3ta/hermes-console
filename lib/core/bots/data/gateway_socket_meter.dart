import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../config/flavor.dart';

/// Compile-time gate: the `[QA-NET]` lines exist only in the QA flavor and never
/// in a release build (`debugPrint` writes in release), so elsewhere every call
/// below folds away and the tree shaker drops them. QA APKs are profile builds.
const bool kNetMeterEnabled = kHermesFlavor == 'qa' && !kReleaseMode;

NetMeterLog? _defaultLog({required bool release}) =>
    kHermesFlavor == 'qa' && !release ? NetMeterLog(debugPrint) : null;

/// Debug meter for Desktop gateway WebSocket opens (spec 070 T209).
///
/// Every `TuiGatewayClient` transport open is recorded here so Bot Mode can
/// prove it no longer opens one socket per refresh/row. In debug builds a
/// summary line is logged at most once per minute.
final class GatewaySocketMeter {
  GatewaySocketMeter._();

  static final GatewaySocketMeter instance = GatewaySocketMeter._();

  static const window = Duration(minutes: 1);

  DateTime Function() now = DateTime.now;
  final List<DateTime> _opens = [];
  int _total = 0;
  DateTime? _lastLog;

  /// Last closes (newest last), capped; no private data (stable reasons).
  static const closeHistory = 50;
  final List<GatewaySocketClose> _closes = [];
  final Map<String, int> _closeCounts = {};
  int _networkLost = 0;

  NetMeterLog? _log = _defaultLog(release: kReleaseMode);

  /// True when `[QA-NET]` lines are being produced (QA flavor only).
  bool get enabled => _log != null;

  @visibleForTesting
  void debugUseLog(NetMeterLog? log) => _log = log;

  static const _originKey = #hermesNetMeterOrigin;
  static final _originToken = RegExp(r'^[a-z][A-Za-z0-9_.]{0,31}$');

  /// Runs [body] labelled with the screen/flow that asks, so every REST call
  /// and RPC it starts (the label rides the zone through awaits) is logged
  /// with `origin=<label>`. Labels are fixed tokens such as `chat.snapshot`;
  /// anything else is masked as `other`. No behaviour change: with the gate
  /// off it only calls [body].
  static T origin<T>(String label, T Function() body) => instance.enabled
      ? runZoned(
          body,
          zoneValues: {
            _originKey: _originToken.hasMatch(label) ? label : 'other',
          },
        )
      : body();

  /// Like [origin], but an enclosing label wins (a passive refresh inside a
  /// foreground reconciliation stays `chat.foreground`).
  static T originIfNone<T>(String label, T Function() body) =>
      Zone.current[_originKey] == null ? origin(label, body) : body();

  static String get _currentOrigin =>
      Zone.current[_originKey] as String? ?? 'none';

  /// Stable, non-reversible socket label `<conn>/<profile>/<lane>`: the
  /// connection id and profile name are hashed, never printed.
  static String socketKey(String connectionId, String profile, String lane) {
    String short(String v, int n) =>
        sha256.convert(utf8.encode(v)).toString().substring(0, n);
    return '${short(connectionId, 6)}/${short(profile, 4)}/$lane';
  }

  /// REST: method, normalized path (no host/query), status (null = failed), ms.
  /// [outcome] (`aborted`, `timeout`, `error`) says why there is no status.
  void recordRest(
    String method,
    String path,
    int? status,
    int ms, {
    String? outcome,
  }) => _log?.rest(method, path, status, ms, now(), _currentOrigin, outcome);

  /// JSON-RPC method name only: no params, no result, no error text.
  void recordRpc(String method, String outcome, int ms) =>
      _log?.rpc(method, outcome, ms, now(), _currentOrigin);

  /// A transport reached `gateway.ready` / was torn down, per [socketKey].
  void socketUp(String key) => _log?.socketUp(key);

  void socketDown(String key) => _log?.socketDown(key);

  /// Sockets currently ready, per [socketKey] (QA only; empty otherwise).
  Map<String, int> get liveSockets => _log?.live ?? const {};

  /// `GET …/messages` in the current summary window, per origin.
  Map<String, int> get messageReads => _log?.messageReads ?? const {};

  /// Times [call] until it settles and records ok/timeout/error.
  void trackRpc(
    String method,
    Future<Object?> call,
    bool Function(Object error) isTimeout,
  ) {
    if (_log == null) return;
    final watch = Stopwatch()..start();
    final label = _currentOrigin;
    void record(String outcome) => origin(
      label,
      () => recordRpc(method, outcome, watch.elapsedMilliseconds),
    );
    call.then(
      (_) => record('ok'),
      onError: (Object e) => record(isTimeout(e) ? 'timeout' : 'error'),
    );
  }

  /// [tag] is ` lane=<lane> socket=<key>` (hashed ids, QA only).
  void recordReady(int ms, {String tag = ''}) =>
      _log?.ws('open ready_ms=$ms$tag', now());

  void recordBackoff(int attempt, int ms, {String tag = ''}) =>
      _log?.ws('backoff attempt=$attempt ms=$ms$tag', now());

  void recordTicketFailure(String kind, {String tag = ''}) =>
      _log?.ws('ticket failed kind=$kind$tag', now());

  /// `recovery scheduled reason=transport|fanout_gap|withheld_turn_end|other`.
  void recordRecovery(String reason) => _log?.recovery(reason, now());

  /// Why the owner chat was last asked to rehydrate (read once by it).
  String? _rehydrationReason;

  void noteRehydration(String reason) {
    if (_log != null) _rehydrationReason = reason;
  }

  String takeRehydrationReason() {
    final reason = _rehydrationReason ?? 'fanout_gap';
    _rehydrationReason = null;
    return reason;
  }

  /// A dial (ticket + open) of [key] is in flight; the summary keeps the peak.
  void dialStart(String key) => _log?.dial(key, 1);

  void dialEnd(String key) => _log?.dial(key, -1);

  /// Runtimes of [key] held in quarantine right now (a gauge).
  void recordQuarantined(String key, int runtimes) =>
      _log?.quarantined(key, runtimes);

  /// JSON decode cost of socket frames since the last recovery line.
  void recordDecode(int ms, int bytes) => _log?.decoded(ms, bytes);

  void recordRecoveryDone(String reason, int totalMs, int applyMs, int msgs) =>
      _log?.recoveryDone(reason, totalMs, applyMs, msgs, now());

  /// PX5D: a chat transport no recovery loop owned any more went back to
  /// connected (`from` offline|reconnecting, `site` link|reattach|retry).
  void recordTransportSettle(String from, String site) =>
      _log?.ws('transport settled from=$from site=$site', now());

  Timer? _stallTimer;

  /// QA-only main-isolate stall detector: a 100 ms timer that fires >500 ms
  /// late means Dart held the UI thread that long.
  void startStallWatch() {
    if (_log == null || _stallTimer != null) return;
    var last = now();
    _stallTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final late = now().difference(last).inMilliseconds - 100;
      last = now();
      if (late > 500) _log?.ws('main_stall ms=$late', last);
    });
  }

  void recordProbe({required bool ok}) =>
      _log?.ws('probe ${ok ? 'ok' : 'timeout'}', now());

  void recordNetworkAvailable() => _log?.ws('net available', now());

  List<GatewaySocketClose> get recentCloses => List.unmodifiable(_closes);

  /// Closes per stable reason since process start (or [reset]).
  Map<String, int> get closeCounts => Map.unmodifiable(_closeCounts);

  int get networkLostCount => _networkLost;

  /// One transport close: `reason` is a stable token (client_dispose,
  /// heartbeat_timeout, probe_timeout, protocol_violation, peer_closed,
  /// transport_error, connect_aborted…), `code` the close code sent or
  /// received, `life` how long the socket was up.
  void recordClose({
    required String reason,
    int? code,
    Duration life = Duration.zero,
    String tag = '',
  }) {
    _closes.add(GatewaySocketClose(reason, code, life, now()));
    if (_closes.length > closeHistory) _closes.removeAt(0);
    _closeCounts[reason] = (_closeCounts[reason] ?? 0) + 1;
    _log?.close(reason, code, life, now(), tag);
    if (kDebugMode) {
      debugPrint(
        '[gateway-sockets] closed reason=$reason code=${code ?? 'none'} '
        'life=${life.inMilliseconds}ms',
      );
    }
  }

  void recordNetworkLost() {
    _networkLost++;
    _log?.ws('net lost', now());
  }

  /// Total opens since process start (or the last [reset]).
  int get totalOpened => _total;

  /// Opens within the trailing [window].
  int get openedLastMinute {
    _trim();
    return _opens.length;
  }

  void recordOpen() {
    _total++;
    final at = now();
    _log?.opened();
    _opens.add(at);
    _trim();
    if (kDebugMode &&
        (_lastLog == null || at.difference(_lastLog!) >= window)) {
      _lastLog = at;
      debugPrint('[gateway-sockets] opened=${_opens.length}/min total=$_total');
    }
  }

  /// [release] is a seam to simulate a release build, which a test cannot be.
  @visibleForTesting
  void reset({bool release = kReleaseMode}) {
    _opens.clear();
    _closes.clear();
    _closeCounts.clear();
    _networkLost = 0;
    _total = 0;
    _lastLog = null;
    _rehydrationReason = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _log = _defaultLog(release: release);
    now = DateTime.now;
  }

  void _trim() {
    final cutoff = now().subtract(window);
    while (_opens.isNotEmpty && _opens.first.isBefore(cutoff)) {
      _opens.removeAt(0);
    }
  }
}

final class GatewaySocketClose {
  const GatewaySocketClose(this.reason, this.code, this.life, this.at);

  final String reason;
  final int? code;
  final Duration life;
  final DateTime at;
}

/// QA-only `[QA-NET]` sink. One line per event plus a summary at most every
/// 60 s (emitted with the next event; there is no timer). Lines carry only
/// stable tokens: no host, query, header, token, body or RPC parameter.
final class NetMeterLog {
  NetMeterLog(this._sink);

  final void Function(String line) _sink;

  static const summaryEvery = Duration(seconds: 60);

  /// Static API path segments that may appear verbatim; every other segment
  /// (profile names, session ids, file names) becomes `:id`.
  static const _segments = {
    'api', 'audio', 'auth', 'check', 'config', 'cron', 'download', 'events',
    'files', 'health', 'hermes', 'info', 'jobs', 'logs', 'me', 'memory',
    'messages', 'model', 'models', 'options', 'profiles', 'providers', 'runs',
    'sessions', 'skills', 'soul', 'status', 'tags', 'tools', 'toolsets',
    'update', 'ws', //
  };
  static final _method = RegExp(r'^[a-z][a-z0-9_.]{0,63}$');

  final Map<String, List<int>> _routes = {};
  final Map<String, int> _closes = {};
  final Map<String, int> _live = {};
  final Map<String, int> _messages = {};
  final Map<String, int> _restResults = {};
  final Map<String, int> _recoveries = {};
  final Map<String, int> _quarantine = {};
  final Map<String, int> _dialsNow = {};
  final Map<String, int> _dialsMax = {};
  int _decodeMs = 0;
  int _decodeBytes = 0;
  int _opens = 0;
  DateTime? _windowStart;

  static String normalizePath(String path) {
    final out = <String>[
      for (final s in path.split('/').where((s) => s.isNotEmpty).take(8))
        _segments.contains(s) ? s : ':id',
    ];
    return '/${out.join('/')}';
  }

  void opened() => _opens++;

  /// Sockets ready right now per label (a gauge: survives summaries).
  Map<String, int> get live => Map.unmodifiable(_live);

  Map<String, int> get messageReads => Map.unmodifiable(_messages);

  void socketUp(String key) => _live[key] = (_live[key] ?? 0) + 1;

  void socketDown(String key) {
    final left = (_live[key] ?? 0) - 1;
    if (left > 0) {
      _live[key] = left;
    } else {
      _live.remove(key);
    }
  }

  void rest(
    String method,
    String path,
    int? status,
    int ms,
    DateTime at,
    String origin,
    String? outcome,
  ) {
    final normalized = normalizePath(path);
    final verb = method.toUpperCase();
    final result = status?.toString() ?? outcome ?? 'error';
    if (status == null) _restResults[result] = (_restResults[result] ?? 0) + 1;
    if (verb == 'GET' && normalized.endsWith('/messages')) {
      _messages[origin] = (_messages[origin] ?? 0) + 1;
    }
    _routes.putIfAbsent('$verb $normalized{origin=$origin}', () => []).add(ms);
    _emit('rest $verb $normalized $result ${ms}ms origin=$origin', at);
  }

  void rpc(String method, String outcome, int ms, DateTime at, String origin) {
    final name = _method.hasMatch(method) ? method : ':id';
    _routes.putIfAbsent('RPC $name{origin=$origin}', () => []).add(ms);
    _emit('rpc $name $outcome ${ms}ms origin=$origin', at);
  }

  void close(
    String reason,
    int? code,
    Duration life,
    DateTime at, [
    String tag = '',
  ]) {
    _closes[reason] = (_closes[reason] ?? 0) + 1;
    _emit(
      'ws close reason=$reason code=${code ?? 'none'} '
      'life=${life.inMilliseconds}ms$tag',
      at,
    );
  }

  static const _recoveryReasons = {
    'transport', 'fanout_gap', 'withheld_turn_end', //
  };

  void recovery(String reason, DateTime at) {
    final token = _recoveryReasons.contains(reason) ? reason : 'other';
    _recoveries[token] = (_recoveries[token] ?? 0) + 1;
    _emit('recovery scheduled reason=$token', at);
  }

  void dial(String key, int delta) {
    final now = ((_dialsNow[key] ?? 0) + delta).clamp(0, 1 << 20);
    _dialsNow[key] = now;
    if (now > (_dialsMax[key] ?? 0)) _dialsMax[key] = now;
  }

  void quarantined(String key, int runtimes) => _quarantine[key] = runtimes;

  void decoded(int ms, int bytes) {
    _decodeMs += ms;
    _decodeBytes += bytes;
  }

  void recoveryDone(
    String reason,
    int total,
    int apply,
    int msgs,
    DateTime at,
  ) {
    _emit(
      'recovery done reason=$reason total_ms=$total decode_ms=$_decodeMs '
      'apply_ms=$apply msgs=$msgs bytes=$_decodeBytes',
      at,
    );
    _decodeMs = 0;
    _decodeBytes = 0;
  }

  void ws(String event, DateTime at) => _emit('ws $event', at);

  void _emit(String line, DateTime at) {
    _windowStart ??= at;
    _sink('[QA-NET] $line');
    if (at.difference(_windowStart!) < summaryEvery) return;
    _windowStart = at;
    final routes = [
      for (final e in _routes.entries) '${e.key}=${_stats(e.value)}',
    ];
    _sink(
      '[QA-NET] summary opens=$_opens closes=$_closes live=$_live '
      'recoveries=$_recoveries '
      'quarantined=${_quarantine.values.fold(0, (a, b) => a + b)} '
      'dials_inflight_max=$_dialsMax '
      'messages=$_messages rest_results=$_restResults ${routes.join(' ')}',
    );
    _recoveries.clear();
    _dialsMax
      ..clear()
      ..addAll({
        for (final e in _dialsNow.entries)
          if (e.value > 0) e.key: e.value,
      });
    _routes.clear();
    _closes.clear();
    _messages.clear();
    _restResults.clear();
    _opens = 0;
  }

  static String _stats(List<int> ms) {
    final sorted = [...ms]..sort();
    int at(double q) => sorted[((sorted.length - 1) * q).round()];
    return '${sorted.length}x p50=${at(0.5)} p95=${at(0.95)}';
  }
}
