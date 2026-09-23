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
        credential: 'ticket-subagent-interrupt',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-subagent-interrupt',
    label: 'Subagent interrupt',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

void main() {
  test('subagent.interrupt usa el id opaco exacto', () async {
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
            'result': {'found': true, 'subagent_id': 'child-opaque-a'},
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    final result = await client.interruptSubagent(
      'runtime-parent',
      'child-opaque-a',
    );

    expect(result.found, isTrue);
    expect(result.subagentId, 'child-opaque-a');
    expect(requests.single['method'], 'subagent.interrupt');
    expect(requests.single['params'], {
      'session_id': 'runtime-parent',
      'subagent_id': 'child-opaque-a',
    });
    expect(
      client.capabilityState(DesktopGatewayCapability.subagentInterrupt),
      DesktopGatewayCapabilityState.supported,
    );
  });

  test(
    'found false es una respuesta válida y no inventa cancelación',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
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
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {'found': false, 'subagent_id': 'child-missing'},
            }),
          );
        }
      });
      final client = _clientFor(server);
      addTearDown(client.close);

      final result = await client.interruptSubagent(
        'runtime-parent',
        'child-missing',
      );

      expect(result.found, isFalse);
      expect(result.subagentId, 'child-missing');
    },
  );

  test('payload malformado invalida solo la capability', () async {
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
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        rpcCount += 1;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {'found': true, 'subagent_id': 'different-child'},
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.interruptSubagent('runtime-parent', 'requested-child'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.interruptSubagent('runtime-parent', 'requested-child'),
      throwsA(isA<TuiGatewayRpcError>()),
    );

    expect(rpcCount, 1);
    expect(
      client.capabilityState(DesktopGatewayCapability.subagentInterrupt),
      DesktopGatewayCapabilityState.invalid,
    );
  });

  test('method-not-found se cachea como unsupported', () async {
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
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        rpcCount += 1;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'error': {'code': -32601, 'message': 'Method not found'},
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.interruptSubagent('runtime-parent', 'child-old-server'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.interruptSubagent('runtime-parent', 'child-old-server'),
      throwsA(isA<TuiGatewayRpcError>()),
    );

    expect(rpcCount, 1);
    expect(
      client.capabilityState(DesktopGatewayCapability.subagentInterrupt),
      DesktopGatewayCapabilityState.unsupported,
    );
  });
}
