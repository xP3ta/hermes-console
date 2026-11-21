// The `moa.*` frames the server wrote while the client's socket was cut come
// back through the contiguous replay of the reconnect once, in order, with
// their payload, and the live stream goes on after them (Desktop trusts the
// transport's per-session sequence the same way, apps/shared/src/
// json-rpc-gateway.ts; what the chat does with each frame is in
// moa_events_test.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

final class _Ticket extends DashboardClient {
  _Ticket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-moa',
      );
}

Map<String, dynamic> _row(int seq, String type, Map<String, dynamic> payload) =>
    {'type': type, 'session_id': 'runtime-1', 'seq': seq, 'payload': payload};

Map<String, dynamic> _frame(int seq, String type, Map<String, dynamic> p) => {
  'jsonrpc': '2.0',
  'method': 'event',
  'params': _row(seq, type, p),
};

const _gapReference = {
  'label': 'model-b',
  'text': 'Beta says 43',
  'index': 2,
  'count': 2,
};

void main() {
  test('frames of a cut replay once, in order, then live goes on', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var connections = 0;
    final firstDelivered = Completer<void>();
    final secondLive = Completer<void>();
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
      connections++;
      if (connections == 1) {
        socket.add(
          jsonEncode(
            _frame(1, 'moa.progress', const {
              'label': 'model-a',
              'refs_done': 1,
              'refs_total': 2,
            }),
          ),
        );
        socket.add(
          jsonEncode(
            _frame(2, 'moa.reference', const {
              'label': 'model-a',
              'text': 'Alpha says 42',
              'index': 1,
              'count': 2,
            }),
          ),
        );
        await firstDelivered.future.timeout(const Duration(seconds: 5));
        await socket.close();
        return;
      }
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] != 'session.events.since') continue;
        expect((frame['params'] as Map)['last_seen'], 2);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'epoch': 'epoch-a',
              'truncated': false,
              'events': [
                _row(3, 'moa.reference', _gapReference),
                _row(4, 'moa.phase', const {'phase': 'aggregator'}),
              ],
              'count': 2,
              'latest_seq': 4,
            },
          }),
        );
        socket.add(
          jsonEncode(
            _frame(5, 'moa.reference', const {
              'label': 'model-c',
              'text': 'Gamma says 44',
              'index': 3,
              'count': 3,
            }),
          ),
        );
        if (!secondLive.isCompleted) secondLive.complete();
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-moa-replay',
        label: 'moa replay',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'unused',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _Ticket(),
    );
    addTearDown(client.close);
    final seen = <TuiGatewayEvent>[];
    final disconnected = Completer<void>();
    final subscription = client.events.listen(
      (event) {
        if (event.sessionId != 'runtime-1') return;
        seen.add(event);
        if (seen.length == 2 && !firstDelivered.isCompleted) {
          firstDelivered.complete();
        }
      },
      onError: (Object _, StackTrace _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    addTearDown(subscription.cancel);

    await client.connect();
    await disconnected.future.timeout(const Duration(seconds: 5));
    await client.connect();
    await secondLive.future.timeout(const Duration(seconds: 5));
    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return seen.length < 5;
    }).timeout(const Duration(seconds: 5));
    // Nothing more arrives: no frame is delivered twice.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      [for (final event in seen) (event.sequence, event.type)],
      [
        (1, 'moa.progress'),
        (2, 'moa.reference'),
        (3, 'moa.reference'),
        (4, 'moa.phase'),
        (5, 'moa.reference'),
      ],
    );
    expect(seen[2].payload['text'], 'Beta says 43');
    expect(seen[3].payload['phase'], 'aggregator');
    expect(seen.map((event) => event.replayed), [
      false,
      false,
      true,
      true,
      false,
    ]);
  });
}
