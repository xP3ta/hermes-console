// Pixel QA of 1.4.1: with Tailscale off, Bots offered
// Retry but Home kept saying «en línea», also after a cold relaunch. Cause: a
// password-login Dashboard whose login failed for want of a network armed the
// shared login cooldown; the next status probes met that cooldown's
// DashboardAuthException without any request, and the probe counted it as
// «reachable». The status probe is now `GET /api/status` without credentials
// (public on the Dashboard, Desktop's own probe): only an answer from the
// server counts.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _client(String host, http.Client mock) {
  final dashboard = DashboardClient(
    host: host,
    basicUser: 'synthetic-user',
    basicPass: 'synthetic-password',
    httpClientOverride: mock,
  );
  return ApiClient(
    baseUrl: 'http://$host:9119',
    apiKey: '',
    httpClient: mock,
    profileDashboard: dashboard,
  );
}

void main() {
  setUp(DashboardClient.resetSharedPasswordSessionsForTesting);

  test('no route: every probe asks the server and says unreachable', () async {
    var requests = 0;
    final offline = MockClient((request) async {
      requests++;
      throw const SocketException('Network is unreachable');
    });
    final client = _client('127.0.0.41', offline);
    addTearDown(client.close);

    final probes = [
      await client.healthReachable(),
      await client.healthReachable(),
      await client.healthReachable(),
    ];

    expect(probes, [false, false, false]);
    expect(requests, 3, reason: 'no probe is answered from local state');
  });

  test('a login cooldown armed offline does not read as reachable', () async {
    var online = false;
    final mock = MockClient((request) async {
      if (!online) throw const SocketException('Network is unreachable');
      return http.Response('{"version":"0.23.1"}', 200);
    });
    final client = _client('127.0.0.42', mock);
    addTearDown(client.close);
    // A real read that logs in fails offline and arms the login cooldown.
    await expectLater(client.getSessions(), throwsA(anything));

    expect(await client.healthReachable(), isFalse);

    // The network is back: the server answers at once, cooldown or not.
    online = true;
    expect(await client.healthReachable(), isTrue);
  });

  test('the probe carries no credentials and never logs in', () async {
    final probed = <Map<String, String>>[];
    var logins = 0;
    final mock = MockClient((request) async {
      if (request.url.path == '/auth/password-login') logins++;
      if (request.url.path == '/api/status') probed.add(request.headers);
      return http.Response('{"version":"0.23.1"}', 200);
    });
    final client = _client('127.0.0.43', mock);
    addTearDown(client.close);

    expect(await client.healthReachable(), isTrue);
    expect(logins, 0);
    expect(probed, hasLength(1));
    final names = probed.single.keys.map((name) => name.toLowerCase());
    expect(names, isNot(contains('cookie')));
    expect(names, isNot(contains('authorization')));
    expect(names, isNot(contains('x-hermes-session-token')));
  });

  test(
    'an answer is reachable, a refusal too; a server error is not',
    () async {
      for (final (index, (code, reachable)) in [
        (200, true),
        (401, true),
        (403, true),
        (500, false),
        (502, false),
      ].indexed) {
        final mock = MockClient((_) async => http.Response('{}', code));
        final client = _client('127.0.1.${10 + index}', mock);
        expect(await client.healthReachable(), reachable, reason: '$code');
        client.close();
      }
    },
  );
}
