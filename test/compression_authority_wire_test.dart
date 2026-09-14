import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/desktop_compression_fence_store.dart';

class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'local-synthetic-probe',
      );
}

void _emitGatewayReady(WebSocket socket) {
  socket.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': 'gateway.ready',
        'payload': {'replay_epoch': 'fixture-epoch', 'heartbeat': false},
      },
    }),
  );
}

class _Storage implements DesktopCompressionFenceStorage {
  String? value;
  Completer<void>? readEntered, releaseRead, writeEntered, releaseWrite;
  @override
  Future<String?> read() async {
    final release = releaseRead;
    if (release != null) {
      if (!readEntered!.isCompleted) readEntered!.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<void> write(String next) async {
    final release = releaseWrite;
    if (release != null) {
      if (!writeEntered!.isCompleted) writeEntered!.complete();
      await release.future;
    }
    value = next;
  }
}

class _Fixture {
  late HttpServer server;
  late TuiGatewayClient client;
  late ActiveChat chat;
  final storage = _Storage();
  final frames = <Map<String, dynamic>>[];
  final rest = <String>[];
  bool successfulReads = false;
  final sockets = <WebSocket>[];
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? respond;
  void Function(ActiveChatEvent)? onEvent;
  Future<void> start(
    String id, {
    bool allowUnownedDesktopSnapshotForTesting = false,
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final socket = await WebSocketTransformer.upgrade(req);
      sockets.add(socket);
      _emitGatewayReady(socket);
      socket.listen((raw) async {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        final result =
            await (respond?.call(frame) ?? Future.value(defaultResult(frame)));
        if (socket.readyState == WebSocket.open) {
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });
    });
    final conn = SavedConnection(
      id: 'independent-$id',
      label: 'Independent local fixture',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'local-test-not-a-real-secret',
      dashboardUrl: 'http://127.0.0.1:${server.port}',
    );
    client = TuiGatewayClient(conn, dashboard: _Dashboard());
    chat = ActiveChat(
      connection: conn,
      sessionId: 'stored-A',
      sessionTitle: 'Independent',
      notifications: null,
      onTerminal: () {},
      onEvent: (e) => onEvent?.call(e),
      desktopGateway: client,
      allowUnownedDesktopSnapshotForTesting:
          allowUnownedDesktopSnapshotForTesting,
      compressionFenceStore: DesktopCompressionFenceStore(
        storage: storage,
        mutationNamespaceForTesting: 'independent-$id',
      ),
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'local-test-not-a-real-secret',
        httpClient: MockClient((req) async {
          rest.add('${req.method} ${req.url.path}');
          return successfulReads
              ? http.Response('{"data":[]}', 200)
              : http.Response('{}', 500);
        }),
      ),
    );
  }

  Map<String, dynamic> defaultResult(Map<String, dynamic> f) =>
      switch (f['method']) {
        'gateway.capabilities' => {'per_session_exclusive_submit': true},
        'session.resume' => {
          'session_id': 'runtime-A',
          'session_key': (f['params'] as Map)['session_id'],
          'messages': <Object>[],
        },
        'session.compress' => {
          'compressed': false,
          'lock_held': true,
          'message': 'synthetic busy',
        },
        _ => <String, dynamic>{},
      };
  List<Object?> get methods => frames.map((f) => f['method']).toList();
  void trace(String label, DesktopCompressionPresentation? result) {}

  Future<void> close() async {
    chat.dispose();
    await client.close();
    for (final s in sockets) {
      await s.close();
    }
    await server.close(force: true);
  }
}

void main() {
  final identities = <String, Map<String, dynamic>>{
    'stored-alias-conflict': {
      'session_key': 'stored-A',
      'stored_session_id': 'stored-B',
    },
    'root-alias-conflict': {
      'session_key': 'stored-A',
      'lineage_root': 'stored-A',
      'info': {'lineage_root_id': 'stored-B'},
    },
    'info-stored-conflict': {
      'session_key': 'stored-A',
      'info': {'stored_session_id': 'stored-B'},
    },
    'info-runtime-conflict': {
      'session_key': 'stored-A',
      'info': {'session_id': 'runtime-B'},
    },
    'bad-root-type': {
      'session_key': 'stored-A',
      'info': {'lineage_root_id': 42},
    },
  };
  for (final entry in identities.entries) {
    test('INDEPENDENT identity ${entry.key}', () async {
      final f = _Fixture();
      await f.start(entry.key);
      addTearDown(f.close);
      f.respond = (frame) async => frame['method'] == 'session.resume'
          ? {'session_id': 'runtime-A', 'messages': <Object>[], ...entry.value}
          : f.defaultResult(frame);
      final result = await f.chat.compressDesktopSessionForPresentation();
      f.trace(entry.key, result);
      expect(f.methods, isNot(contains('session.compress')));
    });
  }
  test(
    'REGRESSION_COMP2A testing-only receipt cannot arm or dispatch',
    () async {
      final f = _Fixture();
      await f.start(
        'testing-only-receipt',
        allowUnownedDesktopSnapshotForTesting: true,
      );
      addTearDown(f.close);
      f.respond = (frame) async => frame['method'] == 'session.resume'
          ? {
              'session_id': 'runtime-A',
              'session_key': 'stored-A',
              'stored_session_id': 'stored-B',
              'messages': <Object>[],
            }
          : f.defaultResult(frame);

      await f.chat.compressDesktopSessionForPresentation();

      expect(f.methods, contains('session.resume'));
      expect(f.methods, isNot(contains('session.compress')));
      expect(f.storage.value, isNull, reason: 'testing receipt must not arm');
    },
  );
  test(
    'REGRESSION_COMP2A_FIX2 strict acquisition precedes testing fallback',
    () async {
      final f = _Fixture();
      await f.start(
        'strict-before-bypass',
        allowUnownedDesktopSnapshotForTesting: true,
      );
      addTearDown(f.close);
      expect(
        await f.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isTrue,
      );
      await f.chat.compressDesktopSessionForPresentation();
      expect(f.methods.where((m) => m == 'session.compress').length, 1);
      expect(f.storage.value, isNotNull);
    },
  );
  for (final kind in ['foreign', 'aliases-exact', 'root-conflict']) {
    test(
      'REGRESSION_COMP2A_FIX2 testing taint survives adoption $kind',
      () async {
        final f = _Fixture();
        await f.start(
          'taint-$kind',
          allowUnownedDesktopSnapshotForTesting: true,
        );
        addTearDown(f.close);
        f.respond = (frame) async => frame['method'] == 'session.resume'
            ? {
                'session_id': 'runtime-UNOWNED',
                'session_key': kind == 'foreign'
                    ? 'stored-FOREIGN'
                    : 'stored-A',
                if (kind == 'aliases-exact')
                  'stored_session_id': 'stored-OTHER',
                if (kind == 'root-conflict') 'lineage_root': 'stored-OTHER',
                'messages': <Object>[],
              }
            : f.defaultResult(frame);
        expect(
          await f.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
          isFalse,
        );
        expect(f.chat.desktopRuntimeSessionId, isNull);
        f.frames.clear();
        await f.chat.compressDesktopSessionForPresentation();
        await expectLater(
          f.chat.compressDesktopSession(),
          throwsA(isA<TuiGatewayRpcError>()),
        );
        expect(f.chat.bindSessionProfile('profile-B'), 'profile-B');
        f.successfulReads = true;
        // A subsequent testing hydration/adoption cannot clear the sticky taint.
        await f.chat.loadMessages(profile: 'profile-B');
        f.frames.clear();
        await f.chat.compressDesktopSessionForPresentation();
        expect(f.methods, isEmpty);
        expect(f.storage.value, isNull, reason: 'tainted binding cannot arm');
      },
    );
  }
  for (final entry in ['presentation', 'direct']) {
    test('REGRESSION_COMP2A_FIX2 external load revokes bound $entry', () async {
      final f = _Fixture();
      await f.start('external-load-$entry');
      addTearDown(f.close);
      expect(f.chat.bindSessionProfile('default'), 'default');
      f.successfulReads = true;
      expect(
        await f.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isTrue,
      );
      f.frames.clear();
      f.storage.readEntered = Completer<void>();
      f.storage.releaseRead = Completer<void>();
      final pending = entry == 'presentation'
          ? f.chat.compressDesktopSessionForPresentation().then<Object?>(
              (v) => v,
            )
          : f.chat.compressDesktopSession().then<Object?>(
              (v) => v,
              onError: (Object e) => e,
            );
      await f.storage.readEntered!.future;
      final refresh = f.chat.loadMessages();
      f.storage.releaseRead!.complete();
      await pending;
      await refresh;
      expect(
        f.methods,
        isEmpty,
        reason:
            'revoked authority must send no compress, replay, or fallback RPC',
      );
      expect(f.storage.value, isNull, reason: 'revoked operation cannot arm');
      // A genuinely new action after the external load still works once.
      await f.chat.compressDesktopSession();
      expect(f.methods.where((method) => method != 'subagent.list'), [
        'session.compress',
      ]);
    });
  }
  for (final invalidation in ['binding', 'profile', 'dispose']) {
    test(
      'INDEPENDENT before-acquisition-storage-await $invalidation',
      () async {
        final f = _Fixture();
        await f.start('storage-$invalidation');
        addTearDown(f.close);
        f.storage.readEntered = Completer<void>();
        f.storage.releaseRead = Completer<void>();
        final pending = f.chat.compressDesktopSessionForPresentation();
        await f.storage.readEntered!.future;
        switch (invalidation) {
          case 'binding':
            expect(f.chat.bindKnownStoredSession('stored-B'), isTrue);
          case 'profile':
            expect(f.chat.bindSessionProfile('profile-B'), 'profile-B');
          case 'dispose':
            f.chat.dispose();
        }
        f.storage.releaseRead!.complete();
        final result = await pending;
        f.trace('storage-$invalidation', result);
        expect(
          f.methods.where(
            (m) => [
              'session.resume',
              'session.activate',
              'session.create',
              'session.compress',
            ].contains(m),
          ),
          isEmpty,
        );
      },
    );
  }
  test(
    'INDEPENDENT concurrent acquisition cannot launder foreign binding',
    () async {
      final f = _Fixture();
      await f.start('concurrent-foreign-binding');
      addTearDown(f.close);
      final entered = Completer<void>(), release = Completer<void>();
      var count = 0;
      f.respond = (frame) async {
        if (frame['method'] != 'session.resume') return f.defaultResult(frame);
        count++;
        if (count == 1) {
          entered.complete();
          await release.future;
          return {'session_id': 'runtime-A', 'session_key': 'stored-A'};
        }
        return {'session_id': 'runtime-B', 'session_key': 'stored-B'};
      };
      final pending = f.chat.compressDesktopSessionForPresentation();
      await entered.future;
      expect(f.chat.bindKnownStoredSession('stored-B'), isTrue);
      final acquired = await f.chat.ensureDesktopRuntime(
        acquireForExplicitAction: true,
      );
      expect(acquired, isTrue);
      release.complete();
      final result = await pending;
      f.trace('concurrent-foreign-binding', result);
      expect(
        f.methods,
        isNot(contains('session.compress')),
        reason: 'A authorization must not become B without lineage proof',
      );
    },
  );
  for (final kind in ['foreign', 'missing']) {
    test('INDEPENDENT concurrent rejected acquisition $kind', () async {
      final f = _Fixture();
      await f.start('concurrent-rejected-$kind');
      addTearDown(f.close);
      final entered = Completer<void>(), release = Completer<void>();
      var count = 0;
      f.respond = (frame) async {
        if (frame['method'] != 'session.resume') return f.defaultResult(frame);
        if (++count == 1) {
          entered.complete();
          await release.future;
          return {'session_id': 'runtime-A', 'session_key': 'stored-A'};
        }
        return {
          'session_id': 'runtime-B',
          if (kind == 'foreign') 'session_key': 'stored-B',
        };
      };
      final pending = f.chat.compressDesktopSessionForPresentation();
      await entered.future;
      expect(
        await f.chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isFalse,
      );
      release.complete();
      final result = await pending;
      f.trace('concurrent-rejected-$kind', result);
      expect(f.methods, isNot(contains('session.compress')));
      expect(f.chat.storedSessionId, isNull);
    });
  }
  test('INDEPENDENT profile invalidation while durable arm waits', () async {
    final f = _Fixture();
    await f.start('arm-profile');
    addTearDown(f.close);
    f.storage.writeEntered = Completer<void>();
    f.storage.releaseWrite = Completer<void>();
    final pending = f.chat.compressDesktopSessionForPresentation();
    await f.storage.writeEntered!.future;
    expect(f.chat.bindSessionProfile('profile-B'), 'profile-B');
    f.storage.releaseWrite!.complete();
    final result = await pending;
    f.trace('arm-profile', result);
    expect(f.methods, isNot(contains('session.compress')));
  });
  for (final method in ['session.resume', 'session.create']) {
    test('INDEPENDENT zone admission $method', () async {
      final f = _Fixture();
      await f.start('zone-$method');
      addTearDown(f.close);
      final entered = Completer<void>(), release = Completer<void>();
      var allowed = true;
      f.respond = (frame) async {
        if (frame['method'] == 'gateway.capabilities') {
          entered.complete();
          await release.future;
        }
        return f.defaultResult(frame);
      };
      final pending = TuiGatewayClient.withCompressionAuthorization(
        () => allowed,
        () async {
          switch (method) {
            case 'session.resume':
              await f.client.resumeExisting('stored-A');
            case 'session.create':
              await f.client.createForFirstSubmit();
          }
        },
      ).then<Object?>((_) => null, onError: (Object error) => error);
      await entered.future;
      allowed = false;
      release.complete();
      expect(await pending, isA<TuiGatewayRpcError>());
      expect(f.methods, ['gateway.capabilities']);
    });
  }
  test(
    'INDEPENDENT session.activate bypasses false mutation authorization',
    () async {
      final f = _Fixture();
      await f.start('zone-session.activate-viewer');
      addTearDown(f.close);
      f.respond = (frame) async => frame['method'] == 'session.activate'
          ? {
              'session_id': 'runtime-A',
              'session_key': 'stored-A',
              'messages': <Object>[],
            }
          : f.defaultResult(frame);

      final snapshot = await TuiGatewayClient.withCompressionAuthorization(
        () => false,
        () =>
            f.client.activateSession('runtime-A', storedSessionId: 'stored-A'),
      );

      expect(snapshot.runtimeSessionId, 'runtime-A');
      expect(snapshot.storedSessionId, 'stored-A');
      expect(f.methods, ['session.activate']);
    },
  );
  test('INDEPENDENT passive reads do not acquire ownership', () async {
    final f = _Fixture();
    await f.start('passive');
    addTearDown(f.close);
    f.successfulReads = true;
    await f.chat.loadMessages();
    await f.chat.warmDesktopGateway();
    await f.chat.loadDesktopModelCatalog();
    await f.chat.ensureDesktopRuntime();
    f.trace('passive', null);
    expect(
      f.methods.where(
        (m) => [
          'session.resume',
          'session.activate',
          'session.create',
          'session.compress',
        ].contains(m),
      ),
      isEmpty,
    );
    expect(f.rest.every((m) => m.startsWith('GET ')), isTrue);
  });
  test('INDEPENDENT profile changed by acquisition callback', () async {
    final f = _Fixture();
    await f.start('callback-profile');
    addTearDown(f.close);
    var invalidated = false;
    f.onEvent = (e) {
      if (e == ActiveChatEvent.sessionInfo &&
          !invalidated &&
          f.chat.storedSessionId != null) {
        invalidated = true;
        f.chat.bindSessionProfile('profile-B');
      }
    };
    final result = await f.chat.compressDesktopSessionForPresentation();
    f.trace('callback-profile', result);
    expect(invalidated, isTrue);
    expect(f.methods, isNot(contains('session.compress')));
  });
}
