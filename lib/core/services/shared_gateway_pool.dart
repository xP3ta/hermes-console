import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/connection.dart';
import 'tui_gateway_client.dart';

/// Conexión Desktop compartida para observadores de solo lectura (inicio,
/// biblioteca de sesiones, mascota, salas, listener de fondo), igual que
/// Desktop comparte un único `HermesGateway` por backend+perfil en lugar de
/// abrir un WebSocket por pantalla. Cada usuario toma un [SharedGatewayLease]
/// y lo libera al terminar.
///
/// Con el último release el socket NO se cierra enseguida: queda
/// [idleLinger] a la espera del siguiente acquire (una pantalla que vuelve,
/// un one-shot de Mission Control, el siguiente tick). Así no se paga un
/// handshake + ticket del dashboard por cada uso breve. [disconnectIdle]
/// cierra ya los que no tienen préstamo (app en segundo plano sin servicio
/// que los necesite).
///
/// Los chats conservan su cliente propio: su ciclo de vida (resume, turnos,
/// liberación a Desktop) es por sesión y no se comparte.
class SharedGatewayPool {
  SharedGatewayPool._() : factory = null, linger = null;

  /// Pool aislado para tests (no comparte entradas con [instance]).
  @visibleForTesting
  SharedGatewayPool.forTesting({this.factory, this.linger = idleLinger});

  /// Global test hook: widget suites that never pump 5 min set this to
  /// [Duration.zero] (close on last release, as before) so no linger timer
  /// outlives the widget tree.
  @visibleForTesting
  static Duration? debugDefaultLinger;

  static final SharedGatewayPool instance = SharedGatewayPool._();

  /// Tiempo que un socket sin préstamos sigue abierto antes de cerrarse.
  static const idleLinger = Duration(minutes: 5);

  final TuiGatewayClient Function(SavedConnection connection)? factory;

  /// Per-pool linger override (tests); null uses the default.
  final Duration? linger;
  final Map<String, _PoolEntry> _entries = {};

  Duration get _effectiveLinger => linger ?? debugDefaultLinger ?? idleLinger;

  /// Número de sockets compartidos vivos (diagnóstico/tests).
  int get liveClientCount => _entries.length;

  /// Préstamos activos en total (diagnóstico/tests).
  int get leaseCount => _entries.values.fold(0, (sum, e) => sum + e.refs);

  SharedGatewayLease acquire(
    SavedConnection connection, {
    TuiGatewayClient Function(SavedConnection connection)? factory,
  }) {
    final key = _keyFor(connection);
    var entry = _entries[key];
    if (entry == null || entry.client.isClosed) {
      entry?.linger?.cancel();
      entry = _PoolEntry(
        (factory ?? this.factory ?? TuiGatewayClient.new)(connection),
      );
      _entries[key] = entry;
    }
    entry.linger?.cancel();
    entry.linger = null;
    entry.refs++;
    return SharedGatewayLease._(this, key, entry);
  }

  void _release(String key, _PoolEntry entry) {
    entry.refs--;
    if (entry.refs > 0) return;
    if (!identical(_entries[key], entry)) {
      unawaited(entry.client.close());
      return;
    }
    entry.linger?.cancel();
    final wait = _effectiveLinger;
    if (wait <= Duration.zero) {
      _closeEntry(key, entry);
      return;
    }
    entry.linger = Timer(wait, () => _closeEntry(key, entry));
  }

  void _closeEntry(String key, _PoolEntry entry) {
    entry.linger?.cancel();
    entry.linger = null;
    if (entry.refs > 0) return;
    if (identical(_entries[key], entry)) _entries.remove(key);
    unawaited(entry.client.close());
  }

  /// Cierra ya los sockets sin préstamo (los que solo estaban en linger).
  /// Pensado para la app en segundo plano cuando ningún servicio los usa.
  void disconnectIdle() {
    for (final entry in _entries.entries.toList()) {
      if (entry.value.refs <= 0) _closeEntry(entry.key, entry.value);
    }
  }

  /// Sondea cada socket vivo del pool (cambio de red). Un socket medio
  /// abierto cae por la ruta normal y su dueño aplica el backoff.
  Future<void> probeAll() async {
    await Future.wait([
      for (final entry in _entries.values.toList())
        if (!entry.client.isClosed)
          entry.client.probeNow().then<void>((_) {}, onError: (Object _) {}),
    ]);
  }

  /// Cierra todo (fin del isolate o tests).
  Future<void> closeAll() async {
    final entries = _entries.values.toList();
    _entries.clear();
    for (final entry in entries) {
      entry.linger?.cancel();
      entry.linger = null;
    }
    await Future.wait([for (final e in entries) e.client.close()]);
  }

  /// La identidad incluye todo lo que cambia el destino o las credenciales:
  /// una conexión editada nunca reutiliza el socket anterior.
  static String _keyFor(SavedConnection c) =>
      Object.hash(c.id, c.baseUrl, c.apiKey, c.kind, c.readOnly).toString();
}

class _PoolEntry {
  _PoolEntry(this.client);

  final TuiGatewayClient client;
  int refs = 0;
  Timer? linger;
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
