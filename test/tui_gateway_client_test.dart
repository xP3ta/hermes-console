import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';

import 'support/projected_compression_reply.dart';
import 'support/rpc_frame_helpers.dart';

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

void main() {
  test('reconnect backoff uses full jitter and caps at fifteen seconds', () {
    final samples = <double>[0, 0.5, 1, 1, 1, 1].iterator;
    final backoff = GatewayReconnectBackoff(
      random: () {
        samples.moveNext();
        return samples.current;
      },
    );

    expect(backoff.nextDelay(), Duration.zero);
    expect(backoff.nextDelay(), const Duration(seconds: 1));
    expect(backoff.nextDelay(), const Duration(seconds: 4));
    expect(backoff.nextDelay(), const Duration(seconds: 8));
    expect(backoff.nextDelay(), const Duration(seconds: 15));
    expect(backoff.nextDelay(), const Duration(seconds: 15));

    final reset = GatewayReconnectBackoff(random: () => 1);
    reset.nextDelay();
    reset.nextDelay();
    reset.markHealthy();
    expect(reset.nextDelay(), const Duration(seconds: 1));
  });

  test(
    'failed real WebSocket upgrade preserves package typed wrapper',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'failed-real-websocket-upgrade',
          label: 'Failed real WebSocket upgrade',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.connect(),
        throwsA(isA<WebSocketChannelException>()),
      );
    },
  );

  test(
    'malformed raw frame fails pending capability proof immediately and safely',
    () async {
      const privateMarker = 'PRIVATE_CAPABILITY_FRAME_MARKER';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] == 'gateway.capabilities') {
            socket.add('$privateMarker{');
          }
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'malformed-capability-frame',
          label: 'Malformed capability frame',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final logs = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = previousDebugPrint);

      final stopwatch = Stopwatch()..start();
      await expectLater(
        client.resumeExistingForRecovery('stored-malformed-capability'),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', 'gateway.capabilities')
              .having(
                (error) => error.origin,
                'origin',
                CompressionFailureOrigin.malformed,
              )
              .having((error) => error.code, 'code', isNull)
              .having((error) => error.data, 'data', isEmpty)
              .having(
                (error) => error.message,
                'message',
                'Invalid JSON-RPC frame',
              ),
        ),
      );
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(logs.join('\n'), isNot(contains(privateMarker)));
    },
    timeout: const Timeout(Duration(seconds: 3)),
  );

  test(
    'valid UTF-8 byte/view frames work while scalar/list frames are inert',
    () async {
      const privateMarker = 'PRIVATE_RESUME_FRAME_MARKER';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] == 'gateway.capabilities') {
            final response = utf8.encode(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {'per_session_exclusive_submit': true},
              }),
            );
            final padded = Uint8List(response.length + 2)
              ..setRange(1, response.length + 1, response);
            socket.add(Uint8List.sublistView(padded, 1, response.length + 1));
          } else if (frame['method'] == 'session.resume') {
            socket.add(jsonEncode([privateMarker]));
            socket.add('42');
            final response = utf8.encode(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {
                  'session_id': 'runtime-byte-view',
                  'stored_session_id': 'stored-non-map-resume',
                  'created': false,
                },
              }),
            );
            final padded = Uint8List(response.length + 4)
              ..setRange(2, response.length + 2, response);
            socket.add(Uint8List.sublistView(padded, 2, response.length + 2));
          }
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'non-map-resume-frame',
          label: 'Non-map resume frame',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final logs = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = previousDebugPrint);

      final stopwatch = Stopwatch()..start();
      final snapshot = await client.resumeExistingForRecovery(
        'stored-non-map-resume',
      );
      stopwatch.stop();

      expect(snapshot.runtimeSessionId, 'runtime-byte-view');

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(logs.join('\n'), isNot(contains(privateMarker)));
    },
    timeout: const Timeout(Duration(seconds: 3)),
  );

  group(
    'map-shaped structural violations retire transport and fail every pending RPC safely',
    () {
      const privateMarker = 'PRIVATE_MALFORMED_MAP_MARKER_/srv/session.jsonl';
      for (final mode in const [
        'response',
        'params',
        'seq',
        'type-absent',
        'type-non-string',
        'type-empty',
        'payload-non-map',
        'session-non-string',
        'session-empty',
      ]) {
        test(mode, () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final sockets = <WebSocket>[];
          final resumeFrames = <Map<String, dynamic>>[];
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
            sockets.add(socket);
            await for (final raw in socket) {
              final frame = jsonDecode(raw as String) as Map<String, dynamic>;
              if (frame['method'] == 'gateway.capabilities') {
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': frame['id'],
                    'result': {'per_session_exclusive_submit': true},
                  }),
                );
              } else if (frame['method'] == 'session.resume') {
                resumeFrames.add(frame);
                if (resumeFrames.length == 1) {
                  socket.add(
                    jsonEncode({
                      'jsonrpc': '2.0',
                      'id': frame['id'],
                      'result': {
                        'session_id': 'runtime-anchor-$mode',
                        'stored_session_id': 'stored-anchor-$mode',
                        'created': false,
                      },
                    }),
                  );
                  continue;
                }
                if (resumeFrames.length != 3) continue;
                final malformed = switch (mode) {
                  'response' => {
                    'jsonrpc': '1.0',
                    'id': resumeFrames[1]['id'],
                    'result': {'marker': privateMarker},
                    'error': {'code': -32600, 'message': privateMarker},
                  },
                  'params' => {
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': [privateMarker],
                  },
                  'type-absent' => {
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'session_id': 'runtime-anchor-$mode',
                      'payload': {'marker': privateMarker},
                    },
                  },
                  'type-non-string' => {
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': ['message.complete', privateMarker],
                      'session_id': 'runtime-anchor-$mode',
                      'payload': {'marker': privateMarker},
                    },
                  },
                  'type-empty' => {
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': '   ',
                      'session_id': 'runtime-anchor-$mode',
                      'payload': {'marker': privateMarker},
                    },
                  },
                  'payload-non-map' => {
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': 'message.complete',
                      'session_id': 'runtime-anchor-$mode',
                      'payload': [privateMarker],
                    },
                  },
                  'session-non-string' => {
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': 'message.complete',
                      'session_id': 7,
                      'payload': {'marker': privateMarker},
                    },
                  },
                  'session-empty' => {
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': 'message.complete',
                      'session_id': '   ',
                      'payload': {'marker': privateMarker},
                    },
                  },
                  _ => {
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': 'future.valid.event',
                      'session_id': 'runtime-private',
                      'seq': 0,
                      'payload': {'marker': privateMarker},
                    },
                  },
                };
                socket.add(jsonEncode(malformed));
                await Future<void>.delayed(const Duration(milliseconds: 20));
                for (final pending in resumeFrames.skip(1)) {
                  socket.add(
                    jsonEncode({
                      'jsonrpc': '2.0',
                      'id': pending['id'],
                      'result': {
                        'session_id': 'runtime-late-$mode',
                        'stored_session_id':
                            (pending['params'] as Map)['session_id'],
                        'created': false,
                      },
                    }),
                  );
                }
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': 'future.valid.event',
                      'session_id': 'runtime-late-$mode',
                      'seq': 1,
                      'payload': {'trusted': false},
                    },
                  }),
                );
              }
            }
          });
          final client = TuiGatewayClient(
            SavedConnection(
              id: 'malformed-map-$mode',
              label: 'Malformed map $mode',
              host: '127.0.0.1',
              port: 8642,
              apiKey: String.fromCharCodes(const [113, 97]),
              dashboardUrl: 'http://127.0.0.1:${server.port}',
            ),
            dashboard: _TicketDashboardClient(),
          );
          final streamErrors = <Object>[];
          final events = <TuiGatewayEvent>[];
          final subscription = client.events.listen(
            events.add,
            onError: (Object error, StackTrace _) => streamErrors.add(error),
          );
          final logs = <String>[];
          final previousDebugPrint = debugPrint;
          debugPrint = (message, {wrapWidth}) {
            if (message != null) logs.add(message);
          };

          Future<Object> capture(Future<Object> operation) async {
            try {
              return await operation;
            } catch (error) {
              return error;
            }
          }

          final anchor = await client.resumeExisting('stored-anchor-$mode');
          expect(anchor.runtimeSessionId, 'runtime-anchor-$mode', reason: mode);
          final first = capture(client.resumeExisting('stored-first-$mode'));
          final second = capture(client.resumeExisting('stored-second-$mode'));
          final outcomes = await Future.wait([first, second]);
          await Future<void>.delayed(const Duration(milliseconds: 60));

          expect(client.isConnected, isFalse, reason: mode);
          expect(streamErrors, hasLength(1), reason: mode);
          expect(events, isEmpty, reason: mode);
          for (final outcome in [...outcomes, ...streamErrors]) {
            expect(outcome, isA<TuiGatewayRpcError>(), reason: mode);
            final error = outcome as TuiGatewayRpcError;
            expect(
              error.origin,
              CompressionFailureOrigin.malformed,
              reason: mode,
            );
            expect(error.message, 'Invalid JSON-RPC frame', reason: mode);
            expect(error.code, isNull, reason: mode);
            expect(error.data, isEmpty, reason: mode);
            expect(
              error.toString(),
              isNot(contains(privateMarker)),
              reason: mode,
            );
          }
          expect(logs.join('\n'), isNot(contains(privateMarker)), reason: mode);

          debugPrint = previousDebugPrint;
          await subscription.cancel();
          await client.close();
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
        }, timeout: const Timeout(Duration(seconds: 10)));
      }
    },
  );

  test(
    'valid unknown response id and valid unknown event preserve the transport',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 9007199254740991,
              'result': {'ignored': true},
            }),
          );
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'future.valid.event',
                'session_id': 'runtime-positive',
                'seq': 1,
                'payload': {'trusted': true},
              },
            }),
          );
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': frame['method'] == 'gateway.capabilities'
                  ? {'per_session_exclusive_submit': true}
                  : {
                      'session_id': 'runtime-positive',
                      'stored_session_id': 'stored-positive',
                      'created': false,
                    },
            }),
          );
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'valid-unknown-json-rpc',
          label: 'Valid unknown JSON-RPC',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final events = <TuiGatewayEvent>[];
      final errors = <Object>[];
      final subscription = client.events.listen(
        events.add,
        onError: (Object error, StackTrace _) => errors.add(error),
      );
      addTearDown(subscription.cancel);

      final binding = await client.resumeExisting('stored-positive');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(binding.runtimeSessionId, 'runtime-positive');
      expect(client.isConnected, isTrue);
      expect(errors, isEmpty);
      expect(
        events.where((event) => event.type == 'future.valid.event'),
        isNotEmpty,
      );
    },
  );

  group('disjoint JSON-RPC envelope grammar', () {
    for (final mode in <String>[
      'unknown-id-invalid-envelope',
      'known-response-event-conflict',
      'event-with-id',
    ]) {
      test(
        '$mode retires transport and fails every pending RPC safely',
        () async {
          const privateMarker = 'PRIVATE_DISJOINT_ENVELOPE_MARKER';
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final sockets = <WebSocket>[];
          addTearDown(() async {
            for (final socket in sockets) {
              await socket.close();
            }
          });
          final resumeFrames = <Map<String, dynamic>>[];
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
            sockets.add(socket);
            await for (final raw in socket) {
              final frame = jsonDecode(raw as String) as Map<String, dynamic>;
              if (frame['method'] == 'gateway.capabilities') {
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': frame['id'],
                    'result': {'per_session_exclusive_submit': true},
                  }),
                );
                continue;
              }
              if (frame['method'] != 'session.resume') continue;
              resumeFrames.add(frame);
              if (resumeFrames.length == 1) {
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': frame['id'],
                    'result': {
                      'session_id': 'runtime-envelope-$mode',
                      'stored_session_id': 'stored-anchor-$mode',
                      'created': false,
                    },
                  }),
                );
                continue;
              }
              if (resumeFrames.length != 3) continue;
              final malformed = switch (mode) {
                'unknown-id-invalid-envelope' => {
                  'jsonrpc': '1.0',
                  'id': 9007199254740991,
                  'result': {'marker': privateMarker},
                  'error': {'code': -32600, 'message': privateMarker},
                },
                'known-response-event-conflict' => {
                  'jsonrpc': '2.0',
                  'id': resumeFrames[1]['id'],
                  'method': 'event',
                  'params': {
                    'type': 'message.complete',
                    'session_id': 'runtime-envelope-$mode',
                    'payload': {'marker': privateMarker},
                  },
                  'result': {'marker': privateMarker},
                },
                _ => {
                  'jsonrpc': '2.0',
                  'id': privateMarker,
                  'method': 'event',
                  'params': {
                    'type': 'message.complete',
                    'session_id': 'runtime-envelope-$mode',
                    'payload': {'marker': privateMarker},
                  },
                },
              };
              socket.add(jsonEncode(malformed));
              await Future<void>.delayed(const Duration(milliseconds: 20));
              for (final pending in resumeFrames.skip(1)) {
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': pending['id'],
                    'result': {
                      'session_id': 'runtime-late-$mode',
                      'stored_session_id':
                          (pending['params'] as Map)['session_id'],
                      'created': false,
                    },
                  }),
                );
              }
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'method': 'event',
                  'params': {
                    'type': 'future.valid.event',
                    'session_id': 'runtime-late-$mode',
                    'seq': 1,
                    'payload': {'trusted': false},
                  },
                }),
              );
            }
          });

          final client = TuiGatewayClient(
            SavedConnection(
              id: 'disjoint-envelope-$mode',
              label: 'Disjoint envelope $mode',
              host: '127.0.0.1',
              port: 8642,
              apiKey: String.fromCharCodes(const [113, 97]),
              dashboardUrl: 'http://127.0.0.1:${server.port}',
            ),
            dashboard: _TicketDashboardClient(),
          );
          addTearDown(client.close);
          final streamErrors = <Object>[];
          final events = <TuiGatewayEvent>[];
          final subscription = client.events.listen(
            events.add,
            onError: (Object error, StackTrace _) => streamErrors.add(error),
          );
          addTearDown(subscription.cancel);
          final logs = <String>[];
          final previousDebugPrint = debugPrint;
          debugPrint = (message, {wrapWidth}) {
            if (message != null) logs.add(message);
          };
          addTearDown(() => debugPrint = previousDebugPrint);

          Future<Object> capture(Future<Object> operation) async {
            try {
              return await operation;
            } catch (error) {
              return error;
            }
          }

          final anchor = await client.resumeExisting('stored-anchor-$mode');
          expect(anchor.runtimeSessionId, 'runtime-envelope-$mode');
          final first = capture(client.resumeExisting('stored-first-$mode'));
          final second = capture(client.resumeExisting('stored-second-$mode'));
          final outcomes = await Future.wait([first, second]);
          await Future<void>.delayed(const Duration(milliseconds: 60));

          expect(client.isConnected, isFalse, reason: mode);
          expect(streamErrors, hasLength(1), reason: mode);
          expect(events, isEmpty, reason: mode);
          for (final outcome in [...outcomes, ...streamErrors]) {
            expect(outcome, isA<TuiGatewayRpcError>(), reason: mode);
            final error = outcome as TuiGatewayRpcError;
            expect(
              error.origin,
              CompressionFailureOrigin.malformed,
              reason: mode,
            );
            expect(error.message, 'Invalid JSON-RPC frame', reason: mode);
            expect(error.code, isNull, reason: mode);
            expect(error.data, isEmpty, reason: mode);
            expect(
              error.toString(),
              isNot(contains(privateMarker)),
              reason: mode,
            );
          }
          expect(logs.join('\n'), isNot(contains(privateMarker)), reason: mode);
        },
        timeout: const Timeout(Duration(seconds: 10)),
      );
    }
  });

  test('valid unknown notification preserves the transport', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'future.notification',
            'params': {'extension': true},
          }),
        );
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': frame['method'] == 'gateway.capabilities'
                ? {'per_session_exclusive_submit': true}
                : {
                    'session_id': 'runtime-notification',
                    'stored_session_id': 'stored-notification',
                    'created': false,
                  },
          }),
        );
      }
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'valid-unknown-notification',
        label: 'Valid unknown notification',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    final errors = <Object>[];
    final subscription = client.events.listen(
      (_) {},
      onError: (Object error, StackTrace _) => errors.add(error),
    );
    addTearDown(subscription.cancel);

    final binding = await client.resumeExisting('stored-notification');
    expect(binding.runtimeSessionId, 'runtime-notification');
    expect(client.isConnected, isTrue);
    expect(errors, isEmpty);
  });

  test('recovery resume preserves a capability RPC timeout kind', () async {
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
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        methods.add(frame['method'] as String);
        // Deliberately leave gateway.capabilities unanswered so the real
        // JSON-RPC timer produces the transport classification.
      }
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'recovery-capability-timeout',
        label: 'Recovery capability timeout',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.resumeExistingForRecovery('stored-timeout'),
      throwsA(
        isA<TuiGatewayRpcError>()
            .having(
              (error) => error.failureKind,
              'failureKind',
              TuiGatewayRpcFailureKind.timeout,
            )
            .having(
              (error) => error.origin,
              'origin',
              CompressionFailureOrigin.unknown,
            ),
      ),
    );
    expect(methods, ['gateway.capabilities']);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'recovery resume types a socket drop during capability proof as transport',
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
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
            continue;
          }
          methods.add(frame['method'] as String);
          await socket.close();
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'recovery-capability-drop',
          label: 'Recovery capability drop',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.resumeExistingForRecovery('stored-capability-drop'),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having(
                (error) => error.origin,
                'origin',
                isNot(CompressionFailureOrigin.localPreflight),
              )
              .having((error) => error.code, 'code', isNull)
              .having((error) => error.data, 'data', isEmpty),
        ),
      );
      expect(methods, ['gateway.capabilities']);
    },
  );

  test(
    'recovery resume types a socket drop during session.resume as transport',
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
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'] as String;
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
            continue;
          }
          methods.add(method);
          if (method == 'gateway.capabilities') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {'per_session_exclusive_submit': true},
              }),
            );
          } else {
            await socket.close();
          }
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'recovery-resume-drop',
          label: 'Recovery resume drop',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.resumeExistingForRecovery('stored-resume-drop'),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', 'session.resume')
              .having(
                (error) => error.origin,
                'origin',
                isNot(CompressionFailureOrigin.localPreflight),
              )
              .having((error) => error.code, 'code', isNull)
              .having((error) => error.data, 'data', isEmpty),
        ),
      );
      expect(methods, ['gateway.capabilities', 'session.resume']);
    },
  );

  test(
    'habla el JSON-RPC oficial de Desktop y recibe eventos del mismo sid',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final requests = <Map<String, dynamic>>[];
      var interruptedBusyReplies = 0;
      String? receivedTicket;
      final serverDone = Completer<void>();
      server.listen((request) async {
        receivedTicket = request.uri.queryParameters['ticket'];
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        try {
          await for (final raw in socket) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            if (isClientCapabilitiesFrame(frame)) {
              socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
              continue;
            }
            requests.add(frame);
            final method = frame['method'] as String;
            final params = Map<String, dynamic>.from(frame['params'] as Map);
            if (method == 'prompt.submit' &&
                params['interrupted'] == true &&
                interruptedBusyReplies++ == 0) {
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': frame['id'],
                  'error': {'code': 4009, 'message': 'session busy'},
                }),
              );
              continue;
            }
            final result = switch (method) {
              'session.resume' => {'session_id': 'runtime-qa'},
              'gateway.capabilities' => {'per_session_exclusive_submit': true},
              'session.steer' => {'status': 'queued'},
              'session.redirect' => {
                'status': params['text'] == 'rechaza'
                    ? 'rejected'
                    : 'redirected',
              },
              _ => <String, dynamic>{'status': 'ok'},
            };
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': result,
              }),
            );
            if (method == 'session.steer') {
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'method': 'event',
                  'params': {
                    'type': 'message.delta',
                    'payload': {'text': 'hecho'},
                  },
                }),
              );
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'method': 'event',
                  'params': {
                    'type': 'subagent.progress',
                    'payload': {'text': 'background'},
                  },
                }),
              );
            }
          }
        } finally {
          if (!serverDone.isCompleted) serverDone.complete();
        }
      });

      final connection = SavedConnection(
        id: 'conn-qa',
        label: 'QA',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      );
      final client = TuiGatewayClient(
        connection,
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await client.connect();
      final binding = await client.resumeSession('stored-qa');
      await client.submitPrompt(binding.runtimeSessionId, 'pregunta');
      await client.submitInterruptedPrompt(
        binding.runtimeSessionId,
        'y también las de ayer',
      );
      final eventFuture = client.events.firstWhere(
        (event) => event.type == 'message.delta',
      );
      final subagentFuture = client.events.firstWhere(
        (event) => event.type == 'subagent.progress',
      );
      await client.steer(binding.runtimeSessionId, 'complemento');
      final redirect = await client.redirect(
        binding.runtimeSessionId,
        'corrige el cierre',
      );
      final rejectedRedirect = await client.redirect(
        binding.runtimeSessionId,
        'rechaza',
      );
      final event = await eventFuture.timeout(const Duration(seconds: 2));
      final subagent = await subagentFuture.timeout(const Duration(seconds: 2));

      expect(receivedTicket, 'ticket-qa');
      expect(binding.runtimeSessionId, 'runtime-qa');
      expect(binding.storedSessionId, 'stored-qa');
      expect(binding.created, isFalse);
      expect(redirect, DesktopRedirectDisposition.redirected);
      expect(rejectedRedirect, DesktopRedirectDisposition.rejected);
      expect(requests.map((request) => request['method']), [
        'gateway.capabilities',
        'session.resume',
        'prompt.submit',
        'prompt.submit',
        'prompt.submit',
        'session.steer',
        'session.redirect',
        'session.redirect',
      ]);
      expect(requests[0]['params'], isEmpty);
      expect(requests[1]['params'], {
        'session_id': 'stored-qa',
        'source': 'desktop',
      });
      expect(requests[2]['params'], {
        'session_id': 'runtime-qa',
        'text': 'pregunta',
      });
      expect(requests[3]['params'], {
        'session_id': 'runtime-qa',
        'text': 'y también las de ayer',
        'interrupted': true,
      });
      expect(requests[4]['params'], {
        'session_id': 'runtime-qa',
        'text': 'y también las de ayer',
        'interrupted': true,
      });
      expect(requests[5]['params'], {
        'session_id': 'runtime-qa',
        'text': 'complemento',
      });
      expect(requests[6]['params'], {
        'session_id': 'runtime-qa',
        'text': 'corrige el cierre',
      });
      expect(event.sessionId, isEmpty);
      expect(event.payload['text'], 'hecho');
      expect(subagent.sessionId, isEmpty);

      await client.close();
      await serverDone.future.timeout(const Duration(seconds: 2));
    },
  );

  test(
    'idempotencia opcional usa params exactos y valida ACK/status',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
            continue;
          }
          requests.add(frame);
          final method = frame['method'] as String;
          final result = switch (method) {
            'session.resume' => {'session_id': 'runtime-modern'},
            'gateway.capabilities' => {'per_session_exclusive_submit': true},
            'prompt.submit' => {
              'accepted': true,
              'client_turn_id':
                  (frame['params'] as Map<String, dynamic>)['client_turn_id'],
              'server_turn_id': 'server-opaque',
              'state': 'accepted',
              'duplicate': false,
            },
            'turn.status' => {
              'known': true,
              'client_turn_id': 'client-opaque',
              'server_turn_id': 'server-opaque',
              'state': 'running',
            },
            _ => <String, dynamic>{},
          };
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-modern-rpc',
          label: 'Modern RPC',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      final binding = await client.resumeSession('stored-modern');
      final ack = await client.submitPromptIdempotent(
        binding.runtimeSessionId,
        'pregunta moderna',
        'client-opaque',
      );
      final queuedAck = await client.submitQueuedPromptIdempotent(
        binding.runtimeSessionId,
        'seguimiento moderno',
        'client-queued',
      );
      final status = await client.getTurnStatus(
        binding.runtimeSessionId,
        'client-opaque',
      );

      expect(requests.map((request) => request['method']), [
        'gateway.capabilities',
        'session.resume',
        'prompt.submit',
        'prompt.submit',
        'turn.status',
      ]);
      expect(requests[2]['params'], {
        'session_id': 'runtime-modern',
        'text': 'pregunta moderna',
        'client_turn_id': 'client-opaque',
      });
      expect(requests[3]['params'], {
        'session_id': 'runtime-modern',
        'text': 'seguimiento moderno',
        'client_turn_id': 'client-queued',
        'queued': true,
      });
      expect(requests[4]['params'], {
        'session_id': 'runtime-modern',
        'client_turn_id': 'client-opaque',
      });
      expect(ack.serverTurnId, 'server-opaque');
      expect(ack.duplicate, isFalse);
      expect(queuedAck.clientTurnId, 'client-queued');
      expect(status.known, isTrue);
      expect(status.state, DesktopTurnState.running);
    },
  );

  test('conserva el motivo estructurado de un rechazo JSON-RPC', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] == 'gateway.capabilities') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {'per_session_exclusive_submit': true},
            }),
          );
          continue;
        }
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'error': {
              'code': 4090,
              'message': 'private remote ownership detail',
              'data': {'reason': 'SESSION_NOT_OWNED'},
            },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-structured-error',
        label: 'Structured error',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    Object? captured;
    try {
      await client.submitPrompt('runtime-owned', 'continúa');
    } catch (error) {
      captured = error;
    }

    expect(captured, isA<TuiGatewayRpcError>());
    expect((captured as dynamic).reason, 'SESSION_NOT_OWNED');
  });

  test(
    'no ancla eventos legacy tras ligar dos runtimes en el mismo socket',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var resumeCalls = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'] as String;
          final result = switch (method) {
            'gateway.capabilities' => {'per_session_exclusive_submit': true},
            'session.resume' => {'session_id': 'runtime-${++resumeCalls}'},
            _ => <String, dynamic>{'status': 'queued'},
          };
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
          if (method == 'session.steer') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'message.delta',
                  'payload': {'text': 'ambiguo'},
                },
              }),
            );
          }
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-ambiguous-legacy',
          label: 'Ambiguous legacy',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      final first = await client.resumeExisting('stored-1');
      final second = await client.resumeExisting('stored-2');
      final eventFuture = client.events.firstWhere(
        (event) => event.type == 'message.delta',
      );
      await client.steer(second.runtimeSessionId, 'continúa');
      final event = await eventFuture.timeout(const Duration(seconds: 2));

      expect(first.runtimeSessionId, 'runtime-1');
      expect(second.runtimeSessionId, 'runtime-2');
      expect(event.sessionId, isEmpty);
    },
  );

  test(
    'parsea el snapshot completo de session.resume de Hermes 0.19',
    () async {
      // Forma emitida por `_live_session_payload` + `_session_info` en el tag
      // v0.19.0 (commit 3ef6bbd201263d354fd83ec55b3c306ded2eb72a).
      final fixture = Map<String, dynamic>.from(
        jsonDecode(
              File(
                'test/fixtures/hermes_agent_019_session_resume.json',
              ).readAsStringSync(),
            )
            as Map,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
            continue;
          }
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': frame['method'] == 'gateway.capabilities'
                  ? {'per_session_exclusive_submit': true}
                  : fixture,
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-snapshot-019',
          label: 'Snapshot 0.19',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      expect(client, isA<HermesDesktopSessionLifecycleGateway>());
      final snapshot = await client.resumeExisting(
        '20260720_101500_fixture',
        profile: 'default',
        omitMessages: true,
      );
      final recoverySnapshot = await client.resumeExistingForRecovery(
        '20260720_101500_fixture',
        profile: 'default',
      );

      expect(snapshot.runtimeSessionId, 'runtime019');
      expect(recoverySnapshot.runtimeSessionId, 'runtime019');
      expect(snapshot.storedSessionId, '20260720_101500_fixture');
      expect(snapshot.created, isFalse);
      expect(snapshot.messageCount, 3);
      expect(snapshot.messages, hasLength(3));
      expect(snapshot.messagesProvided, isTrue);
      expect(snapshot.messages.first.role, DesktopSessionMessageRole.user);
      expect(snapshot.messages.first.text, 'hola desde el móvil');
      expect(snapshot.messages[1].reasoning, 'resumen del razonamiento');
      expect(snapshot.messages[2].toolName, 'web_search');
      expect(snapshot.messages[2].toolCallId, isNull);
      expect(snapshot.inflight?.assistant, 'respuesta parcial');
      expect(snapshot.inflight?.streaming, isTrue);
      expect(snapshot.queued?.user, 'y añade las fuentes');
      expect(snapshot.running, isTrue);
      expect(snapshot.status, 'working');
      expect(snapshot.startedAt?.millisecondsSinceEpoch, 1784542500250);
      expect(snapshot.info.model, 'gpt-5.5-codex');
      expect(snapshot.info.provider, 'openai-codex');
      expect(snapshot.info.reasoningEffort, 'high');
      expect(snapshot.info.fast, isTrue);
      expect(snapshot.info.desktopContract, 4);
      expect(snapshot.info.approvalMode, 'manual');
      expect(snapshot.info.toolCount, 1);
      expect(snapshot.info.skillCount, 1);
      expect(snapshot.info.mcpServerCount, 0);
      expect(snapshot.info.project?['slug'], 'hermes-mobile');
      expect(snapshot.info.usage?.total, 1500);
      expect(snapshot.info.usage?.contextPercent, 1.25);
      expect(snapshot.info.raw, isNot(contains('system_prompt')));
      expect(snapshot.raw, isNot(contains('messages')));
      expect(snapshot.raw, isNot(contains('info')));
      expect(requests.map((request) => request['method']), [
        'gateway.capabilities',
        'session.resume',
        'session.resume',
      ]);
      expect(requests[1]['params'], {
        'session_id': '20260720_101500_fixture',
        'source': 'desktop',
        'profile': 'default',
        'omit_messages': true,
      });
      // Recovery only needs an authoritative runtime binding and inflight
      // snapshot. On current Gateway a full lineage resume can reject a safely
      // compacted chat with 4130; REST/history remains transcript authority.
      expect(requests[2]['params'], {
        'session_id': '20260720_101500_fixture',
        'source': 'desktop',
        'profile': 'default',
        'omit_messages': true,
      });
    },
  );

  test(
    'resumeExisting nunca crea si el servidor no encuentra la sesión',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
            continue;
          }
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              if (frame['method'] == 'gateway.capabilities')
                'result': {'per_session_exclusive_submit': true}
              else if (frame['method'] == 'session.resume')
                'error': {'code': 4007, 'message': 'session not found'}
              else
                'result': {
                  'session_id': 'must-not-exist',
                  'stored_session_id': 'must-not-exist',
                },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-resume-only',
          label: 'Resume only',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.resumeExisting('missing-session'),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', 'session.resume')
              .having((error) => error.code, 'code', 4007),
        ),
      );

      expect(requests.map((request) => request['method']), [
        'gateway.capabilities',
        'session.resume',
      ]);
    },
  );

  test('resumed booleano nunca se convierte en identidad persistida', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-safe',
        'stored_session_id': 42,
        'session_key': false,
        'resumed': true,
      },
      requestedStoredSessionId: 'stored-safe',
      created: false,
      method: 'session.resume',
    );

    expect(snapshot.runtimeSessionId, 'runtime-safe');
    expect(snapshot.storedSessionId, 'stored-safe');
    expect(snapshot.storedSessionId, isNot('true'));
  });

  test('parser rechaza identidades runtime o stored que no sean strings', () {
    expect(
      () => DesktopSessionSnapshot.fromJson(
        {'session_id': true, 'session_key': 'stored-safe'},
        requestedStoredSessionId: 'stored-safe',
        created: false,
        method: 'session.resume',
      ),
      throwsFormatException,
    );
    expect(
      () => DesktopSessionSnapshot.fromJson(
        {'session_id': 'runtime-safe', 'stored_session_id': 42},
        requestedStoredSessionId: '',
        created: true,
        method: 'session.create',
      ),
      throwsFormatException,
    );
  });

  test('parser de snapshot degrada campos malformados sin inventar estado', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-defensive',
        'session_key': 'stored-defensive',
        'message_count': -3,
        'messages': 'not-a-list',
        'inflight': ['not-a-map'],
        'queued': true,
        'running': 'yes',
        'started_at': 'yesterday',
        'status': 200,
        'info': {
          'fast': 'yes',
          'desktop_contract': -1,
          'tools': ['not-a-map'],
          'usage': {'input': -10, 'total': 'many', 'cost_usd': -2},
        },
      },
      requestedStoredSessionId: 'stored-defensive',
      created: false,
      method: 'session.resume',
    );

    expect(snapshot.messageCount, isNull);
    expect(snapshot.messages, isEmpty);
    expect(snapshot.messagesProvided, isFalse);
    expect(snapshot.inflight, isNull);
    expect(snapshot.queued, isNull);
    expect(snapshot.running, isFalse);
    expect(snapshot.startedAt, isNull);
    expect(snapshot.status, isNull);
    expect(snapshot.info.fast, isNull);
    expect(snapshot.info.desktopContract, isNull);
    expect(snapshot.info.toolCount, isNull);
    expect(snapshot.info.usage?.input, isNull);
    expect(snapshot.info.usage?.total, isNull);
    expect(snapshot.info.usage?.costUsd, isNull);
  });

  test('createForFirstSubmit crea directamente y marca el snapshot', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        requests.add(frame);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': frame['method'] == 'gateway.capabilities'
                ? {'per_session_exclusive_submit': true}
                : {
                    'session_id': 'runtime-created-directly',
                    'stored_session_id': 'stored-created-directly',
                    'message_count': 1,
                    'messages': [
                      {'role': 'user', 'text': 'semilla'},
                    ],
                    'info': {'model': 'provider/model'},
                  },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-create-direct',
        label: 'Create direct',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final snapshot = await client.createForFirstSubmit(
      profile: 'coding',
      model: 'provider/model',
      seedMessages: const [
        {'role': 'user', 'content': 'semilla'},
      ],
    );

    expect(snapshot.created, isTrue);
    expect(snapshot.storedSessionId, 'stored-created-directly');
    expect(requests.map((request) => request['method']), [
      'gateway.capabilities',
      'session.create',
    ]);
    expect(requests[1]['params'], {
      'source': 'desktop',
      'profile': 'coding',
      'model': 'provider/model',
      'messages': const [
        {'role': 'user', 'content': 'semilla'},
      ],
    });
  });

  test('resume existente no crea si falta la sesión durable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        requests.add(frame);
        final method = frame['method'] as String;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            if (method == 'gateway.capabilities')
              'result': {'per_session_exclusive_submit': true}
            else if (method == 'session.resume')
              'error': {'code': 4007, 'message': 'session not found'}
            else
              'result': {
                'session_id': 'runtime-created',
                'stored_session_id': 'stored-created',
              },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-create',
        label: 'Create',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.resumeSession(
        'stored-missing',
        model: 'hermes-agent',
        seedMessages: const [
          {'role': 'user', 'content': 'anterior'},
          {'role': 'assistant', 'content': 'respuesta'},
        ],
      ),
      throwsA(
        isA<TuiGatewayRpcError>()
            .having((error) => error.method, 'method', 'session.resume')
            .having((error) => error.code, 'code', 4007),
      ),
    );

    expect(requests.map((request) => request['method']), [
      'gateway.capabilities',
      'session.resume',
    ]);
  });

  test('notifica inmediatamente si un socket ya conectado se corta', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final serverSocket = Completer<WebSocket>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      if (!serverSocket.isCompleted) serverSocket.complete(socket);
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-drop',
        label: 'Drop',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final transportError = client.events.first;
    await client.connect();
    final socket = await serverSocket.future.timeout(
      const Duration(seconds: 2),
    );
    expect(client.isConnected, isTrue);

    await socket.close();

    await expectLater(transportError, throwsA(isA<StateError>()));
    expect(client.isConnected, isFalse);
  });

  test(
    'heartbeat anunciado invalida un socket abierto pero sin respuestas',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'heartbeat': true},
            },
          }),
        );
        // Consume gateway.ping without contestar: simula una radio en agujero
        // negro que deja el TCP aparentemente abierto.
        await for (final _ in socket) {}
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-heartbeat-blackhole',
          label: 'Heartbeat blackhole',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
        heartbeatInterval: const Duration(milliseconds: 10),
        heartbeatDeadline: const Duration(milliseconds: 35),
      );
      addTearDown(client.close);

      final transportError = client.events.firstWhere(
        (event) => event.type == 'never-emitted-after-heartbeat',
      );
      await client.connect();

      await expectLater(
        transportError,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('heartbeat'),
          ),
        ),
      );
      expect(client.isConnected, isFalse);
    },
  );

  group('probeNow tras cambio de red o resume', () {
    Future<(TuiGatewayClient, List<Map<String, dynamic>>)> connectTo({
      required String id,
      required bool answerPings,
      Duration probeNowRecentInbound = Duration.zero,
      void Function(WebSocket socket)? onSocket,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final received = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        onSocket?.call(socket);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a', 'heartbeat': true},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          received.add(frame);
          if (!answerPings || frame['method'] != 'gateway.ping') continue;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'result': {'ok': true},
              'id': frame['id'],
            }),
          );
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: id,
          label: id,
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
        // Heartbeat real de producción: sin probeNow el socket medio abierto
        // sobreviviría 45 s.
        heartbeatInterval: const Duration(seconds: 15),
        heartbeatDeadline: const Duration(seconds: 45),
        probeNowDeadline: const Duration(milliseconds: 80),
        probeNowRecentInbound: probeNowRecentInbound,
      );
      addTearDown(client.close);
      return (client, received);
    }

    // Hermes (`tui_gateway/ws.py`) lee y despacha en serie: tras un RPC
    // no-long el pong se retrasa, pero los eventos del turno siguen llegando.
    test('pong retrasado con eventos entrantes: el socket sigue vivo y el '
        'RPC en vuelo no falla', () async {
      WebSocket? serverSocket;
      final (client, _) = await connectTo(
        id: 'conn-probe-busy-serial',
        answerPings: false,
        onSocket: (socket) => serverSocket = socket,
      );
      final errors = <Object>[];
      final subscription = client.events.listen(
        (_) {},
        onError: (Object error) => errors.add(error),
      );
      addTearDown(subscription.cancel);
      await client.connect();
      final submitOutcome = Completer<Object?>();
      unawaited(
        client
            .submitPrompt('rt', 'x')
            .then<void>(
              (_) => submitOutcome.complete(null),
              onError: (Object error) {
                if (!submitOutcome.isCompleted) {
                  submitOutcome.complete(error);
                }
              },
            ),
      );
      var seq = 1;
      final ticker = Timer.periodic(const Duration(milliseconds: 15), (_) {
        serverSocket?.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': 'rt',
              'seq': seq++,
              'payload': {'text': '.'},
            },
          }),
        );
      });
      addTearDown(ticker.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await client.probeNow(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ticker.cancel();

      expect(client.isConnected, isTrue);
      expect(errors, isEmpty);
      expect(submitOutcome.isCompleted, isFalse, reason: 'sin _failPending');
    });

    test('tráfico entrante reciente: no se envía sonda', () async {
      final (client, received) = await connectTo(
        id: 'conn-probe-recent-inbound',
        answerPings: false,
        probeNowRecentInbound: const Duration(seconds: 3),
      );
      await client.connect();

      // `gateway.ready` acaba de llegar: el socket está demostrado vivo.
      expect(await client.probeNow(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(client.isConnected, isTrue);
      expect(
        received.where((frame) => frame['method'] == 'gateway.ping'),
        isEmpty,
      );
    });

    test('la sonda coalescida no se comparte con una conexión nueva', () async {
      final (client, received) = await connectTo(
        id: 'conn-probe-generation',
        answerPings: false,
      );
      await client.connect();
      final stale = client.probeNow();
      // Mismo turno síncrono: la conexión ya cambió de generación pero la
      // sonda antigua aún no ha liberado `_probeNowFlight`.
      final disconnected = client.disconnectIdle();
      final reconnected = client.connect();

      final fresh = client.probeNow();

      expect(
        identical(stale, fresh),
        isFalse,
        reason: 'el resultado de la sonda del socket anterior no vale aquí',
      );
      await disconnected;
      await reconnected;
      expect(await stale, isFalse);
      expect(await client.probeNow(), isFalse);
      expect(
        received.where((frame) => frame['method'] == 'gateway.ping'),
        hasLength(2),
        reason: 'la conexión nueva recibe su propia sonda',
      );
    });

    test(
      'socket medio abierto: la sonda lo declara muerto enseguida',
      () async {
        final (client, received) = await connectTo(
          id: 'conn-probe-blackhole',
          answerPings: false,
        );
        final errors = <Object>[];
        final subscription = client.events.listen(
          (_) {},
          onError: (Object error) => errors.add(error),
        );
        addTearDown(subscription.cancel);
        await client.connect();
        expect(client.isConnected, isTrue);

        final first = client.probeNow();
        final second = client.probeNow();
        expect(identical(first, second), isTrue, reason: 'sondas coalescidas');
        expect(await first, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(client.isConnected, isFalse);
        expect(errors, isNotEmpty);
        expect(
          received.where((frame) => frame['method'] == 'gateway.ping'),
          hasLength(1),
        );
      },
    );

    test('socket sano: la sonda responde y la conexión sigue', () async {
      final (client, _) = await connectTo(
        id: 'conn-probe-healthy',
        answerPings: true,
      );
      await client.connect();
      expect(await client.probeNow(), isTrue);
      expect(client.isConnected, isTrue);
    });

    test('sin conexión la sonda es un no-op', () async {
      final (client, received) = await connectTo(
        id: 'conn-probe-disconnected',
        answerPings: true,
      );
      expect(await client.probeNow(), isFalse);
      expect(client.isConnected, isFalse);
      expect(received, isEmpty);
    });
  });

  test(
    'una pausa del scheduler da margen al heartbeat antes de cortar',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var pings = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'heartbeat': true},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] != 'gateway.ping') continue;
          pings++;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'result': {'ok': true},
              'id': frame['id'],
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-heartbeat-scheduler-pause',
          label: 'Heartbeat scheduler pause',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
        heartbeatInterval: const Duration(milliseconds: 10),
        heartbeatDeadline: const Duration(milliseconds: 35),
      );
      addTearDown(client.close);
      final errors = <Object>[];
      final subscription = client.events.listen(
        (_) {},
        onError: (Object error) => errors.add(error),
      );
      addTearDown(subscription.cancel);

      await client.connect();
      for (var attempt = 0; attempt < 100 && pings == 0; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(pings, greaterThan(0));

      sleep(const Duration(milliseconds: 80));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(client.isConnected, isTrue);
      expect(errors, isEmpty);
      expect(pings, greaterThan(1));
    },
  );

  test(
    'un gateway antiguo sin heartbeat anunciado permanece compatible',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final received = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          received.add(jsonDecode(raw as String) as Map<String, dynamic>);
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-no-heartbeat',
          label: 'No heartbeat',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
        heartbeatInterval: const Duration(milliseconds: 10),
        heartbeatDeadline: const Duration(milliseconds: 35),
      );
      addTearDown(client.close);

      await client.connect();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(client.isConnected, isTrue);
      expect(framesWithoutClientCapabilities(received), isEmpty);
    },
  );

  test(
    'reintentos de loginRequired conservan el error sin reparación',
    () async {
      final gatewaySource = File(
        'lib/core/services/tui_gateway_client.dart',
      ).readAsStringSync();
      expect(gatewaySource, isNot(contains('.setDashboardCredentials(')));

      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: 1,
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response('<form id="provider-form"></form>', 200);
          }
          return http.Response('not found', 404);
        }),
      );
      addTearDown(dashboard.close);
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-no-repair',
          label: 'No repair',
          host: '127.0.0.1',
          port: 8642,
          apiKey: '',
          dashboardUrl: 'http://127.0.0.1:1',
        ),
        dashboard: dashboard,
      );
      addTearDown(client.close);

      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          client.connect(),
          throwsA(
            isA<DashboardAuthException>().having(
              (error) => error.code,
              'code',
              DashboardAuthFailureCode.loginRequired,
            ),
          ),
        );
      }
    },
  );

  test('envía rewind y adjuntos por los RPC nativos de Desktop', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (isClientCapabilitiesFrame(frame)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          continue;
        }
        requests.add(frame);
        final method = frame['method'] as String;
        final result = switch (method) {
          'session.resume' => {'session_id': 'runtime-native'},
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'image.attach_bytes' => {
            'attached': true,
            'path': '/hermes/images/test.png',
          },
          'file.attach' => {
            'attached': true,
            'path': '/workspace/.hermes/test.txt',
            'ref_text': '@file:.hermes/test.txt',
          },
          'prompt.submit' => {
            'status': 'ok',
            'survivor_user_row_ids': [11, null, 'malformed'],
          },
          _ => <String, dynamic>{'status': 'ok'},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-native',
        label: 'Native',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final binding = await client.resumeSession('stored-native');
    final image = await client.attachImageBytes(
      binding.runtimeSessionId,
      filename: 'test.png',
      contentBase64: 'aW1hZ2U=',
    );
    final file = await client.attachFileBytes(
      binding.runtimeSessionId,
      filename: 'test.txt',
      mimeType: 'text/plain',
      contentBase64: 'aG9sYQ==',
    );
    await client.detachImage(binding.runtimeSessionId, image.path!);
    final rewind = await client.submitDurableRewindPrompt(
      binding.runtimeSessionId,
      'corregido',
      2,
      truncateBeforeRowId: 73,
      rebindSurvivorRowIds: const [11, 22],
    );
    await client.submitRewindPrompt(
      binding.runtimeSessionId,
      'primer turno',
      0,
    );
    await client.submitQueuedPrompt(
      binding.runtimeSessionId,
      'seguimiento en cola',
    );

    expect(requests.map((request) => request['method']), [
      'gateway.capabilities',
      'session.resume',
      'image.attach_bytes',
      'file.attach',
      'image.detach',
      'prompt.submit',
      'prompt.submit',
      'prompt.submit',
    ]);
    expect(requests[2]['params'], {
      'session_id': 'runtime-native',
      'filename': 'test.png',
      'content_base64': 'aW1hZ2U=',
    });
    expect(
      requests[3]['params']['data_url'],
      'data:text/plain;base64,aG9sYQ==',
    );
    expect(file.refText, '@file:.hermes/test.txt');
    expect(rewind.survivorUserRowIds, [11, null, null]);
    expect(requests[5]['params'], {
      'session_id': 'runtime-native',
      'text': 'corregido',
      'truncate_before_row_id': 73,
      'confirm_truncate': true,
      'confirm_empty_truncate': true,
      'rebind_survivor_row_ids': [11, 22],
    });
    expect(requests[6]['params'], {
      'session_id': 'runtime-native',
      'text': 'primer turno',
      'truncate_before_user_ordinal': 0,
      'confirm_truncate': true,
      'confirm_empty_truncate': true,
    });
    expect(requests[7]['params'], {
      'session_id': 'runtime-native',
      'text': 'seguimiento en cola',
      'queued': true,
    });
  });

  test(
    'durable row resolver matches content across shifted ordinals and rejects ambiguity',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
            continue;
          }
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'count': 8,
                'messages': [
                  {'role': 'user', 'row_id': 0, 'text': 'cero'},
                  {
                    'role': 'user',
                    'row_id': 72,
                    'text': 'duplicada',
                    'display_kind': 'notice',
                  },
                  {'role': 'user', 'row_id': 73, 'text': 'duplicada'},
                  {'role': 'assistant', 'row_id': 74, 'text': 'respuesta'},
                  {'role': 'user', 'row_id': 75, 'text': 'duplicada'},
                  {'role': 'user', 'text': 'optimista sin id'},
                  {'role': 'user', 'row_id': 76, 'text': 'última'},
                  {'role': 'assistant', 'row_id': 77, 'text': 'respuesta'},
                ],
              },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-history-row-id',
          label: 'History row id',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      await client.connect();

      expect(
        await client.resolveDurableUserRowId(
          'runtime-history',
          sourceText: 'última',
          expectedOrdinal: 0,
        ),
        76,
      );
      expect(
        await client.resolveDurableUserRowId(
          'runtime-history',
          sourceText: 'duplicada',
          expectedOrdinal: 1,
        ),
        isNull,
      );
      expect(requests.map((request) => request['method']), [
        'session.history',
        'session.history',
      ]);
    },
  );

  test(
    'session.compress envía el JSON-RPC exacto y parsea el resultado',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
            continue;
          }
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': frame['method'] == 'gateway.capabilities'
                  ? {'per_session_exclusive_submit': true}
                  : {
                      'status': 'compressed',
                      'removed': 2,
                      'before_messages': 4,
                      'after_messages': 2,
                      'before_tokens': 179492,
                      'after_tokens': 4100,
                      'summary': {'noop': false},
                      'usage': {'context_used': 4100, 'context_max': 200000},
                      'info': {'stored_session_id': 'stored-compressed'},
                      'messages': [
                        {'role': 'user', 'content': 'Resumen'},
                        {'role': 'assistant', 'content': 'Continuación'},
                      ],
                    },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-compress-rpc',
          label: 'Compress RPC',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      final focused = await client.compressSession(
        'runtime-compress',
        focusTopic: '  decisiones de release  ',
      );
      await client.compressSession('runtime-compress', focusTopic: '   ');

      expect(requests.map((request) => request['method']), [
        'gateway.capabilities',
        'session.compress',
        'session.compress',
      ]);
      expect(requests[1]['params'], {
        'session_id': 'runtime-compress',
        'focus_topic': 'decisiones de release',
      });
      expect(requests[2]['params'], {'session_id': 'runtime-compress'});
      expect(focused.afterMessages, 2);
      expect(focused.info?.storedSessionId, 'stored-compressed');
      expect(focused.messages?.last.text, 'Continuación');
    },
  );

  test(
    'REGRESSION_COMP_UNCERTAIN malformed server ACK remains unclassified post-dispatch',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var compressCalls = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'];
          if (method == 'session.compress') compressCalls++;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': method == 'gateway.capabilities'
                  ? {'per_session_exclusive_submit': true}
                  : {'status': 'compressed', 'removed': 'not-an-int'},
            }),
          );
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-malformed-compress',
          label: 'Malformed compress',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'unused',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.compressSession('runtime-malformed'),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', 'session.compress')
              .having(
                (error) => error.origin,
                'origin',
                CompressionFailureOrigin.malformed,
              )
              .having((error) => error.code, 'code', isNull),
        ),
      );
      expect(compressCalls, 1);
    },
  );

  test(
    'COMP_CONVERGENCE real RPC projected reply survives 42 seconds',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final methods = <String>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'] as String;
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
            continue;
          }
          methods.add(method);
          void reply() => socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': method == 'gateway.capabilities'
                  ? {'per_session_exclusive_submit': true}
                  : projectedCompressionReply(),
            }),
          );
          if (method == 'session.compress') {
            // Keep reading frames so the real socket can answer control pings.
            unawaited(Future<void>.delayed(const Duration(seconds: 42), reply));
          } else {
            reply();
          }
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'compression-delayed-rpc',
          label: 'Delayed RPC',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'fixture',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
        heartbeatInterval: const Duration(minutes: 2),
        heartbeatDeadline: const Duration(minutes: 3),
      );
      addTearDown(client.close);
      final reply = await client.compressSession('runtime-compression');
      expect(reply.isTerminal, isTrue);
      expect(reply.afterMessages, 4);
      expect(reply.messages, hasLength(2));
      expect(methods, ['gateway.capabilities', 'session.compress']);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('session.compress conserva el margen sobre el máximo de Hermes', () {
    expect(
      TuiGatewayClient.sessionCompressRpcTimeout,
      const Duration(seconds: 690),
    );
  });

  test(
    'session.compress no normaliza una identidad runtime con espacios',
    () async {
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-compress-identity',
          label: 'Compress identity',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.compressSession(' runtime-compress '),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.method,
            'method',
            'session.compress',
          ),
        ),
      );
    },
  );

  test(
    'replays multiple runtime watermarks with bounded concurrency',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      const runtimeIds = <String>[
        'runtime-1',
        'runtime-2',
        'runtime-3',
        'runtime-4',
        'runtime-5',
        'runtime-6',
      ];
      var connections = 0;
      var initialEventsReceived = 0;
      var activeReplayRequests = 0;
      var maxActiveReplayRequests = 0;
      final initialReceived = Completer<void>();
      final replayedSessions = <String>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        connections++;
        if (connections == 1) {
          for (final runtimeId in runtimeIds) {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'message.delta',
                  'session_id': runtimeId,
                  'seq': 1,
                  'payload': {'replay_epoch': 'epoch-multi'},
                },
              }),
            );
          }
          await initialReceived.future.timeout(const Duration(seconds: 2));
          await socket.close();
          return;
        }
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] != 'session.events.since') continue;
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          final runtimeId = params['session_id'] as String;
          activeReplayRequests++;
          if (activeReplayRequests > maxActiveReplayRequests) {
            maxActiveReplayRequests = activeReplayRequests;
          }
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 150), () {
              replayedSessions.add(runtimeId);
              activeReplayRequests--;
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': frame['id'],
                  'result': {
                    'epoch': 'epoch-multi',
                    'truncated': false,
                    'events': const [],
                  },
                }),
              );
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-multi-replay',
          label: 'Multi replay',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final disconnected = Completer<void>();
      final subscription = client.events.listen(
        (event) {
          if (runtimeIds.contains(event.sessionId) &&
              ++initialEventsReceived == runtimeIds.length &&
              !initialReceived.isCompleted) {
            initialReceived.complete();
          }
        },
        onError: (Object _, StackTrace _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      addTearDown(subscription.cancel);

      await client.connect();
      await disconnected.future.timeout(const Duration(seconds: 2));
      final stopwatch = Stopwatch()..start();
      await client.connect();
      stopwatch.stop();

      expect(replayedSessions.toSet(), runtimeIds.toSet());
      expect(maxActiveReplayRequests, greaterThan(1));
      expect(maxActiveReplayRequests, lessThanOrEqualTo(4));
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 650)));
    },
  );

  test('holds live events for runtimes queued behind replay workers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    const runtimeIds = <String>[
      'runtime-1',
      'runtime-2',
      'runtime-3',
      'runtime-4',
      'runtime-queued',
    ];
    var connections = 0;
    var initialEventsReceived = 0;
    final initialReceived = Completer<void>();
    final disconnected = Completer<void>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      connections++;
      if (connections == 1) {
        for (final runtimeId in runtimeIds) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': runtimeId,
                'seq': 1,
                'payload': {'replay_epoch': 'epoch-queued'},
              },
            }),
          );
        }
        await initialReceived.future.timeout(const Duration(seconds: 2));
        await socket.close();
        return;
      }

      final activeRequests = <Map<String, dynamic>>[];
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] != 'session.events.since') continue;
        final params = Map<String, dynamic>.from(frame['params'] as Map);
        final runtimeId = params['session_id'] as String;
        if (runtimeId == 'runtime-queued') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'epoch': 'epoch-queued',
                'truncated': false,
                'events': [
                  {
                    'type': 'message.delta',
                    'session_id': runtimeId,
                    'seq': 2,
                    'payload': {'text': 'replayed-queued'},
                  },
                ],
              },
            }),
          );
          continue;
        }

        activeRequests.add(frame);
        if (activeRequests.length != 4) continue;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': 'runtime-queued',
              'seq': 3,
              'payload': {'text': 'live-queued'},
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        for (final pending in activeRequests) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': pending['id'],
              'result': {
                'epoch': 'epoch-queued',
                'truncated': false,
                'events': const [],
              },
            }),
          );
        }
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-queued-replay',
        label: 'Queued replay',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    final texts = <String>[];
    final subscription = client.events.listen(
      (event) {
        if (runtimeIds.contains(event.sessionId) &&
            event.sequence == 1 &&
            ++initialEventsReceived == runtimeIds.length &&
            !initialReceived.isCompleted) {
          initialReceived.complete();
        }
        if (event.payload['text'] case final String text) texts.add(text);
      },
      onError: (Object _, StackTrace _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    addTearDown(subscription.cancel);

    await client.connect();
    await disconnected.future.timeout(const Duration(seconds: 2));
    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(texts, isEmpty);
  });

  test(
    'a failed replay quarantines only that runtime and continues others',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var connections = 0;
      var initialEventsReceived = 0;
      final initialReceived = Completer<void>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        connections++;
        if (connections == 1) {
          for (final runtimeId in const ['runtime-failed', 'runtime-good']) {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'message.delta',
                  'session_id': runtimeId,
                  'seq': 1,
                  'payload': {'replay_epoch': 'epoch-isolated'},
                },
              }),
            );
          }
          await initialReceived.future.timeout(const Duration(seconds: 2));
          await socket.close();
          return;
        }
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] != 'session.events.since') continue;
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          final runtimeId = params['session_id'] as String;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': runtimeId,
                'seq': 3,
                'payload': {'text': 'held-$runtimeId'},
              },
            }),
          );
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              if (runtimeId == 'runtime-failed')
                'error': {'code': 5000, 'message': 'replay unavailable'}
              else
                'result': {
                  'epoch': 'epoch-isolated',
                  'truncated': false,
                  'events': [
                    {
                      'type': 'message.delta',
                      'session_id': runtimeId,
                      'seq': 2,
                      'payload': {'text': 'replayed-$runtimeId'},
                    },
                  ],
                },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-isolated-replay',
          label: 'Isolated replay',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final texts = <String>[];
      final disconnected = Completer<void>();
      final subscription = client.events.listen(
        (event) {
          if (event.payload['replay_epoch'] == 'epoch-isolated' &&
              ++initialEventsReceived == 2 &&
              !initialReceived.isCompleted) {
            initialReceived.complete();
          }
          if (event.payload['text'] case final String text) texts.add(text);
        },
        onError: (Object _, StackTrace _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      addTearDown(subscription.cancel);

      await client.connect();
      await disconnected.future.timeout(const Duration(seconds: 2));
      await client.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(texts, isEmpty);
    },
  );

  test('malformed replay success stays quarantined until recovery', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    const badRuntimeIds = <String>[
      'runtime-bad-events',
      'runtime-invalid-row',
      'runtime-invalid-identity',
      'runtime-bad-epoch',
      'runtime-bad-truncated',
      'runtime-truncated',
    ];
    const allRuntimeIds = <String>[...badRuntimeIds, 'runtime-valid'];
    var connections = 0;
    var initialEventsReceived = 0;
    final initialReceived = Completer<void>();
    WebSocket? replaySocket;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      connections++;
      if (connections == 1) {
        for (final runtimeId in allRuntimeIds) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': runtimeId,
                'seq': 1,
                'payload': {'replay_epoch': 'epoch-validation'},
              },
            }),
          );
        }
        await initialReceived.future.timeout(const Duration(seconds: 2));
        await socket.close();
        return;
      }
      replaySocket = socket;
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] != 'session.events.since') continue;
        final params = Map<String, dynamic>.from(frame['params'] as Map);
        final runtimeId = params['session_id'] as String;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': runtimeId,
              'seq': 3,
              'payload': {'text': 'held-$runtimeId'},
            },
          }),
        );
        final result = switch (runtimeId) {
          'runtime-bad-events' => <String, dynamic>{
            'epoch': 'epoch-validation',
            'truncated': false,
            'events': {'not': 'a list'},
          },
          'runtime-invalid-row' => <String, dynamic>{
            'epoch': 'epoch-validation',
            'truncated': false,
            'events': const ['invalid-row'],
          },
          'runtime-invalid-identity' => <String, dynamic>{
            'epoch': 'epoch-validation',
            'truncated': false,
            'events': const [
              {
                'type': 'message.delta',
                'session_id': 7,
                'seq': 2,
                'payload': {'text': 'invalid-explicit-runtime'},
              },
            ],
          },
          'runtime-bad-epoch' => <String, dynamic>{
            'epoch': '   ',
            'truncated': false,
            'events': const [],
          },
          'runtime-bad-truncated' => <String, dynamic>{
            'epoch': 'epoch-validation',
            'truncated': 'false',
            'events': const [],
          },
          'runtime-truncated' => <String, dynamic>{
            'epoch': 'epoch-validation',
            'truncated': true,
            'events': const [],
          },
          _ => <String, dynamic>{
            'epoch': 'epoch-validation',
            'truncated': false,
            'events': [
              {
                'type': 'message.delta',
                'session_id': runtimeId,
                'seq': 2,
                'payload': {'text': 'replayed-$runtimeId'},
              },
            ],
          },
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-validated-replay',
        label: 'Validated replay',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    final texts = <String>[];
    final disconnected = Completer<void>();
    final subscription = client.events.listen(
      (event) {
        if (event.payload['replay_epoch'] == 'epoch-validation' &&
            ++initialEventsReceived == allRuntimeIds.length &&
            !initialReceived.isCompleted) {
          initialReceived.complete();
        }
        if (event.payload['text'] case final String text) texts.add(text);
      },
      onError: (Object _, StackTrace _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    addTearDown(subscription.cancel);

    await client.connect();
    await disconnected.future.timeout(const Duration(seconds: 2));
    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(texts, isEmpty);

    for (final runtimeId in badRuntimeIds) {
      replaySocket!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'message.delta',
            'session_id': runtimeId,
            'seq': 4,
            'payload': {'text': 'before-recovery-$runtimeId'},
          },
        }),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(texts, isEmpty);

    for (final runtimeId in badRuntimeIds) {
      client.commitRecoveryRuntime(runtimeId);
      replaySocket!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'message.delta',
            'session_id': runtimeId,
            'seq': 5,
            'payload': {'text': 'after-recovery-$runtimeId'},
          },
        }),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(texts, isEmpty);
  });

  test(
    'mismatched replay runtime is atomic and cannot advance another runtime',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var connections = 0;
      final initialReceived = Completer<void>();
      final disconnected = Completer<void>();
      WebSocket? replaySocket;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        connections++;
        if (connections == 1) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'runtime-requested',
                'seq': 1,
                'payload': {'replay_epoch': 'epoch-atomic'},
              },
            }),
          );
          await initialReceived.future.timeout(const Duration(seconds: 2));
          await socket.close();
          return;
        }
        replaySocket = socket;
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] != 'session.events.since') continue;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'epoch': 'epoch-atomic',
                'truncated': false,
                'events': [
                  {
                    'type': 'message.delta',
                    'session_id': 'runtime-requested',
                    'seq': 2,
                    'payload': {'text': 'must-not-dispatch'},
                  },
                  {
                    'type': 'message.delta',
                    'session_id': 'runtime-other',
                    'seq': 50,
                    'payload': {'text': 'must-not-cross-runtime'},
                  },
                ],
              },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-atomic-replay',
          label: 'Atomic replay',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final texts = <String>[];
      final subscription = client.events.listen(
        (event) {
          if (event.payload['replay_epoch'] == 'epoch-atomic' &&
              !initialReceived.isCompleted) {
            initialReceived.complete();
          }
          if (event.payload['text'] case final String text) texts.add(text);
        },
        onError: (Object _, StackTrace _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      addTearDown(subscription.cancel);

      await client.connect();
      await disconnected.future.timeout(const Duration(seconds: 2));
      await client.connect();
      replaySocket!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'message.delta',
            'session_id': 'runtime-other',
            'seq': 1,
            'payload': {'text': 'other-live-event'},
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(texts, ['other-live-event']);
    },
  );

  test('connect fails when its transport disconnects during replay', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var connections = 0;
    final initialReceived = Completer<void>();
    final disconnected = Completer<void>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      connections++;
      if (connections == 1) {
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': 'runtime-disconnect-replay',
              'seq': 1,
              'payload': {'replay_epoch': 'epoch-disconnect-replay'},
            },
          }),
        );
        await initialReceived.future.timeout(const Duration(seconds: 2));
        await socket.close();
        return;
      }
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] == 'session.events.since') {
          await socket.close();
          return;
        }
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-disconnect-replay',
        label: 'Disconnect replay',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    final subscription = client.events.listen(
      (event) {
        if (event.payload['replay_epoch'] == 'epoch-disconnect-replay' &&
            !initialReceived.isCompleted) {
          initialReceived.complete();
        }
      },
      onError: (Object _, StackTrace _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    addTearDown(subscription.cancel);

    await client.connect();
    await disconnected.future.timeout(const Duration(seconds: 2));
    await expectLater(client.connect(), throwsA(isA<StateError>()));
    expect(client.isConnected, isFalse);
  });

  test('reconnect resource overflow fails closed without replay', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final runtimeIds = List<String>.generate(40, (index) => 'runtime-$index');
    var connections = 0;
    var initialEventsReceived = 0;
    final initialReceived = Completer<void>();
    final disconnected = Completer<void>();
    final replayed = <String>[];
    WebSocket? replaySocket;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      connections++;
      if (connections == 1) {
        for (final runtimeId in runtimeIds) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': runtimeId,
                'seq': 1,
                'payload': {'replay_epoch': 'epoch-bounded'},
              },
            }),
          );
        }
        await initialReceived.future.timeout(const Duration(seconds: 2));
        await socket.close();
        return;
      }
      replaySocket = socket;
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] != 'session.events.since') continue;
        final params = Map<String, dynamic>.from(frame['params'] as Map);
        replayed.add(params['session_id'] as String);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'epoch': 'epoch-bounded',
              'truncated': false,
              'events': const [],
            },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-bounded-replay',
        label: 'Bounded replay',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    final unsafeTexts = <String>[];
    final subscription = client.events.listen(
      (event) {
        if (runtimeIds.contains(event.sessionId)) {
          initialEventsReceived++;
          if (event.sessionId ==
                  'runtime-${ReplayCoordinator.maxTrackedRuntimes - 1}' &&
              !initialReceived.isCompleted) {
            initialReceived.complete();
          }
        }
        if (event.payload['text'] case final String text) {
          unsafeTexts.add(text);
        }
      },
      onError: (Object _, StackTrace _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    addTearDown(subscription.cancel);

    await client.connect();
    await disconnected.future.timeout(const Duration(seconds: 2));
    await client.connect();
    for (final runtimeId in const ['runtime-0']) {
      replaySocket!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'message.delta',
            'session_id': runtimeId,
            'seq': 2,
            'payload': {'text': 'unsafe-$runtimeId'},
          },
        }),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(initialEventsReceived, ReplayCoordinator.maxTrackedRuntimes);
    expect(replayed, isEmpty);
    expect(unsafeTexts, isEmpty);
  });

  test('held live replay overflow quarantines instead of releasing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var connections = 0;
    final initialReceived = Completer<void>();
    final disconnected = Completer<void>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      connections++;
      if (connections == 1) {
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': 'runtime-held-overflow',
              'seq': 1,
              'payload': {'replay_epoch': 'epoch-held-overflow'},
            },
          }),
        );
        await initialReceived.future.timeout(const Duration(seconds: 2));
        await socket.close();
        return;
      }
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] != 'session.events.since') continue;
        for (var sequence = 2; sequence <= 66; sequence++) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'runtime-held-overflow',
                'seq': sequence,
                'payload': {'text': 'held-$sequence'},
              },
            }),
          );
        }
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'epoch': 'epoch-held-overflow',
              'truncated': false,
              'events': const [],
            },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-held-overflow',
        label: 'Held overflow',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    final texts = <String>[];
    final subscription = client.events.listen(
      (event) {
        if (event.payload['replay_epoch'] == 'epoch-held-overflow' &&
            !initialReceived.isCompleted) {
          initialReceived.complete();
        }
        if (event.payload['text'] case final String text) texts.add(text);
      },
      onError: (Object _, StackTrace _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    addTearDown(subscription.cancel);

    await client.connect();
    await disconnected.future.timeout(const Duration(seconds: 2));
    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(texts, isEmpty);
  });

  test(
    'resource overflow remains fail-closed after legacy recovery hint',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var connections = 0;
      final retainedBoundaryReceived = Completer<void>();
      final disconnected = Completer<void>();
      WebSocket? recoverySocket;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        connections++;
        if (connections == 1) {
          for (var index = 0; index < 100; index++) {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'message.delta',
                  'session_id': 'runtime-quarantine-$index',
                  'seq': 1,
                  'payload': {'replay_epoch': 'epoch-quarantine-bound'},
                },
              }),
            );
          }
          await retainedBoundaryReceived.future.timeout(
            const Duration(seconds: 2),
          );
          await socket.close();
          return;
        }
        recoverySocket = socket;
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] == 'session.events.since') {
            fail('fail-closed quarantine must not replay uncertain runtimes');
          }
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-quarantine-bound',
          label: 'Quarantine bound',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final initialRuntimeIds = <String>[];
      final texts = <String>[];
      final subscription = client.events.listen(
        (event) {
          if (event.payload['replay_epoch'] == 'epoch-quarantine-bound') {
            initialRuntimeIds.add(event.sessionId);
            if (event.sessionId ==
                    'runtime-quarantine-${ReplayCoordinator.maxTrackedRuntimes - 1}' &&
                !retainedBoundaryReceived.isCompleted) {
              retainedBoundaryReceived.complete();
            }
          }
          if (event.payload['text'] case final String text) texts.add(text);
        },
        onError: (Object _, StackTrace _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      addTearDown(subscription.cancel);

      await client.connect();
      await disconnected.future.timeout(const Duration(seconds: 2));
      await client.connect();
      recoverySocket!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'message.delta',
            'session_id': 'runtime-quarantine-0',
            'seq': 2,
            'payload': {'text': 'unsafe-before-recovery'},
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      client.commitRecoveryRuntime('runtime-quarantine-0');
      recoverySocket!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'message.delta',
            'session_id': 'runtime-quarantine-0',
            'seq': 3,
            'payload': {'text': 'safe-after-recovery'},
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(initialRuntimeIds.length, ReplayCoordinator.maxTrackedRuntimes);
      expect(texts, isEmpty);
    },
  );

  test(
    'a new replay epoch quarantines every prior runtime watermark',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var connections = 0;
      var initialEventsReceived = 0;
      final initialReceived = Completer<void>();
      final newEpochSent = Completer<void>();
      WebSocket? recoverySocket;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        connections++;
        if (connections == 1) {
          for (final runtimeId in const [
            'runtime-epoch-a',
            'runtime-epoch-b',
          ]) {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'message.delta',
                  'session_id': runtimeId,
                  'seq': 1,
                  'payload': {'replay_epoch': 'epoch-old'},
                },
              }),
            );
          }
          await initialReceived.future.timeout(const Duration(seconds: 2));
          await socket.close();
          return;
        }
        recoverySocket = socket;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': 'runtime-epoch-a',
              'seq': 2,
              'payload': {'replay_epoch': 'epoch-new'},
            },
          }),
        );
        for (final runtimeId in const ['runtime-epoch-a', 'runtime-epoch-b']) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': runtimeId,
                'seq': 2,
                'payload': {'text': 'unsafe-$runtimeId'},
              },
            }),
          );
        }
        newEpochSent.complete();
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] != 'session.events.since') continue;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'epoch': 'epoch-new',
                'truncated': false,
                'events': const [],
              },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-new-epoch',
          label: 'New epoch',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final texts = <String>[];
      final disconnected = Completer<void>();
      final subscription = client.events.listen(
        (event) {
          if (event.payload['replay_epoch'] == 'epoch-old' &&
              ++initialEventsReceived == 2 &&
              !initialReceived.isCompleted) {
            initialReceived.complete();
          }
          if (event.payload['text'] case final String text) texts.add(text);
        },
        onError: (Object _, StackTrace _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      addTearDown(subscription.cancel);

      await client.connect();
      await disconnected.future.timeout(const Duration(seconds: 2));
      await client.connect();
      await newEpochSent.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(texts, isEmpty);

      for (final runtimeId in const ['runtime-epoch-a', 'runtime-epoch-b']) {
        client.commitRecoveryRuntime(runtimeId);
        recoverySocket!.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': runtimeId,
              'seq': 3,
              'payload': {'text': 'safe-$runtimeId'},
            },
          }),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(texts, isEmpty);
    },
  );

  test(
    'un replay truncado descarta tanto el tail como frames vivos retenidos',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var connections = 0;
      final firstLiveSent = Completer<void>();
      final firstLiveReceived = Completer<void>();
      final replayRequested = Completer<void>();
      final recoveryCommitted = Completer<void>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        connections++;
        if (connections == 1) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'runtime-replay',
                'seq': 1,
                'payload': {'replay_epoch': 'epoch-qa'},
              },
            }),
          );
          firstLiveSent.complete();
          await firstLiveReceived.future.timeout(const Duration(seconds: 2));
          await socket.close();
          return;
        }
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] != 'session.events.since') continue;
          replayRequested.complete();
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'runtime-replay',
                'seq': 3,
                'payload': {'text': 'live-after-replay-request'},
              },
            }),
          );
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'epoch': 'epoch-qa',
                'truncated': true,
                'latest_seq': 3,
                'events': [
                  {
                    'type': 'message.delta',
                    'session_id': 'runtime-replay',
                    'seq': 2,
                    'payload': {'text': 'replayed-gap'},
                  },
                ],
              },
            }),
          );
          // This frame arrives after the truncation answer, when the local
          // replay hold has already been released. It is still unsafe until an
          // authoritative session recovery re-establishes this runtime.
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'runtime-replay',
                'seq': 4,
                'payload': {'text': 'live-after-truncation'},
              },
            }),
          );
          await recoveryCommitted.future.timeout(const Duration(seconds: 2));
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'runtime-replay',
                'seq': 5,
                'payload': {'text': 'live-after-authoritative-recovery'},
              },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-replay',
          label: 'Replay',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'unused',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final events = <TuiGatewayEvent>[];
      final disconnected = Completer<void>();
      final subscription = client.events.listen(
        (event) {
          events.add(event);
          if (event.sessionId == 'runtime-replay' &&
              event.payload['replay_epoch'] == 'epoch-qa' &&
              !firstLiveReceived.isCompleted) {
            firstLiveReceived.complete();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      addTearDown(subscription.cancel);

      await client.connect();
      await firstLiveSent.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('initial event was not emitted'),
      );
      await firstLiveReceived.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('initial event was not dispatched'),
      );
      await disconnected.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('first transport did not close'),
      );
      await client.connect();
      await replayRequested.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('replay RPC was not requested'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        events.map((event) => event.payload['text']).whereType<String>(),
        isEmpty,
      );
      // The app only releases this runtime after applying a recovery snapshot.
      client.commitRecoveryRuntime('runtime-replay');
      recoveryCommitted.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        events.map((event) => event.payload['text']).whereType<String>(),
        isEmpty,
      );
    },
  );

  group(
    'replay rows use the live event grammar plus identity and sequence',
    () {
      final malformedRows = <String, Map<String, dynamic>>{
        'type-non-string': {
          'type': ['message.delta'],
          'session_id': 'runtime-replay-grammar',
          'seq': 2,
          'payload': {'text': 'injected'},
        },
        'payload-present-non-map': {
          'type': 'message.delta',
          'session_id': 'runtime-replay-grammar',
          'seq': 2,
          'payload': ['injected'],
        },
        'session-absent': {
          'type': 'message.delta',
          'seq': 2,
          'payload': {'text': 'injected'},
        },
        'session-conflicting': {
          'type': 'message.delta',
          'session_id': 'runtime-other',
          'seq': 2,
          'payload': {'text': 'injected'},
        },
        'seq-absent': {
          'type': 'message.delta',
          'session_id': 'runtime-replay-grammar',
          'payload': {'text': 'injected'},
        },
        'seq-non-numeric': {
          'type': 'message.delta',
          'session_id': 'runtime-replay-grammar',
          'seq': '2',
          'payload': {'text': 'injected'},
        },
      };

      for (final entry in malformedRows.entries) {
        test(
          '${entry.key} quarantines atomically without releasing held live',
          () async {
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final sockets = <WebSocket>[];
            addTearDown(() async {
              for (final socket in sockets) {
                await socket.close();
              }
            });
            var connections = 0;
            final initialReceived = Completer<void>();
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
              sockets.add(socket);
              connections++;
              if (connections == 1) {
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': 'message.delta',
                      'session_id': 'runtime-replay-grammar',
                      'seq': 1,
                      'payload': {'replay_epoch': 'epoch-replay-grammar'},
                    },
                  }),
                );
                await initialReceived.future.timeout(
                  const Duration(seconds: 2),
                );
                await socket.close();
                return;
              }
              await for (final raw in socket) {
                final frame = jsonDecode(raw as String) as Map<String, dynamic>;
                if (frame['method'] != 'session.events.since') continue;
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'method': 'event',
                    'params': {
                      'type': 'message.delta',
                      'session_id': 'runtime-replay-grammar',
                      'seq': 3,
                      'payload': {'text': 'held-live'},
                    },
                  }),
                );
                socket.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': frame['id'],
                    'result': {
                      'epoch': 'epoch-replay-grammar',
                      'truncated': false,
                      'latest_seq': 3,
                      'events': [entry.value],
                    },
                  }),
                );
              }
            });

            final client = TuiGatewayClient(
              SavedConnection(
                id: 'replay-grammar-${entry.key}',
                label: 'Replay grammar ${entry.key}',
                host: '127.0.0.1',
                port: 8642,
                apiKey: String.fromCharCodes(const [113, 97]),
                dashboardUrl: 'http://127.0.0.1:${server.port}',
              ),
              dashboard: _TicketDashboardClient(),
            );
            addTearDown(client.close);
            final texts = <String>[];
            final disconnected = Completer<void>();
            final subscription = client.events.listen(
              (event) {
                if (event.sessionId == 'runtime-replay-grammar' &&
                    event.sequence == 1 &&
                    !initialReceived.isCompleted) {
                  initialReceived.complete();
                }
                final text = event.payload['text'];
                if (text is String) texts.add(text);
              },
              onError: (Object _, StackTrace _) {
                if (!disconnected.isCompleted) disconnected.complete();
              },
            );
            addTearDown(subscription.cancel);
            final previousDebugPrint = debugPrint;
            debugPrint = (message, {wrapWidth}) {};
            addTearDown(() => debugPrint = previousDebugPrint);

            await client.connect();
            await initialReceived.future.timeout(const Duration(seconds: 2));
            await disconnected.future.timeout(const Duration(seconds: 2));
            await client.connect();
            await Future<void>.delayed(const Duration(milliseconds: 50));

            expect(texts, isEmpty, reason: entry.key);
          },
          timeout: const Timeout(Duration(seconds: 10)),
        );
      }
    },
  );

  test(
    'valid replay accepts unknown type and absent payload monotonically',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var connections = 0;
      final initialReceived = Completer<void>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'epoch-a'},
            },
          }),
        );
        connections++;
        if (connections == 1) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'runtime-valid-replay-grammar',
                'seq': 1,
                'payload': {'replay_epoch': 'epoch-valid-replay-grammar'},
              },
            }),
          );
          await initialReceived.future.timeout(const Duration(seconds: 2));
          await socket.close();
          return;
        }
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] != 'session.events.since') continue;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'epoch': 'epoch-valid-replay-grammar',
                'truncated': false,
                'latest_seq': 2,
                'events': [
                  {
                    'type': 'future.replay.event',
                    'session_id': 'runtime-valid-replay-grammar',
                    'seq': 2,
                  },
                ],
              },
            }),
          );
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'valid-replay-grammar',
          label: 'Valid replay grammar',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);
      final events = <TuiGatewayEvent>[];
      final disconnected = Completer<void>();
      final subscription = client.events.listen(
        (event) {
          events.add(event);
          if (event.sessionId == 'runtime-valid-replay-grammar' &&
              event.sequence == 1 &&
              !initialReceived.isCompleted) {
            initialReceived.complete();
          }
        },
        onError: (Object _, StackTrace _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      addTearDown(subscription.cancel);

      await client.connect();
      await initialReceived.future.timeout(const Duration(seconds: 2));
      await disconnected.future.timeout(const Duration(seconds: 2));
      await client.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final replayed = events.where(
        (event) => event.type == 'future.replay.event',
      );
      expect(replayed, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test('rechaza atómicamente un replay con secuencias inválidas', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var connections = 0;
    final initialReceived = Completer<void>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      connections++;
      if (connections == 1) {
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': 'runtime-ordered-replay',
              'seq': 1,
              'payload': {'replay_epoch': 'epoch-ordered'},
            },
          }),
        );
        await initialReceived.future.timeout(const Duration(seconds: 2));
        await socket.close();
        return;
      }
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] != 'session.events.since') continue;
        // Neither replay nor held live events may escape when any row is
        // malformed; authoritative recovery must re-establish the runtime.
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'message.delta',
              'session_id': 'runtime-ordered-replay',
              'seq': 4,
              'payload': {'text': 'live-fourth'},
            },
          }),
        );
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'epoch': 'epoch-ordered',
              'truncated': false,
              'latest_seq': 4,
              'events': [
                {
                  'type': 'message.delta',
                  'session_id': 'runtime-ordered-replay',
                  'seq': 3,
                  'payload': {'text': 'replayed-third'},
                },
                // Protocol seq is an integer. A fractional value must not
                // collapse onto seq=2 and steal the real frame's watermark.
                {
                  'type': 'message.delta',
                  'session_id': 'runtime-ordered-replay',
                  'seq': 2.5,
                  'payload': {'text': 'replayed-fractional'},
                },
                // Zero is not a valid monotonic replay sequence either.
                {
                  'type': 'message.delta',
                  'session_id': 'runtime-ordered-replay',
                  'seq': 0,
                  'payload': {'text': 'replayed-zero'},
                },
                // A malformed unsequenced entry must not prevent valid
                // sequenced entries on either side from being ordered.
                {
                  'type': 'message.delta',
                  'session_id': 'runtime-ordered-replay',
                  'payload': {'text': 'replayed-unsequenced'},
                },
                {
                  'type': 'message.delta',
                  'session_id': 'runtime-ordered-replay',
                  'seq': 2,
                  'payload': {'text': 'replayed-second'},
                },
              ],
            },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-ordered-replay',
        label: 'Ordered replay',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);
    final texts = <String>[];
    final disconnected = Completer<void>();
    final subscription = client.events.listen(
      (event) {
        if (event.sessionId == 'runtime-ordered-replay' &&
            event.payload['replay_epoch'] == 'epoch-ordered' &&
            !initialReceived.isCompleted) {
          initialReceived.complete();
        }
        final text = event.payload['text'];
        if (text is String) texts.add(text);
      },
      onError: (Object _, StackTrace _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    addTearDown(subscription.cancel);

    await client.connect();
    await initialReceived.future.timeout(const Duration(seconds: 2));
    await disconnected.future.timeout(const Duration(seconds: 2));
    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(texts, isEmpty);
  });

  test('cierra un socket idle limpiamente y permite reconectar', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final sockets = <WebSocket>[];
    final firstAccepted = Completer<void>();
    final acceptedTwice = Completer<void>();
    final firstClosed = Completer<void>();
    int? firstCloseCode;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-a'},
          },
        }),
      );
      sockets.add(socket);
      if (sockets.length == 1 && !firstAccepted.isCompleted) {
        firstAccepted.complete();
      }
      if (sockets.length == 2 && !acceptedTwice.isCompleted) {
        acceptedTwice.complete();
      }
      // Escuchar el stream hace que dart:io procese también el close frame.
      await for (final _ in socket) {}
      if (sockets.length == 1) {
        firstCloseCode = socket.closeCode;
        if (!firstClosed.isCompleted) firstClosed.complete();
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-idle-reconnect',
        label: 'Idle reconnect',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    await client.connect();
    await firstAccepted.future.timeout(const Duration(seconds: 2));
    await client.disconnectIdle();
    await firstClosed.future.timeout(const Duration(seconds: 2));
    expect(firstCloseCode, 1000);

    await client.connect();
    await acceptedTwice.future.timeout(const Duration(seconds: 2));
    expect(sockets, hasLength(2));
  });

  test('session.close envía runtime exacto y exige closed true', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final closeFrames = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-close'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] == 'session.close') {
          closeFrames.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {'closed': true},
            }),
          );
        }
      }
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'session-close-contract',
        label: 'Session close contract',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    expect(await client.closeSession('runtime-owned-exact'), isTrue);
    expect(closeFrames, hasLength(1));
    expect(closeFrames.single['params'], {'session_id': 'runtime-owned-exact'});
  });

  test('session.close rechaza closed malformed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'epoch-close-malformed'},
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] == 'session.close') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {'closed': 'yes'},
            }),
          );
        }
      }
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'session-close-malformed',
        label: 'Session close malformed',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    await expectLater(
      client.closeSession('runtime-owned-exact'),
      throwsA(
        isA<TuiGatewayRpcError>()
            .having((error) => error.method, 'method', 'session.close')
            .having(
              (error) => error.origin,
              'origin',
              CompressionFailureOrigin.malformed,
            ),
      ),
    );
  });
}
