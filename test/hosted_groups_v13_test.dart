import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
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

void main() {
  test('capabilities fail closed and cache by connection generation', () async {
    var calls = 0;
    final cache = GroupsCapabilityCache();
    Future<Object?> load() async {
      calls++;
      return {
        'protocol_version': 2,
        'driver': true,
        'methods': [
          'groups.capabilities',
          'groups.list',
          'groups.create',
          'groups.state',
          'groups.send',
          'groups.rename',
          'groups.log',
          'groups.disband',
          'groups.stop',
          'groups.retry',
          'groups.approve',
          'groups.promote',
          'groups.peer.invite',
        ],
        'max_log_limit': 500,
      };
    }

    final first = await cache.resolve(
      connectionId: 'a',
      generation: 7,
      loader: load,
    );
    final same = await cache.resolve(
      connectionId: 'a',
      generation: 7,
      loader: load,
    );
    final next = await cache.resolve(
      connectionId: 'a',
      generation: 8,
      loader: load,
    );
    expect(identical(first, same), isTrue);
    expect(calls, 2);
    expect(first!.supports(GroupMethod.send), isFalse);
    expect(first.supports(GroupMethod.retry), isFalse);
    expect(first.supports(GroupMethod.promote), isFalse);
    expect(next!.generation, 8);

    for (final malformed in <Object?>[
      null,
      {},
      {'protocol_version': 2, 'driver': true, 'methods': 'groups.list'},
      {
        'protocol_version': 2,
        'driver': true,
        'methods': ['groups.list', 3],
      },
    ]) {
      final parsed = GroupsCapabilities.tryParse(
        malformed,
        connectionId: 'a',
        generation: 9,
      );
      expect(parsed, isNull);
    }
  });

  test('strict official room, member and log DTOs reject partial authority', () {
    final room = HostedGroupRoom.fromJson({
      'room_id': 'room-1',
      'name': 'Core',
      'members': [
        {
          'member_id': 'm1',
          'profile': 'research',
          'handle': 'research-home',
          'target': {'kind': 'local', 'profile': 'research'},
        },
        {
          'member_id': 'm2',
          'profile': 'research',
          'handle': 'research-lab',
          'target': {
            'kind': 'peer',
            'peer_id': 'peer-lab',
            'installation_id': 'install-lab',
            'profile': 'research',
            'capability_digest':
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          },
        },
      ],
      'authority_gateway_id': 'gateway-private',
      'authority_epoch': 2,
      'revision': 3,
      'created_at': 1.0,
      'updated_at': 2.0,
      'latest_seq': 4,
      'idempotent': false,
    });
    expect(room.members.map((m) => m.owner.connectionId), [
      'gateway-private',
      'peer-lab',
    ]);
    expect(room.members.map((m) => m.handle), [
      'research-home',
      'research-lab',
    ]);
    expect(
      () => HostedGroupRoom.fromJson({
        ...room.toJsonForTest(),
        'members': [{}],
      }),
      throwsFormatException,
    );

    final page = HostedGroupLogPage.fromJson(
      {
        'events': [
          {
            'room_id': 'room-1',
            'seq': 4,
            'event_id': 'event-private',
            'kind': 'message.user',
            'actor': {'kind': 'user', 'id': 'private-user'},
            'authority_epoch': 2,
            'payload': {'text': 'hello', 'thread_id': 'thread-1'},
            'created_at': 2.0,
            'idempotent': false,
          },
        ],
        'cursor': 4,
        'latest_seq': 4,
        'has_more': false,
        'authority': {'gateway_id': 'gateway-private', 'epoch': 2},
      },
      expectedRoomId: 'room-1',
      sinceSeq: 3,
    );
    expect(page.events.single.publicText, 'hello');
    expect(page.cursor, 4);
  });

  test('hosted member source authority transition matrix', () {
    const base = <String, dynamic>{
      'member_id': 'member-1',
      'handle': 'research',
    };
    final cases =
        <
          ({
            String name,
            Map<String, dynamic> member,
            bool accepted,
            String? connectionId,
          })
        >[
          (
            name: 'official local target',
            member: {
              ...base,
              'profile': 'research',
              'target': {'kind': 'local', 'profile': 'research'},
            },
            accepted: true,
            connectionId: 'gateway-private',
          ),
          (
            name: 'official peer target',
            member: {
              ...base,
              'profile': 'research',
              'target': {
                'kind': 'peer',
                'peer_id': 'peer',
                'installation_id': 'install',
                'profile': 'research',
                'capability_digest':
                    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              },
            },
            accepted: true,
            connectionId: 'peer',
          ),
          (
            name: 'explicit legacy member descriptor is rejected',
            member: {...base, 'connection_id': 'legacy', 'profile': 'research'},
            accepted: false,
            connectionId: null,
          ),
          (
            name: 'transport scope cannot replace missing target connection',
            member: {
              ...base,
              'profile': 'research',
              'target': {'kind': 'peer', 'profile': 'research'},
            },
            accepted: false,
            connectionId: null,
          ),
          (
            name: 'member field cannot replace missing target connection',
            member: {
              ...base,
              'connection_id': 'substitute',
              'profile': 'research',
              'target': {'kind': 'local', 'profile': 'research'},
            },
            accepted: false,
            connectionId: null,
          ),
          (
            name: 'member field cannot replace missing target profile',
            member: {
              ...base,
              'profile': 'substitute',
              'target': {'kind': 'local'},
            },
            accepted: false,
            connectionId: null,
          ),
          (
            name: 'malformed target cannot fall back to member identity',
            member: {
              ...base,
              'connection_id': 'substitute',
              'profile': 'research',
              'target': 'peer',
            },
            accepted: false,
            connectionId: null,
          ),
        ];

    for (final entry in cases) {
      HostedGroupMember parse() => HostedGroupMember.fromJson(
        entry.member,
        authorityGatewayId: 'gateway-private',
      );
      if (entry.accepted) {
        expect(
          parse().owner.connectionId,
          entry.connectionId,
          reason: entry.name,
        );
      } else {
        expect(parse, throwsFormatException, reason: entry.name);
      }
    }
  });

  group('groups.state rejects foreign room identity', () {
    for (final operation in const ['state', 'rename', 'stop', 'disband']) {
      test('$operation read-back cannot return a different room', () async {
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
                'payload': {'replay_epoch': 'foreign-room-$operation'},
              },
            }),
          );
          socket.listen((raw) {
            final rpc = Map<String, dynamic>.from(
              jsonDecode(raw as String) as Map,
            );
            final method = rpc['method'] as String;
            final result = switch (method) {
              'groups.capabilities' => {
                'protocol_version': 2,
                'driver': true,
                'methods': [
                  'groups.capabilities',
                  'groups.state',
                  'groups.rename',
                  'groups.stop',
                  'groups.disband',
                ],
                'max_log_limit': 500,
              },
              'groups.state' => {'room': _room('foreign-room')},
              _ => <String, dynamic>{},
            };
            socket.add(
              jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], 'result': result}),
            );
          });
        });
        final client = TuiGatewayClient(
          SavedConnection(
            id: 'foreign-room-$operation',
            label: 'Foreign room $operation',
            host: '127.0.0.1',
            port: 8642,
            dashboardUrl: 'http://127.0.0.1:${server.port}',
            apiKey: String.fromCharCodes(const [113, 97]),
          ),
          dashboard: _TicketDashboardClient(),
        );
        addTearDown(client.close);
        final capabilities = await client.groupCapabilities();

        final read = switch (operation) {
          'rename' => client.renameGroup(
            roomId: 'requested-room',
            eventId: 'rename-event',
            name: 'Renamed',
            generation: capabilities.generation,
          ),
          'stop' => client.stopGroup(
            roomId: 'requested-room',
            cancelId: 'stop-event',
            generation: capabilities.generation,
          ),
          'disband' => client.disbandGroup(
            roomId: 'requested-room',
            cancelId: 'disband-event',
            generation: capabilities.generation,
          ),
          _ => client.groupState(
            'requested-room',
            generation: capabilities.generation,
          ),
        };

        await expectLater(
          read,
          throwsA(
            isA<TuiGatewayRpcError>()
                .having((error) => error.method, 'method', 'groups.state')
                .having(
                  (error) => error.message,
                  'message',
                  'Hermes returned invalid room state',
                ),
          ),
        );
      });
    }
  });

  group('hosted RPC identity transition matrix', () {
    for (final method in const ['groups.list', 'groups.state']) {
      test(
        '$method rejects a member with transport-substituted authority',
        () async {
          final harness = await _HostedRpcHarness.start((actual, params) {
            if (actual == method) {
              final room = _room('requested-room');
              room['members'] = [
                {
                  'member_id': 'member-1',
                  'handle': 'research',
                  'target': {'profile': 'research'},
                },
              ];
              return method == 'groups.list'
                  ? {
                      'rooms': [room],
                      'next_offset': null,
                    }
                  : {'room': room};
            }
            throw StateError('unexpected hosted method $actual');
          });
          addTearDown(harness.close);

          final projected = <HostedGroupRoom>[];
          try {
            if (method == 'groups.list') {
              projected.addAll(
                await harness.client.listGroups(generation: harness.generation),
              );
            } else {
              projected.add(
                await harness.client.groupState(
                  'requested-room',
                  generation: harness.generation,
                ),
              );
            }
            fail('$method projected a room without member authority');
          } on TuiGatewayRpcError catch (error) {
            expect(error.method, method);
          }
          expect(projected, isEmpty);
          expect(harness.methods, ['groups.capabilities', method]);
        },
      );
    }

    test(
      'groups.create rejects a foreign acknowledgement before read-back',
      () async {
        final harness = await _HostedRpcHarness.start((method, params) {
          if (method == 'groups.create') return {'room': _room('foreign-room')};
          if (method == 'groups.state') return {'room': _room('foreign-room')};
          throw StateError('unexpected hosted method $method');
        });
        addTearDown(harness.close);

        await expectLater(
          harness.client.createGroup(
            roomId: 'requested-room',
            name: 'Shared',
            members: const [],
            generation: harness.generation,
          ),
          throwsA(isA<TuiGatewayRpcError>()),
        );
        expect(harness.methods, ['groups.capabilities', 'groups.create']);
      },
    );

    test(
      'groups.create exact acknowledgement reads back the requested room',
      () async {
        final harness = await _HostedRpcHarness.start((method, params) {
          if (method == 'groups.create' || method == 'groups.state') {
            return {'room': _room('requested-room')};
          }
          throw StateError('unexpected hosted method $method');
        });
        addTearDown(harness.close);

        final room = await harness.client.createGroup(
          roomId: 'requested-room',
          name: 'Shared',
          members: const [],
          generation: harness.generation,
        );

        expect(room.roomId, 'requested-room');
        expect(harness.methods, [
          'groups.capabilities',
          'groups.create',
          'groups.state',
        ]);
      },
    );

    test('retired groups.send is rejected before any mutation frame', () async {
      final harness = await _HostedRpcHarness.start((method, params) {
        if (method == 'groups.send') {
          return {
            'accepted': true,
            'client_event_id': params['event_id'],
            'event': _event(params['room_id'] as String, 'foreign-event'),
          };
        }
        if (method == 'groups.log') {
          return {
            'events': [_event(params['room_id'] as String, 'foreign-event')],
            'cursor': 1,
            'latest_seq': 1,
            'has_more': false,
            'authority': {'gateway_id': 'gateway-private', 'epoch': 1},
          };
        }
        throw StateError('unexpected hosted method $method');
      });
      addTearDown(harness.close);

      await expectLater(
        harness.client.sendGroupText(
          roomId: 'requested-room',
          text: 'hello',
          threadId: 'thread-1',
          eventId: 'requested-event',
          generation: harness.generation,
        ),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(harness.methods, ['groups.capabilities']);
    });
  });
}

typedef _HostedResult =
    Object Function(String method, Map<String, dynamic> params);

final class _HostedRpcHarness {
  final HttpServer server;
  final TuiGatewayClient client;
  final int generation;
  final List<String> methods;

  const _HostedRpcHarness._({
    required this.server,
    required this.client,
    required this.generation,
    required this.methods,
  });

  static Future<_HostedRpcHarness> start(_HostedResult resultFor) async {
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
            'payload': {'replay_epoch': 'hosted-identity-matrix'},
          },
        }),
      );
      socket.listen((raw) {
        final rpc = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
        final method = rpc['method'] as String;
        if (method == 'gateway.ping') return;
        methods.add(method);
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
            : resultFor(method, params);
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], 'result': result}),
        );
      });
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'transport-only',
        label: 'Hosted identity matrix',
        host: '127.0.0.1',
        port: 8642,
        dashboardUrl: 'http://127.0.0.1:${server.port}',
        apiKey: String.fromCharCodes(const [113, 97]),
      ),
      dashboard: _TicketDashboardClient(),
    );
    final capabilities = await client.groupCapabilities();
    return _HostedRpcHarness._(
      server: server,
      client: client,
      generation: capabilities.generation,
      methods: methods,
    );
  }

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

Map<String, dynamic> _room(String roomId) => {
  'room_id': roomId,
  'name': 'Foreign',
  'members': [
    {
      'member_id': 'm1',
      'profile': 'research',
      'handle': 'research-home',
      'target': {'kind': 'local', 'profile': 'research'},
    },
    {
      'member_id': 'm2',
      'profile': 'research',
      'handle': 'research-lab',
      'target': {
        'kind': 'peer',
        'peer_id': 'peer-lab',
        'installation_id': 'install-lab',
        'profile': 'research',
        'capability_digest':
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      },
    },
  ],
  'authority_gateway_id': 'gateway-private',
  'authority_epoch': 2,
  'revision': 3,
  'created_at': 1.0,
  'updated_at': 2.0,
  'latest_seq': 4,
  'idempotent': false,
};

Map<String, dynamic> _event(String roomId, String eventId) => {
  'room_id': roomId,
  'seq': 1,
  'event_id': eventId,
  'kind': 'message.user',
  'actor': {'kind': 'user', 'id': 'desktop'},
  'authority_epoch': 1,
  'payload': {'text': 'hello', 'thread_id': 'thread-1'},
  'created_at': 1.0,
  'idempotent': false,
};
