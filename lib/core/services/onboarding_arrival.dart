import 'package:flutter/foundation.dart';

/// One-shot request «open a new chat on connection X», left by the
/// onboarding's «Open chat» for the Home that shows up next (every exit of
/// the onboarding ends in Home). In memory only: a restart forgets it.
class OnboardingArrival {
  OnboardingArrival._();

  static const Duration maxAge = Duration(seconds: 30);
  static ({String connectionId, DateTime at})? _pending;

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// Keeps at most one request: a new one replaces the old.
  static void request(String connectionId) =>
      _pending = (connectionId: connectionId, at: now());

  /// True once, when the request is for [activeId] and younger than
  /// [maxAge]. Any other request is dropped.
  static bool take(String activeId) {
    final pending = _pending;
    if (pending == null) return false;
    _pending = null;
    return pending.connectionId == activeId &&
        now().difference(pending.at) < maxAge;
  }

  @visibleForTesting
  static void reset() {
    _pending = null;
    now = DateTime.now;
  }
}
