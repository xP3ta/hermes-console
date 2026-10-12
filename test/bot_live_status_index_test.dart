import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/room_member_status.dart';

// QA 9490 profile build: Mission Control's Bots tab spent ~16 ms per build in
// BotLiveStatus.forAgent, which merged, copied and sorted every room log once
// per agent × seat (twice per seat). These tests pin that the indexed path
// returns exactly what the original per-call merge returned, and that asking
// again for the same snapshot no longer re-reads the logs.

/// The original implementation, kept verbatim as the reference.
BotLiveStatus referenceForAgent({
  required MissionAgent agent,
  required DateTime now,
  HostedGroupsSnapshot rooms = HostedGroupsSnapshot.empty,
}) {
  var result = BotLiveStatus.derive(agent: agent, now: now);
  int priority(RoomPresence p) => switch (p) {
    RoomPresence.needsYou => 4,
    RoomPresence.working => 3,
    RoomPresence.active => 2,
    RoomPresence.idle => 1,
    RoomPresence.unknown => 0,
  };
  for (final room in rooms.rooms.where((r) => !r.disbanded)) {
    for (final member in room.members.where(
      (m) =>
          m.owner.connectionId == room.authorityGatewayId &&
          m.owner.profile == agent.profile.name,
    )) {
      final events = rooms.logs
          .where(
            (log) =>
                log.authority.gatewayId == room.authorityGatewayId &&
                log.authority.epoch == room.authorityEpoch,
          )
          .expand((log) => log.events)
          .where((e) => e.roomId == room.roomId)
          .toList();
      final driver = rooms.driverStatusFor(room.roomId);
      final candidate = BotLiveStatus.derive(
        agent: agent,
        member: member,
        events: events,
        now: now,
        driverStatus: driver,
      );
      final roomOnly = BotLiveStatus.derive(
        member: member,
        events: events,
        now: now,
        driverStatus: driver,
      );
      if (priority(roomOnly.presence) >= priority(result.presence)) {
        result = candidate;
      }
    }
  }
  return result;
}

const _profiles = ['forja', 'scout', 'builder', 'chief', 'default'];
const _kinds = [
  'message.user',
  'message.member',
  'turn.started',
  'turn.settled',
  'turn.failed',
  'turn.cancelled',
  'room.activity',
  'room.stop_requested',
];

final _now = DateTime.fromMillisecondsSinceEpoch(1000000);

HostedGroupsSnapshot fuzzSnapshot(
  Random rng, {
  int rooms = 6,
  int events = 40,
}) {
  final roomList = <HostedGroupRoom>[];
  final logs = <HostedGroupLogPage>[];
  final drivers = <String, RoomDriverStatus>{};
  for (var r = 0; r < rooms; r++) {
    final gateway = rng.nextInt(4) == 0 ? 'gateway-b' : 'gateway';
    final members = [
      for (final p in _profiles)
        if (rng.nextInt(3) > 0)
          rng.nextInt(6) == 0
              ? {
                  'member_id': '$p-$r-peer',
                  'handle': '$p-peer',
                  'profile': p,
                  'target': {
                    'kind': 'peer',
                    'peer_id': 'peer',
                    'installation_id': 'other',
                    'profile': p,
                    'capability_digest': 'a' * 64,
                  },
                }
              : {
                  'member_id': '$p-$r',
                  'handle': p,
                  'profile': p,
                  'target': {'kind': 'local', 'profile': p},
                },
    ];
    if (members.isEmpty) continue;
    roomList.add(
      HostedGroupRoom.fromJson({
        'room_id': 'room-$r',
        'name': 'Room $r',
        'members': members,
        'authority_gateway_id': gateway,
        'authority_epoch': 2,
        'revision': 1,
        'created_at': 1,
        'updated_at': 2,
        'latest_seq': events,
        if (rng.nextInt(8) == 0) 'disbanded_at': 3,
      }),
    );
    // Current authority, plus sometimes a stale epoch or a foreign gateway.
    for (final (gw, epoch) in [
      (gateway, 2),
      if (rng.nextBool()) (gateway, 1),
      if (rng.nextBool()) ('gateway-c', 2),
    ]) {
      final rows = <Map<String, Object?>>[];
      for (var seq = 1; seq <= events; seq++) {
        final kind = _kinds[rng.nextInt(_kinds.length)];
        final who = members[rng.nextInt(members.length)]['member_id'];
        final thread = 'thread-${rng.nextInt(3)}';
        final user = kind == 'message.user';
        rows.add({
          'room_id': 'room-$r',
          'seq': seq,
          'event_id': 'e-$r-$gw-$epoch-$seq',
          'kind': kind,
          'actor': user
              ? {'kind': 'user', 'id': 'user'}
              : rng.nextInt(5) == 0
              ? {
                  'kind': 'member',
                  'id': 'someone',
                  'connection_id': gateway,
                  'profile': _profiles[rng.nextInt(_profiles.length)],
                }
              : {'kind': 'member', 'id': who},
          'authority_epoch': epoch,
          'created_at': 1000 - rng.nextInt(400),
          'idempotent': false,
          'payload': user
              ? {'text': 'go $seq', 'thread_id': thread}
              : {
                  if (rng.nextInt(4) > 0) 'member_id': who,
                  'discussion_event_id': 'e-$r-$gw-$epoch-${rng.nextInt(seq)}',
                  'thread_id': thread,
                  if (rng.nextInt(3) > 0) 'task_id': 'task-${rng.nextInt(4)}',
                  'description': 'work $seq',
                  if (kind == 'message.member')
                    'text': rng.nextInt(4) == 0 ? 'ask @user' : 'reply $seq',
                },
        });
      }
      logs.add(
        HostedGroupLogPage.fromJson(
          {
            'events': rows,
            'cursor': events,
            'latest_seq': events,
            'has_more': false,
            'authority': {'gateway_id': gw, 'epoch': epoch},
          },
          expectedRoomId: 'room-$r',
          sinceSeq: 0,
        ),
      );
    }
    if (rng.nextBool()) {
      drivers['room-$r'] = RoomDriverStatus(
        running: rng.nextBool(),
        working: rng.nextBool(),
        blocked: false,
      );
    }
  }
  logs.shuffle(rng);
  return HostedGroupsSnapshot(
    rooms: roomList,
    logs: logs,
    driverStatuses: drivers,
  );
}

List<MissionAgent> fuzzAgents(Random rng) => [
  for (final p in [..._profiles, 'nobody'])
    MissionAgent(
      profile: AgentProfile(name: p),
      status: MissionAgentStatus
          .values[rng.nextInt(MissionAgentStatus.values.length)],
      statusEvidence: 'fixture',
      usage: const MissionUsage(),
    ),
];

String describe(BotLiveStatus s) =>
    '${s.presence}|${s.workingOn}|${s.response}';

void main() {
  test('indexed forAgent equals the original per-call merge', () {
    final rng = Random(1215);
    var compared = 0;
    final presences = <RoomPresence>{};
    for (var round = 0; round < 60; round++) {
      final snapshot = fuzzSnapshot(rng);
      final agents = fuzzAgents(rng);
      for (final offset in [0, 50, 100, 130, 200, 500]) {
        final now = _now.add(Duration(seconds: offset));
        // Twice per snapshot: the second pass reads the cached index.
        for (var pass = 0; pass < 2; pass++) {
          for (final agent in agents) {
            final expected = referenceForAgent(
              agent: agent,
              now: now,
              rooms: snapshot,
            );
            final actual = BotLiveStatus.forAgent(
              agent: agent,
              now: now,
              rooms: snapshot,
            );
            expect(
              describe(actual),
              describe(expected),
              reason: 'round $round agent ${agent.profile.name} +${offset}s',
            );
            presences.add(expected.presence);
            compared++;
          }
        }
      }
    }
    expect(compared, greaterThan(4000));
    // The corpus reaches every presence the room join decides between.
    expect(
      presences,
      containsAll([
        RoomPresence.needsYou,
        RoomPresence.working,
        RoomPresence.idle,
      ]),
    );
  });

  test(
    'a new snapshot with the same rooms is read again, not served stale',
    () {
      final rng = Random(7);
      final agents = fuzzAgents(rng);
      var differed = 0;
      for (var i = 0; i < 20; i++) {
        final a = fuzzSnapshot(Random(100 + i));
        final b = fuzzSnapshot(Random(200 + i));
        // Same room objects, only the logs (the revision) change.
        final next = HostedGroupsSnapshot(
          rooms: a.rooms,
          logs: b.logs,
          driverStatuses: a.driverStatuses,
        );
        for (final agent in agents) {
          final first = BotLiveStatus.forAgent(
            agent: agent,
            now: _now,
            rooms: a,
          );
          final second = BotLiveStatus.forAgent(
            agent: agent,
            now: _now,
            rooms: next,
          );
          expect(
            describe(second),
            describe(referenceForAgent(agent: agent, now: _now, rooms: next)),
          );
          if (describe(first) != describe(second)) differed++;
        }
      }
      expect(differed, greaterThan(0), reason: 'fixture must change statuses');
    },
  );

  test('Bots roster rebuilds no longer re-read every room log', () {
    // 10 rooms × 500 events, every bot seated in most rooms: the shape that
    // cost ~16 ms per Bots build on the Pixel.
    final snapshot = fuzzSnapshot(Random(42), rooms: 10, events: 500);
    final agents = fuzzAgents(Random(43));
    int timeBuilds(
      BotLiveStatus Function(MissionAgent, HostedGroupsSnapshot) status,
    ) {
      final watch = Stopwatch()..start();
      for (var build = 0; build < 20; build++) {
        for (final agent in agents) {
          status(agent, snapshot);
        }
      }
      return watch.elapsedMicroseconds;
    }

    BotLiveStatus current(MissionAgent a, HostedGroupsSnapshot s) =>
        BotLiveStatus.forAgent(agent: a, now: _now, rooms: s);
    BotLiveStatus reference(MissionAgent a, HostedGroupsSnapshot s) =>
        referenceForAgent(agent: a, now: _now, rooms: s);
    // Warm up both paths (JIT and the per-snapshot index).
    timeBuilds(current);
    timeBuilds(reference);
    final fast = timeBuilds(current);
    final slow = timeBuilds(reference);
    // Relative bound: wall-clock limits are flaky under suite load.
    expect(
      fast * 10,
      lessThan(slow),
      reason: 'indexed ${fast}us vs original ${slow}us for 20 builds',
    );
  });
}
