import 'dart:async';

class RecentInterruptGuard {
  RecentInterruptGuard({
    this.cooldown = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration cooldown;
  final DateTime Function() _now;
  DateTime? _interruptedAt;

  void markInterrupted() {
    _interruptedAt = _now();
  }

  bool get active {
    final interruptedAt = _interruptedAt;
    if (interruptedAt == null) return false;
    final elapsed = _now().difference(interruptedAt);
    return !elapsed.isNegative && elapsed < cooldown;
  }

  Future<void> interruptBeforeSend(Future<void> Function() interrupt) async {
    if (active) await interrupt();
  }
}
