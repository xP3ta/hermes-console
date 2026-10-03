import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardClient, DashboardWebSocketAuth;
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

SavedConnection _conn(String id, {String apiKey = 'k'}) => SavedConnection(
  id: id,
  label: id,
  host: '10.0.0.1',
  port: 8642,
  apiKey: apiKey,
);

void main() {
  test('observers of the same connection share one gateway socket', () {
    final pool = SharedGatewayPool.forTesting();
    final before = pool.liveClientCount;
    final a = pool.acquire(_conn('pool-a'));
    final b = pool.acquire(_conn('pool-a'));
    expect(identical(a.client, b.client), isTrue);
    expect(pool.liveClientCount, before + 1);

    a.release();
    expect(a.client.isClosed, isFalse, reason: 'b still holds the lease');
    a.release(); // idempotent: must not steal b's reference
    expect(b.client.isClosed, isFalse);

    b.release();
    expect(
      b.client.isClosed,
      isFalse,
      reason: 'the last release lingers instead of closing',
    );
    pool.disconnectIdle();
    expect(b.client.isClosed, isTrue);
    expect(pool.liveClientCount, before);
  });

  test('different connections or credentials never share a socket', () {
    final pool = SharedGatewayPool.instance;
    final a = pool.acquire(_conn('pool-b'));
    final other = pool.acquire(_conn('pool-c'));
    final rotated = pool.acquire(_conn('pool-b', apiKey: 'rotated'));
    expect(identical(a.client, other.client), isFalse);
    expect(identical(a.client, rotated.client), isFalse);
    for (final lease in [a, other, rotated]) {
      lease.release();
    }
  });

  test('a closed shared client is replaced on next acquire', () async {
    final pool = SharedGatewayPool.instance;
    final a = pool.acquire(_conn('pool-d'));
    final first = a.client;
    await first.close();
    final b = pool.acquire(_conn('pool-d'));
    expect(identical(b.client, first), isFalse);
    expect(b.client, isA<TuiGatewayClient>());
    a.release();
    expect(b.client.isClosed, isFalse);
    b.release();
  });

  group('idle linger', () {
    test('release then re-acquire within the linger reuses the client', () {
      fakeAsync((async) {
        final pool = SharedGatewayPool.forTesting();
        final a = pool.acquire(_conn('linger-a'));
        final first = a.client;
        a.release();
        async.elapse(const Duration(seconds: 1));
        expect(first.isClosed, isFalse, reason: 'socket lingers after release');
        final b = pool.acquire(_conn('linger-a'));
        expect(identical(b.client, first), isTrue);
        b.release();
        async.elapse(SharedGatewayPool.idleLinger - const Duration(seconds: 1));
        expect(first.isClosed, isFalse, reason: 're-acquire restarted linger');
        async.elapse(const Duration(seconds: 2));
        expect(first.isClosed, isTrue, reason: 'closed after the linger');
        expect(pool.liveClientCount, 0);
      });
    });

    test('disconnectIdle closes only unleased lingering clients', () {
      fakeAsync((async) {
        final pool = SharedGatewayPool.forTesting();
        final held = pool.acquire(_conn('idle-held'));
        final idle = pool.acquire(_conn('idle-free'));
        final idleClient = idle.client;
        idle.release();
        pool.disconnectIdle();
        async.flushMicrotasks();
        expect(idleClient.isClosed, isTrue);
        expect(held.client.isClosed, isFalse);
        expect(pool.liveClientCount, 1);
        held.release();
        async.elapse(SharedGatewayPool.idleLinger + const Duration(seconds: 1));
      });
    });
  });

  // rl1215: room, Home and library observers share pooled sockets. After a
  // Wi-Fi/cellular switch their clients sat on a stale 15 s backoff, so every
  // poll failed fast with "connection lost" until it ran out. The platform's
  // new-network signal clears it for every pooled client.
  test('rl1215 probeAll clears every pooled client stale backoff', () {
    fakeAsync((async) {
      var networkUp = false;
      final pool = SharedGatewayPool.forTesting(
        factory: (connection) => TuiGatewayClient(
          connection,
          dashboard: _Ticket(() => networkUp),
          heartbeatInterval: Duration.zero,
          now: () => DateTime(2026).add(async.elapsed),
          reconnectBackoff: GatewayReconnectBackoff(random: () => 1),
        ),
      );
      final leases = [
        pool.acquire(_conn('rl1215-room')),
        pool.acquire(_conn('rl1215-home')),
      ];
      for (var i = 0; i < 5; i++) {
        for (final lease in leases) {
          lease.client.connect().then((_) {}, onError: (Object _) {});
        }
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1));
      }
      expect(leases.every((lease) => lease.client.isBackingOff), isTrue);

      networkUp = true;
      unawaited(pool.probeAll());
      async.flushMicrotasks();
      expect(
        leases.where((lease) => lease.client.isBackingOff),
        isEmpty,
        reason: 'a new network path voids the old backoff ladder',
      );
      for (final lease in leases) {
        lease.release();
      }
      pool.disconnectIdle();
      async.elapse(const Duration(seconds: 2));
    });
  });

  test('mk1215: acquireIfConnected never opens or lends a cold socket', () {
    final pool = SharedGatewayPool.forTesting();
    expect(pool.acquireIfConnected(_conn('pool-mk-a')), isNull);
    expect(pool.liveClientCount, 0, reason: 'nothing is created');

    final lease = pool.acquire(_conn('pool-mk-a'));
    addTearDown(pool.disconnectIdle);
    addTearDown(lease.release);
    expect(lease.client.isConnected, isFalse);
    expect(
      pool.acquireIfConnected(_conn('pool-mk-a')),
      isNull,
      reason: 'a socket that is not connected is not lent',
    );
    expect(pool.leaseCount, 1);
  });
}

final class _Ticket extends DashboardClient {
  _Ticket(this.networkUp)
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final bool Function() networkUp;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    if (!networkUp()) throw StateError('Connection attempt cancelled');
    return const DashboardWebSocketAuth(queryName: 'ticket', credential: 'p');
  }
}
