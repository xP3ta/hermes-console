import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/model_catalog_cache.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/mk1215_scripted_gateway_channel.dart';
import 'support/rpc_frame_helpers.dart';

// mk1215: the chat model picker must read `model.options` over the chat's own
// gateway socket even when the chat has no live runtime yet (Desktop
// `requestModelOptions`, apps/desktop/src/lib/model-options.ts), instead of
// going to the Mobile Bridge / Dashboard first.

class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'mk1215-synthetic',
      );
}

class _MemoryStorage implements CompressionRestoreStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async => value = next;
}

const _catalog = {
  'model': 'disk-model',
  'provider': 'provider-a',
  'providers': [
    {
      'slug': 'provider-a',
      'name': 'Provider A',
      'authenticated': true,
      'is_current': true,
      'models': ['disk-model', 'other-model'],
    },
  ],
};

class _Fixture {
  late HttpServer server;
  late TuiGatewayClient client;
  late ActiveChat chat;
  final frames = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];
  Map<String, dynamic> Function(Map<String, dynamic> frame)? respond;

  Future<void> start(String id, {String profile = 'work'}) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final socket = await WebSocketTransformer.upgrade(req);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'mk1215', 'heartbeat': false},
          },
        }),
      );
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        final reply =
            respond?.call(frame) ??
            {
              'result': switch (frame['method']) {
                'model.options' => _catalog,
                _ => <String, dynamic>{},
              },
            };
        if (socket.readyState != WebSocket.open) return;
        socket.add(jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], ...reply}));
      });
    });
    final conn = SavedConnection(
      id: 'mk1215-$id',
      label: 'mk1215 fixture',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:${server.port}',
    );
    client = TuiGatewayClient(conn, dashboard: _Dashboard());
    chat = ActiveChat(
      connection: conn,
      sessionId: 'draft-$id',
      sessionTitle: 'mk1215',
      sessionProfile: profile,
      notifications: null,
      onTerminal: () {},
      desktopGateway: client,
      modelCatalogCache: ModelCatalogCache(),
      compressionRestoreStore: CompressionRestoreStore(
        storage: _MemoryStorage(),
        mutationNamespaceForTesting: 'mk1215-$id',
      ),
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'unused',
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ),
    );
  }

  List<Map<String, dynamic>> get rpcs =>
      framesWithoutClientCapabilities(frames);

  Future<void> close() async {
    chat.dispose();
    await client.close();
    for (final s in sockets) {
      await s.close();
    }
    await server.close(force: true);
  }
}

class _WarmGateway implements HermesDesktopGlobalModelCatalogGateway {
  final calls = <String>[];
  @override
  Future<DesktopModelCatalog> globalModelOptions({
    String profile = '',
    bool refresh = false,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    calls.add(profile);
    return DesktopModelCatalog.fromJson(_catalog);
  }
}

void main() {
  test('mk1215: the sessionless read keeps one 6 s budget for the handshake '
      'and the RPC together', () {
    fakeAsync((async) {
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'mk1215-budget',
          label: 'mk1215 budget',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'k',
          dashboardUrl: 'http://127.0.0.1:1',
        ),
        dashboard: _Dashboard(),
        heartbeatInterval: Duration.zero,
        now: () => DateTime(2026).add(async.elapsed),
        // The handshake takes 5 s and model.options never answers.
        channelFactory: (_, _) => ScriptedGatewayChannel(
          readyAfter: const Duration(seconds: 5),
          respond: (frame) =>
              frame['method'] == 'model.options' ? null : <String, dynamic>{},
        ),
      );
      Object? error;
      Duration? settledAt;
      client
          .globalModelOptions(profile: 'work')
          .then<void>(
            (_) => settledAt = async.elapsed,
            onError: (Object e) {
              error = e;
              settledAt = async.elapsed;
            },
          );
      async.elapse(const Duration(milliseconds: 5999));
      expect(settledAt, isNull, reason: 'still inside the budget');
      async.elapse(const Duration(milliseconds: 1));
      expect(
        settledAt,
        const Duration(seconds: 6),
        reason: 'a 5 s handshake leaves 1 s for the RPC, not another 6 s',
      );
      expect(error, isA<TuiGatewayRpcError>());
      expect(
        (error! as TuiGatewayRpcError).failureKind,
        TuiGatewayRpcFailureKind.timeout,
      );
      unawaited(client.close());
      async.elapse(const Duration(seconds: 30));
    });
  });

  test(
    'mk1215: sin runtime, model.options va por el socket del chat sin sesión '
    'y con el perfil del chat',
    () async {
      final f = _Fixture();
      await f.start('sessionless');
      addTearDown(f.close);
      expect(f.chat.hasDesktopRuntime, isFalse);

      final watch = Stopwatch()..start();
      final catalog = await f.chat.loadDesktopModelCatalog();
      watch.stop();
      // ignore: avoid_print
      print(
        'mk1215 sessionless model.options: ${watch.elapsedMilliseconds} ms',
      );

      expect(catalog, isNotNull);
      expect(catalog!.currentModel, 'disk-model');
      expect(catalog.providers.single.models, ['disk-model', 'other-model']);
      final calls = f.rpcs.where((r) => r['method'] == 'model.options');
      expect(calls, hasLength(1));
      expect(calls.single['params'], {
        'profile': 'work',
        'explicit_only': true,
        'include_unconfigured': false,
        'refresh': false,
      });
      // Listing models never acquires or creates a runtime.
      expect(
        f.rpcs.map((r) => r['method']),
        isNot(
          anyOf(
            contains('session.resume'),
            contains('session.activate'),
            contains('session.create'),
          ),
        ),
      );
      expect(f.chat.hasDesktopRuntime, isFalse);

      // A second open on the same connection/profile is served from cache.
      final again = await f.chat.loadDesktopModelCatalog();
      expect(again, same(catalog));
      expect(f.rpcs.where((r) => r['method'] == 'model.options'), hasLength(1));
    },
  );

  test('mk1215: el perfil por defecto no envía profile', () async {
    final f = _Fixture();
    await f.start('default-profile', profile: '');
    addTearDown(f.close);

    expect(await f.chat.loadDesktopModelCatalog(), isNotNull);
    final params =
        f.rpcs.singleWhere((r) => r['method'] == 'model.options')['params']
            as Map;
    expect(params.containsKey('profile'), isFalse);
    expect(params.containsKey('session_id'), isFalse);
  });

  test(
    'mk1215: un servidor sin model.options degrada a null (fallbacks)',
    () async {
      final f = _Fixture();
      await f.start('unsupported');
      addTearDown(f.close);
      f.respond = (frame) => frame['method'] == 'model.options'
          ? {
              'error': {'code': -32601, 'message': 'Method not found'},
            }
          : {'result': <String, dynamic>{}};

      expect(await f.chat.loadDesktopModelCatalog(), isNull);
      // The unsupported capability is remembered: no second probe.
      expect(await f.chat.loadDesktopModelCatalog(), isNull);
      expect(f.rpcs.where((r) => r['method'] == 'model.options'), hasLength(1));
    },
  );

  test('mk1215: un error del servidor degrada a null sin lanzar', () async {
    final f = _Fixture();
    await f.start('server-error');
    addTearDown(f.close);
    f.respond = (frame) => frame['method'] == 'model.options'
        ? {
            'error': {'code': 5033, 'message': 'boom'},
          }
        : {'result': <String, dynamic>{}};

    expect(await f.chat.loadDesktopModelCatalog(), isNull);
  });
  test(
    'mk1215: con el socket propio aún cerrado usa el socket compartido caliente',
    () async {
      final f = _Fixture();
      await f.start('warm');
      addTearDown(f.close);
      final warm = _WarmGateway();
      expect(f.client.isConnected, isFalse);

      final catalog = await f.chat.loadDesktopModelCatalog(warmGateway: warm);

      expect(catalog?.currentModel, 'disk-model');
      expect(warm.calls, ['work']);
      expect(f.rpcs, isEmpty, reason: 'the chat socket is not dialled');
    },
  );
}
