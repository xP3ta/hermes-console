import 'dart:async';
import 'dart:convert';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/qrc_fake_gateway_socket.dart';

/// Quiet reconnect (qrc): the app reopens on the last known state and the
/// socket comes back in silence. The gateway client parks and redials
/// without a loss, probes a frozen socket with a short deadline, and forgets
/// the backoff ladder of the background on the first wake.

SavedConnection _conn(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
  dashboardUrl: 'http://127.0.0.1:1',
  kind: InstanceKind.vps,
);

TuiGatewayClient _client(
  FakeAsync async, {
  required List<QrcFakeChannel> channels,
  QrcTickets? tickets,
  GatewayReconnectBackoff? backoff,
  String id = 'qrc',
}) => TuiGatewayClient(
  _conn(id),
  dashboard: tickets ?? QrcTickets(),
  heartbeatInterval: Duration.zero,
  now: () => DateTime(2026).add(async.elapsed),
  reconnectBackoff: backoff ?? GatewayReconnectBackoff(random: () => 1),
  channelFactory: (_, _) {
    final channel = QrcFakeChannel();
    channels.add(channel);
    return channel;
  },
);

bool _pinged(QrcFakeChannel channel) =>
    channel.sent.any((frame) => frame.contains('"gateway.ping"'));

void main() {
  tearDown(() {
    GatewayReconnectBackoff.backgroundCadence = false;
    ConnectionStatusRegistry.instance.reset();
  });

  test('background grace keeps a healthy socket and suppresses its own lost-link redial', () {
    fakeAsync((time) {
      final channels = <QrcFakeChannel>[];
      final client = _client(time, channels: channels)..redialWhenIdle = true;
      unawaited(client.connect());
      time.flushMicrotasks();
      client.suspendBackgroundReconnects();
      var reusedHealthy = false;
      client.connect().then((_) => reusedHealthy = true);
      time.flushMicrotasks();
      expect(reusedHealthy, isTrue, reason: 'healthy RPCs still use the existing stream');
      time.elapse(const Duration(seconds: 29));
      expect(client.isConnected, isTrue);
      expect(channels.single.closedByClient, isFalse);
      client.setBackgroundParked(false);
      expect(channels, hasLength(1));
      client.suspendBackgroundReconnects();
      channels.single.closeFromPeer();
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      expect(channels, hasLength(1));
      client.setBackgroundParked(true);
      time.flushMicrotasks();
      client.setBackgroundParked(false);
      unawaited(client.connect());
      time.flushMicrotasks();
      expect(client.isConnected, isTrue);
      expect(channels, hasLength(2));
      unawaited(client.close());
      time.flushMicrotasks();
    });
  });

  test('observer VPN flaps share a minimum three second recovery interval', () {
    fakeAsync((time) {
      final channels = <QrcFakeChannel>[];
      final pool = SharedGatewayPool.forTesting(factory: (connection) =>
        _client(time, channels: channels, id: connection.id));
      final lease = pool.acquire(_conn('observer-flap'));
      unawaited(lease.client.connect());
      time.flushMicrotasks();
      channels.last.closeFromPeer();
      time.flushMicrotasks();
      unawaited(lease.client.connect());
      unawaited(pool.probeAll(networkChanged: true));
      time.flushMicrotasks();
      expect(channels, hasLength(2));
      channels.last.closeFromPeer();
      time.flushMicrotasks();
      unawaited(lease.client.connect());
      time.elapse(const Duration(milliseconds: 100));
      unawaited(pool.probeAll(networkChanged: true));
      time.flushMicrotasks();
      expect(channels, hasLength(2), reason: 'flap does not bypass the backoff');
      time.elapse(const Duration(seconds: 3));
      unawaited(pool.probeAll(networkChanged: true));
      time.flushMicrotasks();
      expect(lease.client.isConnected, isTrue);
      expect(channels, hasLength(3));
      lease.release();
      unawaited(pool.closeAll());
      time.flushMicrotasks();
    });
  });

  test('background parks a 30 s backoff; resume and VPN wake dial once now', () {
    fakeAsync((async) {
      final channels = <QrcFakeChannel>[];
      final tickets = QrcTickets();
      final client = _client(async, channels: channels, tickets: tickets,
        backoff: GatewayReconnectBackoff(base: const Duration(seconds: 30), random: () => 1),
      )..redialWhenIdle = true;
      unawaited(client.connect());
      async.flushMicrotasks();
      GatewayReconnectBackoff.backgroundCadence = true;
      channels.single.closeFromPeer();
      async.flushMicrotasks();
      expect(client.reconnectBackoffRemaining, const Duration(seconds: 30));
      client.setBackgroundParked(true);
      async.flushMicrotasks();
      client.resetReconnectBackoffForNetworkChange();
      client.connect().catchError((Object _) {});
      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();
      expect(channels, hasLength(1), reason: 'no background socket churn');
      expect(tickets.minted, 1);
      GatewayReconnectBackoff.backgroundCadence = false;
      client.setBackgroundParked(false);
      unawaited(client.connect());
      client.resetReconnectBackoffForNetworkChange();
      client.resetReconnectBackoffForNetworkChange();
      unawaited(client.connect());
      async.flushMicrotasks();
      expect(client.isConnected, isTrue);
      expect(channels, hasLength(2), reason: 'all wakes share one dial');
      expect(client.reconnectBackoffRemaining, Duration.zero);
      async.elapse(const Duration(seconds: 31));
      expect(channels, hasLength(2), reason: 'old timer was cancelled');
      // A second VPN path replacement kills the replacement socket too.
      channels.last.closeFromPeer();
      async.flushMicrotasks();
      client.resetReconnectBackoffForNetworkChange();
      client.resetReconnectBackoffForNetworkChange();
      unawaited(client.connect());
      async.flushMicrotasks();
      expect(client.isConnected, isTrue);
      expect(channels, hasLength(3), reason: 'one socket per VPN replacement');
      unawaited(client.close());
      async.flushMicrotasks();
    });
  });

  test('parking an unfinished handshake releases resume without its 12 s timeout', () {
    fakeAsync((async) {
      final channels = <QrcFakeChannel>[];
      final client = TuiGatewayClient(_conn('pending-ready'),
        dashboard: QrcTickets(), heartbeatInterval: Duration.zero,
        channelFactory: (_, _) {
          final channel = QrcFakeChannel(readyOnOpen: channels.isNotEmpty);
          channels.add(channel);
          return channel;
        },
      );
      var cancelled = false;
      client.connect().catchError((Object _) { cancelled = true; });
      async.flushMicrotasks();
      expect(client.isConnected, isFalse);
      client.setBackgroundParked(true);
      async.flushMicrotasks();
      client.setBackgroundParked(false);
      unawaited(client.connect());
      async.flushMicrotasks();
      expect(client.isConnected, isTrue);
      expect(channels, hasLength(2));
      // The retired channel may finish its bounded close drain afterwards.
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(cancelled, isTrue);
      // Complete the replacement socket's optional capability advertisement.
      for (final raw in channels.last.sent) {
        final frame = jsonDecode(raw) as Map<String, dynamic>;
        if (frame['method'] == 'client.capabilities') {
          channels.last.push(jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': {}}));
        }
      }
      async.flushMicrotasks();
      var closed = false;
      client.close().then((_) => closed = true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(closed, isTrue);
      expect(async.nonPeriodicTimerCount, 0,
        reason: async.pendingTimers.map((timer) => timer.debugString).join('\n'));

    });
  });

  test('foreground transient ticket failure redials without Retry within 1 s', () {
    fakeAsync((async) {
      final channels = <QrcFakeChannel>[];
      final tickets = QrcTickets();
      final client = _client(async, channels: channels, tickets: tickets)
        ..redialWhenIdle = true;
      unawaited(client.connect());
      async.flushMicrotasks();
      tickets.failWith = const DashboardWebSocketAuthException(
        DashboardWebSocketAuthFailureCode.unavailable,
        cause: DashboardWebSocketAuthFailureCause.transport,
      );
      channels.single.closeFromPeer();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();
      expect(client.isConnected, isFalse);
      expect(TuiGatewayClient.isDashboardAuthRejection(tickets.failWith!), isFalse);
      tickets.failWith = null;
      async.elapse(const Duration(milliseconds: 600));
      async.flushMicrotasks();
      expect(client.isConnected, isTrue);
      expect(channels, hasLength(2));
      unawaited(client.close());
      async.flushMicrotasks();
    });
  });

  group('probe after a freeze (R3)', () {
    test('no frame for a heartbeat deadline: the probe gives up in 2 s', () {
      fakeAsync((async) {
        final channels = <QrcFakeChannel>[];
        final client = _client(async, channels: channels);
        client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(client.isConnected, isTrue);

        // Frozen in the background: no frame for longer than the heartbeat
        // deadline, and no heartbeat tick ran either.
        async.elapse(
          TuiGatewayClient.defaultHeartbeatDeadline +
              const Duration(seconds: 5),
        );
        client.probeNow().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(_pinged(channels.single), isTrue);
        async.elapse(const Duration(seconds: 2));
        expect(
          client.isConnected,
          isFalse,
          reason: 'the stale probe does not wait the usual 5 s',
        );
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });

    test('a socket with recent frames keeps the 5 s deadline', () {
      fakeAsync((async) {
        final channels = <QrcFakeChannel>[];
        final client = _client(async, channels: channels);
        client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        // Past the «recent inbound» short-circuit, well inside the deadline.
        async.elapse(const Duration(seconds: 4));
        client.probeNow().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(client.isConnected, isTrue, reason: 'a slow pong is tolerated');
        async.elapse(const Duration(seconds: 3));
        expect(client.isConnected, isFalse);
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });
  });

  group('wake after the background (R4)', () {
    test('a 60 s background backoff of a chat socket is cut to a dial now', () {
      fakeAsync((async) {
        final channels = <QrcFakeChannel>[];
        final backoff = GatewayReconnectBackoff(random: () => 1);
        for (var i = 0; i < 8; i++) {
          backoff.nextDelay();
        }
        GatewayReconnectBackoff.backgroundCadence = true;
        final client = _client(async, channels: channels, backoff: backoff)
          ..redialWhenIdle = true;
        client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(client.isConnected, isTrue);

        channels.single.closeFromPeer();
        async.flushMicrotasks();
        expect(client.isConnected, isFalse);
        expect(
          client.reconnectBackoffRemaining,
          GatewayReconnectBackoff.backgroundCap,
          reason: 'the ladder reached the background ceiling',
        );

        GatewayReconnectBackoff.backgroundCadence = false;
        client.resetReconnectBackoffForNetworkChange();
        async.flushMicrotasks();
        expect(channels, hasLength(2), reason: 'the own redial timer was cut');
        expect(client.isConnected, isTrue);
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });
  });

  group('parked sockets (R2)', () {
    test('a parked socket redials quietly: the registry never says a loss', () {
      fakeAsync((async) {
        final channels = <QrcFakeChannel>[];
        final tickets = QrcTickets();
        final client = _client(async, channels: channels, tickets: tickets);
        final registry = ConnectionStatusRegistry(
          clock: () => DateTime(2026).add(async.elapsed),
        );
        final published = <ConnectionStatusKind?>[];
        registry.changes.addListener(
          () => published.add(registry.current('qrc')?.kind),
        );
        registry.bind('qrc', client);
        client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(registry.current('qrc')!.isConnected, isTrue);

        unawaited(client.disconnectIdle());
        async.flushMicrotasks();
        expect(client.linkParked, isTrue);
        expect(client.isConnected, isFalse);
        expect(registry.current('qrc'), isNull, reason: 'parked: no outage');
        final mintedBefore = tickets.minted;

        unawaited(client.redialParked());
        async.flushMicrotasks();
        expect(client.isConnected, isTrue);
        expect(client.linkParked, isFalse);
        expect(tickets.minted, mintedBefore + 1);
        expect(
          published.where(
            (kind) => kind != null && kind != ConnectionStatusKind.connected,
          ),
          isEmpty,
        );

        // Not parked: nothing to do.
        unawaited(client.redialParked());
        async.flushMicrotasks();
        expect(tickets.minted, mintedBefore + 1);
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });

    test('the chats of a multiplexed socket learn their runtimes went with '
        'it, once, on the wake', () {
      fakeAsync((async) {
        final channels = <QrcFakeChannel>[];
        final client = _client(async, channels: channels)
          ..enableSessionMultiplexing();
        var losses = 0;
        final subscription = client.events.listen(
          (_) {},
          onError: (Object _) => losses += 1,
        );
        client.connect().then<void>((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        unawaited(client.disconnectIdle());
        async.flushMicrotasks();
        expect(losses, 0, reason: 'parking is silent');
        unawaited(client.redialParked());
        async.flushMicrotasks();
        expect(losses, 1);
        expect(client.isConnected, isTrue);
        unawaited(subscription.cancel());
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });

    test('the pool parks the leased sockets its callback allows and wakes '
        'them connected', () {
      fakeAsync((async) {
        final channels = <QrcFakeChannel>[];
        final pool = SharedGatewayPool.forTesting(
          factory: (connection) =>
              _client(async, channels: channels, id: connection.id),
        );
        final registry = ConnectionStatusRegistry.instance..reset();
        final published = <ConnectionStatusKind?>[];
        registry.changes.addListener(
          () => published.add(registry.current('qrc-pool')?.kind),
        );
        final chat = pool.acquireChat(
          _conn('qrc-pool'),
          profile: 'default',
          chatLinger: const Duration(seconds: 1),
        );
        final observer = pool.acquire(_conn('qrc-pool'));
        for (final lease in [chat, observer]) {
          lease.client.connect().then<void>((_) {}, onError: (Object _) {});
        }
        async.flushMicrotasks();
        expect(chat.client.isConnected, isTrue);
        expect(observer.client.isConnected, isTrue);

        final asked = <({bool chatLane, String? profile})>[];
        pool.parkIdleLeased(
          canPark: ({required connectionId, required chatLane, profile}) {
            asked.add((chatLane: chatLane, profile: profile));
            return !chatLane;
          },
        );
        async.flushMicrotasks();
        expect(asked, hasLength(2));
        expect(
          asked.firstWhere((a) => a.chatLane).profile,
          'default',
          reason: 'the chat lane names its profile for the idle check',
        );
        expect(observer.client.linkParked, isTrue);
        expect(chat.client.isConnected, isTrue, reason: 'refused: stays');

        pool.parkIdleLeased(
          canPark: ({required connectionId, required chatLane, profile}) =>
              true,
        );
        async.flushMicrotasks();
        expect(chat.client.linkParked, isTrue);
        expect(registry.current('qrc-pool'), isNull);

        unawaited(pool.wakeAfterResume());
        async.flushMicrotasks();
        expect(chat.client.isConnected, isTrue);
        expect(observer.client.isConnected, isTrue);
        expect(registry.current('qrc-pool')!.isConnected, isTrue);
        expect(
          published.where(
            (kind) => kind != null && kind != ConnectionStatusKind.connected,
          ),
          isEmpty,
          reason: 'park and wake never showed a reconnect',
        );

        chat.release();
        observer.release();
        unawaited(pool.closeAll());
        async.flushMicrotasks();
      });
    });
  });
}
