import 'package:flutter/foundation.dart';

import 'bridge_client.dart';
import 'bridge_endpoint_resolver.dart';
import 'connection_manager.dart';
import 'secure_storage.dart';

/// Estado del Mobile Bridge para una instancia, resuelto por [BridgeManager].
enum BridgeStatus {
  /// No hay instancia/host del que derivar una URL.
  notConfigured,

  /// Hay URL (derivada o guardada) pero el bridge no responde (no habilitado).
  unreachable,

  /// El bridge responde pero falta el token (solo hay que añadirlo).
  needsToken,

  /// El bridge responde pero el token es inválido/sin scope.
  authFailed,

  /// Conectado y autenticado.
  connected,
}

@immutable
class BridgeState {
  final BridgeStatus status;
  final String url; // URL efectiva (derivada o guardada)
  final bool urlIsDerived; // true si se dedujo del host del gateway
  final bool hasToken;
  final BridgeCapabilities caps;

  /// Causa concreta cuando [status] es [BridgeStatus.unreachable] (conexión
  /// rechazada, host no resuelto, timeout, TLS, HTTP…). Vacío si no aplica.
  /// La UI lo muestra como diagnóstico real en vez de un mensaje genérico.
  final String errorDetail;

  const BridgeState({
    required this.status,
    required this.url,
    required this.urlIsDerived,
    required this.hasToken,
    required this.caps,
    this.errorDetail = '',
  });

  static const unknown = BridgeState(
    status: BridgeStatus.notConfigured,
    url: '',
    urlIsDerived: false,
    hasToken: false,
    caps: BridgeCapabilities.offline,
  );

  /// El bridge está corriendo (aunque falte token o sea inválido).
  bool get running =>
      status == BridgeStatus.needsToken ||
      status == BridgeStatus.authFailed ||
      status == BridgeStatus.connected;

  bool get connected => status == BridgeStatus.connected;
}

/// Contrato mínimo que las pantallas usan para resolver un Bridge.
///
/// Permite probar que una instancia de solo lectura nunca autoprovisiona
/// credenciales sin acoplar los widgets al almacenamiento real.
abstract interface class BridgeManagerContract {
  Future<BridgeState> probe(String connectionId);
  Future<BridgeProvisionResult> provision(String connectionId);
  Future<bool> tryProvision(String connectionId);
  Future<BridgeClient?> clientFor(String connectionId);
}

/// Resuelve y sondea el Mobile Bridge de forma centralizada para todas las
/// pantallas (memoria, SOUL, cron, config, skills).
///
/// Autodetección: si el usuario no guardó una URL, se deriva del host del
/// gateway de la instancia (`host:9131`), así no hay que teclear IP/puerto.
/// Solo el token es secreto y se pide una vez. Si el bridge no está habilitado,
/// [probe] lo indica para mostrar instrucciones y permitir añadirlo.
class BridgeManager implements BridgeManagerContract {
  final SecureStorage _secure;
  final ConnectionManager _connections;

  BridgeManager(this._secure, this._connections);

  SavedConnection? _conn(String id) {
    for (final c in _connections.getConnections()) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// URL efectiva del bridge para la instancia: la guardada por el usuario o,
  /// si no hay, la derivada del host del gateway. Null si no hay instancia.
  Future<({String url, bool derived})?> effectiveUrl(
    String connectionId,
  ) async {
    final stored = await _secure.readBridge(connectionId, 'url');
    if (stored != null && stored.trim().isNotEmpty) {
      return (url: stored.trim(), derived: false);
    }
    final conn = _conn(connectionId);
    if (conn == null) return null;
    final endpoint = BridgeEndpointResolver.resolve(conn);
    return (url: endpoint.url, derived: endpoint.derived);
  }

  /// URL que se derivaría del host del gateway (sin mirar lo guardado).
  String? derivedUrlFor(String connectionId) {
    final conn = _conn(connectionId);
    return conn == null ? null : BridgeEndpointResolver.resolve(conn).url;
  }

  Future<String?> token(String connectionId) =>
      _secure.readBridge(connectionId, 'token');

  /// Sondea el bridge: corre / necesita token / auth inválido / capacidades.
  @override
  Future<BridgeState> probe(String connectionId) async {
    final eu = await effectiveUrl(connectionId);
    if (eu == null) return BridgeState.unknown;
    final tok = await token(connectionId);
    final hasToken = tok != null && tok.isNotEmpty;
    final client = BridgeClient(baseUrl: eu.url, token: tok ?? '');
    try {
      final h = await client.healthDiagnose();
      if (!h.ok) {
        return BridgeState(
          status: BridgeStatus.unreachable,
          url: eu.url,
          urlIsDerived: eu.derived,
          hasToken: hasToken,
          caps: BridgeCapabilities.offline,
          errorDetail: h.detail,
        );
      }
      if (!hasToken) {
        return BridgeState(
          status: BridgeStatus.needsToken,
          url: eu.url,
          urlIsDerived: eu.derived,
          hasToken: false,
          caps: const BridgeCapabilities(online: true, authValid: false),
        );
      }
      final caps = await client.detect();
      final status = !caps.online
          ? BridgeStatus.unreachable
          : !caps.authValid
          ? BridgeStatus.authFailed
          : BridgeStatus.connected;
      return BridgeState(
        status: status,
        url: eu.url,
        urlIsDerived: eu.derived,
        hasToken: true,
        caps: caps,
      );
    } finally {
      client.close();
    }
  }

  /// Intenta autoprovisionar el token del bridge usando la API key del gateway.
  /// Para instancias remotas requiere API key. Para instancias localhost
  /// (gateway local sin auth) intenta provision con clave vacía: el bridge
  /// valida la identidad contra el gateway local, que acepta peticiones sin
  /// autenticación. Guarda el token y devuelve true si tiene éxito.
  @override
  Future<BridgeProvisionResult> provision(String connectionId) async {
    final conn = _conn(connectionId);
    if (conn == null) {
      return const BridgeProvisionResult.failure(
        BridgeProvisionFailure.unexpectedResponse,
      );
    }
    final isLocal =
        conn.host == '127.0.0.1' ||
        conn.host == 'localhost' ||
        conn.host == '10.0.2.2';
    if (conn.apiKey.trim().isEmpty && !isLocal) {
      return const BridgeProvisionResult.failure(
        BridgeProvisionFailure.missingApiKey,
      );
    }
    late final ({String url, bool derived})? eu;
    try {
      eu = await effectiveUrl(connectionId);
    } catch (_) {
      return const BridgeProvisionResult.failure(
        BridgeProvisionFailure.secureStorage,
      );
    }
    if (eu == null) {
      return const BridgeProvisionResult.failure(
        BridgeProvisionFailure.invalidUrl,
      );
    }
    final result = await BridgeClient.provisionDetailed(
      eu.url,
      conn.apiKey.trim(),
      allowEmptyGatewayKey: isLocal,
    );
    if (!result.ok) return result;
    try {
      await save(
        connectionId,
        token: result.token!,
        urlOverride: eu.derived ? '' : eu.url,
      );
    } catch (_) {
      return const BridgeProvisionResult.failure(
        BridgeProvisionFailure.secureStorage,
      );
    }
    return result;
  }

  @override
  Future<bool> tryProvision(String connectionId) async =>
      (await provision(connectionId)).ok;

  /// Cliente listo para operar, o null si falta URL o token.
  @override
  Future<BridgeClient?> clientFor(String connectionId) async {
    final eu = await effectiveUrl(connectionId);
    final tok = await token(connectionId);
    if (eu == null || tok == null || tok.isEmpty) return null;
    return BridgeClient(baseUrl: eu.url, token: tok);
  }

  /// Guarda el token (y opcionalmente una URL manual que sobreescribe la
  /// derivada). Pasar [urlOverride] vacío/null mantiene la autodetección.
  Future<void> save(
    String connectionId, {
    required String token,
    String? urlOverride,
  }) async {
    await _secure.writeBridge(connectionId, 'token', token.trim());
    final override = urlOverride?.trim() ?? '';
    if (override.isEmpty) {
      // Borra la URL guardada para volver a la autodetección.
      await _secure.writeBridge(connectionId, 'url', '');
    } else {
      await _secure.writeBridge(connectionId, 'url', override);
    }
  }

  Future<void> clear(String connectionId) => _secure.deleteBridge(connectionId);
}
