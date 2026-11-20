// SPDX-License-Identifier: GPL-3.0-only
// One "credentials changed" signal per connection. Desktop disposes and
// redials every socket of a connection whose credentials changed
// (use-gateway-boot.ts: connections.onChanged, then
// disposeSecondariesForConnection with redial) and the re-arm forgets the
// rejected session (store/gateway.ts: rearmSecondary clears
// reauthFailures). A sign-in stored here clears the refusal of every socket
// of that connection, the status stops asking to sign in, and the sockets
// with an owner dial without anybody calling connect. Other connections are
// not touched, and the latch still holds back automatic dials while the
// credential is the refused one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _Clock {
  DateTime now = DateTime(2026, 10, 18, 12);
}

/// A Dashboard whose stored session the server no longer takes: the
/// renewal answers `session_expired`, so a dial stops on "sign in again".
Future<S2Dashboard> _expiredServer() async {
  final d = S2Dashboard()
    ..refreshMode = RefreshMode.expired
    ..rejectCurrent = true;
  await d.start();
  return d;
}

TuiGatewayClient _client(
  SavedConnection c,
  S2Dashboard d,
  SecureChannelFake secure, {
  _Clock? clock,
}) {
  final envelope = d.envelope(c.id);
  secure.storage['dash_token_${c.id}'] = envelope;
  final dashboard = DashboardClient.forConnection(
    c,
    secrets: DashboardSecrets(sessionToken: envelope),
    simpleConnectOverride: true,
  );
  addTearDown(dashboard.close);
  final client = TuiGatewayClient(
    c,
    dashboard: dashboard,
    heartbeatInterval: Duration.zero,
    now: clock == null ? null : () => clock.now,
  );
  addTearDown(client.close);
  return client;
}

Future<ConnectionManager> _manager() async {
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  addTearDown(manager.dispose);
  return manager;
}

/// The user signs in again and the server takes the new session.
Future<void> _signIn(
  ConnectionManager manager,
  S2Dashboard d,
  String id, {
  bool accepted = true,
}) async {
  if (accepted) {
    d.refreshMode = RefreshMode.ok;
    d.rejectCurrent = false;
  }
  await manager.setDashboardSecrets(id, sessionToken: d.envelope(id));
}

Future<void> _until(String what, bool Function() done) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > const Duration(seconds: 3)) fail('never: $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Long enough for a dial the signal started to reach the loopback server.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

ConnectionStatusKind? _shown(String id) =>
    ConnectionStatusRegistry.instance.currentRaw(id)?.kind;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureChannelFake secure;

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    secure = SecureChannelFake()..install();
    ConnectionStatusRegistry.instance.reset();
    addTearDown(ConnectionStatusRegistry.instance.reset);
  });

  test('a stored sign-in redials the chat socket stopped on "sign in '
      'again" without anybody calling connect; the status stops asking to '
      'sign in', () async {
    const id = 'sig-chat';
    final d = await _expiredServer();
    final manager = await _manager();
    final pool = SharedGatewayPool.forTesting(
      factory: (c) => _client(c, d, secure),
    );
    addTearDown(pool.closeAll);
    final lease = pool.acquireChat(
      _conn(id, d.base),
      profile: '',
      chatLinger: const Duration(seconds: 30),
    );
    addTearDown(lease.release);
    final client = lease.client..redialWhenIdle = true;
    await expectLater(client.connectForeground(), throwsA(anything));
    expect(_shown(id), ConnectionStatusKind.authRequired);
    final tickets = d.tickets;

    await _signIn(manager, d, id);

    await _until('the chat socket dials', () => d.tickets > tickets);
    await _settle();
    expect(d.tickets, tickets + 1, reason: 'one dial, with the new session');
    expect(client.linkAuthRejected, isFalse);
    expect(_shown(id), isNot(ConnectionStatusKind.authRequired));
  });

  test('a stored sign-in redials an observer socket leased from the '
      'pool', () async {
    const id = 'sig-observer';
    final d = await _expiredServer();
    final manager = await _manager();
    final pool = SharedGatewayPool.forTesting(
      factory: (c) => _client(c, d, secure),
    );
    addTearDown(pool.closeAll);
    final lease = pool.acquire(_conn(id, d.base));
    addTearDown(lease.release);
    await expectLater(lease.client.connectForeground(), throwsA(anything));
    expect(lease.client.linkAuthRejected, isTrue);
    final tickets = d.tickets;

    await _signIn(manager, d, id);

    await _until('the leased socket dials', () => d.tickets > tickets);
    expect(lease.client.linkAuthRejected, isFalse);
  });

  test('a client nobody owns forgets the refusal and repaints, but does not '
      'dial until it is used', () async {
    const id = 'sig-unowned';
    final d = await _expiredServer();
    final manager = await _manager();
    final client = _client(_conn(id, d.base), d, secure);
    await expectLater(client.connectForeground(), throwsA(anything));
    expect(client.linkAuthRejected, isTrue);
    var edges = 0;
    client.linkListenable.addListener(() => edges += 1);
    final tickets = d.tickets;

    await _signIn(manager, d, id);
    await _settle();

    expect(client.linkAuthRejected, isFalse);
    expect(edges, greaterThan(0), reason: 'the status hears it');
    expect(d.tickets, tickets, reason: 'nobody owns it: no dial');
    await expectLater(client.connect(), throwsA(anything)); // no WS server
    expect(d.tickets, tickets + 1, reason: 'used: it dials');
  });

  test('the sockets of another connection are not touched', () async {
    final signedIn = await _expiredServer();
    final other = await _expiredServer();
    final manager = await _manager();
    final pool = SharedGatewayPool.forTesting(
      factory: (c) => _client(c, c.id == 'sig-a' ? signedIn : other, secure),
    );
    addTearDown(pool.closeAll);
    final a = pool.acquireChat(
      _conn('sig-a', signedIn.base),
      profile: '',
      chatLinger: const Duration(seconds: 30),
    );
    final b = pool.acquireChat(
      _conn('sig-b', other.base),
      profile: '',
      chatLinger: const Duration(seconds: 30),
    );
    addTearDown(a.release);
    addTearDown(b.release);
    a.client.redialWhenIdle = true;
    b.client.redialWhenIdle = true;
    await expectLater(a.client.connectForeground(), throwsA(anything));
    await expectLater(b.client.connectForeground(), throwsA(anything));
    final otherTickets = other.tickets;
    final aTickets = signedIn.tickets;

    await _signIn(manager, signedIn, 'sig-a');
    await _until(
      'the signed-in socket dials',
      () => signedIn.tickets > aTickets,
    );
    await _settle();

    expect(other.tickets, otherTickets);
    expect(b.client.linkAuthRejected, isTrue);
    expect(_shown('sig-b'), ConnectionStatusKind.authRequired);
    await expectLater(b.client.connect(), throwsA(anything));
    expect(other.tickets, otherTickets, reason: 'still latched: no dial');
  });

  test('a sign-in the server refuses too costs one dial; then the socket '
      'stays stopped while the credential does not change', () async {
    const id = 'sig-refused';
    final d = await _expiredServer();
    final manager = await _manager();
    final clock = _Clock();
    final pool = SharedGatewayPool.forTesting(
      factory: (c) => _client(c, d, secure, clock: clock),
    );
    addTearDown(pool.closeAll);
    final lease = pool.acquireChat(
      _conn(id, d.base),
      profile: '',
      chatLinger: const Duration(seconds: 30),
    );
    addTearDown(lease.release);
    final client = lease.client..redialWhenIdle = true;
    await expectLater(client.connectForeground(), throwsA(anything));
    final tickets = d.tickets;

    await _signIn(manager, d, id, accepted: false);
    await _until('the sign-in is tried', () => d.tickets > tickets);
    await _until('stopped again', () => client.linkAuthRejected);
    final afterSignIn = d.tickets;
    final refreshes = d.refreshCalls;

    for (var minute = 0; minute < 10; minute++) {
      clock.now = clock.now.add(const Duration(minutes: 1));
      await expectLater(client.connect(), throwsA(anything));
    }
    await _settle();
    expect(d.tickets, afterSignIn, reason: 'latched: no automatic dial');
    expect(d.refreshCalls, refreshes);
    expect(_shown(id), ConnectionStatusKind.authRequired);
  });
}
