import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_release_channel.dart';
import 'package:hermes_android/core/services/bridge_update_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Estas dos regresiones levantan un servidor exclusivamente loopback. El
  // binding de widgets instala por defecto un HttpOverride que devuelve 400.
  HttpOverrides.global = null;
  final secureStore = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BridgeUpdateService.debugResetMaintenanceState();
    secureStore.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
            }
            return null;
          },
        );
  });

  group('BridgeUpdateService.isOutdated', () {
    test('instalada anterior a empaquetada → true', () {
      expect(BridgeUpdateService.isOutdated('1.8.0', '1.10.0'), isTrue);
      expect(BridgeUpdateService.isOutdated('1.9.9', '1.10.0'), isTrue);
    });

    test('instalada igual o superior → false', () {
      expect(BridgeUpdateService.isOutdated('1.10.0', '1.10.0'), isFalse);
      expect(BridgeUpdateService.isOutdated('1.11.0', '1.10.0'), isFalse);
    });

    test('versión instalada nula o vacía → false (no alcanzable)', () {
      expect(BridgeUpdateService.isOutdated(null, '1.10.0'), isFalse);
      expect(BridgeUpdateService.isOutdated('', '1.10.0'), isFalse);
    });

    test('la versión empaquetada existe y es no vacía', () {
      expect(BridgeUpdateService.packagedVersion, isNotEmpty);
    });
  });

  test('update no modifica una instancia en modo solo lectura', () async {
    final connection = SavedConnection(
      id: 'readonly',
      label: 'Read only',
      host: 'example.com',
      port: 8642,
      apiKey: 'test-key',
      useHttps: true,
      readOnly: true,
    );

    final result = await BridgeUpdateService.update(connection);
    expect(result.ok, isFalse);
    expect(result.detail, contains('read-only'));
  });

  test('check compara contra la release remota verificada', () async {
    final result = await BridgeUpdateService.check(
      _connection(),
      allowRemote: true,
      targetResolver: () async => _release('1.17.0', remote: true).target,
      versionProbe: (_) async => '1.16.0',
    );

    expect(result.reachable, isTrue);
    expect(result.installed, '1.16.0');
    expect(result.available, '1.17.0');
    expect(result.remote, isTrue);
    expect(result.outdated, isTrue);
  });

  test(
    'fallo del canal conserva el asset y no oculta un bridge vivo',
    () async {
      final result = await BridgeUpdateService.check(
        _connection(),
        allowRemote: true,
        targetResolver: () async => throw const FormatException('bad manifest'),
        versionProbe: (_) async => '1.15.0',
      );

      expect(result.reachable, isTrue);
      expect(result.available, BridgeUpdateService.packagedVersion);
      expect(result.remote, isFalse);
      expect(result.outdated, isTrue);
    },
  );

  test(
    'update instala el source verificado y confirma la versión objetivo',
    () async {
      final probes = <String>['1.16.0', '1.17.0'];
      BridgeRelease? installedRelease;
      final result = await BridgeUpdateService.update(
        _connection(),
        targetResolver: () async => _release('1.17.0', remote: true).target,
        releaseDownloader: (_) async => _release('1.17.0', remote: true),
        installer: (release, onProgress) async {
          installedRelease = release;
          return (ok: true, detail: 'installed');
        },
        versionProbe: (_) async => probes.removeAt(0),
        verificationTimeout: const Duration(milliseconds: 20),
        verificationRetryDelay: const Duration(milliseconds: 1),
      );

      expect(result.ok, isTrue);
      expect(installedRelease?.version, '1.17.0');
      expect(installedRelease?.source, contains('remote 1.17.0'));
    },
  );

  test('update no degrada un bridge ya superior', () async {
    var installs = 0;
    final result = await BridgeUpdateService.update(
      _connection(),
      targetResolver: () async => _release('1.17.0', remote: true).target,
      releaseDownloader: (_) async => _release('1.17.0', remote: true),
      installer: (release, progress) async {
        installs++;
        return (ok: true, detail: 'unexpected');
      },
      versionProbe: (_) async => '1.18.0',
    );

    expect(result.ok, isTrue);
    expect(installs, 0);
  });

  test(
    'update falla si tras reiniciar sigue sirviendo la versión antigua',
    () async {
      final result = await BridgeUpdateService.update(
        _connection(),
        targetResolver: () async => _release('1.17.0', remote: true).target,
        releaseDownloader: (_) async => _release('1.17.0', remote: true),
        installer: (release, progress) async => (ok: true, detail: 'installed'),
        versionProbe: (_) async => '1.16.0',
        verificationTimeout: const Duration(milliseconds: 5),
        verificationRetryDelay: const Duration(milliseconds: 1),
      );

      expect(result.ok, isFalse);
      expect(result.detail, contains('1.17.0'));
    },
  );

  test(
    'fallo al descargar el target ofrecido no reinstala el fallback',
    () async {
      var installs = 0;
      final target = _release('1.17.0', remote: true).target;
      final result = await BridgeUpdateService.update(
        _connection(),
        target: target,
        releaseDownloader: (_) async => throw const FormatException('bad hash'),
        installer: (release, progress) async {
          installs++;
          return (ok: true, detail: 'unexpected');
        },
        versionProbe: (_) async => '1.16.0',
      );

      expect(result.ok, isFalse);
      expect(result.detail, contains('1.17.0'));
      expect(installs, 0);
    },
  );

  test('mantenimiento automático usa self_update sin lanzar runs', () async {
    final probes = <String>['1.16.0', '1.17.0'];
    var selfUpdates = 0;
    var legacyInstalls = 0;
    final result = await BridgeUpdateService.update(
      _connection(),
      automatic: true,
      target: _release('1.17.0', remote: true).target,
      releaseDownloader: (_) async => _release('1.17.0', remote: true),
      selfUpdater: (connection, release, progress) async {
        selfUpdates++;
        return (supported: true, ok: true, detail: 'accepted');
      },
      legacyInstaller: (release, progress) async {
        legacyInstalls++;
        return (ok: true, detail: 'unexpected');
      },
      versionProbe: (_) async => probes.removeAt(0),
      verificationTimeout: const Duration(milliseconds: 20),
      verificationRetryDelay: const Duration(milliseconds: 1),
    );

    expect(result.ok, isTrue);
    expect(selfUpdates, 1);
    expect(legacyInstalls, 0);
  });

  test('bridge legacy nunca dispara una ejecución en background', () async {
    var legacyInstalls = 0;
    final result = await BridgeUpdateService.update(
      _connection(),
      automatic: true,
      target: _release('1.17.0', remote: true).target,
      releaseDownloader: (_) async => _release('1.17.0', remote: true),
      selfUpdater: (connection, release, progress) async =>
          (supported: false, ok: false, detail: 'legacy'),
      legacyInstaller: (release, progress) async {
        legacyInstalls++;
        return (ok: true, detail: 'unexpected');
      },
      versionProbe: (_) async => '1.16.0',
    );

    expect(result.ok, isFalse);
    expect(result.detail, contains('manual'));
    expect(legacyInstalls, 0);
  });

  test(
    'self_update usa el token guardado aunque provision esté deshabilitado',
    () async {
      final bridge = await _FakeBridge.start(
        validToken: 'manual-token',
        provisionedToken: null,
      );
      addTearDown(bridge.close);
      secureStore['bridge_url_remote'] = bridge.url;
      secureStore['bridge_token_remote'] = 'manual-token';
      var probes = 0;

      final result = await BridgeUpdateService.update(
        _localConnection(),
        automatic: true,
        target: _release('1.17.0', remote: true).target,
        releaseDownloader: (_) async => _release('1.17.0', remote: true),
        versionProbe: (url) async {
          expect(url, bridge.url);
          return probes++ == 0 ? '1.16.0' : '1.17.0';
        },
        verificationTimeout: const Duration(milliseconds: 50),
        verificationRetryDelay: const Duration(milliseconds: 1),
      );

      expect(result.ok, isTrue);
      expect(bridge.provisionHits, 0);
      expect(bridge.selfUpdateHits, 1);
      expect(bridge.authorizationSeen, contains('Bearer manual-token'));
    },
  );

  test('token guardado inválido se reprovisiona y reemplaza', () async {
    final bridge = await _FakeBridge.start(
      validToken: 'fresh-token',
      provisionedToken: 'fresh-token',
    );
    addTearDown(bridge.close);
    secureStore['bridge_url_remote'] = bridge.url;
    secureStore['bridge_token_remote'] = 'expired-token';
    var probes = 0;

    final result = await BridgeUpdateService.update(
      _localConnection(),
      automatic: true,
      target: _release('1.17.0', remote: true).target,
      releaseDownloader: (_) async => _release('1.17.0', remote: true),
      versionProbe: (url) async {
        expect(url, bridge.url);
        return probes++ == 0 ? '1.16.0' : '1.17.0';
      },
      verificationTimeout: const Duration(milliseconds: 50),
      verificationRetryDelay: const Duration(milliseconds: 1),
    );

    expect(result.ok, isTrue);
    expect(bridge.provisionHits, 1);
    expect(bridge.selfUpdateHits, 1);
    expect(secureStore['bridge_token_remote'], 'fresh-token');
  });

  test('migra las preferencias antiguas a una política común', () async {
    SharedPreferences.setMockInitialValues({
      'hermes_auto_update': true,
      'bridge_auto_update': false,
    });

    expect(await BridgeUpdateService.automaticUpdatesEnabled(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('components_auto_update'), isTrue);

    await BridgeUpdateService.setAutomaticUpdates(false);
    expect(prefs.getBool('components_auto_update'), isFalse);
    expect(prefs.getBool('hermes_auto_update'), isFalse);
    expect(prefs.getBool('bridge_auto_update'), isFalse);
  });

  test('mantenimiento no instala un bridge ausente', () async {
    var updates = 0;
    final result = await BridgeUpdateService.maintainIfEnabled(
      _connection(),
      enabled: () async => true,
      checker: (_) async => BridgeUpdateCheck.none,
      updater: (_) async {
        updates++;
        return (ok: true, detail: 'unexpected');
      },
    );

    expect(result.checked, isTrue);
    expect(result.updated, isFalse);
    expect(updates, 0);
  });

  test(
    'deduplica dos comprobaciones concurrentes de la misma instancia',
    () async {
      final gate = Completer<BridgeUpdateCheck>();
      var checks = 0;
      var updates = 0;
      final connection = _connection();

      Future<BridgeMaintenanceResult> start() =>
          BridgeUpdateService.maintainIfEnabled(
            connection,
            enabled: () async => true,
            checker: (_) {
              checks++;
              return gate.future;
            },
            updater: (_) async {
              updates++;
              return (ok: true, detail: 'updated');
            },
          );

      final first = start();
      await Future<void>.delayed(Duration.zero);
      final second = start();
      gate.complete(
        const BridgeUpdateCheck(
          installed: '1.0.0',
          reachable: true,
          outdated: true,
        ),
      );

      final results = await Future.wait([first, second]);
      expect(checks, 1);
      expect(updates, 1);
      expect(results.every((result) => result.updated), isTrue);
    },
  );

  test('respeta TTL y nunca intenta downgrade', () async {
    var checks = 0;
    var updates = 0;
    final now = DateTime(2026, 7, 16, 12);
    final connection = _connection();

    Future<BridgeMaintenanceResult> run() =>
        BridgeUpdateService.maintainIfEnabled(
          connection,
          now: () => now,
          enabled: () async => true,
          checker: (_) async {
            checks++;
            return const BridgeUpdateCheck(
              installed: '99.0.0',
              reachable: true,
              outdated: false,
            );
          },
          updater: (_) async {
            updates++;
            return (ok: true, detail: 'unexpected');
          },
        );

    final first = await run();
    final second = await run();
    expect(first.checked, isTrue);
    expect(second.checked, isFalse);
    expect(checks, 1);
    expect(updates, 0);
  });
}

SavedConnection _connection() => SavedConnection(
  id: 'remote',
  label: 'Remote',
  host: '192.168.1.40',
  port: 8642,
  apiKey: 'test-key',
);

SavedConnection _localConnection() => SavedConnection(
  id: 'remote',
  label: 'Local test bridge',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'gateway-key',
);

BridgeRelease _release(String version, {required bool remote}) => BridgeRelease(
  version: version,
  source: 'VERSION = "$version"\n# remote $version\n',
  sha256: List.filled(64, remote ? 'a' : 'b').join(),
  remote: remote,
);

class _FakeBridge {
  final HttpServer _server;
  final String validToken;
  final String? provisionedToken;
  int provisionHits = 0;
  int selfUpdateHits = 0;
  final List<String> authorizationSeen = [];

  _FakeBridge._(this._server, this.validToken, this.provisionedToken);

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeBridge> start({
    required String validToken,
    required String? provisionedToken,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _FakeBridge._(server, validToken, provisionedToken);
    server.listen(fixture._handle);
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (auth.isNotEmpty) authorizationSeen.add(auth);
    request.response.headers.contentType = ContentType.json;

    switch ((request.method, request.uri.path)) {
      case ('GET', '/bridge/health'):
        request.response.write('{"status":"ok","version":"1.16.0"}');
      case ('GET', '/bridge/capabilities'):
        if (auth != 'Bearer $validToken') {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.write('{"error":"unauthorized"}');
        } else {
          request.response.write(
            jsonEncode({
              'version': '1.16.0',
              'operations': {'self_update': true},
              'scopes': ['config'],
            }),
          );
        }
      case ('POST', '/bridge/provision'):
        provisionHits++;
        if (provisionedToken == null || auth != 'Bearer gateway-key') {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('{"error":"disabled"}');
        } else {
          request.response.write(jsonEncode({'token': provisionedToken}));
        }
      case ('POST', '/bridge/self-update'):
        selfUpdateHits++;
        if (auth != 'Bearer $validToken') {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.write('{"error":"unauthorized"}');
        } else {
          request.response.write('{"ok":true}');
        }
      default:
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('{"error":"not_found"}');
    }
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}
