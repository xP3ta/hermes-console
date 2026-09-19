import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/room_member_status.dart';

final statusNow = DateTime.fromMillisecondsSinceEpoch(1000000);
final statusRoom = HostedGroupRoom.fromJson({
  'room_id': 'room',
  'name': 'Team',
  'members': [
    for (final name in ['forja', 'chief-of-staff', 'default'])
      {
        'member_id': name,
        'handle': name,
        'profile': name,
        'target': {'kind': 'local', 'profile': name},
      },
  ],
  'authority_gateway_id': 'gateway',
  'authority_epoch': 1,
  'revision': 1,
  'created_at': 1,
  'updated_at': 2,
});

HostedGroupEvent statusEvent(
  int seq,
  String kind, {
  String member = 'forja',
  String discussion = 'event-1',
  String thread = 'thread',
  String? text,
  num at = 990,
  Map<String, Object?> payload = const {},
}) => HostedGroupEvent.fromJson({
  'room_id': 'room',
  'seq': seq,
  'event_id': 'event-$seq',
  'kind': kind,
  'actor': {'kind': kind == 'message.user' ? 'user' : 'member', 'id': member},
  'authority_epoch': 1,
  'created_at': at,
  'idempotent': false,
  'payload': kind == 'message.user'
      ? {'text': text ?? 'hello', 'thread_id': thread}
      : {
          'member_id': member,
          'discussion_event_id': discussion,
          'thread_id': thread,
          'task_id': 'task',
          if (kind == 'message.member') 'text': text ?? 'reply',
          ...payload,
        },
}, roomId: 'room');

MissionAgent statusAgent({
  AgentProfile? profile,
  KanbanTask? task,
  MissionAgentStatus status = MissionAgentStatus.idle,
  String evidence = 'fixture',
}) => MissionAgent(
  profile: profile ?? const AgentProfile(name: 'forja'),
  status: status,
  statusEvidence: evidence,
  currentTask: task,
  usage: const MissionUsage(),
);

void main() {
  final members = statusRoom.members;
  group('server-exact recipients', () {
    final cases = <String, List<String>>{
      '': ['forja', 'chief-of-staff', 'default'],
      'hello': ['forja', 'chief-of-staff', 'default'],
      '@everyone': ['forja', 'chief-of-staff', 'default'],
      '@ALL @forja': ['forja', 'chief-of-staff', 'default'],
      '@EVERYONE': ['forja', 'chief-of-staff', 'default'],
      '@forja': ['forja'],
      '@default @ForJa': ['forja', 'default'],
      '@unknown': ['forja', 'chief-of-staff', 'default'],
      '@unknown @chief-of-staff': ['chief-of-staff'],
      '@forja @FORJA @forja': ['forja'],
      'word@forja': ['forja'], // Server has NO left boundary.
      'mail@forja.example @default': ['default'],
      '@forja. @default': ['default'], // Dot/colon are token characters.
      '@forja:task @default': ['default'],
      '@_forja @default': ['default'],
      '@forja!': ['forja'],
      '@forjaİ @default': ['default'],
      '@chief-of-ſtaff': ['chief-of-staff'],
    };
    for (final entry in cases.entries) {
      test(
        entry.key,
        () => expect(
          resolveRoomRecipients(entry.key, members).map((m) => m.handle),
          entry.value,
        ),
      );
    }
  });
  BotLiveStatus derive(
    List<HostedGroupEvent> events, {
    MissionAgent? agent,
    HostedGroupEvent? message,
    DateTime? now,
  }) => BotLiveStatus.derive(
    member: members.first,
    events: events,
    agent: agent,
    addressedMessage: message,
    now: now ?? statusNow,
  );
  test(
    'no data is unknown; a known idle profile is idle, not gateway-online',
    () {
      expect(derive([]).presence, RoomPresence.unknown);
      expect(
        derive(
          [],
          agent: statusAgent(
            profile: const AgentProfile(name: 'forja', gatewayRunning: true),
          ),
        ).presence,
        RoomPresence.idle,
      );
    },
  );
  test('recent message / start / settled / old activity', () {
    expect(
      derive([statusEvent(2, 'message.member')]).presence,
      RoomPresence.active,
    );
    expect(
      derive([statusEvent(2, 'turn.started')]).presence,
      RoomPresence.working,
    );
    expect(
      derive([
        statusEvent(2, 'turn.started'),
        statusEvent(3, 'turn.settled'),
      ]).presence,
      RoomPresence.active,
    );
    expect(
      derive([statusEvent(2, 'message.member', at: 909)]).presence,
      RoomPresence.idle,
    );
    expect(
      derive([statusEvent(2, 'turn.started', at: 879)]).presence,
      RoomPresence.idle,
    );
    expect(
      derive([statusEvent(2, 'turn.started', member: 'default')]).presence,
      RoomPresence.unknown,
    );
  });
  test('only matching terminal clears a running task; stop clears it', () {
    final start = statusEvent(2, 'turn.started');
    expect(
      derive([
        start,
        statusEvent(3, 'turn.settled', payload: {'task_id': 'old'}),
      ]).presence,
      RoomPresence.working,
    );
    expect(
      derive([start, statusEvent(3, 'room.stop_requested')]).presence,
      RoomPresence.active,
    );
  });
  test('needs-you uses the exact user token and clears on user answer', () {
    final question = statusEvent(2, 'message.member', text: '@USER choose');
    expect(derive([question]).presence, RoomPresence.needsYou);
    expect(
      derive([question, statusEvent(3, 'message.user')]).presence,
      RoomPresence.active,
    );
    expect(
      derive([
        question,
        statusEvent(3, 'message.user', thread: 'other'),
      ]).presence,
      RoomPresence.needsYou,
    );
    expect(
      derive([statusEvent(2, 'message.member', text: '@user-other')]).presence,
      RoomPresence.active,
    );
    expect(
      derive(
        [],
        agent: statusAgent(status: MissionAgentStatus.approvalRequired),
      ).presence,
      RoomPresence.needsYou,
    );
  });
  test(
    'existing projector supplies worker liveness, recent session supplies active',
    () {
      final profile = AgentProfile(
        name: 'forja',
        workerSession: const AgentProfileWorkerSession(
          id: 'worker',
          source: 'tool',
          title: 'Editing a file',
          lastActive: 990,
        ),
      );
      final agent = MissionProjector.build(
        snapshot: MissionBackendSnapshot(
          profiles: [profile],
          loadedAt: statusNow,
        ),
        now: statusNow,
      ).agents.single;
      expect(derive([], agent: agent).presence, RoomPresence.working);
      expect(derive([], agent: agent).workingOn, 'Editing a file');
      expect(
        derive(
          [],
          agent: agent,
          now: statusNow.add(const Duration(seconds: 151)),
        ).presence,
        RoomPresence.idle,
      );
      expect(
        derive(
          [],
          agent: statusAgent(
            profile: const AgentProfile(
              name: 'forja',
              lastSession: AgentProfileSessionSummary(id: 's', lastActive: 990),
            ),
          ),
        ).presence,
        RoomPresence.active,
      );
    },
  );
  test('what priority: room, live worker/session, running Kanban, nothing', () {
    const task = KanbanTask(
      id: 't',
      title: 'Review PR',
      body: '',
      status: 'running',
    );
    final agent = statusAgent(
      status: MissionAgentStatus.working,
      task: task,
      profile: const AgentProfile(
        name: 'forja',
        workerSession: AgentProfileWorkerSession(
          id: 's',
          source: 'tool',
          title: 'Edit source',
          lastActive: 990,
        ),
      ),
    );
    expect(
      derive([
        statusEvent(2, 'turn.started', payload: {'description': 'Room task'}),
      ], agent: agent).workingOn,
      'Room task',
    );
    expect(derive([], agent: agent).workingOn, 'Edit source');
    expect(
      derive(
        [],
        agent: statusAgent(
          status: MissionAgentStatus.working,
          task: task,
          profile: const AgentProfile(
            name: 'forja',
            preferredSession: AgentProfileSessionSummary(
              id: 's',
              title: 'Current session',
              lastActive: 990,
            ),
          ),
        ),
      ).workingOn,
      'Current session',
    );
    expect(
      derive(
        [],
        agent: statusAgent(
          status: MissionAgentStatus.working,
          task: task,
          profile: const AgentProfile(
            name: 'forja',
            preferredSession: AgentProfileSessionSummary(
              id: 's',
              title: 'Old session',
              lastActive: 1,
            ),
          ),
        ),
      ).workingOn,
      'Review PR',
    );
    expect(
      derive(
        [],
        agent: statusAgent(status: MissionAgentStatus.working),
      ).workingOn,
      isNull,
    );
  });
  test('pending, reply, pass, failure, timeout, late reply', () {
    final send = statusEvent(1, 'message.user');
    expect(derive([send], message: send).response, RoomResponse.pending);
    expect(
      derive([send, statusEvent(2, 'message.member')], message: send).response,
      RoomResponse.responded,
    );
    expect(
      derive([
        send,
        statusEvent(2, 'turn.settled', payload: {'passed': true}),
      ], message: send).response,
      RoomResponse.passed,
    );
    expect(
      derive([send, statusEvent(2, 'turn.failed')], message: send).response,
      RoomResponse.noResponse,
    );
    expect(
      derive(
        [send],
        message: send,
        now: statusNow.add(const Duration(seconds: 120)),
      ).response,
      RoomResponse.noResponse,
    );
    expect(
      derive([
        send,
        statusEvent(2, 'turn.failed'),
        statusEvent(3, 'message.member'),
      ], message: send).response,
      RoomResponse.responded,
    );
  });
  test(
    'older run, other thread and other member cannot acknowledge a send',
    () {
      final send = statusEvent(5, 'message.user');
      expect(
        derive([
          send,
          statusEvent(6, 'message.member'),
        ], message: send).response,
        RoomResponse.pending,
      );
      expect(
        derive([
          send,
          statusEvent(
            6,
            'message.member',
            discussion: 'event-5',
            member: 'default',
          ),
        ], message: send).response,
        RoomResponse.pending,
      );
    },
  );
  test('Bots aggregate only local seats and prefer real room detail', () {
    final start = statusEvent(
      2,
      'turn.started',
      payload: {'description': 'Room work'},
    );
    final log = HostedGroupLogPage.fromJson(
      {
        'events': [
          {
            'room_id': 'room',
            'seq': 1,
            'event_id': 'event-1',
            'kind': 'message.user',
            'actor': {'kind': 'user', 'id': 'user'},
            'authority_epoch': 1,
            'created_at': 990,
            'idempotent': false,
            'payload': {'text': 'go', 'thread_id': 'thread'},
          },
          {
            'room_id': 'room',
            'seq': 2,
            'event_id': 'event-2',
            'kind': start.kind,
            'actor': {'kind': 'gateway', 'id': 'gateway'},
            'authority_epoch': 1,
            'created_at': 990,
            'idempotent': false,
            'payload': {
              'member_id': 'forja',
              'discussion_event_id': 'event-1',
              'thread_id': 'thread',
              'task_id': 'task',
              'description': 'Room work',
            },
          },
        ],
        'cursor': 2,
        'latest_seq': 2,
        'has_more': false,
        'authority': {'gateway_id': 'gateway', 'epoch': 1},
      },
      expectedRoomId: 'room',
      sinceSeq: 0,
    );
    final status = BotLiveStatus.forAgent(
      agent: statusAgent(),
      now: statusNow,
      rooms: HostedGroupsSnapshot(rooms: [statusRoom], logs: [log]),
    );
    expect(status.presence, RoomPresence.working);
    expect(status.workingOn, 'Room work');
    final peerRoom = HostedGroupRoom.fromJson({
      'room_id': 'room',
      'name': 'Peer',
      'members': [
        {
          'member_id': 'forja',
          'handle': 'forja',
          'profile': 'forja',
          'target': {
            'kind': 'peer',
            'peer_id': 'peer',
            'installation_id': 'other',
            'profile': 'forja',
            'capability_digest': 'a' * 64,
          },
        },
      ],
      'authority_gateway_id': 'gateway',
      'authority_epoch': 1,
      'revision': 1,
      'created_at': 1,
      'updated_at': 1,
    });
    expect(
      BotLiveStatus.forAgent(
        agent: statusAgent(),
        now: statusNow,
        rooms: HostedGroupsSnapshot(rooms: [peerRoom], logs: [log]),
      ).presence,
      RoomPresence.idle,
    );
  });

  test('activity is chronological, current run only, bounded to last 50', () {
    final events = [
      statusEvent(1, 'message.user'),
      statusEvent(2, 'message.member'),
      statusEvent(3, 'message.user'),
      statusEvent(4, 'message.member'),
      for (var i = 5; i < 65; i++)
        statusEvent(i, 'turn.settled', discussion: 'event-3'),
    ];
    final activity = currentRoomActivity(events.reversed.toList());
    expect(activity, hasLength(50));
    expect(activity.first.sequence, 15);
    expect(activity.last.sequence, 64);
    expect(currentRoomActivity([statusEvent(1, 'message.member')]), isEmpty);
  });
}
