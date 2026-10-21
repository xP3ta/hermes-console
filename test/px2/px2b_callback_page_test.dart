// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';

class _Reply {
  _Reply(this.status, this.type, this.headers, this.body);
  final int status;
  final String? type;
  final HttpHeaders headers;
  final String body;
}

Future<HttpServer> _broker() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((r) async {
    r.response.headers.contentType = ContentType.json;
    if (r.uri.path == '/auth/native/token') {
      await utf8.decoder.bind(r).drain<void>();
      r.response.write(
        jsonEncode({
          'access_token': 'synthetic-access',
          'token_type': 'Bearer',
          'expires_at': 4102444800,
          'provider': 'basic',
          'user_id': 'synthetic-user',
        }),
      );
    } else {
      r.response.write(
        jsonEncode({'provider': 'basic', 'user_id': 'synthetic-user'}),
      );
    }
    await r.response.close();
  });
  return server;
}

/// Runs a login and hands each callback hit to [drive]; returns the replies.
Future<List<_Reply>> _hits(
  List<Future<_Reply> Function(Uri callback, String state)> drive,
) async {
  final server = await _broker();
  final out = <_Reply>[];
  final login = MobileOAuthLogin(
    openBrowser: (url) async {
      final cb = Uri.parse(url.queryParameters['redirect_uri']!);
      final state = url.queryParameters['state']!;
      for (final d in drive) {
        out.add(await d(cb, state));
      }
      return true;
    },
  );
  try {
    await login
        .run(
          connectionId: 'c1',
          baseUrl: 'http://127.0.0.1:${server.port}',
          authorityCurrent: () => true,
        )
        .timeout(const Duration(seconds: 5));
  } on MobileOAuthException {
    // Only rejected hits: the login ends without a session.
  } on TimeoutException {
    login.cancel();
  }
  return out;
}

Future<_Reply> Function(Uri, String) _get(
  String Function(String state) query, {
  String? lang,
  String method = 'GET',
}) => (cb, state) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, cb.replace(query: query(state)));
    if (lang != null) req.headers.set('accept-language', lang);
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    return _Reply(
      res.statusCode,
      res.headers.contentType?.toString(),
      res.headers,
      body,
    );
  } finally {
    client.close(force: true);
  }
};

const _okEn = 'You can close this tab and go back to Console.';
const _okEs = 'Puedes cerrar esta pestaña y volver a Console.';
const _errEn = 'Go back to Console and try again.';
const _errEs = 'Vuelve a Console e inténtalo de nuevo.';

void _clean(_Reply r, List<String> secrets) {
  for (final s in secrets) {
    expect(r.body, isNot(contains(s)));
  }
  expect(r.body, isNot(contains('<script')));
  expect(r.body, isNot(contains('href')));
  expect(r.body, isNot(contains('src=')));
  expect(r.body, isNot(contains('<a ')));
  expect(r.body, isNot(contains('<img')));
}

void main() {
  test('valid callback answers a readable html success page', () async {
    final r = (await _hits([
      _get((s) => 'code=synthetic-code-9&state=$s', lang: 'en-US'),
    ])).single;
    expect(r.status, 200);
    expect(r.type, 'text/html; charset=utf-8');
    expect(r.headers.value('cache-control'), 'no-store');
    expect(r.headers.value('referrer-policy'), 'no-referrer');
    expect(r.headers.value('x-content-type-options'), 'nosniff');
    expect(
      r.headers.value('content-security-policy'),
      "default-src 'none'; style-src 'unsafe-inline'",
    );
    expect(r.body, contains('<html lang="en">'));
    expect(r.body, contains('<meta name="viewport"'));
    expect(r.body, contains('<title>Signed in</title>'));
    expect(r.body, contains('<h1>Signed in</h1>'));
    expect(r.body, contains('<p>$_okEn</p>'));
    expect(r.body, contains('prefers-color-scheme'));
    expect(r.body, contains('color-scheme'));
    expect(r.body, contains('18px'));
    _clean(r, ['synthetic-code-9']);
  });

  test(
    'rejected hits answer the error page and never echo the query',
    () async {
      final replies = await _hits([
        _get((s) => 'code=synthetic-code-9&state=WRONG-STATE-1'),
        _get((s) => 'error=access_denied&code=synthetic-code-9&state=$s'),
        _get((s) => 'code=&state=$s'),
        _get((s) => 'code=synthetic-code-9&state=$s', method: 'POST'),
        _get((s) => 'code=synthetic-code-9&state=$s'),
      ]);
      expect(replies.map((r) => r.status), [400, 400, 400, 400, 200]);
      for (final r in replies.take(4)) {
        expect(r.type, 'text/html; charset=utf-8');
        expect(r.body, contains('<p>$_errEn</p>'));
        expect(r.body, isNot(contains(_okEn)));
        _clean(r, ['synthetic-code-9', 'WRONG-STATE-1', 'access_denied']);
      }
      expect(replies.last.body, contains(_okEn));
    },
  );

  test('language comes from the first Accept-Language tag only', () async {
    final replies = await _hits([
      _get((s) => 'state=bad', lang: 'es-ES,es;q=0.9'),
      _get((s) => 'state=bad', lang: 'en-US,es;q=0.9'),
      _get((s) => 'state=bad'),
      _get((s) => 'state=bad', lang: ';;,,es'),
      _get((s) => 'code=x&state=$s', lang: 'es-ES,es;q=0.9'),
    ]);
    expect(replies[0].body, contains('<html lang="es">'));
    expect(replies[0].body, contains('<p>$_errEs</p>'));
    expect(replies[1].body, contains('<p>$_errEn</p>'));
    expect(replies[2].body, contains('<p>$_errEn</p>'));
    expect(replies[3].body, contains('<p>$_errEn</p>'));
    expect(replies[4].status, 200);
    expect(replies[4].body, contains('<h1>Sesión iniciada</h1>'));
    expect(replies[4].body, contains('<p>$_okEs</p>'));
  });
}
