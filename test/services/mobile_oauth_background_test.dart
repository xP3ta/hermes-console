// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/services/mobile_oauth.dart';

/// Hermes-shaped dashboard: authorize redirects to the app callback with a
/// one-use code (120 s TTL on its own clock), token checks PKCE and audits
/// every request that reaches the handler, /api/auth/me answers the bearer.
class FakeHermes {
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';
  DateTime clock = DateTime.utc(2026, 1, 1);
  final audit = <String>[];
  final _codes = <String, (String challenge, DateTime issued)>{};
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      final q = r.uri.queryParameters;
      if (r.uri.path == '/auth/native/authorize') {
        final code = 'code-${_codes.length + 1}';
        _codes[code] = (q['code_challenge']!, clock);
        r.response.statusCode = 302;
        r.response.headers.set(
          'Location',
          '${q['redirect_uri']}?code=$code&state=${q['state']}',
        );
        await r.response.close();
        return;
      }
      if (r.uri.path == '/auth/native/token') {
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        final entry = _codes.remove(body['code']); // one use, even on failure
        final ok =
            entry != null &&
            clock.difference(entry.$2) < const Duration(seconds: 120) &&
            base64UrlEncode(
                  sha256
                      .convert(ascii.encode('${body['code_verifier']}'))
                      .bytes,
                ).replaceAll('=', '') ==
                entry.$1;
        audit.add(ok ? 'native_token_success' : 'native_token_failure');
        r.response.statusCode = ok ? 200 : 400;
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode(
            ok
                ? {
                    'access_token': 'a1',
                    'token_type': 'Bearer',
                    'expires_at': 4102444800,
                    'provider': 'basic',
                    'user_id': 'u1',
                  }
                : {'detail': 'invalid'},
          ),
        );
        await r.response.close();
        return;
      }
      if (r.uri.path == '/api/auth/me') {
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode({'provider': 'basic', 'user_id': 'u1'}));
        await r.response.close();
        return;
      }
      r.response.statusCode = 404;
      await r.response.close();
    });
  }
}

/// Models Android's background firewall: loopback keeps serving, but the
/// app's own outgoing requests fail while the process is in the background.
class Phone {
  bool background = false;
  int sent = 0;
  int blocked = 0;
  final _waiters = <Completer<void>>[];
  Future<void> foreground() {
    if (!background) return Future.value();
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void resume() {
    background = false;
    for (final c in _waiters.toList()) {
      c.complete();
    }
    _waiters.clear();
  }

  http.Client client() => _PhoneClient(this);
}

class _PhoneClient extends http.BaseClient {
  _PhoneClient(this.phone);
  final Phone phone;
  final _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (phone.background) {
      phone.blocked++;
      throw const SocketException('Connection timed out (background)');
    }
    phone.sent++;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// The browser: signs in, then lingers 20 s (server clock) before the page
/// reaches the callback, while Console is in the background.
Future<bool> Function(Uri) browser(
  FakeHermes hermes,
  Phone phone, {
  Duration lingerOnServer = const Duration(seconds: 20),
  Duration backgroundFor = const Duration(milliseconds: 300),
}) {
  return (url) async {
    phone.background = true;
    final c = HttpClient();
    final areq = await c.getUrl(url);
    areq.followRedirects = false;
    final authorize = await areq.close();
    final callback = Uri.parse(authorize.headers.value('location')!);
    await authorize.drain<void>();
    unawaited(() async {
      await Future<void>.delayed(backgroundFor);
      hermes.clock = hermes.clock.add(lingerOnServer);
      final req = await c.getUrl(callback);
      final res = await req.close();
      await res.drain<void>();
      c.close();
      await Future<void>.delayed(backgroundFor);
      phone.resume();
    }());
    return true;
  };
}

MobileOAuthLogin login(Phone phone, Future<bool> Function(Uri) open) =>
    MobileOAuthLogin(
      openBrowser: open,
      timeout: const Duration(seconds: 20),
      foreground: phone.foreground,
      clientFactory: phone.client,
    );

Future<MobileOAuthSession> run(MobileOAuthLogin l, String base) => l.run(
  connectionId: 'c1',
  baseUrl: base,
  authorityCurrent: () => true,
  allowPrivateHttp: true,
);

void main() {
  test('slow browser with the app in the background still signs in', () async {
    final hermes = FakeHermes();
    await hermes.start();
    final phone = Phone();
    final session = await run(
      login(phone, browser(hermes, phone)),
      hermes.base,
    );
    expect(session.accessToken, 'a1');
    expect(hermes.audit, ['native_token_success']);
    expect(phone.blocked, 0, reason: 'nothing is sent while backgrounded');
  });

  test('a network error is retried once after the next resume', () async {
    final hermes = FakeHermes();
    await hermes.start();
    final phone = Phone();
    // Foreground by the app's own reckoning, but the network drops the first
    // POST (the process was frozen between the check and the send).
    var first = true;
    final flaky = _FlakyClient(() {
      if (first) {
        first = false;
        return true;
      }
      return false;
    });
    final l = MobileOAuthLogin(
      openBrowser: (url) async {
        final c = HttpClient();
        final areq = await c.getUrl(url);
        areq.followRedirects = false;
        final a = await areq.close();
        final cb = Uri.parse(a.headers.value('location')!);
        await a.drain<void>();
        unawaited(() async {
          await (await c.getUrl(cb)).close().then((r) => r.drain<void>());
          c.close();
        }());
        return true;
      },
      foreground: phone.foreground,
      clientFactory: () => flaky,
    );
    final session = await run(l, hermes.base);
    expect(session.accessToken, 'a1');
    expect(flaky.failures, 1);
    expect(hermes.audit, ['native_token_success']);
  });

  test('an HTTP 400 is never retried', () async {
    final hermes = FakeHermes();
    await hermes.start();
    final phone = Phone();
    // Server clock jumps >120 s: the code is expired, answer is 400.
    await expectLater(
      run(
        login(
          phone,
          browser(hermes, phone, lingerOnServer: const Duration(seconds: 130)),
        ),
        hermes.base,
      ),
      throwsA(isA<MobileOAuthException>()),
    );
    expect(hermes.audit, ['native_token_failure']);
  });

  test('cancel while waiting for the foreground sends nothing', () async {
    final hermes = FakeHermes();
    await hermes.start();
    final phone = Phone();
    final l = login(
      phone,
      browser(hermes, phone, backgroundFor: const Duration(seconds: 3)),
    );
    final result = run(l, hermes.base);
    final expectation = expectLater(
      result,
      throwsA(isA<MobileOAuthException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
    l.cancel();
    await expectation;
    expect(hermes.audit, isEmpty);
    expect(phone.sent, 0);
    phone.resume();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hermes.audit, isEmpty, reason: 'no POST after cancel + resume');
  });
}

class _FlakyClient extends http.BaseClient {
  _FlakyClient(this.fail);
  final bool Function() fail;
  final _inner = http.Client();
  int failures = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method == 'POST' && fail()) {
      failures++;
      throw const SocketException('network dropped');
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
