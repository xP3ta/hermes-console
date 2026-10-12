/// Estado estable para los sondeos de salud de una conexión.
///
/// Un único fallo breve no convierte una conexión sana en offline. Además,
/// cada sondeo recibe una generación para que una respuesta antigua no pueda
/// sobrescribir el resultado de una comprobación más reciente.
class ConnectionHealthTracker {
  ConnectionHealthTracker({this.failuresBeforeOffline = 2})
    : assert(failuresBeforeOffline > 0);

  final int failuresBeforeOffline;

  int _generation = 0;
  int _consecutiveFailures = 0;
  bool _healthy = false;
  bool _checking = true;

  int get consecutiveFailures => _consecutiveFailures;
  bool get healthy => _healthy;
  bool get checking => _checking;

  /// What a status label shows: «checking» only while no healthy state is
  /// known. A re-probe of a healthy connection keeps it «online».
  bool get showsChecking => _checking && !_healthy;

  int beginProbe() {
    _checking = true;
    return ++_generation;
  }

  /// Devuelve false si [generation] pertenece a un sondeo ya reemplazado.
  bool recordResult(int generation, {required bool healthy}) {
    if (generation != _generation) return false;
    if (healthy) {
      _consecutiveFailures = 0;
      _healthy = true;
      _checking = false;
      return true;
    }

    _consecutiveFailures++;
    if (_consecutiveFailures >= failuresBeforeOffline) {
      _healthy = false;
      _checking = false;
    } else {
      // Conserva el último estado sano mientras confirmamos que no fue un
      // microcorte. En el primer arranque mantiene la pantalla "conectando".
      _checking = true;
    }
    return true;
  }

  Duration get retryDelay => _consecutiveFailures < failuresBeforeOffline
      ? const Duration(seconds: 3)
      : const Duration(seconds: 30);
}
