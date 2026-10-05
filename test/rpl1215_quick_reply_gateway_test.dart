import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/utils/chat_quick_replies.dart';

import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'quick-replies-test',
      );
}

SavedConnection _connection(int port, {bool readOnly = false}) =>
    SavedConnection(
      id: 'quick-replies',
      label: 'Quick replies',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:$port',
      readOnly: readOnly,
    );

Future<HttpServer> _serve(
  List<Map<String, dynamic>> requests,
  Map<String, dynamic> Function(Map<String, dynamic> frame) reply,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
      socket.add(jsonEncode(reply(frame)));
    }
  });
  return server;
}

Future<TuiGatewayClient> _client(
  List<Map<String, dynamic>> requests,
  Map<String, dynamic> Function(Map<String, dynamic> frame) reply, {
  bool readOnly = false,
}) async {
  final server = await _serve(requests, reply);
  addTearDown(server.close);
  final client = TuiGatewayClient(
    _connection(server.port, readOnly: readOnly),
    dashboard: _TicketDashboardClient(),
  );
  addTearDown(client.close);
  return client;
}

void main() {
  test(
    'llm.oneshot carries only the two last messages, task backend',
    () async {
      final requests = <Map<String, dynamic>>[];
      final client = await _client(
        requests,
        (frame) => {
          'jsonrpc': '2.0',
          'id': frame['id'],
          'result': {
            'text': '- Sí, adelante\n- Muéstrame el diff\n- ¿Y tests?',
          },
        },
      );

      expect(client, isA<HermesQuickReplySuggestionGateway>());
      expect(client.quickReplySuggestionsAvailable, isTrue);
      final replies = await client.suggestQuickReplies(
        lastAssistant: 'He cambiado el parser.',
        lastUser: 'Arregla el parser',
        profile: 'infra',
      );

      expect(replies, ['Sí, adelante', 'Muéstrame el diff', '¿Y tests?']);
      expect(requests, hasLength(1));
      expect(requests.single['method'], 'llm.oneshot');
      final params = requests.single['params'] as Map<String, dynamic>;
      expect(params, {
        'instructions': smartQuickReplyInstructions,
        'input': smartQuickReplyInput(
          lastAssistant: 'He cambiado el parser.',
          lastUser: 'Arregla el parser',
        ),
        'max_tokens': 120,
        'temperature': 0.4,
        'profile': 'infra',
      });
      // No live session lends its (main, pricier) model.
      expect(params.containsKey('session_id'), isFalse);
    },
  );

  test('a read-only connection never spends a model call', () async {
    final requests = <Map<String, dynamic>>[];
    final client = await _client(
      requests,
      (frame) => {
        'jsonrpc': '2.0',
        'id': frame['id'],
        'result': {'text': 'x'},
      },
      readOnly: true,
    );

    expect(client.quickReplySuggestionsAvailable, isFalse);
    expect(
      await client.suggestQuickReplies(lastAssistant: 'a', lastUser: 'b'),
      isEmpty,
    );
    expect(requests, isEmpty);
  });

  test('a server without llm.oneshot hides it afterwards', () async {
    final requests = <Map<String, dynamic>>[];
    final client = await _client(
      requests,
      (frame) => {
        'jsonrpc': '2.0',
        'id': frame['id'],
        'error': {'code': -32601, 'message': 'method not found'},
      },
    );

    expect(
      await client.suggestQuickReplies(lastAssistant: 'a', lastUser: 'b'),
      isEmpty,
    );
    expect(
      client.capabilityState(DesktopGatewayCapability.llmOneshot),
      DesktopGatewayCapabilityState.unsupported,
    );
    expect(client.quickReplySuggestionsAvailable, isFalse);
    expect(
      await client.suggestQuickReplies(lastAssistant: 'a', lastUser: 'b'),
      isEmpty,
    );
    expect(requests, hasLength(1));
  });

  test('a failed generation yields no replies', () async {
    final requests = <Map<String, dynamic>>[];
    final client = await _client(
      requests,
      (frame) => {
        'jsonrpc': '2.0',
        'id': frame['id'],
        'error': {'code': 5030, 'message': 'one-shot generation failed'},
      },
    );

    expect(
      await client.suggestQuickReplies(lastAssistant: 'a', lastUser: 'b'),
      isEmpty,
    );
    expect(client.quickReplySuggestionsAvailable, isTrue);
  });
}
