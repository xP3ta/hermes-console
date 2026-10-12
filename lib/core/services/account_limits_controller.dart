import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/account_usage_limits.dart';

/// Keeps the plan limits of one chat: read when the model sheet opens and
/// after each finished turn (throttled), cached per session so a reopened
/// chat shows the last answer at once. Never polls, and never reads while
/// App Lock is locked.
class AccountLimitsController {
  AccountLimitsController({
    required this.cacheKey,
    required this.load,
    required this.isLocked,
    DateTime Function()? now,
    this.afterTurnMinInterval = const Duration(seconds: 60),
  }) : _now = now ?? DateTime.now,
       _limits = ValueNotifier(_cache[cacheKey]);

  /// `connection|session`: limits belong to the account behind a session.
  final String cacheKey;

  /// Minimum gap between two after-turn reads (each read reaches the
  /// provider's usage API from the server).
  final Duration afterTurnMinInterval;

  /// One read; null when nothing could be read (the last value stays).
  final Future<AccountUsageLimits?> Function() load;

  /// App Lock (or an unmounted chat): no read at all while true.
  final bool Function() isLocked;
  final DateTime Function() _now;
  final ValueNotifier<AccountUsageLimits?> _limits;
  Future<void>? _inFlight;
  DateTime? _loadedAt;
  bool _disposed = false;

  static const _cacheSize = 32;
  static final LinkedHashMap<String, AccountUsageLimits> _cache =
      LinkedHashMap();

  @visibleForTesting
  static void debugClearCache() => _cache.clear();

  ValueListenable<AccountUsageLimits?> get limits => _limits;

  /// Reads the limits once. [afterTurn] reads are skipped when the last one
  /// is newer than [afterTurnMinInterval]. A null or failed answer keeps the
  /// last value; an empty answer clears it.
  Future<void> refresh({bool afterTurn = false}) {
    if (_disposed || isLocked()) return Future<void>.value();
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final loadedAt = _loadedAt;
    if (afterTurn &&
        loadedAt != null &&
        _now().difference(loadedAt) < afterTurnMinInterval) {
      return Future<void>.value();
    }
    final run = () async {
      try {
        final result = await load();
        if (_disposed || result == null) return;
        _loadedAt = _now();
        _cache.remove(cacheKey);
        _cache[cacheKey] = result;
        while (_cache.length > _cacheSize) {
          _cache.remove(_cache.keys.first);
        }
        _limits.value = result;
      } catch (error) {
        debugPrint('[plan-limits] unavailable (${error.runtimeType})');
      }
    }();
    _inFlight = run;
    return run.whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    });
  }

  /// Stops publishing. The notifier itself is left to the GC: an open model
  /// sheet on another route may still be listening while the chat unmounts,
  /// and disposing it under that listener would throw.
  void dispose() {
    _disposed = true;
  }
}
