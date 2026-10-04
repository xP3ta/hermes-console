// A scripted Dashboard for the toolsets endpoints: the list, one toolset's
// config and models, and the writes, with a switch to make the server ignore
// them. Shared by the repository and the screen tests.
import 'dart:convert';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> fakeToolset(
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

final class FakeToolsetsServer {
  final List<http.Request> requests = [];
  List<Map<String, dynamic>> toolsets = [
    fakeToolset('web', enabled: true),
    fakeToolset('files'),
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
