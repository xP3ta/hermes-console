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

  // A full read never cancels: its body reaches the reader on the test's own
  // clock, with nothing left for a real event loop (a FakeAsync zone, like a
  // widget test, never runs one).
  test('a body read to the end completes and cancels the deadline', () {
    fakeAsync((async) {
      final client = DeadlineHttpClient(
        MockClient((_) async => http.Response('{"ok":true}', 200)),
        deadline,
      );
      String? body;
      unawaited(
        client
            .get(Uri.parse('http://127.0.0.1:9/x'))
            .then((response) => body = response.body),
      );
      async.flushMicrotasks();
      expect(body, '{"ok":true}');
      expect(async.pendingTimers, isEmpty);
    });
  });

  group('DashboardClient.apiGetBounded', () {
    // The body stays open, so only the reader's cancel can end the call:
    // with no deadline left armed and nobody listening, it was cancelled.
    // The typed error itself is pinned in
    // transcript_bounded_dashboard_read_test.dart.
    //
    // Runs a capped read and returns how many requests it sent.
    int capped(
      FakeAsync async,
      Future<http.StreamedResponse> Function(http.BaseRequest request) send,
    ) {
      var sent = 0;
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: 9119,
        manualToken: 'synthetic-token',
        httpClientOverride: MockClient.streaming((request, _) {
          sent++;
          return send(request);
        }),
      );
      unawaited(
        dashboard
            .apiGetBounded('sessions/s1/messages', maxBytes: 1024)
            .then<void>((_) {}, onError: (Object _) {}),
      );
      async.flushMicrotasks();
      return sent;
    }

    test('a declared length over the cap leaves no deadline armed', () {
      fakeAsync((async) {
        var listened = false;
        final body = StreamController<List<int>>(
          onListen: () => listened = true,
        );
        final sent = capped(
          async,
          (_) async => http.StreamedResponse(
            body.stream,
            200,
            contentLength: 1 << 20,
          ),
        );
        expect(sent, 1);
        expect(listened, isTrue, reason: 'the reader drains, then cancels');
        expect(body.hasListener, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a body cut part way through leaves no deadline armed', () {
      fakeAsync((async) {
        // Past the cap and still open: the read gives up mid-body.
        var listened = false;
        final body = StreamController<List<int>>(
          onListen: () => listened = true,
        );
        body.add(List<int>.filled(800, 0x61));
        body.add(List<int>.filled(800, 0x61));
        final sent = capped(
          async,
          (_) async => http.StreamedResponse(body.stream, 200),
        );
        expect(sent, 1);
        expect(listened, isTrue);
        expect(body.hasListener, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
