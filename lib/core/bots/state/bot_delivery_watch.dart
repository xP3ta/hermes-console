import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/tui_gateway_client.dart';
import '../data/bot_delivery.dart';

/// A gateway older than `bot_delivery.list` answers «method not found»
/// (-32601): the strip does not exist there, and nothing is shown for it.
/// Desktop `plugins/hermes-bots/screen-connection.ts` `isDisplayUnavailable`
/// (used by `teammate-waits.tsx` `listDeliveries`).
bool isBotDeliveryUnsupported(Object error) {
  if (error is TuiGatewayRpcError) {
    if (error.code == -32601) return true;
    final message = error.message.toLowerCase();
    return message.contains('method not found') ||
        message.contains('method-not-found');
  }
  return false;
}

/// Failure ids the user dismissed. Desktop persists them so a restart does
/// not bring them back for the rest of the gateway's 24 h failure window
/// (`teammate-waits.tsx` `$dismissedDeliveries`).
abstract interface class BotDeliveryDismissals {
  Future<Set<String>> load();
  Future<void> save(Set<String> ids);
}

final class PrefsBotDeliveryDismissals implements BotDeliveryDismissals {
  const PrefsBotDeliveryDismissals();

  static const key = 'bot_delivery_dismissed';

  @override
  Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is List
          ? {
              for (final id in decoded)
                if (id is String) id,
            }
          : <String>{};
    } on FormatException {
      return <String>{};
    }
  }

  @override
  Future<void> save(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(ids.toList()..sort()));
  }
}

/// The «Waiting on teammates» rows of one bot: polls `bot_delivery.list`
/// every [interval] while the owner is on screen (Desktop `refetchInterval:
/// 5000`), keeps the last good rows when a poll fails and says so
/// ([stale]), and drops dismissed failures.
final class BotDeliveryWatch extends ChangeNotifier {
  BotDeliveryWatch({
    required this.gateway,
    required this.profile,
    this.interval = const Duration(seconds: 5),
    DateTime Function()? clock,
    this.dismissals = const PrefsBotDeliveryDismissals(),
  }) : _clock = clock ?? DateTime.now;

  /// The gateway the owner's chat rides now, or null while it has none.
  final BotDeliveryGateway? Function() gateway;

  /// The SENDER bot (`bot_delivery.list {profile}`).
  final String profile;
  final Duration interval;
  final DateTime Function() _clock;

  /// Where dismissed failures are kept between runs.
  final BotDeliveryDismissals dismissals;

  List<BotDelivery> _rows = const [];
  Set<String> _dismissed = <String>{};
  bool _stale = false;
  bool _unsupported = false;
  bool _disposed = false;
  bool _running = false;
  bool _loaded = false;
  Future<void>? _flight;
  Timer? _timer;
  DateTime? _asOf;

  /// Rows the strip shows: dismissed failures drop; only failures can be
  /// dismissed (`visibleDeliveries`).
  List<BotDelivery> get rows => [
    for (final row in _rows)
      if (row.state != BotDeliveryState.failed ||
          !_dismissed.contains(row.deliveryId))
        row,
  ];

  /// The last poll failed: [rows] are the last ones the gateway answered.
  bool get stale => _stale;

  /// The gateway has no `bot_delivery.list`: the strip stays out.
  bool get unsupported => _unsupported;

  /// When the rows were last fetched (or the last poll failed): ages count
  /// from here, as Desktop's `Math.max(dataUpdatedAt, errorUpdatedAt)`.
  DateTime? get asOf => _asOf;

  /// Starts polling now, and every [interval] after each answer.
  void start() {
    if (_disposed || _running || _unsupported) return;
    _running = true;
    unawaited(_poll());
  }

  /// The owner left the foreground: no poll until [start] again.
  void pause() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dismiss(String deliveryId) async {
    if (_disposed) return;
    _dismissed = {..._dismissed, deliveryId};
    notifyListeners();
    await dismissals.save(_dismissed);
  }

  /// One poll now (and the schedule that follows it).
  Future<void> refresh() => _unsupported ? Future<void>.value() : _poll();

  Future<void> _poll() {
    final flight = _flight;
    if (flight != null) return flight;
    return _flight = _fetch().whenComplete(() {
      _flight = null;
      _timer?.cancel();
      _timer = null;
      if (_running && !_disposed && !_unsupported) {
        _timer = Timer(interval, () => unawaited(_poll()));
      }
    });
  }

  Future<void> _fetch() async {
    if (!_loaded) {
      _loaded = true;
      try {
        _dismissed = {..._dismissed, ...await dismissals.load()};
      } catch (_) {
        // A store that cannot be read only brings dismissed failures back.
      }
    }
    final source = gateway();
    if (_disposed || source == null) return;
    try {
      final fetched = await source.listBotDeliveries(profile);
      if (_disposed) return;
      _rows = fetched;
      _stale = false;
      _asOf = _clock();
      await _forgetSettledDismissals(fetched);
    } catch (error) {
      if (_disposed) return;
      if (isBotDeliveryUnsupported(error)) {
        _unsupported = true;
        _rows = const [];
        _stale = false;
      } else {
        // A timeout, a dropped socket or a storage error is not an empty
        // answer: the last rows stay, greyed and labelled.
        _stale = true;
        _asOf = _clock();
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// A failure that left the gateway's window can no longer come back, so
  /// its dismissal is not kept.
  Future<void> _forgetSettledDismissals(List<BotDelivery> fetched) async {
    final live = {for (final row in fetched) row.deliveryId};
    final kept = _dismissed.where(live.contains).toSet();
    if (kept.length == _dismissed.length) return;
    _dismissed = kept;
    try {
      await dismissals.save(kept);
    } catch (_) {
      // Kept in memory; the next answer prunes again.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
