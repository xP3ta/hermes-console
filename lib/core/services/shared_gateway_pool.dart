import 'dart:async';

import '../models/connection.dart';
import 'tui_gateway_client.dart';

/// Conexión Desktop compartida para observadores de solo lectura (inicio,
/// biblioteca de sesiones, mascota), igual que Desktop comparte un único
/// `HermesGateway` por backend+perfil en lugar de abrir un WebSocket por
/// pantalla. Cada pantalla toma un [SharedGatewayLease] y lo libera al
/// desmontarse; el socket se cierra cuando se libera el último.
///
/// Los chats conservan su cliente propio: su ciclo de vida (resume, turnos,
/// liberación a Desktop) es por sesión y no se comparte.
class SharedGatewayPool {
  SharedGatewayPool._();

  static final SharedGatewayPool instance = SharedGatewayPool._();

  final Map<String, _PoolEntry> _entries = {};

  /// Número de sockets compartidos vivos (diagnóstico/tests).
  int get liveClientCount => _entries.length;

  SharedGatewayLease acquire(
    SavedConnection connection, {
    TuiGatewayClient Function(SavedConnection connection)? factory,
  }) {
    final key = _keyFor(connection);
    var entry = _entries[key];
    if (entry == null || entry.client.isClosed) {
      entry = _PoolEntry(
        (factory ?? TuiGatewayClient.new)(connection),
      );
      _entries[key] = entry;
    }
    entry.refs++;
    return SharedGatewayLease._(this, key, entry);
  }

  void _release(String key, _PoolEntry entry) {
    entry.refs--;
    if (entry.refs > 0) return;
    if (identical(_entries[key], entry)) _entries.remove(key);
    unawaited(entry.client.close());
  }

  /// La identidad incluye todo lo que cambia el destino o las credenciales:
  /// una conexión editada nunca reutiliza el socket anterior.
  static String _keyFor(SavedConnection c) => Object.hash(
    c.id,
    c.baseUrl,
    c.apiKey,
    c.kind,
    c.readOnly,
  ).toString();
}

class _PoolEntry {
  _PoolEntry(this.client);

  final TuiGatewayClient client;
  int refs = 0;
}

/// Préstamo de la conexión compartida. [release] es idempotente.
class SharedGatewayLease {
  SharedGatewayLease._(this._pool, this._key, this._entry);

  final SharedGatewayPool _pool;
  final String _key;
  final _PoolEntry _entry;
  bool _released = false;

  TuiGatewayClient get client => _entry.client;

  void release() {
    if (_released) return;
    _released = true;
    _pool._release(_key, _entry);
  }
}
