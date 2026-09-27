import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/gateway_socket_meter.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/raw_ws_server.dart';

final class _Ticket extends DashboardClient {
  _Ticket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'close');
}

SavedConnection _connection(int port) => SavedConnection(
  id: 'clean-close-$port',
  label: 'Clean close',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:$port',
);

/// Records the order of transport operations on a fake channel.
final class _OrderedChannel implements WebSocketChannel {
  _OrderedChannel(this.log) {
    _incoming = StreamController<dynamic>(onCancel: () => log.add('cancel'));
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final List<String> log;
  late final StreamController<dynamic> _incoming;
  int? sentCloseCode;
  String? sentCloseReason;

  /// Simulates the server echoing the close frame after [delay].
  Duration echoDelay = const Duration(milliseconds: 50);

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _OrderedSink(this);

  void reply(Map<String, dynamic> frame) {
    if (_incoming.isClosed) return;
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': frame['id'],
        'result': <String, dynamic>{},
      }),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _OrderedSink implements WebSocketSink {
  _OrderedSink(this.channel);

  final _OrderedChannel channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) {
    final frame = Map<String, dynamic>.from(jsonDecode(data as String) as Map);
    if (frame['id'] is int && (frame['id'] as int) > 0) channel.reply(frame);
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    channel.log.add('close:$closeCode:$closeReason');
    channel.sentCloseCode = closeCode;
    channel.sentCloseReason = closeReason;
    Timer(channel.echoDelay, () {
      channel.log.add('server_close_echo');
      unawaited(channel._incoming.close());
      if (!_done.isCompleted) _done.complete();
    });
    return _done.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'dispose sends close first and cancels only after the stream drains',
    () async {
      final log = <String>[];
      late _OrderedChannel channel;
      final client = TuiGatewayClient(
        _connection(1),
        dashboard: _Ticket(),
        channelFactory: (_, _) => channel = _OrderedChannel(log),
        heartbeatInterval: Duration.zero,
      );
      await client.connect();
      await client.close();

      final closeIndex = log.indexWhere((e) => e.startsWith('close:'));
      expect(closeIndex, isNonNegative, reason: log.join(', '));
      expect(log[closeIndex], 'close:1000:client_dispose');
      expect(
        log.indexOf('cancel'),
        greaterThan(log.indexOf('server_close_echo')),
        reason:
            'cancel() before the peer close is a SHUT_RD → RST (1006): '
            '${log.join(', ')}',
      );
      expect(channel.sentCloseCode, 1000);
    },
  );

  test('stream drain is capped when the peer never echoes the close', () async {
    final log = <String>[];
    final client = TuiGatewayClient(
      _connection(2),
      dashboard: _Ticket(),
      channelFactory: (_, _) =>
          _OrderedChannel(log)..echoDelay = const Duration(minutes: 5),
      heartbeatInterval: Duration.zero,
    );
    await client.connect();
    final sw = Stopwatch()..start();
    await client.close();
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(log, contains('cancel'));
  });

  group('real socket', () {
    late RawWsServer server;

    setUp(() async {
      server = await RawWsServer.bind();
    });
    tearDown(() => server.close());

    test(
      'clean dispose waits for a reply in flight before the close frame',
      () async {
        // Hermes (uvicorn) processes the close frame independently of the
        // handler: a reply written after the client's close fails and the
        // socket is logged as a failed send / 1006 instead of 1000.
        var replyAfterClose = false;
        final handled = Completer<void>();
        server.onRequest = (peer, frame) async {
          if (frame['method'] == 'client.capabilities') {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            var closedAlready = false;
            await peer.closed
                .then((_) => closedAlready = true)
                .timeout(Duration.zero, onTimeout: () => false);
            replyAfterClose = closedAlready;
            handled.complete();
          }
          return {'jsonrpc': '2.0', 'id': frame['id'], 'result': {}};
        };
        final client = TuiGatewayClient(
          _connection(server.port),
          dashboard: _Ticket(),
          heartbeatInterval: Duration.zero,
        );
        final accepted = server.accepted.first;
        await client.connect();
        final peer = await accepted;
        await client.close();
        final closed = await peer.closed.timeout(const Duration(seconds: 5));
        await handled.future.timeout(const Duration(seconds: 5));
        expect(closed.code, 1000, reason: '$closed');
        expect(closed.reason, 'client_dispose');
        expect(
          replyAfterClose,
          isFalse,
          reason: 'the server had to write a reply after the client closed',
        );
      },
    );

    test(
      'background idle disconnect reaches the server with its reason',
      () async {
        final client = TuiGatewayClient(
          _connection(server.port),
          dashboard: _Ticket(),
          heartbeatInterval: Duration.zero,
        );
        addTearDown(client.close);
        final accepted = server.accepted.first;
        await client.connect();
        final peer = await accepted;
        await client.disconnectIdle();
        final closed = await peer.closed.timeout(const Duration(seconds: 5));
        expect(closed.code, 1000);
        expect(closed.reason, 'client_background_idle');
      },
    );

    test(
      'heartbeat timeout closes with a code and reason (never 1005)',
      () async {
        var now = DateTime(2026, 9, 26, 12);
        server.readyPayload = const {'heartbeat': true};
        final client = TuiGatewayClient(
          _connection(server.port),
          dashboard: _Ticket(),
          heartbeatInterval: const Duration(hours: 1),
          heartbeatDeadline: const Duration(seconds: 35),
          now: () => now,
        );
        addTearDown(client.close);
        final errors = <Object>[];
        final sub = client.events.listen((_) {}, onError: errors.add);
        addTearDown(sub.cancel);
        final accepted = server.accepted.first;
        await client.connect();
        final peer = await accepted;
        now = now.add(const Duration(seconds: 20));
        await client.debugHeartbeatTick();
        now = now.add(const Duration(seconds: 20));
        await client.debugHeartbeatTick();
        final closed = await peer.closed.timeout(const Duration(seconds: 5));
        expect(closed.code, TuiGatewayCloseCodes.heartbeatTimeout);
        expect(closed.reason, 'heartbeat_timeout');
      },
    );

    test('malformed frame closes with protocol_violation', () async {
      final client = TuiGatewayClient(
        _connection(server.port),
        dashboard: _Ticket(),
        heartbeatInterval: Duration.zero,
      );
      addTearDown(client.close);
      final sub = client.events.listen((_) {}, onError: (_) {});
      addTearDown(sub.cancel);
      final accepted = server.accepted.first;
      await client.connect();
      final peer = await accepted;
      // A response to an id that is not a JSON-RPC integer violates the wire
      // grammar and triggers the malformed-frame teardown.
      peer.sendJson({
        'jsonrpc': '1.0',
        'id': 9007199254740991,
        'result': {},
        'error': {'code': -32600, 'message': 'x'},
      });
      final closed = await peer.closed.timeout(const Duration(seconds: 5));
      expect(closed.code, TuiGatewayCloseCodes.protocolViolation);
      expect(closed.reason, 'protocol_violation');
    });
  });

  group('close telemetry', () {
    late RawWsServer server;

    setUp(() async {
      server = await RawWsServer.bind();
      GatewaySocketMeter.instance.reset();
    });
    tearDown(() async {
      GatewaySocketMeter.instance.reset();
      await server.close();
    });

    test('the meter records reason, code and life of each close', () async {
      var now = DateTime(2026, 9, 26, 12);
      server.readyPayload = const {'heartbeat': true};
      final client = TuiGatewayClient(
        _connection(server.port),
        dashboard: _Ticket(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(seconds: 35),
        now: () => now,
      );
      final sub = client.events.listen((_) {}, onError: (_) {});
      addTearDown(sub.cancel);
      addTearDown(client.close);
      await client.connect();
      now = now.add(const Duration(seconds: 20));
      await client.debugHeartbeatTick();
      now = now.add(const Duration(seconds: 20));
      await client.debugHeartbeatTick();
      await client.close();

      final closes = GatewaySocketMeter.instance.recentCloses;
      expect(closes.map((c) => c.reason), ['heartbeat_timeout']);
      expect(closes.single.code, TuiGatewayCloseCodes.heartbeatTimeout);
      expect(closes.single.life, const Duration(seconds: 40));
      expect(GatewaySocketMeter.instance.closeCounts, {'heartbeat_timeout': 1});
    });

    test('a dispose is recorded as client_dispose with code 1000', () async {
      final client = TuiGatewayClient(
        _connection(server.port),
        dashboard: _Ticket(),
        heartbeatInterval: Duration.zero,
      );
      await client.connect();
      await client.close();
      final close = GatewaySocketMeter.instance.recentCloses.single;
      expect(close.reason, 'client_dispose');
      expect(close.code, 1000);
    });
  });

  test('default heartbeat deadline undercuts the server ping window', () {
    expect(
      TuiGatewayClient.defaultHeartbeatDeadline,
      const Duration(seconds: 35),
    );
  });

  test('one dashboard ticket per real connect, none per RPC', () async {
    final server = await RawWsServer.bind();
    addTearDown(server.close);
    var tickets = 0;
    final client = TuiGatewayClient(
      _connection(server.port),
      dashboard: _CountingTicket(() => tickets++),
      heartbeatInterval: Duration.zero,
    );
    addTearDown(client.close);
    for (var i = 0; i < 5; i++) {
      await client.groupCapabilities().then<void>((_) {}, onError: (_) {});
      await client.probeNow();
    }
    expect(tickets, 1);
    expect(server.peers, hasLength(1));
  });
}

final class _CountingTicket extends DashboardClient {
  _CountingTicket(this.onMint)
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final void Function() onMint;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    onMint();
    return const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
  }
}
