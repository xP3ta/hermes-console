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
    await client.submitQueuedPromptWithSurface('rt', 'siete', surface);
    await client.submitQueuedPromptIdempotentWithSurface(
      'rt',
      'ocho',
      'turn-8',
      surface,
    );
    await client.submitQueuedPrompt('rt', 'nueve');
    await client.submitQueuedPromptIdempotent('rt', 'diez', 'turn-10');

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
      {'session_id': 'rt', 'text': 'siete', 'queued': true, ...extra},
      {
        'session_id': 'rt',
        'text': 'ocho',
        'client_turn_id': 'turn-8',
        'queued': true,
        ...extra,
      },
      {'session_id': 'rt', 'text': 'nueve', 'queued': true},
      {
        'session_id': 'rt',
        'text': 'diez',
        'client_turn_id': 'turn-10',
        'queued': true,
      },
    ]);
    expect(
      submits.every((params) => !params.containsKey('voice_turn')),
      isTrue,
      reason:
          'GPT-Live delegations and typed prompts are not chained voice turns',
    );
    submits.clear();
    const spoken = PromptClientSurface.voiceChat();
    await client.submitPromptWithSurface('rt', 'spoken', spoken);
    await client.submitPromptIdempotentWithSurface(
      'rt',
      'spoken-id',
      'id',
      spoken,
    );
    await client.submitInterruptedPromptWithSurface(
      'rt',
      'spoken-interrupted',
      spoken,
    );
    await client.submitQueuedPromptWithSurface('rt', 'spoken-queued', spoken);
    await client.submitQueuedPromptIdempotentWithSurface(
      'rt',
      'spoken-queued-id',
      'qid',
      spoken,
    );
    await client.submitPrompt('rt', 'typed-after-spoken');
    expect(
      submits.take(5).every((params) => params['voice_turn'] == true),
      isTrue,
    );
    expect(
      submits
          .take(5)
          .every(
            (params) =>
                !params.containsKey('surface') &&
                !params.containsKey('voice_context'),
          ),
      isTrue,
    );
    expect(submits[2]['interrupted'], isTrue);
    expect(submits[3]['queued'], isTrue);
    expect(submits[4]['queued'], isTrue);
    expect(submits.last, {'session_id': 'rt', 'text': 'typed-after-spoken'});
  });
}
