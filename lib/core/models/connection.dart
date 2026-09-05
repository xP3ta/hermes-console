// Connection model for remote Hermes Gateway API Server.

import 'dart:io';

/// Mecanismo de autenticación de cada superficie de la instancia.
///
/// Gateway (8642) usa [bearerToken] (`Authorization: Bearer API_SERVER_KEY`).
/// Dashboard (9119) usa [cookieSession] (token SPA scrapeado del HTML de `/`),
/// [sessionToken] (token pegado manualmente), o [basicAuth] cuando el servidor
/// define HERMES_DASHBOARD_BASIC_AUTH_USERNAME/PASSWORD.
enum AuthMode {
  none('none', 'No auth'),
  bearerToken('bearer', 'Bearer token'),
  apiKey('api_key', 'API key'),
  sessionToken('session_token', 'Session token (manual)'),
  basicAuth('basic', 'Username and password'),
  cookieSession('cookie_session', 'Automatic (Dashboard token)'),
  unknown('unknown', 'Unknown');

  const AuthMode(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static AuthMode fromStorage(String? value, {AuthMode fallback = AuthMode.unknown}) {
    return AuthMode.values.firstWhere(
      (m) => m.storageKey == value,
      orElse: () => fallback,
    );
  }
}

/// Modo de chat para instancias locales (Termux / on-device bridge).
///
/// [auto] = la app elige según el modelo detectado (OlliteRT/Ollama pequeño →
///   simple, agente capaz → completo). Si no se puede detectar, usa [simple].
/// [simple] = POST directo sin tools; funciona con cualquier modelo pequeño.
/// [agent] = agente completo hermes -z; requiere un modelo capaz (>=7B).
enum LocalChatMode {
  auto('auto', 'Recommended', 'Simple chat by default (no tools)'),
  simple('simple', 'Simple chat', 'No tools, for small models'),
  agent('agent', 'Full agent', 'Requires a capable model (≥7B)');

  const LocalChatMode(this.storageKey, this.label, this.description);

  final String storageKey;
  final String label;
  final String description;

  static LocalChatMode fromStorage(String? value) {
    return LocalChatMode.values.firstWhere(
      (m) => m.storageKey == value,
      orElse: () => LocalChatMode.auto,
    );
  }
}

/// Kind of instance — determines icon and display context.
enum InstanceKind {
  vps('vps', 'VPS'),
  homelab('homelab', 'homelab'),
  pc('pc', 'PC'),
  tailscale('tailscale', 'tailscale'),
  localhost('localhost', 'localhost');

  const InstanceKind(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static InstanceKind fromStorage(String? value) {
    return InstanceKind.values.firstWhere(
      (k) => k.storageKey == value,
      orElse: () => InstanceKind.vps,
    );
  }
}

// Cached emulator detection — evaluated once per process.
bool? _onAndroidEmulator;

bool _checkAndroidEmulator() {
  if (!Platform.isAndroid) return false;
  // Emuladores modernos (ranchu/API 30+): goldfish_pipe fue reemplazado pero
  // goldfish_address_space y goldfish_sync siguen presentes.
  // Emuladores clásicos (goldfish): goldfish_pipe existe.
  return File('/dev/goldfish_address_space').existsSync() ||
      File('/dev/goldfish_pipe').existsSync() ||
      File('/dev/goldfish_sync').existsSync();
}

/// On QEMU Android emulators, 127.0.0.1/localhost refers to the emulator VM,
/// not the host machine. 10.0.2.2 is the standard alias for the host.
/// On real devices this returns [host] unchanged.
///
/// [onDeviceLoopback] desactiva la reescritura: el servicio corre en ESTE mismo
/// dispositivo (p.ej. el agente local Termux, que escucha en 127.0.0.1 del
/// propio Android). Reescribir a 10.0.2.2 lo mandaría al host de desarrollo y
/// nunca conectaría. Solo las instancias que apuntan al host del PC deben
/// reescribirse.
String _resolveHost(String host, {bool onDeviceLoopback = false}) {
  if (onDeviceLoopback) return host;
  _onAndroidEmulator ??= _checkAndroidEmulator();
  if (_onAndroidEmulator! &&
      (host == '127.0.0.1' || host == 'localhost')) {
    return '10.0.2.2';
  }
  return host;
}

/// Versión pública de la reescritura de loopback para servicios que viven en el
/// HOST de desarrollo (no instancias [SavedConnection]). El caso de uso es
/// Ollama: en un dispositivo real con Termux corre en `127.0.0.1` del propio
/// Android (se devuelve sin tocar), pero en el emulador el daemon de Ollama
/// corre en el host de desarrollo, accesible vía `10.0.2.2`.
String resolveEmulatorLoopback(String host) => _resolveHost(host);

/// Infers [InstanceKind] from a hostname or IP string.
///
/// Precedence:
///   localhost / 127.0.0.1 / 10.0.2.2  → localhost
///   *.ts.net or 100.64–100.127 range   → tailscale
///   RFC-1918 private IPs               → homelab
///   everything else                    → vps
InstanceKind inferInstanceKind(String host) {
  final h = host.trim().toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '10.0.2.2') {
    return InstanceKind.localhost;
  }
  if (h.endsWith('.ts.net')) return InstanceKind.tailscale;
  final parts = h.split('.');
  if (parts.length == 4) {
    final octets = parts.map(int.tryParse).toList();
    if (octets.every((o) => o != null)) {
      final a = octets[0]!;
      final b = octets[1]!;
      // Tailscale CGNAT range: 100.64.0.0/10  →  100.64.x.x – 100.127.x.x
      if (a == 100 && b >= 64 && b <= 127) return InstanceKind.tailscale;
      // RFC-1918
      if (a == 10) return InstanceKind.homelab;
      if (a == 192 && b == 168) return InstanceKind.homelab;
      if (a == 172 && b >= 16 && b <= 31) return InstanceKind.homelab;
    }
  }
  return InstanceKind.vps;
}

class NormalizedConnectionHost {
  final String host;
  final int port;
  final bool useHttps;

  const NormalizedConnectionHost({
    required this.host,
    required this.port,
    this.useHttps = false,
  });
}

class SavedConnection {
  final String id;
  final String label;
  final String host;
  final int port;
  final String apiKey;
  final bool useHttps;
  final InstanceKind kind;

  /// Modo solo lectura: la app puede leer chat/sesiones/skills/memoria pero
  /// bloquea toda acción que mute el servidor (borrar sesiones, crear cron,
  /// instalar skills, enviar prompts, cambiar modelo).
  final bool readOnly;

  /// Auth del Gateway. Hoy siempre [AuthMode.bearerToken]; el campo existe
  /// para que la matriz de capacidades y el diagnóstico hablen en concreto.
  final AuthMode gatewayAuthMode;

  /// URL completa del Dashboard/Admin (p.ej. `http://host:9119`). Si es null
  /// se deriva del host del Gateway con la heurística clásica (9119, o el
  /// mismo puerto en despliegues HTTPS con reverse proxy).
  final String? dashboardUrl;

  /// Auth del Dashboard. [AuthMode.cookieSession] = scrape automático del
  /// token SPA; [AuthMode.sessionToken] = token pegado por el usuario;
  /// [AuthMode.basicAuth] = usuario/contraseña (+ scrape posterior).
  final AuthMode dashboardAuthMode;

  /// Nota libre del usuario sobre la instancia.
  final String notes;

  /// Último diagnóstico ejecutado (ms epoch). Null si nunca.
  final int? lastHealthCheckMs;

  /// Los servicios de esta instancia corren en ESTE mismo dispositivo (loopback
  /// del propio Android), p.ej. el agente local Termux. Desactiva la reescritura
  /// 127.0.0.1→10.0.2.2 del emulador, que solo aplica a servidores en el host.
  final bool onDeviceLoopback;

  /// Modo de chat para instancias locales (kind == localhost).
  /// Ignorado en instancias remotas. Default [LocalChatMode.auto].
  final LocalChatMode localChatMode;

  SavedConnection({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.apiKey,
    this.useHttps = false,
    this.readOnly = false,
    this.gatewayAuthMode = AuthMode.bearerToken,
    this.dashboardUrl,
    this.dashboardAuthMode = AuthMode.cookieSession,
    this.notes = '',
    this.lastHealthCheckMs,
    this.onDeviceLoopback = false,
    this.localChatMode = LocalChatMode.auto,
    InstanceKind? kind,
  }) : kind = kind ?? inferInstanceKind(host);

  /// Copia con campos sobreescritos. `kind` se conserva explícitamente (el
  /// constructor lo infiere del host si no se pasa, así que lo pasamos siempre).
  SavedConnection copyWith({
    String? id,
    String? label,
    String? host,
    int? port,
    String? apiKey,
    bool? useHttps,
    bool? readOnly,
    AuthMode? gatewayAuthMode,
    String? dashboardUrl,
    AuthMode? dashboardAuthMode,
    String? notes,
    int? lastHealthCheckMs,
    bool? onDeviceLoopback,
    LocalChatMode? localChatMode,
    InstanceKind? kind,
  }) {
    return SavedConnection(
      id: id ?? this.id,
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      apiKey: apiKey ?? this.apiKey,
      useHttps: useHttps ?? this.useHttps,
      readOnly: readOnly ?? this.readOnly,
      gatewayAuthMode: gatewayAuthMode ?? this.gatewayAuthMode,
      dashboardUrl: dashboardUrl ?? this.dashboardUrl,
      dashboardAuthMode: dashboardAuthMode ?? this.dashboardAuthMode,
      notes: notes ?? this.notes,
      lastHealthCheckMs: lastHealthCheckMs ?? this.lastHealthCheckMs,
      onDeviceLoopback: onDeviceLoopback ?? this.onDeviceLoopback,
      localChatMode: localChatMode ?? this.localChatMode,
      kind: kind ?? this.kind,
    );
  }

  /// Reescribe el loopback según el entorno, salvo que la instancia sea
  /// on-device (sus servicios viven en este mismo Android).
  String _resolved(String h) => _resolveHost(h, onDeviceLoopback: onDeviceLoopback);

  String get baseUrl {
    final scheme = useHttps ? 'https' : 'http';
    return '$scheme://${_resolved(host)}:$port';
  }

  /// Alias semántico: URL del Gateway API Server.
  String get gatewayUrl => baseUrl;

  /// Puerto por defecto del Mobile Bridge (servicio opcional del servidor).
  static const int defaultBridgePort = 9131;

  /// URL derivada del Mobile Bridge: mismo host que el gateway, puerto 9131.
  /// Permite autodetectar el bridge sin que el usuario teclee IP/puerto.
  String get derivedBridgeUrl {
    final scheme = useHttps ? 'https' : 'http';
    return '$scheme://${_resolved(host)}:$defaultBridgePort';
  }

  /// Dashboard/API-server topology differs between local LAN and HTTPS proxy
  /// setups. Local Gateway chat connections normally use 8642 while the
  /// dashboard lives on 9119. HTTPS reverse-proxy deployments usually expose
  /// both API surfaces on the same external HTTPS port.
  int get dashboardPort {
    final explicit = dashboardUri;
    if (explicit != null) {
      return explicit.hasPort ? explicit.port : (explicit.scheme == 'https' ? 443 : 80);
    }
    return useHttps ? port : 9119;
  }

  /// URL efectiva del Dashboard (explícita o derivada).
  /// En emuladores Android, reescribe 127.0.0.1/localhost → 10.0.2.2.
  String get effectiveDashboardUrl {
    final explicit = dashboardUrl?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      final url = explicit.endsWith('/')
          ? explicit.substring(0, explicit.length - 1)
          : explicit;
      final uri = Uri.tryParse(url.contains('://') ? url : 'http://$url');
      if (uri != null && uri.host.isNotEmpty) {
        final resolved = _resolved(uri.host);
        if (resolved != uri.host) return uri.replace(host: resolved).toString();
      }
      return url;
    }
    final scheme = useHttps ? 'https' : 'http';
    return '$scheme://${_resolved(host)}:${useHttps ? port : 9119}';
  }

  Uri? get dashboardUri {
    final raw = dashboardUrl?.trim();
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
    return (uri == null || uri.host.isEmpty) ? null : uri;
  }

  bool get dashboardUseHttps =>
      dashboardUri?.scheme == 'https' || (dashboardUrl == null && useHttps);

  String get dashboardHost => dashboardUri?.host ?? host;

  /// Parses [input] as a URI and extracts host, port, and HTTPS flag.
  ///
  /// When the user provides an explicit port inside the URL (e.g.
  /// `https://example.com:8443`) that port is always used.
  ///
  /// When the URL has no explicit port, the [fallbackPort] is used.
  /// Callers should set [fallbackPort] to the value typed by the user in the
  /// Port field, so custom HTTPS ports (e.g. 8443) are preserved.
  static NormalizedConnectionHost normalizeHostAndPort(
    String input,
    int fallbackPort,
  ) {
    var raw = input.trim();
    final bool detectedHttps = raw.toLowerCase().startsWith('https://');
    if (raw.isEmpty) {
      return NormalizedConnectionHost(
        host: raw,
        port: fallbackPort,
        useHttps: detectedHttps,
      );
    }

    if (!raw.contains('://')) raw = 'http://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      return NormalizedConnectionHost(
        host: input.trim(),
        port: fallbackPort,
        useHttps: detectedHttps,
      );
    }

    final normalizedPort = uri.hasPort
        ? uri.port
        : detectedHttps && fallbackPort == 8642
        ? 443
        : fallbackPort;

    return NormalizedConnectionHost(
      host: uri.host,
      port: normalizedPort,
      useHttps: detectedHttps || (uri.scheme == 'https'),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'host': host,
      'port': port,
      'use_https': useHttps,
      'kind': kind.storageKey,
      'read_only': readOnly,
      'gateway_auth_mode': gatewayAuthMode.storageKey,
      'dashboard_url': dashboardUrl,
      'dashboard_auth_mode': dashboardAuthMode.storageKey,
      'notes': notes,
      'last_health_check_ms': lastHealthCheckMs,
      'on_device_loopback': onDeviceLoopback,
      'local_chat_mode': localChatMode.storageKey,
      // api_key is NOT persisted here — stored in Android Keystore via SecureStorage
    };
  }

  factory SavedConnection.fromMap(Map<String, dynamic> map) {
    final host = map['host'] as String;
    // If no 'kind' stored, infer from host so existing data migrates cleanly.
    final kind = map.containsKey('kind')
        ? InstanceKind.fromStorage(map['kind'] as String?)
        : inferInstanceKind(host);
    final hLower = host.trim().toLowerCase();
    final isLoopback = hLower == '127.0.0.1' || hLower == 'localhost';
    // Migración: instancias localhost loopback guardadas antes de este campo
    // son el agente local on-device → no reescribir su loopback.
    final onDeviceLoopback = map['on_device_loopback'] as bool? ??
        (kind == InstanceKind.localhost && isLoopback);
    return SavedConnection(
      id: map['id'] as String,
      label: map['label'] as String,
      host: host,
      port: (map['port'] as int?) ?? 8642,
      apiKey: (map['api_key'] as String?) ?? '',
      useHttps: (map['use_https'] as bool?) ?? false,
      readOnly: (map['read_only'] as bool?) ?? false,
      gatewayAuthMode: AuthMode.fromStorage(
        map['gateway_auth_mode'] as String?,
        fallback: AuthMode.bearerToken,
      ),
      dashboardUrl: map['dashboard_url'] as String?,
      dashboardAuthMode: AuthMode.fromStorage(
        map['dashboard_auth_mode'] as String?,
        fallback: AuthMode.cookieSession,
      ),
      notes: (map['notes'] as String?) ?? '',
      lastHealthCheckMs: map['last_health_check_ms'] as int?,
      onDeviceLoopback: onDeviceLoopback,
      localChatMode: LocalChatMode.fromStorage(
        map['local_chat_mode'] as String?,
      ),
      kind: kind,
    );
  }
}
