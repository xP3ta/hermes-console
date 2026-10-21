// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// A real HTTP server on 127.0.0.1 and an ephemeral port that answers the
/// Dashboard's native sign-in routes with their official shape
/// (`hermes_cli/dashboard_auth/routes.py`): authorize 302 + PKCE cookie,
/// `password-login` with `next`, one-use PKCE token, `/api/auth/me`.
class HermesShapedServer {
  HermesShapedServer._(this._server);
  final HttpServer _server;

  static const user = 'admin';
  static const pass = 'S3cret-pass-CANARY';

  // Knobs.
  int authorizeStatus = 302; // 200 = a page, 404 = no native flow
  int? loginStatus; // forces the status of password-login
  bool next = true; // false: 200 without `next`
  String Function(String next)? rewriteNext; // tamper with `next`
  int rateLimitAfter = 1 << 30; // attempts before 429

  // Evidence.
  final requests = <String>[]; // "METHOD path"
  final bodies = <String, List<String>>{};
  int get tokenPosts =>
      requests.where((r) => r == 'POST /auth/native/token').length;
  int _attempts = 0;
  final _pending =
      <String, ({String challenge, String redirect, String state})>{};
  final _codes = <String, (String challenge, String broker)>{};
  final _used = <String>{};

  static Future<HermesShapedServer> start() async {
    final s = HermesShapedServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    unawaited(s._serve());
    return s;
  }

  String get url => 'http://127.0.0.1:${_server.port}';
  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final req in _server) {
      final text = await utf8.decoder.bind(req).join();
      requests.add('${req.method} ${req.uri.path}');
      bodies.putIfAbsent('${req.method} ${req.uri.path}', () => []).add(text);
      try {
        await _route(req, text);
      } catch (_) {
        req.response.statusCode = 500;
      }
      await req.response.close();
    }
  }

  void _json(HttpRequest req, int status, Object body) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }

  Future<void> _route(HttpRequest req, String text) async {
    final p = req.uri.path;
    if (req.method == 'GET' && p == '/auth/native/authorize') {
      if (authorizeStatus != 302) {
        req.response.statusCode = authorizeStatus;
        return;
      }
      final q = req.uri.queryParameters;
      final broker = 'broker${_pending.length}';
      _pending[broker] = (
        challenge: q['code_challenge']!,
        redirect: q['redirect_uri']!,
        state: q['state']!,
      );
      req.response
        ..statusCode = 302
        ..headers.set('Location', '/login')
        ..headers.add(
          'Set-Cookie',
          'hermes_session_pkce=$broker; Path=/; HttpOnly',
        );
    } else if (req.method == 'POST' && p == '/auth/password-login') {
      final cookie = req.headers.value('cookie') ?? '';
      final broker = RegExp(
        r'hermes_session_pkce=([^;]+)',
      ).firstMatch(cookie)?[1];
      final body = jsonDecode(text) as Map;
      if (loginStatus == 404) return _json(req, 404, {'detail': 'Not Found'});
      if (++_attempts > rateLimitAfter) {
        req.response.headers.set('Retry-After', '30');
        return _json(req, 429, {'detail': 'Too many login attempts.'});
      }
      if (body['username'] != user || body['password'] != pass) {
        return _json(req, 401, {'detail': 'Invalid credentials'});
      }
      final pending = _pending[broker];
      if (pending == null) return _json(req, 400, {'detail': 'expired'});
      if (!next) return _json(req, 200, {'ok': true});
      final code = 'code${_codes.length}';
      _codes[code] = (pending.challenge, broker!);
      var target =
          '${pending.redirect}?code=$code&state=${Uri.encodeQueryComponent(pending.state)}';
      if (rewriteNext != null) target = rewriteNext!(target);
      _json(req, 200, {'ok': true, 'next': target});
    } else if (req.method == 'POST' && p == '/auth/native/token') {
      final body = jsonDecode(text) as Map;
      final code = body['code'];
      final entry = _codes[code];
      final challenge = base64UrlEncode(
        sha256.convert(ascii.encode('${body['code_verifier']}')).bytes,
      ).replaceAll('=', '');
      if (entry == null || !_used.add('$code') || entry.$1 != challenge) {
        return _json(req, 400, {
          'detail': 'Invalid or expired authorization code.',
        });
      }
      _json(req, 200, {
        'access_token': 'access-1',
        'refresh_token': 'refresh-1',
        'token_type': 'Bearer',
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 43200,
        'provider': 'basic',
        'user_id': user,
      });
    } else if (req.method == 'GET' && p == '/api/auth/me') {
      if (req.headers.value('authorization') != 'Bearer access-1') {
        return _json(req, 401, {'detail': 'Unauthorized'});
      }
      _json(req, 200, {'provider': 'basic', 'user_id': user});
    } else {
      req.response.statusCode = 404;
    }
  }
}
