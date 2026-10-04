import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/prompt_client_surface.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'surface-test-ticket',
      );
}

SavedConnection _connectionFor(int port) => SavedConnection(
  id: 'surface-wire-test',
  label: 'Surface wire test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
  dashboardUrl: 'http://127.0.0.1:$port',
);

void main() {
  test('surface variants add surface/voice_context to prompt.submit', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final submits = <Map<String, dynamic>>[];
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
        final method = frame['method'] as String;
        if (isClientCapabilitiesFrame(frame)) continue;
        Map<String, dynamic> result = {'status': 'ok'};
        if (method == 'gateway.capabilities') {
          result = {'per_session_exclusive_submit': true};
        } else if (method == 'prompt.submit') {
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          submits.add(params);
          result = {
            'accepted': true,
            'client_turn_id': params['client_turn_id'],
            'server_turn_id': 'server-turn',
            'state': 'accepted',
            'duplicate': false,
          };
        }
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });
    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    const surface = PromptClientSurface.voiceLive(
      voiceContext: 'User: hola\nVoice assistant: dime',
    );

    await client.submitPromptWithSurface('rt', 'uno', surface);
    await client.submitPromptIdempotentWithSurface(
      'rt',
      'dos',
      'turn-2',
      surface,
    );
    await client.submitInterruptedPromptWithSurface('rt', 'tres', surface);
    await client.submitPrompt('rt', 'cuatro');
    await client.submitPromptIdempotent('rt', 'cinco', 'turn-5');
    await client.submitInterruptedPrompt('rt', 'seis');

    const extra = {
      'surface': 'voice-live',
      'voice_context': 'User: hola\nVoice assistant: dime',
    };
    expect(submits, [
      {'session_id': 'rt', 'text': 'uno', ...extra},
      {'session_id': 'rt', 'text': 'dos', 'client_turn_id': 'turn-2', ...extra},
      {'session_id': 'rt', 'text': 'tres', 'interrupted': true, ...extra},
      {'session_id': 'rt', 'text': 'cuatro'},
      {'session_id': 'rt', 'text': 'cinco', 'client_turn_id': 'turn-5'},
      {'session_id': 'rt', 'text': 'seis', 'interrupted': true},
    ]);
  });
}
