import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show Uint8List, debugPrint, visibleForTesting;
import 'package:http/http.dart' as http;

import '../utils/transport_privacy.dart';
import 'profile_chat_mode.dart';

const String cronJobIdPattern = r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$';

/// Valida y normaliza un ID de cron antes de cualquier acceso a red.
///
/// Es la allowlist compartida por Manager, Bridge y Dashboard. El primer
/// carácter alfanumérico impide que el CLI lo interprete como una opción.
String validateCronJobId(String jobId) {
  final id = jobId.trim();
  if (!RegExp(cronJobIdPattern).hasMatch(id)) {
    throw ArgumentError.value(jobId, 'jobId');
  }
  return id;
}

String? validateCronProfile(String? profile) {
  final value = profile?.trim() ?? '';
  if (value.isEmpty || value == 'default') return null;
  if (!isValidProfileName(value)) {
    throw ArgumentError.value(profile, 'profile');
  }
  return value;
}

/// Cliente del Mobile Bridge (servicio opcional del servidor, puerto 9131).
///
/// FASE A (cliente preparado): por ahora SOLO lectura — `health` y
/// `capabilities`. Las operaciones de escritura (memory/soul/skills) NO se
/// implementan hasta que exista el servidor y se apruebe el threat model
/// (`docs/BRIDGE_SECURITY_MODEL.md`). Cuando el bridge no está configurado o no
/// responde, la app degrada a borrador local + copiar comando (sin fingir
/// sincronización).
///
/// Contrato: `docs/MOBILE_BRIDGE_SPEC.md`.

/// Categoría de fallo de una petición al bridge/dashboard/gateway. Solo para
/// diagnóstico interno: NO cambia lo que ve el usuario, pero permite distinguir
/// un 400 real de una caída de red (antes ambos se confundían con "offline").
enum BridgeErrorKind {
  /// Red: conexión rechazada, host no resoluble, socket caído.
  network,

  /// Timeout: el servidor no respondió a tiempo.
  timeout,

  /// 400 (y otros 4xx no específicos): petición mal formada / rechazada.
  badRequest,

  /// 401 / 403: falta auth o el token/credencial no tiene permiso.
  auth,

  /// 404: endpoint inexistente en esta versión del bridge.
  notFound,

  /// 5xx: error del servidor.
  server,

  /// Sin clasificar.
  unknown,
}

/// Clasifica un status HTTP en una [BridgeErrorKind].
BridgeErrorKind bridgeErrorKindForStatus(int status) {
  if (status == 401 || status == 403) return BridgeErrorKind.auth;
  if (status == 404) return BridgeErrorKind.notFound;
  if (status >= 500) return BridgeErrorKind.server;
  if (status >= 400) return BridgeErrorKind.badRequest;
  return BridgeErrorKind.unknown;
}

/// Error del bridge (código + mensaje legible del servidor).
///
/// [kind]/[status]/[diagnostic] son aditivos (TASK-016): clasifican el fallo y
/// llevan un resumen SANITIZADO para logs. El [message] mostrado al usuario no
/// cambia. [diagnostic] nunca contiene secretos (Authorization/token/password).
class BridgeException implements Exception {
  final String code;
  final String message;
  final BridgeErrorKind kind;
  final int? status;
  final String? diagnostic;
  const BridgeException(
    this.code,
    this.message, {
    this.kind = BridgeErrorKind.unknown,
    this.status,
    this.diagnostic,
  });
  @override
  String toString() => message;
}

/// Capacidades declaradas por el bridge en `GET /bridge/capabilities`.
class BridgeCapabilities {
  final bool online;
  final bool authValid;
  final bool readOnly;
  final List<String> scopes;

  // Operaciones declaradas (false si no soportada/sin scope).
  final bool fileRead;
  final bool memoryWrite;
  final bool soulWrite;
  final bool cronWrite;
  final bool cronDelete;
  final bool selfUpdate;
  final bool skillsInstall;
  final bool skillsRemove;
  final bool logsExtended;
  final bool auditRead;

  /// Destino lógico -> escribible con los scopes actuales (de `targets`).
  final Map<String, bool> writableTargets;

  final String? version;

  const BridgeCapabilities({
    this.online = false,
    this.authValid = false,
    this.readOnly = false,
    this.scopes = const [],
    this.fileRead = false,
    this.memoryWrite = false,
    this.soulWrite = false,
    this.cronWrite = false,
    this.cronDelete = false,
    this.selfUpdate = false,
    this.skillsInstall = false,
    this.skillsRemove = false,
    this.logsExtended = false,
    this.auditRead = false,
    this.writableTargets = const {},
    this.version,
  });

  /// ¿Se puede escribir [target] (memory/user/soul/persona/cron…)?
  bool canWriteTarget(String target) => writableTargets[target] ?? false;

  /// Bridge no configurado / inalcanzable: todo en false.
  static const offline = BridgeCapabilities();

  bool get anyWrite =>
      memoryWrite || soulWrite || selfUpdate || skillsInstall || skillsRemove;

  factory BridgeCapabilities.fromJson(
    Map<String, dynamic> json, {
    bool authValid = true,
  }) {
    final ops = (json['operations'] as Map?)?.cast<String, dynamic>() ?? {};
    bool op(String k) => ops[k] == true;
    final targets = (json['targets'] as Map?)?.cast<String, dynamic>() ?? {};
    final writable = <String, bool>{
      for (final e in targets.entries)
        e.key: (e.value is Map) && ((e.value as Map)['writable'] == true),
    };
    return BridgeCapabilities(
      online: true,
      authValid: authValid,
      readOnly: json['read_only'] == true,
      scopes: ((json['scopes'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      fileRead: op('file_read'),
      memoryWrite: op('memory_write'),
      soulWrite: op('soul_write'),
      cronWrite: op('cron_write'),
      cronDelete: op('cron_delete'),
      selfUpdate: op('self_update'),
      skillsInstall: op('skills_install'),
      skillsRemove: op('skills_remove'),
      logsExtended: op('logs_extended'),
      auditRead: op('audit_read') || op('logs_extended'),
      writableTargets: writable,
      version: json['version']?.toString(),
    );
  }
}

/// Por qué el bridge responde o no, clasificado a partir del error real de red.
/// Permite a la UI explicar la causa concreta en vez de "no disponible".
enum BridgeReach {
  /// Responde 200 con status ok.
  ok,

  /// Hay host pero nada escucha en el puerto (no iniciado / puerto distinto).
  refused,

  /// No respondió a tiempo.
  timeout,

  /// No se pudo resolver/alcanzar el host.
  dns,

  /// Falló el handshake TLS.
  tls,

  /// Respondió, pero con un código HTTP distinto de 200.
  httpError,

  /// Respondió 200 pero el cuerpo no es el esperado.
  badResponse,
}

/// Resultado detallado de sondear `/bridge/health`.
class BridgeHealth {
  final BridgeReach reach;
  final int? httpStatus;

  /// Texto legible con la causa concreta (para la UI de diagnóstico).
  final String detail;

  const BridgeHealth(this.reach, {this.httpStatus, this.detail = ''});

  bool get ok => reach == BridgeReach.ok;
}

class BridgeClient {
  static const Duration _standardTimeout = Duration(seconds: 20);
  final String baseUrl;
  final String token;
  final http.Client _http;

  BridgeClient({
    required String baseUrl,
    required this.token,
    http.Client? httpClient,
  }) : baseUrl = TransportPrivacy.requireAllowed(
         baseUrl.endsWith('/')
             ? baseUrl.substring(0, baseUrl.length - 1)
             : baseUrl,
       ),
       _http = httpClient ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  /// Sube un adjunto al almacén confinado del Mobile Bridge mediante un body
  /// binario en streaming. No crea una copia base64 ni carga el archivo entero
  /// en memoria. Devuelve la ruta gestionada que puede leer el agente local.
  Future<String> uploadAttachment(
    File file, {
    required String filename,
    String mimeType = 'application/octet-stream',
    Duration timeout = const Duration(seconds: 45),
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final length = await file.length();
    if (length <= 0 || length > maxBytes) {
      throw const BridgeException(
        'attachment_too_large',
        'The attachment is empty or exceeds the allowed limit.',
      );
    }
    final safeName = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safeName.isEmpty || safeName.contains('..')) {
      throw ArgumentError('invalid attachment name');
    }

    final request = http.StreamedRequest(
      'POST',
      Uri.parse('$baseUrl/bridge/attachments'),
    );
    request.headers.addAll({
      'Authorization': 'Bearer $token',
      'Content-Type': mimeType.isEmpty ? 'application/octet-stream' : mimeType,
      'X-Hermes-Filename': safeName,
    });
    request.contentLength = length;

    final sendFuture = _http.send(request).timeout(timeout);
    try {
      await request.sink.addStream(file.openRead());
      await request.sink.close();
      final streamed = await sendFuture;
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(timeout);
      final data = _decode(response);
      final path = (data['path'] ?? '').toString();
      if (!path.startsWith('/')) {
        throw const BridgeException(
          'attachment_invalid_path',
          'The bridge did not return a valid attachment path.',
        );
      }
      return path;
    } catch (_) {
      try {
        await request.sink.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// Actualiza el propio Bridge mediante su endpoint allowlisted. El servidor
  /// vuelve a verificar hash, versión y sintaxis antes de sustituir el script.
  Future<Map<String, dynamic>> selfUpdate({
    required String source,
    required String version,
    required String sha256,
  }) async {
    final bytes = utf8.encode(source);
    if (bytes.isEmpty || bytes.length > 512 * 1024) {
      throw const BridgeException(
        'self_update_size',
        'The Mobile Bridge release exceeds the allowed limit.',
      );
    }
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const BridgeException(
        'self_update_metadata',
        'The Mobile Bridge release metadata is not valid.',
      );
    }
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/self-update'),
          headers: _headers,
          body: jsonEncode({
            'version': version,
            'sha256': sha256,
            'source_b64': base64.encode(bytes),
          }),
        )
        .timeout(const Duration(seconds: 30));
    return _decode(res);
  }

  /// GET /bridge/health (sin auth). true si responde 200 status ok.
  /// Wrapper sobre [healthDiagnose] para los llamadores que solo quieren un sí/no.
  Future<bool> health() async => (await healthDiagnose()).ok;

  /// GET /bridge/health clasificando POR QUÉ no responde, para que la UI muestre
  /// la causa real (conexión rechazada, host no resuelto, timeout, TLS, HTTP)
  /// en vez de un genérico "no disponible". Nunca lanza.
  Future<BridgeHealth> healthDiagnose() async {
    try {
      final res = await _http
          .get(Uri.parse('$baseUrl/bridge/health'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        return BridgeHealth(
          BridgeReach.httpError,
          httpStatus: res.statusCode,
          detail: 'The bridge responded HTTP ${res.statusCode}.',
        );
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if ((data['status'] ?? '') == 'ok') {
        return const BridgeHealth(BridgeReach.ok);
      }
      return const BridgeHealth(
        BridgeReach.badResponse,
        detail: 'Respuesta inesperada de /bridge/health (sin status: ok).',
      );
    } on TimeoutException {
      return const BridgeHealth(
        BridgeReach.timeout,
        detail:
            'The bridge did not respond in time (timeout). '
            'Is it started and reachable on this network?',
      );
    } on SocketException catch (e) {
      // osError.errorCode 111 = connection refused; fallo de DNS no trae osError.
      final refused =
          e.osError?.errorCode == 111 ||
          e.message.toLowerCase().contains('refused');
      if (refused) {
        return const BridgeHealth(
          BridgeReach.refused,
          detail:
              'Connection refused: the host is there but nothing is listening on that '
              'port. The bridge is not started, or the port is different.',
        );
      }
      return BridgeHealth(
        BridgeReach.dns,
        detail: 'Could not resolve/reach the host: ${e.message}.',
      );
    } on HandshakeException catch (e) {
      return BridgeHealth(
        BridgeReach.tls,
        detail: 'TLS error connecting to the bridge: ${e.message}.',
      );
    } catch (e) {
      return BridgeHealth(
        BridgeReach.badResponse,
        detail: 'Fallo al sondear el bridge: $e.',
      );
    }
  }

  /// Detecta el bridge y sus capacidades. Nunca lanza: devuelve
  /// [BridgeCapabilities.offline] si no está disponible/autorizado.
  Future<BridgeCapabilities> detect() async {
    if (!await health()) return BridgeCapabilities.offline;
    try {
      final res = await _http
          .get(Uri.parse('$baseUrl/bridge/capabilities'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 401 || res.statusCode == 403) {
        // Online pero token inválido/sin scope.
        return const BridgeCapabilities(online: true, authValid: false);
      }
      if (res.statusCode != 200) {
        // Sigue degradando a "offline" hacia el usuario (sin cambio de
        // producto), pero deja en el log la causa real: un 400/500 NO es lo
        // mismo que el bridge caído (TASK-016).
        _emit(
          _diagnostic(
            kind: bridgeErrorKindForStatus(res.statusCode),
            status: res.statusCode,
            method: res.request?.method,
            url: res.request?.url.toString(),
            body: res.body,
          ),
        );
        return BridgeCapabilities.offline;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return BridgeCapabilities.fromJson(data);
    } catch (e) {
      debugPrint(
        '[bridge] excepción silenciada (se continúa sin propagar): $e',
      );
      return BridgeCapabilities.offline;
    }
  }

  /// POST /bridge/provision con la API key del **gateway** (no el token del
  /// bridge). Si el servidor lo permite, devuelve el token del bridge para
  /// configurarlo automáticamente.
  ///
  /// Los instaladores oficiales modernos usan deliberadamente la misma clave
  /// fuerte para Gateway y Bridge. Si el administrador ha cerrado el endpoint
  /// de provisión, comprobamos esa misma clave contra capabilities y la
  /// reutilizamos únicamente cuando el Bridge confirma que está autenticada.
  /// Así las rutas antiguas de la app no pierden acceso ni self-update después
  /// de un setup verificado. Devuelve null si ninguna de las dos vías autentica.
  static Future<String?> provision(
    String baseUrl,
    String gatewayKey, {
    http.Client? httpClient,
  }) async {
    late final String base;
    try {
      base = TransportPrivacy.requireAllowed(
        baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
      );
    } on ArgumentError {
      return null;
    }
    final client = httpClient ?? http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('$base/bridge/provision'),
            headers: {
              'Authorization': 'Bearer $gatewayKey',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final tok = data['token']?.toString().trim();
        if (tok != null && tok.isNotEmpty) return tok;
      }

      if (gatewayKey.trim().isEmpty) return null;
      final caps = await client
          .get(
            Uri.parse('$base/bridge/capabilities'),
            headers: {
              'Authorization': 'Bearer $gatewayKey',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (caps.statusCode != 200) return null;
      final data = jsonDecode(caps.body) as Map<String, dynamic>;
      final scopes = data['scopes'];
      final operations = data['operations'];
      final version = data['version']?.toString().trim() ?? '';
      final isBridge = data['object'] == 'hermes.bridge.capabilities';
      if (!isBridge ||
          scopes is! List ||
          operations is! Map ||
          version.isEmpty) {
        return null;
      }
      return gatewayKey.trim();
    } catch (e) {
      debugPrint('[bridge] excepción silenciada (se devuelve null): $e');
      return null;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// GET /bridge/health (sin auth) → versión del bridge EN EJECUCIÓN. Devuelve
  /// null si no responde o no informa versión. Se usa para detectar un bridge
  /// viejo (de una instalación anterior) que sigue vivo sirviendo código antiguo
  /// y compararlo con [AgentRuntimeConsts.expectedBridgeVersion].
  static Future<String?> probeVersion(
    String baseUrl, {
    http.Client? httpClient,
  }) async {
    late final String base;
    try {
      base = TransportPrivacy.requireAllowed(
        baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
      );
    } on ArgumentError {
      return null;
    }
    final client = httpClient ?? http.Client();
    try {
      final res = await client
          .get(Uri.parse('$base/bridge/health'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final v = data['version']?.toString();
      return (v != null && v.isNotEmpty) ? v : null;
    } catch (e) {
      debugPrint('[bridge] excepción silenciada (se devuelve null): $e');
      return null;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// GET /bridge/read/{target}. Lee el contenido actual de un destino
  /// allowlisted (`soul`/`persona`/`memory`). Solo lectura: no modifica nada.
  /// Devuelve {ok, exists, content, path, size}.
  Future<Map<String, dynamic>> read(String target) async {
    final res = await _http
        .get(Uri.parse('$baseUrl/bridge/read/$target'), headers: _headers)
        .timeout(_standardTimeout);
    return _decode(res);
  }

  /// POST /bridge/{soul|memory}/write. [file] es un destino allowlisted
  /// (`soul`/`persona`/`memory`). Con [dryRun] devuelve el diff sin escribir.
  /// Devuelve el cuerpo JSON ({ok, diff, backup_id, path}).
  Future<Map<String, dynamic>> write({
    required String file,
    required String content,
    bool dryRun = false,
  }) async {
    final endpoint = file == 'soul' ? 'soul' : 'memory';
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/$endpoint/write'),
          headers: _headers,
          body: jsonEncode({
            'file': file,
            'content': content,
            'dry_run': dryRun,
          }),
        )
        .timeout(_standardTimeout);
    return _decode(res);
  }

  /// Elimina un cron mediante el comando oficial ejecutado por el Mobile
  /// Bridge. Evita depender de las credenciales de login del Dashboard.
  Future<void> deleteCronJob(String jobId, {String? profile}) async {
    final id = validateCronJobId(jobId);
    final scopedProfile = validateCronProfile(profile);
    final endpoint = Uri.parse(
      '$baseUrl/bridge/cron/jobs/${Uri.encodeComponent(id)}',
    );
    final uri = scopedProfile == null
        ? endpoint
        : endpoint.replace(queryParameters: {'profile': scopedProfile});
    final res = await _http
        .delete(uri, headers: _headers)
        .timeout(_standardTimeout);
    final data = _decode(res);
    if (data['ok'] != true) {
      throw const BridgeException(
        'cron_remove_unconfirmed',
        'The bridge did not confirm the cron deletion.',
      );
    }
  }

  /// POST /bridge/skills/install. [source] debe pasar [isValidSkillSource].
  Future<Map<String, dynamic>> installSkill(
    String source, {
    bool dryRun = false,
  }) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/skills/install'),
          headers: _headers,
          body: jsonEncode({'source': source, 'dry_run': dryRun}),
        )
        .timeout(_standardTimeout);
    return _decode(res);
  }

  /// POST /bridge/chat — ejecuta un turno del agente local (oneshot
  /// `hermes -z`) y devuelve la respuesta final. Es el camino de chat para la
  /// instancia LOCAL (que no expone la API HTTP `/v1/runs`). El agente puede
  /// tardar (carga modelo + tools), de ahí el timeout amplio.
  Future<String> chat(
    String prompt, {
    List<Map<String, dynamic>> history = const [],
    List<String> attachmentPaths = const [],
    Duration timeout = const Duration(minutes: 5),
    String profile = '',
  }) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/chat'),
          headers: _headers,
          // `profile` solo se incluye si NO está vacío: con vacío el body es
          // byte-idéntico al actual (perfil default → sin aislamiento, sin cambio).
          // Un bridge antiguo ignora el campo extra y se comporta como hoy.
          body: jsonEncode({
            'prompt': prompt,
            'history': history,
            if (attachmentPaths.isNotEmpty) 'attachments': attachmentPaths,
            if (profile.isNotEmpty) 'profile': profile,
          }),
        )
        .timeout(timeout);
    final data = _decode(res);
    return (data['response'] ?? '').toString();
  }

  /// POST /bridge/chat con mode=simple — POST directo al modelo local SIN tools,
  /// SIN agente. Resuelve el bucle de tool-calling que deja vacío a los modelos
  /// pequeños (OlliteRT/Ollama). Solo para instancias locales.
  Future<String> chatSimple(
    String prompt, {
    List<Map<String, dynamic>> history = const [],
    int maxTokens = 1024,
    Duration timeout = const Duration(minutes: 3),
    String profile = '',
  }) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/chat'),
          headers: _headers,
          body: jsonEncode({
            'prompt': prompt,
            'history': history,
            'mode': 'simple',
            'max_tokens': maxTokens,
            if (profile.isNotEmpty) 'profile': profile,
          }),
        )
        .timeout(timeout);
    final data = _decode(res);
    return (data['response'] ?? '').toString();
  }

  /// POST /bridge/chat/stream — igual que [chat] pero TRANSMITE la respuesta por
  /// SSE: emite cada fragmento de texto según el agente local lo va generando (el
  /// bridge corre `hermes -z` bajo un PTY). Permite hablar/pintar frase a frase
  /// sin esperar a la respuesta entera. Si el bridge desplegado es viejo (sin este
  /// endpoint) responde 404 y este método lanza [BridgeException] ANTES de emitir
  /// nada → el llamador cae al [chat] clásico.
  Stream<String> chatStream(
    String prompt, {
    List<Map<String, dynamic>> history = const [],
    List<String> attachmentPaths = const [],
    Duration timeout = const Duration(minutes: 5),
    String profile = '',
  }) async* {
    final req = http.Request('POST', Uri.parse('$baseUrl/bridge/chat/stream'));
    req.headers.addAll(_headers);
    req.body = jsonEncode({
      'prompt': prompt,
      'history': history,
      if (attachmentPaths.isNotEmpty) 'attachments': attachmentPaths,
      if (profile.isNotEmpty) 'profile': profile,
    });
    final res = await _http.send(req).timeout(timeout);
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      final kind = bridgeErrorKindForStatus(res.statusCode);
      var code = 'http_${res.statusCode}';
      var msg = body.isNotEmpty ? body : 'HTTP ${res.statusCode}';
      try {
        final j = jsonDecode(body);
        if (j is Map && j['error'] is Map) {
          code = (j['error']['code'] ?? code).toString();
          msg = (j['error']['message'] ?? msg).toString();
        }
      } catch (e) {
        debugPrint('[bridge] excepción silenciada (se ignora sin más): $e');
      }
      final diag = _diagnostic(
        kind: kind,
        status: res.statusCode,
        method: 'POST',
        url: '$baseUrl/bridge/chat/stream',
        body: body,
      );
      _emit(diag);
      throw BridgeException(
        code,
        msg,
        kind: kind,
        status: res.statusCode,
        diagnostic: diag,
      );
    }
    final lines = res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      Map<String, dynamic> obj;
      try {
        obj = jsonDecode(payload) as Map<String, dynamic>;
      } catch (e) {
        debugPrint(
          '[bridge] excepción silenciada (se omite este elemento): $e',
        );
        continue; // línea SSE no-JSON: ignorar
      }
      final err = obj['error'];
      if (err != null) {
        throw BridgeException('chat_stream_failed', err.toString());
      }
      final delta = obj['delta'];
      if (delta is String && delta.isNotEmpty) yield delta;
      if (obj['done'] == true) break;
    }
  }

  /// POST /bridge/skills/remove {name}. [name] valida `^[A-Za-z0-9_.-]+$`.
  Future<Map<String, dynamic>> removeSkill(
    String name, {
    bool dryRun = false,
  }) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/skills/remove'),
          headers: _headers,
          body: jsonEncode({'name': name, 'dry_run': dryRun}),
        )
        .timeout(_standardTimeout);
    return _decode(res);
  }

  /// POST /bridge/model/set → fija el modelo PRINCIPAL escribiendo config.yaml
  /// (vía del agente local: el Dashboard `/api/model/set` no corre on-device).
  /// Para ollama/custom pasa [modelBaseUrl] (`http://127.0.0.1:11434/v1`) y, si
  /// se conoce, un [contextLength] >= 64000. Requiere scope `config`.
  Future<Map<String, dynamic>> setModel({
    required String provider,
    required String model,
    String modelBaseUrl = '',
    int contextLength = 0,
  }) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/model/set'),
          headers: _headers,
          body: jsonEncode({
            'provider': provider,
            'model': model,
            if (modelBaseUrl.isNotEmpty) 'base_url': modelBaseUrl,
            if (contextLength > 0) 'context_length': contextLength,
          }),
        )
        .timeout(_standardTimeout);
    return _decode(res);
  }

  /// Basename válido para /bridge/image: sin separadores ni `..`, charset
  /// estricto y extensión de imagen permitida. Espejo del guard del servidor
  /// (docs/UPSTREAM_CONTRACT.md): el cliente nunca manda
  /// rutas con directorios.
  static final RegExp _imageNameRe = RegExp(
    r'^[A-Za-z0-9._-]+\.(?:png|jpe?g|webp)$',
    caseSensitive: false,
  );

  /// GET `/bridge/image?name=<basename>` → bytes de una imagen generada por el
  /// agente (spec 030). Solo lectura (scope read); el servidor confina al
  /// directorio de imágenes generadas. Lanza [BridgeException] en no-2xx y
  /// [ArgumentError] si el basename no pasa el guard local.
  Future<Uint8List> fetchGeneratedImage(
    String basename, {
    Duration timeout = const Duration(seconds: 20),
    int maxBytes = 20 * 1024 * 1024,
  }) async {
    final name = basename.trim();
    if (name.contains('/') ||
        name.contains('\\') ||
        name.contains('..') ||
        !_imageNameRe.hasMatch(name)) {
      throw ArgumentError('invalid image name');
    }
    final request = http.Request(
      'GET',
      Uri.parse('$baseUrl/bridge/image?name=${Uri.encodeQueryComponent(name)}'),
    )..headers['Authorization'] = 'Bearer $token';
    final res = await _http.send(request).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BridgeException(
        'image_fetch_failed',
        'HTTP ${res.statusCode}',
        kind: bridgeErrorKindForStatus(res.statusCode),
        status: res.statusCode,
      );
    }
    final contentType = (res.headers['content-type'] ?? '').toLowerCase();
    if (!contentType.startsWith('image/')) {
      throw const BridgeException(
        'image_invalid_type',
        'The server did not return an image.',
      );
    }
    final declared = int.tryParse(res.headers['content-length'] ?? '');
    if (declared != null && declared > maxBytes) {
      throw const BridgeException(
        'image_too_large',
        'The image exceeds the allowed limit.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(timeout)) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const BridgeException(
          'image_too_large',
          'The image exceeds the allowed limit.',
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  /// GET /bridge/dashboard/credentials → {username, password_set, public_url}.
  /// Lee la config de login del Dashboard SIN exponer secretos. Scope: read.
  Future<Map<String, dynamic>> getDashboardCredentials() async {
    final res = await _http
        .get(
          Uri.parse('$baseUrl/bridge/dashboard/credentials'),
          headers: _headers,
        )
        .timeout(_standardTimeout);
    return _decode(res);
  }

  /// POST /bridge/dashboard/credentials {username?, password} → fija la
  /// contraseña del Dashboard (hash scrypt en el servidor) y lo reinicia.
  /// Devuelve {ok, username, restarted}. Scope: config.
  Future<Map<String, dynamic>> setDashboardCredentials({
    String? username,
    required String password,
  }) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/dashboard/credentials'),
          headers: _headers,
          body: jsonEncode({
            if (username != null && username.trim().isNotEmpty)
              'username': username.trim(),
            'password': password,
          }),
        )
        .timeout(_standardTimeout);
    return _decode(res);
  }

  /// GET /bridge/diag/local → diagnóstico de extremo a extremo del agente local
  /// ejecutado EN el dispositivo: versión del bridge, modelo en config.yaml,
  /// estado de ollama y sondas de carga cronometradas (64K vs 4K). Devuelve un
  /// `summary` legible y los datos crudos. Requiere scope `read`.
  Future<Map<String, dynamic>> localDiag() async {
    final res = await _http
        .get(Uri.parse('$baseUrl/bridge/diag/local'), headers: _headers)
        .timeout(const Duration(minutes: 2));
    return _decode(res);
  }

  /// GET /bridge/diag/llamacpp → benchmark on-device de llama.cpp con GPU
  /// (Vulkan) vs CPU para decidir si migrar el motor local desde Ollama.
  /// Puede tardar varios minutos (instala llama.cpp si falta + dos cargas del
  /// modelo), por eso el timeout es generoso. Devuelve {ok, installed,
  /// has_vulkan, gpu, cpu, summary, raw}.
  Future<Map<String, dynamic>> llamacppBench() async {
    final res = await _http
        .get(Uri.parse('$baseUrl/bridge/diag/llamacpp'), headers: _headers)
        .timeout(const Duration(minutes: 6));
    return _decode(res);
  }

  /// GET /bridge/diag/gpu → sonda de ALCANCE de la GPU desde Termux: ¿enumera
  /// OpenCL (clinfo) o Vulkan (vulkaninfo) algún dispositivo? Decide si CUALQUIER
  /// motor por GPU es viable en este móvil. Instala clinfo/vulkan-tools → tarda.
  /// Devuelve {ok, opencl, vulkan, libs, summary, raw}.
  Future<Map<String, dynamic>> gpuProbe() async {
    final res = await _http
        .get(Uri.parse('$baseUrl/bridge/diag/gpu'), headers: _headers)
        .timeout(const Duration(minutes: 6));
    return _decode(res);
  }

  /// GET /bridge/model/get → modelo activo real de config.yaml (rápido, sin
  /// sondear Ollama). La pantalla lo lee al abrir para restaurar el badge «en
  /// uso», que antes solo vivía en memoria y se perdía al recrear la pantalla.
  /// Devuelve {ok, provider, model, base_url}.
  Future<Map<String, dynamic>> getActiveModel() async {
    final res = await _http
        .get(Uri.parse('$baseUrl/bridge/model/get'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    return _decode(res);
  }

  /// GET /bridge/model/options → catálogo COMPLETO de proveedores/modelos, con
  /// la MISMA forma que el Dashboard `/api/model/options` ({providers, model,
  /// provider}). Lo construye el bridge con la función oficial de Hermes, así la
  /// app puede listar y elegir cualquier modelo configurado usando solo el token
  /// del bridge —sin el login del Dashboard—. Requiere scope `read`.
  Future<Map<String, dynamic>> modelOptions() async {
    // 95s: el bridge se da hasta 90s para construir el catálogo la primera
    // vez (intérprete frío importando hermes_cli). Con 30s la app cortaba
    // antes que el servidor, caía a los fallbacks y el usuario tenía que
    // reintentar hasta que el caché del servidor entraba en calor (spec 028).
    final res = await _http
        .get(Uri.parse('$baseUrl/bridge/model/options'), headers: _headers)
        .timeout(const Duration(seconds: 95));
    return _decode(res);
  }

  /// GET /bridge/models/fallback → lista [{provider, model}] del fallback.
  Future<List<Map<String, String>>> getFallback() async {
    final res = await _http
        .get(Uri.parse('$baseUrl/bridge/models/fallback'), headers: _headers)
        .timeout(_standardTimeout);
    final data = _decode(res);
    return ((data['fallback_providers'] as List?) ?? const [])
        .map(
          (e) => {
            'provider': (e['provider'] ?? '').toString(),
            'model': (e['model'] ?? '').toString(),
          },
        )
        .toList();
  }

  /// POST /bridge/models/fallback → fija la cadena de fallback (con backup).
  Future<void> setFallback(List<Map<String, String>> providers) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/models/fallback'),
          headers: _headers,
          body: jsonEncode({'providers': providers}),
        )
        .timeout(_standardTimeout);
    _decode(res);
  }

  /// GET /bridge/skills/find?q=. Busca en skills.sh proxyando el CLI del
  /// servidor. Devuelve [{source, name, installs, url}].
  Future<List<Map<String, dynamic>>> findSkills(String query) async {
    final res = await _http
        .get(
          Uri.parse(
            '$baseUrl/bridge/skills/find?q=${Uri.encodeQueryComponent(query)}',
          ),
          headers: _headers,
        )
        .timeout(_standardTimeout);
    final data = _decode(res);
    return ((data['results'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  /// POST /bridge/skills/enabled {name, enabled}. Activa/desactiva una skill
  /// editando `skills.disabled` en config.yaml (sin tocar el resto).
  Future<Map<String, dynamic>> setSkillEnabled(
    String name,
    bool enabled,
  ) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/skills/enabled'),
          headers: _headers,
          body: jsonEncode({'name': name, 'enabled': enabled}),
        )
        .timeout(_standardTimeout);
    return _decode(res);
  }

  /// Validación de nombre de skill para remove (sin inyección).
  static final _skillNameRe = RegExp(r'^[A-Za-z0-9_.-]+$');
  static bool isValidSkillName(String name) {
    final s = name.trim();
    return s.isNotEmpty && s.length <= 200 && _skillNameRe.hasMatch(s);
  }

  /// POST /bridge/rollback {backup_id}.
  Future<Map<String, dynamic>> rollback(String backupId) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/bridge/rollback'),
          headers: _headers,
          body: jsonEncode({'backup_id': backupId}),
        )
        .timeout(_standardTimeout);
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    final status = res.statusCode;
    if (status < 200 || status >= 300) {
      final kind = bridgeErrorKindForStatus(status);
      final diag = _diagnostic(
        kind: kind,
        status: status,
        method: res.request?.method,
        url: res.request?.url.toString(),
        body: res.body,
      );
      _emit(diag);
      // Intenta extraer el error JSON del servidor; si no es JSON (p.ej. 404
      // devuelve HTML), genera un mensaje legible en vez de un FormatException.
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        throw BridgeException(
          (data['error'] ?? 'http_$status').toString(),
          (data['message'] ?? 'HTTP $status').toString(),
          kind: kind,
          status: status,
          diagnostic: diag,
        );
      } on BridgeException {
        rethrow;
      } catch (e) {
        debugPrint(
          '[bridge] excepción silenciada (se agrega una pista al mensaje de error): $e',
        );
        final hint = status == 404
            ? ' — endpoint no disponible en esta versión del bridge'
            : '';
        throw BridgeException(
          'http_$status',
          'HTTP $status$hint',
          kind: kind,
          status: status,
          diagnostic: diag,
        );
      }
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // --- Diagnóstico de errores HTTP (TASK-016) -------------------------------
  // Objetivo: que un 400/401/403/500 deje evidencia legible de la causa real,
  // sin filtrar secretos y sin cambiar lo que ve el usuario.

  /// Sumidero del diagnóstico. Por defecto va a `debugPrint` (aparece en
  /// `adb logcat`/`flutter logs` como `I/flutter … [bridge] …`, igual que el
  /// resto de diagnósticos del repo). Los tests pueden interceptarlo para
  /// verificar que el mensaje NO contiene secretos. Nunca se muestra al usuario.
  @visibleForTesting
  static void Function(String message)? debugSink;

  static void _emit(String message) {
    final sink = debugSink;
    if (sink != null) {
      sink(message);
    } else {
      debugPrint(message);
    }
  }

  /// Resumen de una línea, SANITIZADO, de un fallo HTTP. Incluye categoría,
  /// status, método+endpoint (con la URL redactada) y un trozo del body. Nunca
  /// incluye cabeceras (donde vive `Authorization: Bearer …`).
  static String _diagnostic({
    required BridgeErrorKind kind,
    required int status,
    String? method,
    String? url,
    String? body,
  }) {
    final where = url == null
        ? ''
        : ' ${method ?? 'HTTP'} ${redactUrlForLog(url)}';
    final b = (body == null || body.trim().isEmpty)
        ? ''
        : ' body=${truncateForLog(body)}';
    return '[bridge] ${kind.name} $status:$where$b';
  }

  /// Redacta una URL para logs: quita el userinfo (`user:pass@`) y enmascara
  /// cualquier query sensible (token/key/secret/password/auth/sig/cookie).
  @visibleForTesting
  static String redactUrlForLog(String url) {
    try {
      final u = Uri.parse(url);
      final qp = <String, String>{};
      u.queryParameters.forEach((k, v) {
        final lk = k.toLowerCase();
        final sensitive =
            lk.contains('token') ||
            lk.contains('key') ||
            lk.contains('secret') ||
            lk.contains('password') ||
            lk.contains('passwd') ||
            lk.contains('auth') ||
            lk.contains('sig') ||
            lk.contains('cookie');
        qp[k] = sensitive ? 'REDACTED' : v;
      });
      return u
          .replace(userInfo: '', queryParameters: qp.isEmpty ? null : qp)
          .toString();
    } catch (e) {
      debugPrint(
        '[bridge] excepción silenciada (se continúa sin propagar): $e',
      );
      return '<url>';
    }
  }

  /// Colapsa espacios y trunca a [max] caracteres (defecto 500) para no volcar
  /// bodies enormes ni multilínea en los logs.
  @visibleForTesting
  static String truncateForLog(String s, [int max = 500]) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.length <= max) return one;
    return '${one.substring(0, max)}…(+${one.length - max})';
  }

  /// Validación del identificador de skill para skills.install. La app NUNCA
  /// envía una línea de comando; envía este `source` validado. Rechaza todo lo
  /// que pueda derivar en inyección (espacios, `;`, `&`, `|`, `$`, backticks,
  /// rutas absolutas, URLs). Acepta identificadores del registro de Hermes de
  /// 2–5 segmentos (p.ej. `owner/repo`, `official/email/agentmail`,
  /// `skills-sh/owner/repo/skill`), opcionalmente con `@skill`. Debe coincidir
  /// con el `SKILL_RE` REAL del servidor (hermes_bridge.py:
  /// `^[\w.-]+(/[\w.-]+){1,4}(@[\w.-]+)?$`), verificado en vivo: el catálogo
  /// oficial de skills.sh usa rutas multi-segmento (`categoría/sub/nombre`).
  static final _skillSourceRe = RegExp(
    r'^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+){1,4}(@[A-Za-z0-9_.-]+)?$',
  );

  static bool isValidSkillSource(String source) {
    final s = source.trim();
    if (s.isEmpty || s.length > 200) return false;
    return _skillSourceRe.hasMatch(s);
  }

  void close() => _http.close();
}
