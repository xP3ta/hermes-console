import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-context-breakdown',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-context-breakdown',
    label: 'Context breakdown',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

void main() {
  test('session.context_breakdown usa la identidad runtime exacta', () async {
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
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'categories': [
                {
                  'id': 'conversation',
                  'label': 'Conversation',
                  'color': 'var(--ignored-on-android)',
                  'tokens': 4200,
                },
              ],
              'context_used': 5000,
              'context_max': 20000,
              'context_percent': 25,
              'estimated_total': 4800,
              'model': 'gpt-5.5',
            },
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    final breakdown = await client.contextBreakdown('runtime-context');

    expect(breakdown.contextUsed, 5000);
    expect(breakdown.categories.single.id, 'conversation');
    expect(requests.single['method'], 'session.context_breakdown');
    expect(requests.single['params'], {'session_id': 'runtime-context'});
    expect(
      client.capabilityState(DesktopGatewayCapability.sessionContextBreakdown),
      DesktopGatewayCapabilityState.supported,
    );
  });

  test('payload inválido se cachea como capability inválida', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var requests = 0;
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
        requests += 1;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {'categories': 'invalid'},
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.contextBreakdown('runtime-context'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.contextBreakdown('runtime-context'),
      throwsA(isA<TuiGatewayRpcError>()),
    );

    expect(requests, 1);
    expect(
      client.capabilityState(DesktopGatewayCapability.sessionContextBreakdown),
      DesktopGatewayCapabilityState.invalid,
    );
  });
}
