import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/mission_room.dart';
import 'package:hermes_android/core/models/mission_room_projection.dart';
import 'package:hermes_android/core/models/session.dart';

void main() {
  group('MissionRoomWorkProjector', () {
    test('resolves only exact board and preserves unavailable links', () {
      final currentCollision = _task(
        'same-id',
        status: 'running',
        assignee: 'shared-worker',
      );
      final linked = _task('linked', status: 'ready');
      final room = _room(
        'room-a',
        links: [
          _link('board-b', 'same-id'),
          _link('board-a', 'linked'),
          _link('board-a', 'not-loaded'),
        ],
      );

      final result = MissionRoomWorkProjector.build(
        rooms: [room],
        snapshot: _snapshot(
          boardId: 'board-a',
          tasks: [currentCollision, linked],
        ),
        mission: MissionProjection(tasks: [currentCollision, linked]),
      );
      final projection = result.rooms.single;

      expect(projection.linkedTasks, hasLength(3));
      expect(projection.linkedTasks[0].link.boardId, 'board-b');
      expect(projection.linkedTasks[0].task, isNull);
      expect(projection.linkedTasks[1].task, same(linked));
      expect(projection.linkedTasks[2].link.taskId, 'not-loaded');
      expect(projection.linkedTasks[2].task, isNull);
      expect(
        result.unscoped.tasks.map((entry) => entry.link),
        contains(_link('board-a', 'same-id')),
      );
    });

    test('never attributes tasks from assignee or Room membership', () {
      final room = _room(
        'room-a',
        links: const [],
        members: const ['manager', 'shared-worker'],
      );
      final sameMember = _task(
        'member-task',
        status: 'blocked',
        assignee: 'shared-worker',
      );

      final result = MissionRoomWorkProjector.build(
        rooms: [room],
        snapshot: _snapshot(boardId: 'board-a', tasks: [sameMember]),
        mission: MissionProjection(
          tasks: [sameMember],
          activity: [_activity('member-task', profile: 'shared-worker')],
        ),
      );

      expect(result.rooms.single.linkedTasks, isEmpty);
      expect(result.rooms.single.activity, isEmpty);
      expect(result.rooms.single.attentionCount, 0);
      expect(result.unscoped.tasks.single.task, same(sameMember));
    });

    test('projects one explicitly linked task into every linked Room', () {
      final task = _task('shared', status: 'running');
      final rooms = [
        _room('room-a', links: [_link('board-a', 'shared')]),
        _room('room-b', links: [_link('board-a', 'shared')]),
      ];

      final result = MissionRoomWorkProjector.build(
        rooms: rooms,
        snapshot: _snapshot(boardId: 'board-a', tasks: [task]),
        mission: MissionProjection(tasks: [task]),
      );

      expect(result.rooms, hasLength(2));
      expect(result.rooms[0].linkedTasks.single.task, same(task));
      expect(result.rooms[1].linkedTasks.single.task, same(task));
      expect(result.unscoped.tasks, isEmpty);
    });

    test(
      'filters activity by linked task and ignores local manager lineage',
      () {
        final managerChild = _session(
          'manager-child',
          lineageRootId: 'manager-root',
          profile: 'manager',
          updatedAt: 20,
        );
        final sameProfileButUnrelated = _session(
          'other-session',
          profile: 'manager',
          updatedAt: 30,
        );
        final room = _room(
          'room-a',
          managerSessionId: 'manager-root',
          links: [_link('board-a', 'linked')],
        );
        final activities = [
          _activity('linked'),
          _activity(
            'manager-child',
            kind: MissionActivityKind.sessionUpdated,
            profile: 'manager',
          ),
          _activity(
            'manager-root',
            kind: MissionActivityKind.sessionUpdated,
            profile: 'manager',
          ),
          _activity('unlinked', profile: 'manager'),
          _activity(
            'other-session',
            kind: MissionActivityKind.sessionUpdated,
            profile: 'manager',
          ),
        ];

        final result = MissionRoomWorkProjector.build(
          rooms: [room],
          snapshot: _snapshot(
            boardId: 'board-a',
            tasks: [_task('linked'), _task('unlinked')],
            sessions: [managerChild, sameProfileButUnrelated],
          ),
          mission: MissionProjection(
            tasks: [_task('linked'), _task('unlinked')],
            activity: activities,
          ),
        );
        final projection = result.rooms.single;

        expect(projection.activity.map((event) => event.sourceId), ['linked']);
        expect(projection.workerSession, isNull);
      },
    );

    test('keeps unattributable approvals and tasks in the global tray', () {
      final room = _room(
        'room-a',
        managerSessionId: 'manager-root',
        links: [_link('board-a', 'linked')],
      );
      final manager = _session('manager-child', lineageRootId: 'manager-root');
      const scopedApproval = MissionApproval(
        profileName: 'manager',
        sessionId: 'manager-child',
        sessionTitle: 'Room manager',
        requestId: 'approval-room',
        description: 'Room action',
      );
      const globalApproval = MissionApproval(
        profileName: 'manager',
        sessionId: 'same-profile-other-session',
        sessionTitle: 'Other chat',
        requestId: 'approval-global',
        description: 'Global action',
      );

      final result = MissionRoomWorkProjector.build(
        rooms: [room],
        snapshot: _snapshot(
          boardId: 'board-a',
          tasks: [_task('linked'), _task('unlinked')],
          sessions: [manager],
        ),
        mission: MissionProjection(
          tasks: [_task('linked'), _task('unlinked')],
          approvals: [scopedApproval, globalApproval],
        ),
      );

      expect(result.rooms.single.approvals, isEmpty);
      expect(result.unscoped.approvals, [scopedApproval, globalApproval]);
      expect(result.unscoped.tasks.single.link.taskId, 'unlinked');
      expect(result.unscoped.tasks.single.link.boardId, 'board-a');
    });

    test('orders active tasks and derives attention and spine state', () {
      final room = _room(
        'room-a',
        managerSessionId: 'manager-session',
        links: [
          _link('board-a', 'ready'),
          _link('board-a', 'review'),
          _link('board-a', 'running'),
          _link('board-a', 'blocked'),
          _link('board-a', 'done'),
        ],
      );
      const approval = MissionApproval(
        profileName: 'manager',
        sessionId: 'manager-session',
        sessionTitle: 'Manager',
        description: 'Approve',
      );

      final result = MissionRoomWorkProjector.build(
        rooms: [room],
        snapshot: _snapshot(
          boardId: 'board-a',
          tasks: [
            _task('ready', status: 'ready'),
            _task('review', status: 'review'),
            _task('running', status: 'running'),
            _task('blocked', status: 'blocked'),
            _task('done', status: 'done'),
          ],
          sessions: [_session('manager-session')],
        ),
        mission: MissionProjection(
          tasks: [
            _task('ready', status: 'ready'),
            _task('review', status: 'review'),
            _task('running', status: 'running'),
            _task('blocked', status: 'blocked'),
            _task('done', status: 'done'),
          ],
          approvals: const [approval],
        ),
      );
      final projection = result.rooms.single;

      expect(projection.activeTasks.map((entry) => entry.link.taskId), [
        'blocked',
        'running',
        'review',
        'ready',
      ]);
      expect(projection.primaryTask!.link.taskId, 'blocked');
      expect(projection.spineState, MissionRoomSpineState.blocked);
      expect(projection.attentionCount, 1);
    });

    test('does not scope a provisional manager session', () {
      final room = _room(
        'room-a',
        managerSessionId: 'mob-draft',
        links: const [],
      );
      const approval = MissionApproval(
        profileName: 'manager',
        sessionId: 'mob-draft',
        sessionTitle: 'Draft',
        description: 'Approve',
      );

      final result = MissionRoomWorkProjector.build(
        rooms: [room],
        snapshot: _snapshot(
          boardId: 'board-a',
          sessions: [_session('mob-draft')],
        ),
        mission: const MissionProjection(approvals: [approval]),
      );

      expect(result.rooms.single.workerSession, isNull);
      expect(result.rooms.single.approvals, isEmpty);
      expect(result.unscoped.approvals, [approval]);
    });

    test('fails closed when the durable session belongs to another bot', () {
      final room = _room(
        'room-a',
        managerSessionId: 'manager-root',
        links: const [],
      );
      const approval = MissionApproval(
        profileName: 'manager',
        sessionId: 'manager-root',
        sessionTitle: 'Reassigned session',
        description: 'Approve',
      );

      final result = MissionRoomWorkProjector.build(
        rooms: [room],
        snapshot: _snapshot(
          boardId: 'board-a',
          sessions: [_session('manager-root', profile: 'another-bot')],
        ),
        mission: const MissionProjection(approvals: [approval]),
      );

      expect(result.rooms.single.workerSession, isNull);
      expect(result.rooms.single.approvals, isEmpty);
      expect(result.unscoped.approvals, [approval]);
    });

    test(
      'local manager metadata never scopes shared activity or approvals',
      () {
        final room = _room(
          'room-a',
          managerSessionId: 'manager-root',
          links: const [],
        );
        const approval = MissionApproval(
          profileName: 'manager',
          sessionId: 'manager-root',
          sessionTitle: 'Local manager session',
          requestId: 'request-1',
          description: 'private payload',
        );
        final result = MissionRoomWorkProjector.build(
          rooms: [room],
          snapshot: _snapshot(
            boardId: 'board-a',
            sessions: [_session('manager-root')],
          ),
          mission: MissionProjection(
            approvals: const [approval],
            activity: [
              _activity(
                'manager-root',
                kind: MissionActivityKind.sessionUpdated,
                profile: 'manager',
              ),
            ],
          ),
        );

        expect(result.rooms.single.workerSession, isNull);
        expect(result.rooms.single.approvals, isEmpty);
        expect(result.rooms.single.activity, isEmpty);
        expect(result.unscoped.approvals, [approval]);
      },
    );

    test('keeps tasks outside the selected scope out of global work', () {
      final local = _task('local', status: 'ready');
      final foreign = _task('foreign', status: 'blocked');

      final result = MissionRoomWorkProjector.build(
        rooms: [_room('room-a', links: const [])],
        snapshot: _snapshot(boardId: 'board-a', tasks: [local, foreign]),
        mission: MissionProjection(tasks: [local]),
      );

      expect(result.unscoped.tasks.map((entry) => entry.link.taskId), [
        'local',
      ]);
    });

    test('does not relabel work linked to a hidden room as unscoped', () {
      final task = _task('shared', status: 'running');
      final visible = _room('visible', links: const []);
      final hidden = _room('hidden', links: [_link('board-a', 'shared')]);

      final result = MissionRoomWorkProjector.build(
        rooms: [visible],
        ownershipRooms: [visible, hidden],
        snapshot: _snapshot(boardId: 'board-a', tasks: [task]),
        mission: MissionProjection(tasks: [task]),
      );

      expect(result.rooms.single.linkedTasks, isEmpty);
      expect(result.unscoped.tasks, isEmpty);
    });
  });
}

MissionRoom _room(
  String id, {
  required List<MissionRoomTaskLink> links,
  String managerSessionId = 'manager-session',
  List<String> members = const ['manager'],
}) => MissionRoom(
  id: id,
  connectionId: 'connection',
  name: id,
  managerProfile: 'manager',
  memberProfiles: members,
  managerSessionId: managerSessionId,
  linkedTasks: links,
  createdAtMs: 1,
  updatedAtMs: 1,
);

MissionRoomTaskLink _link(String boardId, String taskId) =>
    MissionRoomTaskLink(boardId: boardId, taskId: taskId);

KanbanTask _task(String id, {String status = 'todo', String? assignee}) =>
    KanbanTask(
      id: id,
      title: id,
      body: '',
      status: status,
      assignee: assignee,
      createdAt: 1,
    );

MissionBackendSnapshot _snapshot({
  required String boardId,
  List<KanbanTask> tasks = const [],
  List<Session> sessions = const [],
}) => MissionBackendSnapshot(
  sessions: sessions,
  board: KanbanBoard(
    boardId: boardId,
    columns: [KanbanColumn(name: 'all', tasks: tasks)],
  ),
  loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
);

MissionActivity _activity(
  String sourceId, {
  MissionActivityKind kind = MissionActivityKind.taskStarted,
  String? profile,
}) => MissionActivity(
  stableId: '${kind.name}:$sourceId',
  profileName: profile,
  kind: kind,
  timestamp: DateTime.fromMillisecondsSinceEpoch(1),
  title: sourceId,
  sourceId: sourceId,
);

Session _session(
  String id, {
  String? lineageRootId,
  String? profile,
  double updatedAt = 1,
}) => Session(
  id: id,
  title: id,
  model: 'model',
  source: 'desktop',
  messageCount: 1,
  isActive: true,
  preview: '',
  startedAt: 1,
  updatedAt: updatedAt,
  lineageRootId: lineageRootId,
  profile: profile ?? 'manager',
);
