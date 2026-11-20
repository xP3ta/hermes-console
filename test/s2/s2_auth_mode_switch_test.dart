// SPDX-License-Identifier: GPL-3.0-only
// A sign-in that switches the Dashboard auth mode (user name and password to
// browser sign-in) reaches the sockets made before it. Desktop builds the
// sockets of a connection again when it changes (use-gateway-boot.ts:
// connections.onChanged, then disposeSecondariesForConnection with
// redial). A Console client kept the mode it was made with and, after the
// switch, went on loading the password the sign-in had just removed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/dashboard_sign_in.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../s1/s1_fixtures.dart' show SecureChannelFake;
import 's2_fixtures.dart';

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
    DashboardClient.resetSharedPasswordSessionsForTesting();
  });

  test('a socket made in password mode dials with the browser sign-in that '
      'replaced the password', () async {
    const id = 'mode-switch';
    final secure = SecureChannelFake()..install();
    final d = S2Dashboard();
    await d.start();
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final connection = SavedConnection(
      id: id,
      label: 'Mode switch',
      host: '127.0.0.1',
      port: 9131,
      apiKey: 'test-key',
      dashboardUrl: d.base,
      dashboardAuthMode: AuthMode.basicAuth,
    );
    await manager.upsertConnection(connection);
    await manager.setDashboardSecrets(
      id,
      username: 'test-user',
      password: 'test-password',
    );
    final pool = SharedGatewayPool.forTesting(
      factory: (c) => TuiGatewayClient(c, heartbeatInterval: Duration.zero),
    );
    addTearDown(pool.closeAll);
    final lease = pool.acquire(connection);
    addTearDown(lease.release);
    // This Dashboard has no password login: the password gets nowhere.
    await expectLater(lease.client.connectForeground(), throwsA(anything));
    expect(d.tickets, 0);

    await storeDashboardSignIn(
      manager,
      connection,
      DashboardCredsResult(
        mode: AuthMode.sessionToken,
        sessionToken: d.envelope(id),
      ),
    );
    expect(secure.storage['dash_pass_$id'], isNull, reason: 'replaced');

    await _until('a ticket with the browser sign-in', () => d.tickets > 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(lease.client.linkAuthRejected, isFalse, reason: 'it was accepted');
  });
}
