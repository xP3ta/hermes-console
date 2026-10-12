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
        credential: 'params-test-ticket',
      );
}

SavedConnection _connectionFor(int port) => SavedConnection(
  id: 'params-wire-test',
  label: 'Params wire test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
  dashboardUrl: 'http://127.0.0.1:$port',
);

void main() {
  test('typed sends put exactly the pre-surface params on the wire', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // The encoded params of every prompt.submit, key order included.
    final wire = <String>[];
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
          wire.add(jsonEncode(params));
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

    await client.submitPrompt('rt', 'plain');
    await client.submitInterruptedPrompt('rt', 'interrupted');
    await client.submitQueuedPrompt('rt', 'queued');
    await client.submitQueuedPromptIdempotent('rt', 'queued idem', 'turn-q');
    await client.submitPromptIdempotent('rt', 'idem', 'turn-i');

    // These literals are the params the client sent before the surface
    // metadata existed: same keys, same order, nothing added.
    expect(wire, [
      '{"session_id":"rt","text":"plain"}',
      '{"session_id":"rt","text":"interrupted","interrupted":true}',
      '{"session_id":"rt","text":"queued","queued":true}',
      '{"session_id":"rt","text":"queued idem","client_turn_id":"turn-q",'
          '"queued":true}',
      '{"session_id":"rt","text":"idem","client_turn_id":"turn-i"}',
    ]);
  });

  group('mergePromptSubmitParams', () {
    const base = {
      'session_id': 'rt',
      'text': 'hola',
      'client_turn_id': 'turn-1',
      'queued': true,
    };

    test('empty metadata returns the base unchanged, order included', () {
      final merged = mergePromptSubmitParams(base, const {});
      expect(jsonEncode(merged), jsonEncode(base));
    });

    test('metadata can never override or reorder the routing keys', () {
      final merged = mergePromptSubmitParams(base, {
        'session_id': 'other',
        'text': 'hijacked',
        'client_turn_id': 'turn-2',
        'queued': false,
        'surface': 'voice-live',
      });
      expect(merged['session_id'], 'rt');
      expect(merged['text'], 'hola');
      expect(merged['client_turn_id'], 'turn-1');
      expect(merged['queued'], true);
      expect(merged['surface'], 'voice-live');
      expect(merged.keys.toList(), [
        'session_id',
        'text',
        'client_turn_id',
        'queued',
        'surface',
      ]);
    });

    test('an interrupted base also keeps its flag', () {
      final merged = mergePromptSubmitParams(
        {'session_id': 'rt', 'text': 'x', 'interrupted': true},
        {'interrupted': false},
      );
      expect(merged['interrupted'], true);
    });
  });
}
