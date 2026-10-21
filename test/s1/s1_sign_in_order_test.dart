// SPDX-License-Identifier: GPL-3.0-only
// D2 (REVIEW-C2B): signing in from the instance editor stores the mode and the
// secrets in two steps; a failed secrets write must not leave an instance that
// still holds its password in session-token mode.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/dashboard_sign_in.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 's1_fixtures.dart';

const _id = 's1-signin';
const _base = 'http://127.0.0.1:9119';

SavedConnection _legacy() => SavedConnection(
  id: _id,
  label: 'Old',
  host: '127.0.0.1',
  port: 9131,
  apiKey: 'test-api-key',
  dashboardUrl: _base,
  dashboardAuthMode: AuthMode.basicAuth,
);

String _envelope() => MobileOAuthSession(
  connectionId: _id,
  baseUrl: _base,
  accessToken: 'test-at-0',
  expiresAt: 4102444800,
  provider: 'basic',
  userId: 'u1',
  refreshToken: 'test-rt-0',
).encode();

Future<(ConnectionManager, SecureChannelFake)> _setUp() async {
  final secure = SecureChannelFake()..install();
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  await manager.upsertConnection(_legacy());
  secure.storage['dash_user_$_id'] = 'admin';
  secure.storage['dash_pass_$_id'] = 'test-old-pass';
  return (manager, secure);
}

AuthMode _mode(ConnectionManager m) =>
    m.getConnections().firstWhere((c) => c.id == _id).dashboardAuthMode;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed secrets write restores the previous mode; the password '
      'stays usable', () async {
    final (manager, secure) = await _setUp();
    secure.failTokenWrite = true;
    await expectLater(
      storeDashboardSignIn(
        manager,
        _legacy(),
        DashboardCredsResult(
          mode: AuthMode.sessionToken,
          sessionToken: _envelope(),
        ),
      ),
      throwsA(anything),
    );
    expect(_mode(manager), AuthMode.basicAuth);
    expect(secure.storage['dash_pass_$_id'], 'test-old-pass');
    expect(secure.storage['dash_token_$_id'], isNull);
  });

  test(
    'success: session-token mode, envelope stored, password dropped',
    () async {
      final (manager, secure) = await _setUp();
      await storeDashboardSignIn(
        manager,
        _legacy(),
        DashboardCredsResult(
          mode: AuthMode.sessionToken,
          sessionToken: _envelope(),
        ),
      );
      expect(_mode(manager), AuthMode.sessionToken);
      expect(secure.storage['dash_token_$_id'], _envelope());
      expect(secure.storage.containsKey('dash_pass_$_id'), isFalse);
      expect(secure.flushes, greaterThanOrEqualTo(1));
    },
  );
}
