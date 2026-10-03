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
/// Los chats abiertos de una conexión comparten otro socket propio
/// ([acquireChat]), multiplexado por `session_id` como el único
/// `JsonRpcGatewayClient` de Desktop: un handshake, un heartbeat y una
/// reconexión para todos, cada chat con su sesión, su watermark y su estado.
/// Va aparte de los observadores para que estos sigan sin recibir los frames
/// de los chats y para que, al soltar el último chat, el socket se cierre tras
/// la gracia corta de un chat y Hermes recoja los runtimes que nadie lee
/// (igual que al cerrar el socket propio de cada chat).
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
  }) => _acquire(_keyFor(connection), connection, factory: factory);

  /// The chat socket of ([connection], [profile]): one WebSocket that every
  /// open chat of that profile multiplexes its session over. After the last
  /// chat lets go it lingers [chatLinger] (a reopen skips the handshake) and
  /// then closes.
  SharedGatewayLease acquireChat(
    SavedConnection connection, {
    required String profile,
    required Duration chatLinger,
    TuiGatewayClient Function(SavedConnection connection)? factory,
  }) => _acquire(
    _chatKeyFor(connection, profile),
    connection,
    factory: factory,
    chatLinger: chatLinger,
  );

  static const String _chatLane = '|chat';

  static String _chatKeyFor(SavedConnection connection, String profile) =>
      '${_keyFor(connection)}|${profile.trim()}$_chatLane';

  /// Another chat may not join the chat socket of ([connection], [profile]):
  /// chats already ride it and it has not proven per-session replay (a
  /// connected `gateway.ready` with `replay_epoch`). Before that frame the
  /// transport is unknown (several chats opened at once would otherwise all
  /// ride a socket that may turn out legacy), and a legacy server cannot
  /// re-attach each chat from its own watermark after a drop. Such chats keep
  /// their own socket; with no rider yet the chat may take it alone.
  bool chatSocketRefusesAnotherChat(
    SavedConnection connection,
    String profile,
  ) {
    final entry = _entries[_chatKeyFor(connection, profile)];
    return entry != null &&
        !entry.client.isClosed &&
        entry.refs > 0 &&
        !entry.client.knownPerSessionReplayTransport;
  }

  /// Live chat sockets (diagnostics/tests).
  @visibleForTesting
  int get chatClientCount =>
      _entries.keys.where((key) => key.endsWith(_chatLane)).length;

  SharedGatewayLease _acquire(
    String key,
    SavedConnection connection, {
    TuiGatewayClient Function(SavedConnection connection)? factory,
    Duration? chatLinger,
  }) {
    var entry = _entries[key];
    if (entry == null || entry.client.isClosed) {
      entry?.linger?.cancel();
      final client = (factory ?? this.factory ?? TuiGatewayClient.new)(
        connection,
      );
      if (chatLinger != null) client.enableSessionMultiplexing();
      entry = _PoolEntry(client, linger: chatLinger);
      _entries[key] = entry;
    }
    entry.linger?.cancel();
    entry.linger = null;
    entry.refs++;
    return SharedGatewayLease._(this, key, entry);
  }

  /// Lends the shared socket only when it is already open and connected, so
  /// a one-shot read (the chat model picker, mk1215) can ride a warm socket
  /// without ever opening a new one. `null` otherwise; nothing is created.
  SharedGatewayLease? acquireIfConnected(SavedConnection connection) {
    final key = _keyFor(connection);
    final entry = _entries[key];
    if (entry == null || entry.client.isClosed || !entry.client.isConnected) {
      return null;
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
    // Widget suites pin [debugDefaultLinger] to zero so no timer outlives
    // the tree; that applies to chat sockets too.
    final wait = entry.ownLinger == null
        ? _effectiveLinger
        : debugDefaultLinger ?? entry.ownLinger!;
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

  /// Cierra ya los sockets de chat sin préstamo (en su gracia tras soltar el
  /// último chat): cambio de red, presión de memoria o segundo plano.
  void disconnectIdleChats() {
    for (final entry in _entries.entries.toList()) {
      if (entry.key.endsWith(_chatLane) && entry.value.refs <= 0) {
        _closeEntry(entry.key, entry.value);
      }
    }
  }

  /// Retires every chat socket after a credential change (Dashboard secret
  /// or auth mode, which the pool key cannot see). A retired socket serves
  /// no new chat: the next [acquireChat] dials with the new credentials.
  /// Chats still riding it keep it until they let go; it then closes at
  /// once instead of lingering for a reopen.
  void retireChatSockets() {
    for (final entry in _entries.entries.toList()) {
      if (!entry.key.endsWith(_chatLane)) continue;
      _entries.remove(entry.key);
      entry.value.linger?.cancel();
      entry.value.linger = null;
      if (entry.value.refs <= 0) unawaited(entry.value.client.close());
    }
  }

  /// Sondea cada socket vivo del pool (cambio de red). Un socket medio
  /// abierto cae por la ruta normal y su dueño aplica el backoff. Los ya
  /// caídos olvidan el backoff de la red anterior (rl1215).
  Future<void> probeAll() async {
    for (final entry in _entries.values) {
      if (!entry.client.isClosed) {
        entry.client.resetReconnectBackoffForNetworkChange();
      }
    }
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
  _PoolEntry(this.client, {Duration? linger}) : ownLinger = linger;

  final TuiGatewayClient client;

  /// Linger of this entry after its last release (chat sockets); null uses
  /// the pool default.
  final Duration? ownLinger;
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
