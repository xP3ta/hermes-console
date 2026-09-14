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
        credential: 'ticket-session-activity',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-session-activity',
    label: 'Session activity',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

void main() {
  test('session.activate conserva identidades y snapshot 0.19', () async {
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
            'result': frame['method'] == 'gateway.capabilities'
                ? {'per_session_exclusive_submit': true}
                : {
                    'session_id': 'runtime-live',
                    'session_key': 'durable-tip',
                    'running': true,
                    'status': 'streaming',
                    'message_count': 7,
                    'info': {'model': 'gpt-5.5-codex'},
                  },
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    final snapshot = await client.activateSession(
      'runtime-live',
      storedSessionId: 'durable-tip',
    );

    expect(snapshot.runtimeSessionId, 'runtime-live');
    expect(snapshot.storedSessionId, 'durable-tip');
    expect(snapshot.running, isTrue);
    expect(snapshot.info.model, 'gpt-5.5-codex');
    expect(requests.map((request) => request['method']), ['session.activate']);
    expect(requests.single['params'], {
      'session_id': 'runtime-live',
      'cols': 96,
    });
    expect(
      client.capabilityState(DesktopGatewayCapability.sessionActivate),
      DesktopGatewayCapabilityState.supported,
    );
  });

  test('active_list descarta filas malas y limita texto retenido', () async {
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
              'sessions': [
                {'id': true, 'preview': 'discard me'},
                {
                  'id': 'runtime-b',
                  'session_key': 'durable-b',
                  'current': true,
                  'status': 'working',
                  'last_active': 1784500000,
                  'started_at': 1784499900,
                  'message_count': 10,
                  'model': 'model-b',
                  'preview': List.filled(700, 'x').join(),
                  'title': 'Conversation B',
                  'system_prompt': 'must not survive',
                },
              ],
            },
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    final inventory = await client.listActiveSessions(
      currentRuntimeSessionId: 'runtime-b',
    );

    expect(inventory.hasMalformedRows, isTrue);
    expect(inventory.sessions, hasLength(1));
    final row = inventory.sessions.single;
    expect(row.runtimeSessionId, 'runtime-b');
    expect(row.storedSessionId, 'durable-b');
    expect(row.current, isTrue);
    expect(row.preview, hasLength(512));
    expect(row.messageCount, 10);
    expect(requests.single['params'], {'current_session_id': 'runtime-b'});
  });

  test('method-not-found se cachea hasta desconectar', () async {
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
          jsonEncode(
            rpcCount == 1
                ? {
                    'jsonrpc': '2.0',
                    'id': frame['id'],
                    'error': {'code': -32601, 'message': 'Method not found'},
                  }
                : {
                    'jsonrpc': '2.0',
                    'id': frame['id'],
                    'result': {'sessions': const []},
                  },
          ),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.listActiveSessions(),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.listActiveSessions(),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(rpcCount, 1);

    await client.disconnectIdle();
    final recovered = await client.listActiveSessions();
    expect(recovered.sessions, isEmpty);
    expect(rpcCount, 2);
  });

  test('payload raíz inválido marca solo active_list como invalid', () async {
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
            'result': {'sessions': 'invalid'},
          }),
        );
      }
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.listActiveSessions(),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(
      client.capabilityState(DesktopGatewayCapability.sessionActiveList),
      DesktopGatewayCapabilityState.invalid,
    );
    await expectLater(
      client.listActiveSessions(),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(rpcCount, 1);
  });
}
