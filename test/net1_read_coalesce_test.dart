import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardClient, DashboardWebSocketAuth;
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// N6a (f): identical read-only requests in flight on one socket share a
/// single frame; after they settle the next call goes out again.
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

Future<(TuiGatewayClient, List<Map<String, dynamic>>)> _open({
  Duration answerAfter = const Duration(milliseconds: 60),
  bool fail = false,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final received = <Map<String, dynamic>>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {'replay_epoch': 'epoch-a'},
        },
      }),
    );
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      received.add(frame);
      final method = frame['method'];
      Future<void>.delayed(answerAfter, () {
        final Object body = fail
            ? {'code': -32000, 'message': 'boom'}
            : switch (method) {
                'spawn_tree.list' => {'entries': <Object>[]},
                'process.list' => {'processes': <Object>[]},
                _ => <String, Object>{},
              };
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            if (fail) 'error': body else 'result': body,
          }),
        );
      });
    }
  });
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'n6a-coalesce',
      label: 'n6a',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'qa',
      dashboardUrl: 'http://127.0.0.1:${server.port}',
    ),
    dashboard: _TicketDashboardClient(),
  );
  addTearDown(client.close);
  final subscription = client.events.listen((_) {}, onError: (_) {});
  addTearDown(subscription.cancel);
  await client.connect();
  return (client, received);
}

int _count(List<Map<String, dynamic>> received, String method) =>
    received.where((frame) => frame['method'] == method).length;

void main() {
  test('concurrent identical snapshots share one spawn_tree.list and one '
      'process.list', () async {
    final (client, received) = await _open();

    await Future.wait([
      client.agentCenterSnapshot(runtimeSessionId: 'rt'),
      client.agentCenterSnapshot(runtimeSessionId: 'rt'),
      client.agentCenterSnapshot(runtimeSessionId: 'rt'),
    ]);
    expect(_count(received, 'spawn_tree.list'), 1);
    expect(_count(received, 'process.list'), 1);

    await client.agentCenterSnapshot(runtimeSessionId: 'rt');
    expect(_count(received, 'process.list'), 2, reason: 'settled: not cached');
  });

  test('different parameters are different reads', () async {
    final (client, received) = await _open();

    await Future.wait([
      client.agentCenterSnapshot(runtimeSessionId: 'rt-a'),
      client.agentCenterSnapshot(runtimeSessionId: 'rt-b'),
    ]);
    expect(_count(received, 'process.list'), 2);
  });

  test(
    'a failure reaches every coalesced caller and is not remembered',
    () async {
      final (client, received) = await _open(fail: true);

      final results = await Future.wait([
        client
            .agentCenterSnapshot(runtimeSessionId: 'rt')
            .then<Object?>((_) => null, onError: (Object e) => e),
        client
            .agentCenterSnapshot(runtimeSessionId: 'rt')
            .then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      expect(results.every((e) => e != null), isTrue);
      expect(_count(received, 'process.list'), 1);

      await client
          .agentCenterSnapshot(runtimeSessionId: 'rt')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(_count(received, 'process.list'), 2);
    },
  );
}
