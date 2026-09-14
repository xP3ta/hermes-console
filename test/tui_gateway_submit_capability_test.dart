import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/compression_dispatcher.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';

class _CapabilityDashboardClient extends DashboardClient {
  _CapabilityDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'capability-test-ticket',
      );
}

SavedConnection _connectionFor(int port) => SavedConnection(
  id: 'capability-test',
  label: 'Capability test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: String.fromCharCodes(const [113, 97]),
  dashboardUrl: 'http://127.0.0.1:$port',
);

void main() {
  test(
    'REGRESSION_COMP_PREFLIGHT revalidates after asynchronous admission',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final entered = Completer<void>(), release = Completer<void>();
      final methods = <String>[];
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
          methods.add(frame['method'] as String);
          if (frame['method'] == 'gateway.capabilities') {
            entered.complete();
            await release.future;
          }
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': frame['method'] == 'gateway.capabilities'
                  ? {'per_session_exclusive_submit': true}
                  : {'status': 'lock_held'},
            }),
          );
        }
      });
      final client = TuiGatewayClient(
        _connectionFor(server.port),
        dashboard: _CapabilityDashboardClient(),
      );
      addTearDown(client.close);
      var current = true;
      final running = CompressionDispatcher(client).dispatch(
        'runtime-1',
        focusTopic: '',
        connectionEpoch: 1,
        sessionEpoch: 1,
        stillValid: () => current,
        matchesRoot: (_) => true,
      );
      await entered.future;
      current = false;
      release.complete();
      final result = await running;
      expect(methods, ['gateway.capabilities']);
      expect(result.evidence.outcome, DesktopCompressionOutcome.notDispatched);
    },
  );
  test('literal false capability blocks prompt before the wire', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
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
        final method = frame['method'] as String;
        methods.add(method);
        final result = switch (method) {
          'gateway.capabilities' => {'per_session_exclusive_submit': false},
          'prompt.submit' => {'status': 'ok'},
          _ => <String, dynamic>{'status': 'ok'},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });

    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _CapabilityDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.submitPrompt('runtime-1', 'hola'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.compressSession('runtime-1'),
      throwsA(
        isA<TuiGatewayRpcError>()
            .having((e) => e.method, 'method', 'session.compress')
            .having(
              (e) => e.origin,
              'origin',
              CompressionFailureOrigin.localPreflight,
            )
            .having(
              (e) => e.compressionReason,
              'compressionReason',
              CompressionFailureReason.exclusiveSubmitCapabilityDenied,
            ),
      ),
    );
    expect(methods, ['gateway.capabilities']);
  });

  test('capability RPC failures become a safe local denial', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
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
        methods.add(frame['method'] as String);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'error': {
              'code': -32601,
              'message': 'private session=secret-session pid=2658179',
              'data': {'reasoning': 'never expose this'},
            },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _CapabilityDashboardClient(),
    );
    addTearDown(client.close);

    TuiGatewayRpcError? denial;
    try {
      await client.submitPrompt('runtime-1', 'hola');
    } on TuiGatewayRpcError catch (error) {
      denial = error;
    }
    expect(denial, isNotNull);
    expect(denial!.method, 'prompt.submit');
    expect(denial.code, isNull);
    expect(denial.data, {'reason': 'EXCLUSIVE_SUBMIT_CAPABILITY_DENIED'});
    expect(
      denial.compressionReason,
      CompressionFailureReason.exclusiveSubmitCapabilityDenied,
    );
    expect(denial.message, 'Hermes Agent cannot safely accept this message');
    expect(denial.toString(), isNot(contains('secret-session')));
    expect(denial.toString(), isNot(contains('2658179')));
    expect(methods, ['gateway.capabilities']);
  });

  test(
    'recovery preserves an unknown capability RPC as a remote terminal error',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final methods = <String>[];
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
          methods.add(frame['method'] as String);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {
                'code': 712345,
                'message': 'private remote capability failure',
              },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        _connectionFor(server.port),
        dashboard: _CapabilityDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.resumeExistingForRecovery('stored-chat'),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', 'gateway.capabilities')
              .having((error) => error.code, 'code', 712345)
              .having(
                (error) => error.origin,
                'origin',
                CompressionFailureOrigin.remoteRpc,
              ),
        ),
      );
      expect(methods, ['gateway.capabilities']);
    },
  );

  test('malformed capability envelope cannot authorize a prompt', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
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
        final method = frame['method'] as String;
        methods.add(method);
        socket.add(
          jsonEncode({
            'jsonrpc': method == 'gateway.capabilities' ? '1.0' : '2.0',
            'id': frame['id'],
            'result': method == 'gateway.capabilities'
                ? {'per_session_exclusive_submit': true}
                : {'status': 'ok'},
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _CapabilityDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.submitPrompt('runtime-1', 'hola'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(methods, ['gateway.capabilities']);
  });

  test(
    'steer and redirect require a literal exclusive capability before wire',
    () async {
      for (final capability in <Map<String, dynamic>>[
        {'per_session_exclusive_submit': false},
        const <String, dynamic>{},
        {'per_session_exclusive_submit': 'true'},
      ]) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final methods = <String>[];
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': <String, dynamic>{},
              },
            }),
          );
          await for (final raw in socket) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            final method = frame['method'] as String;
            methods.add(method);
            final result = switch (method) {
              'gateway.capabilities' => capability,
              'session.steer' => {'status': 'queued'},
              'session.redirect' => {'status': 'redirected'},
              _ => <String, dynamic>{'status': 'ok'},
            };
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': result,
              }),
            );
          }
        });

        final client = TuiGatewayClient(
          _connectionFor(server.port),
          dashboard: _CapabilityDashboardClient(),
        );
        try {
          await expectLater(
            client.steer('runtime-1', 'corrige'),
            throwsA(isA<TuiGatewayRpcError>()),
          );
          await expectLater(
            client.redirect('runtime-1', 'corrige'),
            throwsA(isA<TuiGatewayRpcError>()),
          );
          expect(methods, ['gateway.capabilities']);
        } finally {
          await client.close();
          await server.close(force: true);
        }
      }
    },
  );

  test(
    'runtime creation and prompt-adjacent mutations share the fence',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final methods = <String>[];
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
          final method = frame['method'] as String;
          methods.add(method);
          final result = method == 'gateway.capabilities'
              ? <String, dynamic>{'per_session_exclusive_submit': false}
              : <String, dynamic>{
                  'session_id': 'runtime-1',
                  'session_key': 'stored-chat',
                  'messages': <Object>[],
                };
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });

      final client = TuiGatewayClient(
        _connectionFor(server.port),
        dashboard: _CapabilityDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.resumeExisting('stored-chat'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.createForFirstSubmit(),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.resumeExistingForRecovery('stored-chat'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      final activation = await client.activateSession(
        'runtime-1',
        storedSessionId: 'stored-chat',
      );
      expect(activation.runtimeSessionId, 'runtime-1');
      await expectLater(
        client.compressSession('runtime-1'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.attachImageBytes(
          'runtime-1',
          filename: 'image.png',
          contentBase64: 'aW1hZ2U=',
        ),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.attachFileBytes(
          'runtime-1',
          filename: 'note.txt',
          mimeType: 'text/plain',
          contentBase64: 'dGV4dA==',
        ),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.detachImage('runtime-1', '/tmp/image.png'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(methods, ['gateway.capabilities', 'session.activate']);
    },
  );

  test('idempotent prompt is fenced before the wire', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
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
        final method = frame['method'] as String;
        methods.add(method);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': method == 'gateway.capabilities'
                ? {'per_session_exclusive_submit': false}
                : {
                    'accepted': true,
                    'client_turn_id': 'request-1',
                    'status': 'accepted',
                  },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _CapabilityDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.submitPromptIdempotent('runtime-1', 'hola', 'request-1'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(methods, ['gateway.capabilities']);
  });

  test('all prompt-submit variants use the same fence', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
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
        final method = frame['method'] as String;
        methods.add(method);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': method == 'gateway.capabilities'
                ? {'per_session_exclusive_submit': false}
                : {'status': 'ok', 'row_id': 1},
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _CapabilityDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.submitInterruptedPrompt('runtime-1', 'continúa'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.submitRewindPrompt('runtime-1', 'corrige', 1),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.submitDurableRewindPrompt(
        'runtime-1',
        'corrige durable',
        1,
        truncateBeforeRowId: 7,
      ),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(methods, ['gateway.capabilities']);
  });

  test('reconnect invalidates the capability decision', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methodsByConnection = <List<String>>[];
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
        }),
      );
      final connectionIndex = methodsByConnection.length;
      methodsByConnection.add(<String>[]);
      sockets.add(socket);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        final method = frame['method'] as String;
        methodsByConnection[connectionIndex].add(method);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': method == 'gateway.capabilities'
                ? {'per_session_exclusive_submit': connectionIndex == 0}
                : {'status': 'ok'},
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _CapabilityDashboardClient(),
    );
    addTearDown(client.close);

    await client.submitPrompt('runtime-1', 'primero');
    await sockets.single.close();
    final disconnectDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (client.isConnected && DateTime.now().isBefore(disconnectDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(client.isConnected, isFalse);

    await expectLater(
      client.steer('runtime-1', 'segundo'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.redirect('runtime-1', 'tercero'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(methodsByConnection, [
      ['gateway.capabilities', 'prompt.submit'],
      ['gateway.capabilities'],
    ]);
  });

  test('slash and command dispatch are fenced before the wire', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
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
        final method = frame['method'] as String;
        methods.add(method);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': method == 'gateway.capabilities'
                ? {'per_session_exclusive_submit': false}
                : {'type': 'exec', 'status': 'accepted', 'output': 'unsafe'},
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _CapabilityDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.slashExec('runtime-1', 'help'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.commandDispatch('runtime-1', name: 'help'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(methods, ['gateway.capabilities']);
  });

  test('concurrent prompts share one capability probe', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    final firstCapabilitySeen = Completer<void>();
    final releaseCapability = Completer<void>();
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
        final method = frame['method'] as String;
        methods.add(method);
        if (method == 'gateway.capabilities') {
          if (!firstCapabilitySeen.isCompleted) firstCapabilitySeen.complete();
          unawaited(() async {
            await releaseCapability.future;
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {'per_session_exclusive_submit': true},
              }),
            );
          }());
          continue;
        }
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {'status': 'ok'},
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      _connectionFor(server.port),
      dashboard: _CapabilityDashboardClient(),
    );
    addTearDown(client.close);

    final first = client.submitPrompt('runtime-1', 'uno');
    await firstCapabilitySeen.future.timeout(const Duration(seconds: 2));
    final second = client.submitPrompt('runtime-1', 'dos');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    releaseCapability.complete();
    await Future.wait([first, second]);

    expect(
      methods.where((method) => method == 'gateway.capabilities').length,
      1,
    );
    expect(methods.where((method) => method == 'prompt.submit').length, 2);
  });

  test(
    'roster-bound resume keeps active-list and resume on one socket',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final methods = <String>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'lease-A'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'] as String;
          methods.add(method);
          final result = switch (method) {
            'session.active_list' => {
              'sessions': [
                {'id': 'runtime-advertised', 'session_key': 'stored-chat'},
              ],
            },
            'gateway.capabilities' => {'per_session_exclusive_submit': true},
            'session.resume' => {
              'session_id': 'runtime-advertised',
              'session_key': 'stored-chat',
              'messages': <Object>[],
              'messages_omitted': true,
            },
            _ => <String, dynamic>{'status': 'ok'},
          };
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });

      final client = TuiGatewayClient(
        _connectionFor(server.port),
        dashboard: _CapabilityDashboardClient(),
      );
      addTearDown(client.close);

      final recovery = await client.resumeAdvertisedExistingForRecovery(
        'stored-chat',
      );
      final snapshot = recovery.snapshot;
      expect(snapshot.runtimeSessionId, 'runtime-advertised');
      expect(snapshot.storedSessionId, 'stored-chat');
      expect(client.consumeRosterBoundRecovery(recovery), isTrue);
      expect(client.consumeRosterBoundRecovery(recovery), isFalse);
      expect(methods, [
        'session.active_list',
        'gateway.capabilities',
        'session.resume',
      ]);
    },
  );

  test(
    'roster-bound resume never crosses rotation after active-list',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final methodsByConnection = <List<String>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        final connectionIndex = methodsByConnection.length;
        methodsByConnection.add(<String>[]);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'lease-$connectionIndex'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'] as String;
          methodsByConnection[connectionIndex].add(method);
          if (method == 'session.active_list') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {
                  'sessions': [
                    {
                      'id': 'runtime-from-retired-socket',
                      'session_key': 'stored-chat',
                    },
                  ],
                },
              }),
            );
            await socket.close();
            continue;
          }
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': method == 'gateway.capabilities'
                  ? {'per_session_exclusive_submit': true}
                  : {
                      'session_id': 'runtime-must-not-bind',
                      'session_key': 'stored-chat',
                      'messages': <Object>[],
                    },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        _connectionFor(server.port),
        dashboard: _CapabilityDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.resumeAdvertisedExistingForRecovery('stored-chat'),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.failureKind,
            'failureKind',
            TuiGatewayRpcFailureKind.connectionLost,
          ),
        ),
      );
      expect(methodsByConnection, [
        ['session.active_list'],
      ]);
    },
  );
}
