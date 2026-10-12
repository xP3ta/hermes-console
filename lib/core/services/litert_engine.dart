/// Cliente del motor local por GPU **OlliteRT** (app nativa aparte que corre
/// modelos `.litertlm` en la GPU/NPU del móvil vía LiteRT-LM y los sirve por un
/// endpoint OpenAI-compatible en `127.0.0.1:8000`).
///
/// Por qué directo (sin el bridge): en el escenario local TODO vive en el mismo
/// móvil — la app Hermes Console, el agente Hermes local y OlliteRT — así que la
/// app llega a OlliteRT por loopback igual que lo hace el agente. La app solo
/// LEE estado (`/health`, `/v1/models`); la descarga y el arranque de modelos los
/// gestiona OlliteRT desde su propia UI (su API remota no los expone).
///
/// Repo: https://github.com/NightMean/OlliteRT (Apache-2.0).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/transport_privacy.dart';

/// URL de descarga/instalación de OlliteRT (releases de GitHub).
///
/// OlliteRT (proyecto de terceros que empaqueta Google LiteRT-LM) NO tiene
/// release estable: a 2026-06-23 la API de GitHub solo expone pre-releases
/// (`prerelease=true`, última `v0.9.6-beta.1`) y `/releases/latest` da 404. Por
/// eso se enlaza la LISTA de releases (siempre muestra la última disponible),
/// no una versión fija. Revisar si publican una estable antes de cambiar el copy
/// «(beta)» del botón de instalación. Ver TASK-020.
const String kOlliteRtReleasesUrl =
    'https://github.com/NightMean/OlliteRT/releases';

/// Posibles package ids de OlliteRT (sabores stable/beta) para intentar
/// abrirlo por intent. Se intenta lanzar directamente (sin depender de la
/// visibilidad de paquetes de Android); si ninguno abre, se cae a la URL de
/// releases.
const List<String> kOlliteRtPackageIds = [
  'com.ollitert.llm',
  'com.ollitert.llm.beta',
];

/// Puerto por defecto del servidor OpenAI de OlliteRT.
const int kOlliteRtDefaultPort = 8000;

/// Base por defecto (loopback del propio móvil).
const String kOlliteRtDefaultBaseUrl = 'http://127.0.0.1:8000';

/// Endpoint `/v1` que se escribe en la config de Hermes para inferir por GPU.
const String kOlliteRtV1BaseUrl = 'http://127.0.0.1:8000/v1';

/// Estado de alcance de OlliteRT desde la app.
enum OlliteRtStatus {
  /// `/health` respondió: OlliteRT instalado y sirviendo.
  running,

  /// No se pudo contactar el puerto: no instalado, o servidor parado.
  unreachable,

  /// Aún no sondeado.
  unknown,
}

/// Un modelo tal y como lo reporta OlliteRT en `GET /v1/models`.
class OlliteRtServedModel {
  const OlliteRtServedModel({required this.id, this.ownedBy});

  final String id;
  final String? ownedBy;

  factory OlliteRtServedModel.fromJson(Map<String, dynamic> json) =>
      OlliteRtServedModel(
        id: (json['id'] ?? '').toString(),
        ownedBy: json['owned_by']?.toString(),
      );
}

/// Resultado de un sondeo de estado.
class OlliteRtSnapshot {
  const OlliteRtSnapshot({
    required this.status,
    this.models = const [],
    this.error,
  });

  final OlliteRtStatus status;
  final List<OlliteRtServedModel> models;
  final String? error;

  bool get isRunning => status == OlliteRtStatus.running;
}

/// Cliente HTTP ligero contra OlliteRT.
class OlliteRtClient {
  OlliteRtClient({String? baseUrl, this.token, http.Client? httpClient})
    : baseUrl = TransportPrivacy.requireAllowed(
        (baseUrl ?? kOlliteRtDefaultBaseUrl).replaceAll(RegExp(r'/+$'), ''),
      ),
      _http = httpClient ?? http.Client();

  /// Base SIN `/v1` ni barra final, p. ej. `http://127.0.0.1:8000`.
  final String baseUrl;

  /// Bearer opcional (OlliteRT puede correr sin auth en localhost).
  final String? token;

  final http.Client _http;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
  };

  /// ¿El servidor responde? Prueba `/health` y cae a `/ping`.
  Future<bool> ping({Duration timeout = const Duration(seconds: 3)}) async {
    for (final path in ['/health', '/ping']) {
      try {
        final res = await _http
            .get(Uri.parse('$baseUrl$path'), headers: _headers)
            .timeout(timeout);
        if (res.statusCode >= 200 && res.statusCode < 500) return true;
      } catch (_) {
        // siguiente intento
      }
    }
    return false;
  }

  /// Lista los modelos que OlliteRT tiene cargados/disponibles (`/v1/models`).
  Future<List<OlliteRtServedModel>> listModels({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final res = await _http
        .get(Uri.parse('$baseUrl/v1/models'), headers: _headers)
        .timeout(timeout);
    if (res.statusCode != 200) {
      throw Exception('OlliteRT /v1/models HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body);
    final data = (body is Map && body['data'] is List)
        ? body['data'] as List
        : const [];
    return data
        .whereType<Map>()
        .map((m) => OlliteRtServedModel.fromJson(Map<String, dynamic>.from(m)))
        .where((m) => m.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Sondeo de estado completo: alcance + lista de modelos si responde.
  Future<OlliteRtSnapshot> snapshot() async {
    final up = await ping();
    if (!up) {
      return const OlliteRtSnapshot(status: OlliteRtStatus.unreachable);
    }
    try {
      final models = await listModels();
      return OlliteRtSnapshot(status: OlliteRtStatus.running, models: models);
    } catch (e) {
      // Servidor arriba pero la lista falló (auth, versión…): seguimos como
      // "running" sin modelos, con la causa.
      return OlliteRtSnapshot(
        status: OlliteRtStatus.running,
        error: e.toString(),
      );
    }
  }

  void close() => _http.close();
}
