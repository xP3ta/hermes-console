// Diagnóstico de conexión por instancia: pruebas reales contra el
// Dashboard/Admin (9119), clasificación de errores con causa concreta y
// construcción de la CapabilityMatrix.
//
// Contratos verificados contra hermes-agent 0.16.0 — ver docs/API_AUDIT.md.
// Regla: nada de endpoints inventados; lo no comprobable queda `unknown`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'origin_bound_http_client.dart';

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

  /// The server may simply not offer this through this surface (plugins on
  /// the Gateway: Hermes serves them from the Dashboard).
  final bool optional;

  const ProbeResult({
    required this.name,
    required this.status,
    this.httpCode,
    this.latencyMs,
    this.detail = '',
    this.optional = false,
  });

  /// An optional capability this surface does not offer: it says what the
  /// server can do, never that the connection needs attention.
  bool get absentOptional =>
      optional &&
      (status == ProbeStatus.notFound ||
          status == ProbeStatus.methodNotAllowed);

  ProbeResult asOptional() => ProbeResult(
    name: name,
    status: status,
    httpCode: httpCode,
    latencyMs: latencyMs,
    detail: detail,
    optional: true,
  );

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

/// Informe completo de un diagnóstico.
class DiagnosticsReport {
  final List<ProbeResult> gateway;
  final List<ProbeResult> dashboard;
  final CapabilityMatrix matrix;
  final List<String> suggestions;
  final DateTime ranAt;

  const DiagnosticsReport({
    required this.gateway,
    required this.dashboard,
    required this.matrix,
    required this.suggestions,
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
    if (suggestions.isNotEmpty) {
      b.writeln('\n[${s.diagCopySuggestions}]');
      for (final s in suggestions) {
        b.writeln('  - $s');
      }
    }
    return b.toString();
  }
}

/// The two surfaces a full check visits, in order.
enum DiagnosticsStage { gateway, dashboard }

/// Called as each surface's probes finish, with exactly what they found.
typedef DiagnosticsStageCallback =
    void Function(DiagnosticsStage stage, List<ProbeResult> results);

class ConnectionDiagnostics {
  final http.Client _http;
  static const _kTimeout = Duration(seconds: 8);

  ConnectionDiagnostics({http.Client? httpClient})
    : _http = OriginBoundHttpClient(httpClient);

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

  // ── Dashboard/Admin (9119) ────────────────────────────────────────────

  Future<List<ProbeResult>> probeDashboard(
    SavedConnection conn,
    DashboardSecrets secrets,
  ) async {
    final base = TransportPrivacy.requireAllowed(conn.effectiveDashboardUrl);
    final results = <ProbeResult>[];

    // 1. Vida y versión como Desktop (electron/remote-liveness.ts:116-127):
    //    el endpoint de salud y, si falta (404), el de estado.
    String? version;
    Future<ProbeResult> life(String path) => _probe(
      'status',
      'GET',
      Uri.parse('$base$path'),
      inspectResponse: (res) {
        if (res.statusCode != 200) return;
        try {
          final v = (jsonDecode(res.body) as Map)['version'];
          if (v is String && v.isNotEmpty) version = v;
        } catch (_) {
          // A body without a version leaves it unread.
        }
      },
    );
    var status = await life('/api/health');
    if (!status.isOnline) {
      results.add(status);
      return results;
    }
    // The status endpoint only stands in when the health one is missing
    // (404), as in backend-health.ts:182-185; any other answer is the answer.
    if (status.status == ProbeStatus.notFound) {
      status = await life('/api/status');
    }
    results.add(status);
    if (!status.isOnline) return results;
    if (version != null) {
      results.add(
        ProbeResult(name: 'version', status: ProbeStatus.ok, detail: version!),
      );
    }

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
      ('sessions', '/api/sessions?limit=1'),
      ('skills', '/api/skills'),
      ('toolsets', '/api/tools/toolsets'),
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
    DiagnosticsStageCallback? onStage,
  }) async {
    // Desktop talks to one origin, the Dashboard: no Gateway request here.
    const gw = <ProbeResult>[];
    final dash = await probeDashboard(conn, secrets);
    onStage?.call(DiagnosticsStage.dashboard, dash);
    final version = dash.where((r) => r.name == 'version').firstOrNull?.detail;
    return DiagnosticsReport(
      gateway: gw,
      dashboard: dash,
      matrix: buildMatrix(gw, dash, version),
      suggestions: buildSuggestions(s, conn, gw, dash),
      ranAt: DateTime.now(),
    );
  }

  /// Deriva la matriz desde los resultados: se infiere con probes del
  /// Dashboard y lo no comprobable queda unknown.
  CapabilityMatrix buildMatrix(
    List<ProbeResult> gw,
    List<ProbeResult> dash,
    String? version,
  ) {
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
    final dashSessions = find(dash, 'sessions');
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
    final sessionsRead = fromProbe(dashSessions);
    final cronRead = fromProbe(find(dash, 'cron'));
    final modelsReadDash = fromProbe(find(dash, 'models/providers'));

    return CapabilityMatrix(
      gatewayOnline: gatewayOnline,
      // Desktop's liveness (remote-liveness.ts:116-127): alive only when the
      // probe answered OK.
      dashboardOnline: dashStatus == null
          ? CapState.unknown
          : (dashStatus.status == ProbeStatus.ok ? CapState.yes : CapState.no),
      gatewayAuthValid: gatewayAuthValid,
      dashboardAuthValid: dashboardAuthValid,
      chatSupported: CapState.unknown,
      sessionsRead: sessionsRead,
      sessionsWrite: sessionsRead,
      sessionsDelete: sessionsRead,
      // El streaming real solo se confirma con el primer chat exitoso.
      streamingSupported: CapState.unknown,
      turnIdempotency: CapState.unknown,
      kanbanTrackedCreate: CapState.unknown,
      skillsRead: _firstYes([
        fromProbe(find(dash, 'skills')),
        fromProbe(find(gw, 'skills (gateway)')),
      ]),
      skillsToggle: CapState.unknown,
      // No probe here proves install support.
      skillsInstall: CapState.unknown,
      toolsetsRead: fromProbe(find(dash, 'toolsets')),
      cronRead: cronRead,
      cronWrite: cronRead,
      memoryRead: fromProbe(find(dash, 'memory')),
      memoryWrite: CapState.no,
      modelsRead: _firstYes([modelsReadDash, fromProbe(find(gw, 'models'))]),
      modelsWrite: modelsReadDash,
      configRead: fromProbe(find(dash, 'config')),
      configWrite: CapState.no,
      logsRead: fromProbe(find(dash, 'logs')),
      pluginsSupported: fromProbe(find(gw, 'plugins')),
      gatewayVersion: version,
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
    final dashStatus = dash.isNotEmpty ? dash.first : null;

    switch (dashStatus?.status) {
      case ProbeStatus.refused || ProbeStatus.timeout:
        out.add(s.diagDashDownBoth);
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

    if (dashStatus?.status == ProbeStatus.ok) {
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
