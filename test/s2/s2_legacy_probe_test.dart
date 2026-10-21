// SPDX-License-Identifier: GPL-3.0-only
// S2 (review debt 3): the one-time legacy bridge probe must not turn a
// transient refresh failure into a false "a step is missing" notice.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/legacy_bridge_retirement.dart';

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

Future<DashboardAccess> _probe(String id, RefreshMode mode) async {
  final d = S2Dashboard();
  await d.start();
  final secure = SecureChannelFake()..install();
  // Expired by the clock: the refresh runs without needing the flagged 401
  // retry, so this holds with the flag off too.
  secure.storage['dash_token_$id'] = d.envelope(
    id,
    expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 30,
  );
  d.refreshMode = mode;
  return probeDashboardAccess(_conn(id, d.base));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('503 on the refresh: no verdict, never "needs sign-in"', () async {
    expect(
      await _probe('s2-probe-503', RefreshMode.unavailable),
      DashboardAccess.unknown,
    );
  });

  test('session_expired on the refresh: needs sign-in', () async {
    expect(
      await _probe('s2-probe-expired', RefreshMode.expired),
      DashboardAccess.needsSignIn,
    );
  });
}
