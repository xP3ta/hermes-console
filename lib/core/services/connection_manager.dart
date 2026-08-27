// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/agent_profile.dart';
import '../models/capability_matrix.dart';
import '../models/connection.dart';
import '../utils/transport_privacy.dart';
import '../models/memory_info.dart';
import '../models/model_active_info.dart';
import '../models/model_info.dart';
import '../models/model_provider.dart';
import '../models/moa_config.dart';
import '../models/session.dart';
import 'chat_draft_store.dart';
import 'bridge_client.dart';
import 'mission_bot_chat_store.dart';
import 'secure_storage.dart';
import 'turn_outbox_store.dart';

// Re-export for convenience
export '../models/capability_matrix.dart';
export '../models/connection.dart';
export '../models/memory_info.dart';
export '../models/model_active_info.dart';
export '../models/model_info.dart';
export '../models/model_provider.dart';
export '../models/session.dart';

typedef BridgeClientFactory =
    BridgeClient Function({required String baseUrl, required String token});
typedef BridgeProvisioner =
    Future<String?> Function(String baseUrl, String gatewayKey);
typedef DashboardClientFactory =
    DashboardClient Function(SavedConnection connection);
typedef ClearCancelledTurnsForConnection = Future<int> Function(String id);

@visibleForTesting
bool supportsKanbanTrackedCreateVersion(String? rawVersion) {
  final value = rawVersion?.trim() ?? '';
  final match = RegExp(
    r'(?:^|[^0-9])(\d+)\.(\d+)\.(\d+)(?:[^0-9]|$)',
  ).firstMatch(value);
  if (match == null) return false;
  final major = int.tryParse(match.group(1)!);
  final minor = int.tryParse(match.group(2)!);
  final patch = int.tryParse(match.group(3)!);
  if (major == null || minor == null || patch == null) return false;

  bool atLeast(int expectedMajor, int expectedMinor, int expectedPatch) {
    if (major != expectedMajor) return major > expectedMajor;
    if (minor != expectedMinor) return minor > expectedMinor;
    return patch >= expectedPatch;
  }

  return major >= 2000 ? atLeast(2026, 5, 7) : atLeast(0, 13, 0);
}

/// Manages saved remote connections.
///
/// Connection metadata (label, host, port) is stored in SharedPreferences.
/// API keys are stored exclusively in Android Keystore via [SecureStorage].
/// Use [ConnectionManager.create] to initialise; do not call the constructor
/// directly.
class ConnectionManager {
  static const String _key = 'saved_connections';
  static const Uuid _uuid = Uuid();

  /// Instancia que el usuario fija como predeterminada: la app arranca SIEMPRE
  /// con ella (ver [applyDefaultOnLaunch]). Distinta de [lastConnKey], que es la
  /// "activa" de la sesión actual y puede cambiarse en caliente sin alterar la
  /// predeterminada.
  static const String defaultConnKey = 'default_connection_id';

  /// Última instancia activa (la que el home lee para abrir/conectar). Se siembra
  /// desde la predeterminada en cada arranque en frío.
  static const String lastConnKey = 'last_connection_id';

  final SharedPreferences prefs;
  final SecureStorage _secure;
  final BridgeClientFactory _bridgeClientFactory;
  final BridgeProvisioner _bridgeProvisioner;
  final DashboardClientFactory _dashboardClientFactory;
  final ClearCancelledTurnsForConnection? _clearCancelledTurns;
  // In-memory cache populated by [_loadApiKeys]. Keeps getConnections() sync.
  final Map<String, String> _apiKeyCache = {};

  /// Perfil de agente activo por instancia (NOUS Profile Builder). `null`/vacío
  /// = perfil por defecto (sin scoping). Notifica para que Modelos/Skills y la
  /// cabecera reaccionen al cambio.
  final ValueNotifier<String?> activeProfile = ValueNotifier<String?>(null);

  /// Id de la instancia activa. Cambia al activar otra instancia desde cualquier
  /// pantalla; el home (y quien escuche) se entera al instante sin reiniciar la
  /// app. Antes, activar una instancia fuera del drawer del home dejaba el home
  /// con la instancia anterior hasta salir y volver a entrar.
  final ValueNotifier<String?> activeConnectionId = ValueNotifier<String?>(
    null,
  );

  ConnectionManager._(
    this.prefs,
    this._secure, {
    BridgeClientFactory? bridgeClientFactory,
    BridgeProvisioner? bridgeProvisioner,
    DashboardClientFactory? dashboardClientFactory,
    ClearCancelledTurnsForConnection? clearCancelledTurns,
  }) : _bridgeClientFactory =
           bridgeClientFactory ??
           (({required baseUrl, required token}) =>
               BridgeClient(baseUrl: baseUrl, token: token)),
       _bridgeProvisioner = bridgeProvisioner ?? BridgeClient.provision,
       _dashboardClientFactory = dashboardClientFactory ?? DashboardClient.lazy,
       _clearCancelledTurns = clearCancelledTurns;

  static String _activeProfileKey(String connId) => 'active_profile_$connId';

  /// Perfil activo guardado para [connId] (vacío = por defecto).
  String activeProfileFor(String connId) =>
      prefs.getString(_activeProfileKey(connId)) ?? '';

  /// Fija el perfil activo de [connId]. Pasa vacío/`default` para volver al
  /// home por defecto.
  Future<void> setActiveProfile(String connId, String profile) async {
    final normalized = (profile == 'default') ? '' : profile;
    if (normalized.isEmpty) {
      await prefs.remove(_activeProfileKey(connId));
    } else {
      await prefs.setString(_activeProfileKey(connId), normalized);
    }
    activeProfile.value = normalized.isEmpty ? null : normalized;
  }

  /// Detiene una tarea programada usando primero el Mobile Bridge (comando
  /// oficial de Hermes) y conservando el Dashboard como fallback para
  /// servidores antiguos. Nunca rota ni reconfigura credenciales.
  Future<void> deleteLinkedCronJob(
    SavedConnection connection,
    String jobId, {
    String? profile,
  }) async {
    // Debe ocurrir antes de leer secretos, provisionar o construir clientes.
    final id = validateCronJobId(jobId);
    final scopedProfile = validateCronProfile(profile);
    Future<void> deleteWithDashboard() async {
      final dashboard = _dashboardClientFactory(connection);
      try {
        await dashboard.deleteCronJob(id, profile: scopedProfile);
      } finally {
        dashboard.close();
      }
    }

    Object? bridgeError;
    Object? dashboardFirstError;
    BridgeClient? bridge;
    var bridgeUrl = connection.derivedBridgeUrl;
    String? bridgeToken;
    try {
      final storedBridgeUrl = await _secure.readBridge(connection.id, 'url');
      if (storedBridgeUrl != null && storedBridgeUrl.trim().isNotEmpty) {
        bridgeUrl = storedBridgeUrl.trim();
      }
      bridgeToken = await _secure.readBridge(connection.id, 'token');
    } catch (error) {
      bridgeError = error;
    }

    final hadStoredBridgeToken = bridgeToken?.isNotEmpty == true;
    if (!hadStoredBridgeToken) {
      // Sin una instalación Bridge ya autenticada, el Dashboard es la ruta
      // normal y disponible en todas las instancias. Probarlo primero evita
      // esperar el timeout de provisión contra hosts (p. ej. workers.dev) que
      // nunca pueden publicar el puerto 9131.
      try {
        await deleteWithDashboard();
        return;
      } on ArgumentError {
        rethrow;
      } on CronDeleteRejectedException {
        rethrow;
      } catch (error) {
        dashboardFirstError = error;
      }

      if (connection.apiKey.trim().isNotEmpty) {
        try {
          bridgeToken = await _bridgeProvisioner(
            bridgeUrl,
            connection.apiKey.trim(),
          );
          if (bridgeToken != null && bridgeToken.isNotEmpty) {
            await _secure.writeBridge(connection.id, 'token', bridgeToken);
          }
        } on ArgumentError {
          rethrow;
        } catch (error) {
          bridgeError = error;
        }
      }
    }

    try {
      if (bridgeToken != null && bridgeToken.isNotEmpty) {
        bridge = _bridgeClientFactory(baseUrl: bridgeUrl, token: bridgeToken);
        final capabilities = await bridge.detect();
        if (capabilities.cronDelete) {
          await bridge.deleteCronJob(id, profile: scopedProfile);
          return;
        }
      }
    } on ArgumentError {
      rethrow;
    } on BridgeException catch (error) {
      bridgeError = error;
      // Un token GUARDADO puede haber cambiado tras reinstalar el servicio.
      // Si acabamos de provisionarlo en esta misma llamada no lo repetimos.
      if (hadStoredBridgeToken &&
          error.kind == BridgeErrorKind.auth &&
          connection.apiKey.trim().isNotEmpty) {
        try {
          bridge?.close();
          bridge = null;
          final freshToken = await _bridgeProvisioner(
            bridgeUrl,
            connection.apiKey.trim(),
          );
          if (freshToken != null && freshToken.isNotEmpty) {
            await _secure.writeBridge(connection.id, 'token', freshToken);
            bridge = _bridgeClientFactory(
              baseUrl: bridgeUrl,
              token: freshToken,
            );
            final capabilities = await bridge.detect();
            if (capabilities.cronDelete) {
              await bridge.deleteCronJob(id, profile: scopedProfile);
              return;
            }
          }
        } on ArgumentError {
          rethrow;
        } catch (retryError) {
          bridgeError = retryError;
        }
      }
    } catch (error) {
      bridgeError = error;
    } finally {
      bridge?.close();
    }

    if (dashboardFirstError != null) {
      if (bridgeError == null) throw dashboardFirstError;
      throw Exception(
        'Dashboard: $dashboardFirstError; Mobile Bridge: $bridgeError',
      );
    }

    try {
      await deleteWithDashboard();
    } on CronDeleteRejectedException {
      rethrow;
    } catch (dashboardError) {
      if (bridgeError == null) rethrow;
      throw Exception(
        'Mobile Bridge: $bridgeError; Dashboard: $dashboardError',
      );
    }
  }

  /// Id de la instancia predeterminada, o `null` si no hay ninguna fijada o la
  /// que estaba fijada ya no existe.
  String? get defaultConnectionId {
    final id = prefs.getString(defaultConnKey);
    if (id == null || id.isEmpty) return null;
    final exists =
        (prefs.getStringList(_key) ?? const []).isNotEmpty &&
        getConnections().any((c) => c.id == id);
    return exists ? id : null;
  }

  /// Fija (o limpia con `null`) la instancia predeterminada.
  Future<void> setDefaultConnection(String? id) async {
    if (id == null || id.isEmpty) {
      await prefs.remove(defaultConnKey);
    } else {
      await prefs.setString(defaultConnKey, id);
    }
  }

  /// Fija la instancia activa de la sesión ([lastConnKey]) y notifica a los
  /// oyentes ([activeConnectionId]) para que se refresquen al instante. Usar
  /// esto en lugar de escribir `lastConnKey` a mano, para que el cambio se
  /// propague aunque se haga desde fuera del home.
  Future<void> setActiveConnection(String id) async {
    if (id.isEmpty) return;
    await prefs.setString(lastConnKey, id);
    activeConnectionId.value = id;
  }

  /// Siembra la instancia activa con la predeterminada en el arranque en frío.
  /// Llamar una sola vez en `main()` antes de construir la app: así el home abre
  /// con la predeterminada, pero el cambio de instancia en caliente (que escribe
  /// [lastConnKey]) sigue respetándose durante la sesión.
  Future<void> applyDefaultOnLaunch() async {
    final defId = defaultConnectionId;
    if (defId != null) {
      await prefs.setString(lastConnKey, defId);
      // Siembra el notifier: sin esto arranca en null y las pantallas que
      // resuelven la instancia activa escuchándolo (Ajustes, home) no tienen
      // valor hasta el primer cambio manual (spec 028).
      activeConnectionId.value = defId;
    }
  }

  /// Async factory. Initialises storage and migrates any plaintext API keys
  /// still present in SharedPreferences into Android Keystore.
  static Future<ConnectionManager> create(
    SharedPreferences prefs, {
    BridgeClientFactory? bridgeClientFactory,
    BridgeProvisioner? bridgeProvisioner,
    DashboardClientFactory? dashboardClientFactory,
    ClearCancelledTurnsForConnection? clearCancelledTurns,
  }) async {
    final manager = ConnectionManager._(
      prefs,
      SecureStorage(),
      bridgeClientFactory: bridgeClientFactory,
      bridgeProvisioner: bridgeProvisioner,
      dashboardClientFactory: dashboardClientFactory,
      clearCancelledTurns: clearCancelledTurns,
    );
    await manager._loadApiKeys();
    // Poda silenciosa de datos huérfanos de instancias borradas (no toca nada
    // de las conexiones vivas ni ajustes globales). Falla suave.
    try {
      await manager.pruneOrphanData();
    } catch (e) {
      debugPrint('[connection] excepción silenciada (se ignora sin más): $e');
    }
    return manager;
  }

  Future<void> _loadApiKeys() async {
    final jsonList = prefs.getStringList(_key) ?? [];
    var needsResave = false;
    final validConnections = <SavedConnection>[];

    for (final j in jsonList) {
      try {
        final map = jsonDecode(j) as Map<String, dynamic>;
        // Migración: el agente local exponía el chat/estado en :8642 (gateway de
        // mensajería), pero esa API la sirve el dashboard en :9119. Reapuntamos
        // las conexiones locales antiguas para que "online" y el chat funcionen.
        final storedKind = (map['kind'] as String?)?.trim();
        final isLegacyLocalKind =
            storedKind == null ||
            storedKind.isEmpty ||
            storedKind == InstanceKind.localhost.name;
        if (map['host'] == '127.0.0.1' &&
            (map['port'] as num?)?.toInt() == 8642 &&
            isLegacyLocalKind) {
          map['port'] = 9119;
          map['dashboard_url'] = 'http://127.0.0.1:9119';
          needsResave = true;
        }
        final conn = SavedConnection.fromMap(map);
        validConnections.add(conn);

        final plainKey = (map['api_key'] as String?) ?? '';
        if (plainKey.isNotEmpty) {
          // Migration: plaintext key found in JSON → move to Keystore
          await _secure.writeApiKey(conn.id, plainKey);
          _apiKeyCache[conn.id] = plainKey;
          needsResave = true;
        } else {
          final stored = await _secure.readApiKey(conn.id);
          if (stored != null && stored.isNotEmpty) {
            _apiKeyCache[conn.id] = stored;
          }
        }
      } catch (e) {
        debugPrint(
          '[connection] excepción silenciada (se continúa sin propagar): $e',
        );
        // Corrupt SharedPrefs entry — exclude from re-save
        needsResave = true;
        continue;
      }
    }

    if (needsResave) {
      await _saveAll(validConnections);
    }
  }

  /// Returns connections with API keys injected from the in-memory cache.
  List<SavedConnection> getConnections() {
    final jsonList = prefs.getStringList(_key) ?? [];
    return jsonList.map((j) {
      final conn = SavedConnection.fromMap(
        jsonDecode(j) as Map<String, dynamic>,
      );
      final cachedKey = _apiKeyCache[conn.id];
      if (cachedKey != null && cachedKey.isNotEmpty) {
        // copyWith preserva todos los campos (incluido onDeviceLoopback) al
        // inyectar la API key cacheada — reconstruir a mano olvidaría campos.
        return conn.copyWith(apiKey: cachedKey);
      }
      return conn;
    }).toList();
  }

  /// Busca una instancia guardada que apunta al mismo endpoint de Gateway.
  /// La credencial no forma parte de la identidad: un QR puede traer un token
  /// rotado para el mismo servidor y debe ofrecer actualizarlo, no duplicarlo.
  SavedConnection? findConnectionByEndpoint({
    required String host,
    required int port,
    required bool useHttps,
    String? excludingId,
  }) {
    String canonicalHost(String value) {
      final normalized = value.trim().toLowerCase();
      return normalized.endsWith('.')
          ? normalized.substring(0, normalized.length - 1)
          : normalized;
    }

    final wantedHost = canonicalHost(host);
    for (final connection in getConnections()) {
      if (connection.id == excludingId) continue;
      if (canonicalHost(connection.host) == wantedHost &&
          connection.port == port &&
          connection.useHttps == useHttps) {
        return connection;
      }
    }
    return null;
  }

  Future<void> saveConnection(
    String label,
    String host,
    int port,
    String apiKey, {
    InstanceKind? kind,
    bool readOnly = false,
  }) async {
    final normalized = SavedConnection.normalizeHostAndPort(host, port);
    final conn = SavedConnection(
      id: _uuid.v4(),
      label: label,
      host: normalized.host,
      port: normalized.port,
      apiKey: apiKey,
      useHttps: normalized.useHttps,
      readOnly: readOnly,
      kind: kind ?? inferInstanceKind(normalized.host),
    );
    await _secure.writeApiKey(conn.id, apiKey);
    _apiKeyCache[conn.id] = apiKey;
    final current = getConnections();
    current.insert(0, conn);
    await _saveAll(current);
  }

  Future<void> updateApiKey(String connId, String apiKey) async {
    await _secure.writeApiKey(connId, apiKey);
    _apiKeyCache[connId] = apiKey;
    // SharedPrefs metadata does not include api_key — no update needed there
  }

  /// Updates the metadata (label, host, port, kind) of an existing connection.
  /// The API key is only updated when [apiKey] is non-null and non-empty.
  Future<void> updateConnection(
    String id, {
    required String label,
    required String host,
    required int port,
    required bool useHttps,
    required InstanceKind kind,
    String? apiKey,
    bool? readOnly,
  }) async {
    if (apiKey != null && apiKey.isNotEmpty) {
      await _secure.writeApiKey(id, apiKey);
      _apiKeyCache[id] = apiKey;
    }
    final current = getConnections();
    final idx = current.indexWhere((c) => c.id == id);
    if (idx == -1) return;
    final existing = current[idx];
    final updated = SavedConnection(
      id: id,
      label: label,
      host: host,
      port: port,
      apiKey: _apiKeyCache[id] ?? existing.apiKey,
      useHttps: useHttps,
      readOnly: readOnly ?? existing.readOnly,
      onDeviceLoopback: existing.onDeviceLoopback,
      kind: kind,
    );
    if (!_sameGatewayEndpoint(existing, updated)) {
      await prefs.remove(_capsKey(id));
    }
    current[idx] = updated;
    await _saveAll(current);
  }

  /// Inserta o reemplaza una conexión completa (formato nuevo del editor de
  /// instancias). Los secretos van por separado: la API key del Gateway con
  /// [apiKey] y los del Dashboard con [setDashboardSecrets].
  Future<void> upsertConnection(SavedConnection conn) async {
    if (conn.apiKey.isNotEmpty) {
      await _secure.writeApiKey(conn.id, conn.apiKey);
      _apiKeyCache[conn.id] = conn.apiKey;
    }
    final current = getConnections();
    final idx = current.indexWhere((c) => c.id == conn.id);
    if (idx == -1) {
      // Un id nuevo no puede heredar una matriz abandonada de otra instancia.
      await prefs.remove(_capsKey(conn.id));
      current.insert(0, conn);
    } else {
      if (!_sameGatewayEndpoint(current[idx], conn)) {
        await prefs.remove(_capsKey(conn.id));
      }
      current[idx] = conn;
    }
    await _saveAll(current);
  }

  // ── Secretos del Dashboard (Keystore) ─────────────────────────────────

  Future<DashboardSecrets> getDashboardSecrets(String connId) async {
    return DashboardSecrets(
      sessionToken: await _secure.readDashboardSecret(connId, 'token'),
      username: await _secure.readDashboardSecret(connId, 'user'),
      password: await _secure.readDashboardSecret(connId, 'pass'),
    );
  }

  Future<void> setDashboardSecrets(
    String connId, {
    String? sessionToken,
    String? username,
    String? password,
  }) async {
    if (sessionToken != null) {
      await _secure.writeDashboardSecret(connId, 'token', sessionToken);
    }
    if (username != null) {
      await _secure.writeDashboardSecret(connId, 'user', username);
    }
    if (password != null) {
      await _secure.writeDashboardSecret(connId, 'pass', password);
    }
  }

  // ── Mobile Bridge (Keystore) ──────────────────────────────────────────

  /// Configuración privada del Mobile Bridge asociada a una instancia.
  ///
  /// La URL vacía significa "usar la derivada del host del Gateway". El token
  /// nunca se incorpora al modelo serializable ni a SharedPreferences.
  Future<({String url, String token})> getBridgeConfig(String connId) async {
    return (
      url: (await _secure.readBridge(connId, 'url') ?? '').trim(),
      token: (await _secure.readBridge(connId, 'token') ?? '').trim(),
    );
  }

  /// Guarda cambios del Bridge sin borrar secretos accidentalmente.
  ///
  /// - [url] no nula reemplaza el override; vacía vuelve a la autodetección.
  /// - [token] solo reemplaza el secreto si contiene un valor. Así, al editar
  ///   una instancia, dejar el campo secreto vacío conserva el token anterior.
  Future<void> setBridgeConfig(
    String connId, {
    String? url,
    String? token,
  }) async {
    if (url != null) {
      await _secure.writeBridge(connId, 'url', url.trim());
    }
    final normalizedToken = token?.trim() ?? '';
    if (normalizedToken.isNotEmpty) {
      await _secure.writeBridge(connId, 'token', normalizedToken);
    }
  }

  Future<void> clearBridgeConfig(String connId) => _secure.deleteBridge(connId);

  // ── Matriz de capacidades (prefs, JSON por instancia) ─────────────────

  static String _capsKey(String connId) => 'capabilities_$connId';
  static const Duration _turnIdempotencyCapabilityTtl = Duration(hours: 24);

  static bool _sameGatewayEndpoint(
    SavedConnection previous,
    SavedConnection next,
  ) =>
      previous.host == next.host &&
      previous.port == next.port &&
      previous.useHttps == next.useHttps;

  CapabilityMatrix loadCapabilities(String connId) {
    final raw = prefs.getString(_capsKey(connId));
    if (raw == null) return const CapabilityMatrix();
    try {
      return CapabilityMatrix.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint(
        '[connection] excepción silenciada (se continúa sin propagar): $e',
      );
      return const CapabilityMatrix();
    }
  }

  Future<void> saveCapabilities(String connId, CapabilityMatrix matrix) =>
      prefs.setString(_capsKey(connId), jsonEncode(matrix.toJson()));

  /// Marca streaming como confirmado tras el primer chat SSE exitoso.
  /// Estático porque ChatScreen no sostiene el manager.
  static Future<void> markStreamingSupported(String connId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _capsKey(connId);
    Map<String, dynamic> json;
    try {
      json = jsonDecode(prefs.getString(key) ?? '{}') as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[connection] excepción silenciada (fallback: json = {}): $e');
      json = {};
    }
    if (json['streaming_supported'] == 'yes') return;
    json['streaming_supported'] = 'yes';
    await prefs.setString(key, jsonEncode(json));
  }

  /// Capability aditiva, autenticada y ligada al diagnóstico reciente.
  /// Ausente, inválida, inferida, futura u obsoleta se interpreta siempre como
  /// protocolo heredado, sin probes ni requests extra.
  static Future<bool> isTurnIdempotencySupported(String connId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_capsKey(connId));
      if (raw == null) return false;
      final matrix = CapabilityMatrix.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (matrix.turnIdempotency != CapState.yes ||
          !matrix.isServerSourced('turnIdempotency')) {
        return false;
      }
      final checkedAtMs = matrix.checkedAtMs;
      if (checkedAtMs == null) return false;
      final ageMs = DateTime.now().millisecondsSinceEpoch - checkedAtMs;
      return ageMs >= 0 &&
          ageMs <= _turnIdempotencyCapabilityTtl.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  /// Read-only compatibility evidence for Room worker task creation.
  ///
  /// A direct, server-sourced declaration wins. Older Hermes versions did not
  /// publish that field, so the documented fallback accepts the two audited
  /// release lineages that contain both `idempotency_key` and the returned
  /// authoritative task: Agent >= 0.13.0 or calendar release >= v2026.5.7.
  /// Missing/malformed evidence and explicit server `false` fail closed.
  static Future<bool> isKanbanTrackedCreateSupported(String connId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_capsKey(connId));
      if (raw == null) return false;
      final matrix = CapabilityMatrix.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (matrix.isServerSourced('kanbanTrackedCreate')) {
        return matrix.kanbanTrackedCreate == CapState.yes;
      }
      return supportsKanbanTrackedCreateVersion(matrix.gatewayVersion);
    } catch (_) {
      return false;
    }
  }

  /// Borra todas las API keys y secretos de Dashboard del Keystore sin tocar
  /// los metadatos de conexión. Tras esto, cada instancia pedirá la clave de
  /// nuevo.
  Future<void> wipeAllApiKeys() async {
    await _secure.clearAllConnectionSecrets();
    _apiKeyCache.clear();
  }

  // Prefijos de claves de SharedPreferences ligadas a UNA conexión (id UUID).
  // Sirven para limpiar todo lo de una instancia al borrarla y para podar
  // huérfanas de borrados antiguos al arrancar (evita basura tras updates del
  // APK, que conservan los datos a propósito).
  static const List<String> _connScopedPrefixes = [
    'capabilities_',
    'active_profile_',
    'runs_',
    'approval_activity_',
    'approval_rules_',
    'archived_sessions_',
    'hidden_sessions_',
    'mission_control.organizations.v1.',
    'mission_control.rooms.v1.',
    'mission_control.bot_chat_pins.v1.',
  ];
  static const List<String> _connScopedDoubleColon = [
    'memory_draft_ts::',
    'memory_draft::',
  ];
  // Preferencias de mascota con scope `<connId>.<profileId>`: el connId (UUID,
  // sin puntos) es el segmento tras el prefijo y antes del primer punto.
  static const List<String> _connScopedDottedPrefixes = [
    'companion.selected_slug.',
    'companion.enabled.',
    'companion.scale.',
    'companion.size_multiplier.',
  ];

  /// Devuelve el id de conexión codificado en [key], o null si no es una clave
  /// con ámbito de conexión. Los ids son UUID (sin guiones bajos), así que la
  /// extracción es inequívoca.
  static String? _connIdOfKey(String key) {
    for (final p in _connScopedDoubleColon) {
      if (key.startsWith(p)) {
        final rest = key.substring(p.length);
        final i = rest.indexOf('::');
        return i >= 0 ? rest.substring(0, i) : rest;
      }
    }
    for (final p in _connScopedDottedPrefixes) {
      if (key.startsWith(p)) {
        final rest = key.substring(p.length);
        final i = rest.indexOf('.');
        return i >= 0 ? rest.substring(0, i) : rest;
      }
    }
    for (final p in _connScopedPrefixes) {
      if (key.startsWith(p)) return key.substring(p.length);
    }
    return null;
  }

  Future<void> _removeConnectionPrefs(String id) async {
    for (final k in prefs.getKeys().toList()) {
      if (_connIdOfKey(k) == id) await prefs.remove(k);
    }
  }

  /// Poda datos de SharedPreferences huérfanos: entradas con ámbito de conexión
  /// cuyo id ya no existe (instancias borradas en el pasado). Conserva intactas
  /// las conexiones vivas y todos los ajustes globales. Devuelve cuántas quitó.
  Future<int> pruneOrphanData() async {
    final valid = getConnections().map((c) => c.id).toSet();
    var removed = 0;
    for (final k in prefs.getKeys().toList()) {
      final id = _connIdOfKey(k);
      if (id != null && id.isNotEmpty && !valid.contains(id)) {
        await prefs.remove(k);
        removed++;
      }
    }
    return removed;
  }

  Future<void> deleteConnection(String id) async {
    // El resto de recovery local se mantiene best-effort por compatibilidad.
    try {
      await ChatDraftStore(prefs).deleteForConnection(id);
      await TurnOutboxStore().deleteForConnection(id);
      await MissionBotChatStore(prefs).deleteForConnection(id);
    } catch (error) {
      // Borrar la instancia no debe quedar bloqueado por un Keystore dañado.
      // No se registra contenido, ids ni detalles del plugin.
      debugPrint('[connection] recovery cleanup failed (${error.runtimeType})');
    }
    // Credenciales (Keystore).
    await _secure.deleteApiKey(id);
    await _secure.deleteDashboardSecrets(id);
    await _secure.deleteBridge(id);
    // Todos los datos con ámbito de esta conexión (caps, perfil activo, runs,
    // aprobaciones, sesiones archivadas/ocultas, borradores de memoria).
    await _removeConnectionPrefs(id);
    _apiKeyCache.remove(id);
    // Si era la predeterminada, deja de serlo (evita que [applyDefaultOnLaunch]
    // siembre un id muerto).
    if (prefs.getString(defaultConnKey) == id) {
      await prefs.remove(defaultConnKey);
    }
    final current = getConnections();
    current.removeWhere((c) => c.id == id);
    // A estas alturas ya no quedan credenciales capaces de hidratar la conexión.
    // Limpiar ahora evita retirar protección de un backend todavía utilizable.
    Object? cleanupError;
    try {
      await _clearCancelledTurns?.call(id);
    } catch (error) {
      cleanupError = error;
    }
    // La baja de la conexión se completa incluso si el cleanup quedó encolado.
    await _saveAll(current);
    if (cleanupError != null) {
      debugPrint(
        '[connection] cancelled-turn cleanup queued after delete: '
        '${cleanupError.runtimeType}',
      );
    }
  }

  Future<void> _saveAll(List<SavedConnection> list) => prefs.setStringList(
    _key,
    list.map((c) => jsonEncode(c.toMap())).toList(),
  );
}

/// HTTP client for the Hermes Gateway API Server (port 8642).
///
/// Uses Bearer token auth. Same pattern as hermes-desktop.
/// Página de mensajes de `/api/sessions/{id}/messages` con la metadata
/// `pagination` que añade Hermes Agent 0.20. `messages` llega en orden
/// cronológico (más antiguo primero) aunque el `offset` se mida hacia atrás
/// desde el mensaje más reciente.
class SessionMessagesPage {
  final List<Map<String, dynamic>> messages;

  /// `pagination.limit` de la respuesta; null cuando el gateway es antiguo y
  /// devolvió el transcript completo one-shot (sin metadata).
  final int? limit;

  /// `pagination.offset` de la respuesta (0 si no hay metadata).
  final int offset;

  SessionMessagesPage({required this.messages, required Object? pagination})
    : limit = _pageInt(pagination, 'limit'),
      offset = _pageInt(pagination, 'offset') ?? 0;

  bool get hasPagination => limit != null;

  static int? _pageInt(Object? pagination, String key) {
    if (pagination is! Map) return null;
    final value = pagination[key];
    if (value is! num || !value.isFinite || value < 0) return null;
    return value.toInt();
  }
}

class ApiClient {
  static const Duration _requestTimeout = Duration(seconds: 15);
  final http.Client _http;
  final String baseUrl;
  final String _apiKey;
  final String? _connectionId;

  // Keep the public parameter name `apiKey` while storing it privately.
  ApiClient({
    required String baseUrl,
    required String apiKey,
    String? connectionId,
    http.Client? httpClient,
  }) : _apiKey = apiKey,
       _connectionId = connectionId,
       baseUrl = TransportPrivacy.requireAllowed(
         baseUrl.endsWith('/')
             ? baseUrl.substring(0, baseUrl.length - 1)
             : baseUrl,
       ),
       _http = httpClient ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_apiKey',
    'Content-Type': 'application/json',
  };

  // ── Session listing ──────────────────────────────────────────────────

  /// Lista sesiones. Por defecto el servidor pliega las sesiones "hijas"
  /// (continuaciones/subagentes/ramas) dentro de su padre, así que muchas
  /// quedan ocultas y no se pueden borrar desde la app. [includeChildren] pide
  /// `?include_children=true` para ver TODAS (necesario para limpiar de verdad).
  /// `limit=200` evita el tope por defecto de 50 del servidor.
  Future<List<Session>> getSessions({bool includeChildren = false}) async {
    final res = await _http
        .get(
          Uri.parse(
            '$baseUrl/api/sessions?limit=200'
            '${includeChildren ? '&include_children=true' : ''}',
          ),
          headers: _headers,
        )
        .timeout(_requestTimeout);
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = data['data'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((s) => Session.fromJson(s))
        // Compatibilidad de limpieza: versiones experimentales antiguas crearon
        // sesiones internas con este prefijo. Nunca fueron chats del usuario.
        .where((s) => !s.id.startsWith('mob-aux-'))
        .toList();
  }

  // ── Messages ─────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getMessages(String sessionId) async {
    final res = await _http
        .get(
          Uri.parse('$baseUrl/api/sessions/$sessionId/messages'),
          headers: _headers,
        )
        .timeout(_requestTimeout);
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = data['data'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Una página del transcript con la semántica `order=latest` de Hermes
  /// Agent 0.20: [offset] se mide hacia atrás desde el mensaje MÁS reciente y
  /// la página llega en orden cronológico. Servidores antiguos ignoran los
  /// parámetros y devuelven el transcript entero sin metadata `pagination`;
  /// el llamador detecta ese caso con [SessionMessagesPage.hasPagination] y
  /// lo trata como historial completo.
  Future<SessionMessagesPage> getMessagesPage(
    String sessionId, {
    int limit = 120,
    int offset = 0,
  }) async {
    final res = await _http
        .get(
          Uri.parse(
            '$baseUrl/api/sessions/$sessionId/messages'
            '?limit=$limit&order=latest&offset=$offset',
          ),
          headers: _headers,
        )
        .timeout(_requestTimeout);
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = data['data'] as List? ?? [];
    return SessionMessagesPage(
      messages: list.whereType<Map<String, dynamic>>().toList(),
      pagination: data['pagination'],
    );
  }

  // ── Models ───────────────────────────────────────────────────────────

  /// Fetches available models from GET /v1/models (OpenAI-compatible).
  /// Returns a fallback list with 'hermes-agent' when the endpoint is
  /// unreachable or returns a non-200 status.
  Future<List<ModelInfo>> getModelInfoList() async {
    try {
      final res = await _http
          .get(Uri.parse('$baseUrl/v1/models'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        return [const ModelInfo(id: 'hermes-agent')];
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = data['data'] as List? ?? [];
      final models = list
          .whereType<Map<String, dynamic>>()
          .map(ModelInfo.fromJson)
          .toList();
      return models.isEmpty ? [const ModelInfo(id: 'hermes-agent')] : models;
    } catch (e) {
      debugPrint(
        '[connection] excepción silenciada (se continúa sin propagar): $e',
      );
      return [const ModelInfo(id: 'hermes-agent')];
    }
  }

  /// Convenience wrapper: returns just model IDs. Use [getModelInfoList] for
  /// richer metadata (created, owned_by).
  Future<List<String>> getModels() async {
    final models = await getModelInfoList();
    return models.map((m) => m.id).toList();
  }

  /// Sonda best-effort de los modelos del backend Ollama del MISMO host, vía
  /// `GET http://<host>:<port>/api/tags`. Hermes solo anuncia el alias
  /// `hermes-agent` en `/v1/models`, así que esto es lo que permite elegir el
  /// "cerebro" real (p.ej. `gemma4:e4b`) para el modo voz. Devuelve [] en
  /// silencio si no hay Ollama o no es alcanzable (usuarios sin Ollama no se
  /// ven afectados). El puerto por defecto es el estándar de Ollama (11434).
  Future<List<String>> getBackendModels({int port = 11434}) async {
    try {
      final base = Uri.parse(baseUrl);
      final uri = Uri(
        scheme: base.scheme.isEmpty ? 'http' : base.scheme,
        host: base.host,
        port: port,
        path: '/api/tags',
      );
      final res = await _http.get(uri).timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = data['models'] as List? ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map((m) => (m['name'] ?? '').toString())
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint(
        '[connection] excepción silenciada (se devuelve lista vacía): $e',
      );
      return const [];
    }
  }

  // ── Health check ─────────────────────────────────────────────────────

  Future<bool> healthCheck() async {
    try {
      final health = await _http
          .get(Uri.parse('$baseUrl/health'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (health.statusCode == 401 || health.statusCode == 403) return false;
      if (health.statusCode != 200) return false;

      // /health may be intentionally public on some deployments. Confirm that
      // the saved API key can also reach an authenticated endpoint before the
      // add/update connection dialogs accept it as valid.
      final sessions = await _http
          .get(Uri.parse('$baseUrl/api/sessions'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      return sessions.statusCode == 200;
    } catch (e) {
      debugPrint('[connection] excepción silenciada (se asume false): $e');
      return false;
    }
  }

  /// Calienta la conexión keep-alive al gateway (Fase 0 HCR). Un GET ligero a
  /// `/health` abre el socket TCP + handshake TLS y deja la conexión en el pool
  /// del `http.Client` compartido, para que el PRIMER turno de voz no arranque
  /// en frío (DNS/TLS) — que es justo cuando "se queda pensando" más. Es
  /// best-effort: traga cualquier error y no bloquea (fire-and-forget).
  Future<void> warmUp() async {
    try {
      await _http
          .get(Uri.parse('$baseUrl/health'), headers: _headers)
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // Calentamiento opcional: si falla, el turno real reportará el error.
    }
  }

  // ── Generic HTTP helpers (for Dashboard API compatibility) ────────────

  Future<Map<String, dynamic>> apiGet(String endpoint) async {
    final res = await _http
        .get(Uri.parse('$baseUrl/$endpoint'), headers: _headers)
        .timeout(_requestTimeout);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> apiGetList(String endpoint) async {
    final res = await _http
        .get(Uri.parse('$baseUrl/$endpoint'), headers: _headers)
        .timeout(_requestTimeout);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return jsonDecode(res.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/$endpoint'),
          headers: _headers,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(_requestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> apiDelete(String endpoint) async {
    final res = await _http
        .delete(Uri.parse('$baseUrl/$endpoint'), headers: _headers)
        .timeout(_requestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
  }

  // ── Session management ───────────────────────────────────────────────

  /// DELETE /api/sessions/{id}. Devuelve el campo `deleted` del servidor:
  /// true si realmente se borró, false si el backend respondió OK pero no la
  /// borró (p.ej. recreada por un canal activo). Un 404 es éxito idempotente:
  /// la sesión ya no existe y se puede retirar su recuperación local. Lanza en
  /// los demás errores HTTP.
  Future<bool> deleteSession(String sessionId) async {
    final res = await _http
        .delete(
          Uri.parse('$baseUrl/api/sessions/$sessionId'),
          headers: _headers,
        )
        .timeout(_requestTimeout);
    if (res.statusCode == 404) {
      await _clearSessionRecovery(sessionId);
      return true;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    bool deleted;
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      deleted = data['deleted'] != false; // ausente → asumir borrada
    } catch (e) {
      debugPrint('[connection] excepción silenciada (se asume true): $e');
      deleted = true;
    }
    if (deleted) await _clearSessionRecovery(sessionId);
    return deleted;
  }

  Future<void> _clearSessionRecovery(String sessionId) async {
    final connectionId = _connectionId;
    if (connectionId == null || connectionId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await ChatDraftStore(prefs).clearForSession(connectionId, sessionId);
      await TurnOutboxStore().deleteForChat(connectionId, sessionId);
    } catch (error) {
      // El servidor ya confirmó el borrado: un fallo local de Keystore no debe
      // convertir esa operación remota correcta en un falso error de UI.
      debugPrint(
        '[connection] session recovery cleanup failed (${error.runtimeType})',
      );
    }
  }

  /// GET /api/sessions/{id} — detalle con métricas (tokens, coste, lineage).
  Future<Session> getSession(String sessionId) async {
    final data = await apiGet('api/sessions/$sessionId');
    return Session.fromJson((data['session'] as Map<String, dynamic>?) ?? data);
  }

  /// POST /api/sessions/{id}/fork — ramifica una sesión (semántica /branch
  /// del CLI: la original queda end_reason="branched" y la hija hereda el
  /// transcript con parent_session_id). Verificado en vivo (api_server.py).
  Future<Session> forkSession(String sessionId, {String? title}) async {
    final data = await apiPost(
      'api/sessions/$sessionId/fork',
      body: {if (title != null && title.isNotEmpty) 'title': title},
    );
    return Session.fromJson((data['session'] as Map<String, dynamic>?) ?? data);
  }

  // ── Runs (/v1/runs — ejecuciones de agente con aprobaciones) ──────────
  //
  // Contrato verificado contra api_server.py del upstream y el servidor
  // vivo: el gateway NO expone listado de runs (GET /v1/runs → 405) y los
  // estados viven en memoria (tras completar/reiniciar → 404 run_not_found).

  /// POST /v1/runs — lanza una ejecución; devuelve el run_id (HTTP 202).
  ///
  /// [history] es la conversación previa (turnos anteriores) en formato
  /// OpenAI `[{role, content}]`, orden cronológico (más antiguo primero), SIN
  /// el turno actual (que va en [input]).
  ///
  /// IMPORTANTE (verificado en api_server.py del upstream): `/v1/runs` es
  /// STATELESS respecto a la conversación. El campo [sessionId] solo etiqueta el
  /// run (se usa como `task_id`/clave de aprobación), pero el gateway NO carga el
  /// transcript de la sesión ni reinyecta los turnos previos en el contexto del
  /// LLM. El ÚNICO modo de mantener el hilo es enviar [history] en el campo
  /// **`conversation_history`** (es lo que el handler pasa a
  /// `agent.run_conversation(conversation_history=...)`). Un campo `messages`
  /// NO se lee aquí (eso es del endpoint chat/completions): mandarlo como único
  /// contexto = el agente responde sin memoria del turno anterior ("no sé").
  /// Lo mandamos también como alias inofensivo por compatibilidad con gateways
  /// antiguos (los campos desconocidos se ignoran sin error). (El único contexto
  /// que sobrevive vía [sessionId] es lo que el agente haya guardado en su
  /// memoria de largo plazo con la tool de memoria — no es continuidad
  /// conversacional.)
  ///
  /// Alternativa nativa con contexto server-side automático: el endpoint
  /// `POST /api/sessions/{id}/chat[/stream]` carga el transcript de la sesión
  /// por sí mismo (sin reenviar `messages`), pero no expone el ciclo de run con
  /// `approval.request` del que depende la tarjeta de aprobación del chat.
  Future<String> startRun({
    required String input,
    String? sessionId,
    String? model,
    List<Map<String, dynamic>>? history,
    String? profile,
  }) async {
    Map<String, dynamic> buildBody({required bool withHistory}) => {
      'input': input,
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (model != null && model.isNotEmpty) 'model': model,
      // `profile` se incluye SOLO si el llamador lo pasa explícitamente. Hoy el
      // gateway HTTP no enruta por perfil (lo ignora), así que los caminos
      // remotos actuales NO lo envían; queda como contrato preparado para cuando
      // el upstream acepte perfil en /v1/runs (la app ya estaría lista).
      if (profile != null && profile.isNotEmpty) 'profile': profile,
      if (withHistory && history != null && history.isNotEmpty) ...{
        // `conversation_history` es el campo que el gateway lee de verdad para
        // reinyectar el hilo; `messages` se manda solo como alias compatible.
        'conversation_history': history,
        'messages': history,
      },
    };

    final hasHistory = history != null && history.isNotEmpty;
    Map<String, dynamic> data;
    // 30 s es suficiente para que el gateway procese el POST inicial. Sin este
    // timeout la petición puede colgar indefinidamente si el servidor está caído
    // o sobrecargado (el SSE subsiguiente no llega a iniciarse y la UI no avanza).
    const runStartTimeout = Duration(seconds: 30);
    try {
      data = await apiPost(
        'v1/runs',
        body: buildBody(withHistory: true),
      ).timeout(runStartTimeout);
    } catch (e) {
      // Si un gateway estricto/antiguo rechaza el cuerpo con historial
      // (400/422), NO reintentamos sin contexto (eso = el agente olvida el
      // turno previo y "se vuelve tonto"). En su lugar inyectamos el historial
      // como transcript dentro del propio `input`, que siempre se respeta —
      // mismo principio que el bridge local con `hermes -z`.
      final s = e.toString();
      if (hasHistory && (s.contains('400') || s.contains('422'))) {
        data = await apiPost(
          'v1/runs',
          body: _buildContextInjectedBody(input, history, sessionId, model),
        ).timeout(runStartTimeout);
      } else {
        rethrow;
      }
    }
    final runId = data['run_id'] as String?;
    if (runId == null || runId.isEmpty) {
      throw Exception('Gateway did not return run_id');
    }
    return runId;
  }

  /// Cuerpo de `/v1/runs` con el contexto inyectado dentro de `input` (fallback
  /// cuando el gateway rechaza los campos de historial). El transcript previo va
  /// envuelto para que el agente lo distinga del turno actual y responda solo al
  /// último mensaje, sin perder el hilo.
  static Map<String, dynamic> _buildContextInjectedBody(
    String input,
    List<Map<String, dynamic>> history,
    String? sessionId,
    String? model,
  ) {
    final transcript = history
        .map((m) {
          final who = (m['role'] == 'user') ? 'User' : 'Assistant';
          return '$who: ${(m['content'] ?? '').toString()}';
        })
        .join('\n');
    final contextualInput =
        'Continue this conversation maintaining context. Reply only to the '
        'LAST user message, without repeating the history.\n\n'
        '<previous_conversation>\n$transcript\n</previous_conversation>\n\n'
        'User: $input';
    return {
      'input': contextualInput,
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (model != null && model.isNotEmpty) 'model': model,
    };
  }

  /// GET /v1/runs/{id} — estado pollable. Lanza con el código HTTP en el
  /// mensaje (404 = el gateway ya no conserva esta ejecución).
  Future<Map<String, dynamic>> getRun(String runId) => apiGet('v1/runs/$runId');

  /// POST /v1/runs/{id}/approval — resuelve una aprobación pendiente.
  /// [choice]: once | session | always | deny.
  Future<Map<String, dynamic>> resolveRunApproval(
    String runId,
    String choice, {
    bool resolveAll = false,
  }) => apiPost(
    'v1/runs/$runId/approval',
    body: {'choice': choice, if (resolveAll) 'resolve_all': true},
  );

  /// POST /v1/runs/{id}/stop — interrumpe la ejecución.
  Future<Map<String, dynamic>> stopRun(String runId) =>
      apiPost('v1/runs/$runId/stop');

  /// GET /v1/runs/{id}/events — SSE de eventos estructurados del run
  /// (message.delta, tool.started/completed, approval.request,
  /// run.completed/failed/cancelled). Devuelve cuando el stream cierra.
  Future<void> streamRunEvents(
    String runId, {
    required void Function(Map<String, dynamic> event) onEvent,
    required void Function() onDone,
    required void Function(String error) onError,
    Duration idleTimeout = const Duration(seconds: 90),
  }) async {
    try {
      final request = http.Request(
        'GET',
        Uri.parse('$baseUrl/v1/runs/$runId/events'),
      );
      request.headers.addAll(_headers);
      final response = await _http.send(request).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        onError('HTTP ${response.statusCode}');
        return;
      }
      String buffer = '';
      // A-010 (spec 028): timeout de inactividad también a MITAD de stream,
      // igual que la ruta rápida. Si la conexión muere en silencio (cambio
      // wifi→datos, NAT/Tailscale) el turno no queda en "respondiendo…" para
      // siempre: el error cierra el run con la burbuja de reintento. Los
      // keepalives del gateway (frames no-JSON) también cuentan como actividad.
      await response.stream
          .transform(utf8.decoder)
          .timeout(
            idleTimeout,
            onTimeout: (sink) {
              sink.addError(
                TimeoutException(
                  'SSE run events idle timeout (${idleTimeout.inSeconds}s)',
                ),
              );
              sink.close();
            },
          )
          .forEach((chunk) {
            buffer += chunk;
            while (buffer.contains('\n\n')) {
              final end = buffer.indexOf('\n\n');
              final frame = buffer.substring(0, end);
              buffer = buffer.substring(end + 2);
              for (final line in frame.split('\n')) {
                if (!line.startsWith('data:')) continue;
                final data = line.substring(5).trim();
                if (data.isEmpty) continue;
                try {
                  final parsed = jsonDecode(data);
                  if (parsed is Map<String, dynamic>) onEvent(parsed);
                } catch (_) {
                  // Frame no-JSON (keepalive/comentario): ignorar.
                }
              }
            }
          });
      onDone();
    } catch (e) {
      onError(e.toString());
    }
  }

  /// GET /v1/skills — catálogo de skills vía Gateway (Bearer). Fallback
  /// cuando el Dashboard (9119) no está accesible; devuelve name,
  /// description y category.
  Future<List<Map<String, dynamic>>> getGatewaySkills() async {
    final data = await apiGet('v1/skills');
    final list = data['data'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  // ── Dashboard-compatible helpers (port 9119 endpoints, may not work on API server) ──

  Future<Map<String, dynamic>> getModelInfo() => apiGet('api/model/info');
  Future<Map<String, dynamic>> getModelOptions() => apiGet('api/model/options');
  Future<List<Map<String, dynamic>>> getSkills() async {
    final data = await apiGetList('api/skills');
    return data.whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>> setModel(
    String scope,
    String provider,
    String model,
  ) => apiPost(
    'api/model/set',
    body: {'scope': scope, 'provider': provider, 'model': model},
  );

  void close() => _http.close();
}

typedef ToolProgressCallback = void Function(Map<String, dynamic> progress);

/// SSE streaming chat client for the Gateway API Server.
class GatewayChatClient {
  final ApiClient _api;
  final String _baseUrl;

  GatewayChatClient(this._api) : _baseUrl = _api.baseUrl;

  /// Generate a client-side session ID: `mob-<timestamp>-<uuid>`.
  static String generateSessionId() {
    return 'mob-${DateTime.now().millisecondsSinceEpoch}-${const Uuid().v4()}';
  }

  /// Build OpenAI chat-completions messages, preserving prior history and
  /// ensuring the newly typed user message is present exactly once at the end.
  static List<Map<String, dynamic>> buildChatCompletionMessages({
    required String message,
    List<Map<String, dynamic>>? history,
  }) {
    final messages = <Map<String, dynamic>>[];
    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        final role = (msg['role'] == 'agent' || msg['role'] == 'assistant')
            ? 'assistant'
            : 'user';
        final content = msg['content']?.toString() ?? '';
        if (content.isEmpty) continue;
        messages.add({'role': role, 'content': content});
      }
    }

    final latest = message.trim();
    final alreadyLast =
        messages.isNotEmpty &&
        messages.last['role'] == 'user' &&
        messages.last['content'] == latest;
    if (latest.isNotEmpty && !alreadyLast) {
      messages.add({'role': 'user', 'content': latest});
    }
    return messages;
  }

  /// Parse one SSE frame. Returns streamed text token, or null for non-token
  /// frames. Hermes tool progress frames are delivered via [onToolProgress].
  static String? parseSseFrame(
    String frame, {
    ToolProgressCallback? onToolProgress,
  }) {
    String eventType = '';
    final dataLines = <String>[];

    for (final rawLine in frame.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty || line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }

    if (dataLines.isEmpty) return null;
    final data = dataLines.join('\n').trim();
    if (data.isEmpty || data == '[DONE]') return null;

    try {
      final parsed = jsonDecode(data);
      if (eventType == 'hermes.tool.progress') {
        if (parsed is Map<String, dynamic>) onToolProgress?.call(parsed);
        return null;
      }

      if (parsed is Map<String, dynamic>) {
        final choices = parsed['choices'] as List?;
        if (choices != null && choices.isNotEmpty && choices.first is Map) {
          final first = choices.first as Map;
          final delta = first['delta'];
          if (delta is Map) {
            final content = delta['content'];
            if (content != null && content.toString().isNotEmpty) {
              return content.toString();
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[connection] excepción silenciada (se devuelve null): $e');
      return null;
    }
    return null;
  }

  /// Send a message and stream the assistant response token-by-token.
  ///
  /// [onConnected] fires once when the server returns HTTP 200 and the SSE
  /// stream is open but no content has arrived yet (the "waiting" state).
  Future<void> sendMessageStreaming({
    required String message,
    required String sessionId,
    String? model,
    List<Map<String, dynamic>>? history,
    Map<String, String>? extraHeaders,
    int? maxTokens,
    required void Function(String token) onToken,
    ToolProgressCallback? onToolProgress,
    void Function()? onConnected,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    final messages = buildChatCompletionMessages(
      message: message,
      history: history,
    );

    final body = {
      'model': model ?? 'hermes-agent',
      'messages': messages,
      'stream': true,
      // Techo duro opcional de generación para consumidores del cliente HTTP.
      'max_tokens': ?maxTokens,
    };

    final headers = {
      ..._api._headers,
      'X-Hermes-Session-Id': sessionId,
      ...?extraHeaders,
    };

    try {
      final request = http.Request(
        'POST',
        Uri.parse('$_baseUrl/v1/chat/completions'),
      );
      request.headers.addAll(headers);
      request.body = jsonEncode(body);

      final response = await _api._http.send(request);

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        String errorMsg;
        try {
          final err = jsonDecode(errorBody);
          errorMsg =
              err['error']?['message'] ??
              err['message'] ??
              'HTTP ${response.statusCode}';
        } catch (e) {
          debugPrint(
            '[connection] no se pudo parsear el error del servidor, se usa el código HTTP: $e',
          );
          errorMsg = 'HTTP ${response.statusCode}';
        }
        onError(errorMsg);
        return;
      }

      // HTTP 200 — stream is open, server is processing (waiting state).
      onConnected?.call();

      String buffer = '';
      await response.stream
          .transform(utf8.decoder)
          .timeout(
            const Duration(seconds: 90),
            onTimeout: (sink) {
              sink.addError(TimeoutException('SSE stream idle timeout (90s)'));
              sink.close();
            },
          )
          .forEach((chunk) {
            buffer += chunk;
            while (buffer.contains('\n\n')) {
              final eventEnd = buffer.indexOf('\n\n');
              final frame = buffer.substring(0, eventEnd);
              buffer = buffer.substring(eventEnd + 2);

              final token = parseSseFrame(
                frame,
                onToolProgress: onToolProgress,
              );
              if (token != null && token.isNotEmpty) onToken(token);
            }
          });

      onDone();
    } catch (e) {
      onError(e.toString());
    }
  }

  void abort() {
    _api.close();
  }
}

/// Secretos de auth del Dashboard guardados en Keystore.
class DashboardSecrets {
  final String? sessionToken;
  final String? username;
  final String? password;

  const DashboardSecrets({this.sessionToken, this.username, this.password});

  bool get hasBasicAuth =>
      (username?.isNotEmpty ?? false) && (password?.isNotEmpty ?? false);
}

/// Credencial efímera para abrir el WebSocket JSON-RPC oficial del Dashboard.
///
/// Dashboards actuales usan un ticket de un solo uso; instalaciones antiguas
/// usan el token de sesión embebido en la página. [headers] solo contiene la
/// cabecera Basic cuando hay un reverse proxy heredado que la exige también en
/// el upgrade. Nunca se persiste ni se registra este objeto.
class DashboardWebSocketAuth {
  final String queryName;
  final String credential;
  final Map<String, dynamic> headers;

  const DashboardWebSocketAuth({
    required this.queryName,
    required this.credential,
    this.headers = const {},
  });
}

enum DashboardAuthFailureCode {
  loginRequired('dashboard_login_required'),
  invalidCredentials('dashboard_invalid_credentials'),
  rateLimited('dashboard_login_rate_limited'),
  loginFailed('dashboard_login_failed'),
  sessionCookieMissing('dashboard_session_cookie_missing');

  const DashboardAuthFailureCode(this.stableCode);

  final String stableCode;
}

/// Señal estable para decisiones de autenticación del Dashboard.
///
/// La lógica de reparación nunca debe depender del copy ni del idioma del
/// mensaje mostrado al usuario.
class DashboardAuthException implements Exception {
  final DashboardAuthFailureCode code;
  final int? statusCode;

  const DashboardAuthException(this.code, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? code.stableCode
      : '${code.stableCode} (HTTP $statusCode)';
}

/// Fallo HTTP estructural de una ruta autenticada del Dashboard.
///
/// Conserva el formato textual histórico para diagnóstico, pero permite que la
/// UI distinga 401/403/404 de una caída de red, un 500 o un JSON inválido sin
/// tomar decisiones mediante substrings.
class DashboardHttpException implements Exception {
  final int statusCode;
  final String body;

  const DashboardHttpException(this.statusCode, {this.body = ''});

  @override
  String toString() => 'HTTP $statusCode';
}

/// El servidor entendió el DELETE pero conservó deliberadamente el cron
/// (`200 {"deleted":false}`). Es un rechazo de negocio, no un fallo de red.
class CronDeleteRejectedException implements Exception {
  const CronDeleteRejectedException();

  @override
  String toString() => 'cron_delete_rejected';
}

/// Client for the Hermes Dashboard REST API (port 9119).
///
/// Modos de auth soportados:
///  - cookieSession (por defecto): scrapea `window.__HERMES_SESSION_TOKEN__`
///    del HTML de `/` y lo cachea en RAM.
///  - sessionToken: usa un token pegado manualmente por el usuario.
///  - basicAuth: añade `Authorization: Basic` al scrape y a cada llamada
///    (para Dashboards protegidos con HERMES_DASHBOARD_BASIC_AUTH_*).
class DashboardUpdateApplyResult {
  final bool responseConfirmed;

  const DashboardUpdateApplyResult.confirmed() : responseConfirmed = true;

  const DashboardUpdateApplyResult.transportUncertain()
    : responseConfirmed = false;
}

class DashboardBinaryResponse {
  final Uint8List bytes;
  final Map<String, String> headers;

  const DashboardBinaryResponse({required this.bytes, this.headers = const {}});

  String? get contentType => headers['content-type'];
}

class DashboardClient {
  /// Coordina únicamente logins simultáneos entre instancias de cliente. Cada
  /// pantalla conserva su propio `http.Client`, pero una ráfaga de aperturas no
  /// dispara varios POST con la misma contraseña ni activa el rate-limit.
  static final Map<(String, String, String), Future<Map<String, String>>>
  _sharedPasswordLoginFlights = {};

  final http.Client _http;
  final String _baseUrl;
  String? _manualToken;
  String? _basicUser;
  String? _basicPass;
  String? _token;

  /// Cookies de sesión de un Dashboard con login propio (`hermes_session_at`,
  /// `hermes_session_rt` y `hermes_session_provider`). Se establecen con un POST
  /// a `/auth/password-login`
  /// (usuario+contraseña) y el servidor las ROTA de forma transparente, así que
  /// re-leemos `Set-Cookie` en cada respuesta. Vacío = sesión sin establecer.
  final Map<String, String> _cookies = {};

  /// True cuando el Dashboard NO expone el login por contraseña (instalación
  /// abierta/antigua, o `/auth/password-login` da 404): caemos al camino
  /// heredado (scrape del token de página / cabecera Basic) sin reintentar.
  bool _passwordLoginUnsupported = false;

  /// Carga perezosa de secretos desde Keystore (modo sessionToken/basicAuth)
  /// para que las pantallas puedan construir el cliente de forma síncrona.
  Future<void> Function(DashboardClient self)? _secretsLoader;
  bool _secretsLoaded = false;
  Future<void>? _secretsFuture;
  Future<void>? _passwordLoginFuture;

  static const _kTimeout = Duration(seconds: 10);

  /// Los endpoints de audio son operaciones bloqueantes: esperan al proveedor,
  /// al manejo del fichero y a la codificación base64. Hermes Desktop les da
  /// un margen propio de 180–600 s sin alargar el timeout corto del resto del
  /// Dashboard. La síntesis escala por longitud del texto.
  @visibleForTesting
  static Duration audioSpeakRequestTimeout(String text) {
    final milliseconds = (text.length * 35).clamp(180000, 600000);
    return Duration(milliseconds: milliseconds);
  }

  /// El data URL base64 aproxima el tamaño y la duración del clip. Replica la
  /// política de Hermes Desktop: ~0,1 ms por carácter, con suelo de 180 s y
  /// techo de 600 s.
  @visibleForTesting
  static Duration audioTranscribeRequestTimeout(String dataUrl) {
    final milliseconds = ((dataUrl.length / 10).ceil()).clamp(180000, 600000);
    return Duration(milliseconds: milliseconds);
  }

  String get baseUrl => _baseUrl;

  DashboardClient({
    required String host,
    int port = 9119,
    bool useHttps = false,
    String? manualToken,
    String? basicUser,
    String? basicPass,
    http.Client? httpClientOverride,
  }) : _baseUrl = TransportPrivacy.requireAllowed(
         '${useHttps ? 'https' : 'http'}://$host:$port',
       ),
       _manualToken = manualToken,
       _basicUser = basicUser,
       _basicPass = basicPass,
       _http = httpClientOverride ?? http.Client();

  /// Cliente que respeta el modo de auth de la instancia, leyendo los
  /// secretos del Keystore en el primer uso. Para pantallas que solo tienen
  /// la [SavedConnection] (sin el manager).
  factory DashboardClient.lazy(
    SavedConnection conn, {
    http.Client? httpClientOverride,
  }) {
    final client = DashboardClient(
      host: conn.dashboardHost,
      port: conn.dashboardPort,
      useHttps: conn.dashboardUseHttps,
      httpClientOverride: httpClientOverride,
    );
    if (conn.dashboardAuthMode == AuthMode.sessionToken ||
        conn.dashboardAuthMode == AuthMode.basicAuth ||
        conn.dashboardAuthMode == AuthMode.cookieSession) {
      final secure = SecureStorage();
      client._secretsLoader = (self) async {
        if (conn.dashboardAuthMode == AuthMode.sessionToken) {
          self._manualToken = await secure.readDashboardSecret(
            conn.id,
            'token',
          );
        } else {
          // cookieSession es el modo de descubrimiento automático. Si una
          // migración reparó el Dashboard mediante el Bridge, reutiliza las
          // credenciales generadas y guardadas en Keystore sin exigir que el
          // usuario cambie manualmente el modo de la conexión.
          self._basicUser = await secure.readDashboardSecret(conn.id, 'user');
          self._basicPass = await secure.readDashboardSecret(conn.id, 'pass');
        }
      };
    }
    return client;
  }

  Future<void> _ensureSecrets() async {
    if (_secretsLoaded) return;
    final inFlight = _secretsFuture;
    if (inFlight != null) return inFlight;
    final future = _loadSecretsOnce();
    _secretsFuture = future;
    try {
      await future;
      _secretsLoaded = true;
    } finally {
      if (identical(_secretsFuture, future)) _secretsFuture = null;
    }
  }

  Future<void> _loadSecretsOnce() async {
    await _secretsLoader?.call(this);
  }

  /// Construye el cliente desde la configuración de la instancia,
  /// respetando dashboardUrl explícita y el modo de auth elegido.
  factory DashboardClient.forConnection(
    SavedConnection conn, {
    DashboardSecrets? secrets,
    http.Client? httpClientOverride,
  }) {
    return DashboardClient(
      host: conn.dashboardHost,
      port: conn.dashboardPort,
      useHttps: conn.dashboardUseHttps,
      manualToken: conn.dashboardAuthMode == AuthMode.sessionToken
          ? secrets?.sessionToken
          : null,
      basicUser: conn.dashboardAuthMode == AuthMode.basicAuth
          ? secrets?.username
          : null,
      basicPass: conn.dashboardAuthMode == AuthMode.basicAuth
          ? secrets?.password
          : null,
      httpClientOverride: httpClientOverride,
    );
  }

  String? get _basicAuthHeader {
    final u = _basicUser, p = _basicPass;
    if (u == null || u.isEmpty || p == null || p.isEmpty) return null;
    return 'Basic ${base64Encode(utf8.encode('$u:$p'))}';
  }

  /// Actualiza únicamente la sesión en memoria tras una reparación automática
  /// vía Mobile Bridge. Los secretos se persisten por separado en Keystore.
  void usePasswordCredentials(String username, String password) {
    _basicUser = username;
    _basicPass = password;
    _token = null;
    _cookies.clear();
    _secretsLoaded = true;
    _secretsFuture = null;
    _passwordLoginFuture = null;
  }

  Future<String> _getToken() async {
    await _ensureSecrets();
    final manual = _manualToken;
    if (manual != null && manual.isNotEmpty) return manual;
    if (_token != null) return _token!;
    final basic = _basicAuthHeader;
    final res = await _http
        .get(
          Uri.parse('$_baseUrl/'),
          headers: basic != null ? {'Authorization': basic} : null,
        )
        .timeout(
          _kTimeout,
          onTimeout: () {
            throw Exception(
              'Dashboard timeout — $_baseUrl is not responding. Check that the '
              'Dashboard/Admin URL points to port 9119.',
            );
          },
        );
    if (res.statusCode == 401 || res.statusCode == 403) {
      if (basic == null) {
        throw DashboardAuthException(
          DashboardAuthFailureCode.loginRequired,
          statusCode: res.statusCode,
        );
      }
      throw DashboardAuthException(
        DashboardAuthFailureCode.invalidCredentials,
        statusCode: res.statusCode,
      );
    }
    if (res.statusCode != 200) {
      throw Exception(
        'Dashboard not accessible at $_baseUrl (HTTP ${res.statusCode})',
      );
    }
    final match = RegExp(
      r'window\.__HERMES_SESSION_TOKEN__="([^"]+)";',
    ).firstMatch(res.body);
    if (match == null) {
      // Sin token en la página: o no es el Dashboard, o exige login propio y
      // sirve la página de login (sin el token embebido). Si fuese login, el
      // arreglo es configurar usuario+contraseña del Dashboard en la instancia.
      final looksLikeLogin =
          res.body.contains('provider-form') ||
          res.body.contains('/auth/password-login') ||
          res.body.contains('name="password"');
      if (looksLikeLogin) {
        throw const DashboardAuthException(
          DashboardAuthFailureCode.loginRequired,
        );
      }
      throw Exception(
        'Dashboard session token not found — is $_baseUrl the Hermes Dashboard?',
      );
    }
    _token = match.group(1)!;
    return _token!;
  }

  /// ¿Tenemos usuario+contraseña para el login por formulario del Dashboard?
  bool get _hasPasswordCreds =>
      (_basicUser?.isNotEmpty ?? false) && (_basicPass?.isNotEmpty ?? false);

  /// Lee las cookies de sesión de un `Set-Cookie` y las guarda. El paquete
  /// `http` une varias cabeceras Set-Cookie con coma, por eso extraemos por
  /// NOMBRE (los valores de token no llevan `;`, `,` ni espacios). Tolera el
  /// prefijo `__Host-`/`__Secure-` por si el Dashboard va por HTTPS, y respeta
  /// los borrados (`Max-Age=0` con valor vacío o `deleted`).
  void _ingestSetCookie(http.Response res) {
    final raw = res.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    final re = RegExp(
      r'((?:__Host-|__Secure-)?hermes_session_(?:at|rt|pkce|provider))=([^;,\s]*)',
    );
    for (final m in re.allMatches(raw)) {
      final name = m.group(1)!;
      final val = m.group(2)!;
      if (val.isEmpty || val == 'deleted') {
        _cookies.remove(name);
      } else {
        _cookies[name] = val;
      }
    }
  }

  String? get _cookieHeader => _cookies.isEmpty
      ? null
      : _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// Establece una sesión vía `POST /auth/password-login` (cuerpo JSON
  /// `{provider, username, password}`) y guarda las cookies devueltas. El
  /// Dashboard de Hermes con login propio valida la sesión por COOKIE en todas
  /// las rutas `/api/*` (no por cabecera), así que esto desbloquea modelos,
  /// skills, SOUL, cron y perfiles con el mismo usuario/contraseña que el
  /// navegador. Lanza con mensaje claro en credenciales inválidas (401) o
  /// rate-limit (429); marca el login como no soportado en 404 (Dashboard sin
  /// el endpoint) para que el llamante caiga al camino heredado.
  Future<void> _passwordLogin() async {
    final res = await _http
        .post(
          Uri.parse('$_baseUrl/auth/password-login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'provider': 'basic',
            'username': _basicUser,
            'password': _basicPass,
          }),
        )
        .timeout(_kTimeout);
    if (res.statusCode == 404) {
      _passwordLoginUnsupported = true;
      throw Exception('password-login unsupported');
    }
    if (res.statusCode == 429) {
      throw DashboardAuthException(
        DashboardAuthFailureCode.rateLimited,
        statusCode: res.statusCode,
      );
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw DashboardAuthException(
        DashboardAuthFailureCode.invalidCredentials,
        statusCode: res.statusCode,
      );
    }
    if (res.statusCode != 200) {
      throw DashboardAuthException(
        DashboardAuthFailureCode.loginFailed,
        statusCode: res.statusCode,
      );
    }
    _ingestSetCookie(res);
    if (!_cookies.keys.any((k) => k.endsWith('hermes_session_at'))) {
      throw DashboardAuthException(
        DashboardAuthFailureCode.sessionCookieMissing,
        statusCode: res.statusCode,
      );
    }
  }

  /// Comparte un solo login entre todas las pantallas que arrancan a la vez.
  /// El Future se elimina al terminar para permitir un nuevo intento tras un
  /// 401 o un fallo de red, pero mientras está activo ningún consumidor puede
  /// pisar las cookies emitidas para otro.
  Future<void> _ensurePasswordLogin() async {
    if (_cookies.isNotEmpty) return;
    final inFlight = _passwordLoginFuture;
    if (inFlight != null) return inFlight;
    // Incluye la credencial exacta: dos perfiles contra la misma URL/usuario
    // no deben prestarse una sesión si uno conserva una contraseña antigua.
    // La clave solo vive durante el POST y se elimina en el `finally` inferior.
    final sharedKey = (_baseUrl, _basicUser ?? '', _basicPass ?? '');
    final shared = _sharedPasswordLoginFlights[sharedKey];
    if (shared != null) {
      final future = shared.then((cookies) {
        _cookies
          ..clear()
          ..addAll(cookies);
      });
      _passwordLoginFuture = future;
      try {
        await future;
      } finally {
        if (identical(_passwordLoginFuture, future)) {
          _passwordLoginFuture = null;
        }
      }
      return;
    }
    final loginFuture = () async {
      await _passwordLogin();
      return Map<String, String>.from(_cookies);
    }();
    _sharedPasswordLoginFlights[sharedKey] = loginFuture;
    final future = loginFuture.then<void>((_) {});
    _passwordLoginFuture = future;
    try {
      await future;
    } finally {
      if (identical(_sharedPasswordLoginFlights[sharedKey], loginFuture)) {
        _sharedPasswordLoginFlights.remove(sharedKey);
      }
      if (identical(_passwordLoginFuture, future)) {
        _passwordLoginFuture = null;
      }
    }
  }

  Future<Map<String, String>> _authHeaders() async {
    await _ensureSecrets();
    // Dashboard con login propio: autenticamos por COOKIE de sesión (POST
    // /auth/password-login con usuario+contraseña). Es lo que desbloquea la
    // lista completa de modelos/proveedores y el resto de la API nativa.
    if (_hasPasswordCreds && !_passwordLoginUnsupported) {
      try {
        await _ensurePasswordLogin();
        return <String, String>{
          'Cookie': ?_cookieHeader,
          'Content-Type': 'application/json',
        };
      } on Exception {
        // 404 → endpoint ausente: caemos al camino heredado abajo. Otros
        // errores (401/429/red) se propagan al reintentar la petición.
        if (!_passwordLoginUnsupported) rethrow;
      }
    }
    final headers = <String, String>{
      'X-Hermes-Session-Token': await _getToken(),
      'Content-Type': 'application/json',
    };
    final basic = _basicAuthHeader;
    if (basic != null) headers['Authorization'] = basic;
    return headers;
  }

  /// Olvida la sesión por cookie para forzar un nuevo login en la próxima
  /// petición (tras un 401: el `at` caducó y el `rt` no pudo rotarlo).
  void _resetSession() {
    _token = null;
    _cookies.clear();
    _passwordLoginFuture = null;
  }

  /// Resuelve los headers de auth sin hacer ninguna llamada de datos.
  /// Usado por ConnectionDiagnostics para clasificar fallos de auth.
  Future<Map<String, String>> authHeadersForDiagnostics() => _authHeaders();

  /// Mintea un ticket de un solo uso (30s) para autenticar un WebSocket.
  /// Los sockets no pueden mandar la cookie/Authorization en el upgrade, así
  /// que en dashboards con login por cookie hay que pasar `?ticket=`. Devuelve
  /// null si el endpoint no existe (modo token/loopback → se usa `?token=`).
  Future<String?> mintWsTicket() async {
    try {
      final res = await apiPost('auth/ws-ticket');
      final t = res['ticket'];
      return (t is String && t.isNotEmpty) ? t : null;
    } catch (e) {
      debugPrint('[connection] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }

  /// Resuelve la autenticación que espera `/api/ws`, el mismo endpoint usado
  /// por Hermes Desktop. Prefiere tickets de 30 s en Dashboards con login y
  /// degrada al token de sesión únicamente para instalaciones heredadas.
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    final ticket = await mintWsTicket();
    final basic = _basicAuthHeader;
    final headers = <String, dynamic>{};
    if (basic != null) headers['Authorization'] = basic;
    if (ticket != null && ticket.isNotEmpty) {
      return DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: ticket,
        headers: headers,
      );
    }
    return DashboardWebSocketAuth(
      queryName: 'token',
      credential: await _getToken(),
      headers: headers,
    );
  }

  Map<String, dynamic> _decodeMapResponse(http.Response res) {
    final trimmed = res.body.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }

  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .get(Uri.parse('$_baseUrl/api/$endpoint'), headers: headers)
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return apiGet(endpoint, retried: true);
    }
    if (res.statusCode != 200) {
      throw DashboardHttpException(res.statusCode, body: res.body);
    }
    return _decodeMapResponse(res);
  }

  Future<List<dynamic>> apiGetList(
    String endpoint, {
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .get(Uri.parse('$_baseUrl/api/$endpoint'), headers: headers)
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return apiGetList(endpoint, retried: true);
    }
    if (res.statusCode != 200) {
      throw DashboardHttpException(res.statusCode, body: res.body);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is List<dynamic>) return decoded;
    if (decoded is Map<String, dynamic> && decoded['data'] is List<dynamic>) {
      return decoded['data'] as List<dynamic>;
    }
    throw Exception('Expected list response');
  }

  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
    Duration timeout = _kTimeout,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .post(
          Uri.parse('$_baseUrl/api/$endpoint'),
          headers: headers,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(timeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return apiPost(endpoint, body: body, retried: true, timeout: timeout);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardHttpException(res.statusCode, body: res.body);
    }
    return _decodeMapResponse(res);
  }

  /// Envía un único fichero mediante multipart conservando exactamente la
  /// misma autenticación, cookies rotatorias y reintento 401 que el resto del
  /// Dashboard. El caller decide y valida el límite de dominio antes de red.
  Future<Map<String, dynamic>> apiPostMultipartFile(
    String endpoint, {
    required String fieldName,
    required String filePath,
    required String filename,
    Map<String, String> fields = const {},
    bool retried = false,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final authHeaders = await _authHeaders();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/api/$endpoint'),
    );
    request.headers.addAll({
      for (final entry in authHeaders.entries)
        if (entry.key.toLowerCase() != 'content-type') entry.key: entry.value,
    });
    request.fields.addAll(fields);
    request.files.add(
      await http.MultipartFile.fromPath(
        fieldName,
        filePath,
        filename: filename,
      ),
    );
    final streamed = await _http.send(request).timeout(timeout);
    final responseMetadata = http.Response(
      '',
      streamed.statusCode,
      headers: streamed.headers,
    );
    _ingestSetCookie(responseMetadata);
    if (streamed.statusCode == 401 && !retried) {
      await _cancelResponseStream(streamed.stream);
      _resetSession();
      return apiPostMultipartFile(
        endpoint,
        fieldName: fieldName,
        filePath: filePath,
        filename: filename,
        fields: fields,
        retried: true,
        timeout: timeout,
      );
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final errorBytes = await _readResponseStream(
        streamed.stream,
        maxBytes: 2048,
        truncate: true,
      );
      throw DashboardHttpException(
        streamed.statusCode,
        body: utf8.decode(errorBytes, allowMalformed: true),
      );
    }
    // La respuesta oficial es un JSON diminuto con metadata. Un Dashboard
    // manipulado no debe poder anular el límite del adjunto devolviendo un body
    // ilimitado después de aceptar el upload.
    final responseBytes = await _readResponseStream(
      streamed.stream,
      maxBytes: 256 * 1024,
    );
    final res = http.Response.bytes(
      responseBytes,
      streamed.statusCode,
      headers: streamed.headers,
    );
    return _decodeMapResponse(res);
  }

  /// Descarga autenticada y acotada. Se valida Content-Length cuando existe y
  /// también cada chunk, por lo que una respuesta maliciosa no puede forzar a
  /// Android a reservar memoria ilimitada.
  Future<DashboardBinaryResponse> apiDownload(
    String endpoint, {
    required int maxBytes,
    bool retried = false,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (maxBytes < 1) {
      throw RangeError.range(maxBytes, 1, null, 'maxBytes');
    }
    final request = http.Request('GET', Uri.parse('$_baseUrl/api/$endpoint'));
    request.headers.addAll(await _authHeaders());
    final streamed = await _http.send(request).timeout(timeout);
    final responseMetadata = http.Response(
      '',
      streamed.statusCode,
      headers: streamed.headers,
    );
    _ingestSetCookie(responseMetadata);
    if (streamed.statusCode == 401 && !retried) {
      await _cancelResponseStream(streamed.stream);
      _resetSession();
      return apiDownload(
        endpoint,
        maxBytes: maxBytes,
        retried: true,
        timeout: timeout,
      );
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final errorBytes = await _readResponseStream(
        streamed.stream,
        maxBytes: 2048,
        truncate: true,
      );
      throw DashboardHttpException(
        streamed.statusCode,
        body: utf8.decode(errorBytes, allowMalformed: true),
      );
    }
    final declaredLength = streamed.contentLength;
    if (declaredLength != null && declaredLength > maxBytes) {
      await _cancelResponseStream(streamed.stream);
      throw StateError('Dashboard download exceeds $maxBytes bytes');
    }
    final bytes = await _readResponseStream(
      streamed.stream,
      maxBytes: maxBytes,
    );
    return DashboardBinaryResponse(
      bytes: bytes,
      headers: Map<String, String>.unmodifiable(streamed.headers),
    );
  }

  Future<void> _cancelResponseStream(Stream<List<int>> stream) async {
    final subscription = stream.listen((_) {});
    await subscription.cancel();
  }

  Future<Uint8List> _readResponseStream(
    Stream<List<int>> stream, {
    required int maxBytes,
    bool truncate = false,
  }) async {
    final iterator = StreamIterator<List<int>>(stream);
    final builder = BytesBuilder(copy: false);
    var received = 0;
    try {
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        final remaining = maxBytes - received;
        if (chunk.length > remaining) {
          if (!truncate) {
            throw StateError('Dashboard download exceeds $maxBytes bytes');
          }
          if (remaining > 0) builder.add(chunk.sublist(0, remaining));
          break;
        }
        builder.add(chunk);
        received += chunk.length;
      }
      return builder.takeBytes();
    } finally {
      await iterator.cancel();
    }
  }

  Future<void> apiDelete(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .delete(
          Uri.parse('$_baseUrl/api/$endpoint'),
          headers: body != null
              ? {...headers, 'Content-Type': 'application/json'}
              : headers,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return apiDelete(endpoint, body: body, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardHttpException(res.statusCode, body: res.body);
    }
  }

  Future<Map<String, dynamic>> apiPut(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .put(
          Uri.parse('$_baseUrl/api/$endpoint'),
          headers: headers,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return apiPut(endpoint, body: body, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardHttpException(res.statusCode, body: res.body);
    }
    return _decodeMapResponse(res);
  }

  Future<Map<String, dynamic>> apiPatch(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .patch(
          Uri.parse('$_baseUrl/api/$endpoint'),
          headers: headers,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return apiPatch(endpoint, body: body, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardHttpException(res.statusCode, body: res.body);
    }
    return _decodeMapResponse(res);
  }

  Future<MemoryInfo> getMemoryInfo({
    String? profile,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .get(
          Uri.parse('$_baseUrl/api/memory${_profileQuery(profile)}'),
          headers: headers,
        )
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return getMemoryInfo(profile: profile, retried: true);
    }
    if (res.statusCode != 200) {
      throw DashboardHttpException(res.statusCode, body: res.body);
    }
    return MemoryInfo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Sufijo `?profile=<name>` para escalar una llamada a un perfil concreto.
  /// Vacío para el perfil por defecto (sin scoping). El servidor admite este
  /// parámetro en model/*, skills, config y env.
  static String _profileQuery(String? profile, {String sep = '?'}) {
    if (profile == null || profile.isEmpty || profile == 'default') return '';
    return '${sep}profile=${Uri.encodeQueryComponent(profile)}';
  }

  /// GET /api/model/info — con auth (cookie de sesión o token). Escalable por
  /// perfil. Antes iba sin cabeceras y fallaba con 401 en Dashboards con login.
  Future<ModelActiveInfo> getModelInfo({
    String? profile,
    bool retried = false,
  }) async {
    final res = await _http
        .get(
          Uri.parse('$_baseUrl/api/model/info${_profileQuery(profile)}'),
          headers: await _authHeaders(),
        )
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return getModelInfo(profile: profile, retried: true);
    }
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return ModelActiveInfo.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  /// GET /api/model/options — requiere auth Dashboard.
  Future<List<ModelProvider>> getModelOptions({
    String? profile,
    bool explicitOnly = false,
  }) async {
    final params = <String>[
      if (explicitOnly) 'explicit_only=1',
      if (profile != null && profile.isNotEmpty && profile != 'default')
        'profile=${Uri.encodeQueryComponent(profile)}',
    ];
    final suffix = params.isEmpty ? '' : '?${params.join('&')}';
    final data = await apiGet('model/options$suffix');
    final rawProviders = data['providers'];
    final providers = rawProviders is Map
        ? rawProviders.entries.map((entry) {
            final provider = entry.value;
            if (provider is Map) {
              return {
                'slug': entry.key.toString(),
                ...provider.cast<String, dynamic>(),
              };
            }
            return {'slug': entry.key.toString(), 'name': provider.toString()};
          })
        : (rawProviders as List? ?? const []).whereType<Map>().map(
            (provider) => provider.cast<String, dynamic>(),
          );
    return providers.map(ModelProvider.fromJson).toList();
  }

  /// GET /api/model/auxiliary — asignaciones por función + principal.
  Future<Map<String, dynamic>> getAuxiliaryModels({String? profile}) =>
      apiGet('model/auxiliary${_profileQuery(profile)}');

  /// POST /api/model/set — requiere auth Dashboard. Escalable por perfil.
  Future<bool> setActiveModel({
    required String providerSlug,
    required String modelId,
    String scope = 'main',
    String task = '',
    String baseUrl = '',
    String apiKey = '',
    String? profile,
  }) async {
    final res = await apiPost(
      'model/set${_profileQuery(profile)}',
      body: {
        'provider': providerSlug,
        'model': modelId,
        'scope': scope,
        if (task.isNotEmpty) 'task': task,
        if (baseUrl.isNotEmpty) 'base_url': baseUrl,
        if (apiKey.isNotEmpty) 'api_key': apiKey,
      },
    );
    return (res['ok'] as bool?) ?? false;
  }

  /// Prueba un endpoint OpenAI-compatible desde el servidor Hermes.
  ///
  /// Hacer esta sonda en el Dashboard, como Hermes Desktop, es importante:
  /// el endpoint puede estar ligado a loopback o a una red accesible desde el
  /// servidor pero no directamente desde el teléfono.
  Future<Map<String, dynamic>> validateExternalProvider({
    required String baseUrl,
    String apiKey = '',
  }) => apiPost(
    'providers/validate',
    body: {'key': 'OPENAI_BASE_URL', 'value': baseUrl, 'api_key': apiKey},
  );

  /// Intenta eliminar un custom_provider del servidor vía DELETE /api/model/provider.
  /// Lanza Exception si la API no lo soporta (404/405) para que el llamante
  /// pueda mostrar un mensaje apropiado al usuario.
  Future<void> deleteCustomProvider(String name) =>
      apiDelete('model/provider', body: {'name': name});

  /// GET /api/model/moa → receta del Mixture of Agents (spec 029). Lanza si el
  /// Dashboard no está accesible/autenticado → la pantalla degrada a solo-lectura.
  Future<MoaConfig> getMoa({String? profile}) async {
    final data = await apiGet('model/moa${_profileQuery(profile)}');
    return MoaConfig.fromJson(data);
  }

  /// PUT /api/model/moa → persiste la receta (forma con presets: reenvía todos
  /// para no perder los ajenos). Devuelve true si el servidor confirmó.
  Future<bool> setMoa(MoaConfig config, {String? profile}) async {
    final res = await apiPut(
      'model/moa${_profileQuery(profile)}',
      body: config.toJson(),
    );
    return (res['ok'] as bool?) ?? true;
  }

  // ── OAuth nativo del dashboard (device_code) ─────────────────────────────
  // Más limpio que `hermes auth add` por Termux: JSON directo con url+código.
  // `provider` debe ser el id del CLI (p.ej. nous, openai-codex, xai-oauth).

  /// `GET /api/providers/oauth` → lista de providers OAuth con su `flow`
  /// (device_code/loopback/external/…). Devuelve {slug: flow}. El `flow` decide
  /// si el login es viable in-app (device_code/loopback/minimax) o requiere un
  /// CLI externo (external).
  Future<Map<String, String>> getOAuthFlows() async {
    final res = await apiGet('providers/oauth');
    final list = (res['providers'] as List?) ?? const [];
    final out = <String, String>{};
    for (final p in list) {
      if (p is Map) {
        final id = (p['id'] ?? '').toString();
        final flow = (p['flow'] ?? '').toString();
        if (id.isNotEmpty) out[id] = flow;
      }
    }
    return out;
  }

  /// `POST /api/providers/oauth/{provider}/start` → inicia el flujo y devuelve
  /// {session_id, flow, user_code, verification_url, poll_interval, expires_in}.
  Future<Map<String, dynamic>> startProviderOAuth(String provider) =>
      apiPost('providers/oauth/$provider/start', body: const {});

  /// `GET /api/providers/oauth/{provider}/poll/{session_id}` → {status,
  /// error_message}. status "pending" mientras se espera; terminal al completar.
  Future<Map<String, dynamic>> pollProviderOAuth(
    String provider,
    String sessionId,
  ) => apiGet('providers/oauth/$provider/poll/$sessionId');

  /// Resetea todos los slots auxiliares a automático (scope=auxiliary,
  /// task=__reset__).
  Future<bool> resetAuxiliaryModels({String? profile}) => setActiveModel(
    providerSlug: 'auto',
    modelId: '',
    scope: 'auxiliary',
    task: '__reset__',
    profile: profile,
  );

  // ── Perfiles de agente (NOUS Profile Builder) ────────────────────────
  // Cada perfil es un home aislado (~/.hermes/profiles/<name>/). Todo vía la
  // Dashboard API existente: cero cambios en el servidor o en el bridge.

  /// GET /api/profiles — lista de perfiles con su configuración resumida.
  Future<List<AgentProfile>> getProfiles() async {
    final data = await apiGet('profiles');
    final list = (data['profiles'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AgentProfile.fromJson)
        .toList();
  }

  /// POST /api/profiles — crea un perfil. `name` es el único requerido
  /// (regex `[a-z0-9][a-z0-9_-]{0,63}`). [cloneFrom] hereda config/skills/env
  /// de un perfil existente.
  Future<Map<String, dynamic>> createProfile({
    required String name,
    String? cloneFrom,
    String? description,
  }) => apiPost(
    'profiles',
    body: {
      'name': name,
      if (cloneFrom != null && cloneFrom.isNotEmpty) 'clone_from': cloneFrom,
      if (description != null && description.isNotEmpty)
        'description': description,
    },
  );

  /// PATCH /api/profiles/{name} — renombra el perfil (`new_name` requerido).
  Future<Map<String, dynamic>> renameProfile(String name, String newName) =>
      apiPatch('profiles/$name', body: {'new_name': newName});

  /// DELETE /api/profiles/{name} — elimina el perfil.
  Future<void> deleteProfile(String name) => apiDelete('profiles/$name');

  /// GET /api/profiles/{name}/soul → {content, exists}.
  Future<Map<String, dynamic>> getProfileSoul(String name) =>
      apiGet('profiles/$name/soul');

  /// PUT /api/profiles/{name}/soul {content} — escribe el SOUL del perfil.
  Future<Map<String, dynamic>> setProfileSoul(String name, String content) =>
      apiPut('profiles/$name/soul', body: {'content': content});

  // ── Actualización de Hermes (hermes update) ──────────────────────────

  /// GET /api/hermes/update/check → {install_method, current_version, behind,
  /// update_available, can_apply, update_command}.
  Future<Map<String, dynamic>> checkUpdate({bool force = false}) =>
      apiGet(force ? 'hermes/update/check?force=true' : 'hermes/update/check');

  /// POST /api/hermes/update — aplica la actualización (reinicia Dashboard y
  /// Gateway). El comando es síncrono y puede tardar bastante más que el timeout
  /// HTTP; además, el propio reinicio puede cerrar el socket antes de responder.
  /// En ambos casos el POST ya pudo quedar aceptado y el llamador debe confirmar
  /// el resultado sondeando `/api/status`, no anunciar un fallo inmediato.
  Future<DashboardUpdateApplyResult> applyUpdate({
    Duration timeout = _kTimeout,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    late final http.Response res;
    try {
      res = await _http
          .post(Uri.parse('$_baseUrl/api/hermes/update'), headers: headers)
          .timeout(timeout);
    } on TimeoutException {
      return const DashboardUpdateApplyResult.transportUncertain();
    } on SocketException {
      return const DashboardUpdateApplyResult.transportUncertain();
    } on http.ClientException {
      return const DashboardUpdateApplyResult.transportUncertain();
    }
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return applyUpdate(timeout: timeout, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    return const DashboardUpdateApplyResult.confirmed();
  }

  /// POST /api/ops/config-migrate — migra el esquema de config.yaml al último
  /// (lanza `hermes config migrate` en segundo plano). Migración ADITIVA: añade
  /// claves nuevas con su default y sube `_config_version`; no borra ni cambia
  /// valores existentes. Devuelve {ok, pid, name} de inmediato (es detached).
  Future<Map<String, dynamic>> migrateConfig() => apiPost('ops/config-migrate');

  // ── Estado del servidor / diagnóstico ────────────────────────────────

  /// GET /api/status → {version, release_date, gateway_running, gateway_state,
  /// gateway_pid, gateway_platforms (plat -> {state,error}), active_sessions,
  /// config_version, latest_config_version, auth_required, ...}. Solo lectura.
  Future<Map<String, dynamic>> getServerStatus() => apiGet('status');

  /// Transcript almacenado por el Dashboard, con aislamiento por perfil.
  /// El API gateway de :8642 no acepta `profile`; las sesiones de perfiles
  /// secundarios deben leerse por este endpoint igual que Hermes Desktop.
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String sessionId, {
    String profile = '',
  }) async {
    final normalizedProfile = profile.trim();
    final query = normalizedProfile.isEmpty
        ? ''
        : '?${Uri(queryParameters: {'profile': normalizedProfile}).query}';
    final data = await apiGet(
      'sessions/${Uri.encodeComponent(sessionId)}/messages$query',
    );
    final raw = data['messages'] ?? data['data'];
    if (raw is! List) {
      throw const FormatException('Invalid Dashboard session transcript');
    }
    return raw
        .whereType<Map>()
        .map((message) => Map<String, dynamic>.from(message))
        .toList(growable: false);
  }

  /// Variante paginada (`order=latest`, offset hacia atrás desde el mensaje
  /// más reciente) del transcript Dashboard, igual que
  /// [ApiClient.getMessagesPage]. Dashboards antiguos responden sin metadata
  /// `pagination`: el llamador lo trata como transcript completo.
  Future<SessionMessagesPage> getSessionMessagesPage(
    String sessionId, {
    String profile = '',
    int limit = 120,
    int offset = 0,
  }) async {
    final normalizedProfile = profile.trim();
    final query = Uri(
      queryParameters: {
        'limit': '$limit',
        'order': 'latest',
        'offset': '$offset',
        if (normalizedProfile.isNotEmpty) 'profile': normalizedProfile,
      },
    ).query;
    final data = await apiGet(
      'sessions/${Uri.encodeComponent(sessionId)}/messages?$query',
    );
    final raw = data['messages'] ?? data['data'];
    if (raw is! List) {
      throw const FormatException('Invalid Dashboard session transcript');
    }
    return SessionMessagesPage(
      messages: raw
          .whereType<Map>()
          .map((message) => Map<String, dynamic>.from(message))
          .toList(growable: false),
      pagination: data['pagination'],
    );
  }

  /// POST /api/gateway/restart — reinicia el gateway (acción de mantenimiento
  /// independiente de la actualización; útil para reconectar plataformas).
  Future<Map<String, dynamic>> restartGateway() => apiPost('gateway/restart');

  /// GET /api/config — configuración efectiva del servidor. No se presupone
  /// que todos los plugins redacten sus campos: cada consumidor debe extraer
  /// únicamente las rutas que necesita y descartar el resto. [profile]
  /// mantiene el mismo aislamiento que Hermes Desktop.
  Future<Map<String, dynamic>> getServerConfig({String? profile}) =>
      apiGet('config${_profileQuery(profile)}');

  /// GET /api/config/schema. Aunque el schema actual es global, conservar el
  /// scope en la petición evita mezclar una lectura con otro perfil si el
  /// Dashboard lo hace profile-aware en una versión posterior.
  Future<Map<String, dynamic>> getServerConfigSchema({String? profile}) =>
      apiGet('config/schema${_profileQuery(profile)}');

  /// PUT /api/config con el registro completo leído y editado en memoria.
  ///
  /// Compatibilidad para editores completos. Las superficies acotadas deben
  /// preferir [putServerConfigPatch] para no reenviar configuración ajena.
  Future<Map<String, dynamic>> putServerConfigRecord(
    Map<String, dynamic> config, {
    String? profile,
    bool retried = false,
  }) => _putServerConfig(config, profile: profile, retried: retried);

  /// Aplica un fragmento de configuración mediante el deep-merge oficial del
  /// Dashboard. Es la ruta preferida para superficies acotadas: evita reenviar
  /// al móvil o de vuelta al servidor campos ajenos al ajuste que se edita.
  Future<Map<String, dynamic>> putServerConfigPatch(
    Map<String, dynamic> patch, {
    String? profile,
    bool retried = false,
  }) => _putServerConfig(patch, profile: profile, retried: retried);

  Future<Map<String, dynamic>> _putServerConfig(
    Map<String, dynamic> config, {
    String? profile,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .put(
          Uri.parse('$_baseUrl/api/config${_profileQuery(profile)}'),
          headers: headers,
          body: jsonEncode({'config': config}),
        )
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return _putServerConfig(config, profile: profile, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardHttpException(res.statusCode);
    }
    return _decodeMapResponse(res);
  }

  /// POST /api/audio/speak — sintetiza mediante el proveedor TTS ya configurado
  /// en Hermes (Edge, MiniMax, etc.) y devuelve un data URL de audio.
  /// Ninguna clave de proveedor sale del servidor.
  Future<Map<String, dynamic>> synthesizeSpeech(
    String text, {
    String? profile,
    Duration? timeout,
  }) => apiPost(
    'audio/speak${_profileQuery(profile)}',
    body: {'text': text},
    timeout: timeout ?? audioSpeakRequestTimeout(text),
  );

  /// POST /api/audio/transcribe — transcribe un clip de voz con el proveedor
  /// STT ya configurado en Hermes (el mismo que usa Desktop). El clip viaja
  /// como data URL base64; ninguna clave de proveedor sale del servidor.
  Future<Map<String, dynamic>> transcribeAudio(
    String dataUrl, {
    String mimeType = 'audio/wav',
    String? profile,
    Duration? timeout,
  }) => apiPost(
    'audio/transcribe${_profileQuery(profile)}',
    body: {'data_url': dataUrl, 'mime_type': mimeType},
    timeout: timeout ?? audioTranscribeRequestTimeout(dataUrl),
  );

  /// Sonda sin efectos de una ruta de audio (spec 048/US5), por el MISMO
  /// camino autenticado que el resto del Dashboard. Es un `POST` con cuerpo
  /// vacío a propósito: el web server tiene un catch-all `GET /{path}` para
  /// servir el frontend, así que un GET autenticado devuelve 404 aunque la
  /// ruta POST exista (verificado contra Hermes Agent). Con POST vacío:
  /// 422/400 = la
  /// ruta existe y validó el cuerpo; 405 = solo el catch-all GET conoce esa
  /// ruta (no existe); 404 = no existe. Sin efectos: la validación corta
  /// antes de tocar STT/TTS.
  Future<int> probeAudioEndpoint(String name, {String? profile}) async {
    try {
      await apiPost('audio/$name${_profileQuery(profile)}', body: const {});
      return 200;
    } on DashboardHttpException catch (e) {
      return e.statusCode;
    }
  }

  /// Catálogo dinámico del TTS que ofrece el mismo configurador oficial de
  /// Hermes Desktop. Incluye plugins, credenciales requeridas (solo `is_set`),
  /// proveedor activo y preparación opcional.
  Future<Map<String, dynamic>> getVoiceToolsetConfig(
    String toolset, {
    String? profile,
  }) => apiGet(
    'tools/toolsets/${_voiceToolset(toolset)}/config${_profileQuery(profile)}',
  );

  Future<Map<String, dynamic>> getTtsToolsetConfig({String? profile}) =>
      getVoiceToolsetConfig('tts', profile: profile);

  Future<Map<String, dynamic>> getSttToolsetConfig({String? profile}) =>
      getVoiceToolsetConfig('stt', profile: profile);

  /// Selecciona un proveedor por el nombre exacto anunciado por el catálogo.
  /// El servidor valida la fila y persiste `tts.provider` por su camino
  /// canónico; la app nunca escribe config.yaml.
  Future<Map<String, dynamic>> setVoiceToolsetProvider(
    String toolset,
    String providerName, {
    String? profile,
  }) => apiPut(
    'tools/toolsets/${_voiceToolset(toolset)}/provider${_profileQuery(profile)}',
    body: {'provider': providerName},
  );

  Future<Map<String, dynamic>> setTtsToolsetProvider(
    String providerName, {
    String? profile,
  }) => setVoiceToolsetProvider('tts', providerName, profile: profile);

  Future<Map<String, dynamic>> setSttToolsetProvider(
    String providerName, {
    String? profile,
  }) => setVoiceToolsetProvider('stt', providerName, profile: profile);

  /// Envía claves nuevas al almacén `.env` de Hermes. Los nombres permitidos
  /// los valida el servidor contra el catálogo TTS; los valores no se leen de
  /// vuelta ni se guardan en el móvil.
  Future<Map<String, dynamic>> setVoiceToolsetCredentials(
    String toolset,
    Map<String, String> values, {
    String? profile,
  }) => apiPut(
    'tools/toolsets/${_voiceToolset(toolset)}/env${_profileQuery(profile)}',
    body: {'env': values},
  );

  Future<Map<String, dynamic>> setTtsToolsetCredentials(
    Map<String, String> values, {
    String? profile,
  }) => setVoiceToolsetCredentials('tts', values, profile: profile);

  Future<Map<String, dynamic>> setSttToolsetCredentials(
    Map<String, String> values, {
    String? profile,
  }) => setVoiceToolsetCredentials('stt', values, profile: profile);

  /// Inicia una preparación declarada por el proveedor (KittenTTS, Piper…).
  /// `key` se valida de nuevo server-side contra la allowlist oficial.
  Future<Map<String, dynamic>> startVoiceToolsetPostSetup(
    String toolset,
    String key, {
    String? profile,
  }) => apiPost(
    'tools/toolsets/${_voiceToolset(toolset)}/post-setup${_profileQuery(profile)}',
    body: {'key': key},
  );

  Future<Map<String, dynamic>> startTtsToolsetPostSetup(
    String key, {
    String? profile,
  }) => startVoiceToolsetPostSetup('tts', key, profile: profile);

  Future<Map<String, dynamic>> startSttToolsetPostSetup(
    String key, {
    String? profile,
  }) => startVoiceToolsetPostSetup('stt', key, profile: profile);

  static String _voiceToolset(String value) {
    if (value == 'tts' || value == 'stt') return value;
    throw ArgumentError.value(value, 'toolset', 'Expected tts or stt');
  }

  /// Estado de una acción larga del Dashboard, con `running`, `exit_code` y
  /// últimas líneas. [name] solo se usa con nombres definidos por Hermes.
  Future<Map<String, dynamic>> getActionStatus(String name) =>
      apiGet('actions/${Uri.encodeComponent(name)}/status');

  /// PUT /api/env — fija una variable de entorno (p.ej. la API key de un
  /// proveedor). El servidor rechaza nombres peligrosos (denylist).
  Future<bool> setEnvVar(String key, String value) async {
    final res = await apiPut('env', body: {'key': key, 'value': value});
    return (res['ok'] as bool?) ?? false;
  }

  /// DELETE /api/env — borra una variable de entorno (p.ej. la API key de un
  /// proveedor) para desconfigurarlo.
  Future<void> deleteEnvVar(String key) => apiDelete('env', body: {'key': key});

  /// DELETE /api/providers/oauth/{id} — desconecta un proveedor OAuth.
  Future<void> disconnectOAuth(String providerId) =>
      apiDelete('providers/oauth/$providerId');

  /// POST /api/providers/oauth/{id}/start — inicia el login OAuth (device_code).
  Future<Map<String, dynamic>> startOAuth(String providerId) =>
      apiPost('providers/oauth/$providerId/start');

  /// GET /api/providers/oauth/{id}/poll/{session} — estado del login OAuth.
  Future<Map<String, dynamic>> pollOAuth(String providerId, String sessionId) =>
      apiGet('providers/oauth/$providerId/poll/$sessionId');

  Future<List<Map<String, dynamic>>> getSkills({String? profile}) async {
    final data = await apiGetList('skills${_profileQuery(profile)}');
    return data.whereType<Map<String, dynamic>>().toList();
  }

  /// GET /api/logs — tail del log elegido con filtros server-side.
  /// Contrato (web_server.py): file ∈ {agent,errors,gateway,gui,desktop},
  /// lines ≤ 500, level/search opcionales. Devuelve {file, lines: [String]}.
  Future<List<String>> getLogs({
    String file = 'agent',
    int lines = 200,
    String? level,
    String? search,
  }) async {
    final params = <String, String>{
      'file': file,
      'lines': '$lines',
      if (level != null && level.isNotEmpty) 'level': level,
      if (search != null && search.isNotEmpty) 'search': search,
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final data = await apiGet('logs?$query');
    return (data['lines'] as List? ?? []).whereType<String>().toList();
  }

  // ── Cron job management ──────────────────────────────────────────────

  /// Elimina un cron de forma idempotente. Si hay perfil activo, probamos ese
  /// ámbito y SIEMPRE confirmamos también en el ámbito global: Hermes responde
  /// éxito cuando el job ya estaba ausente del perfil, así que un 2xx scoped no
  /// demuestra que el schedule global haya desaparecido.
  Future<void> deleteCronJob(String jobId, {String? profile}) async {
    final id = validateCronJobId(jobId);
    final scopedProfile = validateCronProfile(profile);
    final endpoint = 'cron/jobs/${Uri.encodeComponent(id)}';
    final scopedQuery = _profileQuery(scopedProfile);
    if (scopedQuery.isNotEmpty) {
      final deleted = await _deleteCronEndpoint('$endpoint$scopedQuery');
      if (!deleted) {
        throw const CronDeleteRejectedException();
      }
    }
    final deleted = await _deleteCronEndpoint(endpoint);
    if (!deleted) {
      throw const CronDeleteRejectedException();
    }
  }

  Future<bool> _deleteCronEndpoint(
    String endpoint, {
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .delete(Uri.parse('$_baseUrl/api/$endpoint'), headers: headers)
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return _deleteCronEndpoint(endpoint, retried: true);
    }
    if (res.statusCode == 404) return true;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final body = res.body.trim();
    if (body.isEmpty) return true;
    try {
      final decoded = jsonDecode(body);
      return decoded is! Map || decoded['deleted'] != false;
    } on FormatException {
      // Algunos Dashboards antiguos devuelven texto/HTML con 2xx. Conservamos
      // la compatibilidad previa: solo `deleted:false` JSON es un rechazo.
      return true;
    }
  }

  Future<Map<String, dynamic>> createJob({
    required String prompt,
    required String schedule,
    String name = '',
    String deliver = 'local',
    String? profile,
  }) => apiPost(
    'cron/jobs${_profileQuery(profile)}',
    body: {
      'prompt': prompt,
      'schedule': schedule,
      'name': name,
      'deliver': deliver,
    },
  );

  static Map<String, dynamic> buildCronUpdateBody(
    Map<String, dynamic> updates,
  ) => {'updates': updates};

  Future<Map<String, dynamic>> updateJob(
    String jobId,
    Map<String, dynamic> updates, {
    String? profile,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http
        .put(
          Uri.parse('$_baseUrl/api/cron/jobs/$jobId${_profileQuery(profile)}'),
          headers: headers,
          body: jsonEncode(buildCronUpdateBody(updates)),
        )
        .timeout(_kTimeout);
    _ingestSetCookie(res);
    if (res.statusCode == 401 && !retried) {
      _resetSession();
      return updateJob(jobId, updates, profile: profile, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  void close() => _http.close();
}
