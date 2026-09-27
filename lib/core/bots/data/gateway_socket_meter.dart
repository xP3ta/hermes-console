import 'package:flutter/foundation.dart';

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
  }) {
    _closes.add(GatewaySocketClose(reason, code, life, now()));
    if (_closes.length > closeHistory) _closes.removeAt(0);
    _closeCounts[reason] = (_closeCounts[reason] ?? 0) + 1;
    if (kDebugMode) {
      debugPrint(
        '[gateway-sockets] closed reason=$reason code=${code ?? 'none'} '
        'life=${life.inMilliseconds}ms',
      );
    }
  }

  void recordNetworkLost() => _networkLost++;

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
    _opens.add(at);
    _trim();
    if (kDebugMode &&
        (_lastLog == null || at.difference(_lastLog!) >= window)) {
      _lastLog = at;
      debugPrint('[gateway-sockets] opened=${_opens.length}/min total=$_total');
    }
  }

  @visibleForTesting
  void reset() {
    _opens.clear();
    _closes.clear();
    _closeCounts.clear();
    _networkLost = 0;
    _total = 0;
    _lastLog = null;
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
