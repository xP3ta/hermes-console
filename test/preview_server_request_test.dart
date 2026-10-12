import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// Loopback Hermes fake that can push server→client requests.
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
        if (!_frames.isClosed) _frames.add(frame);
        final method = frame['method'];
        if (method is! String) continue;
        final result = switch (method) {
          'client.capabilities' => {
            'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
          },
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
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
  final _frames = StreamController<Map<String, dynamic>>.broadcast();

  static Future<_Gateway> start() async =>
      _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  void pushServerRequest(
    String id,
    String method,
    Map<String, dynamic> params,
  ) => sockets.last.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': {'session_id': 'runtime-1', ...params},
    }),
  );

  Future<Map<String, dynamic>> nextFrame(
    bool Function(Map<String, dynamic>) where,
  ) {
    for (final frame in frames) {
      if (where(frame)) return Future.value(frame);
    }
    return _frames.stream.firstWhere(where);
  }

  Future<void> close() async {
    await _frames.close();
    await server.close(force: true);
  }
}

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-preview',
      );
}

void main() {
  late _Gateway gateway;

  setUp(() async => gateway = await _Gateway.start());
  tearDown(() => gateway.close());

  Future<TuiGatewayClient> connected() async {
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-preview',
        label: 'Preview',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    await client.connect();
    return client;
  }

  // Console renders no in-app browser, so Hermes must not wait on it: the
  // agent gets an error at once instead of a stalled turn.
  for (final entry in <String, Map<String, dynamic>>{
    'preview.read': {'start': 0, 'count': 20},
    'preview.act': {'action': 'click', 'ref': '@e1'},
  }.entries) {
    test(
      '${entry.key} from the server is refused with -32601 at once',
      () async {
        await connected();
        final id = 'srq-${entry.key.replaceAll('.', '')}01';

        gateway.pushServerRequest(id, entry.key, entry.value);
        final answer = await gateway
            .nextFrame((frame) => frame['id'] == id && frame['method'] == null)
            .timeout(const Duration(seconds: 1));

        expect((answer['error'] as Map)['code'], -32601);
        expect(answer.containsKey('result'), isFalse);
      },
    );
  }
}
