import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

SavedConnection _connection() => SavedConnection(
  id: 'diagnostics-test',
  label: 'Diagnostics test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-token',
  onDeviceLoopback: true,
);

String _capabilities({
  bool? skillsToggle,
  bool? pluginsApi,
  Object? pluginsEndpoint,
}) {
  final features = <String, Object?>{
    'skills_api': true,
    'chat_completions': true,
  };
  if (skillsToggle != null) features['skills_toggle'] = skillsToggle;
  if (pluginsApi != null) features['plugins_api'] = pluginsApi;
  final endpoints = <String, Object?>{};
  if (pluginsEndpoint != null) endpoints['plugins'] = pluginsEndpoint;
  return jsonEncode({
    'object': 'hermes.api_server.capabilities',
    'features': features,
    'endpoints': endpoints,
  });
}

Future<({CapabilityMatrix matrix, List<http.Request> requests})> _run({
  required int capabilitiesStatus,
  required String capabilitiesBody,
}) async {
  final requests = <http.Request>[];
  final diagnostics = ConnectionDiagnostics(
    httpClient: MockClient((request) async {
      requests.add(request);
      switch (request.url.path) {
        case '/health':
          return http.Response(jsonEncode({'version': '0.20.4'}), 200);
        case '/api/sessions':
        case '/v1/models':
        case '/v1/skills':
        case '/v1/toolsets':
        case '/v1/plugins':
        case '/v9/server-declared/plugins':
          return http.Response('{}', 200);
        case '/v1/capabilities':
          return http.Response(capabilitiesBody, capabilitiesStatus);
        default:
          return http.Response('{}', 404);
      }
    }),
  );

  try {
    final (gateway, version, serverCaps) = await diagnostics.probeGateway(
      _connection(),
    );
    return (
      matrix: diagnostics.buildMatrix(
        gateway,
        const [],
        version,
        serverCaps: serverCaps,
      ),
      requests: requests,
    );
  } finally {
    diagnostics.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('declared true and false capabilities are authoritative', () async {
    for (final declared in [true, false]) {
      final result = await _run(
        capabilitiesStatus: 200,
        capabilitiesBody: _capabilities(
          skillsToggle: declared,
          pluginsApi: declared,
        ),
      );
      final expected = declared ? CapState.yes : CapState.no;

      expect(result.matrix.skillsToggle, expected);
      expect(result.matrix.pluginsSupported, expected);
      expect(result.matrix.isServerSourced('skillsToggle'), isTrue);
      expect(result.matrix.isServerSourced('pluginsSupported'), isTrue);
      expect(result.matrix.skillsInstall, CapState.unknown);
    }
  });

  test(
    'absent capabilities fall back without enabling skills toggle',
    () async {
      final result = await _run(
        capabilitiesStatus: 200,
        capabilitiesBody: _capabilities(),
      );

      expect(result.matrix.skillsToggle, CapState.unknown);
      expect(result.matrix.pluginsSupported, CapState.yes);
      expect(result.matrix.skillsInstall, CapState.unknown);
      expect(result.matrix.isServerSourced('skillsToggle'), isFalse);
    },
  );

  test(
    '404 and malformed capabilities use the safe plugins GET fallback',
    () async {
      for (final response in [
        (404, '{}'),
        (200, '{not-json'),
        (
          200,
          jsonEncode({
            'object': 'other.contract',
            'features': {'skills_toggle': true, 'plugins_api': true},
          }),
        ),
      ]) {
        final result = await _run(
          capabilitiesStatus: response.$1,
          capabilitiesBody: response.$2,
        );

        expect(result.matrix.skillsToggle, CapState.unknown);
        expect(result.matrix.pluginsSupported, CapState.yes);
        expect(
          result.requests.where((request) => request.url.path == '/v1/plugins'),
          hasLength(1),
        );
      }
    },
  );

  test(
    'uses a declared same-origin plugins GET path without hard-coding',
    () async {
      final result = await _run(
        capabilitiesStatus: 200,
        capabilitiesBody: _capabilities(
          pluginsApi: true,
          pluginsEndpoint: const {
            'method': 'GET',
            'path': '/v9/server-declared/plugins',
          },
        ),
      );

      expect(
        result.requests.map((request) => request.url.path),
        contains('/v9/server-declared/plugins'),
      );
      expect(
        result.requests.map((request) => request.url.path),
        isNot(contains('/v1/plugins')),
      );
    },
  );

  test('rejects mutating and cross-origin endpoint metadata', () async {
    for (final endpoint in [
      const {'method': 'PUT', 'path': '/v1/plugins'},
      const {'method': 'GET', 'path': 'https://evil.example/v1/plugins'},
    ]) {
      final result = await _run(
        capabilitiesStatus: 200,
        capabilitiesBody: _capabilities(
          pluginsApi: true,
          pluginsEndpoint: endpoint,
        ),
      );

      expect(
        result.requests.map((request) => request.url.host),
        everyElement('127.0.0.1'),
      );
      expect(
        result.requests.map((request) => request.url.path),
        isNot(contains('/v1/plugins')),
      );
    }
  });

  test('gateway diagnostics issue only safe GET requests', () async {
    final result = await _run(
      capabilitiesStatus: 200,
      capabilitiesBody: _capabilities(skillsToggle: true, pluginsApi: true),
    );

    expect(result.requests.map((request) => request.method).toSet(), {'GET'});
    expect(
      result.requests.map((request) => request.url.path),
      isNot(contains('/v1/skills/toggle')),
    );
  });
}
