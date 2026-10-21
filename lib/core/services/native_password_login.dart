// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../utils/transport_privacy.dart';
import 'mobile_oauth.dart';
import 'origin_bound_http_client.dart';

enum NativePasswordFailure {
  /// 401/403 from `/auth/password-login`.
  invalidCredentials,

  /// 429 from the Dashboard (10 attempts per minute and address).
  rateLimited,

  /// No such route (404), no PKCE redirect, or no `next`: use the browser.
  unsupported,
  network,
  failed,
}

/// Body-free on purpose: neither the password, the username nor any server
/// text can reach a log or a diagnostics bundle through this exception.
class NativePasswordLoginException implements Exception {
  const NativePasswordLoginException(this.failure);
  final NativePasswordFailure failure;
  @override
  String toString() => 'Native password sign-in failed: ${failure.name}';
}

/// Sign in with a user name and password, without a browser: the same
/// Dashboard routes the browser login walks (`GET /auth/native/authorize`,
/// `POST /auth/password-login`, `POST /auth/native/token`), driven by the app
/// in the foreground. The result is the very [MobileOAuthSession] the browser
/// login yields.
///
/// The password exists only as an argument of [run] while it is sent: it is
/// not a field, is never stored and appears in no message or [toString].
class NativePasswordLogin {
  NativePasswordLogin({
    http.Client Function()? clientFactory,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 15),
  }) : _clientFactory = clientFactory ?? OriginBoundHttpClient.new,
       _now = now ?? DateTime.now;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final Duration timeout;
  http.Client? _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close();
  }

  Future<MobileOAuthSession> run({
    required String connectionId,
    required String baseUrl,
    required String username,
    required String password,
    required bool Function() authorityCurrent,
    bool allowPrivateHttp = false,
  }) async {
    NativePasswordLoginException fail(NativePasswordFailure f) =>
        NativePasswordLoginException(f);
    // Policy first: nothing is sent to a public cleartext host, nor to a
    // private http one the owner has not agreed to.
    final String allowed;
    try {
      allowed = TransportPrivacy.requireAllowed(baseUrl);
    } catch (_) {
      throw fail(NativePasswordFailure.failed);
    }
    final base = Uri.parse(allowed);
    final loopback =
        base.host == 'localhost' ||
        (InternetAddress.tryParse(base.host)?.isLoopback ?? false);
    if ((base.scheme == 'http' && !loopback && !allowPrivateHttp) ||
        _cancelled ||
        !authorityCurrent()) {
      throw fail(NativePasswordFailure.failed);
    }
    final target = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final pkce = PkceAttempt.generate();
    // Never connected to: the Dashboard only echoes it back inside `next`.
    final callback = Uri.parse(
      'http://127.0.0.1:${49152 + Random.secure().nextInt(16000)}/callback',
    );
    final client = _client = _clientFactory();
    try {
      Future<http.Response> send(
        String method,
        String path, {
        Map<String, dynamic>? body,
        String? cookie,
      }) async {
        if (_cancelled || !authorityCurrent()) {
          throw fail(NativePasswordFailure.failed);
        }
        final req = http.Request(method, Uri.parse('$target$path'))
          ..followRedirects = false;
        req.headers['Content-Type'] = 'application/json';
        if (cookie != null) req.headers['Cookie'] = cookie;
        if (body != null) req.body = jsonEncode(body);
        return client.send(req).then(http.Response.fromStream).timeout(timeout);
      }

      Map<String, dynamic> json(http.Response r) {
        final d = jsonDecode(r.body);
        if (d is! Map<String, dynamic>) {
          throw fail(NativePasswordFailure.failed);
        }
        return d;
      }

      // 1. Begin the native flow; the 302 carries the PKCE cookie.
      final auth = await send(
        'GET',
        Uri(
          path: '/auth/native/authorize',
          queryParameters: {
            'provider': 'basic',
            'code_challenge': pkce.challenge,
            'code_challenge_method': 'S256',
            'redirect_uri': callback.toString(),
            'state': pkce.state,
          },
        ).toString(),
      );
      if (auth.statusCode == 429) throw fail(NativePasswordFailure.rateLimited);
      final cookie = _cookieHeader(auth.headers['set-cookie']);
      if (auth.statusCode != 302 || cookie.isEmpty) {
        throw fail(NativePasswordFailure.unsupported);
      }
      // 2. The credentials, with that cookie and no other.
      final login = await send(
        'POST',
        '/auth/password-login',
        body: {'provider': 'basic', 'username': username, 'password': password},
        cookie: cookie,
      );
      switch (login.statusCode) {
        case 200:
          break;
        case 404:
          throw fail(NativePasswordFailure.unsupported);
        case 401 || 403:
          throw fail(NativePasswordFailure.invalidCredentials);
        case 429:
          throw fail(NativePasswordFailure.rateLimited);
        default:
          throw fail(NativePasswordFailure.failed);
      }
      final next = json(login)['next'];
      if (next is! String) throw fail(NativePasswordFailure.unsupported);
      // 3. `next` must be OUR callback with OUR state; it is read, never opened.
      final uri = Uri.tryParse(next);
      final q = uri?.queryParametersAll ?? const <String, List<String>>{};
      if (uri == null ||
          !next.startsWith('$callback?') ||
          q['state']?.length != 1 ||
          q['state']!.single != pkce.state ||
          q['code']?.length != 1 ||
          q['code']!.single.isEmpty ||
          q.containsKey('error')) {
        throw fail(NativePasswordFailure.failed);
      }
      // 4. Redeem the one-use code with the verifier.
      final tokens = await send(
        'POST',
        '/auth/native/token',
        body: {'code': q['code']!.single, 'code_verifier': pkce.verifier},
      );
      if (tokens.statusCode != 200) throw fail(NativePasswordFailure.failed);
      final issued = sessionFromNativeTokens(
        json(tokens),
        connectionId: connectionId,
        baseUrl: target,
        now: _now(),
        retainRefresh: true,
      );
      if (_cancelled || !authorityCurrent()) {
        throw fail(NativePasswordFailure.failed);
      }
      return issued;
    } on NativePasswordLoginException {
      rethrow;
    } on MobileOAuthException {
      throw fail(NativePasswordFailure.failed);
    } on SocketException {
      throw fail(NativePasswordFailure.network);
    } on http.ClientException {
      throw fail(NativePasswordFailure.network);
    } on TimeoutException {
      throw fail(NativePasswordFailure.network);
    } catch (_) {
      throw fail(NativePasswordFailure.failed);
    } finally {
      client.close();
      _client = null;
    }
  }

  /// `name=value` pairs of the `Set-Cookie` header(s), attributes dropped. Kept
  /// in memory for this one origin only; never persisted.
  static String _cookieHeader(String? setCookie) {
    if (setCookie == null) return '';
    final jar = <String>[];
    for (final c in setCookie.split(RegExp(r',\s*(?=[^;,=\s]+=)'))) {
      final pair = c.split(';').first.trim();
      if (pair.contains('=')) jar.add(pair);
    }
    return jar.join('; ');
  }
}
