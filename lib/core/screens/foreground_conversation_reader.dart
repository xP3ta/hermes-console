import 'dart:async';
import 'dart:math' as math;

/// Programa lecturas REST pasivas de una conversación visible.
///
/// Usa timers one-shot: la siguiente lectura solo se arma después de que la
/// anterior termine. Ocultar o destruir el lector invalida su generación para
/// que una respuesta tardía no vuelva a poner en marcha el ciclo.
class ForegroundConversationReader {
  ForegroundConversationReader({
    required this.successInterval,
    this.eventBackstopInterval = const Duration(seconds: 30),
    this.activeInterval = const Duration(seconds: 3),
    this.storeChangeGap = const Duration(seconds: 10),
    required this.failureIntervals,
    this.changeEventsAvailable = false,
    String Function()? durableChatId,
    bool Function()? externallyOwnedTurnActive,
    bool Function()? recoveryConverging,
    required this.canRead,
    required this.read,
  }) : _durableChatId = durableChatId ?? (() => ''),
       _externallyOwnedTurnActive = externallyOwnedTurnActive ?? (() => false),
       _recoveryConverging = recoveryConverging ?? (() => false),
       assert(failureIntervals.isNotEmpty);

  final Duration successInterval;
  final Duration eventBackstopInterval;
  final Duration activeInterval;
  final Duration storeChangeGap;
  final List<Duration> failureIntervals;
  bool changeEventsAvailable;
  final String Function() _durableChatId;
  final bool Function() _externallyOwnedTurnActive;
  final bool Function() _recoveryConverging;
  final bool Function() canRead;
  final Future<bool> Function() read;

  Timer? _timer;
  Timer? _storeChangeGapTimer;
  bool _storeChangePending = false;
  bool _visible = false;
  bool _disposed = false;
  bool _readInFlight = false;
  bool _immediateReadPending = false;
  bool _eventRecoveryConverging = false;
  bool _terminalObserved = false;
  int _generation = 0;
  int _consecutiveFailures = 0;
  ({bool active, bool recovery})? _lastConvergenceSnapshot;
  ({bool active, bool recovery})? _settledConvergenceSnapshot;
  int _agreeingSnapshots = 0;

  void setVisible(bool visible, {bool immediate = false}) {
    if (_disposed) return;
    if (_visible == visible && !immediate) return;
    _visible = visible;
    _generation += 1;
    _timer?.cancel();
    _timer = null;
    _immediateReadPending = false;
    if (_visible) {
      _schedule(immediate ? Duration.zero : _successDelay, _generation);
    }
  }

  void setChangeEventsAvailable(bool available, {bool immediate = true}) {
    if (_disposed || changeEventsAvailable == available) return;
    changeEventsAvailable = available;
    if (immediate) {
      notifyRelevantEvent(recoveryConverging: true);
    } else {
      refreshEligibility();
    }
  }

  void notifySessionsChanged(String changedDurableChatId) {
    final current = _durableChatId().trim();
    if (current.isEmpty || changedDurableChatId.trim() != current) return;
    notifyRelevantEvent(recoveryConverging: true);
  }

  /// re1215: `sessions.changed` without a session id. Any agent writing the
  /// shared store fires it (floored to one per 2 s on the server), so while
  /// another session works it arrives every couple of seconds and an
  /// immediate read per tick polled the open idle chat every 2 s. Desktop
  /// trails these ticks on a 10 s gap (`SESSIONS_LIST_TICK_GAP_MS`): the
  /// first tick after a quiet gap reads at once, later ones collapse into one
  /// read when the gap ends. Nothing is dropped, only coalesced.
  void notifyDurableStoreChanged() {
    if (_disposed) return;
    if (_storeChangeGapTimer != null) {
      _storeChangePending = true;
      return;
    }
    _startStoreChangeGap();
    notifyRelevantEvent();
  }

  void _startStoreChangeGap() {
    _storeChangeGapTimer = Timer(storeChangeGap, () {
      _storeChangeGapTimer = null;
      if (_disposed || !_storeChangePending) return;
      _storeChangePending = false;
      _startStoreChangeGap();
      notifyRelevantEvent();
    });
  }

  void notifyRelevantEvent({
    bool recoveryConverging = false,
    bool terminal = false,
  }) {
    if (_disposed) return;
    _consecutiveFailures = 0;
    _lastConvergenceSnapshot = null;
    _settledConvergenceSnapshot = null;
    _agreeingSnapshots = 0;
    _terminalObserved = terminal;
    if (terminal) {
      _eventRecoveryConverging = false;
    } else if (recoveryConverging) {
      _eventRecoveryConverging = true;
    }
    if (!_visible) return;
    _requestImmediateRead();
  }

  void refreshEligibility({bool immediate = false}) {
    if (_disposed || !_visible) return;
    if (immediate) {
      notifyRelevantEvent();
      return;
    }
    if (_readInFlight) return;
    _timer?.cancel();
    _timer = null;
    _generation += 1;
    _schedule(_successDelay, _generation);
  }

  Duration get _successDelay {
    if (!changeEventsAvailable) return successInterval;
    if (_terminalObserved) return eventBackstopInterval;
    final snapshot = (
      active: _externallyOwnedTurnActive(),
      recovery: _eventRecoveryConverging || _recoveryConverging(),
    );
    if ((snapshot.active || snapshot.recovery) &&
        snapshot != _settledConvergenceSnapshot) {
      return activeInterval;
    }
    return eventBackstopInterval;
  }

  void _requestImmediateRead() {
    _generation += 1;
    _timer?.cancel();
    _timer = null;
    if (_readInFlight) {
      _immediateReadPending = true;
      return;
    }
    _schedule(Duration.zero, _generation);
  }

  void _schedule(Duration delay, int generation) {
    if (_disposed || !_visible || generation != _generation) return;
    _timer = Timer(delay, () => _run(generation));
  }

  Future<void> _run(int generation) async {
    _timer = null;
    if (_disposed || !_visible || generation != _generation) return;
    if (_readInFlight || !canRead()) {
      _schedule(_successDelay, generation);
      return;
    }

    _readInFlight = true;
    var succeeded = false;
    try {
      succeeded = await read();
    } catch (_) {
      succeeded = false;
    } finally {
      _readInFlight = false;
    }

    if (_disposed || !_visible) return;
    if (_immediateReadPending) {
      _immediateReadPending = false;
      _schedule(Duration.zero, _generation);
      return;
    }
    if (generation != _generation) return;
    if (succeeded) {
      _consecutiveFailures = 0;
      _observeConvergenceSnapshot();
      _schedule(_successDelay, generation);
      return;
    }

    _consecutiveFailures += 1;
    final index = math.min(
      _consecutiveFailures - 1,
      failureIntervals.length - 1,
    );
    _schedule(failureIntervals[index], generation);
  }

  void _observeConvergenceSnapshot() {
    if (!changeEventsAvailable) return;
    final snapshot = (
      active: _externallyOwnedTurnActive(),
      recovery: _eventRecoveryConverging || _recoveryConverging(),
    );
    if (!snapshot.active && !snapshot.recovery) {
      _eventRecoveryConverging = false;
      _lastConvergenceSnapshot = null;
      _settledConvergenceSnapshot = null;
      _agreeingSnapshots = 0;
      return;
    }
    if (snapshot == _lastConvergenceSnapshot) {
      _agreeingSnapshots += 1;
    } else {
      _lastConvergenceSnapshot = snapshot;
      _agreeingSnapshots = 1;
    }
    if (_agreeingSnapshots >= 2) {
      _settledConvergenceSnapshot = snapshot;
      _eventRecoveryConverging = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _visible = false;
    _generation += 1;
    _timer?.cancel();
    _timer = null;
    _storeChangeGapTimer?.cancel();
    _storeChangeGapTimer = null;
    _storeChangePending = false;
    _immediateReadPending = false;
  }
}
