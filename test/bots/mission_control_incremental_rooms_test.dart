import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/gateway_socket_meter.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';

import '../support/spec070_fixtures.dart';

/// Incremental hosted-groups gateway: records every since_seq it is asked.
final class _IncrementalGateway
    implements
        MissionHostedGroupsGateway,
        MissionHostedGroupsIncrementalGateway {
  final sinceCalls = <int>[];
  var fullLogReads = 0;

  @override
  Future<GroupsCapabilities> capabilities() async => spec070Capabilities();
  @override
  Future<List<HostedGroupRoom>> list({required int generation}) async => [
    spec070Room(),
  ];
  @override
  Future<HostedGroupRoom> state(
    String roomId, {
    required int generation,
  }) async => spec070Room();
  @override
  Future<HostedGroupLogPage> log(
    String roomId, {
    required int generation,
  }) async {
    fullLogReads++;
    throw StateError('full log must not be re-read');
  }

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String roomId, {required int generation}) async =>
      (room: spec070Room(), driverStatus: spec070DriverStatus());

  @override
  Future<HostedGroupLogPage> logSince(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    sinceCalls.add(sinceSeq);
    if (sinceSeq == 0) return spec070LogPage('groups_log_page1');
    if (sinceSeq == 4) return spec070LogPage('groups_log_page2');
    return spec070LogPage('groups_log_empty');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MissionControlRepository _repository(MissionHostedGroupsGateway gateway) =>
    MissionControlRepository(
      profilesLoader: () async => spec070Profiles(),
      sessionsLoader: () async => const [],
      boardLoader: () async => const KanbanBoard(columns: []),
      hostedGroupsGateway: gateway,
    );

void main() {
  test('snapshot carries driver status and reads logs incrementally', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final first = await repository.load();
    expect(first.hostedGroups.driverStatusFor('room-devs')?.working, isTrue);
    expect(first.hostedGroups.logs.single.events, hasLength(8));
    expect(gateway.sinceCalls, [0, 4]);

    gateway.sinceCalls.clear();
    await repository.load();
    expect(gateway.sinceCalls, [8], reason: 'only the delta after the cursor');
    expect(gateway.fullLogReads, 0);
    repository.close();
  });

  test('room refresh reuses the cursor and opens no socket (T209)', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    GatewaySocketMeter.instance.reset();
    gateway.sinceCalls.clear();
    for (var i = 0; i < 10; i++) {
      final read = await repository.readHostedGroup(room, generation: 1);
      expect(read.log?.events, hasLength(8));
      expect(read.driverStatus?.needsUser, isTrue);
    }
    expect(gateway.sinceCalls, List.filled(10, 8));
    expect(GatewaySocketMeter.instance.totalOpened, 0);
    repository.close();
  });
}
