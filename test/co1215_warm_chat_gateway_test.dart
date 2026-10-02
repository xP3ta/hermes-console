import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// co1215: a released chat parks its own WebSocket client for a short grace
/// so reopening the same chat skips the ticket + upgrade + ready handshake.
class _CountingGateway implements HermesDesktopGateway {
  _CountingGateway(this.id);

  final int id;
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  bool connected = false;
  int connectCalls = 0;
  int closeCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async {
    connectCalls++;
    connected = true;
  }

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

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

ApiClient _api() => ApiClient(
  baseUrl: 'https://example.invalid',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('unused', 500)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<_CountingGateway> created;
  late ActiveChatService service;

  ActiveChatService newService() => ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
    desktopGatewayFactory: (_) {
      final gateway = _CountingGateway(created.length);
      created.add(gateway);
      return gateway;
    },
  );

  setUp(() {
    created = [];
    service = newService();
  });

  tearDown(() => service.dispose());

  ActiveChat attach(String connectionId, String sessionId) => service.attach(
    connection: _connection(connectionId),
    sessionId: sessionId,
    sessionTitle: 'Warm',
    api: _api(),
    storedMessageLoader: (_, _) async => const [],
    disableForegroundKeepAlive: true,
  );

  Future<void> openConnected(String connectionId, String sessionId) async {
    attach(connectionId, sessionId);
    await created.last.connect();
  }

  test('reopening a released chat within the grace reuses its live client', () {
    fakeAsync((async) {
      openConnected('conn', 'chat-a');
      async.flushMicrotasks();
      service.release('conn', 'chat-a');
      async.flushMicrotasks();

      expect(created.single.closeCalls, 0);
      expect(service.warmGatewayCountForTesting, 1);

      async.elapse(const Duration(seconds: 30));
      final reopened = attach('conn', 'chat-a');
      async.flushMicrotasks();

      expect(created, hasLength(1), reason: 'no new socket on reopen');
      expect(reopened.hasDesktopTransport, isTrue);
      expect(created.single.isConnected, isTrue);
      expect(service.warmGatewayCountForTesting, 0);

      // Released again: the same client is parked again, then closed when
      // its grace runs out.
      service.release('conn', 'chat-a');
      async.flushMicrotasks();
      expect(created.single.closeCalls, 0);
      async.elapse(ActiveChatService.warmGatewayGrace);
      async.flushMicrotasks();
      expect(created.single.closeCalls, 1);
      expect(service.warmGatewayCountForTesting, 0);
    });
  });

  test('a parked client is closed when its grace expires', () {
    fakeAsync((async) {
      openConnected('conn', 'chat-a');
      async.flushMicrotasks();
      service.release('conn', 'chat-a');
      async.elapse(
        ActiveChatService.warmGatewayGrace - const Duration(seconds: 1),
      );
      expect(created.single.closeCalls, 0);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(created.single.closeCalls, 1);

      attach('conn', 'chat-a');
      expect(created, hasLength(2), reason: 'expired client is not reused');
    });
  });

  test('a disconnected client is never parked', () {
    fakeAsync((async) {
      attach('conn', 'chat-a');
      service.release('conn', 'chat-a');
      async.flushMicrotasks();
      expect(created.single.closeCalls, 1);
      expect(service.warmGatewayCountForTesting, 0);
    });
  });

  test('the parked set is bounded and evicts the oldest client', () {
    fakeAsync((async) {
      final limit = ActiveChatService.warmGatewayLimit;
      for (var i = 0; i <= limit; i++) {
        openConnected('conn', 'chat-$i');
        async.flushMicrotasks();
        service.release('conn', 'chat-$i');
        async.flushMicrotasks();
      }
      expect(service.warmGatewayCountForTesting, limit);
      expect(created.first.closeCalls, 1);
      expect(created.skip(1).every((g) => g.closeCalls == 0), isTrue);
    });
  });

  test('backgrounding and memory pressure close every parked client', () {
    fakeAsync((async) {
      openConnected('conn', 'chat-a');
      async.flushMicrotasks();
      service.release('conn', 'chat-a');
      openConnected('conn', 'chat-b');
      async.flushMicrotasks();
      service.release('conn', 'chat-b');
      async.flushMicrotasks();
      expect(service.warmGatewayCountForTesting, 2);

      service.closeWarmGateways();
      async.flushMicrotasks();
      expect(created.map((g) => g.closeCalls), [1, 1]);
      expect(service.warmGatewayCountForTesting, 0);
    });
  });

  test('a parked client only serves the same chat on the same connection', () {
    fakeAsync((async) {
      openConnected('conn', 'chat-a');
      async.flushMicrotasks();
      service.release('conn', 'chat-a');
      async.flushMicrotasks();

      attach('conn', 'chat-b');
      attach('other', 'chat-a');
      expect(created, hasLength(3));
      expect(service.warmGatewayCountForTesting, 1);
    });
  });

  test('forgetting a connection closes its parked clients', () {
    fakeAsync((async) {
      openConnected('conn', 'chat-a');
      async.flushMicrotasks();
      service.release('conn', 'chat-a');
      async.flushMicrotasks();

      unawaited(service.clearCancelledTurnsForConnection('conn'));
      async.flushMicrotasks();
      expect(created.single.closeCalls, 1);
      expect(service.warmGatewayCountForTesting, 0);
    });
  });

  test('an injected gateway stays owned by its caller and is not parked', () {
    fakeAsync((async) {
      final injected = _CountingGateway(-1);
      service.attach(
        connection: _connection('conn'),
        sessionId: 'chat-a',
        sessionTitle: 'Warm',
        api: _api(),
        desktopGateway: injected,
        storedMessageLoader: (_, _) async => const [],
        disableForegroundKeepAlive: true,
      );
      injected.connect();
      async.flushMicrotasks();
      service.release('conn', 'chat-a');
      async.flushMicrotasks();
      expect(service.warmGatewayCountForTesting, 0);
      expect(injected.closeCalls, 1);
    });
  });

  test('disposing the service closes parked clients', () {
    fakeAsync((async) {
      final local = newService();
      local.attach(
        connection: _connection('conn'),
        sessionId: 'chat-a',
        sessionTitle: 'Warm',
        api: _api(),
        storedMessageLoader: (_, _) async => const [],
        disableForegroundKeepAlive: true,
      );
      created.last.connect();
      async.flushMicrotasks();
      local.release('conn', 'chat-a');
      async.flushMicrotasks();
      local.dispose();
      async.flushMicrotasks();
      expect(created.last.closeCalls, 1);
    });
  });
}
