import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('named profile prefixes every Gateway run REST operation', () async {
    final requests = <http.Request>[];
    final client = ApiClient(
      baseUrl: 'https://hermes.example',
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST' && request.url.path.endsWith('/v1/runs')) {
          return http.Response(jsonEncode({'run_id': 'run/1'}), 202);
        }
        if (request.url.path.endsWith('/events')) {
          return http.Response('data: {"event":"run.completed"}\n\n', 200);
        }
        return http.Response(jsonEncode({'status': 'running'}), 200);
      }),
    );

    final runId = await client.startRun(input: 'do it', profile: 'team_alpha');
    await client.getRun(runId, profile: 'team_alpha');
    await client.resolveRunApproval(runId, 'once', profile: 'team_alpha');
    await client.stopRun(runId, profile: 'team_alpha');
    await client.streamRunEvents(
      runId,
      profile: 'team_alpha',
      onEvent: (_) {},
      onDone: () {},
      onError: fail,
    );

    expect(
      requests.map((request) => request.url.toString()),
      everyElement(contains('/p/team_alpha/')),
    );
    final createBody = jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect(createBody.containsKey('profile'), isFalse);
    client.close();
  });

  test(
    'named profile prefixes session detail message delete and fork routes',
    () async {
      final requests = <http.Request>[];
      final client = ApiClient(
        baseUrl: 'https://hermes.example',
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/messages')) {
            return http.Response(jsonEncode({'data': <Object>[]}), 200);
          }
          if (request.method == 'DELETE') {
            return http.Response(jsonEncode({'deleted': true}), 200);
          }
          return http.Response(
            jsonEncode({
              'session': {
                'id': 'session/1',
                'title': 'Scoped',
                'started_at': 1,
              },
            }),
            200,
          );
        }),
      );

      await client.getSession('session/1', profile: 'team_alpha');
      await client.getMessages('session/1', profile: 'team_alpha');
      await client.getMessagesPage('session/1', profile: 'team_alpha');
      await client.deleteSession('session/1', profile: 'team_alpha');
      await client.forkSession('session/1', profile: 'team_alpha');

      expect(
        requests.map((request) => request.url.toString()),
        everyElement(contains('/p/team_alpha/api/sessions/session%2F1')),
      );
      client.close();
    },
  );

  test('named profile prefixes the Gateway session inventory route', () async {
    late Uri requested;
    final client = ApiClient(
      baseUrl: 'https://hermes.example',
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        requested = request.url;
        return http.Response(jsonEncode({'data': <Object>[]}), 200);
      }),
    );

    await client.getSessions(includeChildren: true, profile: 'team_alpha');

    expect(requested.path, '/p/team_alpha/api/sessions');
    expect(requested.queryParameters, {
      'limit': '200',
      'offset': '0',
      'include_children': 'true',
    });
    client.close();
  });

  test('named profile rejects a conflicting Gateway session owner', () async {
    final client = ApiClient(
      baseUrl: 'https://hermes.example',
      apiKey: 'fixture-token',
      httpClient: MockClient((_) async {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'session-1',
                'title': 'Wrong owner',
                'started_at': 1,
                'profile': 'other_team',
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    await expectLater(
      client.getSessions(profile: 'team_alpha'),
      throwsA(isA<FormatException>()),
    );
  });

  test('Gateway profile routing uses the upstream profile-name grammar', () {
    expect(
      ApiClient.profileEndpoint('api/sessions', profile: 'ops-2_alpha'),
      'p/ops-2_alpha/api/sessions',
    );
    for (final invalid in const ['../other', 'team alpha', 'UPPER', 'a.b']) {
      expect(
        () => ApiClient.profileEndpoint('api/sessions', profile: invalid),
        throwsArgumentError,
        reason: invalid,
      );
    }
  });

  test(
    'default and empty profiles preserve unprefixed Gateway routes',
    () async {
      final requests = <http.Request>[];
      final client = ApiClient(
        baseUrl: 'https://hermes.example',
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode({'status': 'running'}), 200);
        }),
      );

      await client.getRun('run-1');
      await client.getRun('run-2', profile: 'default');
      await client.getRun('run-3', profile: '  ');

      expect(requests.map((request) => request.url.path), [
        '/v1/runs/run-1',
        '/v1/runs/run-2',
        '/v1/runs/run-3',
      ]);
      client.close();
    },
  );
}
