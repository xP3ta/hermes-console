// SPDX-License-Identifier: GPL-3.0-only
// PX4: after a native session expires and its slot is dropped, the next probe
// falls to the legacy page read. A Dashboard with auth answers `GET /` with
// 302 -> /login (never 200/401), and that must read as "sign in", not as an
// outage. Server shaped like Hermes e06df9c2ea (routes.py auth_native_refresh,
// middleware.py _unauth_response).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';

import '../s1/s1_fixtures.dart' show SecureChannelFake;
import '../s2/s2_fixtures.dart';

SavedConnection _conn(String id, String base) => SavedConnection(
  id: id,
  label: 'PX4',
  host: '127.0.0.1',
  port: 9131,
  apiKey: 'test-gateway-key',
  dashboardUrl: base,
  dashboardAuthMode: AuthMode.sessionToken,
);

class _HermesShaped {
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';
  int rootHits = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      await utf8.decoder.bind(r).join();
      Future<void> json(int code, Object o) async {
        r.response.statusCode = code;
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(o));
        await r.response.close();
      }

      switch ((r.method, r.uri.path)) {
        case ('GET', '/api/status'):
          return json(200, {'auth_required': true});
        case ('POST', '/auth/native/refresh'):
          return json(401, {
            'error': 'session_expired',
            'detail': 'Refresh token expired or invalid; start a new sign-in.',
          });
        case ('GET', '/api/sessions'):
          return json(401, {
            'error': 'session_expired',
            'detail': 'Unauthorized',
            'reason': 'invalid_or_expired_session',
            'login_url': '/login',
          });
        case ('GET', '/'):
          rootHits += 1;
          r.response.statusCode = 302;
          r.response.headers.set('location', '/login');
          return r.response.close();
      }
      return json(404, {});
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test(
    'second read after the slot is dropped says sign in, not offline',
    () async {
      const id = 'px4-expired';
      final d = _HermesShaped();
      await d.start();
      final secure = SecureChannelFake()..install();
      secure.storage['dash_token_$id'] = MobileOAuthSession(
        connectionId: id,
        baseUrl: d.base,
        accessToken: accessN(0),
        expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 30,
        provider: 'basic',
        userId: 'u1',
        refreshToken: refreshN(0),
        rev: 0,
      ).encode();
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final conn = _conn(id, d.base);

      // (1) first read: refresh rejected, slot dropped.
      await expectLater(
        ApiClient.forConnection(conn).getSessions(),
        throwsA(isA<CoreReadException>()),
      );
      expect(secure.storage.containsKey('dash_token_$id'), isFalse);

      // (2) NEW client, slot gone: reachable (the login is what is missing).
      expect(await ApiClient.forConnection(conn).healthReachable(), isTrue);

      // (3) the status panel's check says loginRequired.
      expect(
        await checkSavedDashboardLogin(manager, conn),
        DashboardAuthCheck.loginRequired,
      );
      expect(d.rootHits, greaterThan(0));
    },
  );
}
