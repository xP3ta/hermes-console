import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_session_timeline.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

DashboardClient _client(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = DashboardClient(
    host: 'hermes.example.test',
    manualToken: 'token',
    httpClientOverride: MockClient(handler),
  );
  addTearDown(client.close);
  return client;
}

void main() {
  group('parseSessionTimelinePage', () {
    test('reads entries and pagination', () {
      final page = parseSessionTimelinePage({
        'entries': [
          {'row_id': 4, 'preview': 'cuatro', 'timestamp': 1.5},
          {'row_id': 9, 'preview': 'nueve'},
        ],
        'pagination': {
          'limit': 500,
          'after_row_id': null,
          'returned': 2,
          'total': 9,
          'has_more': true,
          'next_cursor': 9,
        },
      });
      expect(page, isNotNull);
      expect(page!.entries.map((e) => e.rowId), [4, 9]);
      expect(page.entries.map((e) => e.preview), ['cuatro', 'nueve']);
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 9);
    });

    test('drops rows without a numeric id or a text preview', () {
      final page = parseSessionTimelinePage({
        'entries': [
          {'row_id': '4', 'preview': 'texto'},
          {'row_id': 5, 'preview': null},
          {'row_id': null, 'preview': 'x'},
          'basura',
          {'row_id': 6, 'preview': 'bien'},
        ],
      });
      expect(page!.entries.map((e) => e.rowId), [6]);
    });

    test('a missing pagination block means a complete page', () {
      final page = parseSessionTimelinePage({'entries': <Object?>[]});
      expect(page!.hasMore, isFalse);
      expect(page.nextCursor, isNull);
    });

    test('has_more without a usable cursor cannot continue', () {
      final page = parseSessionTimelinePage({
        'entries': <Object?>[],
        'pagination': {'has_more': true, 'next_cursor': null},
      });
      expect(page!.hasMore, isFalse);
    });

    test('a body without an entries list is not a timeline', () {
      expect(parseSessionTimelinePage({'messages': []}), isNull);
      expect(parseSessionTimelinePage(null), isNull);
    });
  });

  group('DashboardClient.getSessionTimelinePage', () {
    test('requests one bounded page scoped to the profile', () async {
      Uri? requested;
      final client = _client((request) async {
        requested = request.url;
        return http.Response('{"entries":[]}', 200);
      });
      final page = await client.getSessionTimelinePage(
        'sess 1',
        profile: 'research',
      );
      expect(page, isNotNull);
      expect(requested!.path, '/api/sessions/sess%201/timeline');
      expect(requested!.queryParameters['limit'], '500');
      expect(requested!.queryParameters['profile'], 'research');
      expect(requested!.queryParameters.containsKey('after_row_id'), isFalse);
    });

    test('passes the cursor on later pages and omits an empty profile', () async {
      Uri? requested;
      final client = _client((request) async {
        requested = request.url;
        return http.Response('{"entries":[]}', 200);
      });
      await client.getSessionTimelinePage('s', afterRowId: 120);
      expect(requested!.queryParameters['after_row_id'], '120');
      expect(requested!.queryParameters.containsKey('profile'), isFalse);
    });

    test('404 and 405 mean the route is not offered', () async {
      for (final status in [404, 405]) {
        final client = _client((_) async => http.Response('nope', status));
        expect(await client.getSessionTimelinePage('s'), isNull);
      }
    });

    test('other failures are not swallowed', () async {
      final client = _client((_) async => http.Response('boom', 500));
      expect(
        client.getSessionTimelinePage('s'),
        throwsA(isA<DashboardHttpException>()),
      );
    });
  });
}
