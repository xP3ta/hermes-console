// SPDX-License-Identifier: GPL-3.0-only
// The foreground-service listener runs in its own isolate with its own
// sockets and its own credential epoch, so a sign-in made in the UI never
// reached them: a socket stopped on "sign in again" stayed stopped until
// the service restarted. The UI counts each stored sign-in in
// SharedPreferences, the store both isolates already read; the listener
// turns a count that moved into the same signal the UI isolate gives its
// own sockets (DashboardClient.noteSignInStored).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../s1/s1_fixtures.dart' show SecureChannelFake;
import '../s2/s2_fixtures.dart';

SavedConnection _conn(String id, String base) => SavedConnection(
  id: id,
  label: 'Listener',
  host: '127.0.0.1',
  port: 9131,
  apiKey: 'test-key',
  dashboardUrl: base,
  dashboardAuthMode: AuthMode.sessionToken,
);

Future<S2Dashboard> _expiredServer() async {
  final d = S2Dashboard()
    ..refreshMode = RefreshMode.expired
    ..rejectCurrent = true;
  await d.start();
  return d;
}

Future<void> _until(String what, bool Function() done) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > const Duration(seconds: 3)) fail('never: $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureChannelFake secure;

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    secure = SecureChannelFake()..install();
  });

  test('a stored sign-in is counted for its connection only; a sign-in '
      'that could not be stored is not', () async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    addTearDown(manager.dispose);
    final a = ConnectionManager.dashboardSignInsKey('count-a');
    final b = ConnectionManager.dashboardSignInsKey('count-b');

    await manager.setDashboardSecrets(
      'count-a',
      username: 'test-user',
      password: 'test-password',
    );
    expect(prefs.getInt(a), 1);
    expect(prefs.getInt(b), isNull);

    secure.failTokenWrite = true;
    await expectLater(
      manager.setDashboardSecrets('count-a', sessionToken: 'test-token'),
      throwsA(anything),
    );
    expect(prefs.getInt(a), 1);
  });

  test('the listener signals a connection only when its count moved; the '
      'first look only records', () async {
    final prefs = await SharedPreferences.getInstance();
    final heard = <String>[];
    final watch = BackgroundSignInWatch(onSignIn: heard.add);
    final a = _conn('watch-a', 'http://127.0.0.1:1');
    final b = _conn('watch-b', 'http://127.0.0.1:1');
    await prefs.setInt(ConnectionManager.dashboardSignInsKey(a.id), 4);

    watch.observe(prefs, [a, b]);
    watch.observe(prefs, [a, b]);
    expect(heard, isEmpty, reason: 'nothing moved since the first look');

    await prefs.setInt(ConnectionManager.dashboardSignInsKey(b.id), 1);
    watch.observe(prefs, [a, b]);
    watch.observe(prefs, [a, b]);
    expect(heard, [b.id], reason: 'once, for the connection that moved');
  });

  test('a sign-in counted by the UI reaches the listener\'s own sockets: the '
      'one of that connection forgets the refusal and dials, another '
      'connection\'s stays stopped', () async {
    final signedIn = await _expiredServer();
    final other = await _expiredServer();
    final prefs = await SharedPreferences.getInstance();
    final a = _conn('bg-a', signedIn.base);
    final b = _conn('bg-b', other.base);
    final pool = SharedGatewayPool.forTesting(
      factory: (c) {
        final d = c.id == a.id ? signedIn : other;
        final envelope = d.envelope(c.id);
        secure.storage['dash_token_${c.id}'] = envelope;
        final dashboard = DashboardClient.forConnection(
          c,
          secrets: DashboardSecrets(sessionToken: envelope),
          simpleConnectOverride: true,
        );
        addTearDown(dashboard.close);
        return TuiGatewayClient(
          c,
          dashboard: dashboard,
          heartbeatInterval: Duration.zero,
        );
      },
    );
    addTearDown(pool.closeAll);
    final leaseA = pool.acquire(a);
    final leaseB = pool.acquire(b);
    addTearDown(leaseA.release);
    addTearDown(leaseB.release);
    await expectLater(leaseA.client.connectForeground(), throwsA(anything));
    await expectLater(leaseB.client.connectForeground(), throwsA(anything));
    final watch = BackgroundSignInWatch()..observe(prefs, [a, b]);
    final ticketsA = signedIn.tickets;
    final ticketsB = other.tickets;

    // The UI isolate stored a new session for A and counted it.
    signedIn
      ..refreshMode = RefreshMode.ok
      ..rejectCurrent = false;
    secure.storage['dash_token_${a.id}'] = signedIn.envelope(a.id);
    await prefs.setInt(ConnectionManager.dashboardSignInsKey(a.id), 1);
    watch.observe(prefs, [a, b]);

    await _until('A dials', () => signedIn.tickets > ticketsA);
    await _settle();
    expect(leaseA.client.linkAuthRejected, isFalse);
    expect(leaseB.client.linkAuthRejected, isTrue);
    expect(other.tickets, ticketsB);
    await expectLater(leaseB.client.connect(), throwsA(anything));
    expect(other.tickets, ticketsB, reason: 'B is still stopped');
  });
}
