import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class _TicketDashboard extends DashboardClient {
  _TicketDashboard() : super(host: '127.0.0.1', manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'test-ticket',
      );
}

void main() {
  for (final status in ['rejected', 'malformed']) {
    test('wire steer status $status has the correct queue safety', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final calls = <String>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'steer-test'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'] as String;
          calls.add(method);
          final result = switch (method) {
            'gateway.capabilities' => {'per_session_exclusive_submit': true},
            'session.resume' => {'session_id': 'runtime-steer'},
            'session.steer' => {'status': status},
            _ => <String, dynamic>{},
          };
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'steer-$status',
          label: 'Steer',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'unused',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboard(),
      );
      addTearDown(client.close);
      final binding = await client.resumeSession('stored-steer');
      Object? failure;
      try {
        await client.steer(binding.runtimeSessionId, 'guide');
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<TuiGatewayRpcError>());
      final error = failure as TuiGatewayRpcError;
      expect(error.method, 'session.steer');
      expect(
        error.code,
        status == 'rejected' ? TuiGatewayRpcError.steerRejectedCode : null,
      );
      expect(activeChatSteerFailureIsSafeToQueue(error), status == 'rejected');
      expect(calls.where((method) => method == 'session.steer'), hasLength(1));
    });
  }
}
