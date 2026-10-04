// Toolsets of the server: the list, enabling, the provider, the model and the
// credentials of one toolset. Every write is confirmed by reading back.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/server_toolset.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart'
    show ServerConfigException, ServerConfigFailureKind;
import 'package:hermes_android/core/services/server_toolsets_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _toolset(
  String name, {
  bool enabled = false,
  Object? description = 'Does things',
}) => {
  'name': name,
  'label': 'Label $name',
  'description': description,
  'platform': 'cli',
  'platform_label': 'CLI',
  'enabled': enabled,
  'available': true,
  'configured': true,
  'tools': ['a', 'b'],
};

final class _Server {
  final List<http.Request> requests = [];
  List<Map<String, dynamic>> toolsets = [
    _toolset('web', enabled: true),
    _toolset('files'),
  ];
  bool wrapList = false;
  Map<String, dynamic> config = {
    'name': 'web',
    'has_category': true,
    'providers': [
      {
        'name': 'alpha',
        'badge': 'free',
        'tag': 'fast',
        'env_vars': [
          {
            'key': 'ALPHA_KEY',
            'prompt': 'Key',
            'url': null,
            'default': null,
            'is_set': false,
          },
        ],
        'post_setup': null,
        'requires_nous_auth': false,
        'is_active': true,
        'status': 'ready',
      },
      {
        'name': 'beta',
        'badge': null,
        'tag': null,
        'env_vars': <Object?>[],
        'post_setup': null,
        'requires_nous_auth': true,
        'is_active': false,
        'status': 'needs_auth',
      },
    ],
    'active_provider': 'alpha',
  };
  Map<String, dynamic> models = {
    'name': 'web',
    'has_models': true,
    'provider': 'alpha',
    'plugin': null,
    'models': [
      {
        'id': 'm1',
        'display': 'Model 1',
        'speed': null,
        'strengths': null,
        'price': null,
      },
      {'id': 'm2', 'display': 'Model 2'},
    ],
    'current': 'm1',
    'default': 'm1',
  };

  Object? enableResponse = {
    'ok': true,
    'name': 'web',
    'platform': 'cli',
    'enabled': true,
    'post_setup_started': null,
  };
  int? putStatus;
  bool ignoreWrites = false;

  late final DashboardClient dashboard = DashboardClient(
    host: 'hermes.example.test',
    port: 9119,
    manualToken: 'synthetic-token',
    httpClientOverride: MockClient(_handle),
  );

  List<http.Request> get puts =>
      requests.where((r) => r.method == 'PUT').toList();

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/tools/toolsets') {
      return http.Response(
        jsonEncode(wrapList ? {'data': toolsets} : toolsets),
        200,
      );
    }
    if (request.method == 'GET' && path.endsWith('/config')) {
      return http.Response(jsonEncode(config), 200);
    }
    if (request.method == 'GET' && path.endsWith('/models')) {
      return http.Response(jsonEncode(models), 200);
    }
    if (request.method == 'PUT') {
      final status = putStatus;
      if (status != null) return http.Response('{}', status);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (!ignoreWrites) {
        if (path.endsWith('/provider')) {
          config['active_provider'] = body['provider'];
        } else if (path.endsWith('/model')) {
          models['current'] = body['model'];
        } else if (path.endsWith('/env')) {
          final env = (body['env'] as Map).keys.toSet();
          for (final provider in config['providers'] as List) {
            for (final v in (provider as Map)['env_vars'] as List) {
              if (env.contains((v as Map)['key'])) v['is_set'] = true;
            }
          }
        } else {
          final name = path.split('/').last;
          for (final row in toolsets) {
            if (row['name'] == name) row['enabled'] = body['enabled'];
          }
        }
      }
      return http.Response(
        jsonEncode(
          path.endsWith('/env')
              ? {
                  'ok': true,
                  'name': 'web',
                  'saved': ['ALPHA_KEY'],
                  'skipped': <Object?>[],
                  'is_set': {'ALPHA_KEY': true},
                }
              : enableResponse is Map && !path.endsWith('/provider')
              ? enableResponse
              : {'ok': true},
        ),
        200,
      );
    }
    return http.Response('{}', 404);
  }
}

ServerToolsetsRepository _repo(
  _Server server, {
  String? profile,
  bool writable = true,
}) => ServerToolsetsRepository(
  server.dashboard,
  profile: profile,
  writable: writable,
);

Future<ServerConfigException> _failure(Future<Object?> future) async {
  try {
    await future;
  } on ServerConfigException catch (error) {
    return error;
  }
  throw TestFailure('Expected ServerConfigException');
}

void main() {
  group('list', () {
    test('parses a bare list, with null optional fields', () async {
      final server = _Server()
        ..toolsets = [
          _toolset('web', enabled: true, description: null),
          {'name': 'bare'},
        ];
      final rows = await _repo(server).list();

      expect(rows.map((t) => t.name), ['web', 'bare']);
      expect(rows.first.enabled, isTrue);
      expect(rows.first.description, isNull);
      expect(rows.first.label, 'Label web');
      expect(rows.last.label, 'bare');
      expect(rows.last.enabled, isFalse);
      expect(rows.last.tools, isEmpty);
    });

    test('parses the wrapped list', () async {
      final server = _Server()..wrapList = true;
      expect((await _repo(server).list()).map((t) => t.name), ['web', 'files']);
    });

    test('rows without a usable name are dropped', () async {
      final server = _Server()
        ..toolsets = [
          {'name': ''},
          {'label': 'x'},
          _toolset('ok'),
        ];
      expect((await _repo(server).list()).map((t) => t.name), ['ok']);
    });

    test('carries the profile', () async {
      final server = _Server();
      await _repo(server, profile: 'work').list();
      expect(server.requests.single.url.queryParameters, {'profile': 'work'});
    });
  });

  group('enable', () {
    test('one PUT with the flag, one re-read of the list', () async {
      final server = _Server();
      final result = await _repo(server).setEnabled('files', true);

      expect(server.puts, hasLength(1));
      expect(server.puts.single.url.path, '/api/tools/toolsets/files');
      expect(jsonDecode(server.puts.single.body), {'enabled': true});
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(
        result.toolsets.firstWhere((t) => t.name == 'files').enabled,
        true,
      );
      expect(result.postSetupStarted, isFalse);
    });

    test('post_setup_started is reported, never followed', () async {
      final server = _Server()
        ..enableResponse = {
          'ok': true,
          'name': 'files',
          'platform': 'cli',
          'enabled': true,
          'post_setup_started': 'install_x',
        };
      final result = await _repo(server).setEnabled('files', true);
      expect(result.postSetupStarted, isTrue);
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
    });

    test('a flag the re-read does not show is notSaved', () async {
      final server = _Server()..ignoreWrites = true;
      final failure = await _failure(_repo(server).setEnabled('files', true));
      expect(failure.kind, ServerConfigFailureKind.notSaved);
    });

    test('an unknown toolset (400) is rejected', () async {
      final server = _Server()..putStatus = 400;
      final failure = await _failure(_repo(server).setEnabled('nope', true));
      expect(failure.kind, ServerConfigFailureKind.rejected);
      expect(server.requests.map((r) => r.method), ['PUT']);
    });

    test('a read-only repository never reaches the network', () async {
      final server = _Server();
      final failure = await _failure(
        _repo(server, writable: false).setEnabled('files', true),
      );
      expect(failure.kind, ServerConfigFailureKind.readOnly);
      expect(server.requests, isEmpty);
    });

    test('a name that is not a plain toolset name is refused', () async {
      final server = _Server();
      for (final name in const ['', '../config', 'a/b', 'a b', 'x?y=1']) {
        final failure = await _failure(_repo(server).setEnabled(name, true));
        expect(failure.kind, ServerConfigFailureKind.rejected, reason: name);
      }
      expect(server.requests, isEmpty);
    });
  });

  group('detail', () {
    test('config parses providers, env vars with is_set only', () async {
      final server = _Server();
      final config = await _repo(server).config('web');

      expect(config.hasCategory, isTrue);
      expect(config.activeProvider, 'alpha');
      expect(config.providers.map((p) => p.name), ['alpha', 'beta']);
      expect(config.providers.first.isActive, isTrue);
      expect(config.providers.first.envVars.single.key, 'ALPHA_KEY');
      expect(config.providers.first.envVars.single.isSet, isFalse);
      expect(config.providers.last.requiresNousAuth, isTrue);
      expect(server.requests.single.url.path, '/api/tools/toolsets/web/config');
    });

    test('models parses the list and the current one', () async {
      final server = _Server();
      final models = await _repo(server).models('web');

      expect(models.hasModels, isTrue);
      expect(models.current, 'm1');
      expect(models.models.map((m) => m.id), ['m1', 'm2']);
      expect(models.models.last.display, 'Model 2');
    });

    test('choosing a provider: one PUT, then the config again', () async {
      final server = _Server();
      final config = await _repo(server).setProvider('web', 'beta');

      expect(jsonDecode(server.puts.single.body), {'provider': 'beta'});
      expect(server.puts.single.url.path, '/api/tools/toolsets/web/provider');
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(config.activeProvider, 'beta');
    });

    test('a provider the re-read does not show is notSaved', () async {
      final server = _Server()..ignoreWrites = true;
      final failure = await _failure(_repo(server).setProvider('web', 'beta'));
      expect(failure.kind, ServerConfigFailureKind.notSaved);
    });

    test('choosing a model: one PUT, then the models again', () async {
      final server = _Server();
      final models = await _repo(server).setModel('web', 'm2');

      expect(jsonDecode(server.puts.single.body), {'model': 'm2'});
      expect(server.puts.single.url.path, '/api/tools/toolsets/web/model');
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(models.current, 'm2');
    });

    test('a model the re-read does not show is notSaved', () async {
      final server = _Server()..ignoreWrites = true;
      final failure = await _failure(_repo(server).setModel('web', 'm2'));
      expect(failure.kind, ServerConfigFailureKind.notSaved);
    });

    test('credentials go in one PUT and only is_set comes back', () async {
      final server = _Server();
      final config = await _repo(
        server,
      ).saveCredentials('web', {'ALPHA_KEY': 'synthetic-secret-value'});

      expect(server.puts.single.url.path, '/api/tools/toolsets/web/env');
      expect(jsonDecode(server.puts.single.body), {
        'env': {'ALPHA_KEY': 'synthetic-secret-value'},
      });
      expect(config.providers.first.envVars.single.isSet, isTrue);
      expect(config.toString(), isNot(contains('synthetic-secret-value')));
    });

    test('a credential the re-read still shows unset is notSaved', () async {
      final server = _Server()..ignoreWrites = true;
      final failure = await _failure(
        _repo(server).saveCredentials('web', {'ALPHA_KEY': 'v'}),
      );
      expect(failure.kind, ServerConfigFailureKind.notSaved);
    });

    test('empty and blank credentials are not sent', () async {
      final server = _Server();
      final failure = await _failure(
        _repo(server).saveCredentials('web', {'ALPHA_KEY': '  '}),
      );
      expect(failure.kind, ServerConfigFailureKind.rejected);
      expect(server.requests, isEmpty);
    });

    test('profile on every request', () async {
      final server = _Server();
      final repo = _repo(server, profile: 'work');
      await repo.setProvider('web', 'beta');
      await repo.setModel('web', 'm2');
      for (final request in server.requests) {
        expect(request.url.queryParameters, {'profile': 'work'});
      }
    });
  });

  group('failures', () {
    for (final entry in {
      401: ServerConfigFailureKind.authentication,
      403: ServerConfigFailureKind.permissionDenied,
      404: ServerConfigFailureKind.unsupported,
      500: ServerConfigFailureKind.remote,
    }.entries) {
      test('HTTP ${entry.key} on a write is ${entry.value.name}', () async {
        final server = _Server()..putStatus = entry.key;
        final failure = await _failure(_repo(server).setEnabled('files', true));
        expect(failure.kind, entry.value);
      });
    }

    test('a write that went through but cannot be re-read is '
        'unconfirmed', () async {
      final repo = ServerToolsetsRepository(
        DashboardClient(
          host: 'hermes.example.test',
          port: 9119,
          manualToken: 'synthetic-token',
          httpClientOverride: MockClient(
            (request) async => request.method == 'PUT'
                ? http.Response(jsonEncode({'ok': true}), 200)
                : http.Response('{}', 500),
          ),
        ),
      );
      final failure = await _failure(repo.setEnabled('files', true));
      expect(failure.kind, ServerConfigFailureKind.unconfirmed);
    });
  });

  test('the model parses defensively', () {
    final row = ServerToolset.tryParse({
      'name': 'x',
      'label': null,
      'tools': ['a', 3, null, 'b'],
      'enabled': 'yes',
    });
    expect(row, isNotNull);
    expect(row!.label, 'x');
    expect(row.tools, ['a', 'b']);
    expect(row.enabled, isFalse);
    expect(ServerToolset.tryParse('nope'), isNull);
  });
}
