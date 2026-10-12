import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/account_usage_fixtures.dart' as fx;
import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-account-usage',
      );
}

void main() {
  test('session.usage and usage.bars: exact methods and params', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        requests.add(frame);
        final result = frame['method'] == 'session.usage'
            ? fx.usage(account: fx.codexLines)
            : fx.barsAvailable;
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-account-usage',
        label: 'Account usage',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'unused',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final usage = await client.sessionUsage('runtime-usage');
    final bars = await client.usageBars();

    expect(usage['account_lines'], fx.codexLines);
    expect(bars['available'], isTrue);
    expect(requests.map((r) => r['method']), ['session.usage', 'usage.bars']);
    expect(requests.first['params'], {'session_id': 'runtime-usage'});
    expect(requests.last['params'], isEmpty);
  });
}
