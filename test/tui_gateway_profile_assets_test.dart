import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'profile-assets-test',
      );
}

SavedConnection _connection(int port) => SavedConnection(
  id: 'profile-assets',
  label: 'Profile assets',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'gateway-key',
  dashboardUrl: 'http://127.0.0.1:$port',
);

Future<HttpServer> _serve(
  FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> frame) reply,
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
      socket.add(jsonEncode(await reply(frame)));
    }
  });
  return server;
}

void main() {
  test('profiles.get_asset uses the official profile-scoped request', () async {
    final requests = <Map<String, dynamic>>[];
    final server = await _serve((frame) {
      requests.add(frame);
      return {
        'jsonrpc': '2.0',
        'id': frame['id'],
        'result': {
          'found': true,
          'mime': 'image/png',
          'size': 68,
          'data':
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        },
      };
    });
    addTearDown(server.close);
    final client = TuiGatewayClient(
      _connection(server.port),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final avatar = await client.profileAvatar('infra');

    expect(avatar, isA<AgentProfileAvatar>());
    expect(avatar!.mimeType, 'image/png');
    expect(avatar.bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(requests, hasLength(1));
    expect(requests.single['method'], 'profiles.get_asset');
    expect(requests.single['params'], {'name': 'infra', 'asset': 'avatar'});
    expect(
      client.capabilityState(DesktopGatewayCapability.profileAssets),
      DesktopGatewayCapabilityState.supported,
    );
  });

  test('missing profile avatar is a supported empty result', () async {
    final server = await _serve(
      (frame) => {
        'jsonrpc': '2.0',
        'id': frame['id'],
        'result': {'found': false},
      },
    );
    addTearDown(server.close);
    final client = TuiGatewayClient(
      _connection(server.port),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    expect(await client.profileAvatar('qa'), isNull);
    expect(
      client.capabilityState(DesktopGatewayCapability.profileAssets),
      DesktopGatewayCapabilityState.supported,
    );
  });

  test(
    'malformed avatar payload invalidates the optional capability',
    () async {
      final server = await _serve(
        (frame) => {
          'jsonrpc': '2.0',
          'id': frame['id'],
          'result': {'found': true, 'data': 'data:image/png;base64,YXZhdGFy'},
        },
      );
      addTearDown(server.close);
      final client = TuiGatewayClient(
        _connection(server.port),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.profileAvatar('infra'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(
        client.capabilityState(DesktopGatewayCapability.profileAssets),
        DesktopGatewayCapabilityState.invalid,
      );
    },
  );

  test('old gateways are probed once and then fail locally', () async {
    var requests = 0;
    final server = await _serve((frame) {
      requests++;
      return {
        'jsonrpc': '2.0',
        'id': frame['id'],
        'error': {'code': -32601, 'message': 'Method not found'},
      };
    });
    addTearDown(server.close);
    final client = TuiGatewayClient(
      _connection(server.port),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.profileAvatar('infra'),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', -32601),
      ),
    );
    await expectLater(
      client.profileAvatar('infra'),
      throwsA(isA<TuiGatewayRpcError>()),
    );

    expect(requests, 1);
    expect(
      client.capabilityState(DesktopGatewayCapability.profileAssets),
      DesktopGatewayCapabilityState.unsupported,
    );
  });

  test('invalid profile names never reach Hermes', () async {
    final client = TuiGatewayClient(
      _connection(1),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.profileAvatar('../default'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
  });
}
