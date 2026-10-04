import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// Loopback Hermes fake: answers the handshake and records client RPCs.
class _Gateway {
  _Gateway._(this.server) {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        final method = frame['method'];
        if (method is! String) continue;
        final result = switch (method) {
          'client.capabilities' => {
            'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
          },
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'session.resume' => {
            'session_id': 'watch-runtime-1',
            'session_key': (frame['params'] as Map)['session_id'],
            'running': true,
            'messages': <Object>[],
            'info': {'lazy': true},
          },
          'session.close' => {'closed': true},
          _ => <String, dynamic>{'status': 'ok'},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });
  }

  final HttpServer server;
  final sockets = <WebSocket>[];
  final frames = <Map<String, dynamic>>[];

  static Future<_Gateway> start() async =>
      _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Iterable<Map<String, dynamic>> calls(String method) =>
      frames.where((frame) => frame['method'] == method);

  Future<void> close() => server.close(force: true);
}

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-watch',
      );
}

void main() {
  late _Gateway gateway;

  setUp(() async => gateway = await _Gateway.start());
  tearDown(() => gateway.close());

  TuiGatewayClient clientFor() {
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-watch',
        label: 'Watch',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    return client;
  }

  test('resumeWatchSession asks for a lazy watch of the child under the '
      'parent profile', () async {
    final client = clientFor();

    final snapshot = await client.resumeWatchSession(
      'child-1',
      profile: ' parent-profile ',
    );

    expect(snapshot.runtimeSessionId, 'watch-runtime-1');
    expect(snapshot.running, isTrue);
    final resume = gateway.calls('session.resume').single;
    expect(resume['params'], {
      'session_id': 'child-1',
      'source': 'desktop',
      'cols': 96,
      'lazy': true,
      'profile': 'parent-profile',
    });
  });

  test(
    'a watch runtime is not adopted as the socket legacy runtime or watchdog anchor',
    () async {
      final client = clientFor();

      await client.resumeWatchSession('child-1', profile: 'parent-profile');

      expect(client.watchedRuntimesForTesting, isEmpty);
    },
  );

  test('closing the watch runtime sends one session.close for it', () async {
    final client = clientFor();
    final snapshot = await client.resumeWatchSession('child-1', profile: '');

    expect(await client.closeSession(snapshot.runtimeSessionId), isTrue);

    final closes = gateway.calls('session.close').toList();
    expect(closes, hasLength(1));
    expect(closes.single['params'], {'session_id': 'watch-runtime-1'});
    expect(
      (gateway.calls('session.resume').single['params'] as Map).containsKey(
        'profile',
      ),
      isFalse,
      reason: 'an empty profile is omitted, never sent as ""',
    );
  });
}
