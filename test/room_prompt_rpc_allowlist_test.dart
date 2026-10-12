import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-qa',
      );
}

/// Loopback fake gateway that records every method it receives.
Future<(HttpServer, List<(String, Map<String, dynamic>)>)> _server() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seen = <(String, Map<String, dynamic>)>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {'replay_epoch': 'room-prompts'},
        },
      }),
    );
    socket.listen((raw) {
      final rpc = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
      final method = rpc['method'] as String;
      if (method == 'gateway.ping') return;
      if (isClientCapabilitiesFrame(rpc)) {
        socket.add(jsonEncode(clientCapabilitiesResponse(rpc)));
        return;
      }
      seen.add((method, Map<String, dynamic>.from(rpc['params'] as Map)));
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': rpc['id'],
          'result': {'status': 'ok', 'sessions': const []},
        }),
      );
    });
  });
  return (server, seen);
}

TuiGatewayClient _client(HttpServer server, {required bool readOnly}) =>
    TuiGatewayClient(
      SavedConnection(
        id: 'room-prompts',
        label: 'Room prompts',
        host: '127.0.0.1',
        port: 8642,
        dashboardUrl: 'http://127.0.0.1:${server.port}',
        apiKey: String.fromCharCodes(const [113, 97]),
        readOnly: readOnly,
      ),
      dashboard: _TicketDashboardClient(),
    );

void main() {
  test('only room member compression gets the compute-host timeout', () {
    expect(
      TuiGatewayClient.roomPromptTimeoutFor('session.compress'),
      const Duration(seconds: 660),
    );
    expect(
      TuiGatewayClient.roomPromptTimeoutFor('session.resume'),
      const Duration(seconds: 15),
    );
    expect(
      TuiGatewayClient.roomPromptTimeoutFor('session.list'),
      const Duration(seconds: 15),
    );
  });

  test('room prompt RPCs pass through with their exact payload', () async {
    final (server, seen) = await _server();
    final client = _client(server, readOnly: false);
    addTearDown(() async {
      await client.close();
      await server.close(force: true);
    });
    await client.roomPromptRequest('request.answer', {
      'id': 'srq-1',
      'result': {'answer': 'Sí'},
    });
    await client.roomPromptRequest('session.compress', {
      'session_id': 'runtime-builder',
    });
    expect(seen.first.$1, 'request.answer');
    expect(seen.first.$2, {
      'id': 'srq-1',
      'result': {'answer': 'Sí'},
    });
    expect(seen.last.$1, 'session.compress');
    expect(seen.last.$2, {'session_id': 'runtime-builder'});
    await expectLater(
      client.roomPromptRequest('session.close', {'session_id': 'rt'}),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(seen.map((c) => c.$1), isNot(contains('session.close')));
  });

  test('a read-only connection may read prompts but never answer', () async {
    final (server, seen) = await _server();
    final client = _client(server, readOnly: true);
    addTearDown(() async {
      await client.close();
      await server.close(force: true);
    });
    await client.roomPromptRequest('session.active_list', const {});
    for (final method in const [
      'request.answer',
      'clarify.lock',
      'approval.respond',
      'session.interrupt',
      'session.compress',
    ]) {
      await expectLater(
        client.roomPromptRequest(method, const {}),
        throwsA(isA<TuiGatewayRpcError>()),
        reason: method,
      );
    }
    expect(seen.map((c) => c.$1), ['session.active_list']);
  });

  group('session.resume for a stalled room member', () {
    const exact = {
      'session_id': 'stored-review',
      'profile': 'review',
      'source': 'bot_room',
      'omit_messages': true,
    };

    test('passes only in the exact room-member shape', () async {
      final (server, seen) = await _server();
      final client = _client(server, readOnly: false);
      addTearDown(() async {
        await client.close();
        await server.close(force: true);
      });
      await client.roomPromptRequest('session.resume', exact);
      expect(seen.single.$1, 'session.resume');
      expect(seen.single.$2, exact);
      for (final params in <Map<String, dynamic>>[
        {...exact, 'source': 'desktop'},
        {...exact, 'omit_messages': false},
        {...exact, 'eager_build': true},
        {...exact, 'profile': ''},
        {...exact, 'session_id': ''},
        const {'session_id': 'stored-review', 'profile': 'review'},
      ]) {
        await expectLater(
          client.roomPromptRequest('session.resume', params),
          throwsA(isA<TuiGatewayRpcError>()),
          reason: '$params',
        );
      }
      expect(seen, hasLength(1));
    });

    test('a read-only connection never resumes', () async {
      final (server, seen) = await _server();
      final client = _client(server, readOnly: true);
      addTearDown(() async {
        await client.close();
        await server.close(force: true);
      });
      await expectLater(
        client.roomPromptRequest('session.resume', exact),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(seen, isEmpty);
    });
  });
}
