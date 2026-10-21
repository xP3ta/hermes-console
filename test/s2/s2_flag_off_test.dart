// SPDX-License-Identifier: GPL-3.0-only
// S2 behind kSimpleConnectEnabled: with the flag OFF (production) only the
// "expired session -> sign in required" mapping (H1, DJ-4) is active. No
// retry after a 401, no socket latch, no sign-in banner wording.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/mobile_oauth.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/dashboard_sign_in_event.dart';

import '../s1/s1_fixtures.dart' show SecureChannelFake;
import 's2_fixtures.dart';

SavedConnection _conn(String id, String base) => SavedConnection(
  id: id,
  label: 'S2',
  host: '127.0.0.1',
  port: 9131,
  apiKey: 'test-key',
  dashboardUrl: base,
  dashboardAuthMode: AuthMode.sessionToken,
);

class _Rig {
  _Rig(this.d, this.dashboard, this.client);
  final S2Dashboard d;
  final DashboardClient dashboard;
  final TuiGatewayClient client;
}

Future<_Rig> _rig(
  String id, {
  bool withRefresh = true,
  int? expiresAt,
  RefreshMode mode = RefreshMode.ok,
  bool rejectCurrent = false,
}) async {
  final d = S2Dashboard()
    ..refreshMode = mode
    ..rejectCurrent = rejectCurrent;
  await d.start();
  final secure = SecureChannelFake()..install();
  final envelope = d.envelope(
    id,
    withRefresh: withRefresh,
    expiresAt: expiresAt,
  );
  secure.storage['dash_token_$id'] = envelope;
  final dashboard = DashboardClient.forConnection(
    _conn(id, d.base),
    secrets: DashboardSecrets(sessionToken: envelope),
    simpleConnectOverride: false,
  );
  addTearDown(dashboard.close);
  final client = TuiGatewayClient(
    _conn(id, d.base),
    dashboard: dashboard,
    heartbeatInterval: Duration.zero,
  );
  addTearDown(client.close);
  return _Rig(d, dashboard, client);
}

ConnectionStatusKind _kind(TuiGatewayClient c) => deriveConnectionStatus(
  socketReady: c.isConnected,
  authRejected: c.linkAuthRejected,
  networkLost: false,
).kind;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('flag off: H1 (expired envelope, no refresh) still shows sign-in '
      'required', () async {
    final r = await _rig(
      'off-h1',
      withRefresh: false,
      expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 30,
    );
    await expectLater(r.client.connectForeground(), throwsA(anything));
    expect(_kind(r.client), ConnectionStatusKind.authRequired);
  });

  test('flag off: refresh answers session_expired -> sign-in required '
      '(mapping not behind the flag)', () async {
    final r = await _rig('off-expired', mode: RefreshMode.expired);
    r.d.rejectCurrent = true;
    await expectLater(r.client.connectForeground(), throwsA(anything));
    expect(_kind(r.client), ConnectionStatusKind.authRequired);
  });

  test(
    'flag off: a 401 on a native session keeps the base behaviour (the '
    'same access resent once, no renewal, no S2 rejection bookkeeping)',
    () async {
      const id = 'off-401';
      final r = await _rig(id, rejectCurrent: true);
      await expectLater(r.dashboard.apiGet('ping'), throwsA(anything));
      expect(r.d.pings, [accessN(0), accessN(0)], reason: 'base: same access');
      expect(r.d.refreshCalls, 0, reason: 'no S2 renewal after the 401');
    },
  );

  test('flag off: no latch; every connect() asks for a ticket again', () async {
    final r = await _rig('off-latch', rejectCurrent: true);
    await expectLater(r.client.connectForeground(), throwsA(anything));
    final tickets = r.d.tickets;
    expect(tickets, greaterThan(0));
    for (var i = 0; i < 3; i++) {
      await expectLater(r.client.connectForeground(), throwsA(anything));
    }
    expect(r.d.tickets, greaterThan(tickets), reason: 'not latched');
    // connect() (non-foreground) is not short-circuited either.
    final before = r.d.tickets;
    await expectLater(r.client.connect(), throwsA(anything));
    expect(r.d.tickets, greaterThan(before), reason: 'connect() dials');
  });

  test('banner: the browser-session wording needs the flag AND a native '
      'session (not a manual token)', () {
    const native = '${MobileOAuthSession.prefix}x';
    expect(
      dashboardBrowserSession(simpleConnect: false, storedSession: native),
      isFalse,
    );
    expect(
      dashboardBrowserSession(simpleConnect: true, storedSession: native),
      isTrue,
    );
    expect(
      dashboardBrowserSession(
        simpleConnect: true,
        storedSession: 'manual-token',
      ),
      isFalse,
    );
    expect(
      dashboardBrowserSession(simpleConnect: true, storedSession: null),
      isFalse,
    );
  });
}
