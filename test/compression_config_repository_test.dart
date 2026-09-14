import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/compression_config.dart';
import 'package:hermes_android/core/services/compression_config_repository.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _fixture() =>
    jsonDecode(
          File(
            'test/fixtures/spec047/compression_config.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

Map<String, dynamic> _cloneMap(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Map<String, dynamic> _agent020Config({Object? thresholdTokens}) {
  final config = _cloneMap(_fixture()['config']!);
  final compression = config['compression'] as Map<String, dynamic>;
  compression.addAll({
    'threshold_tokens': thresholdTokens,
    'min_tail_user_messages': 3,
    'progress_notices': true,
  });
  return config;
}

Map<String, dynamic> _agent020Schema() => {
  'fields': <String, dynamic>{
    'compression.enabled': {'type': 'boolean'},
    'compression.threshold': {'type': 'number'},
    'compression.target_ratio': {'type': 'number'},
    'compression.protect_last_n': {'type': 'number'},
    // Agent 0.20 infiere string porque el default publicado es null.
    'compression.threshold_tokens': {'type': 'string'},
    'compression.min_tail_user_messages': {'type': 'number'},
    'compression.progress_notices': {'type': 'boolean'},
  },
};

DashboardClient _dashboard(http.Client client) => DashboardClient(
  host: '127.0.0.1',
  port: 9119,
  manualToken: 'synthetic-dashboard-token',
  httpClientOverride: client,
);

Future<CompressionConfigException> _failure(Future<Object?> future) async {
  try {
    await future;
  } on CompressionConfigException catch (error) {
    return error;
  }
  throw TestFailure('Expected CompressionConfigException');
}

final class _TrackingClient extends http.BaseClient {
  final MockClient delegate;
  bool closed = false;

  _TrackingClient(Future<http.Response> Function(http.Request) handler)
    : delegate = MockClient(handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (closed) {
      throw http.ClientException('synthetic closed client');
    }
    return delegate.send(request);
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    delegate.close();
  }
}

/// Deliberately permits a late `send` after `close` so this test proves the
/// Dashboard client fence itself, rather than relying on a transport detail.
final class _CloseIgnoringClient extends http.BaseClient {
  _CloseIgnoringClient(Future<http.Response> Function(http.Request) handler)
    : _delegate = MockClient(handler);

  final MockClient _delegate;
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _delegate.send(request);

  @override
  void close() {
    closeCalls += 1;
  }
}

void main() {
  group('CompressionConfigRepository load', () {
    test('lee los cuatro campos y limites del fixture en el perfil', () async {
      final fixture = _fixture();
      final requests = <http.Request>[];
      final dashboard = _dashboard(
        MockClient((request) async {
          requests.add(request);
          return switch (request.url.path) {
            '/api/config' => http.Response(jsonEncode(fixture['config']), 200),
            '/api/config/schema' => http.Response(
              jsonEncode(fixture['schema']),
              200,
            ),
            _ => http.Response('not found', 404),
          };
        }),
      );
      final repository = CompressionConfigRepository(
        dashboard,
        profile: fixture['profile'] as String,
      );
      addTearDown(() {
        repository.close();
        dashboard.close();
      });

      final snapshot = await repository.load();

      expect(snapshot.isSupported, isTrue);
      expect(snapshot.profile, 'synthetic-profile');
      expect(snapshot.enabled, isTrue);
      expect(
        snapshot.configuration,
        const CompressionConfig(
          enabled: true,
          threshold: 0.5,
          targetRatio: 0.2,
          protectLastN: 20,
        ),
      );
      expect(snapshot.limits, CompressionConfigLimits.native);
      expect(snapshot.fetchedAt.isUtc, isTrue);
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.method, 'GET');
        expect(request.url.queryParameters, {'profile': 'synthetic-profile'});
      }
    });

    test(
      'acepta el schema plano real y usa limites nativos si no publica rangos',
      () async {
        final fixture = _fixture();
        final requests = <http.Request>[];
        final schema = <String, dynamic>{
          'fields': <String, dynamic>{
            'compression.enabled': {'type': 'boolean'},
            'compression.threshold': {'type': 'number'},
            'compression.target_ratio': {'type': 'number'},
            'compression.protect_last_n': {'type': 'number'},
          },
        };
        final dashboard = _dashboard(
          MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/api/config') {
              return http.Response(jsonEncode(fixture['config']), 200);
            }
            return http.Response(jsonEncode(schema), 200);
          }),
        );
        final repository = CompressionConfigRepository(
          dashboard,
          profile: 'default',
        );
        addTearDown(() {
          repository.close();
          dashboard.close();
        });

        final snapshot = await repository.load();

        expect(repository.profile, isNull);
        expect(snapshot.isSupported, isTrue);
        expect(snapshot.limits, CompressionConfigLimits.native);
        expect(
          requests.every((request) => request.url.queryParameters.isEmpty),
          isTrue,
        );
      },
    );

    test(
      'Agent 0.20 publica tres campos opcionales sin inventar threshold tokens',
      () async {
        final dashboard = _dashboard(
          MockClient(
            (request) async => http.Response(
              jsonEncode(
                request.url.path == '/api/config'
                    ? _agent020Config()
                    : _agent020Schema(),
              ),
              200,
            ),
          ),
        );
        final repository = CompressionConfigRepository(dashboard);
        addTearDown(() {
          repository.close();
          dashboard.close();
        });

        final snapshot = await repository.load();

        expect(snapshot.optionalFields.thresholdTokens, isTrue);
        expect(snapshot.optionalFields.minTailUserMessages, isTrue);
        expect(snapshot.optionalFields.progressNotices, isTrue);
        expect(snapshot.configuration!.thresholdTokens, isNull);
        expect(snapshot.configuration!.minTailUserMessages, 3);
        expect(snapshot.configuration!.progressNotices, isTrue);
        expect(
          snapshot.configuration!.toDashboardPatch(),
          isNot(contains('threshold_tokens')),
          reason: 'null significa no tocar, no elegir un cap arbitrario',
        );
      },
    );

    test(
      'un campo opcional exige presencia tanto en schema como en config',
      () async {
        final modernConfig = _agent020Config(thresholdTokens: 120000);
        final legacySchema = _cloneMap(_fixture()['schema']!);
        final modernSchema = _agent020Schema();
        final legacyConfig = _cloneMap(_fixture()['config']!);

        CompressionConfigSnapshot parse(
          Map<String, dynamic> config,
          Map<String, dynamic> schema,
        ) => CompressionConfigSnapshot.fromDashboard(
          profile: null,
          config: config,
          schema: schema,
          fetchedAt: DateTime.utc(2026, 8, 3),
        );

        final configOnly = parse(modernConfig, legacySchema);
        final schemaOnly = parse(legacyConfig, modernSchema);

        expect(configOnly.optionalFields.any, isFalse);
        expect(configOnly.configuration!.thresholdTokens, isNull);
        expect(configOnly.configuration!.minTailUserMessages, isNull);
        expect(configOnly.configuration!.progressNotices, isNull);
        expect(schemaOnly.optionalFields.any, isFalse);
        expect(schemaOnly.configuration!.thresholdTokens, isNull);
        expect(schemaOnly.configuration!.minTailUserMessages, isNull);
        expect(schemaOnly.configuration!.progressNotices, isNull);
      },
    );

    test(
      'distingue contrato no soportado de autocompresion desactivada',
      () async {
        final fixture = _fixture();
        final disabledConfig = _cloneMap(fixture['config']!);
        (disabledConfig['compression'] as Map<String, dynamic>)['enabled'] =
            false;

        Future<CompressionConfigSnapshot> loadWith({
          required Map<String, dynamic> config,
          required Map<String, dynamic> schema,
        }) async {
          final dashboard = _dashboard(
            MockClient(
              (request) async => http.Response(
                jsonEncode(request.url.path == '/api/config' ? config : schema),
                200,
              ),
            ),
          );
          final repository = CompressionConfigRepository(dashboard);
          try {
            return await repository.load();
          } finally {
            repository.close();
            dashboard.close();
          }
        }

        final disabled = await loadWith(
          config: disabledConfig,
          schema: _cloneMap(fixture['schema']!),
        );
        final unsupported = await loadWith(
          config: _cloneMap(fixture['config']!),
          schema: <String, dynamic>{'fields': <String, dynamic>{}},
        );

        expect(disabled.support, CompressionConfigSupport.supported);
        expect(disabled.enabled, isFalse);
        expect(unsupported.support, CompressionConfigSupport.unsupported);
        expect(unsupported.enabled, isNull);
        expect(unsupported.configuration, isNull);
        expect(unsupported.limits, isNull);
      },
    );

    test(
      '404 de config/schema degrada a unsupported sin inventar defaults',
      () async {
        final dashboard = _dashboard(
          MockClient((_) async => http.Response('legacy dashboard', 404)),
        );
        final repository = CompressionConfigRepository(dashboard);
        addTearDown(() {
          repository.close();
          dashboard.close();
        });

        final snapshot = await repository.load();

        expect(snapshot.support, CompressionConfigSupport.unsupported);
        expect(snapshot.enabled, isNull);
      },
    );

    test('payload incoherente produce invalidResponse tipado', () async {
      final fixture = _fixture();
      final config = _cloneMap(fixture['config']!);
      (config['compression'] as Map<String, dynamic>)['threshold'] = 'secret';
      final dashboard = _dashboard(
        MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path == '/api/config' ? config : fixture['schema'],
            ),
            200,
          ),
        ),
      );
      final repository = CompressionConfigRepository(dashboard);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });

      final error = await _failure(repository.load());

      expect(error.code, CompressionConfigFailureCode.invalidResponse);
      expect(error.toString(), isNot(contains('secret')));
    });
  });

  group('CompressionConfigRepository save', () {
    test(
      'PUT replica Desktop: registro completo y solo cuatro reemplazos',
      () async {
        final fixture = _fixture();
        final serverConfig = _cloneMap(fixture['config']!);
        final serverCompression =
            serverConfig['compression'] as Map<String, dynamic>;
        serverCompression['future_native_sibling'] = {'preserve': true};
        Map<String, dynamic>? capturedBody;
        final requests = <http.Request>[];
        final dashboard = _dashboard(
          MockClient((request) async {
            requests.add(request);
            if (request.method == 'GET' && request.url.path == '/api/config') {
              return http.Response(jsonEncode(serverConfig), 200);
            }
            if (request.method == 'GET' &&
                request.url.path == '/api/config/schema') {
              return http.Response(jsonEncode(fixture['schema']), 200);
            }
            if (request.method == 'PUT' && request.url.path == '/api/config') {
              capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
              final configPatch =
                  capturedBody!['config'] as Map<String, dynamic>;
              serverCompression.addAll(
                configPatch['compression'] as Map<String, dynamic>,
              );
              return http.Response('{"ok":true}', 200);
            }
            return http.Response('not found', 404);
          }),
        );
        final repository = CompressionConfigRepository(
          dashboard,
          profile: 'synthetic-profile',
        );
        addTearDown(() {
          repository.close();
          dashboard.close();
        });
        final base = await repository.load();
        const changed = CompressionConfig(
          enabled: false,
          threshold: 0.75,
          targetRatio: 0.3,
          protectLastN: 40,
        );

        final saved = await repository.save(base, changed);

        final sentConfig = capturedBody!['config'] as Map<String, dynamic>;
        final sentCompression =
            sentConfig['compression'] as Map<String, dynamic>;
        expect(sentCompression, {
          'enabled': false,
          'threshold': 0.75,
          'target_ratio': 0.3,
          'protect_last_n': 40,
          'future_native_sibling': {'preserve': true},
        });
        expect(sentConfig['unrelated_synthetic_key'], {'preserve': true});
        expect(serverConfig['unrelated_synthetic_key'], {'preserve': true});
        expect(serverCompression['future_native_sibling'], {'preserve': true});
        expect(saved.configuration, changed);
        expect(saved.profile, 'synthetic-profile');
        expect(requests.last.method, 'PUT');
        expect(requests.last.url.queryParameters, {
          'profile': 'synthetic-profile',
        });
      },
    );

    test(
      'PUT 0.20 cambia solo opcionales publicados y no materializa null',
      () async {
        final config = _agent020Config();
        (config['compression'] as Map<String, dynamic>)['future_020_key'] = 7;
        Map<String, dynamic>? sent;
        final dashboard = _dashboard(
          MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode(
                  request.url.path == '/api/config'
                      ? config
                      : _agent020Schema(),
                ),
                200,
              );
            }
            sent = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('{"ok":true}', 200);
          }),
        );
        final repository = CompressionConfigRepository(dashboard);
        addTearDown(() {
          repository.close();
          dashboard.close();
        });
        final base = await repository.load();
        final changed = base.configuration!.copyWith(
          thresholdTokens: 120000,
          minTailUserMessages: 4,
          progressNotices: false,
        );

        final saved = await repository.save(base, changed);

        final compression =
            (sent!['config'] as Map<String, dynamic>)['compression']
                as Map<String, dynamic>;
        expect(compression['threshold_tokens'], 120000);
        expect(compression['min_tail_user_messages'], 4);
        expect(compression['progress_notices'], isFalse);
        expect(compression['future_020_key'], 7);
        expect(saved.configuration, changed);
        expect(saved.optionalFields, base.optionalFields);
      },
    );

    test('rechaza cada valor fuera de rango antes de cualquier PUT', () async {
      final fixture = _fixture();
      var putCount = 0;
      final dashboard = _dashboard(
        MockClient((request) async {
          if (request.method == 'PUT') {
            putCount += 1;
            return http.Response('{"ok":true}', 200);
          }
          return http.Response(
            jsonEncode(
              request.url.path == '/api/config'
                  ? fixture['config']
                  : fixture['schema'],
            ),
            200,
          );
        }),
      );
      final repository = CompressionConfigRepository(dashboard);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });
      final base = await repository.load();
      final current = base.configuration!;
      final invalid = <(CompressionConfig, String)>[
        (current.copyWith(threshold: 0.099), 'threshold'),
        (current.copyWith(threshold: 0.951), 'threshold'),
        (current.copyWith(threshold: double.nan), 'threshold'),
        (current.copyWith(targetRatio: 0.049), 'target_ratio'),
        (current.copyWith(targetRatio: 0.801), 'target_ratio'),
        (current.copyWith(protectLastN: -1), 'protect_last_n'),
        (current.copyWith(protectLastN: 201), 'protect_last_n'),
        (current.copyWith(thresholdTokens: 0), 'threshold_tokens'),
        (current.copyWith(minTailUserMessages: 0), 'min_tail_user_messages'),
      ];

      for (final (configuration, field) in invalid) {
        final error = await _failure(repository.save(base, configuration));
        expect(error.code, CompressionConfigFailureCode.invalidValue);
        expect(error.field, field);
      }

      expect(putCount, 0);
    });

    test('acepta exactamente los limites inferior y superior', () async {
      final fixture = _fixture();
      var putCount = 0;
      final dashboard = _dashboard(
        MockClient((request) async {
          if (request.method == 'PUT') {
            putCount += 1;
            return http.Response('{"ok":true}', 200);
          }
          return http.Response(
            jsonEncode(
              request.url.path == '/api/config'
                  ? fixture['config']
                  : fixture['schema'],
            ),
            200,
          );
        }),
      );
      final repository = CompressionConfigRepository(dashboard);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });
      final base = await repository.load();

      await repository.save(
        base,
        const CompressionConfig(
          enabled: true,
          threshold: 0.1,
          targetRatio: 0.05,
          protectLastN: 0,
        ),
      );
      await repository.save(
        base,
        const CompressionConfig(
          enabled: true,
          threshold: 0.95,
          targetRatio: 0.8,
          protectLastN: 200,
        ),
      );

      expect(putCount, 2);
    });

    test('target_ratio es independiente de threshold', () {
      expect(
        () => CompressionConfigLimits.native.requireValid(
          const CompressionConfig(
            enabled: true,
            threshold: 0.1,
            targetRatio: 0.8,
            protectLastN: 20,
          ),
        ),
        returnsNormally,
      );
    });

    test(
      'un snapshot de otro perfil o unsupported nunca se puede guardar',
      () async {
        final fixture = _fixture();
        var putCount = 0;
        final dashboard = _dashboard(
          MockClient((request) async {
            if (request.method == 'PUT') putCount += 1;
            return http.Response('{"ok":true}', 200);
          }),
        );
        final repository = CompressionConfigRepository(
          dashboard,
          profile: 'profile-a',
        );
        addTearDown(() {
          repository.close();
          dashboard.close();
        });
        final now = DateTime.now().toUtc();
        final wrongProfile = CompressionConfigSnapshot.supported(
          profile: 'profile-b',
          configuration: const CompressionConfig(
            enabled: true,
            threshold: 0.5,
            targetRatio: 0.2,
            protectLastN: 20,
          ),
          limits: CompressionConfigLimits.native,
          recordHandle: CompressionConfigRecordHandle.fromRedactedRecord(
            _cloneMap(fixture['config']!),
          ),
          fetchedAt: now,
        );
        final unsupported = CompressionConfigSnapshot.unsupported(
          profile: 'profile-a',
          fetchedAt: now,
        );
        final configuration = CompressionConfigSnapshot.fromDashboard(
          profile: 'profile-a',
          config: _cloneMap(fixture['config']!),
          schema: _cloneMap(fixture['schema']!),
          fetchedAt: now,
        ).configuration!;

        expect(
          (await _failure(repository.save(wrongProfile, configuration))).code,
          CompressionConfigFailureCode.invalidProfile,
        );
        expect(
          (await _failure(repository.save(unsupported, configuration))).code,
          CompressionConfigFailureCode.unsupported,
        );
        expect(putCount, 0);
      },
    );

    test(
      'un snapshot legacy no permite añadir campos 0.20 por su cuenta',
      () async {
        final fixture = _fixture();
        var putCount = 0;
        final dashboard = _dashboard(
          MockClient((request) async {
            if (request.method == 'PUT') putCount += 1;
            return http.Response(
              jsonEncode(
                request.url.path == '/api/config'
                    ? fixture['config']
                    : fixture['schema'],
              ),
              200,
            );
          }),
        );
        final repository = CompressionConfigRepository(dashboard);
        addTearDown(() {
          repository.close();
          dashboard.close();
        });
        final base = await repository.load();

        final error = await _failure(
          repository.save(
            base,
            base.configuration!.copyWith(thresholdTokens: 100000),
          ),
        );

        expect(error.code, CompressionConfigFailureCode.invalidValue);
        expect(error.field, 'threshold_tokens');
        expect(putCount, 0);
      },
    );
  });

  group('fallos sanitizados y lifecycle', () {
    test('descarta el body remoto tanto al leer como al guardar', () async {
      final fixture = _fixture();
      final readDashboard = _dashboard(
        MockClient(
          (_) async => http.Response('{"token":"private-read-secret"}', 503),
        ),
      );
      final readRepository = CompressionConfigRepository(readDashboard);
      addTearDown(() {
        readRepository.close();
        readDashboard.close();
      });

      final readError = await _failure(readRepository.load());
      expect(readError.code, CompressionConfigFailureCode.remote);
      expect(readError.statusCode, 503);
      expect(readError.toString(), isNot(contains('private-read-secret')));

      final writeDashboard = _dashboard(
        MockClient((request) async {
          if (request.method == 'PUT') {
            return http.Response('{"detail":"private-write-secret"}', 422);
          }
          return http.Response(
            jsonEncode(
              request.url.path == '/api/config'
                  ? fixture['config']
                  : fixture['schema'],
            ),
            200,
          );
        }),
      );
      final writeRepository = CompressionConfigRepository(writeDashboard);
      addTearDown(() {
        writeRepository.close();
        writeDashboard.close();
      });
      final base = await writeRepository.load();

      final writeError = await _failure(
        writeRepository.save(base, base.configuration!),
      );
      expect(writeError.code, CompressionConfigFailureCode.rejected);
      expect(writeError.statusCode, 422);
      expect(writeError.toString(), isNot(contains('private-write-secret')));
    });

    test('el handle del registro nunca imprime contenido redactado', () {
      final handle = CompressionConfigRecordHandle.fromRedactedRecord({
        'compression': {
          'enabled': true,
          'threshold': 0.5,
          'target_ratio': 0.2,
          'protect_last_n': 20,
        },
        'provider': {'api_key': '***redacted-private-value***'},
      });

      expect(handle.toString(), 'CompressionConfigRecordHandle(redacted)');
      expect(handle.toString(), isNot(contains('redacted-private-value')));
    });

    test('valida el perfil antes de realizar peticiones', () {
      var requests = 0;
      final dashboard = _dashboard(
        MockClient((_) async {
          requests += 1;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(dashboard.close);

      expect(
        () => CompressionConfigRepository(dashboard, profile: '../private'),
        throwsA(
          isA<CompressionConfigException>().having(
            (error) => error.code,
            'code',
            CompressionConfigFailureCode.invalidProfile,
          ),
        ),
      );
      expect(requests, 0);
    });

    test(
      'forConnection respeta readOnly, posee el cliente y close es idempotente',
      () async {
        final fixture = _fixture();
        var putCount = 0;
        final tracking = _TrackingClient((request) async {
          if (request.method == 'PUT') {
            putCount += 1;
            return http.Response('{"ok":true}', 200);
          }
          return http.Response(
            jsonEncode(
              request.url.path == '/api/config'
                  ? fixture['config']
                  : fixture['schema'],
            ),
            200,
          );
        });
        final dashboard = _dashboard(tracking);
        final connection = SavedConnection(
          id: 'read-only-instance',
          label: 'Read only',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'synthetic-gateway-key',
          readOnly: true,
        );
        final repository = CompressionConfigRepository.forConnection(
          connection,
          profile: 'synthetic-profile',
          dashboardFactory: (_) => dashboard,
        );
        final base = await repository.load();

        final readOnlyError = await _failure(
          repository.save(base, base.configuration!),
        );
        expect(readOnlyError.code, CompressionConfigFailureCode.readOnly);
        expect(putCount, 0);
        expect(tracking.closed, isFalse);

        repository.close();
        repository.close();

        expect(repository.isClosed, isTrue);
        expect(tracking.closed, isTrue);
        final closedError = await _failure(repository.load());
        expect(closedError.code, CompressionConfigFailureCode.closed);
      },
    );

    test(
      'forConnection sin permiso de escritura conserva GET y rechaza PUT',
      () async {
        final fixture = _fixture();
        final requests = <http.Request>[];
        final tracking = _TrackingClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(
              request.url.path == '/api/config'
                  ? fixture['config']
                  : fixture['schema'],
            ),
            200,
          );
        });
        final dashboard = _dashboard(tracking);
        final repository = CompressionConfigRepository.forConnection(
          SavedConnection(
            id: 'capability-read-only-instance',
            label: 'Capability read only',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'synthetic-gateway-key',
          ),
          profile: 'synthetic-profile',
          writable: false,
          dashboardFactory: (_) => dashboard,
        );
        final base = await repository.load();

        final readOnlyError = await _failure(
          repository.save(base, base.configuration!),
        );

        expect(readOnlyError.code, CompressionConfigFailureCode.readOnly);
        expect(
          requests.where((request) => request.method == 'GET'),
          hasLength(2),
        );
        expect(
          requests.every(
            (request) =>
                request.url.queryParameters['profile'] == 'synthetic-profile',
          ),
          isTrue,
        );
        expect(requests.where((request) => request.method == 'PUT'), isEmpty);
        repository.close();
        expect(tracking.closed, isTrue);
      },
    );

    test(
      'close espera un PUT ya iniciado antes de cerrar su cliente',
      () async {
        final fixture = _fixture();
        final putStarted = Completer<void>();
        final putResult = Completer<http.Response>();
        final tracking = _TrackingClient((request) async {
          if (request.method == 'PUT') {
            if (!putStarted.isCompleted) putStarted.complete();
            return putResult.future;
          }
          return http.Response(
            jsonEncode(
              request.url.path == '/api/config'
                  ? fixture['config']
                  : fixture['schema'],
            ),
            200,
          );
        });
        final dashboard = _dashboard(tracking);
        final repository = CompressionConfigRepository.forConnection(
          SavedConnection(
            id: 'writable-instance',
            label: 'Writable',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'synthetic-gateway-key',
          ),
          profile: 'synthetic-profile',
          dashboardFactory: (_) => dashboard,
        );
        final base = await repository.load();
        final changed = base.configuration!.copyWith(threshold: 0.72);

        final saving = repository.save(base, changed);
        await putStarted.future;
        repository.close();

        expect(repository.isClosed, isTrue);
        expect(tracking.closed, isFalse);
        putResult.complete(http.Response('{"ok":true}', 200));
        expect((await saving).configuration, changed);
        expect(tracking.closed, isTrue);
        final closedError = await _failure(repository.load());
        expect(closedError.code, CompressionConfigFailureCode.closed);
      },
    );

    test(
      'close con abort cierra de inmediato el cliente propio en un PUT activo',
      () async {
        final fixture = _fixture();
        final putStarted = Completer<void>();
        final putResult = Completer<http.Response>();
        final tracking = _TrackingClient((request) async {
          if (request.method == 'PUT') {
            if (!putStarted.isCompleted) putStarted.complete();
            return putResult.future;
          }
          return http.Response(
            jsonEncode(
              request.url.path == '/api/config'
                  ? fixture['config']
                  : fixture['schema'],
            ),
            200,
          );
        });
        final dashboard = _dashboard(tracking);
        final repository = CompressionConfigRepository.forConnection(
          SavedConnection(
            id: 'fenced-writable-instance',
            label: 'Fenced writable',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'synthetic-gateway-key',
          ),
          profile: 'synthetic-profile',
          dashboardFactory: (_) => dashboard,
        );
        final base = await repository.load();
        final changed = base.configuration!.copyWith(threshold: 0.72);

        final saving = repository.save(base, changed);
        await putStarted.future;
        repository.close(abortActiveOperations: true);

        expect(repository.isClosed, isTrue);
        expect(tracking.closed, isTrue);
        putResult.complete(http.Response('{"ok":true}', 200));
        expect((await saving).configuration, changed);
      },
    );

    test(
      'close con abort bloquea un PUT que seguía esperando autenticación',
      () async {
        final fixture = _fixture();
        var putCount = 0;
        final tracking = _CloseIgnoringClient((request) async {
          if (request.method == 'PUT') putCount += 1;
          return http.Response(
            jsonEncode(
              request.url.path == '/api/config'
                  ? fixture['config']
                  : fixture['schema'],
            ),
            200,
          );
        });
        final dashboard = _dashboard(tracking);
        final repository = CompressionConfigRepository.forConnection(
          SavedConnection(
            id: 'fenced-before-put-instance',
            label: 'Fenced before PUT',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'synthetic-gateway-key',
          ),
          profile: 'synthetic-profile',
          dashboardFactory: (_) => dashboard,
        );
        final base = await repository.load();
        final saving = repository.save(
          base,
          base.configuration!.copyWith(threshold: 0.72),
        );

        repository.close(abortActiveOperations: true);
        final failure = await _failure(saving);

        expect(failure.code, CompressionConfigFailureCode.transport);
        expect(putCount, 0);
        expect(tracking.closeCalls, 1);
      },
    );

    test('el constructor inyectado toma prestado el DashboardClient', () async {
      final fixture = _fixture();
      final tracking = _TrackingClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path == '/api/config'
                ? fixture['config']
                : fixture['schema'],
          ),
          200,
        ),
      );
      final dashboard = _dashboard(tracking);
      final repository = CompressionConfigRepository(dashboard);

      await repository.load();
      repository.close();

      expect(tracking.closed, isFalse);
      await dashboard.getServerConfig();
      dashboard.close();
      expect(tracking.closed, isTrue);
    });
  });
}
