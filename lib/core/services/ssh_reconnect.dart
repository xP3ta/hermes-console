// Reconexión automática del terminal SSH (1.4.0, F1). Solo tras una caída de
// red (SshSessionEnd.connectionLost), con backoff acotado y sin trabajo en
// segundo plano: al pasar a segundo plano se cancela el timer y, al volver,
// se reanuda solo si la ausencia fue corta. Lo posee la pantalla del
// terminal, que lo libera en dispose.
import 'dart:async';

import 'package:flutter/foundation.dart';

enum SshReconnectStatus {
  /// Nothing to show: connected, or closed on purpose.
  idle,

  /// Waiting for the next attempt's delay.
  waiting,

  /// An attempt is in flight.
  reconnecting,

  /// The last attempt worked; shown for [SshAutoReconnect.noticeDuration].
  reconnected,

  /// Gave up (attempts used up, a failure no retry can fix, or a long time
  /// in the background). Only the manual button reconnects from here.
  offline,
}

/// Result of one reconnection attempt.
enum SshReconnectOutcome {
  connected,

  /// Network-looking failure: wait and try again while attempts remain.
  retry,

  /// A retry cannot help (credentials, configuration, a host key that needs
  /// the user): go straight to [SshReconnectStatus.offline].
  stop,
}

class SshAutoReconnect {
  SshAutoReconnect({
    required this.attempt,
    this.delays = defaultDelays,
    this.maxBackground = defaultMaxBackground,
    this.noticeDuration = defaultNoticeDuration,
    this.stableAfter = defaultStableAfter,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// One delay per attempt: 1, 2, 4, 8 and 15 s, then offline.
  static const List<Duration> defaultDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

  /// A longer absence in the background ends the automatic attempts.
  static const Duration defaultMaxBackground = Duration(minutes: 2);

  static const Duration defaultNoticeDuration = Duration(seconds: 4);

  /// A connection that drops again sooner than this after a reconnect keeps
  /// using the same attempts instead of a fresh run: a flapping link ends
  /// offline instead of looping forever.
  static const Duration defaultStableAfter = Duration(seconds: 60);

  /// Opens a new connection. Must not accept a new or changed host key on
  /// its own (TOFU): it reports [SshReconnectOutcome.stop] instead.
  final Future<SshReconnectOutcome> Function() attempt;
  final List<Duration> delays;
  final Duration maxBackground;
  final Duration noticeDuration;
  final Duration stableAfter;
  final DateTime Function() _clock;

  final ValueNotifier<SshReconnectStatus> status =
      ValueNotifier<SshReconnectStatus>(SshReconnectStatus.idle);

  Timer? _timer;
  int _attempts = 0;
  // Bumped whenever a run is cancelled, so a late result is ignored.
  int _run = 0;
  bool _disposed = false;
  bool _inBackground = false;
  bool _pendingWhileAway = false;
  DateTime? _backgroundSince;
  DateTime? _connectedAt;

  /// Attempts made in the current run.
  int get attempts => _attempts;

  /// true while a timer or an attempt is pending.
  bool get isActive =>
      status.value == SshReconnectStatus.waiting ||
      status.value == SshReconnectStatus.reconnecting;

  /// The connection dropped: start a run of attempts (a fresh one unless
  /// the last reconnect is less than [stableAfter] old).
  void start() {
    if (_disposed) return;
    _cancel();
    final connectedAt = _connectedAt;
    final flapping =
        connectedAt != null && _clock().difference(connectedAt) < stableAfter;
    if (!flapping) _attempts = 0;
    _scheduleNext();
  }

  /// Stops without a message: the user reconnected by hand or closed the
  /// session on purpose.
  void stop() {
    if (_disposed) return;
    _cancel();
    _pendingWhileAway = false;
    _connectedAt = null;
    status.value = SshReconnectStatus.idle;
  }

  /// The app went to the background: cancel the timer of the next attempt.
  /// An attempt already in flight is let finish and its result counts: a
  /// connection made meanwhile must not end up shown as offline.
  void pause() {
    if (_disposed || _inBackground) return;
    _inBackground = true;
    _backgroundSince = _clock();
    if (status.value == SshReconnectStatus.waiting) {
      _cancel();
      _pendingWhileAway = true;
    }
  }

  /// Back in the foreground: carry on with the attempts left after a short
  /// absence, or give up after a long one.
  void resume() {
    if (_disposed || !_inBackground) return;
    _inBackground = false;
    final since = _backgroundSince;
    _backgroundSince = null;
    if (!_pendingWhileAway) return;
    _pendingWhileAway = false;
    if (since != null && _clock().difference(since) > maxBackground) {
      status.value = SshReconnectStatus.offline;
      return;
    }
    _scheduleNext();
  }

  void dispose() {
    _disposed = true;
    _cancel();
    status.dispose();
  }

  void _cancel() {
    _run++;
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext() {
    if (_attempts >= delays.length) {
      status.value = SshReconnectStatus.offline;
      return;
    }
    status.value = SshReconnectStatus.waiting;
    if (_inBackground) {
      // Nothing runs in the background; resume() decides.
      _pendingWhileAway = true;
      return;
    }
    final run = _run;
    _timer = Timer(delays[_attempts], () => _fire(run));
  }

  Future<void> _fire(int run) async {
    _timer = null;
    if (_disposed || run != _run) return;
    _attempts++;
    status.value = SshReconnectStatus.reconnecting;
    SshReconnectOutcome outcome;
    try {
      outcome = await attempt();
    } catch (e) {
      debugPrint('[ssh-reconnect] attempt failed (${e.runtimeType})');
      outcome = SshReconnectOutcome.retry;
    }
    if (_disposed || run != _run) return;
    switch (outcome) {
      case SshReconnectOutcome.connected:
        _connectedAt = _clock();
        status.value = SshReconnectStatus.reconnected;
        _timer = Timer(noticeDuration, () {
          if (_disposed || run != _run) return;
          _timer = null;
          status.value = SshReconnectStatus.idle;
        });
      case SshReconnectOutcome.retry:
        _scheduleNext();
      case SshReconnectOutcome.stop:
        status.value = SshReconnectStatus.offline;
    }
  }
}
