import 'dart:collection';

/// Suprime la doble entrega inmediata del mismo deep link que algunos backends
/// Android publican tanto en `getInitialLink()` como en `uriLinkStream`.
///
/// La ventana es deliberadamente corta: un enlace diferente siempre pasa y el
/// mismo enlace puede volver a abrirse después, por ejemplo si el usuario desea
/// revisar otra vez la instancia.
final class PairingLinkDeliveryGate {
  PairingLinkDeliveryGate({
    DateTime Function()? now,
    this.duplicateWindow = const Duration(seconds: 2),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration duplicateWindow;

  final Map<String, DateTime> _recentlyAccepted = <String, DateTime>{};
  final Queue<Uri> _deferred = Queue<Uri>();

  bool get hasDeferred => _deferred.isNotEmpty;

  void defer(Uri uri) {
    final fingerprint = uri.toString();
    if (_deferred.any((candidate) => candidate.toString() == fingerprint)) {
      return;
    }
    _deferred.addLast(uri);
  }

  Uri? takeDeferredIf(bool canConsume) {
    if (!canConsume || _deferred.isEmpty) return null;
    return _deferred.removeFirst();
  }

  Uri? takeDeferred() => takeDeferredIf(true);

  bool shouldHandle(Uri uri) {
    final fingerprint = uri.toString();
    final current = _now();
    _recentlyAccepted.removeWhere((_, acceptedAt) {
      final elapsed = current.difference(acceptedAt);
      return elapsed.isNegative || elapsed >= duplicateWindow;
    });
    if (_recentlyAccepted.containsKey(fingerprint)) return false;

    _recentlyAccepted[fingerprint] = current;
    return true;
  }
}
