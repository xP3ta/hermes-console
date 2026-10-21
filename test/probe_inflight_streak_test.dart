import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardClient, DashboardWebSocketAuth;
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// N2: a `probeNow` timeout while a turn is in flight is a streak of two, not
/// a single strike (Desktop `gateway-liveness-policy.ts`: defer the first
/// timeout under in-flight work, re-probe after 3 s, close on a streak of 2).
/// Without a turn in flight the first timeout still closes with 4002.
final class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-qa',
      );
}

const _deadline = Duration(milliseconds: 80);
const _retry = Duration(milliseconds: 150);

Future<(TuiGatewayClient, List<Map<String, dynamic>>, List<Object>)> _open(
  String id, {
  void Function(WebSocket socket)? onSocket,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final received = <Map<String, dynamic>>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    onSocket?.call(socket);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {'replay_epoch': 'epoch-a', 'heartbeat': true},
        },
      }),
    );
    // Never answers anything: the probe can only time out.
    await for (final raw in socket) {
      received.add(jsonDecode(raw as String) as Map<String, dynamic>);
    }
  });
  final client = TuiGatewayClient(
    SavedConnection(
      id: id,
      label: id,
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'qa',
      dashboardUrl: 'http://127.0.0.1:${server.port}',
    ),
    dashboard: _TicketDashboardClient(),
    heartbeatInterval: const Duration(seconds: 15),
    heartbeatDeadline: const Duration(seconds: 45),
    probeNowDeadline: _deadline,
    probeNowRecentInbound: Duration.zero,
    probeNowRetryDelay: _retry,
  );
  addTearDown(client.close);
  final errors = <Object>[];
  final subscription = client.events.listen(
    (_) {},
    onError: (Object error) => errors.add(error),
  );
  addTearDown(subscription.cancel);
  await client.connect();
  return (client, received, errors);
}

int _pings(List<Map<String, dynamic>> received) =>
    received.where((frame) => frame['method'] == 'gateway.ping').length;

void _startTurn(TuiGatewayClient client) => client.debugMarkRuntimeBusy('rt');

void main() {
  test('turn in flight: first probe timeout keeps the socket, a streak of 2 '
      'closes with 4002', () async {
    final (client, received, errors) = await _open('n2-busy');
    _startTurn(client);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final verdict = client.probeNow();
    await Future<void>.delayed(_deadline + const Duration(milliseconds: 60));
    expect(client.isConnected, isTrue, reason: 'first timeout is deferred');
    expect(errors, isEmpty);
    expect(_pings(received), 1);

    expect(await verdict, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.isConnected, isFalse, reason: 'second timeout closes');
    expect(_pings(received), 2, reason: 'one re-probe, no more');
    expect(errors, isNotEmpty);
  });

  test('no turn in flight: the first probe timeout closes', () async {
    final (client, received, errors) = await _open('n2-idle');

    expect(await client.probeNow(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.isConnected, isFalse);
    expect(_pings(received), 1);
    expect(errors, isNotEmpty);
  });

  test('a frame between the two probes resets the streak', () async {
    WebSocket? serverSocket;
    final (client, received, errors) = await _open(
      'n2-frame-between',
      onSocket: (socket) => serverSocket = socket,
    );
    _startTurn(client);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final verdict = client.probeNow();
    await Future<void>.delayed(_deadline + const Duration(milliseconds: 40));
    expect(client.isConnected, isTrue);
    serverSocket!.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'message.delta',
          'session_id': 'rt',
          'seq': 1,
          'payload': {'text': '.'},
        },
      }),
    );

    expect(await verdict, isTrue, reason: 'alive: the streak starts over');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.isConnected, isTrue);
    expect(errors, isEmpty);
    expect(_pings(received), 1, reason: 'no second probe after a live frame');
  });

  test('closing the client cancels the pending re-probe', () async {
    final (client, received, errors) = await _open('n2-close-cancels');
    _startTurn(client);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final verdict = client.probeNow();
    await Future<void>.delayed(_deadline + const Duration(milliseconds: 40));
    await client.close();

    expect(await verdict, isFalse);
    await Future<void>.delayed(_retry);
    expect(_pings(received), 1, reason: 'the re-probe timer died with close');
    expect(errors, isEmpty);
  });
}
