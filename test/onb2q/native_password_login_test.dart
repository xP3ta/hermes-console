// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/core/services/native_password_login.dart';

import 'hermes_shaped_server.dart';

class _Counting extends http.BaseClient {
  int sent = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent++;
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
  }
}

Future<NativePasswordFailure?> _fail(
  Future<MobileOAuthSession> Function() run,
) async {
  try {
    await run();
  } on NativePasswordLoginException catch (e) {
    return e.failure;
  }
  return null;
}

void main() {
  late HermesShapedServer server;
  setUp(() async => server = await HermesShapedServer.start());
  tearDown(() => server.close());

  Future<MobileOAuthSession> login({
    String user = HermesShapedServer.user,
    String pass = HermesShapedServer.pass,
    String? base,
  }) => NativePasswordLogin().run(
    connectionId: 'c1',
    baseUrl: base ?? server.url,
    username: user,
    password: pass,
    authorityCurrent: () => true,
  );

  test('R2 signs in against a real server and keeps no password', () async {
    final session = await login();
    expect(session.provider, 'basic');
    expect(session.userId, 'admin');
    expect(session.refreshable, isTrue);
    expect(session.encode(), startsWith(MobileOAuthSession.prefix));
    expect(session.encode(), isNot(contains(HermesShapedServer.pass)));
    expect(server.requests, [
      'GET /auth/native/authorize',
      'POST /auth/password-login',
      'POST /auth/native/token',
    ], reason: 'no browser, no loopback server, no extra calls');
  });

  test('R3 a foreign state or redirect is never redeemed', () async {
    server.rewriteNext = (n) =>
        n.replaceFirst(RegExp(r'state=[^&]+'), 'state=other');
    expect(await _fail(login), NativePasswordFailure.failed);
    server.rewriteNext = (n) =>
        n.replaceFirst('http://127.0.0.1:', 'http://127.0.0.2:');
    expect(await _fail(login), NativePasswordFailure.failed);
    server.rewriteNext = (n) => n.replaceFirst('/callback', '/elsewhere');
    expect(await _fail(login), NativePasswordFailure.failed);
    server.rewriteNext = (n) => n.replaceFirst(RegExp(r'code=[^&]+'), 'code=');
    expect(await _fail(login), NativePasswordFailure.failed);
    expect(server.tokenPosts, 0);
  });

  test('R4 each refusal gets its own plain failure', () async {
    expect(
      await _fail(() => login(pass: 'wrong')),
      NativePasswordFailure.invalidCredentials,
    );
    server.rateLimitAfter = 0;
    expect(await _fail(login), NativePasswordFailure.rateLimited);
    server.rateLimitAfter = 1 << 30;
    server.loginStatus = 404; // "no such route", never a wrong password
    expect(await _fail(login), NativePasswordFailure.unsupported);
    server.loginStatus = null;
    server.next = false;
    expect(await _fail(login), NativePasswordFailure.unsupported);
    server.next = true;
    server.authorizeStatus = 200; // a page, not the 302
    expect(await _fail(login), NativePasswordFailure.unsupported);
    server.authorizeStatus = 404;
    expect(await _fail(login), NativePasswordFailure.unsupported);
    expect(server.tokenPosts, 0);
  });

  test('R4b a dead server is a network failure', () async {
    final url = server.url;
    await server.close();
    expect(await _fail(() => login(base: url)), NativePasswordFailure.network);
    server = await HermesShapedServer.start();
  });

  test('R5 cleartext to a public host sends nothing', () async {
    for (final url in ['http://8.8.8.8:9119', 'http://example.com:9119']) {
      final client = _Counting();
      final failure = await _fail(
        () => NativePasswordLogin(clientFactory: () => client).run(
          connectionId: 'c1',
          baseUrl: url,
          username: 'a',
          password: 'b',
          authorityCurrent: () => true,
          allowPrivateHttp: true, // consent does not open a public host
        ),
      );
      expect(failure, NativePasswordFailure.failed, reason: url);
      expect(client.sent, 0, reason: url);
    }
  });

  test('R7 private http needs the consent before any request', () async {
    final client = _Counting();
    Future<NativePasswordFailure?> go(bool consent) => _fail(
      () => NativePasswordLogin(clientFactory: () => client).run(
        connectionId: 'c1',
        baseUrl: 'http://192.168.1.50:9119',
        username: 'a',
        password: 'b',
        authorityCurrent: () => true,
        allowPrivateHttp: consent,
      ),
    );
    expect(await go(false), NativePasswordFailure.failed);
    expect(client.sent, 0);
    await go(true);
    expect(client.sent, greaterThan(0));
  });

  test('R6 neither logs nor messages carry the password or the user', () async {
    final out = <String>[];
    final old = debugPrint;
    debugPrint = (m, {wrapWidth}) => out.add('$m');
    addTearDown(() => debugPrint = old);
    Object? thrown;
    await runZoned(
      () async {
        await login();
        for (final bad in ['wrong', '${HermesShapedServer.pass}x']) {
          try {
            await login(pass: bad);
          } catch (e) {
            thrown = e;
            out.add('$e');
          }
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => out.add(line),
      ),
    );
    expect(thrown, isA<NativePasswordLoginException>());
    expect(out.join('\n'), isNot(contains(HermesShapedServer.pass)));
    expect(out.join('\n'), isNot(contains('admin')));
  });

  test('stale authority aborts before anything is sent', () async {
    final failure = await _fail(
      () => NativePasswordLogin().run(
        connectionId: 'c1',
        baseUrl: server.url,
        username: HermesShapedServer.user,
        password: HermesShapedServer.pass,
        authorityCurrent: () => false,
      ),
    );
    expect(failure, NativePasswordFailure.failed);
    expect(server.requests, isEmpty);
  });
}
