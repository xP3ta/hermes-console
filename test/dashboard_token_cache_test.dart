import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Dashboard fake that serves the SPA index with an embedded session token
/// and accepts `/api/*` only with the current token. Counts every request.
class _Dashboard {
  String token = 'tok-1';
  int indexReads = 0;
  int apiCalls = 0;
  final sentTokens = <String?>[];

  http.Client client() => MockClient((request) async {
    if (request.url.path == '/') {
      indexReads++;
      return http.Response(
        '<html><script>window.__HERMES_SESSION_TOKEN__="$token";</script>',
        200,
      );
    }
    if (request.url.path == '/api/auth/ws-ticket') {
      return http.Response('not found', 404);
    }
    apiCalls++;
    final sent = request.headers['X-Hermes-Session-Token'];
    sentTokens.add(sent);
    if (sent != token) return http.Response('unauthorized', 401);
    return http.Response(
      jsonEncode({'ok': true}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

DashboardClient _client(_Dashboard server, {String host = 'dash.local'}) {
  final client = DashboardClient(
    host: host,
    port: 9119,
    httpClientOverride: server.client(),
  );
  addTearDown(client.close);
  return client;
}

void main() {
  setUp(DashboardClient.resetSharedPasswordSessionsForTesting);

  test(
    'a new client for the same Dashboard reuses the scraped token',
    () async {
      final server = _Dashboard();

      await _client(server).apiGet('status');
      await _client(server).apiGet('status');
      await _client(server).apiGet('status');

      // Before: one GET / (the whole SPA index) per client, i.e. 3.
      expect(server.indexReads, 1);
      expect(server.apiCalls, 3);
    },
  );

  test('a rotated token is re-scraped once and shared again', () async {
    final server = _Dashboard();
    await _client(server).apiGet('status');

    server.token = 'tok-2';
    await _client(server).apiGet('status');
    await _client(server).apiGet('status');

    expect(server.indexReads, 2);
    expect(server.sentTokens, ['tok-1', 'tok-1', 'tok-2', 'tok-2']);
  });

  test('a stale 401 does not evict a token another client refreshed', () async {
    final server = _Dashboard();
    final stale = _client(server);
    await stale.apiGet('status');

    server.token = 'tok-2';
    // A fresh client re-scrapes tok-2 after its own 401.
    await _client(server).apiGet('status');
    expect(server.indexReads, 2);

    // The old client now gets 401 with tok-1; it must adopt tok-2 from the
    // shared cache instead of scraping the index again.
    await stale.apiGet('status');
    expect(server.indexReads, 2);
    expect(server.sentTokens.last, 'tok-2');
  });

  test('different Dashboards never share a token', () async {
    final a = _Dashboard();
    final b = _Dashboard()..token = 'other';

    await _client(a, host: 'a.local').apiGet('status');
    await _client(b, host: 'b.local').apiGet('status');

    expect(a.indexReads, 1);
    expect(b.indexReads, 1);
    expect(b.sentTokens, ['other']);
  });

  test(
    'a legacy token WebSocket never trusts a token it did not scrape',
    () async {
      final server = _Dashboard();
      await _client(server).apiGet('status');
      server.token = 'tok-ws';

      // No ws-ticket endpoint: the socket falls back to `?token=`, which has no
      // 401 retry, so it scrapes its own token instead of the shared one.
      final auth = await _client(server).webSocketAuth();

      expect(auth.queryName, 'token');
      expect(auth.credential, 'tok-ws');
      expect(server.indexReads, 2);
    },
  );
}
