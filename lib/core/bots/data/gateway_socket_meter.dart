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
      debugPrint(
        '[gateway-sockets] opened=${_opens.length}/min total=$_total',
      );
    }
  }

  @visibleForTesting
  void reset() {
    _opens.clear();
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
