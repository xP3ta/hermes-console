import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-model-catalog',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-model-catalog',
    label: 'Model catalog',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

void main() {
  test(
    'model.options usa el runtime y conserva capacidades por modelo',
    () async {
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
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'model': 'model-a',
                'provider': 'provider-a',
                'providers': [
                  {
                    'slug': 'provider-a',
                    'name': 'Provider A',
                    'authenticated': true,
                    'models': ['model-a'],
                    'capabilities': {
                      'model-a': {'fast': false, 'reasoning': true},
                    },
                  },
                ],
              },
            }),
          );
        }
      });
      final client = _clientFor(server);
      addTearDown(client.close);

      final catalog = await client.modelOptions('runtime-a', refresh: true);

      expect(catalog.currentModel, 'model-a');
      expect(
        catalog.optionFor('provider-a', 'model-a')?.capabilities.fast,
        false,
      );
      expect(
        catalog.optionFor('provider-a', 'model-a')?.capabilities.reasoning,
        true,
      );
      expect(requests.single['method'], 'model.options');
      expect(requests.single['params'], {
        'session_id': 'runtime-a',
        'explicit_only': true,
        'include_unconfigured': false,
        'refresh': true,
      });
      expect(
        client.capabilityState(DesktopGatewayCapability.modelOptions),
        DesktopGatewayCapabilityState.supported,
      );
    },
  );

  test('catálogo malformado se aísla como capacidad inválida', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var rpcCount = 0;
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
        rpcCount += 1;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {'providers': 'invalid'},
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.modelOptions('runtime-a'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.modelOptions('runtime-a'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(rpcCount, 1);
    expect(
      client.capabilityState(DesktopGatewayCapability.modelOptions),
      DesktopGatewayCapabilityState.invalid,
    );
  });
}
