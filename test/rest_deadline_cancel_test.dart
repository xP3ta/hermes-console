// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

// Transitive via flutter_test: the clock the timers are counted on.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/origin_bound_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// F3: a capped Dashboard read stops reading once the body passes the cap,
/// or refuses a too-large declared length without reading. Either way the
/// call is over, and its total deadline must go with it instead of staying
/// armed (holding the request) until it fires.
void main() {
  const deadline = Duration(seconds: 10);

  test('a reader that stops early cancels the call deadline', () {
    fakeAsync((async) {
      final body = StreamController<List<int>>();
      final client = DeadlineHttpClient(
        MockClient.streaming(
          (request, _) async => http.StreamedResponse(body.stream, 200),
        ),
        deadline,
      );
      final request = http.Request('GET', Uri.parse('http://127.0.0.1:9/x'));
      StreamSubscription<List<int>>? reader;
      unawaited(
        client
            .send(request)
            .then((response) => reader = response.stream.listen((_) {})),
      );
      async.flushMicrotasks();
      body.add(const [1, 2, 3]);
      async.flushMicrotasks();
      expect(reader, isNotNull);
      expect(
        async.pendingTimers,
        hasLength(1),
        reason: 'the deadline runs while the body is read',
      );

      unawaited(reader!.cancel());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a body read to the end still cancels the deadline', () {
    fakeAsync((async) {
      final client = DeadlineHttpClient(
        MockClient((_) async => http.Response('{}', 200)),
        deadline,
      );
      unawaited(client.get(Uri.parse('http://127.0.0.1:9/x')));
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });

  group('DashboardClient.apiGetBounded', () {
    Object? capped(
      FakeAsync async,
      Future<http.StreamedResponse> Function(http.BaseRequest request) send,
    ) {
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: 9119,
        manualToken: 'synthetic-token',
        httpClientOverride: MockClient.streaming(
          (request, _) => send(request),
        ),
      );
      Object? error;
      unawaited(
        dashboard
            .apiGetBounded('sessions/s1/messages', maxBytes: 1024)
            .then<void>((_) {}, onError: (Object e) => error = e),
      );
      async.flushMicrotasks();
      return error;
    }

    test('a declared length over the cap leaves no deadline armed', () {
      fakeAsync((async) {
        final body = StreamController<List<int>>();
        final error = capped(
          async,
          (_) async => http.StreamedResponse(
            body.stream,
            200,
            contentLength: 1 << 20,
          ),
        );
        expect(error, isA<SessionTranscriptTooLargeException>());
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a body cut part way through leaves no deadline armed', () {
      fakeAsync((async) {
        // Past the cap and still open: the read gives up mid-body.
        final body = StreamController<List<int>>()
          ..add(List<int>.filled(800, 0x61))
          ..add(List<int>.filled(800, 0x61));
        final error = capped(
          async,
          (_) async => http.StreamedResponse(body.stream, 200),
        );
        expect(error, isA<SessionTranscriptTooLargeException>());
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
