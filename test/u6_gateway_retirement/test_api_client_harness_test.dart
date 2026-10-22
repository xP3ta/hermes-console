import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fake_dashboard_sessions.dart';
import '../support/test_api_client.dart';

/// The shared harness that replaces clients built without a Dashboard
/// (PLAN-RETIRO-RAMAS-SIN-DASHBOARD C1). Until the no-Dashboard branches are
/// removed, this file still builds one legacy client to prove the harness
/// reads the same fake the same way; that half leaves with them.
const _base = 'http://127.0.0.1:8642';

List<Map<String, dynamic>> _rows(int count) => [
  for (var i = 1; i <= count; i++)
    {'id': i, 'role': i.isOdd ? 'user' : 'assistant', 'content': 'm$i'},
];

/// A fake written for the legacy transport: messages under [key] (`data`, as
/// the API server, or `messages`, as the Dashboard) and the detail wrapped in
/// `session`. It never looks at headers or ports.
http.Client _legacyFake(
  String key,
  List<http.Request> seen, {
  int status = 200,
}) => MockClient((request) async {
  seen.add(request);
  if (status != 200) return http.Response('{}', status);
  final url = request.url;
  if (url.path == '/api/sessions/s/messages') {
    final rows = _rows(3);
    final query = url.queryParameters;
    return http.Response(
      jsonEncode({
        'session_id': 's-tip',
        key: rows,
        'pagination': {
          'limit': int.parse(query['limit']!),
          'offset': int.parse(query['offset']!),
          'order': 'latest',
          'returned': rows.length,
        },
      }),
      200,
    );
  }
  if (url.path == '/api/sessions/s') {
    return http.Response(
      jsonEncode({
        'session': {'id': 's', 'title': 'Stored', 'started_at': 1},
      }),
      200,
    );
  }
  return http.Response('{}', 404);
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('testApiClient', () {
    for (final key in ['data', 'messages']) {
      test('reads a legacy fake ($key) exactly like the legacy '
          'transport', () async {
        final legacySeen = <http.Request>[];
        final harnessSeen = <http.Request>[];
        final legacy = ApiClient(
          baseUrl: _base,
          apiKey: 'k',
          httpClient: _legacyFake(key, legacySeen),
        );
        final harness = testApiClient(
          baseUrl: _base,
          httpClient: _legacyFake(key, harnessSeen),
        );
        addTearDown(legacy.close);
        addTearDown(harness.close);

        final a = await legacy.getMessagesPage('s');
        final b = await harness.getMessagesPage('s');
        expect(b.messages, a.messages);
        expect(b.offset, a.offset);
        expect(b.limit, a.limit);
        expect(b.returned, a.returned);
        expect(b.hasPagination, a.hasPagination);
        expect(b.resolvedTipId, a.resolvedTipId);
        expect(b.coverage, a.coverage);
        expect(await harness.getMessages('s'), await legacy.getMessages('s'));
        final rowA = await legacy.getSession('s');
        final rowB = await harness.getSession('s');
        expect(rowB.id, rowA.id);
        expect(rowB.title, rowA.title);

        // Same paths and queries on the same origin.
        expect(
          harnessSeen.map((r) => r.url.toString()),
          legacySeen.map((r) => r.url.toString()),
        );
      });
    }

    test('a compacted lineage proves full coverage on both '
        'transports', () async {
      http.Client fake() => MockClient(
        (request) async => http.Response(
          jsonEncode({
            'session_id': 's',
            'messages': [
              {
                'id': 1,
                'role': 'user',
                'content': 'archived',
                'compacted': true,
                'active': false,
              },
              ..._rows(2),
            ],
            'pagination': {
              'limit': 120,
              'offset': 0,
              'order': 'latest',
              'returned': 3,
            },
          }),
          200,
        ),
      );
      final legacy = ApiClient(baseUrl: _base, apiKey: 'k', httpClient: fake());
      final harness = testApiClient(baseUrl: _base, httpClient: fake());
      addTearDown(legacy.close);
      addTearDown(harness.close);

      final a = await legacy.getMessagesPage('s');
      final b = await harness.getMessagesPage('s');
      expect(a.coverage, {CoreReadCoverage.full});
      expect(b.coverage, a.coverage);
      expect(b.messages, a.messages);
    });

    test('a closed client refuses a later read before it reaches the '
        'fake', () async {
      var reads = 0;
      final harness = testApiClient(
        baseUrl: _base,
        httpClient: MockClient((_) async {
          reads += 1;
          return http.Response('{}', 500);
        }),
      );
      harness.close();

      await expectLater(
        harness.getMessagesPage('s'),
        throwsA(isA<http.ClientException>()),
      );
      expect(reads, 0);
    });

    test('answerAfterClose keeps sending to the fake after close, like the '
        'legacy transport', () async {
      var legacyReads = 0;
      var harnessReads = 0;
      final legacy = ApiClient(
        baseUrl: _base,
        apiKey: 'k',
        httpClient: MockClient((_) async {
          legacyReads += 1;
          return http.Response('{}', 500);
        }),
      );
      final harness = testApiClient(
        baseUrl: _base,
        answerAfterClose: true,
        httpClient: MockClient((_) async {
          harnessReads += 1;
          return http.Response('{}', 500);
        }),
      );
      legacy.close();
      harness.close();
      final matcher = throwsA(
        isA<CoreReadException>().having(
          (e) => e.kind,
          'kind',
          CoreReadErrorKind.temporarilyUnavailable,
        ),
      );

      await expectLater(legacy.getMessagesPage('s'), matcher);
      await expectLater(harness.getMessagesPage('s'), matcher);
      expect(legacyReads, 1);
      expect(harnessReads, 1);
    });

    test('sends the Dashboard session token, never an API-key bearer, and '
        'never scrapes the page first', () async {
      final seen = <http.Request>[];
      final harness = testApiClient(
        baseUrl: _base,
        httpClient: _legacyFake('messages', seen),
      );
      addTearDown(harness.close);

      await harness.getMessagesPage('s');
      await harness.getSession('s');

      expect(seen, isNotEmpty);
      expect(seen.map((r) => r.url.path), isNot(contains('/')));
      for (final request in seen) {
        expect(request.headers['X-Hermes-Session-Token'], testDashboardToken);
        expect(request.headers['Authorization'], isNull);
      }
    });

    for (final (status, kind) in [
      (400, CoreReadErrorKind.malformed),
      (404, CoreReadErrorKind.notFound),
      (503, CoreReadErrorKind.temporarilyUnavailable),
      (401, CoreReadErrorKind.auth),
    ]) {
      test('a $status page keeps its CORE-READ kind ($kind)', () async {
        final legacySeen = <http.Request>[];
        final harnessSeen = <http.Request>[];
        final legacy = ApiClient(
          baseUrl: _base,
          apiKey: 'k',
          httpClient: _legacyFake('data', legacySeen, status: status),
        );
        final harness = testApiClient(
          baseUrl: _base,
          httpClient: _legacyFake('data', harnessSeen, status: status),
        );
        addTearDown(legacy.close);
        addTearDown(harness.close);
        final matcher = throwsA(
          isA<CoreReadException>().having((e) => e.kind, 'kind', kind),
        );

        await expectLater(legacy.getMessagesPage('s'), matcher);
        await expectLater(harness.getMessagesPage('s'), matcher);
        // The Dashboard retries a 401 once with its session; nothing else
        // is retried.
        expect(harnessSeen, hasLength(status == 401 ? 2 : 1));
      });
    }
  });

  group('FakeDashboardSessions', () {
    test('serves lists, details, pages and deletes per profile in the '
        'reference shapes', () async {
      final fake = FakeDashboardSessions(profiles: {'social-writer'});
      for (var i = 0; i < 130; i++) {
        fake.putSession({
          'id': 'd$i',
          'title': 'Default $i',
          'started_at': 1790000000 + i,
          'last_active': 1790000000 + i,
        });
      }
      fake
        ..putSession({
          'id': 'w1',
          'title': 'Writer',
          'started_at': 1790000500,
        }, profile: 'social-writer')
        ..putMessages('w1', _rows(250), profile: 'social-writer');
      final client = testApiClient(httpClient: fake.client());
      addTearDown(client.close);

      final defaults = await client.getSessions();
      expect(defaults, hasLength(130));
      expect(defaults.first.id, 'd129');
      final writer = await client.getSessions(profile: 'social-writer');
      expect(writer.map((s) => s.id), ['w1']);
      expect(writer.single.profile, 'social-writer');

      expect(
        (await client.getSession('w1', profile: 'social-writer')).title,
        'Writer',
      );
      final newest = await client.getMessagesPage(
        'w1',
        profile: 'social-writer',
      );
      expect(newest.messages.first['id'], 131);
      expect(newest.messages.last['id'], 250);
      final older = await client.getMessagesPage(
        'w1',
        profile: 'social-writer',
        offset: 120,
      );
      expect(older.messages.first['id'], 11);
      expect(
        (await client.getMessages('w1', profile: 'social-writer')).length,
        250,
      );
      await expectLater(
        client.getMessagesPage('w1'),
        throwsA(
          isA<CoreReadException>().having(
            (e) => e.kind,
            'kind',
            CoreReadErrorKind.notFound,
          ),
        ),
      );
      await expectLater(
        client.getMessagesPage('w1', profile: 'other'),
        throwsA(isA<CoreReadException>()),
      );

      expect(
        await client.deleteSession('w1', profile: 'social-writer'),
        isTrue,
      );
      expect(fake.deleted, [(profile: 'social-writer', sessionId: 'w1')]);
      expect(await client.healthReachable(), isTrue);

      expect(fake.outsideApi, isEmpty);
      expect(fake.gatewayShaped, isEmpty);
      expect(
        fake.requests.where((r) => r.url.path == '/api/sessions').map(
          (r) => int.parse(r.url.queryParameters['limit']!),
        ),
        everyElement(lessThanOrEqualTo(100)),
      );
    });

    test('records a Gateway-shaped request', () async {
      final fake = FakeDashboardSessions();
      final legacy = ApiClient(
        baseUrl: 'http://127.0.0.1:9119',
        apiKey: 'k',
        httpClient: fake.client(),
      );
      addTearDown(legacy.close);
      await expectLater(
        legacy.getMessagesPage('s', profile: 'social-writer'),
        throwsA(anything),
      );
      expect(
        fake.outsideApi.single.path,
        '/p/social-writer/api/sessions/s/messages',
      );
      expect(fake.gatewayShaped, isNotEmpty);
    });
  });
}
