import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Fake Dashboards behind Basic auth. Each (host, Authorization) pair is its
/// own session with its own page token, so a token scraped with one set of
/// credentials is rejected when sent with another. `/auth/password-login`
/// answers 404 to force the legacy page-token path.
class _Dashboards {
  /// Current page token per `host|Authorization`.
  final tokens = <String, String>{};
  final indexReads = <String, int>{};
  final sent = <String, List<String?>>{};
  var _minted = 0;

  static String key(String host, String? auth) => '$host|${auth ?? ''}';

  static String basic(String user, String pass) =>
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

  /// Server-side restart for one credential set: its token rotates.
  void rotate(String host, String user, String pass) {
    tokens[key(host, basic(user, pass))] = 'tok-${++_minted}';
  }

  int reads(String host, String user, String pass) =>
      indexReads[key(host, basic(user, pass))] ?? 0;

  List<String?> sentBy(String host, String user, String pass) =>
      sent[key(host, basic(user, pass))] ?? const [];

  http.Client client() => MockClient((request) async {
    final k = key(request.url.host, request.headers['Authorization']);
    final path = request.url.path;
    if (path == '/auth/password-login' || path == '/api/auth/ws-ticket') {
      return http.Response('not found', 404);
    }
    if (path == '/') {
      indexReads[k] = (indexReads[k] ?? 0) + 1;
      final token = tokens.putIfAbsent(k, () => 'tok-${++_minted}');
      return http.Response(
        '<html><script>window.__HERMES_SESSION_TOKEN__="$token";</script>',
        200,
      );
    }
    final token = request.headers['X-Hermes-Session-Token'];
    (sent[k] ??= []).add(token);
    if (token == null || token != tokens[k]) {
      return http.Response('unauthorized', 401);
    }
    return http.Response(
      jsonEncode({'ok': true}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

DashboardClient _client(
  _Dashboards server, {
  String host = 'dash.local',
  required String user,
  required String pass,
}) {
  final client = DashboardClient(
    host: host,
    port: 9119,
    basicUser: user,
    basicPass: pass,
    httpClientOverride: server.client(),
  );
  addTearDown(client.close);
  return client;
}

void main() {
  setUp(DashboardClient.resetSharedPasswordSessionsForTesting);

  test(
    'same host with different credentials never shares a page token',
    () async {
      final server = _Dashboards();

      await _client(server, user: 'alice', pass: 'a').apiGet('status');
      await _client(server, user: 'bob', pass: 'b').apiGet('status');
      await _client(server, user: 'alice', pass: 'other').apiGet('status');
      // Second round: each credential set reuses only its own token.
      await _client(server, user: 'alice', pass: 'a').apiGet('status');
      await _client(server, user: 'bob', pass: 'b').apiGet('status');
      await _client(server, user: 'alice', pass: 'other').apiGet('status');

      for (final (user, pass) in [
        ('alice', 'a'),
        ('bob', 'b'),
        ('alice', 'other'),
      ]) {
        expect(
          server.reads('dash.local', user, pass),
          1,
          reason: '$user:$pass',
        );
        final own =
            server.tokens[_Dashboards.key(
              'dash.local',
              _Dashboards.basic(user, pass),
            )];
        expect(server.sentBy('dash.local', user, pass), [own, own]);
      }
    },
  );

  test('same host and same credentials share one scrape', () async {
    final server = _Dashboards();

    await _client(server, user: 'alice', pass: 'a').apiGet('status');
    await _client(server, user: 'alice', pass: 'a').apiGet('status');
    await _client(server, user: 'alice', pass: 'a').apiGet('status');

    expect(server.reads('dash.local', 'alice', 'a'), 1);
    expect(server.sentBy('dash.local', 'alice', 'a'), hasLength(3));
  });

  test("a 401 for one credential set keeps the other's token cached", () async {
    final server = _Dashboards();
    final alice = _client(server, user: 'alice', pass: 'a');
    final bob = _client(server, user: 'bob', pass: 'b');
    await alice.apiGet('status');
    await bob.apiGet('status');
    final bobToken = server
        .tokens[_Dashboards.key('dash.local', _Dashboards.basic('bob', 'b'))];

    server.rotate('dash.local', 'alice', 'a');
    await alice.apiGet('status'); // 401 -> evict alice's token -> re-scrape.
    expect(server.reads('dash.local', 'alice', 'a'), 2);

    // A brand-new client for bob must still adopt bob's cached token.
    await _client(server, user: 'bob', pass: 'b').apiGet('status');
    await bob.apiGet('status');
    expect(server.reads('dash.local', 'bob', 'b'), 1);
    expect(server.sentBy('dash.local', 'bob', 'b'), [
      bobToken,
      bobToken,
      bobToken,
    ]);
  });

  test(
    'different hosts with the same credentials never share a token',
    () async {
      final server = _Dashboards();

      await _client(
        server,
        host: 'a.local',
        user: 'alice',
        pass: 'a',
      ).apiGet('status');
      await _client(
        server,
        host: 'b.local',
        user: 'alice',
        pass: 'a',
      ).apiGet('status');

      expect(server.reads('a.local', 'alice', 'a'), 1);
      expect(server.reads('b.local', 'alice', 'a'), 1);
      final bToken = server
          .tokens[_Dashboards.key('b.local', _Dashboards.basic('alice', 'a'))];
      expect(server.sentBy('b.local', 'alice', 'a'), [bToken]);
    },
  );

  test(
    'anonymous and Basic clients of one host keep separate tokens',
    () async {
      final server = _Dashboards();
      final anon = DashboardClient(
        host: 'dash.local',
        port: 9119,
        httpClientOverride: server.client(),
      );
      addTearDown(anon.close);

      await anon.apiGet('status');
      await _client(server, user: 'alice', pass: 'a').apiGet('status');

      expect(server.indexReads[_Dashboards.key('dash.local', null)], 1);
      expect(server.reads('dash.local', 'alice', 'a'), 1);
      expect(server.sent[_Dashboards.key('dash.local', null)], hasLength(1));
      // Alice's first request already carries her own token, never the
      // anonymous one (which would only be recovered through a 401 retry).
      final aliceToken =
          server.tokens[_Dashboards.key(
            'dash.local',
            _Dashboards.basic('alice', 'a'),
          )];
      expect(server.sentBy('dash.local', 'alice', 'a'), [aliceToken]);
    },
  );
}
