import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/test_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a named profile selects its session detail, messages and delete with '
    '?profile=',
    () async {
      final requests = <http.Request>[];
      final client = testApiClient(
        baseUrl: 'https://hermes.example',
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/messages')) {
            return http.Response(
              jsonEncode({'session_id': 'session/1', 'messages': <Object>[]}),
              200,
            );
          }
          // No mutation fence: the DELETE goes out as is.
          if (path.endsWith('/mutation-snapshot')) {
            return http.Response('{}', 404);
          }
          if (request.method == 'DELETE') {
            return http.Response(jsonEncode({'ok': true}), 200);
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
      expect(
        await client.deleteSession('session/1', profile: 'team_alpha'),
        isTrue,
      );

      expect(requests, isNotEmpty);
      for (final request in requests) {
        final url = request.url.toString();
        expect(url, contains('/api/sessions/session%2F1'));
        expect(url, isNot(contains('/p/')));
        expect(request.url.queryParameters['profile'], 'team_alpha');
      }
      client.close();
    },
  );

  test('named profile rejects a conflicting session owner', () async {
    final client = testApiClient(
      baseUrl: 'https://hermes.example',
      httpClient: MockClient((_) async {
        return http.Response(
          jsonEncode({
            'sessions': [
              {
                'id': 'session-1',
                'title': 'Wrong owner',
                'started_at': 1,
                'profile': 'other_team',
              },
            ],
            'total': 1,
            'limit': 100,
            'offset': 0,
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
    // As on the server, a display-cased name is that profile's lowercase id.
    expect(
      ApiClient.profileEndpoint('api/sessions', profile: 'UPPER'),
      'p/upper/api/sessions',
    );
    expect(
      ApiClient.profileEndpoint('api/sessions', profile: 'Default'),
      'api/sessions',
    );
    for (final invalid in const ['../other', 'team alpha', 'a.b']) {
      expect(
        () => ApiClient.profileEndpoint('api/sessions', profile: invalid),
        throwsArgumentError,
        reason: invalid,
      );
    }
  });
}
