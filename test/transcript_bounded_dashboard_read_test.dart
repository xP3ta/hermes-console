import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/test_api_client.dart';

/// Every profile reads its transcript from the Dashboard, with the same
/// deadline and the server's 500-row page. A capped read (the export's
/// `maxJsonChars`) must hold while the body arrives, not after it was
/// decoded: the Dashboard inlines images by default, so one page can be far
/// larger than its row count suggests. Default and named profile alike.
void main() {
  for (final profile in [null, 'social-writer']) {
    group('a capped transcript read (profile: ${profile ?? 'default'})', () {
      ApiClient streamingClient({
        required int totalBytes,
        required void Function(int) onChunk,
        int? declaredLength,
        List<Uri>? requests,
      }) => testApiClient(
        httpClient: MockClient.streaming((request, _) async {
          requests?.add(request.url);
          Stream<List<int>> body() async* {
            var sent = 0;
            while (sent < totalBytes) {
              const chunk = 64 * 1024;
              sent += chunk;
              onChunk(sent);
              yield List<int>.filled(chunk, 0x61);
            }
          }

          return http.StreamedResponse(
            body(),
            200,
            contentLength: declaredLength,
          );
        }),
      );

      test('stops reading the body once it passes the cap', () async {
        var delivered = 0;
        final requests = <Uri>[];
        final client = streamingClient(
          totalBytes: 8 * 1024 * 1024,
          onChunk: (n) => delivered = n,
          requests: requests,
        );
        addTearDown(client.close);
        await expectLater(
          client.getMessages('s1', profile: profile, maxJsonChars: 100000),
          throwsA(isA<SessionTranscriptTooLargeException>()),
        );
        // 100 000 chars allow at most 400 000 bytes (+ one chunk in flight).
        expect(delivered, lessThanOrEqualTo(512 * 1024));
        expect(requests.single.path, '/api/sessions/s1/messages');
        expect(requests.single.queryParameters['profile'], profile);
      });

      test('a declared length over the cap is refused without '
          'reading', () async {
        var delivered = 0;
        final client = streamingClient(
          totalBytes: 8 * 1024 * 1024,
          declaredLength: 4 * 1024 * 1024,
          onChunk: (n) => delivered = n,
        );
        addTearDown(client.close);
        await expectLater(
          client.getMessages('s1', profile: profile, maxJsonChars: 100000),
          throwsA(isA<SessionTranscriptTooLargeException>()),
        );
        expect(delivered, lessThanOrEqualTo(64 * 1024));
      });

      test('under the cap it reads the same transcript as an uncapped '
          'read', () async {
        final rows = [
          for (var i = 1; i <= 3; i++)
            {'id': i, 'role': i.isOdd ? 'user' : 'assistant', 'content': 'm$i'},
        ];
        final client = testApiClient(
          httpClient: MockClient((request) async {
            final query = request.url.queryParameters;
            return http.Response(
              jsonEncode({
                'session_id': 's1',
                'messages': rows,
                'pagination': {
                  'limit': int.parse(query['limit']!),
                  'offset': int.parse(query['offset']!),
                  'order': 'latest',
                  'returned': rows.length,
                },
              }),
              200,
            );
          }),
        );
        addTearDown(client.close);
        final capped = await client.getMessages(
          's1',
          profile: profile,
          maxJsonChars: 100000,
        );
        expect(capped, await client.getMessages('s1', profile: profile));
        expect(capped.map((row) => row['id']), [1, 2, 3]);
      });

      test('a capped read keeps the Dashboard retry and error kinds', () async {
        var calls = 0;
        final client = testApiClient(
          httpClient: MockClient((request) async {
            calls += 1;
            // One 401, which the Dashboard retries once, then a 404.
            if (calls == 1) return http.Response('{}', 401);
            return http.Response('{"detail":"Session not found"}', 404);
          }),
        );
        addTearDown(client.close);
        await expectLater(
          client.getMessages('s1', profile: profile, maxJsonChars: 100000),
          throwsA(
            isA<CoreReadException>().having(
              (e) => e.kind,
              'kind',
              profile == null
                  ? CoreReadErrorKind.notFound
                  : CoreReadErrorKind.profileUnavailable,
            ),
          ),
        );
        expect(calls, 2);
      });
    });
  }
  group('a capped transcript read and the Dashboard session', () {
    setUp(DashboardClient.resetSharedPasswordSessionsForTesting);

    test('keeps a cookie the Dashboard rotated on a refused body', () async {
      final cookies = <String?>[];
      final mock = MockClient.streaming((request, _) async {
        final path = request.url.path;
        if (path == '/auth/password-login') {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{}')),
            200,
            headers: {'set-cookie': 'hermes_session_at=first; Path=/'},
          );
        }
        cookies.add(request.headers['Cookie']);
        if (path == '/api/sessions/s1/messages') {
          // Hermes rotates the session on any request; this answer is
          // refused by its declared length.
          return http.StreamedResponse(
            Stream.value(List<int>.filled(16, 0x61)),
            200,
            contentLength: 4 * 1024 * 1024,
            headers: {'set-cookie': 'hermes_session_at=rotated; Path=/'},
          );
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"version":"0.22"}')),
          200,
        );
      });
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        basicUser: 'synthetic-user',
        basicPass: 'synthetic-password',
        httpClientOverride: mock,
      );
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:9119',
        apiKey: '',
        httpClient: mock,
        profileDashboard: dashboard,
      );
      addTearDown(client.close);

      await expectLater(
        client.getMessages('s1', maxJsonChars: 100000),
        throwsA(isA<SessionTranscriptTooLargeException>()),
      );
      expect(await client.healthReachable(), isTrue);

      expect(cookies.first, contains('hermes_session_at=first'));
      expect(cookies.last, contains('hermes_session_at=rotated'));
    });

    test(
      'a body that never ends meets the Dashboard deadline',
      () async {
        final client = testApiClient(
          httpClient: MockClient.streaming((request, _) async {
            // Headers arrive, the body never ends. Like a real client, the
            // transport stops when the request is aborted.
            final body = StreamController<List<int>>();
            if (request is http.Abortable) {
              unawaited(
                request.abortTrigger?.whenComplete(
                  () => body.addError(
                    http.RequestAbortedException(request.url),
                  ),
                ),
              );
            }
            return http.StreamedResponse(body.stream, 200);
          }),
        );
        addTearDown(client.close);
        await expectLater(
          client.getMessages('s1', maxJsonChars: 100000),
          throwsA(isA<TimeoutException>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });
}
