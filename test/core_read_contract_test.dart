import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/test_api_client.dart';

Map<String, dynamic> _sessionRow(String id, {String profile = 'research'}) => {
  'id': id,
  '_lineage_root_id': 'root-$id',
  'title': id,
  'model': 'test-model',
  'source': 'mobile',
  'message_count': 1,
  'started_at': 1,
  'last_active': 2,
  'profile': profile,
};

void main() {
  test(
    'ApiClient sessions traverse the Dashboard total and deduplicate pins',
    () async {
      final requests = <http.Request>[];
      final client = testApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        connectionId: 'connection-a',
        httpClient: MockClient((request) async {
          requests.add(request);
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          // The Dashboard pages 100 rows at a time and back-fills the pinned
          // chat on every page.
          final end = math.min(offset + 100, 201);
          return http.Response(
            jsonEncode({
              'sessions': [
                for (var index = offset; index < end; index++)
                  _sessionRow('session-$index'),
                _sessionRow('pinned'),
              ],
              'total': 202,
              'limit': 100,
              'offset': offset,
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      final sessions = await client.getSessions(profile: 'research');

      expect(sessions, hasLength(202));
      expect(sessions.where((row) => row.id == 'pinned'), hasLength(1));
      expect(requests.map((request) => request.method), everyElement('GET'));
      expect(
        requests.map((request) => request.url.path),
        everyElement('/api/sessions'),
      );
      expect(
        requests.map((request) => request.url.queryParameters['profile']),
        everyElement('research'),
      );
      expect(requests.map((request) => request.url.queryParameters['offset']), [
        '0',
        '100',
        '200',
      ]);
      for (final request in requests) {
        expect(request.headers['X-Hermes-Session-Token'], testDashboardToken);
        expect(request.headers['Authorization'], isNull);
      }
    },
  );

  test('a short page without a total still ends the listing', () async {
    final offsets = <String>[];
    final client = testApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      connectionId: 'connection-a',
      httpClient: MockClient((request) async {
        offsets.add(request.url.queryParameters['offset'] ?? '0');
        return http.Response(
          jsonEncode({
            'sessions': [
              for (var index = 0; index < 99; index++)
                _sessionRow('session-$index'),
            ],
            'limit': 100,
            'offset': 0,
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    expect(await client.getSessions(profile: 'research'), hasLength(99));
    expect(offsets, ['0']);
  });

  test('session pagination fails typed on a repeated page', () async {
    var requests = 0;
    final client = testApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      connectionId: 'connection-a',
      httpClient: MockClient((request) async {
        requests += 1;
        return http.Response(
          jsonEncode({
            'sessions': [_sessionRow('same')],
            'total': 500,
            'limit': 100,
            'offset': int.parse(request.url.queryParameters['offset'] ?? '0'),
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    await expectLater(
      client.getSessions(profile: 'research'),
      throwsA(
        predicate<Object>(
          (error) =>
              error.runtimeType.toString() == 'CoreReadException' &&
              error.toString().contains('paginationStalled'),
        ),
      ),
    );
    expect(requests, 2);
  });

  test('profile auth failure is terminal and never retries unscoped', () async {
    final requests = <http.Request>[];
    final client = testApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      connectionId: 'connection-a',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{"error":"must not be exposed"}', 401);
      }),
    );
    addTearDown(client.close);

    await expectLater(
      client.getSessions(profile: 'research'),
      throwsA(
        predicate<Object>(
          (error) =>
              error.runtimeType.toString() == 'CoreReadException' &&
              error.toString().contains('auth') &&
              !error.toString().contains('must not be exposed'),
        ),
      ),
    );
    // The Dashboard retries a 401 once with its session, then gives up;
    // both reads stay scoped to the profile.
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request.url.path, '/api/sessions');
      expect(request.url.queryParameters['profile'], 'research');
    }
  });

  test(
    'ApiClient messages caps pages and preserves raw cursor plus resolved tip',
    () async {
      late http.Request observed;
      final client = testApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        connectionId: 'connection-a',
        httpClient: MockClient((request) async {
          observed = request;
          return http.Response(
            jsonEncode({
              'session_id': 'resolved-tip',
              'data': [
                {'id': 'visible', 'role': 'user', 'content': 'hello'},
                {'id': 'hidden', 'role': 'system', 'content': 'private'},
              ],
              'pagination': {
                'limit': 500,
                'offset': 0,
                'order': 'latest',
                'returned': 2,
              },
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      final dynamic page = await client.getMessagesPage(
        'stored-chat',
        profile: 'research',
        limit: 900,
      );

      expect(observed.method, 'GET');
      // The Dashboard selects a named profile with `?profile=`.
      expect(observed.url.path, '/api/sessions/stored-chat/messages');
      expect(observed.url.queryParameters, {
        'limit': '500',
        'order': 'latest',
        'offset': '0',
        'include_compacted': 'true',
        'profile': 'research',
      });
      expect(page.returned, 2);
      expect(page.resolvedTipId, 'resolved-tip');
      expect(
        page.coverage.map((Object value) => value.toString()),
        containsAll([
          'CoreReadCoverage.tipOnly',
          'CoreReadCoverage.metadataPartial',
        ]),
      );
    },
  );

  test(
    'ApiClient messages request canonical compacted display history',
    () async {
      late http.Request observed;
      final client = testApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        connectionId: 'connection-a',
        httpClient: MockClient((request) async {
          observed = request;
          return http.Response(
            jsonEncode({
              'session_id': 'stored-chat',
              'messages': const [
                {'id': 'old-q', 'role': 'user', 'content': 'old q'},
                {'id': 'old-a', 'role': 'assistant', 'content': 'old a'},
                {'id': 'summary', 'role': 'system', 'content': 'summary'},
                {'id': 'current-q', 'role': 'user', 'content': 'Todavía?'},
                {'id': 'current-a', 'role': 'assistant', 'content': 'GO'},
              ],
              // A transitional response may expose both keys. The current
              // Dashboard key is authoritative and must not be combined with
              // the legacy list.
              'data': const [
                {'id': 'legacy-only', 'role': 'user', 'content': 'duplicate'},
              ],
              'pagination': const {
                'limit': 120,
                'offset': 0,
                'order': 'latest',
                'returned': 5,
              },
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      final page = await client.getMessagesPage('stored-chat');

      expect(observed.url.queryParameters, {
        'limit': '120',
        'order': 'latest',
        'offset': '0',
        'include_compacted': 'true',
      });
      expect(page.messages.map((message) => message['content']), [
        'old q',
        'old a',
        'summary',
        'Todavía?',
        'GO',
      ]);
    },
  );

  test(
    'resolved descendant compacted rows never claim the whole lineage',
    () async {
      final client = testApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        connectionId: 'connection-a',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'session_id': 'rotated-tip',
              'messages': const [
                {
                  'id': 'tip-compacted',
                  'role': 'user',
                  'content': 'tip-only compacted row',
                  'active': 0,
                  'compacted': 1,
                },
              ],
              'pagination': const {
                'limit': 120,
                'offset': 0,
                'order': 'latest',
                'returned': 1,
              },
            }),
            200,
          ),
        ),
      );
      addTearDown(client.close);

      final page = await client.getMessagesPage('lineage-root');

      expect(page.coverage, contains(CoreReadCoverage.tipOnly));
      expect(page.coverage, isNot(contains(CoreReadCoverage.full)));
    },
  );

  test(
    'CORE-READ scope and identities never collapse stored tip and runtime',
    () {
      const scope = CoreReadScope(
        connectionId: 'connection-a',
        profileOwner: 'research',
      );
      const identity = SessionIdentity(
        logicalRootId: 'root-a',
        storedId: 'stored-a',
        resolvedTipId: 'tip-a',
      );

      final acquired = identity.withRuntime('runtime-a');

      expect(
        scope.cacheKey('messages:stored-a'),
        'connection-a\u001fresearch\u001fmessages:stored-a',
      );
      expect(acquired.logicalRootId, 'root-a');
      expect(acquired.storedId, 'stored-a');
      expect(acquired.resolvedTipId, 'tip-a');
      expect(acquired.runtimeId, 'runtime-a');
      expect(identity.runtimeId, isNull);
    },
  );
}
