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
  stateWithDriver(String roomId, {required int generation}) async {
    stateReads.add(roomId);
    return (
      room: stateRoom?.call() ?? spec070Room(),
      driverStatus: spec070DriverStatus(),
    );
  }

  HostedGroupRoom Function()? stateRoom;
  var emptyRoom = false;

  @override
  Future<HostedGroupLogPage> logSince(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    sinceCalls.add(sinceSeq);
    if (emptyRoom) {
      return HostedGroupLogPage.fromJson(
        {
          'events': const <Object?>[],
          'cursor': 0,
          'latest_seq': 0,
          'has_more': false,
          'authority': {'gateway_id': 'gw-home-1', 'epoch': 2},
        },
        expectedRoomId: roomId,
        sinceSeq: sinceSeq,
      );
    }
    if (sinceSeq == 0) return spec070LogPage('groups_log_page1');
    if (sinceSeq == 4) return spec070LogPage('groups_log_page2');
    if (sinceSeq > 8) {
      // Nothing new after a send this client already merged.
      return HostedGroupLogPage.fromJson(
        {
          'events': const <Object?>[],
          'cursor': sinceSeq,
          'latest_seq': sinceSeq,
          'has_more': false,
          'authority': {'gateway_id': 'gw-home-1', 'epoch': 2},
        },
        expectedRoomId: roomId,
        sinceSeq: sinceSeq,
      );
    }
    return spec070LogPage('groups_log_empty');
  }

  final sends = <String>[];
  final stateReads = <String>[];

  /// What `groups.send` returns: its verified log tail since `ack - 1`.
  HostedGroupLogPage Function()? sendTail;

  @override
  Future<HostedGroupLogPage> send(
    String roomId, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) async {
    sends.add(text);
    return sendTail?.call() ?? spec070LogPage('groups_log_empty');
  }

  final mutations = <String>[];

  @override
  Future<HostedGroupRoom> rename(
    String roomId, {
    required String name,
    required int generation,
  }) async {
    mutations.add('rename:$name');
    return spec070Room();
  }

  @override
  Future<HostedGroupRoom> stop(String roomId, {required int generation}) async {
    mutations.add('stop');
    return spec070Room();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The tail `groups.send` hands back: the acknowledged user event at
/// [ackSeq], read with `since_seq = ackSeq - 1` (as `sendGroupText` does).
HostedGroupLogPage _sendTail({
  int ackSeq = 9,
  int latestSeq = 9,
  String gatewayId = 'gw-home-1',
  int epoch = 2,
}) => HostedGroupLogPage.fromJson(
  {
    'events': [
      {
        'room_id': 'room-devs',
        'seq': ackSeq,
        'event_id': HostedGroupSendAttempt.forClientEvent(
          'evt-1',
        ).durableEventId,
        'kind': 'message.user',
        'actor': {'kind': 'user', 'id': 'desktop'},
        'authority_epoch': epoch,
        'payload': {'text': 'hola', 'thread_id': 'thread-1'},
        'created_at': 1790000400.0,
        'idempotent': false,
      },
    ],
    'cursor': ackSeq,
    'latest_seq': latestSeq,
    'has_more': latestSeq > ackSeq,
    'authority': {'gateway_id': gatewayId, 'epoch': epoch},
  },
  expectedRoomId: 'room-devs',
  sinceSeq: ackSeq - 1,
);

/// `groups.state`'s room with another latest sequence (null omits the field,
/// as older gateways do) or authority epoch.
HostedGroupRoom _roomWith({required int? latestSeq, int? epoch}) {
  final json = Map<String, dynamic>.from(
    spec070Result('groups_state')['room'] as Map,
  );
  if (latestSeq == null) {
    json.remove('latest_seq');
  } else {
    json['latest_seq'] = latestSeq;
  }
  if (epoch != null) json['authority_epoch'] = epoch;
  return HostedGroupRoom.fromJson(json);
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
    expect(gateway.sinceCalls, isEmpty, reason: 'state shows nothing new');
    expect(GatewaySocketMeter.instance.totalOpened, 0);
    repository.close();
  });

  // A long room (1000+ events) made every send re-read the whole log page
  // by page before the message showed: sending must reuse the cursor.
  test('sending reads only the delta, never the full log again', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    final sent = await repository.sendHostedGroupText(
      room,
      text: 'hola',
      attempt: HostedGroupSendAttempt.forClientEvent('evt-1'),
      generation: 1,
    );
    expect(gateway.sends, ['hola']);
    expect(gateway.fullLogReads, 0);
    // A tail without this attempt's event proves nothing: read the delta.
    expect(gateway.sinceCalls, [8], reason: 'only the delta after the cursor');
    expect(sent.log?.events, hasLength(8));
    expect(sent.driverStatus, isNotNull);
    repository.close();
  });

  // Each send used to wait for groups.state and another groups.log after
  // the acknowledgement; the verified tail already carries the new events.
  test(
    'send merges its verified tail into the cursor, no extra reads',
    () async {
      final gateway = _IncrementalGateway()..sendTail = _sendTail;
      final repository = _repository(gateway);
      final snapshot = await repository.load();
      final room = snapshot.hostedGroups.rooms.single;
      gateway.sinceCalls.clear();
      gateway.stateReads.clear();
      final sent = await repository.sendHostedGroupText(
        room,
        text: 'hola',
        attempt: HostedGroupSendAttempt.forClientEvent('evt-1'),
        generation: 1,
      );
      expect(gateway.stateReads, isEmpty, reason: 'the poller refreshes state');
      expect(gateway.sinceCalls, isEmpty);
      expect(sent.log?.events, hasLength(9));
      expect(
        sent.log?.events.last.eventId,
        HostedGroupSendAttempt.forClientEvent('evt-1').durableEventId,
      );
      expect(sent.log?.cursor, 9);
      expect(sent.room.roomId, room.roomId);
      expect(sent.room.revision, room.revision);

      // The next refresh continues after the merged tail.
      final next = await repository.readHostedGroup(room, generation: 1);
      expect(gateway.sinceCalls, [9]);
      expect(next.log?.events, hasLength(9));
      repository.close();
    },
  );

  test(
    'a tail that does not continue the cursor falls back to a read',
    () async {
      // Someone else wrote seq 9 first: the ack is seq 10, cursor is at 8.
      final gateway = _IncrementalGateway()
        ..sendTail = () => _sendTail(ackSeq: 10, latestSeq: 10);
      final repository = _repository(gateway);
      final snapshot = await repository.load();
      final room = snapshot.hostedGroups.rooms.single;
      gateway.sinceCalls.clear();
      gateway.stateReads.clear();
      await repository.sendHostedGroupText(
        room,
        text: 'hola',
        attempt: HostedGroupSendAttempt.forClientEvent('evt-1'),
        generation: 1,
      );
      expect(gateway.sinceCalls, [8], reason: 'gap: read the delta instead');
      expect(gateway.stateReads, ['room-devs']);
      repository.close();
    },
  );

  test('a tail without this attempt\'s event is not trusted', () async {
    // The tail continues the cursor but carries another attempt's event.
    final gateway = _IncrementalGateway()..sendTail = _sendTail;
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    gateway.stateReads.clear();
    await repository.sendHostedGroupText(
      room,
      text: 'hola',
      attempt: HostedGroupSendAttempt.forClientEvent('evt-other'),
      generation: 1,
    );
    expect(gateway.stateReads, ['room-devs']);
    expect(gateway.sinceCalls, [8]);
    repository.close();
  });

  test('a tail with more events after it reads the rest', () async {
    final gateway = _IncrementalGateway()
      ..sendTail = () => _sendTail(latestSeq: 12);
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    gateway.stateReads.clear();
    await repository.sendHostedGroupText(
      room,
      text: 'hola',
      attempt: HostedGroupSendAttempt.forClientEvent('evt-1'),
      generation: 1,
    );
    expect(gateway.sinceCalls, [8]);
    repository.close();
  });

  // Rename and stop re-read the whole log from seq 0, one page per 100
  // events; a long room waited seconds for a readback the cursor already
  // held.
  test('rename and stop read only the delta after the cursor', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();

    final renamed = await repository.renameHostedGroup(
      room,
      name: 'Devs',
      generation: 1,
    );
    expect(gateway.mutations, ['rename:Devs']);
    expect(gateway.fullLogReads, 0);
    expect(gateway.sinceCalls, [8], reason: 'only the delta after the cursor');
    expect(renamed.log?.events, hasLength(8));

    gateway.sinceCalls.clear();
    final stopped = await repository.stopHostedGroup(room, generation: 1);
    expect(gateway.mutations, ['rename:Devs', 'stop']);
    expect(gateway.fullLogReads, 0);
    expect(gateway.sinceCalls, [8]);
    expect(stopped.log?.events, hasLength(8));
    repository.close();
  });

  test('rename without an open cursor reads the log from the start', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final renamed = await repository.renameHostedGroup(
      spec070Room(),
      name: 'Devs',
      generation: 1,
    );
    expect(gateway.fullLogReads, 0);
    expect(gateway.sinceCalls, [0, 4], reason: 'complete, gap-free log');
    expect(renamed.log?.events, hasLength(8));
    repository.close();
  });

  // A quiet room paid groups.state AND groups.log on every 3 s tick. When
  // state proves the cursor already holds the room's latest sequence under
  // the same authority, the log read is skipped.
  test('a refresh skips the log when state shows nothing new', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    gateway.stateReads.clear();
    for (var i = 0; i < 10; i++) {
      final read = await repository.readHostedGroup(room, generation: 1);
      expect(read.log?.events, hasLength(8));
      expect(read.log?.latestSeq, 8);
      expect(read.driverStatus?.needsUser, isTrue);
    }
    expect(gateway.stateReads, List.filled(10, 'room-devs'));
    expect(gateway.sinceCalls, isEmpty, reason: 'latest_seq did not advance');
    repository.close();
  });

  test('a refresh reads the delta once latest_seq advances', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    gateway.stateRoom = () => _roomWith(latestSeq: 9);
    await repository.readHostedGroup(room, generation: 1);
    expect(gateway.sinceCalls, [8]);
    repository.close();
  });

  test('a refresh reads the log when state omits latest_seq', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    gateway.stateRoom = () => _roomWith(latestSeq: null);
    await repository.readHostedGroup(room, generation: 1);
    expect(gateway.sinceCalls, [8], reason: 'older gateways: no proof');
    repository.close();
  });

  // Without latest_seq the room reads 0, which an empty log also holds:
  // that is no proof, so the log is still read.
  test('an empty room without latest_seq still reads the log', () async {
    final gateway = _IncrementalGateway()
      ..emptyRoom = true
      ..stateRoom = () => _roomWith(latestSeq: null);
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    await repository.readHostedGroup(room, generation: 1);
    expect(gateway.sinceCalls, [0]);
    repository.close();
  });

  test('a refresh reads the log when the authority changed', () async {
    final gateway = _IncrementalGateway();
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    gateway.stateRoom = () => _roomWith(latestSeq: 8, epoch: 3);
    await expectLater(
      repository.readHostedGroup(room, generation: 1),
      throwsFormatException,
    );
    expect(gateway.sinceCalls, [8]);
    repository.close();
  });

  test('a tail under another authority is never merged', () async {
    final gateway = _IncrementalGateway()..sendTail = () => _sendTail(epoch: 3);
    final repository = _repository(gateway);
    final snapshot = await repository.load();
    final room = snapshot.hostedGroups.rooms.single;
    gateway.sinceCalls.clear();
    gateway.stateReads.clear();
    final sent = await repository.sendHostedGroupText(
      room,
      text: 'hola',
      attempt: HostedGroupSendAttempt.forClientEvent('evt-1'),
      generation: 1,
    );
    expect(gateway.stateReads, ['room-devs'], reason: 'verified the slow way');
    expect(gateway.sinceCalls, [8]);
    expect(
      sent.log?.events.map((e) => e.eventId),
      isNot(
        contains(HostedGroupSendAttempt.forClientEvent('evt-1').durableEventId),
      ),
    );
    repository.close();
  });
}
