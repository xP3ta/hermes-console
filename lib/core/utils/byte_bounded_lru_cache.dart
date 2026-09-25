import 'dart:collection';

import 'package:flutter/foundation.dart';

/// LRU acotada a la vez por número de entradas y por tamaño aproximado.
///
/// [sizeOf] estima el coste de una entrada (clave + valor). Una entrada que
/// por sí sola supera [maxBytes] no se guarda: nunca vacía la caché para
/// alojar un único valor gigante.
final class ByteBoundedLruCache<K, V> {
  ByteBoundedLruCache({
    required this.maxEntries,
    required this.maxBytes,
    required this.sizeOf,
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0);

  final int maxEntries;
  final int maxBytes;
  final int Function(K key, V value) sizeOf;

  final LinkedHashMap<K, ({V value, int bytes})> _entries = LinkedHashMap();
  int _bytes = 0;

  int get length => _entries.length;
  int get bytes => _bytes;

  /// Devuelve el valor y lo marca como el más reciente.
  ({V value})? lookup(K key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    return (value: entry.value);
  }

  void put(K key, V value) {
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.bytes;
    final size = sizeOf(key, value);
    if (size < 0 || size > maxBytes) return;
    _entries[key] = (value: value, bytes: size);
    _bytes += size;
    while (_entries.length > maxEntries || _bytes > maxBytes) {
      final eldest = _entries.keys.first;
      _bytes -= _entries.remove(eldest)!.bytes;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  @visibleForTesting
  Iterable<K> get keysOldestFirstForTesting => _entries.keys;
}

/// Punto único para vaciar las cachés de render estáticas (proceso) cuando
/// cambia la autoridad de los datos: borrar una conexión, revocar todas las
/// API keys o cambiar de perfil. Vive en `utils` para que los servicios no
/// importen pantallas.
abstract final class PrivateRenderCaches {
  static final Set<VoidCallback> _clearers = <VoidCallback>{};

  static void register(VoidCallback clear) => _clearers.add(clear);

  /// Para tests que registran clearers temporales: evita que se acumulen
  /// entre casos (el conjunto es estático de proceso).
  static void unregister(VoidCallback clear) => _clearers.remove(clear);

  @visibleForTesting
  static int get registeredCountForTesting => _clearers.length;

  static void clearAll() {
    for (final clear in List<VoidCallback>.of(_clearers)) {
      clear();
    }
  }
}
