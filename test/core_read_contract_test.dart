import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
    'Gateway sessions traverses has_more by raw window and deduplicates pins',
    () async {
      final requests = <http.Request>[];
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        connectionId: 'connection-a',
        httpClient: MockClient((request) async {
          requests.add(request);
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          if (offset == 0) {
            return http.Response(
              jsonEncode({
                'data': [
                  for (var index = 0; index < 200; index++)
                    _sessionRow('session-$index'),
                  _sessionRow('pinned'),
                ],
                'limit': 200,
                'offset': 0,
                'has_more': true,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'data': [_sessionRow('session-200'), _sessionRow('pinned')],
              'limit': 200,
              'offset': 200,
              'has_more': false,
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
      expect(requests.map((request) => request.url.path), [
        '/p/research/api/sessions',
        '/p/research/api/sessions',
      ]);
      expect(requests.map((request) => request.url.queryParameters['offset']), [
        '0',
        '200',
      ]);
      expect(
        requests.map((request) => request.headers['authorization']),
        everyElement('Bearer test-key'),
      );
    },
  );

  test('Gateway session pagination fails typed on a repeated page', () async {
    var requests = 0;
    final client = ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'test-key',
      connectionId: 'connection-a',
      httpClient: MockClient((request) async {
        requests += 1;
        return http.Response(
          jsonEncode({
            'data': [_sessionRow('same')],
            'limit': 200,
            'offset': request.url.queryParameters['offset'] == '200' ? 200 : 0,
            'has_more': true,
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
    final client = ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'test-key',
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
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/p/research/api/sessions');
  });

  test(
    'Gateway messages caps pages and preserves raw cursor plus resolved tip',
    () async {
      late http.Request observed;
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
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
      expect(
        observed.url.path,
        '/p/research/api/sessions/stored-chat/messages',
      );
      expect(observed.url.queryParameters, {
        'limit': '500',
        'order': 'latest',
        'offset': '0',
        'include_compacted': 'true',
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
    'Gateway messages requests canonical compacted display history',
    () async {
      late http.Request observed;
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
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
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
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
