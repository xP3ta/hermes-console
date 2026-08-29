// Diagnóstico de conexión por instancia: pruebas reales contra el Gateway
// (8642) y el Dashboard/Admin (9119), clasificación de errores con causa
// concreta y construcción de la CapabilityMatrix.
//
// Contratos verificados contra hermes-agent 0.16.0 — ver docs/API_AUDIT.md.
// Regla: nada de endpoints inventados; lo no comprobable queda `unknown`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../l10n/app_localizations.dart';
import '../utils/transport_privacy.dart';
import 'connection_manager.dart';

/// Persiste una matriz recién comprobada únicamente cuando el diagnóstico se
/// ejecutó contra la misma superficie que la conexión guardada.
///
/// El editor permite probar URL y credenciales sin guardar. Asociar ese
/// resultado a la conexión viva haría aparecer capacidades verdes de otro
/// endpoint al volver a abrirla. Por eso la escritura es independiente del
/// formulario y falla cerrada si cambió el destino o alguna credencial.
Future<bool> persistVerifiedCapabilityMatrix({
  required ConnectionManager manager,
  required SavedConnection probedConnection,
  required CapabilityMatrix matrix,
  required bool credentialsOverridden,
}) async {
  if (credentialsOverridden || matrix.checkedAtMs == null) return false;

  SavedConnection? saved;
  for (final connection in manager.getConnections()) {
    if (connection.id == probedConnection.id) {
      saved = connection;
      break;
    }
  }
  if (saved == null || !_sameDiagnosticTarget(saved, probedConnection)) {
    return false;
  }

  await manager.saveCapabilities(saved.id, matrix);
  return true;
}

bool _sameDiagnosticTarget(SavedConnection saved, SavedConnection probed) {
  String normalizedUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '').toLowerCase();

  return saved.id == probed.id &&
      normalizedUrl(saved.gatewayUrl) == normalizedUrl(probed.gatewayUrl) &&
      normalizedUrl(saved.effectiveDashboardUrl) ==
          normalizedUrl(probed.effectiveDashboardUrl) &&
      saved.gatewayAuthMode == probed.gatewayAuthMode &&
      saved.dashboardAuthMode == probed.dashboardAuthMode &&
      saved.kind == probed.kind &&
      saved.onDeviceLoopback == probed.onDeviceLoopback;
}

/// Resultado clasificado de una prueba individual.
enum ProbeStatus {
  ok,
  authInvalid,
  authRequired,
  notFound,
  methodNotAllowed,
  refused,
  timeout,
  dnsError,
  tlsError,
  httpError,
  error,
  skipped,
}

extension ProbeStatusX on ProbeStatus {
  bool get isOk => this == ProbeStatus.ok;

  String localizedLabel(Strings s) => switch (this) {
    ProbeStatus.ok => s.diagStatusOk,
    ProbeStatus.authInvalid => s.diagStatusAuthInvalid,
    ProbeStatus.authRequired => s.diagStatusAuthRequired,
    ProbeStatus.notFound => s.diagStatusNotFound,
    ProbeStatus.methodNotAllowed => s.diagStatusReadOnly,
    ProbeStatus.refused => s.diagStatusRefused,
    ProbeStatus.timeout => s.diagStatusTimeout,
    ProbeStatus.dnsError => s.diagStatusDns,
    ProbeStatus.tlsError => s.diagStatusTls,
    ProbeStatus.httpError => s.diagStatusHttp,
    ProbeStatus.error => s.diagStatusError,
    ProbeStatus.skipped => s.diagStatusSkipped,
  };
}

class ProbeResult {
  final String name;
  final ProbeStatus status;
  final int? httpCode;
  final int? latencyMs;
  final String detail;

  const ProbeResult({
    required this.name,
    required this.status,
    this.httpCode,
    this.latencyMs,
    this.detail = '',
  });

  String localizedName(Strings s) => switch (name) {
    'health' || 'status' => s.ieProbeOnline,
    'auth' => s.ieProbeAuth,
    'sessions' => s.ieProbeSessions,
    'models' => s.ieProbeModels,
    'models/providers' => s.ieProbeModelsProviders,
    'memory' => s.ieProbeMemory,
    'skills (gateway)' => 'skills',
    _ => name,
  };

  /// Los detalles de transporte se generan en la capa de red y antes eran
  /// siempre españoles. La UI y el diagnóstico copiable presentan una causa
  /// localizada sin volcar excepciones del sistema ni texto de otro idioma.
  String localizedDetail(Strings s) => switch (status) {
    ProbeStatus.timeout => s.diagDetailTimeout,
    ProbeStatus.tlsError => s.diagDetailTls,
    ProbeStatus.dnsError => s.diagDetailDns,
    ProbeStatus.refused => s.diagDetailRefused,
    ProbeStatus.authInvalid || ProbeStatus.authRequired => s.diagDetailAuth,
    ProbeStatus.error => s.diagStatusError,
    _ => detail,
  };
}

/// Payload parseado de GET /v1/capabilities (contrato hermes-agent:
/// gateway/platforms/api_server.py — object hermes.api_server.capabilities).
class ServerCapabilities {
  final String? platform;
  final String? model;
  final Map<String, dynamic> features;
  final Map<String, dynamic> endpoints;

  const ServerCapabilities({
    this.platform,
    this.model,
    this.features = const {},
    this.endpoints = const {},
  });

  static ServerCapabilities? tryParse(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['object'] != 'hermes.api_server.capabilities') {
        return null;
      }
      return ServerCapabilities(
        platform: json['platform'] as String?,
        model: json['model'] as String?,
        features: (json['features'] as Map?)?.cast<String, dynamic>() ?? {},
        endpoints: (json['endpoints'] as Map?)?.cast<String, dynamic>() ?? {},
      );
    } catch (_) {
      debugPrint('[diagnostics] respuesta de capacidades inválida');
      return null;
    }
  }

  bool? feature(String key) {
    final v = features[key];
    return v is bool ? v : null;
  }

  bool hasEndpoint(String key) => endpoints.containsKey(key);

  /// Returns a server-declared read endpoint only when it remains on [base].
  /// Invalid or mutating metadata is ignored rather than probed speculatively.
  Uri? safeGetEndpoint(String key, Uri base) {
    final value = endpoints[key];
    if (value is! Map || value['method'] != 'GET' || value['path'] is! String) {
      return null;
    }
    final candidate = Uri.tryParse(value['path'] as String);
    if (candidate == null ||
        candidate.hasScheme ||
        candidate.hasAuthority ||
        !candidate.path.startsWith('/') ||
        candidate.hasFragment ||
        candidate.hasQuery ||
        candidate.pathSegments.lastOrNull != key) {
      return null;
    }
    final resolved = base.resolveUri(candidate);
    if (resolved.scheme != base.scheme ||
        resolved.host != base.host ||
        resolved.port != base.port) {
      return null;
    }
    return resolved;
  }

  /// Resumen legible para el diagnóstico (sin volcar el JSON entero).
  String get summary {
    final on = features.entries
        .where((e) => e.value == true)
        .map((e) => e.key)
        .toList();
    final off = features.entries
        .where((e) => e.value == false)
        .map((e) => e.key)
        .toList();
    return [
      if (platform != null) 'platform: $platform',
      if (model != null) 'model: $model',
      'endpoints: ${endpoints.length}',
      if (on.isNotEmpty) 'on: ${on.join(', ')}',
      if (off.isNotEmpty) 'off: ${off.join(', ')}',
    ].join('\n');
  }
}

/// Informe completo de un diagnóstico.
class DiagnosticsReport {
  final List<ProbeResult> gateway;
  final List<ProbeResult> dashboard;
  final List<ProbeResult> bridge;
  final CapabilityMatrix matrix;
  final List<String> suggestions;
  final ServerCapabilities? serverCapabilities;
  final DateTime ranAt;

  const DiagnosticsReport({
    required this.gateway,
    required this.dashboard,
    this.bridge = const [],
    required this.matrix,
    required this.suggestions,
    this.serverCapabilities,
    required this.ranAt,
  });

  /// Texto plano copiable para soporte/debug. No incluye tokens.
  String toCopyText(Strings s) {
    final b = StringBuffer('${s.diagCopyTitle}\n');
    b.writeln('date: ${ranAt.toIso8601String()}');
    b.writeln('\n[gateway]');
    for (final r in gateway) {
      b.writeln(
        '  ${r.localizedName(s)}: ${r.status.localizedLabel(s)}'
        '${r.httpCode != null ? ' (HTTP ${r.httpCode})' : ''}'
        '${r.latencyMs != null ? ' ${r.latencyMs}ms' : ''}'
        '${r.localizedDetail(s).isNotEmpty ? ' — ${r.localizedDetail(s)}' : ''}',
      );
    }
    b.writeln('\n[dashboard]');
    for (final r in dashboard) {
      b.writeln(
        '  ${r.localizedName(s)}: ${r.status.localizedLabel(s)}'
        '${r.httpCode != null ? ' (HTTP ${r.httpCode})' : ''}'
        '${r.latencyMs != null ? ' ${r.latencyMs}ms' : ''}'
        '${r.localizedDetail(s).isNotEmpty ? ' — ${r.localizedDetail(s)}' : ''}',
      );
    }
    b.writeln('\n[bridge]');
    for (final r in bridge) {
      b.writeln(
        '  ${r.localizedName(s)}: ${r.status.localizedLabel(s)}'
        '${r.httpCode != null ? ' (HTTP ${r.httpCode})' : ''}'
        '${r.latencyMs != null ? ' ${r.latencyMs}ms' : ''}'
        '${r.localizedDetail(s).isNotEmpty ? ' — ${r.localizedDetail(s)}' : ''}',
      );
    }
    final caps = serverCapabilities;
    if (caps != null) {
      b.writeln('\n[/v1/capabilities]');
      b.writeln(caps.summary);
    }
    if (suggestions.isNotEmpty) {
      b.writeln('\n[${s.diagCopySuggestions}]');
      for (final s in suggestions) {
        b.writeln('  - $s');
      }
    }
    return b.toString();
  }
}

class ConnectionDiagnostics {
  final http.Client _http;
  static const _kTimeout = Duration(seconds: 8);

  ConnectionDiagnostics({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  void close() => _http.close();

  // ── Primitiva de sondeo ────────────────────────────────────────────────

  Future<ProbeResult> _probe(
    String name,
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Set<int> okCodes = const {200},
    void Function(http.Response)? inspectResponse,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final request = http.Request(method, uri);
      request.followRedirects = false;
      if (headers != null) request.headers.addAll(headers);
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final streamed = await _http.send(request).timeout(_kTimeout);
      final res = await http.Response.fromStream(streamed);
      inspectResponse?.call(res);
      sw.stop();
      final code = res.statusCode;
      final status = okCodes.contains(code)
          ? ProbeStatus.ok
          : switch (code) {
              401 || 403 => ProbeStatus.authInvalid,
              404 => ProbeStatus.notFound,
              405 => ProbeStatus.methodNotAllowed,
              _ => ProbeStatus.httpError,
            };
      return ProbeResult(
        name: name,
        status: status,
        httpCode: code,
        latencyMs: sw.elapsedMilliseconds,
        detail: status == ProbeStatus.ok ? '' : 'HTTP $code',
      );
    } on TimeoutException {
      return ProbeResult(
        name: name,
        status: ProbeStatus.timeout,
        detail: 'sin respuesta en ${_kTimeout.inSeconds}s',
      );
    } on HandshakeException catch (e) {
      return ProbeResult(
        name: name,
        status: ProbeStatus.tlsError,
        detail: 'certificado TLS inválido: ${e.message}',
      );
    } on SocketException catch (e) {
      final msg = e.message.toLowerCase();
      final os = e.osError?.message.toLowerCase() ?? '';
      if (msg.contains('failed host lookup') ||
          os.contains('name or service')) {
        return ProbeResult(
          name: name,
          status: ProbeStatus.dnsError,
          detail: 'el host no se resuelve',
        );
      }
      if (msg.contains('refused') || os.contains('refused')) {
        return ProbeResult(
          name: name,
          status: ProbeStatus.refused,
          detail: 'conexión rechazada (¿puerto correcto?)',
        );
      }
      return ProbeResult(
        name: name,
        status: ProbeStatus.error,
        detail: e.message,
      );
    } catch (e) {
      return ProbeResult(name: name, status: ProbeStatus.error, detail: '$e');
    }
  }

  // ── Gateway (8642) ────────────────────────────────────────────────────

  Future<(List<ProbeResult>, String?, ServerCapabilities?)> probeGateway(
    SavedConnection conn,
  ) async {
    final base = TransportPrivacy.requireAllowed(conn.gatewayUrl);
    final auth = {'Authorization': 'Bearer ${conn.apiKey}'};
    final results = <ProbeResult>[];
    String? version;
    ServerCapabilities? serverCaps;

    // 1. /health — público; da online + versión + latencia.
    final health = await _probe('health', 'GET', Uri.parse('$base/health'));
    if (health.isOnline && health.status == ProbeStatus.ok) {
      try {
        final res = await _http
            .get(Uri.parse('$base/health'))
            .timeout(_kTimeout);
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        version = data['version'] as String?;
      } catch (e) {
        debugPrint(
          '[diagnostics] excepción silenciada (se ignora sin más): $e',
        );
      }
    }
    results.add(health);
    if (!health.isOnline) return (results, version, serverCaps);

    // 2. /api/sessions con Bearer — valida auth + lectura de sesiones.
    results.add(
      await _probe(
        'sessions',
        'GET',
        Uri.parse('$base/api/sessions'),
        headers: conn.apiKey.isEmpty ? null : auth,
      ),
    );

    // 3. /v1/models — lectura de modelos del Gateway.
    results.add(
      await _probe(
        'models',
        'GET',
        Uri.parse('$base/v1/models'),
        headers: auth,
      ),
    );

    // 4. /v1/capabilities — fuente principal de la matriz cuando responde.
    //    Contrato: object hermes.api_server.capabilities con features{} y
    //    endpoints{} (api_server.py del upstream).
    final capsUri = Uri.parse('$base/v1/capabilities');
    final capsProbe = await _probe(
      'capabilities',
      'GET',
      capsUri,
      headers: auth,
      inspectResponse: (res) {
        if (res.statusCode == 200) {
          serverCaps = ServerCapabilities.tryParse(res.body);
        }
      },
    );
    results.add(capsProbe);

    // 5. /v1/skills y /v1/toolsets — lectura via Gateway.
    results.add(
      await _probe(
        'skills (gateway)',
        'GET',
        Uri.parse('$base/v1/skills'),
        headers: auth,
      ),
    );
    results.add(
      await _probe(
        'toolsets',
        'GET',
        Uri.parse('$base/v1/toolsets'),
        headers: auth,
      ),
    );

    // 5b. Skills toggle is never probed: authenticated capabilities is
    // authoritative and diagnostics must not issue mutating requests. Plugins
    // may be verified with GET, honoring valid same-origin endpoint metadata.
    final baseUri = Uri.parse(base);
    final pluginsUri = serverCaps?.hasEndpoint('plugins') ?? false
        ? serverCaps!.safeGetEndpoint('plugins', baseUri)
        : baseUri.resolve('/v1/plugins');
    if (pluginsUri != null) {
      results.add(await _probe('plugins', 'GET', pluginsUri, headers: auth));
    }

    return (results, version, serverCaps);
  }

  // ── Dashboard/Admin (9119) ────────────────────────────────────────────

  Future<List<ProbeResult>> probeDashboard(
    SavedConnection conn,
    DashboardSecrets secrets,
  ) async {
    final base = TransportPrivacy.requireAllowed(conn.effectiveDashboardUrl);
    final results = <ProbeResult>[];

    // 1. /api/status — público; online + estado del gateway según el server.
    final status = await _probe('status', 'GET', Uri.parse('$base/api/status'));
    results.add(status);
    if (!status.isOnline) return results;

    // 2. Resolver auth. Con Basic Auth, _authHeaders() hace login por formulario
    //    y devuelve una COOKIE de sesión (no un X-Hermes-Session-Token). Antes
    //    solo se aceptaba el token → con Basic Auth daba SIEMPRE "auth inválida
    //    · sin token de sesión", aunque el usuario/contraseña fueran correctos.
    //    Ahora la auth es válida si hay CUALQUIER credencial (cookie de login,
    //    token de sesión o Basic), y esas mismas cabeceras se usan para probar
    //    los endpoints protegidos (así sus capacidades dejan de salir en "?").
    Map<String, String> headers = const {};
    String? authError;
    final client = DashboardClient.forConnection(conn, secrets: secrets);
    try {
      headers = await client.authHeadersForDiagnostics();
    } catch (e) {
      authError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      client.close();
    }

    final hasAuth =
        headers.containsKey('Cookie') ||
        (headers['X-Hermes-Session-Token']?.isNotEmpty ?? false) ||
        headers.containsKey('Authorization');
    if (!hasAuth) {
      results.add(
        ProbeResult(
          name: 'auth',
          status: authError != null && authError.contains('login')
              ? ProbeStatus.authRequired
              : ProbeStatus.authInvalid,
          detail: authError ?? 'revisa el usuario y la contraseña',
        ),
      );
      return results;
    }
    results.add(const ProbeResult(name: 'auth', status: ProbeStatus.ok));

    // 3. Endpoints de lectura confirmados en la auditoría.
    for (final (name, path) in const [
      ('skills', '/api/skills'),
      ('cron', '/api/cron/jobs'),
      ('memory', '/api/memory'),
      ('models/providers', '/api/model/options'),
      ('config', '/api/config'),
      ('logs', '/api/logs'),
    ]) {
      results.add(
        await _probe(name, 'GET', Uri.parse('$base$path'), headers: headers),
      );
    }

    return results;
  }

  // ── Diagnóstico completo + matriz ─────────────────────────────────────

  Future<DiagnosticsReport> run(
    Strings s,
    SavedConnection conn,
    DashboardSecrets secrets, {
    String? bridgeUrl,
    String? bridgeToken,
  }) async {
    final (gw, version, serverCaps) = await probeGateway(conn);
    final dash = await probeDashboard(conn, secrets);
    final bridge = await probeBridge(
      conn,
      bridgeUrl: bridgeUrl,
      bridgeToken: bridgeToken,
    );
    final matrix = buildMatrix(gw, dash, version, serverCaps: serverCaps);
    return DiagnosticsReport(
      gateway: gw,
      dashboard: dash,
      bridge: bridge,
      matrix: matrix,
      suggestions: buildSuggestions(s, conn, gw, dash),
      serverCapabilities: serverCaps,
      ranAt: DateTime.now(),
    );
  }

  // ── Mobile Bridge (9131) ──────────────────────────────────────────────

  /// Sondea el Mobile Bridge derivado del host (:9131) sin mutar su estado.
  /// /bridge/health es público; si ya existe un token del Bridge, comprueba
  /// directamente sus capacidades. El aprovisionamiento pertenece al flujo de
  /// edición, no al diagnóstico.
  Future<List<ProbeResult>> probeBridge(
    SavedConnection conn, {
    String? bridgeUrl,
    String? bridgeToken,
  }) async {
    final configuredUrl = bridgeUrl?.trim() ?? '';
    final base = TransportPrivacy.requireAllowed(
      configuredUrl.isEmpty ? conn.derivedBridgeUrl : configuredUrl,
    );
    final results = <ProbeResult>[];

    final health = await _probe(
      'health',
      'GET',
      Uri.parse('$base/bridge/health'),
    );
    results.add(health);
    // Sin un 200 en /bridge/health el bridge no está ahí (puerto cerrado u
    // otro servicio): no tiene sentido comprobar sus capacidades.
    if (health.status != ProbeStatus.ok) return results;

    final storedToken = bridgeToken?.trim() ?? '';
    if (storedToken.isNotEmpty) {
      results.add(
        await _probe(
          'auth',
          'GET',
          Uri.parse('$base/bridge/capabilities'),
          headers: {'Authorization': 'Bearer $storedToken'},
        ),
      );
    }
    return results;
  }

  /// Deriva la matriz desde los resultados. /v1/capabilities tiene prioridad
  /// cuando responde (lo declara el servidor); el resto se infiere con
  /// probes y lo no comprobable queda unknown.
  CapabilityMatrix buildMatrix(
    List<ProbeResult> gw,
    List<ProbeResult> dash,
    String? version, {
    ServerCapabilities? serverCaps,
  }) {
    ProbeResult? find(List<ProbeResult> list, String name) {
      for (final r in list) {
        if (r.name == name) return r;
      }
      return null;
    }

    CapState fromProbe(ProbeResult? r) {
      if (r == null) return CapState.unknown;
      if (r.status == ProbeStatus.ok) return CapState.yes;
      if (r.status == ProbeStatus.notFound ||
          r.status == ProbeStatus.methodNotAllowed) {
        return CapState.no;
      }
      return CapState.unknown;
    }

    final health = find(gw, 'health');
    final gwSessions = find(gw, 'sessions');
    final dashStatus = find(dash, 'status');
    final dashAuth = find(dash, 'auth');

    final gatewayOnline = health == null
        ? CapState.unknown
        : (health.isOnline ? CapState.yes : CapState.no);
    final gatewayAuthValid = gwSessions == null
        ? CapState.unknown
        : (gwSessions.status == ProbeStatus.ok
              ? CapState.yes
              : gwSessions.status == ProbeStatus.authInvalid
              ? CapState.no
              : CapState.unknown);
    final dashboardAuthValid = dashAuth == null
        ? CapState.unknown
        : (dashAuth.status == ProbeStatus.ok ? CapState.yes : CapState.no);

    // Compatibilidad 0.16.x: sesiones, cron y modelos conservan la inferencia
    // histórica. Versiones nuevas declaran skills/plugins en capabilities.
    final sessionsRead = fromProbe(gwSessions);
    final cronRead = fromProbe(find(dash, 'cron'));
    final modelsReadDash = fromProbe(find(dash, 'models/providers'));

    // Valores declarados por /v1/capabilities (prioridad sobre probes).
    final serverSourced = <String>[];
    CapState srv(String matrixField, CapState probed, bool? declared) {
      if (declared == null) return probed;
      serverSourced.add(matrixField);
      return declared ? CapState.yes : CapState.no;
    }

    CapState srvEndpoint(String matrixField, CapState probed, String? key) {
      if (serverCaps == null || key == null) return probed;
      serverSourced.add(matrixField);
      return serverCaps.hasEndpoint(key) ? CapState.yes : CapState.no;
    }

    return CapabilityMatrix(
      gatewayOnline: gatewayOnline,
      dashboardOnline: dashStatus == null
          ? CapState.unknown
          : (dashStatus.isOnline ? CapState.yes : CapState.no),
      gatewayAuthValid: gatewayAuthValid,
      dashboardAuthValid: dashboardAuthValid,
      chatSupported: srv(
        'chatSupported',
        CapState.unknown,
        serverCaps?.feature('chat_completions'),
      ),
      sessionsRead: srvEndpoint(
        'sessionsRead',
        sessionsRead,
        serverCaps == null ? null : 'sessions',
      ),
      sessionsWrite: srvEndpoint(
        'sessionsWrite',
        sessionsRead,
        serverCaps == null ? null : 'session_create',
      ),
      sessionsDelete: srvEndpoint(
        'sessionsDelete',
        sessionsRead,
        serverCaps == null ? null : 'session_delete',
      ),
      // Sin declaración del servidor, el streaming real solo se confirma con
      // el primer chat SSE exitoso (ChatScreen lo marca).
      streamingSupported: srv(
        'streamingSupported',
        CapState.unknown,
        serverCaps?.feature('chat_completions_streaming'),
      ),
      turnIdempotency: srv(
        'turnIdempotency',
        CapState.unknown,
        serverCaps?.feature('turn_idempotency_v1'),
      ),
      kanbanTrackedCreate: srv(
        'kanbanTrackedCreate',
        CapState.unknown,
        serverCaps?.feature('kanban_tracked_create'),
      ),
      skillsRead: srv(
        'skillsRead',
        _firstYes([
          fromProbe(find(dash, 'skills')),
          fromProbe(find(gw, 'skills (gateway)')),
        ]),
        serverCaps?.feature('skills_api'),
      ),
      skillsToggle: srv(
        'skillsToggle',
        CapState.unknown,
        serverCaps?.feature('skills_toggle'),
      ),
      // Installation is a separate Mobile Bridge capability. The Gateway
      // skills_toggle declaration says nothing about install support.
      skillsInstall: CapState.unknown,
      toolsetsRead: srvEndpoint(
        'toolsetsRead',
        fromProbe(find(gw, 'toolsets')),
        serverCaps == null ? null : 'toolsets',
      ),
      cronRead: cronRead,
      cronWrite: cronRead,
      memoryRead: fromProbe(find(dash, 'memory')),
      memoryWrite: srv(
        'memoryWrite',
        CapState.no,
        serverCaps?.feature('memory_write_api'),
      ),
      modelsRead: _firstYes([modelsReadDash, fromProbe(find(gw, 'models'))]),
      modelsWrite: modelsReadDash,
      configRead: fromProbe(find(dash, 'config')),
      configWrite: srv(
        'configWrite',
        CapState.no,
        serverCaps?.feature('admin_config_rw'),
      ),
      logsRead: fromProbe(find(dash, 'logs')),
      pluginsSupported: srv(
        'pluginsSupported',
        fromProbe(find(gw, 'plugins')),
        serverCaps?.feature('plugins_api'),
      ),
      gatewayVersion: version,
      serverModel: serverCaps?.model,
      serverSourced: serverSourced,
      checkedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static CapState _firstYes(List<CapState> states) {
    if (states.any((s) => s.isYes)) return CapState.yes;
    if (states.every((s) => s.isNo)) return CapState.no;
    return CapState.unknown;
  }

  /// Sugerencias accionables según lo encontrado.
  List<String> buildSuggestions(
    Strings s,
    SavedConnection conn,
    List<ProbeResult> gw,
    List<ProbeResult> dash,
  ) {
    final out = <String>[];
    final health = gw.isNotEmpty ? gw.first : null;
    final dashStatus = dash.isNotEmpty ? dash.first : null;

    switch (health?.status) {
      case ProbeStatus.refused:
        out.add(s.diagGwRefused);
      case ProbeStatus.timeout:
        out.add(s.diagGwTimeout);
      case ProbeStatus.dnsError:
        out.add(s.diagGwDns);
      case ProbeStatus.tlsError:
        out.add(s.diagGwTls);
      default:
        break;
    }

    final gwCaps = gw.where((r) => r.name == 'capabilities').firstOrNull;
    if (gwCaps?.status == ProbeStatus.authInvalid) {
      out.add(s.diagCapsAuthInvalid);
    } else if (gwCaps?.status == ProbeStatus.notFound) {
      out.add(s.diagCapsNotFound);
    }

    final gwAuth = gw.where((r) => r.name == 'sessions').firstOrNull;
    if (gwAuth?.status == ProbeStatus.authInvalid) {
      out.add(conn.apiKey.isEmpty ? s.diagTokenMissing : s.diagTokenInvalid);
    }

    final gwOk = health?.status == ProbeStatus.ok;
    switch (dashStatus?.status) {
      case ProbeStatus.refused || ProbeStatus.timeout:
        out.add(gwOk ? s.diagDashDownGwOk : s.diagDashDownBoth);
      case ProbeStatus.notFound:
        out.add(s.diagDashNotFound);
      default:
        break;
    }

    final dashAuth = dash.where((r) => r.name == 'auth').firstOrNull;
    if (dashAuth?.status == ProbeStatus.authRequired) {
      out.add(s.diagDashAuthRequired);
    } else if (dashAuth?.status == ProbeStatus.authInvalid) {
      out.add(s.diagDashAuthInvalid);
    }

    if (gwOk && (dashStatus?.status == ProbeStatus.ok)) {
      final any404 = dash.any((r) => r.status == ProbeStatus.notFound);
      if (any404) {
        out.add(s.diagSome404);
      }
    }

    if (conn.useHttps || conn.dashboardUseHttps) {
      out.add(s.diagHttpsProxy);
    }

    return out;
  }
}

extension on ProbeResult {
  /// true si la superficie respondió algo (aunque sea un error HTTP).
  bool get isOnline => switch (status) {
    ProbeStatus.refused ||
    ProbeStatus.timeout ||
    ProbeStatus.dnsError ||
    ProbeStatus.tlsError ||
    ProbeStatus.error => false,
    _ => true,
  };
}
