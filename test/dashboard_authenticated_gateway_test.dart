import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

void main() {
  test('existing Dashboard password authority accepts official submit and fresh reconnect ticket', () async {
    DashboardClient.resetSharedPasswordSessionsForTesting();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final tickets = <String>{};
    final upgrades = <String>[];
    final paths = <String>[];
    final submits = <Map<String, dynamic>>[];
    var minted = 0;
    server.listen((request) async {
      paths.add(request.uri.path);
      if (request.uri.path == '/auth/password-login') {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body, {
          'provider': 'basic',
          'username': 'synthetic-user',
          'password': 'synthetic-password',
        });
        request.response.headers.set(
          HttpHeaders.setCookieHeader,
          'hermes_session_at=synthetic-cookie; HttpOnly; Path=/',
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true}');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/api/auth/ws-ticket') {
        expect(
          request.headers.value('cookie'),
          contains('hermes_session_at=synthetic-cookie'),
        );
        final ticket = 'synthetic-ticket-${++minted}';
        tickets.add(ticket);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'ticket': ticket, 'ttl_seconds': 30}),
        );
        await request.response.close();
        return;
      }
      expect(request.uri.path, '/api/ws');
      final ticket = request.uri.queryParameters['ticket'];
      expect(tickets.remove(ticket), isTrue);
      upgrades.add(ticket!);
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
        if (isClientCapabilitiesFrame(frame)) continue;
        Map<String, dynamic> result = {'status': 'ok'};
        if (frame['method'] == 'gateway.capabilities') {
          result = {'per_session_exclusive_submit': true};
        }
        if (frame['method'] == 'prompt.submit') {
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          submits.add(params);
          result = {
            'accepted': true,
            'client_turn_id': params['client_turn_id'],
            'server_turn_id': 'synthetic-server-turn-${submits.length}',
            'state': 'accepted',
            'duplicate': false,
          };
        }
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });
    final connection = SavedConnection(
      id: 'authenticated-owner',
      label: 'Existing',
      host: '127.0.0.1',
      port: 9131,
      apiKey: 'synthetic-gateway-key',
      dashboardUrl: 'http://127.0.0.1:${server.port}',
      dashboardAuthMode: AuthMode.basicAuth,
    );
    final dashboard = DashboardClient.forConnection(
      connection,
      secrets: const DashboardSecrets(
        username: 'synthetic-user',
        password: 'synthetic-password',
      ),
    );
    final gateway = TuiGatewayClient(connection, dashboard: dashboard);
    addTearDown(gateway.close);
    final first = await gateway.submitPromptIdempotent(
      'owned-runtime',
      'synthetic first',
      'synthetic-turn-1',
    );
    expect(first.accepted, isTrue);
    expect(first.serverTurnId, 'synthetic-server-turn-1');
    await gateway.disconnectIdle();
    final second = await gateway.submitPromptIdempotent(
      'owned-runtime',
      'synthetic second',
      'synthetic-turn-2',
    );
    expect(second.accepted, isTrue);
    expect(second.serverTurnId, 'synthetic-server-turn-2');
    expect(minted, 2);
    expect(upgrades.toSet(), hasLength(2));
    expect(tickets, isEmpty);
    expect(submits.map((p) => p['session_id']), everyElement('owned-runtime'));
    expect(paths.where((p) => p.startsWith('/bridge/')), isEmpty);
    expect(connection.apiKey, 'synthetic-gateway-key');
    dashboard.close();
  });
}
