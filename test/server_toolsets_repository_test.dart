// Toolsets of Settings › Advanced › Tools: list, enable, provider, model and
// credentials, each change confirmed by re-reading the server.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/services/server_toolsets_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class _Server {
  List<Map<String, dynamic>> toolsets = [
    {
      'name': 'web',
      'label': 'Web',
      'description': 'Search the web',
      'platform': 'cli',
      'enabled': true,
      'available': true,
      'configured': true,
      'tools': ['web_search'],
    },
    {
      'name': 'browser',
      'label': 'Browser',
      'description': null,
      'enabled': false,
      'available': true,
      'configured': false,
      'tools': <String>[],
    },
  ];
  Map<String, dynamic> config = {
    'name': 'web',
    'has_category': true,
    'providers': [
      {
        'name': 'Exa',
        'badge': 'paid',
        'tag': null,
        'env_vars': [
          {
            'key': 'EXA_API_KEY',
            'prompt': 'Exa key',
            'url': 'https://exa.example/keys',
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
        'name': 'Nous',
        'badge': null,
        'tag': null,
        'env_vars': <Map<String, dynamic>>[],
        'post_setup': null,
        'requires_nous_auth': true,
        'is_active': false,
        'status': 'needs_auth',
      },
    ],
    'active_provider': 'Exa',
  };
  Map<String, dynamic> models = {
    'name': 'web',
    'has_models': true,
    'provider': 'Exa',
    'models': [
      {'id': 'fast', 'display': 'Fast', 'speed': null, 'strengths': null},
      {'id': 'deep', 'display': 'Deep', 'speed': null, 'strengths': null},
    ],
    'current': 'fast',
    'default': 'fast',
  };

  final requests = <http.Request>[];
  bool wrapList = false;
  bool applyWrites = true;
  Object? postSetupStarted;
  int putStatus = 200;
  Completer<void>? holdPut;

  List<http.Request> get puts => [
    for (final r in requests)
      if (r.method == 'PUT') r,
  ];

  DashboardClient client() => DashboardClient(
    host: '127.0.0.1',
    port: 9119,
    manualToken: 'synthetic-dashboard-token',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (request.method == 'GET') {
        if (path == '/api/tools/toolsets') {
          return http.Response(
            jsonEncode(wrapList ? {'data': toolsets} : toolsets),
            200,
          );
        }
        if (path == '/api/tools/toolsets/web/config') {
          return http.Response(jsonEncode(config), 200);
        }
        if (path == '/api/tools/toolsets/web/models') {
          return http.Response(jsonEncode(models), 200);
        }
        return http.Response('{}', 404);
      }
      if (request.method == 'PUT') {
        await holdPut?.future;
        if (putStatus != 200) return http.Response('{}', putStatus);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final name = path.split('/')[4];
        if (path == '/api/tools/toolsets/$name') {
          if (applyWrites) {
            for (final t in toolsets) {
              if (t['name'] == name) t['enabled'] = body['enabled'];
            }
          }
          return http.Response(
            jsonEncode({
              'ok': true,
              'name': name,
              'enabled': body['enabled'],
              'post_setup_started': postSetupStarted,
            }),
            200,
          );
        }
        if (path.endsWith('/provider')) {
          if (applyWrites) {
            config['active_provider'] = body['provider'];
            for (final p in config['providers'] as List) {
              (p as Map<String, dynamic>)['is_active'] =
                  p['name'] == body['provider'];
            }
          }
          return http.Response(
            jsonEncode({
              'ok': true,
              'name': name,
              'provider': body['provider'],
              'needs_nous_auth': body['provider'] == 'Nous',
            }),
            200,
          );
        }
        if (path.endsWith('/model')) {
          if (applyWrites) models['current'] = body['model'];
          return http.Response(
            jsonEncode({'ok': true, 'name': name, 'model': body['model']}),
            200,
          );
        }
        if (path.endsWith('/env')) {
          final env = body['env'] as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'ok': true,
              'name': name,
              'saved': env.keys.toList(),
              'skipped': <String>[],
              'is_set': {for (final k in env.keys) k: true},
            }),
            200,
          );
        }
      }
      return http.Response('{}', 404);
    }),
  );
}

ServerToolsetsRepository _repo(
  _Server server, {
  String? profile,
  bool writable = true,
}) => ServerToolsetsRepository(
  server.client(),
  profile: profile,
  writable: writable,
);

void main() {
  group('list', () {
    test('reads the toolsets with null in optional fields', () async {
      final rows = (await _repo(_Server()).list())!;
      expect(rows.map((t) => t.name), ['web', 'browser']);
      expect(rows.first.label, 'Web');
      expect(rows.first.enabled, isTrue);
      expect(rows.last.description, isNull);
      expect(rows.last.configured, isFalse);
    });

    test('accepts the list wrapped as {data: [...]}', () async {
      final server = _Server()..wrapList = true;
      expect((await _repo(server).list())!, hasLength(2));
    });

    test('the profile travels in the query', () async {
      final server = _Server();
      await _repo(server, profile: 'work').list();
      expect(server.requests.single.url.queryParameters['profile'], 'work');
    });

    test('a read answered after a profile change is discarded', () async {
      final server = _Server();
      var current = true;
      final pending = _repo(server).list(isCurrent: () => current);
      current = false;
      expect(await pending, isNull);
    });
  });

  group('setEnabled', () {
    test('one PUT, one re-read of the list', () async {
      final server = _Server();
      final result = await _repo(server).setEnabled('browser', true);
      expect(result.outcome, ServerConfigSaveOutcome.confirmed);
      expect(result.postSetupStarted, isNull);
      expect(server.requests.map((r) => '${r.method} ${r.url.path}').toList(), [
        'PUT /api/tools/toolsets/browser',
        'GET /api/tools/toolsets',
      ]);
      expect(jsonDecode(server.puts.single.body), {'enabled': true});
    });

    test('post_setup_started is reported, never tracked', () async {
      final server = _Server()..postSetupStarted = 'install_browser';
      final result = await _repo(server).setEnabled('browser', true);
      expect(result.postSetupStarted, 'install_browser');
      expect(server.requests, hasLength(2), reason: 'no polling');
    });

    test('a re-read that disagrees is a mismatch', () async {
      final server = _Server()..applyWrites = false;
      final result = await _repo(server).setEnabled('browser', true);
      expect(result.outcome, ServerConfigSaveOutcome.mismatch);
      expect(result.enabled, isFalse);
    });

    test('read-only never reaches the network', () async {
      final server = _Server();
      await expectLater(
        _repo(server, writable: false).setEnabled('web', false),
        throwsA(isA<ServerConfigException>()),
      );
      expect(server.requests, isEmpty);
    });

    test('a 400 for an unknown toolset is a failure, not a success', () async {
      final server = _Server()..putStatus = 400;
      await expectLater(
        _repo(server).setEnabled('nope', true),
        throwsA(isA<ServerConfigException>()),
      );
    });

    test('an answer after the profile changed is stale', () async {
      final server = _Server()..holdPut = Completer<void>();
      var current = true;
      final pending = _repo(
        server,
      ).setEnabled('browser', true, isCurrent: () => current);
      current = false;
      server.holdPut!.complete();
      expect((await pending).outcome, ServerConfigSaveOutcome.stale);
    });
  });

  group('config, provider, model and credentials', () {
    test('reads providers with status and the active one', () async {
      final config = (await _repo(_Server()).config('web'))!;
      expect(config.hasCategory, isTrue);
      expect(config.activeProvider, 'Exa');
      expect(config.providers.map((p) => p.name), ['Exa', 'Nous']);
      expect(config.providers.first.isActive, isTrue);
      expect(config.providers.last.requiresNousAuth, isTrue);
      expect(config.providers.first.envVars.single.key, 'EXA_API_KEY');
      expect(config.providers.first.envVars.single.isSet, isFalse);
    });

    test('choosing a provider is confirmed by re-reading the config', () async {
      final server = _Server();
      final result = await _repo(server).setProvider('web', 'Nous');
      expect(result.outcome, ServerConfigSaveOutcome.confirmed);
      expect(result.needsNousAuth, isTrue);
      expect(jsonDecode(server.puts.single.body), {'provider': 'Nous'});
      expect(server.requests.last.url.path, '/api/tools/toolsets/web/config');
    });

    test('reads the models and the current one', () async {
      final models = (await _repo(_Server()).models('web'))!;
      expect(models.hasModels, isTrue);
      expect(models.current, 'fast');
      expect(models.models.map((m) => m.id), ['fast', 'deep']);
    });

    test('choosing a model is confirmed by re-reading the models', () async {
      final server = _Server();
      final result = await _repo(server).setModel('web', 'deep');
      expect(result.outcome, ServerConfigSaveOutcome.confirmed);
      expect(jsonDecode(server.puts.single.body), {'model': 'deep'});
      expect(server.requests.last.url.path, '/api/tools/toolsets/web/models');
    });

    test('credentials go out once and only their names come back', () async {
      final server = _Server();
      final set = await _repo(server).saveEnv('web', {'EXA_API_KEY': 's3cret'});
      expect(set, {'EXA_API_KEY': true});
      expect(jsonDecode(server.puts.single.body), {
        'env': {'EXA_API_KEY': 's3cret'},
      });
      // The value is not read back by anything.
      expect(server.requests, hasLength(1));
    });
  });
}
