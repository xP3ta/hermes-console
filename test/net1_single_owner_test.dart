import 'dart:async';
import 'dart:convert';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// N3: one owner per socket. While a client is waiting out its reconnect
/// backoff, an owner's `connect()` (chat recovery, warm-up, observers) waits
/// for the single redial the client schedules itself; only a user action
/// (`connectForeground`) skips the wait (Desktop `store/gateway.ts` foreground
/// reconnect). A transport failure minting the ticket is not an auth failure.
SavedConnection _conn(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://127.0.0.1:1',
  kind: InstanceKind.vps,
);

/// Counts every ticket request; fails the first [failures] with [error].
final class _Tickets extends DashboardClient {
  _Tickets({this.failures = 0, Object? error})
    : error =
          error ??
          const DashboardWebSocketAuthException(
            DashboardWebSocketAuthFailureCode.unavailable,
            cause: DashboardWebSocketAuthFailureCause.transport,
          ),
      super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  int failures;
  final Object error;
  int tickets = 0;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    tickets++;
    if (failures > 0) {
      failures--;
      throw error;
    }
    return const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
  }
}

/// Emits `gateway.ready` and then stays open.
final class _ReadyChannel implements WebSocketChannel {
  _ReadyChannel() {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _Sink(this);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sink implements WebSocketSink {
  _Sink(this.channel);

  final _ReadyChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) {}

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) _done.complete();
    if (!channel._incoming.isClosed) unawaited(channel._incoming.close());
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Rig {
  _Rig(
    FakeAsync async,
    this.dashboard, {
    Duration redialWaitCap = const Duration(seconds: 20),
  }) {
    client = TuiGatewayClient(
      _conn('n3'),
      dashboard: dashboard,
      heartbeatInterval: Duration.zero,
      now: () => DateTime(2026).add(async.elapsed),
      // random 1 = the ceiling of the ladder, so the gap is deterministic.
      reconnectBackoff: GatewayReconnectBackoff(random: () => 1),
      redialWaitCap: redialWaitCap,
      channelFactory: (_, _) {
        dials++;
        return _ReadyChannel();
      },
    );
  }

  final _Tickets dashboard;
  late final TuiGatewayClient client;
  int dials = 0;
}

void main() {
  test('two chats and the warm-up on a client in backoff: one ticket and one '
      'dial for the gap, none before it ends', () {
    fakeAsync((async) {
      final rig = _Rig(async, _Tickets(failures: 1));
      rig.client.connect().then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      expect(rig.dashboard.tickets, 1);
      expect(rig.client.isBackingOff, isTrue);
      final gap = rig.client.reconnectBackoffRemaining;

      final done = <String>[];
      for (final owner in ['chat-1', 'chat-2', 'warm-up']) {
        rig.client.connect().then<void>(
          (_) => done.add(owner),
          onError: (Object error) => done.add('$owner:$error'),
        );
      }
      async.flushMicrotasks();
      async.elapse(gap - const Duration(milliseconds: 1));
      expect(
        rig.dashboard.tickets,
        1,
        reason: 'no ticket is minted inside the backoff gap',
      );
      expect(rig.dials, 0);
      expect(done, isEmpty);

      async.elapse(const Duration(milliseconds: 50));
      expect(rig.dashboard.tickets, 2, reason: 'one ticket for the gap');
      expect(rig.dials, 1, reason: 'one dial for the gap');
      expect(done, unorderedEquals(['chat-1', 'chat-2', 'warm-up']));
      expect(rig.client.isConnected, isTrue);
      unawaited(rig.client.close());
      async.flushMicrotasks();
    });
  });

  test('a failed gap redial arms the next gap once for every waiter', () {
    fakeAsync((async) {
      final rig = _Rig(async, _Tickets(failures: 2));
      rig.client.connect().then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      final firstGap = rig.client.reconnectBackoffRemaining;

      final errors = <Object>[];
      for (var i = 0; i < 3; i++) {
        rig.client.connect().then<void>((_) {}, onError: errors.add);
      }
      async.flushMicrotasks();
      async.elapse(firstGap + const Duration(milliseconds: 1));
      expect(rig.dashboard.tickets, 2);
      expect(errors, hasLength(3), reason: 'every waiter sees the failure');
      expect(rig.client.isBackingOff, isTrue, reason: 'next gap armed');

      final secondGap = rig.client.reconnectBackoffRemaining;
      rig.client.connect().then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      async.elapse(secondGap + const Duration(milliseconds: 1));
      expect(rig.dashboard.tickets, 3);
      expect(rig.client.isConnected, isTrue);
      unawaited(rig.client.close());
      async.flushMicrotasks();
    });
  });

  test('a user action skips the backoff and the pending waiters share its '
      'dial', () {
    fakeAsync((async) {
      final rig = _Rig(async, _Tickets(failures: 1));
      rig.client.connect().then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      expect(rig.client.isBackingOff, isTrue);

      var waiterDone = false;
      rig.client.connect().then<void>((_) => waiterDone = true);
      rig.client.connectForeground().then<void>((_) {});
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 5));
      expect(rig.dashboard.tickets, 2, reason: 'send dials at once');
      expect(rig.dials, 1);
      expect(waiterDone, isTrue);
      expect(rig.client.isConnected, isTrue);

      // Nothing is left scheduled: no second dial when the old gap ends.
      async.elapse(const Duration(seconds: 30));
      expect(rig.dashboard.tickets, 2);
      expect(rig.dials, 1);
      unawaited(rig.client.close());
      async.flushMicrotasks();
    });
  });

  test('a waiter is bounded by the redial wait cap and a closed client '
      'never dials', () {
    fakeAsync((async) {
      final rig = _Rig(
        async,
        _Tickets(failures: 1),
        redialWaitCap: const Duration(milliseconds: 50),
      );
      rig.client.connect().then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      expect(rig.client.reconnectBackoffRemaining, greaterThan(Duration.zero));

      Object? waiterError;
      rig.client.connect().then<void>(
        (_) {},
        onError: (Object e) {
          waiterError = e;
        },
      );
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 60));
      expect(waiterError, isA<TuiGatewayRpcError>());
      expect(
        (waiterError! as TuiGatewayRpcError).failureKind,
        TuiGatewayRpcFailureKind.connectionLost,
      );

      unawaited(rig.client.close());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 60));
      expect(rig.dashboard.tickets, 1, reason: 'close cancels the redial');
      expect(rig.dials, 0);
    });
  });

  test('closing the client settles the waiters at once', () {
    fakeAsync((async) {
      final rig = _Rig(async, _Tickets(failures: 1));
      rig.client.connect().then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      Object? waiterError;
      rig.client.connect().then<void>(
        (_) {},
        onError: (Object e) {
          waiterError = e;
        },
      );
      async.flushMicrotasks();
      expect(waiterError, isNull);

      unawaited(rig.client.close());
      async.flushMicrotasks();
      expect(waiterError, isNotNull, reason: 'no wait for the 20 s cap');
      async.elapse(const Duration(seconds: 60));
      expect(rig.dashboard.tickets, 1);
    });
  });

  test('a validated network change redials the waiters at once', () {
    fakeAsync((async) {
      final rig = _Rig(async, _Tickets(failures: 1));
      rig.client.connect().then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      var done = false;
      rig.client.connect().then<void>((_) => done = true);
      async.flushMicrotasks();
      expect(rig.dashboard.tickets, 1);

      rig.client.resetReconnectBackoffForNetworkChange();
      async.elapse(const Duration(milliseconds: 5));
      expect(rig.dashboard.tickets, 2);
      expect(done, isTrue);
      unawaited(rig.client.close());
      async.flushMicrotasks();
    });
  });

  group('ticket failures', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(ActiveChat, _Tickets, TuiGatewayClient)> openChat(
      _Tickets dashboard,
    ) async {
      final client = TuiGatewayClient(
        _conn('n3-chat'),
        dashboard: dashboard,
        heartbeatInterval: Duration.zero,
        reconnectBackoff: GatewayReconnectBackoff(random: () => 1),
      );
      addTearDown(client.close);
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn('n3-chat'),
        sessionId: 'sess-n3',
        sessionTitle: 'N3',
        notifications: null,
        onTerminal: () {},
        desktopGateway: client,
      );
      addTearDown(chat.dispose);
      await client.connect().then<void>((_) {}, onError: (Object _) {});
      return (chat, dashboard, client);
    }

    test('warm-up on a client in backoff waits for the gap instead of '
        'dialling', () async {
      final (chat, dashboard, client) = await openChat(_Tickets(failures: 2));
      expect(client.isBackingOff, isTrue);
      expect(dashboard.tickets, 1);

      final warm = chat.warmDesktopGateway();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        dashboard.tickets,
        1,
        reason:
            'the warm-up is not an owner: it must not mint a ticket '
            'inside the gap',
      );
      await warm;
      expect(dashboard.tickets, 2, reason: 'one ticket once the gap ended');
    });

    test('a transport timeout minting the ticket is not auth-required and '
        'is not logged as auth', () async {
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          logs.add(message ?? '');
      addTearDown(() => debugPrint = previous);

      final (chat, _, client) = await openChat(_Tickets(failures: 99));
      await client.connectForeground().then<void>((_) {}, onError: (_) {});
      await chat.warmDesktopGateway();

      expect(chat.dashboardAuthRequired, isFalse);
      expect(
        logs.where((line) => line.contains('Dashboard auth unavailable')),
        isEmpty,
        reason: 'logs: $logs',
      );
    });

    test('a 401 minting the ticket marks auth required', () async {
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          logs.add(message ?? '');
      addTearDown(() => debugPrint = previous);

      final (chat, _, client) = await openChat(
        _Tickets(
          failures: 99,
          error: const DashboardWebSocketAuthException(
            DashboardWebSocketAuthFailureCode.unavailable,
            statusCode: 401,
          ),
        ),
      );
      await client.connectForeground().then<void>((_) {}, onError: (_) {});
      await chat.warmDesktopGateway();

      expect(chat.dashboardAuthRequired, isTrue);
      expect(
        logs.where((line) => line.contains('Dashboard auth unavailable')),
        isNotEmpty,
        reason: 'logs: $logs',
      );
    });
  });
}
