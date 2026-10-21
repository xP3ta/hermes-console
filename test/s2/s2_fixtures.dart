// SPDX-License-Identifier: GPL-3.0-only
// S2 fixtures: a Dashboard stand-in whose access token can be rejected while
// it is still inside its lifetime (the case a clock can not see), whose
// refresh can answer 200 / 401 session_expired / 503, and which counts what
// reached it. Synthetic tokens only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';

String accessN(int n) => 'test-at-$n';
String refreshN(int n) => 'test-rt-$n';

enum RefreshMode { ok, expired, unavailable }

class S2Dashboard {
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';

  RefreshMode refreshMode = RefreshMode.ok;
  int rotations = 0;

  /// The server forgot the CURRENT access (revoked, restarted): 401 although
  /// the clock says it is valid. A rotation fixes it unless [rejectAll].
  bool rejectCurrent = false;

  /// Every access is refused, even the rotated one.
  bool rejectAll = false;

  /// Answer 403 (no permission) instead of 401.
  bool forbid = false;

  int refreshCalls = 0;
  final pings = <String>[]; // access of every GET /api/ping that arrived
  final writes = <String>[]; // access of every POST /api/echo that arrived
  int tickets = 0; // POST /api/auth/ws-ticket that arrived

  /// Runs when a write reaches the server (before it answers).
  void Function()? onWrite;

  String get currentAccess => accessN(rotations);

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen(_handle);
  }

  Future<void> _json(HttpRequest r, int code, Object o) async {
    r.response.statusCode = code;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(o));
    await r.response.close();
  }

  bool _authorised(HttpRequest r) {
    final auth = r.headers.value('authorization') ?? '';
    final access = auth.startsWith('Bearer ') ? auth.substring(7) : '';
    if (rejectAll) return false;
    if (access != currentAccess) return false;
    return !rejectCurrent;
  }

  String _sent(HttpRequest r) =>
      (r.headers.value('authorization') ?? '').replaceFirst('Bearer ', '');

  Future<void> _handle(HttpRequest r) async {
    await utf8.decoder.bind(r).join();
    if (r.uri.path == '/auth/native/refresh' && r.method == 'POST') {
      refreshCalls += 1;
      switch (refreshMode) {
        case RefreshMode.expired:
          return _json(r, 401, {'error': 'session_expired'});
        case RefreshMode.unavailable:
          return _json(r, 503, {'detail': 'provider unreachable'});
        case RefreshMode.ok:
          rotations += 1;
          rejectCurrent = false;
          return _json(r, 200, {
            'token_type': 'Bearer',
            'access_token': accessN(rotations),
            'refresh_token': refreshN(rotations),
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            'provider': 'basic',
            'user_id': 'u1',
          });
      }
    }
    if (r.uri.path == '/api/status') {
      return _json(r, 200, {'auth_required': true});
    }
    if (r.uri.path == '/api/ping' || r.uri.path == '/api/auth/me') {
      pings.add(_sent(r));
    } else if (r.uri.path == '/api/echo') {
      writes.add(_sent(r));
      onWrite?.call();
    } else if (r.uri.path == '/api/auth/ws-ticket') {
      tickets += 1;
    } else {
      return _json(r, 404, {});
    }
    if (forbid) return _json(r, 403, {'detail': 'forbidden'});
    if (!_authorised(r)) return _json(r, 401, {'error': 'unauthorized'});
    if (r.uri.path == '/api/auth/ws-ticket') {
      return _json(r, 200, {'ticket': 'test-ticket'});
    }
    return _json(r, 200, {'ok': true});
  }

  /// A browser-login envelope: valid for an hour by the clock.
  String envelope(
    String connectionId, {
    bool withRefresh = true,
    int? expiresAt,
  }) => MobileOAuthSession(
    connectionId: connectionId,
    baseUrl: base,
    accessToken: accessN(0),
    expiresAt:
        expiresAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
    provider: 'basic',
    userId: 'u1',
    refreshToken: withRefresh ? refreshN(0) : null,
    rev: 0,
  ).encode();
}
