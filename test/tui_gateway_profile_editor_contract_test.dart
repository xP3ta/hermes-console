import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-profile-editor',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-profile-editor',
    label: 'Profile Editor',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

/// PNG 1x1 válido reutilizado como data URI de avatar.
const _avatarDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// Servidor JSON-RPC WS de loopback que simula un Gateway Hermes con el
/// roster dado y registra cada método recibido.
Future<({HttpServer server, List<Map<String, dynamic>> requests})>
_bindGateway({
  required List<Map<String, dynamic>> profiles,
  Map<String, Map<String, dynamic> Function(Map<String, dynamic> params)>?
  extraHandlers,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
      final method = frame['method'] as String;
      final params = Map<String, dynamic>.from(frame['params'] as Map);
      late final Map<String, dynamic> result;
      switch (method) {
        case 'profiles.list':
          result = {'profiles': profiles};
        case 'profiles.configure':
          result =
              extraHandlers?[method]?.call(params) ??
              {
                'ok': true,
                'applied': {'ui_meta': true},
              };
        default:
          result =
              extraHandlers?[method]?.call(params) ??
              (throw StateError('Unexpected method $method'));
      }
      socket.add(
        jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
      );
    }
  });
  return (server: server, requests: requests);
}

void main() {
  test(
    'saveProfileBotMeta hace RMW oficial y conserva los campos ajenos',
    () async {
      final (:server, :requests) = await _bindGateway(
        profiles: [
          {
            'name': 'infra',
            'ui_meta': {
              'hermes-bots': {
                'chat': 'stored-infra',
                'title': 'Infra vieja',
                'group': 'Research',
                'desktopOnly': {'layout': 'compact', 'version': 2},
                'imageKind': 'photo',
                'custom': true,
              },
              'foreign-plugin': {'keep': true},
            },
          },
        ],
      );
      addTearDown(server.close);

      final client = _clientFor(server);
      addTearDown(client.close);
      await client.saveProfileBotMeta(
        profile: 'infra',
        title: 'Infra Lead',
        shape: 'cloud',
        colorHex: '#38BDF8',
      );

      final configure = requests.where(
        (r) => r['method'] == 'profiles.configure',
      );
      expect(configure, hasLength(1));
      expect(configure.single['params'], {
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {
            'chat': 'stored-infra',
            'title': 'Infra Lead',
            'group': 'Research',
            'desktopOnly': {'layout': 'compact', 'version': 2},
            'shape': 'cloud',
            'color': '#38bdf8',
            'imageKind': 'shape',
            'custom': true,
          },
        },
      });
    },
  );

  test('saveProfileBotMeta persiste false al desocultar y despinear', () async {
    final (:server, :requests) = await _bindGateway(
      profiles: [
        {
          'name': 'infra',
          'ui_meta': {
            'hermes-bots': {
              'chat': 'stored-infra',
              'hidden': true,
              'pinned': true,
              'futureDesktopField': {'version': 3},
            },
          },
        },
      ],
    );
    addTearDown(server.close);

    final client = _clientFor(server);
    addTearDown(client.close);
    await client.saveProfileBotMeta(
      profile: 'infra',
      hidden: false,
      pinned: false,
    );

    final configure = requests.singleWhere(
      (request) => request['method'] == 'profiles.configure',
    );
    expect(configure['params'], {
      'name': 'infra',
      'ui_meta': {
        'hermes-bots': {
          'chat': 'stored-infra',
          'hidden': false,
          'pinned': false,
          'futureDesktopField': {'version': 3},
        },
      },
    });
  });

  test('saveProfileBotMeta conserva un wire Blobatar con dos puntos', () async {
    final (:server, :requests) = await _bindGateway(
      profiles: [
        {
          'name': 'infra',
          'ui_meta': {
            'hermes-bots': {
              'chat': 'stored-infra',
              'group': 'Research',
              'futureDesktopField': 7,
            },
          },
        },
      ],
    );
    addTearDown(server.close);

    final client = _clientFor(server);
    addTearDown(client.close);
    await client.saveProfileBotMeta(
      profile: 'infra',
      shape: 'blobatar:nimbus:organic',
      colorHex: '#8B5CF6',
    );

    final configure = requests.singleWhere(
      (request) => request['method'] == 'profiles.configure',
    );
    expect(configure['params'], {
      'name': 'infra',
      'ui_meta': {
        'hermes-bots': {
          'chat': 'stored-infra',
          'group': 'Research',
          'futureDesktopField': 7,
          'shape': 'blobatar:nimbus:organic',
          'color': '#8b5cf6',
          'imageKind': 'shape',
          'custom': true,
        },
      },
    });
  });

  test(
    'saveProfileBotMeta preserva metadata desconocida sin interpretarla',
    () async {
      final unsafeValues = [
        '<svg xmlns="http://www.w3.org/2000/svg"><path /></svg>',
        'data:image/svg+xml;base64,PHN2Zy8+',
        'PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciLz4=',
      ];

      for (final unsafe in unsafeValues) {
        final (:server, :requests) = await _bindGateway(
          profiles: [
            {
              'name': 'infra',
              'ui_meta': {
                'hermes-bots': {
                  'chat': 'stored-infra',
                  'legacyPreview': unsafe,
                },
              },
            },
          ],
        );
        addTearDown(server.close);

        final client = _clientFor(server);
        addTearDown(client.close);
        await client.saveProfileBotMeta(
          profile: 'infra',
          shape: 'cloud',
          colorHex: '#38bdf8',
        );

        final configure = requests.singleWhere(
          (request) => request['method'] == 'profiles.configure',
        );
        final params = Map<String, dynamic>.from(configure['params'] as Map);
        final uiMeta = Map<String, dynamic>.from(params['ui_meta'] as Map);
        final botMeta = Map<String, dynamic>.from(uiMeta['hermes-bots'] as Map);
        expect(botMeta['legacyPreview'], unsafe, reason: unsafe);
        expect(botMeta['shape'], 'cloud');
        expect(botMeta['imageKind'], 'shape');
      }
    },
  );

  test('saveProfileBotMeta con título vacío elimina la clave', () async {
    final (:server, :requests) = await _bindGateway(
      profiles: [
        {
          'name': 'infra',
          'ui_meta': {
            'hermes-bots': {'chat': 'stored-infra', 'title': 'Infra'},
          },
        },
      ],
    );
    addTearDown(server.close);

    final client = _clientFor(server);
    addTearDown(client.close);
    await client.saveProfileBotMeta(profile: 'infra', title: '');

    final configure = requests.singleWhere(
      (r) => r['method'] == 'profiles.configure',
    );
    expect(configure['params'], {
      'name': 'infra',
      'ui_meta': {
        'hermes-bots': {'chat': 'stored-infra'},
      },
    });
  });

  test('saveProfileBotMeta exige la confirmación applied.ui_meta', () async {
    final (:server, :requests) = await _bindGateway(
      profiles: [
        {'name': 'infra'},
      ],
      extraHandlers: {
        'profiles.configure': (_) => {
          'ok': true,
          'applied': {'ui_meta': false},
        },
      },
    );
    addTearDown(server.close);

    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.saveProfileBotMeta(profile: 'infra', title: 'X'),
      throwsA(
        isA<TuiGatewayRpcError>().having(
          (error) => error.method,
          'method',
          'profiles.configure',
        ),
      ),
    );
    expect(requests, isNotEmpty);
  });

  test(
    'saveProfileBotMeta rechaza valores inválidos antes del transporte',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var requests = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
          }),
        );
        await for (final _ in socket) {
          requests++;
        }
      });

      final client = _clientFor(server);
      addTearDown(client.close);

      await expectLater(
        client.saveProfileBotMeta(profile: 'infra', shape: '../triangle'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.saveProfileBotMeta(profile: 'infra', colorHex: 'blue'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.saveProfileBotMeta(profile: 'Bad Name', title: 'X'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(requests, 0);
    },
  );

  test('setProfileAvatar envía el data URI validado al asset store', () async {
    final (:server, :requests) = await _bindGateway(
      profiles: [],
      extraHandlers: {
        'profiles.set_asset': (_) => {'ok': true, 'asset': 'avatar', 'size': 8},
      },
    );
    addTearDown(server.close);

    final client = _clientFor(server);
    addTearDown(client.close);
    await client.setProfileAvatar(profile: 'infra', dataUri: _avatarDataUri);

    expect(requests, hasLength(1));
    expect(requests.single['method'], 'profiles.set_asset');
    expect(requests.single['params'], {
      'name': 'infra',
      'asset': 'avatar',
      'data': _avatarDataUri,
    });
  });

  test(
    'setProfileAvatar rechaza payloads no raster antes del transporte',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var requests = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
          }),
        );
        await for (final _ in socket) {
          requests++;
        }
      });

      final client = _clientFor(server);
      addTearDown(client.close);

      await expectLater(
        client.setProfileAvatar(
          profile: 'infra',
          dataUri: 'data:image/svg+xml;base64,PHN2Zy8+',
        ),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(requests, 0);
    },
  );

  test('clearProfileAvatar emite set_asset con clear', () async {
    final (:server, :requests) = await _bindGateway(
      profiles: [],
      extraHandlers: {
        'profiles.set_asset': (_) => {'ok': true, 'asset': 'avatar', 'size': 0},
      },
    );
    addTearDown(server.close);

    final client = _clientFor(server);
    addTearDown(client.close);
    await client.clearProfileAvatar('infra');

    expect(requests.single['method'], 'profiles.set_asset');
    expect(requests.single['params'], {
      'name': 'infra',
      'asset': 'avatar',
      'clear': true,
    });
  });
}
