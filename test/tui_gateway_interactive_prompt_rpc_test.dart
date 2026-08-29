import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-interactive-rpc',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-interactive-rpc',
    label: 'Interactive RPC',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

void main() {
  test('clarify expired atraviesa el transporte real como terminal', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {'status': 'expired'},
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    final result = await client.respondToClarify(
      'clarify-expired',
      'respuesta',
      questionId: 'q0',
    );

    expect(result.status, DesktopPromptResponseStatus.expired);
    expect(result.isExpired, isTrue);
  });

  test('envía los cuatro payloads exactos de Hermes Desktop 0.19', () async {
    const sudoValue = 'ephemeral-sudo-test-value';
    const secretValue = 'ephemeral-secret-test-value';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final observed = <Map<String, Object?>>[];

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        final method = frame['method'] as String;
        final params = Map<String, dynamic>.from(frame['params'] as Map);
        final keys = params.keys.toList()..sort();
        final status = switch (method) {
          'clarify.respond' => 'ok',
          'sudo.respond' => 'expired',
          'secret.respond' => 'ok',
          'terminal.read.respond' => 'ok',
          _ => 'invalid',
        };

        observed.add(switch (method) {
          'clarify.respond' ||
          'terminal.read.respond' => {'method': method, 'params': params},
          'sudo.respond' => {
            'method': method,
            'keys': keys,
            'request_id': params['request_id'],
            'value_matches': params['password'] == sudoValue,
          },
          'secret.respond' => {
            'method': method,
            'keys': keys,
            'request_id': params['request_id'],
            'value_matches': params['value'] == secretValue,
          },
          _ => {'method': method, 'keys': keys},
        });
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {'status': status},
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    final sudo = EphemeralSensitiveValue(sudoValue);
    final secret = EphemeralSensitiveValue(secretValue);

    final clarifyResult = await client.respondToClarify(
      'clarify-opaque',
      'Respuesta elegida',
    );
    final sudoResult = await client.respondToSudo('sudo-opaque', sudo);
    final secretResult = await client.respondToSecret('secret-opaque', secret);
    final terminalResult = await client.respondToTerminalRead(
      'terminal-opaque',
    );

    expect(observed, [
      {
        'method': 'clarify.respond',
        'params': {
          'request_id': 'clarify-opaque',
          'answer': 'Respuesta elegida',
        },
      },
      {
        'method': 'sudo.respond',
        'keys': ['password', 'request_id'],
        'request_id': 'sudo-opaque',
        'value_matches': true,
      },
      {
        'method': 'secret.respond',
        'keys': ['request_id', 'value'],
        'request_id': 'secret-opaque',
        'value_matches': true,
      },
      {
        'method': 'terminal.read.respond',
        'params': {'request_id': 'terminal-opaque', 'text': ''},
      },
    ]);
    expect(clarifyResult.status, DesktopPromptResponseStatus.ok);
    expect(sudoResult.status, DesktopPromptResponseStatus.expired);
    expect(sudoResult.isExpired, isTrue);
    expect(secretResult.status, DesktopPromptResponseStatus.ok);
    expect(terminalResult.status, DesktopPromptResponseStatus.ok);
    expect(sudo.isDisposed, isTrue);
    expect(sudo.hasValue, isFalse);
    expect(secret.isDisposed, isTrue);
    expect(secret.hasValue, isFalse);
  });

  test('redacta el secreto antes de esperar la respuesta JSON-RPC', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requestReceived = Completer<void>();
    final releaseResponse = Completer<void>();
    addTearDown(() {
      if (!releaseResponse.isCompleted) releaseResponse.complete();
    });

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (!requestReceived.isCompleted) requestReceived.complete();
        await releaseResponse.future;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {'status': 'ok'},
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    final value = EphemeralSensitiveValue('one-shot-test-value');
    final response = client.respondToSecret('secret-one-shot', value);

    await requestReceived.future.timeout(const Duration(seconds: 2));
    expect(value.hasValue, isFalse);
    expect(value.isDisposed, isTrue);

    releaseResponse.complete();
    expect((await response).status, DesktopPromptResponseStatus.ok);
  });

  test(
    'redacta errores remotos que intenten repetir un valor sensible',
    () async {
      const sensitiveValue = 'must-not-escape-through-errors';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {
                'code': 4009,
                'message': 'rejected value ${params['password']}',
              },
            }),
          );
        }
      });

      final client = _clientFor(server);
      addTearDown(client.close);
      final value = EphemeralSensitiveValue(sensitiveValue);
      Object? failure;
      try {
        await client.respondToSudo('sudo-expired', value);
      } catch (error) {
        failure = error;
      }

      expect(
        failure,
        isA<TuiGatewayRpcError>()
            .having((error) => error.method, 'method', 'sudo.respond')
            .having((error) => error.code, 'code', 4009)
            .having(
              (error) => error.message,
              'message',
              'Hermes rejected the sensitive response',
            ),
      );
      expect(failure.toString(), isNot(contains(sensitiveValue)));
      expect(value.isDisposed, isTrue);
      expect(value.hasValue, isFalse);
    },
  );

  test('rechaza request_id vacío y consume igualmente el secreto', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final client = _clientFor(server);
    addTearDown(client.close);
    final value = EphemeralSensitiveValue('discarded-test-value');

    await expectLater(
      client.respondToSecret('  ', value),
      throwsA(
        isA<TuiGatewayRpcError>().having(
          (error) => error.method,
          'method',
          'secret.respond',
        ),
      ),
    );
    expect(value.isDisposed, isTrue);
    expect(value.hasValue, isFalse);
  });
}
