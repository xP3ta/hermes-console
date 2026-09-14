import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-session-config',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-session-config',
    label: 'Session config',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

void main() {
  test('crea la primera sesión capturando toda la configuración', () async {
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
                    'session_id': 'runtime-created-configured',
                    'stored_session_id': 'stored-created-configured',
                  },
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    final snapshot = await client.createForFirstSubmitConfigured(
      profile: 'coding',
      seedMessages: const [
        {'role': 'user', 'content': 'seed'},
      ],
      config: DesktopSessionCreateConfig(
        model: DesktopModelSelection(
          modelId: 'openai/gpt-5.5-codex',
          providerSlug: 'openai-codex',
        ),
        reasoningEffort: DesktopReasoningEffort.high,
        fastMode: DesktopFastMode.normal,
        title: 'Bot Chat',
        hidden: true,
      ),
    );

    expect(snapshot.created, isTrue);
    expect(snapshot.runtimeSessionId, 'runtime-created-configured');
    expect(requests.map((request) => request['method']), [
      'gateway.capabilities',
      'session.create',
    ]);
    expect(requests[1]['params'], {
      'source': 'desktop',
      'profile': 'coding',
      'title': 'Bot Chat',
      'hidden': true,
      'model': 'openai/gpt-5.5-codex',
      'provider': 'openai-codex',
      'reasoning_effort': 'high',
      'fast': false,
      'close_on_disconnect': false,
      'messages': const [
        {'role': 'user', 'content': 'seed'},
      ],
    });
  });

  test(
    'envía config.set session-scoped con payloads deterministas 0.19',
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
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          requests.add(frame);
          final key = params['key'] as String;
          final confirmRequired =
              key == 'model' && params['confirm_expensive_model'] == false;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'key': key,
                'value': switch (key) {
                  'model' => 'openai/gpt-5.5-codex',
                  'reasoning' => params['value'],
                  'fast' => params['value'],
                  _ => 'invalid',
                },
                'scope': 'session',
                'confirm_required': confirmRequired,
                if (confirmRequired)
                  'confirm_message': 'This model may be expensive',
              },
            }),
          );
        }
      });

      final client = _clientFor(server);
      addTearDown(client.close);
      final model = DesktopModelSelection(
        modelId: 'openai/gpt-5.5-codex',
        providerSlug: 'openai-codex',
      );

      final confirmation = await client.setSessionModel('runtime-a', model);
      final confirmed = await client.setSessionModel(
        'runtime-a',
        model,
        confirmExpensiveModel: true,
      );
      final reasoning = await client.setSessionReasoning(
        'runtime-a',
        DesktopReasoningEffort.none,
      );
      final fast = await client.setSessionFastMode(
        'runtime-a',
        DesktopFastMode.normal,
      );

      expect(confirmation.confirmRequired, isTrue);
      expect(confirmation.confirmMessage, 'This model may be expensive');
      expect(confirmed.confirmRequired, isFalse);
      expect(reasoning.value, 'none');
      expect(fast.value, 'normal');
      expect(requests.map((request) => request['method']), [
        'config.set',
        'config.set',
        'config.set',
        'config.set',
      ]);
      expect(requests.map((request) => request['params']), [
        {
          'session_id': 'runtime-a',
          'key': 'model',
          'value': 'openai/gpt-5.5-codex --provider openai-codex --session',
          'confirm_expensive_model': false,
        },
        {
          'session_id': 'runtime-a',
          'key': 'model',
          'value': 'openai/gpt-5.5-codex --provider openai-codex --session',
          'confirm_expensive_model': true,
        },
        {'session_id': 'runtime-a', 'key': 'reasoning', 'value': 'none'},
        {'session_id': 'runtime-a', 'key': 'fast', 'value': 'normal'},
      ]);
    },
  );

  test('rechaza respuestas globales o con clave distinta', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var responseIndex = 0;

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
        final malformed = responseIndex++ == 0
            ? <String, dynamic>{
                'key': 'fast',
                'value': 'fast',
                'scope': 'global',
              }
            : <String, dynamic>{
                'key': 'model',
                'value': 'unexpected',
                'scope': 'session',
              };
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': malformed,
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    final invalidResponse = isA<TuiGatewayRpcError>()
        .having((error) => error.method, 'method', 'config.set')
        .having(
          (error) => error.message,
          'message',
          'Hermes returned an invalid session config response',
        );

    await expectLater(
      client.setSessionFastMode('runtime-a', DesktopFastMode.fast),
      throwsA(invalidResponse),
    );
    await expectLater(
      client.setSessionReasoning('runtime-a', DesktopReasoningEffort.low),
      throwsA(invalidResponse),
    );
  });

  test('rechaza runtime vacío antes de abrir el transporte', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var connections = 0;
    server.listen((request) async {
      connections += 1;
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
        }),
      );
      await socket.close();
    });
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.setSessionFastMode('  ', DesktopFastMode.fast),
      throwsA(
        isA<TuiGatewayRpcError>()
            .having((error) => error.method, 'method', 'config.set')
            .having(
              (error) => error.message,
              'message',
              'Missing runtime session identity',
            ),
      ),
    );
    expect(connections, 0);
  });
}
