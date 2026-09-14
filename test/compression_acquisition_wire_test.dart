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

import 'support/in_memory_compression_fence_storage.dart';

class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'review-local-fixture',
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

void main() {
  for (final scenario in const ['binding', 'profile', 'dispose', 'foreign']) {
    final foreign = scenario == 'foreign';
    test(
      foreign
          ? 'REGRESSION_COMP_FIX4_FOREIGN_RESPONSE_REJECTED_WIRE'
          : 'REGRESSION_COMP_FIX4_INVALIDATION_BEFORE_RESUME_${scenario.toUpperCase()}_WIRE',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final entered = Completer<void>(), release = Completer<void>();
        final frames = <Map<String, dynamic>>[];
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          _emitGatewayReady(socket);
          await for (final raw in socket) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            frames.add(frame);
            final method = frame['method'];
            if (method == 'gateway.capabilities' && !foreign) {
              if (!entered.isCompleted) entered.complete();
              await release.future;
            }
            final result = switch (method) {
              'gateway.capabilities' => {'per_session_exclusive_submit': true},
              'session.resume' => {
                'session_id': foreign ? 'runtime-FOREIGN' : 'runtime-A',
                'session_key': foreign ? 'stored-FOREIGN' : 'stored-A',
                'info': foreign
                    ? {'lineage_root_id': 'stored-FOREIGN'}
                    : <String, dynamic>{},
                'messages': <Object>[],
              },
              'session.compress' => {
                'compressed': false,
                'lock_held': true,
                'message': 'fixture busy',
              },
              _ => <String, dynamic>{},
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
        final connection = SavedConnection(
          id: 'review-wire-$foreign',
          label: 'Review',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes([113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        );
        final client = TuiGatewayClient(connection, dashboard: _Dashboard());
        final chat = ActiveChat(
          connection: connection,
          sessionId: 'stored-A',
          sessionTitle: 'Review',
          notifications: null,
          onTerminal: () {},
          desktopGateway: client,
          compressionFenceStore: DesktopCompressionFenceStore(
            storage: InMemoryDesktopCompressionFenceStorage(),
            mutationNamespaceForTesting: 'review-wire-$foreign',
          ),
          api: ApiClient(
            baseUrl: 'http://127.0.0.1:1',
            apiKey: String.fromCharCodes([113, 97]),
            httpClient: MockClient((_) async => http.Response('{}', 500)),
          ),
        );
        addTearDown(chat.dispose);
        final pending = chat.compressDesktopSessionForPresentation();
        if (!foreign) {
          await entered.future;
          switch (scenario) {
            case 'binding':
              expect(chat.bindKnownStoredSession('stored-B'), isTrue);
            case 'profile':
              expect(chat.bindSessionProfile('other-profile'), 'other-profile');
            case 'dispose':
              chat.dispose();
          }
          release.complete();
        }
        await pending;
        final methods = frames.map((f) => f['method']).toList();
        if (foreign) {
          expect(
            methods,
            isNot(contains('session.compress')),
            reason: 'foreign lineage in acquisition cannot authorize mutation',
          );
        } else {
          expect(
            methods,
            isNot(contains('session.resume')),
            reason:
                'acquisition identity must be checked at final wire admission',
          );
        }
      },
    );
  }

  test('REGRESSION_COMP_FIX4_AMBIGUOUS_TIP_REJECTED_WIRE', () async {
    final methods = await _runTipAcquisitionWire(storedTip: 'stored-AMBIGUOUS');

    expect(methods, isNot(contains('session.compress')));
  });

  test('REGRESSION_COMP_FIX4_MISSING_IDENTITY_REJECTED_WIRE', () async {
    final methods = await _runTipAcquisitionWire(storedTip: null);

    expect(methods, isNot(contains('session.compress')));
  });

  test('REGRESSION_COMP_FIX4_SAME_LINEAGE_TIP_ACCEPTED_WIRE', () async {
    final methods = await _runTipAcquisitionWire(
      storedTip: 'stored-compressed-tip',
      lineageRoot: 'stored-A',
    );

    expect(
      methods,
      containsAllInOrder(const [
        'gateway.capabilities',
        'session.resume',
        'session.compress',
      ]),
    );
  });

  test(
    'REGRESSION_COMP_FIX4_CONCURRENT_VALIDATED_ACQUISITION_REUSED_WIRE',
    () async {
      final result = await _runConcurrentAcquisitionWire();

      expect(result.resumeCount, 2);
      expect(result.compressRuntimeIds, ['runtime-concurrent-B']);
      expect(result.failure, isNull);
    },
  );
}

Future<List<Object?>> _runTipAcquisitionWire({
  required String? storedTip,
  String? lineageRoot,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final frames = <Map<String, dynamic>>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    _emitGatewayReady(socket);
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      frames.add(frame);
      final method = frame['method'];
      final result = switch (method) {
        'gateway.capabilities' => {'per_session_exclusive_submit': true},
        'session.resume' => {
          'session_id': 'runtime-tip',
          'session_key': ?storedTip,
          'info': {'lineage_root_id': ?lineageRoot},
          'messages': <Object>[],
        },
        'session.compress' => {
          'compressed': false,
          'lock_held': true,
          'message': 'fixture busy',
        },
        _ => <String, dynamic>{},
      };
      socket.add(
        jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
      );
    }
  });
  final connection = SavedConnection(
    id: 'fix4-tip-${storedTip ?? 'missing'}',
    label: 'Fix4 acquisition',
    host: '127.0.0.1',
    port: 8642,
    apiKey: String.fromCharCodes(List<int>.filled(32, 7)),
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  );
  final client = TuiGatewayClient(connection, dashboard: _Dashboard());
  final chat = ActiveChat(
    connection: connection,
    sessionId: 'stored-A',
    sessionTitle: 'Fix4 acquisition',
    notifications: null,
    onTerminal: () {},
    desktopGateway: client,
    compressionFenceStore: DesktopCompressionFenceStore(
      storage: InMemoryDesktopCompressionFenceStorage(),
      mutationNamespaceForTesting: 'fix4-tip-${storedTip ?? 'missing'}',
    ),
    api: ApiClient(
      baseUrl: 'http://127.0.0.1:1',
      apiKey: String.fromCharCodes(List<int>.filled(32, 7)),
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    ),
  );
  try {
    await chat.compressDesktopSessionForPresentation();
    return frames.map((frame) => frame['method']).toList(growable: false);
  } finally {
    chat.dispose();
    await client.close();
    await server.close(force: true);
  }
}

Future<({int resumeCount, List<String> compressRuntimeIds, Object? failure})>
_runConcurrentAcquisitionWire() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final firstResumeEntered = Completer<void>();
  final releaseFirstResume = Completer<void>();
  final compressRuntimeIds = <String>[];
  var resumeCount = 0;
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    _emitGatewayReady(socket);
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      final method = frame['method'];
      late final Map<String, dynamic> result;
      if (method == 'gateway.capabilities') {
        result = {'per_session_exclusive_submit': true};
      } else if (method == 'session.resume') {
        resumeCount += 1;
        if (resumeCount == 1) {
          if (!firstResumeEntered.isCompleted) firstResumeEntered.complete();
          unawaited(
            releaseFirstResume.future.then((_) {
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': frame['id'],
                  'result': {
                    'session_id': 'runtime-concurrent-A',
                    'session_key': 'stored-A',
                    'messages': <Object>[],
                  },
                }),
              );
            }),
          );
          continue;
        } else {
          result = {
            'session_id': 'runtime-concurrent-B',
            'session_key': 'stored-concurrent-tip-B',
            'info': {'lineage_root_id': 'stored-A'},
            'messages': <Object>[],
          };
        }
      } else if (method == 'session.compress') {
        final params = frame['params'] as Map<String, dynamic>;
        compressRuntimeIds.add(params['session_id'] as String);
        result = {
          'compressed': false,
          'lock_held': true,
          'message': 'fixture busy',
        };
      } else {
        result = <String, dynamic>{};
      }
      socket.add(
        jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
      );
    }
  });
  final connection = SavedConnection(
    id: 'fix4-concurrent-wire',
    label: 'Fix4 concurrent acquisition',
    host: '127.0.0.1',
    port: 8642,
    apiKey: String.fromCharCodes(List<int>.filled(32, 7)),
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  );
  final client = TuiGatewayClient(connection, dashboard: _Dashboard());
  final chat = ActiveChat(
    connection: connection,
    sessionId: 'stored-A',
    sessionTitle: 'Fix4 concurrent acquisition',
    notifications: null,
    onTerminal: () {},
    desktopGateway: client,
    compressionFenceStore: DesktopCompressionFenceStore(
      storage: InMemoryDesktopCompressionFenceStorage(),
      mutationNamespaceForTesting: 'fix4-concurrent-wire',
    ),
    api: ApiClient(
      baseUrl: 'http://127.0.0.1:1',
      apiKey: String.fromCharCodes(List<int>.filled(32, 7)),
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    ),
  );
  try {
    final pending = chat.compressDesktopSessionForPresentation();
    await firstResumeEntered.future;
    expect(
      await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
      isTrue,
    );
    releaseFirstResume.complete();
    final presentation = await pending;
    return (
      resumeCount: resumeCount,
      compressRuntimeIds: List<String>.unmodifiable(compressRuntimeIds),
      failure: presentation.failure,
    );
  } finally {
    if (!releaseFirstResume.isCompleted) releaseFirstResume.complete();
    chat.dispose();
    await client.close();
    await server.close(force: true);
  }
}
