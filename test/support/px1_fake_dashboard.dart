// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Real loopback HTTP Dashboard with the 0.21.7 / 0.22.0 contract: `/api/status`
/// announces `auth_flows` [cookie, native_pkce], `/auth/native/token` answers
/// like `_bearer_payload` (routes.py:111), every other API route refuses a
/// request without the issued Bearer (401).
class Px1FakeDashboard {
  static const issuedToken = 'px1-issued-access-token';
  late final HttpServer _server;
  String get base => 'http://127.0.0.1:${_server.port}';
  final List<String> requests = [];
  int sessionsWithBearer = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => _server.close(force: true));
    _server.listen(_serve);
  }

  Future<void> _serve(HttpRequest r) async {
    requests.add('${r.method} ${r.uri.path}');
    final bearer = r.headers.value('authorization') == 'Bearer $issuedToken';
    if (r.uri.path == '/api/sessions' && bearer) sessionsWithBearer++;
    await utf8.decoder.bind(r).drain<void>();
    final who = {'provider': 'sso', 'user_id': 'px1-user'};
    final authorized = bearer ? 200 : 401;
    final (int, Map<String, Object>) answer = switch (r.uri.path) {
      '/api/status' => (
        200,
        {
          'auth_flows': ['cookie', 'native_pkce'],
        },
      ),
      '/api/auth/providers' => (
        200,
        {
          'providers': [
            {'name': 'sso', 'supports_password': false},
          ],
        },
      ),
      '/auth/native/token' => (
        200,
        {
          'access_token': issuedToken,
          'token_type': 'Bearer',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 43200,
          'refresh_token': 'px1-refresh-token',
          ...who,
        },
      ),
      '/api/auth/me' => (authorized, who),
      _ => (authorized, {'sessions': []}),
    };
    r.response
      ..statusCode = answer.$1
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'auth_required': true, ...answer.$2}));
    await r.response.close();
  }

  /// The system browser: follows the authorize URL to the app's own callback.
  Future<bool> browse(Uri authorize) async {
    final q = authorize.queryParameters;
    final callback = Uri.parse(
      q['redirect_uri']!,
    ).replace(queryParameters: {'code': 'px1-code', 'state': q['state']!});
    final res = await (await HttpClient().getUrl(callback)).close();
    await res.drain<void>();
    return res.statusCode == 200;
  }
}
