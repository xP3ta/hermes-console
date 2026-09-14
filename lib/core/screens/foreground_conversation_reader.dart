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
    required this.failureIntervals,
    required this.canRead,
    required this.read,
  }) : assert(failureIntervals.isNotEmpty);

  final Duration successInterval;
  final List<Duration> failureIntervals;
  final bool Function() canRead;
  final Future<bool> Function() read;

  Timer? _timer;
  bool _visible = false;
  bool _disposed = false;
  bool _readInFlight = false;
  int _generation = 0;
  int _consecutiveFailures = 0;

  void setVisible(bool visible, {bool immediate = false}) {
    if (_disposed) return;
    if (_visible == visible && !immediate) return;
    _visible = visible;
    _generation += 1;
    _timer?.cancel();
    _timer = null;
    if (_visible) {
      _schedule(immediate ? Duration.zero : successInterval, _generation);
    }
  }

  void refreshEligibility({bool immediate = false}) {
    if (_disposed || !_visible || _readInFlight) return;
    _timer?.cancel();
    _timer = null;
    _generation += 1;
    _schedule(immediate ? Duration.zero : successInterval, _generation);
  }

  void _schedule(Duration delay, int generation) {
    if (_disposed || !_visible || generation != _generation) return;
    _timer = Timer(delay, () => _run(generation));
  }

  Future<void> _run(int generation) async {
    _timer = null;
    if (_disposed || !_visible || generation != _generation) return;
    if (_readInFlight || !canRead()) {
      _schedule(successInterval, generation);
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

    if (_disposed || !_visible || generation != _generation) return;
    if (succeeded) {
      _consecutiveFailures = 0;
      _schedule(successInterval, generation);
      return;
    }

    _consecutiveFailures += 1;
    final index = math.min(
      _consecutiveFailures - 1,
      failureIntervals.length - 1,
    );
    _schedule(failureIntervals[index], generation);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _visible = false;
    _generation += 1;
    _timer?.cancel();
    _timer = null;
  }
}
