import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/custom_endpoints_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('scopes paths, encodes ids, and never retains key previews', () async {
    final requests = <http.Request>[];
    final client = DashboardClient(
      host: 'hermes.example.test',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'endpoints': [
                {
                  'id': 'edge/a',
                  'name': 'Edge',
                  'base_url': 'https://llm.example.test/v1',
                  'model': 'edge-model',
                  'models': ['edge-model'],
                  'api_mode': 'chat_completions',
                  'discover_models': true,
                  'has_api_key': true,
                  'api_key_preview': r'${EDGE_API_KEY}',
                  'is_current': false,
                  'source': 'providers',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{"ok":true}', 200);
      }),
    );
    addTearDown(client.close);

    final catalog = await client.listCustomEndpoints(profile: 'team one');
    expect(catalog!.endpoints.single.hasApiKey, isTrue);
    expect(
      catalog.endpoints.single.toString(),
      isNot(contains('EDGE_API_KEY')),
    );
    await client.activateCustomEndpoint('edge/a', profile: 'team one');
    await client.deleteCustomEndpoint('edge/a', profile: 'default');

    expect(requests[0].url.path, '/api/providers/custom-endpoints');
    expect(requests[0].url.queryParameters, {'profile': 'team one'});
    expect(
      requests[1].url.path,
      '/api/providers/custom-endpoints/edge%2Fa/activate',
    );
    expect(requests[1].url.queryParameters, {'profile': 'team one'});
    expect(requests[2].url.queryParameters, isEmpty);
  });

  test('draft omits an empty key and includes a typed key', () {
    const empty = CustomEndpointDraft(
      name: 'Edge',
      baseUrl: 'https://llm.example.test/v1',
      model: 'edge-model',
      apiKey: '   ',
    );
    const typed = CustomEndpointDraft(
      name: 'Edge',
      baseUrl: 'https://llm.example.test/v1',
      model: 'edge-model',
      apiKey: 'test-key',
    );

    expect(empty.toJson(), isNot(contains('api_key')));
    expect(typed.toJson()['api_key'], 'test-key');
  });

  test('save and validate send the exact scoped payloads', () async {
    final requests = <http.Request>[];
    final client = DashboardClient(
      host: 'hermes.example.test',
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/validate')) {
          return http.Response(
            '{"ok":true,"reachable":true,"message":"Ready",'
            '"models":[],"model_details":[],"resolved_base_url":""}',
            200,
          );
        }
        return http.Response('{"ok":true,"id":"edge"}', 200);
      }),
    );
    addTearDown(client.close);
    const empty = CustomEndpointDraft(
      name: 'Edge',
      baseUrl: 'https://llm.example.test/v1',
      model: 'edge-model',
      apiKey: '',
    );
    const typed = CustomEndpointDraft(
      name: 'Edge',
      baseUrl: 'https://llm.example.test/v1',
      model: 'edge-model',
      apiKey: 'test-key',
    );

    await client.saveCustomEndpoint(empty, profile: 'default');
    await client.saveCustomEndpoint(typed, profile: 'team one');
    await client.validateCustomEndpoint(empty);

    expect(requests[0].url.queryParameters, isEmpty);
    expect(jsonDecode(requests[0].body), isNot(contains('api_key')));
    expect(requests[1].url.queryParameters, {'profile': 'team one'});
    expect(jsonDecode(requests[1].body)['api_key'], 'test-key');
    expect(requests[2].url.path, '/api/providers/custom-endpoints/validate');
    expect(requests[2].url.queryParameters, isEmpty);
  });

  test('404 and 405 report unsupported', () async {
    for (final status in [404, 405]) {
      final client = DashboardClient(
        host: 'hermes.example.test',
        manualToken: 'test-token',
        httpClientOverride: MockClient((_) async => http.Response('', status)),
      );
      expect(await client.listCustomEndpoints(), isNull);
      client.close();
    }
  });
}
