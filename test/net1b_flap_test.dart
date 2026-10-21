import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show ApiClient, DashboardClient, DashboardWebSocketAuth;
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// NET1b: a network flap (validated `available`, then `lost`, every ~5 s)
/// must not close parked sockets and must clear the reconnect backoff at most
/// once per 15 s window (Desktop's WAKE_RECONNECT_HOLDOFF_MS), while the
/// cheap probe keeps running on every signal.
SavedConnection _conn(String id) => SavedConnection(
  id: id,
  label: id,
  host: 'example.invalid',
  port: 443,
  apiKey: 'k',
  useHttps: true,
  kind: InstanceKind.vps,
);

final class _OfflineTicket extends DashboardClient {
  _OfflineTicket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      throw StateError('Connection attempt cancelled');
}

TuiGatewayClient _offlineClient(SavedConnection connection, FakeAsync async) =>
    TuiGatewayClient(
      connection,
      dashboard: _OfflineTicket(),
      heartbeatInterval: Duration.zero,
      now: () => DateTime(2026).add(async.elapsed),
      reconnectBackoff: GatewayReconnectBackoff(random: () => 1),
    );

/// Climbs the backoff ladder on a dead path up to its 15 s ceiling (Desktop
/// base 300 ms: 300, 600, 1.2 s, 2.4 s, 4.8 s, 9.6 s, 15 s).
void _failDials(FakeAsync async, Iterable<TuiGatewayClient> clients) {
  for (final client in clients) {
    for (var i = 0; i < 8; i++) {
      client.connectForeground().then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
    }
  }
}

class _ParkedGateway implements HermesDesktopGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  bool connected = false;
  int closeCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw UnimplementedError();

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() async {
    closeCalls++;
    connected = false;
    if (!_events.isClosed) await _events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('RED-1 a validated available keeps the parked socket', () {
    fakeAsync((async) {
      final created = <_ParkedGateway>[];
      final service = ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
        desktopGatewayFactory: (_) {
          final gateway = _ParkedGateway();
          created.add(gateway);
          return gateway;
        },
      );
      final connection = _conn('conn-net1b');
      service.attach(
        connection: connection,
        sessionId: 'chat-a',
        sessionTitle: 'Warm',
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'k',
          httpClient: MockClient((_) async => http.Response('unused', 500)),
        ),
        storedMessageLoader: (_, _) async => const [],
        disableForegroundKeepAlive: true,
      );
      created.last.connect();
      async.flushMicrotasks();
      service.release('conn-net1b', 'chat-a');
      async.flushMicrotasks();
      expect(service.warmGatewayCountForTesting, 1);

      service.requestImmediateTransportRecovery();
      async.flushMicrotasks();

      expect(service.warmGatewayCountForTesting, 1);
      expect(created.single.closeCalls, 0);
      service.dispose();
    });
  });

  test('RED-2 chats clear their backoff once per 15 s window', () {
    fakeAsync((async) {
      final service = ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      final clients = <TuiGatewayClient>[];
      for (var i = 0; i < 3; i++) {
        final connection = _conn('conn-net1b-$i');
        final client = _offlineClient(connection, async);
        clients.add(client);
        service.attach(
          connection: connection,
          sessionId: 'session-net1b-$i',
          sessionTitle: 'net1b $i',
          desktopGateway: client,
          disableForegroundKeepAlive: true,
        );
      }
      _failDials(async, clients);
      expect(clients.every((c) => c.isBackingOff), isTrue);

      var clears = 0;
      for (var cycle = 0; cycle < 10; cycle++) {
        service.requestImmediateTransportRecovery();
        async.flushMicrotasks();
        if (clients.every((c) => !c.isBackingOff)) clears++;
        if (cycle == 1) {
          expect(
            clears,
            1,
            reason: 'the 2nd available, 5 s after the first, is held off',
          );
        }
        _failDials(async, clients);
        async.elapse(const Duration(milliseconds: 5000));
      }
      expect(clears, lessThanOrEqualTo(4), reason: '50 s of flap');
      expect(clears, greaterThanOrEqualTo(3), reason: 'the window reopens');
      for (final client in clients) {
        unawaited(client.close());
      }
      service.dispose();
    });
  });

  test('RED-3 the pool probes every signal, clears backoff once per 15 s', () {
    fakeAsync((async) {
      final pool = SharedGatewayPool.forTesting(
        factory: (connection) => _offlineClient(connection, async),
      );
      final leases = [
        for (var i = 0; i < 3; i++) pool.acquire(_conn('pool-net1b-$i')),
      ];
      final clients = [for (final lease in leases) lease.client];
      _failDials(async, clients);
      expect(clients.every((c) => c.isBackingOff), isTrue);

      var clears = 0;
      for (var cycle = 0; cycle < 10; cycle++) {
        unawaited(pool.probeAll());
        async.flushMicrotasks();
        if (clients.every((c) => !c.isBackingOff)) clears++;
        if (cycle == 1) {
          expect(clears, 1, reason: 'the 2nd available is held off');
        }
        _failDials(async, clients);
        async.elapse(const Duration(milliseconds: 5000));
      }
      expect(clears, lessThanOrEqualTo(4), reason: '50 s of flap');
      expect(clears, greaterThanOrEqualTo(3), reason: 'the window reopens');
      unawaited(pool.closeAll());
      async.flushMicrotasks();
    });
  });

  test('the holdoff is not sealed when no backoff was running', () {
    fakeAsync((async) {
      final pool = SharedGatewayPool.forTesting(
        factory: (connection) => _offlineClient(connection, async),
      );
      final lease = pool.acquire(_conn('pool-net1b-idle'));
      unawaited(pool.probeAll()); // nothing backing off: no seal
      async.flushMicrotasks();
      _failDials(async, [lease.client]);
      expect(lease.client.isBackingOff, isTrue);

      unawaited(pool.probeAll());
      async.flushMicrotasks();
      expect(lease.client.isBackingOff, isFalse);
      unawaited(pool.closeAll());
      async.flushMicrotasks();
    });
  });
}
