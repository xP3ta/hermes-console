import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import '../support/rpc_frame_helpers.dart';

final class _TicketDashboard extends DashboardClient {
  _TicketDashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-capabilities',
      );
}

TuiGatewayClient _clientFor(HttpServer server, {bool readOnly = false}) =>
    TuiGatewayClient(
      SavedConnection(
        id: 'conn-capabilities',
        label: 'Capabilities contract',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        readOnly: readOnly,
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboard(),
    );

Future<List<Map<String, dynamic>>> _serve(HttpServer server) async {
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
          'result': {'ok': true, 'plugins': <Object>[]},
        }),
      );
    }
  });
  return requests;
}

void main() {
  test(
    'plugins.manage list and install reach the gateway with their params',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = await _serve(server);
      final client = _clientFor(server);
      addTearDown(client.close);

      await client.capabilitiesRequest('plugins.manage', {
        'action': 'list',
        'profile': 'work',
      });
      await client.capabilitiesRequest('plugins.manage', {
        'action': 'install',
        'catalog_name': 'weather',
        'profile': 'work',
      });

      final sent = requests.where((f) => f['method'] == 'plugins.manage');
      expect(sent.map((f) => f['params']), [
        {'action': 'list', 'profile': 'work'},
        {'action': 'install', 'catalog_name': 'weather', 'profile': 'work'},
      ]);
    },
  );

  test('read-only reaches list but never a mutation or settings', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = await _serve(server);
    final client = _clientFor(server, readOnly: true);
    addTearDown(client.close);

    await client.capabilitiesRequest('plugins.manage', {'action': 'list'});
    for (final action in const [
      'install',
      'toggle',
      'update',
      'remove',
      'settings',
    ]) {
      await expectLater(
        client.capabilitiesRequest('plugins.manage', {'action': action}),
        throwsA(isA<TuiGatewayRpcError>()),
        reason: action,
      );
    }
    expect(
      requests
          .where((f) => f['method'] == 'plugins.manage')
          .map((f) => (f['params'] as Map)['action']),
      ['list'],
    );
  });

  test('a writable connection still rejects settings and onboarding', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = await _serve(server);
    final client = _clientFor(server);
    addTearDown(client.close);

    for (final action in const ['settings', 'onboarding']) {
      await expectLater(
        client.capabilitiesRequest('plugins.manage', {'action': action}),
        throwsA(isA<TuiGatewayRpcError>()),
        reason: action,
      );
    }
    expect(requests.where((f) => f['method'] == 'plugins.manage'), isEmpty);
  });
}
