// SPDX-License-Identifier: GPL-3.0-only
// S2 (socket level): a session the server no longer accepts shows as "sign-in
// required" (H1: it used to show "Reconnecting" forever) and the socket stops
// dialling until a login (new credential epoch) or an explicit retry. Copy of
// Desktop's latched reauth error (backend-health.ts:213-241).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/native_session_store.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

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
  _Rig(this.id, this.d, this.secure, this.client, this.clock);
  final String id;
  final S2Dashboard d;
  final SecureChannelFake secure;
  final TuiGatewayClient client;
  final _Clock clock;
}

class _Clock {
  DateTime now = DateTime(2026, 10, 18, 12);
}

Future<_Rig> _rig(
  String id, {
  bool withRefresh = true,
  int? expiresAt,
  RefreshMode mode = RefreshMode.ok,
  bool rejectCurrent = true,
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
    simpleConnectOverride: true,
  );
  addTearDown(dashboard.close);
  final clock = _Clock();
  final client = TuiGatewayClient(
    _conn(id, d.base),
    dashboard: dashboard,
    heartbeatInterval: Duration.zero,
    now: () => clock.now,
  );
  addTearDown(client.close);
  return _Rig(id, d, secure, client, clock);
}

ConnectionStatusKind _kind(TuiGatewayClient c) => deriveConnectionStatus(
  socketReady: c.isConnected,
  authRejected: c.linkAuthRejected,
  networkLost: false,
).kind;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('H1: an expired envelope with no refresh shows sign-in required, not '
      'reconnecting', () async {
    final r = await _rig(
      's2-h1',
      withRefresh: false,
      expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 30,
      rejectCurrent: false,
    );
    await expectLater(r.client.connectForeground(), throwsA(anything));
    expect(r.client.linkAuthRejected, isTrue);
    expect(_kind(r.client), ConnectionStatusKind.authRequired);
  });

  test('refresh answers session_expired: sign-in required; in 10 minutes of '
      'clock and many connect attempts: 0 more refreshes, 0 more tickets, and '
      'each attempt fails at once', () async {
    final r = await _rig('s2-latch', mode: RefreshMode.expired);
    await expectLater(r.client.connectForeground(), throwsA(anything));
    expect(_kind(r.client), ConnectionStatusKind.authRequired);
    final refreshes = r.d.refreshCalls;
    final tickets = r.d.tickets;
    expect(refreshes, 1);

    final sw = Stopwatch()..start();
    for (var minute = 0; minute < 10; minute++) {
      r.clock.now = r.clock.now.add(const Duration(minutes: 1));
      for (var i = 0; i < 3; i++) {
        await expectLater(r.client.connect(), throwsA(anything));
      }
    }
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(r.d.refreshCalls, refreshes);
    expect(r.d.tickets, tickets);
    expect(_kind(r.client), ConnectionStatusKind.authRequired);
  });

  test('a login (new credential epoch) lifts the latch; so does an explicit '
      'retry', () async {
    final r = await _rig('s2-lift', mode: RefreshMode.expired);
    await expectLater(r.client.connectForeground(), throwsA(anything));
    final tickets = r.d.tickets;
    await expectLater(r.client.connect(), throwsA(anything));
    expect(r.d.tickets, tickets, reason: 'latched: no dial');

    // The user signs in again: the store gets a new envelope, the epoch moves.
    r.d.refreshMode = RefreshMode.ok;
    r.d.rejectCurrent = false;
    NativeSessionCoordinator.instance.invalidate(r.id);
    r.secure.storage.update(
      'dash_token_${r.id}',
      (_) => r.d.envelope(r.id),
      ifAbsent: () => r.d.envelope(r.id),
    );
    await expectLater(r.client.connect(), throwsA(anything)); // no WS server
    expect(r.d.tickets, greaterThan(tickets), reason: 'epoch moved: dials');
  });

  test('Retry (connectForeground) asks the server again after the server '
      'refused the renewed access too; the sign-in notice clears once it '
      'works', () async {
    final r = await _rig('s2-retry-button', rejectCurrent: false);
    r.d.rejectAll = true;
    await expectLater(r.client.connectForeground(), throwsA(anything));
    expect(_kind(r.client), ConnectionStatusKind.authRequired);
    final tickets = r.d.tickets;
    await expectLater(r.client.connect(), throwsA(anything));
    expect(r.d.tickets, tickets, reason: 'latched: no dial');

    r.d.rejectAll = false; // the server accepts the renewed access again
    await expectLater(r.client.connectForeground(), throwsA(anything));
    expect(r.d.tickets, greaterThan(tickets), reason: 'Retry dials');
    expect(r.client.linkAuthRejected, isFalse, reason: 'ticket was accepted');
    expect(_kind(r.client), isNot(ConnectionStatusKind.authRequired));
  });
}
