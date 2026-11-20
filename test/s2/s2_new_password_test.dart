// SPDX-License-Identifier: GPL-3.0-only
// A client that outlives a sign-in uses the credential it stored. Desktop
// builds every socket of a connection again once its credentials change
// (use-gateway-boot.ts: connections.onChanged, then
// disposeSecondariesForConnection with redial). A Console client that had
// read the user name and password from Keystore once kept logging in with
// the old password after the user signed in with a new one, and stopped on
// "sign in again" again.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../s1/s1_fixtures.dart' show SecureChannelFake;

const _user = 'test-user';
const _oldPassword = 'test-old-password';
const _newPassword = 'test-new-password';

/// A Dashboard with its own password login. One password is current, and a
/// session cookie is good only while the password that opened it is.
class _PasswordDashboard {
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';

  String password = _oldPassword;

  /// The password of every login that reached the server.
  final logins = <String>[];

  /// WebSocket tickets issued.
  int tickets = 0;

  int _opened = 0;
  final _sessions = <String>{};

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen(_handle);
  }

  /// The password changes on the server and every open session ends.
  void changePassword(String next) {
    password = next;
    _sessions.clear();
  }

  Future<void> _reply(HttpRequest r, int code, [Object? body]) async {
    r.response.statusCode = code;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(body ?? <String, Object>{}));
    await r.response.close();
  }

  Future<void> _handle(HttpRequest r) async {
    final body = await utf8.decoder.bind(r).join();
    if (r.uri.path == '/auth/password-login' && r.method == 'POST') {
      final sent = (jsonDecode(body) as Map)['password'] as String? ?? '';
      logins.add(sent);
      if (sent != password) return _reply(r, 401, {'error': 'invalid'});
      final session = 'test-session-${++_opened}';
      _sessions.add(session);
      r.response.headers.add(
        'set-cookie',
        'hermes_session_at=$session; Path=/; HttpOnly',
      );
      return _reply(r, 200, {'ok': true});
    }
    // No gateway behind it: the upgrade is not found.
    if (r.uri.path == '/api/ws') return _reply(r, 404);
    final cookie = r.headers.value('cookie') ?? '';
    if (!_sessions.any((s) => cookie.contains('hermes_session_at=$s'))) {
      return _reply(r, 401, {'error': 'unauthorized'});
    }
    if (r.uri.path == '/api/auth/ws-ticket') {
      tickets += 1;
      return _reply(r, 200, {'ticket': 'test-ticket'});
    }
    return _reply(r, 200, {'ok': true});
  }
}

SavedConnection _conn(String id, String base) => SavedConnection(
  id: id,
  label: 'Password',
  host: '127.0.0.1',
  port: 9131,
  apiKey: 'test-key',
  dashboardUrl: base,
  dashboardAuthMode: AuthMode.basicAuth,
);

Future<ConnectionManager> _manager() async {
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  addTearDown(manager.dispose);
  return manager;
}

Future<void> _until(String what, bool Function() done) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > const Duration(seconds: 3)) fail('never: $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    SecureChannelFake().install();
    DashboardClient.resetSharedPasswordSessionsForTesting();
  });

  test('a Dashboard client made before a sign-in with a new password logs '
      'in with the new password afterwards', () async {
    const id = 'pw-rest';
    final d = _PasswordDashboard();
    await d.start();
    final manager = await _manager();
    await manager.setDashboardSecrets(
      id,
      username: _user,
      password: _oldPassword,
    );
    final client = DashboardClient.lazy(_conn(id, d.base));
    addTearDown(client.close);
    await client.apiGet('auth/me');
    expect(d.logins, [_oldPassword]);

    d.changePassword(_newPassword);
    await manager.setDashboardSecrets(
      id,
      username: _user,
      password: _newPassword,
    );

    expect(await client.apiGet('auth/me'), {'ok': true});
    expect(
      d.logins.skip(1).toList(),
      [_newPassword],
      reason: 'the old password is not sent again',
    );
  });

  test('a socket stopped on the old password dials with the new one once '
      'the user signs in with it', () async {
    const id = 'pw-socket';
    final d = _PasswordDashboard()..password = _newPassword;
    await d.start();
    final manager = await _manager();
    await manager.setDashboardSecrets(
      id,
      username: _user,
      password: _oldPassword,
    );
    final pool = SharedGatewayPool.forTesting(
      factory: (c) => TuiGatewayClient(c, heartbeatInterval: Duration.zero),
    );
    addTearDown(pool.closeAll);
    final lease = pool.acquire(_conn(id, d.base));
    addTearDown(lease.release);
    await expectLater(lease.client.connectForeground(), throwsA(anything));
    expect(lease.client.linkAuthRejected, isTrue);
    expect(d.logins, [_oldPassword]);
    expect(d.tickets, 0);

    await manager.setDashboardSecrets(
      id,
      username: _user,
      password: _newPassword,
    );

    await _until('a ticket with the new password', () => d.tickets == 1);
    expect(d.logins.skip(1).toList(), [_newPassword]);
    expect(lease.client.linkAuthRejected, isFalse);
  });
}
