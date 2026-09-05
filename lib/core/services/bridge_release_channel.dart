import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'bridge_version.dart';

class BridgeReleaseTarget {
  final String version;
  final String sha256;
  final int size;
  final int minAppBuild;
  final bool remote;

  const BridgeReleaseTarget({
    required this.version,
    required this.sha256,
    required this.size,
    required this.minAppBuild,
    required this.remote,
  });
}

class BridgeRelease {
  final String version;
  final String source;
  final String sha256;
  final int size;
  final int minAppBuild;
  final bool remote;

  const BridgeRelease({
    required this.version,
    required this.source,
    required this.sha256,
    this.size = 0,
    this.minAppBuild = 0,
    required this.remote,
  });

  BridgeReleaseTarget get target => BridgeReleaseTarget(
    version: version,
    sha256: sha256,
    size: size,
    minAppBuild: minAppBuild,
    remote: remote,
  );
}

typedef BridgeSourceLoader = Future<String> Function();
typedef AppBuildLoader = Future<int> Function();
typedef BridgeReleaseTargetResolver = Future<BridgeReleaseTarget> Function();
typedef BridgeReleaseDownloader =
    Future<BridgeRelease> Function(BridgeReleaseTarget target);

/// Resuelve la release instalable del Mobile Bridge.
///
/// El asset de la app es siempre el fallback. La comprobación remota descarga
/// únicamente metadata; el payload se obtiene después y para un target fijo. El
/// manifiesto no puede aportar una URL: manifest y payload viven en ubicaciones
/// HTTPS compiladas y todo el contenido se valida antes de salir de esta clase.
class BridgeReleaseChannel {
  static final Uri manifestUri = Uri.https(
    'raw.githubusercontent.com',
    '/xP3ta/hermes-setup/main/bridge-release.json',
  );
  static final Uri payloadUri = Uri.https(
    'raw.githubusercontent.com',
    '/xP3ta/hermes-setup/main/hermes_bridge.py',
  );

  static const int maxManifestBytes = 16 * 1024;
  static const int maxPayloadBytes = 512 * 1024;
  static const Duration defaultRequestTimeout = Duration(seconds: 8);

  static final RegExp _semver = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
  );
  static final RegExp _sha256 = RegExp(r'^[a-f0-9]{64}$');
  static final RegExp _sourceVersion = RegExp(
    r'''^VERSION\s*=\s*["']((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))["']\s*(?:#.*)?$''',
    multiLine: true,
  );
  static const Set<String> _manifestKeys = {
    'schema',
    'version',
    'min_app_build',
    'sha256',
    'size',
  };

  final http.Client _http;
  final BridgeSourceLoader _loadPackagedSource;
  final AppBuildLoader _loadAppBuild;
  final Duration requestTimeout;

  BridgeReleaseChannel({
    http.Client? httpClient,
    BridgeSourceLoader? loadPackagedSource,
    AppBuildLoader? loadAppBuild,
    this.requestTimeout = defaultRequestTimeout,
  }) : _http = httpClient ?? http.Client(),
       _loadPackagedSource =
           loadPackagedSource ??
           (() => rootBundle.loadString('assets/bridge/hermes_bridge.py')),
       _loadAppBuild = loadAppBuild ?? _platformBuild;

  static Future<int> _platformBuild() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber.trim()) ?? 0;
  }

  static Future<BridgeReleaseTarget> resolveLatestTarget() async {
    final channel = BridgeReleaseChannel();
    try {
      return await channel.resolveTarget();
    } finally {
      channel.close();
    }
  }

  static Future<BridgeRelease> downloadLatestTarget(
    BridgeReleaseTarget target,
  ) async {
    final channel = BridgeReleaseChannel();
    try {
      return await channel.downloadVerified(target);
    } finally {
      channel.close();
    }
  }

  /// Conveniencia para consumidores que necesitan resolver y descargar en una
  /// sola operación. Ante un fallo remoto retorna el asset empaquetado.
  static Future<BridgeRelease> resolveLatest() async {
    final channel = BridgeReleaseChannel();
    try {
      return await channel.resolve();
    } finally {
      channel.close();
    }
  }

  Future<BridgeReleaseTarget> resolveTarget() async {
    final packaged = await _packagedRelease();
    try {
      final manifestBytes = await _readBounded(
        manifestUri,
        maxBytes: maxManifestBytes,
      );
      final manifest = _parseManifest(manifestBytes);
      final comparison = BridgeVersion.compare(
        manifest.version,
        packaged.version,
      );
      if (comparison < 0) {
        return packaged.target;
      }
      final appBuild = await _loadAppBuild();
      if (appBuild <= 0 || manifest.minAppBuild > appBuild) {
        return packaged.target;
      }
      // Una publicación idéntica sigue siendo útil: permite que el servidor
      // legacy descargue el payload fijado por HTTPS sin meter todo el script
      // en el contexto del agente. Solo conservamos el origen remoto cuando
      // coincide byte a byte con el asset empaquetado.
      if (comparison == 0 &&
          (manifest.sha256 != packaged.sha256 ||
              manifest.size != packaged.size)) {
        return packaged.target;
      }
      return manifest.target;
    } catch (_) {
      return packaged.target;
    }
  }

  /// Descarga exactamente [target]. Si era remoto, cualquier incoherencia
  /// lanza: nunca se reinstala silenciosamente el fallback tras haber ofrecido
  /// al usuario una versión remota concreta.
  Future<BridgeRelease> downloadVerified(BridgeReleaseTarget target) async {
    final packaged = await _packagedRelease();
    if (!target.remote) return packaged;
    if (target.size <= 0 || target.size > maxPayloadBytes) {
      throw const FormatException('Invalid remote Bridge size.');
    }

    final payload = await _readBounded(payloadUri, maxBytes: maxPayloadBytes);
    if (payload.length != target.size) {
      throw const FormatException('Remote Bridge size does not match.');
    }
    final actualHash = sha256.convert(payload).toString();
    if (actualHash != target.sha256) {
      throw const FormatException('SHA-256 remoto del Bridge no coincide.');
    }
    final source = utf8.decode(payload, allowMalformed: false);
    if (_extractVersion(source) != target.version) {
      throw const FormatException('VERSION remota del Bridge no coincide.');
    }
    return BridgeRelease(
      version: target.version,
      source: source,
      sha256: actualHash,
      size: payload.length,
      minAppBuild: target.minAppBuild,
      remote: true,
    );
  }

  Future<BridgeRelease> resolve() async {
    final target = await resolveTarget();
    try {
      return await downloadVerified(target);
    } catch (_) {
      return _packagedRelease();
    }
  }

  Future<Uint8List> _readBounded(Uri uri, {required int maxBytes}) {
    return _readBoundedInner(uri, maxBytes: maxBytes).timeout(requestTimeout);
  }

  Future<Uint8List> _readBoundedInner(Uri uri, {required int maxBytes}) async {
    if (uri.scheme != 'https' ||
        uri.host != 'raw.githubusercontent.com' ||
        (uri != manifestUri && uri != payloadUri)) {
      throw const FormatException('Origen de release no permitido.');
    }
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await _http.send(request);
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', uri);
    }
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > maxBytes) {
      throw const FormatException('Respuesta de release demasiado grande.');
    }

    final output = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.stream) {
      length += chunk.length;
      if (length > maxBytes) {
        throw const FormatException('Respuesta de release demasiado grande.');
      }
      output.add(chunk);
    }
    return output.takeBytes();
  }

  _BridgeReleaseManifest _parseManifest(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.toSet().length != _manifestKeys.length ||
        !decoded.keys.toSet().containsAll(_manifestKeys)) {
      throw const FormatException('Invalid Bridge manifest.');
    }

    final schema = decoded['schema'];
    final version = decoded['version'];
    final minAppBuild = decoded['min_app_build'];
    final hash = decoded['sha256'];
    final size = decoded['size'];
    if (schema != 1 ||
        version is! String ||
        !_semver.hasMatch(version) ||
        minAppBuild is! int ||
        minAppBuild <= 0 ||
        hash is! String ||
        !_sha256.hasMatch(hash) ||
        size is! int ||
        size <= 0 ||
        size > maxPayloadBytes) {
      throw const FormatException('Invalid Bridge release fields.');
    }
    return _BridgeReleaseManifest(
      version: version,
      minAppBuild: minAppBuild,
      sha256: hash,
      size: size,
    );
  }

  Future<BridgeRelease> _packagedRelease() async {
    final source = await _loadPackagedSource();
    final bytes = utf8.encode(source);
    return BridgeRelease(
      version: _extractVersion(source),
      source: source,
      sha256: sha256.convert(bytes).toString(),
      size: bytes.length,
      minAppBuild: 0,
      remote: false,
    );
  }

  String _extractVersion(String source) {
    final matches = _sourceVersion.allMatches(source).toList(growable: false);
    if (matches.length != 1) {
      throw const FormatException('VERSION del Bridge ausente o ambigua.');
    }
    return matches.single.group(1)!;
  }

  void close() => _http.close();
}

class _BridgeReleaseManifest {
  final String version;
  final int minAppBuild;
  final String sha256;
  final int size;

  const _BridgeReleaseManifest({
    required this.version,
    required this.minAppBuild,
    required this.sha256,
    required this.size,
  });

  BridgeReleaseTarget get target => BridgeReleaseTarget(
    version: version,
    sha256: sha256,
    size: size,
    minAppBuild: minAppBuild,
    remote: true,
  );
}
