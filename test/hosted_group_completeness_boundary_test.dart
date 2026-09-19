import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

final class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'test');
}

typedef _ResultBuilder =
    FutureOr<Object?> Function(String method, Map<String, dynamic> params);

final class _HostedBoundaryHarness {
  final HttpServer server;
  final TuiGatewayClient client;
  final int generation;
  final List<Map<String, dynamic>> requests;
  final List<WebSocket> sockets;

  const _HostedBoundaryHarness._({
    required this.server,
    required this.client,
    required this.generation,
    required this.requests,
    required this.sockets,
  });

  static Future<_HostedBoundaryHarness> start(
    _ResultBuilder resultFor, {
    Set<String> closeAfterFirstResponse = const {},
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, dynamic>>[];
    final sockets = <WebSocket>[];
    final closedMethods = <String>{};
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'hosted-completeness'},
          },
        }),
      );
      socket.listen((raw) async {
        final rpc = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
        final method = rpc['method'] as String;
        if (method == 'gateway.ping') return;
        requests.add(rpc);
        final params = Map<String, dynamic>.from(rpc['params'] as Map);
        final result = method == 'groups.capabilities'
            ? {
                'protocol_version': 2,
                'driver': true,
                'methods': GroupMethod.values
                    .where((entry) => entry != GroupMethod.promote)
                    .map((entry) => entry.wire)
                    .toList(),
                'max_log_limit': 500,
              }
            : await resultFor(method, params);
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], 'result': result}),
        );
        if (closeAfterFirstResponse.contains(method) &&
            closedMethods.add(method)) {
          scheduleMicrotask(
            () =>
                socket.close(WebSocketStatus.goingAway, 'rotate exact channel'),
          );
        }
      });
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'hosted-completeness',
        label: 'Hosted completeness',
        host: '127.0.0.1',
        port: 8642,
        dashboardUrl: 'http://127.0.0.1:${server.port}',
        apiKey: String.fromCharCodes(const [113, 97]),
      ),
      dashboard: _Dashboard(),
      heartbeatInterval: const Duration(hours: 1),
      heartbeatDeadline: const Duration(hours: 2),
    );
    try {
      final capabilities = await client.groupCapabilities();
      return _HostedBoundaryHarness._(
        server: server,
        client: client,
        generation: capabilities.generation,
        requests: requests,
        sockets: sockets,
      );
    } catch (_) {
      await client.close();
      await server.close(force: true);
      rethrow;
    }
  }

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

void main() {
  test(
    'groups.capabilities fails closed when its exact channel closes',
    () async {
      await expectLater(
        _HostedBoundaryHarness.start(
          (method, params) => _validResult(method, params),
          closeAfterFirstResponse: const {'groups.capabilities'},
        ),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.failureKind,
            'failureKind',
            TuiGatewayRpcFailureKind.connectionLost,
          ),
        ),
      );
    },
  );

  test(
    'groups.list page parser retains typed rows and official next_offset',
    () {
      final page = HostedGroupListPage.fromJson({
        'rooms': [_room(0)],
        'next_offset': 1,
      });

      expect(page.rooms.single.roomId, 'room-000');
      expect(page.nextOffset, 1);
      expect(
        () => HostedGroupListPage.fromJson({
          'rooms': [_room(0)],
          'next_offset': '1',
        }),
        throwsFormatException,
      );
    },
  );

  group('exact WebSocket lease fences every projectable room operation', () {
    for (final operation in const [
      'groups.list',
      'groups.state',
      'groups.create',
      'groups.rename',
      'groups.stop',
      'groups.approve',
      'groups.disband',
    ]) {
      test('$operation fails closed when its exact channel closes', () async {
        final harness = await _HostedBoundaryHarness.start(
          (method, params) => _validResult(method, params),
          closeAfterFirstResponse: {operation},
        );
        addTearDown(harness.close);
        final projected = <HostedGroupRoom>[];

        try {
          final value = await _invoke(harness, operation);
          if (value is List<HostedGroupRoom>) {
            projected.addAll(value);
          } else {
            projected.add(value as HostedGroupRoom);
          }
          fail('$operation projected data from a retired channel');
        } on TuiGatewayRpcError catch (error) {
          expect(error.failureKind, TuiGatewayRpcFailureKind.connectionLost);
        }

        expect(projected, isEmpty, reason: operation);
        if (_mutationMethods.contains(operation)) {
          expect(
            harness.requests.where(
              (request) => request['method'] == 'groups.state',
            ),
            isEmpty,
            reason: '$operation must not rebase its nested read-back',
          );
          expect(harness.sockets, hasLength(1));
        }
      });

      test('$operation projects on one unchanged exact channel', () async {
        final harness = await _HostedBoundaryHarness.start(
          (method, params) => _validResult(method, params),
        );
        addTearDown(harness.close);

        final value = await _invoke(harness, operation);
        final rooms = value is List<HostedGroupRoom>
            ? value
            : <HostedGroupRoom>[value as HostedGroupRoom];

        expect(rooms.map((room) => room.roomId), everyElement('room-1'));
        expect(harness.sockets, hasLength(1));
        if (_mutationMethods.contains(operation)) {
          expect(
            harness.requests.map((request) => request['method']),
            containsAllInOrder([operation, 'groups.state']),
          );
        }
      });
    }
  });

  test('groups.retry retirement emits no mutation frame', () async {
    final harness = await _HostedBoundaryHarness.start(
      (method, params) => _validResult(method, params),
    );
    addTearDown(harness.close);

    await expectLater(
      harness.client.retryGroupTask(
        roomId: 'room-1',
        taskId: 'task-1',
        generation: harness.generation,
      ),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(
      harness.requests.where((request) => request['method'] == 'groups.retry'),
      isEmpty,
    );
  });

  test(
    'groups.send proves its acknowledgement in the log over one exact lease',
    () async {
      final durableId = TuiGatewayClient.durableGroupEventId('client-event-1');
      final harness = await _HostedBoundaryHarness.start((method, params) {
        if (method == 'groups.send') {
          return {
            'accepted': true,
            'client_event_id': params['event_id'],
            'event': {
              'room_id': 'room-1',
              'seq': 1,
              'event_id': durableId,
              'kind': 'message.user',
              'actor': {'kind': 'user', 'id': 'desktop'},
              'authority_epoch': 1,
              'payload': {'text': 'hello there', 'thread_id': 'thread-1'},
              'created_at': 1.0,
              'idempotent': false,
            },
          };
        }
        if (method == 'groups.log') {
          return {
            'events': [
              {
                'room_id': 'room-1',
                'seq': 1,
                'event_id': durableId,
                'kind': 'message.user',
                'actor': {'kind': 'user', 'id': 'desktop'},
                'authority_epoch': 1,
                'payload': {'text': 'hello there', 'thread_id': 'thread-1'},
                'created_at': 1.0,
                'idempotent': false,
              },
            ],
            'cursor': 1,
            'latest_seq': 1,
            'has_more': false,
            'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
          };
        }
        return _validResult(method, params);
      });
      addTearDown(harness.close);

      final page = await harness.client.sendGroupText(
        roomId: 'room-1',
        text: 'hello there',
        threadId: 'thread-1',
        eventId: 'client-event-1',
        generation: harness.generation,
      );

      expect(page.events.single.eventId, durableId);
      expect(
        harness.requests.map((request) => request['method']),
        containsAllInOrder(['groups.send', 'groups.log']),
      );
      expect(harness.sockets, hasLength(1));
    },
  );

  test(
    'groups.log.complete pages the whole room history over one exact lease',
    () async {
      const total = 3;
      final harness = await _HostedBoundaryHarness.start((method, params) {
        if (method != 'groups.log') return _validResult(method, params);
        final sinceSeq = params['since_seq'] as int;
        final seq = sinceSeq + 1;
        return {
          'events': seq > total
              ? <Object?>[]
              : [
                  {
                    'room_id': 'room-1',
                    'seq': seq,
                    'event_id': 'user:seq-$seq',
                    'kind': 'message.user',
                    'actor': {'kind': 'user', 'id': 'desktop'},
                    'authority_epoch': 1,
                    'payload': {'text': 'message $seq', 'thread_id': 'thread-1'},
                    'created_at': seq.toDouble(),
                    'idempotent': false,
                  },
                ],
          'cursor': seq > total ? sinceSeq : seq,
          'latest_seq': total,
          'has_more': seq < total,
          'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
        };
      });
      addTearDown(harness.close);

      final page = await harness.client.groupLogComplete(
        'room-1',
        pageLimit: 1,
        generation: harness.generation,
      );

      expect(page.events, hasLength(total));
      expect(
        page.events.map((event) => event.publicText),
        ['message 1', 'message 2', 'message 3'],
      );
      expect(page.hasMore, isFalse);
      expect(
        harness.requests
            .where((request) => request['method'] == 'groups.log')
            .length,
        total,
      );
      expect(harness.sockets, hasLength(1));
    },
  );

  test(
    'groups.list follows official offsets through an empty terminal page and publishes once',
    () async {
      final terminalRequested = Completer<void>();
      final releaseTerminal = Completer<void>();
      final harness = await _HostedBoundaryHarness.start((
        method,
        params,
      ) async {
        if (method != 'groups.list') return _validResult(method, params);
        final offset = params['offset'] as int;
        if (offset == 257) {
          if (!terminalRequested.isCompleted) terminalRequested.complete();
          await releaseTerminal.future;
          return {'rooms': <Object?>[], 'next_offset': null};
        }
        final end = switch (offset) {
          0 => 100,
          100 => 200,
          200 => 257,
          _ => throw StateError('unexpected list offset $offset'),
        };
        return {
          'rooms': [
            for (var index = offset; index < end; index++) _room(index),
          ],
          'next_offset': end,
        };
      });
      addTearDown(harness.close);
      var published = false;
      final loading = harness.client
          .listGroups(generation: harness.generation)
          .then((value) {
            published = true;
            return value;
          });

      await terminalRequested.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(
        published,
        isFalse,
        reason: 'no intermediate page may be published',
      );
      releaseTerminal.complete();
      final rooms = await loading;

      expect(rooms, hasLength(257));
      expect(rooms.map((room) => room.roomId), [
        for (var index = 0; index < 257; index++) _roomId(index),
      ]);
      final listRequests = harness.requests
          .where((request) => request['method'] == 'groups.list')
          .toList();
      expect(
        listRequests.map((request) => (request['params'] as Map)['offset']),
        [0, 100, 200, 257],
      );
      expect(
        listRequests.map((request) => (request['params'] as Map)['limit']),
        everyElement(500),
      );
    },
  );

  group('groups.list rejects incomplete or ambiguous pagination', () {
    final cases = <String, _ResultBuilder>{
      'malformed next_offset': (method, params) => {
        'rooms': [_room(0)],
        'next_offset': '1',
      },
      'non-advancing next_offset': (method, params) => {
        'rooms': [_room(0)],
        'next_offset': params['offset'],
      },
      'skipped next_offset': (method, params) => {
        'rooms': [_room(0)],
        'next_offset': 2,
      },
      'reordered next_offset': (method, params) {
        final offset = params['offset'] as int;
        return offset == 0
            ? {
                'rooms': [_room(0), _room(1)],
                'next_offset': 2,
              }
            : {
                'rooms': [_room(2)],
                'next_offset': 1,
              };
      },
      'cyclic next_offset': (method, params) {
        final offset = params['offset'] as int;
        return switch (offset) {
          0 => {
            'rooms': [_room(0)],
            'next_offset': 1,
          },
          1 => {
            'rooms': [_room(1)],
            'next_offset': 2,
          },
          _ => {
            'rooms': [_room(2)],
            'next_offset': 1,
          },
        };
      },
      'duplicate room across pages': (method, params) {
        final offset = params['offset'] as int;
        return offset == 0
            ? {
                'rooms': [_room(0)],
                'next_offset': 1,
              }
            : {
                'rooms': [_room(0)],
                'next_offset': null,
              };
      },
    };

    for (final entry in cases.entries) {
      test(entry.key, () async {
        final harness = await _HostedBoundaryHarness.start(entry.value);
        addTearDown(harness.close);
        final projected = <HostedGroupRoom>[];

        try {
          projected.addAll(
            await harness.client.listGroups(generation: harness.generation),
          );
          fail('${entry.key} produced a complete room claim');
        } on TuiGatewayRpcError catch (error) {
          expect(error.method, 'groups.list');
        }

        expect(projected, isEmpty);
      });
    }
  });

  test('groups.list rotation between pages exposes no partial list', () async {
    final harness = await _HostedBoundaryHarness.start(
      (method, params) => {
        'rooms': [_room(params['offset'] as int)],
        'next_offset': (params['offset'] as int) + 1,
      },
      closeAfterFirstResponse: {'groups.list'},
    );
    addTearDown(harness.close);
    final projected = <HostedGroupRoom>[];

    await expectLater(
      () async => projected.addAll(
        await harness.client.listGroups(generation: harness.generation),
      ),
      throwsA(
        isA<TuiGatewayRpcError>().having(
          (error) => error.failureKind,
          'failureKind',
          TuiGatewayRpcFailureKind.connectionLost,
        ),
      ),
    );
    expect(projected, isEmpty);
  });

  test('groups.list pagination is bounded and publishes no prefix', () async {
    final harness = await _HostedBoundaryHarness.start((method, params) {
      final offset = params['offset'] as int;
      return {
        'rooms': [_room(offset)],
        'next_offset': offset + 1,
      };
    });
    addTearDown(harness.close);
    final projected = <HostedGroupRoom>[];

    await expectLater(
      () async => projected.addAll(
        await harness.client.listGroups(generation: harness.generation),
      ),
      throwsA(isA<TuiGatewayRpcError>()),
    );

    expect(projected, isEmpty);
    expect(
      harness.requests.where((request) => request['method'] == 'groups.list'),
      hasLength(512),
    );
  });
}

const _mutationMethods = {
  'groups.create',
  'groups.rename',
  'groups.stop',
  'groups.approve',
  'groups.disband',
};

Future<Object> _invoke(_HostedBoundaryHarness harness, String operation) =>
    switch (operation) {
      'groups.list' => harness.client.listGroups(
        generation: harness.generation,
      ),
      'groups.state' => harness.client.groupState(
        'room-1',
        generation: harness.generation,
      ),
      'groups.create' => harness.client.createGroup(
        roomId: 'room-1',
        name: 'Room 1',
        members: const [],
        generation: harness.generation,
      ),
      'groups.rename' => harness.client.renameGroup(
        roomId: 'room-1',
        eventId: 'rename-1',
        name: 'Renamed',
        generation: harness.generation,
      ),
      'groups.stop' => harness.client.stopGroup(
        roomId: 'room-1',
        cancelId: 'stop-1',
        generation: harness.generation,
      ),

      'groups.approve' => harness.client.approveGroupTask(
        roomId: 'room-1',
        memberId: 'member-1',
        taskId: 'task-1',
        executionGeneration: 1,
        choice: 'approve',
        requestId: 'request-1',
        generation: harness.generation,
      ),
      'groups.disband' => harness.client.disbandGroup(
        roomId: 'room-1',
        cancelId: 'disband-1',
        generation: harness.generation,
      ),
      _ => throw StateError('unknown operation $operation'),
    };

Object _validResult(String method, Map<String, dynamic> params) =>
    switch (method) {
      'groups.list' => {
        'rooms': [_room(1)],
        'next_offset': null,
      },
      'groups.state' => {'room': _room(1)},
      'groups.create' => {'room': _room(1)},
      'groups.rename' ||
      'groups.stop' ||
      'groups.approve' ||
      'groups.disband' => <String, dynamic>{},
      _ => throw StateError('unexpected method $method'),
    };

String _roomId(int index) =>
    index == 1 ? 'room-1' : 'room-${index.toString().padLeft(3, '0')}';

Map<String, Object?> _room(int index) => {
  'room_id': _roomId(index),
  'name': 'Room $index',
  'members': <Object?>[],
  'authority_gateway_id': 'gateway-private',
  'authority_epoch': 1,
  'revision': 1,
  'created_at': 1,
  'updated_at': 2,
  'latest_seq': 0,
};
