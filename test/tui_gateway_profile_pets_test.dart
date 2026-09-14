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
        credential: 'ticket-qa',
      );
}

/// Levanta un gateway fake sobre WebSocket que graba los requests y responde
/// a los métodos `pet.*` según [handler]. Un método no cubierto recibe el
/// `-32601` estándar de JSON-RPC (method not found), como un gateway antiguo.
Future<({HttpServer server, List<Map<String, dynamic>> requests})>
_servePetGateway(
  Map<String, dynamic>? Function(String method, Map<String, dynamic> params)
  handler, {
  void Function(void Function(Map<String, dynamic> frame))? onSocket,
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
    onSocket?.call((frame) => socket.add(jsonEncode(frame)));
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      requests.add(frame);
      final method = frame['method'] as String;
      final params = Map<String, dynamic>.from(frame['params'] as Map? ?? {});
      final result = handler(method, params);
      if (result == null) {
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'error': {'code': -32601, 'message': 'Method not found'},
          }),
        );
      } else {
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    }
  });
  return (server: server, requests: requests);
}

TuiGatewayClient _clientFor(HttpServer server) {
  final connection = SavedConnection(
    id: 'conn-qa',
    label: 'QA',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  );
  return TuiGatewayClient(connection, dashboard: _TicketDashboardClient());
}

void main() {
  test(
    'pet.info envía knownRevision y parsea el spritesheet oficial completo',
    () async {
      final (:server, :requests) = await _servePetGateway((method, params) {
        if (method != 'pet.info') return null;
        return {
          'enabled': true,
          'slug': 'zoro',
          'displayName': 'Zoro',
          'mime': 'image/webp',
          'spritesheetBase64': 'UklGRg==',
          'spritesheetRevision': 'sha256:r2',
          'spritesheetUnchanged': false,
          'frameW': 192,
          'frameH': 208,
          'framesPerState': 8,
          'framesByState': {'idle': 8, 'walk': 6},
          'framesByRow': {'0': 8, '1': 6},
          'loopMs': 900,
          'scale': 1.25,
          'stateRows': ['idle', 'walk'],
        };
      });
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      final info = await client.profilePetInfo(
        profile: 'alpha',
        knownRevision: 'sha256:r1',
      );

      expect(requests.single['method'], 'pet.info');
      expect(requests.single['params'], {
        'profile': 'alpha',
        'knownRevision': 'sha256:r1',
      });
      expect(info.slug, 'zoro');
      expect(info.mime, 'image/webp');
      expect(info.spritesheetBase64, 'UklGRg==');
      expect(info.spritesheetRevision, 'sha256:r2');
      expect(info.spritesheetUnchanged, isFalse);
      expect(info.frameW, 192);
      expect(info.frameH, 208);
      expect(info.framesPerState, 8);
      expect(info.framesByState, {'idle': 8, 'walk': 6});
      expect(info.framesByRow, {'0': 8, '1': 6});
      expect(info.loopMs, 900);
      expect(info.scale, 1.25);
      expect(info.stateRows, ['idle', 'walk']);
    },
  );

  test(
    'pet.info acepta spritesheetUnchanged sin volver a exigir el base64',
    () async {
      final (:server, :requests) = await _servePetGateway((method, params) {
        if (method != 'pet.info') return null;
        return {
          'enabled': true,
          'slug': 'zoro',
          'displayName': 'Zoro',
          'mime': 'image/webp',
          'spritesheetRevision': 'sha256:r1',
          'spritesheetUnchanged': true,
          'frameW': 192,
          'frameH': 208,
          'framesPerState': 8,
          'framesByState': {'idle': 8},
          'framesByRow': {'0': 8},
          'loopMs': 900,
          'scale': 1.0,
          'stateRows': ['idle'],
        };
      });
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      final info = await client.profilePetInfo(
        profile: 'alpha',
        knownRevision: 'sha256:r1',
      );

      expect(requests.single['params']['knownRevision'], 'sha256:r1');
      expect(info.spritesheetRevision, 'sha256:r1');
      expect(info.spritesheetUnchanged, isTrue);
      expect(info.spritesheetBase64, isNull);
    },
  );

  test(
    'pet.info / pet.select envían el profile y parsean la respuesta',
    () async {
      final (:server, :requests) = await _servePetGateway((method, params) {
        switch (method) {
          case 'pet.info':
            return {
              'enabled': true,
              'slug': 'nimbus',
              'displayName': 'Nimbus',
              'scale': 1.0,
            };
          case 'pet.select':
            return {'ok': true, 'slug': params['slug'], 'displayName': 'Jinx'};
          case 'pet.disable':
            return {'ok': true};
        }
        return null;
      });
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      final info = await client.profilePetInfo(profile: 'alpha');
      expect(info.hasPet, isTrue);
      expect(info.slug, 'nimbus');
      expect(info.displayName, 'Nimbus');

      final selection = await client.profilePetSelect(
        profile: 'alpha',
        slug: 'jinx',
      );
      expect(selection.slug, 'jinx');
      expect(selection.displayName, 'Jinx');

      expect(await client.profilePetDisable(profile: 'alpha'), isTrue);

      expect(requests.map((r) => r['method']), [
        'pet.info',
        'pet.select',
        'pet.disable',
      ]);
      expect(requests[0]['params'], {'profile': 'alpha'});
      expect(requests[1]['params'], {'profile': 'alpha', 'slug': 'jinx'});
      expect(requests[2]['params'], {'profile': 'alpha'});
    },
  );

  test(
    'sin profile explícito no se envía el parámetro (perfil de arranque)',
    () async {
      final (:server, :requests) = await _servePetGateway(
        (method, params) => {'enabled': false},
      );
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      final info = await client.profilePetInfo();
      expect(info.hasPet, isFalse);
      expect(requests.single['params'], isEmpty);
    },
  );

  test(
    'pet.thumb devuelve el dataUri o null con ok:false (fail-open)',
    () async {
      final (:server, :requests) = await _servePetGateway((method, params) {
        if (method == 'pet.thumb' && params['slug'] == 'nimbus') {
          return {
            'ok': true,
            'slug': 'nimbus',
            'dataUri': 'data:image/png;base64,AA==',
          };
        }
        if (method == 'pet.thumb') {
          return {'ok': false, 'slug': params['slug']};
        }
        return null;
      });
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      expect(
        await client.profilePetThumb(profile: 'alpha', slug: 'nimbus'),
        'data:image/png;base64,AA==',
      );
      expect(
        await client.profilePetThumb(profile: 'alpha', slug: 'jinx'),
        isNull,
      );
      // `url` solo viaja cuando se informa (mascotas no instaladas).
      await client.profilePetThumb(slug: 'nimbus', url: 'https://x/y.webp');
      expect(requests.last['params'], {
        'slug': 'nimbus',
        'url': 'https://x/y.webp',
      });
    },
  );

  test('pet.gallery parsea la lista y descarta entradas malformadas', () async {
    final served = await _servePetGateway((method, params) {
      if (method == 'pet.gallery') {
        return {
          'enabled': true,
          'active': 'nimbus',
          'pets': [
            {'slug': 'nimbus', 'displayName': 'Nimbus', 'installed': true},
            {'slug': '', 'displayName': 'rota'},
            'ni-mapa',
            {'slug': 'jinx', 'displayName': 'Jinx', 'generated': true},
          ],
        };
      }
      return null;
    });
    addTearDown(served.server.close);
    final client = _clientFor(served.server);
    addTearDown(client.close);

    final gallery = await client.profilePetGallery(
      profile: 'alpha',
      localOnly: true,
    );
    expect(gallery.enabled, isTrue);
    expect(gallery.active, 'nimbus');
    expect(gallery.pets.map((p) => p.slug), ['nimbus', 'jinx']);
    expect(gallery.pets.first.installed, isTrue);
    expect(gallery.pets.last.generated, isTrue);
  });

  test(
    'fail-closed: gateway sin pet.* marca la capacidad y no reintenta',
    () async {
      final (:server, :requests) = await _servePetGateway(
        (method, params) => null, // -32601 para todo
      );
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      await expectLater(
        client.profilePetInfo(profile: 'alpha'),
        throwsA(
          isA<TuiGatewayRpcError>().having((e) => e.code, 'code', -32601),
        ),
      );
      // Segunda llamada: la capacidad ya está marcada como no soportada y el
      // cliente corta sin ir a la red.
      await expectLater(
        client.profilePetSelect(profile: 'alpha', slug: 'nimbus'),
        throwsA(
          isA<TuiGatewayRpcError>().having((e) => e.code, 'code', -32601),
        ),
      );
      expect(requests, hasLength(1));
    },
  );

  test(
    'los eventos pet.changed del broadcast global llegan al stream',
    () async {
      void Function(Map<String, dynamic>)? emit;
      final (:server, :requests) = await _servePetGateway(
        (method, params) => {'enabled': false},
        onSocket: (add) => emit = add,
      );
      addTearDown(server.close);
      final client = _clientFor(server);
      addTearDown(client.close);

      await client.connect();
      final changed = client.events.firstWhere((e) => e.type == 'pet.changed');
      emit!({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'pet.changed',
          'payload': {'enabled': true, 'slug': 'nimbus'},
        },
      });
      final event = await changed.timeout(const Duration(seconds: 2));
      expect(event.payload['slug'], 'nimbus');
      expect(requests, isEmpty); // el broadcast no necesita request previo
    },
  );

  test('valida profile y slug antes de tocar la red', () async {
    final (:server, :requests) = await _servePetGateway(
      (method, params) => {'enabled': false},
    );
    addTearDown(server.close);
    final client = _clientFor(server);
    addTearDown(client.close);

    await expectLater(
      client.profilePetInfo(profile: 'PERFIL INVALIDO'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.profilePetSelect(slug: '  '),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(requests, isEmpty);
  });
}
