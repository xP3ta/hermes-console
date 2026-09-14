import 'kanban.dart';
import 'mission_control.dart';
import 'mission_room.dart';
import 'session.dart';

enum MissionRoomSpineState { neutral, active, warning, blocked }

/// Exact, board-qualified resolution of a Room task link.
///
/// A null [task] is meaningful: the link remains part of the Room even when
/// its board is not the currently loaded board or its task is absent from the
/// snapshot. Consumers must not fall back to a same-id task from another
/// board.
final class MissionRoomLinkedTask {
  final MissionRoomTaskLink link;
  final KanbanTask? task;

  const MissionRoomLinkedTask({required this.link, this.task});

  bool get isAvailable => task != null;
}

/// Ephemeral, read-only work view for one Room.
final class MissionRoomWorkProjection {
  final String roomId;
  final List<MissionRoomLinkedTask> linkedTasks;
  final List<MissionRoomLinkedTask> activeTasks;
  final MissionRoomLinkedTask? primaryTask;
  final List<MissionActivity> activity;
  final List<MissionApproval> approvals;
  final int attentionCount;
  final MissionRoomSpineState spineState;
  final Session? workerSession;

  const MissionRoomWorkProjection._({
    required this.roomId,
    required this.linkedTasks,
    required this.activeTasks,
    required this.primaryTask,
    required this.activity,
    required this.approvals,
    required this.attentionCount,
    required this.spineState,
    required this.workerSession,
  });
}

/// Work that the current evidence cannot assign to any Room.
///
/// This intentionally has no activity feed or usage aggregate. Every task is
/// kept with its exact board locator so navigation cannot collide by task id.
final class UnscopedMissionWorkProjection {
  final List<MissionRoomLinkedTask> tasks;
  final List<MissionApproval> approvals;

  const UnscopedMissionWorkProjection._({
    required this.tasks,
    required this.approvals,
  });
}

final class MissionRoomWorkSet {
  final List<MissionRoomWorkProjection> rooms;
  final UnscopedMissionWorkProjection unscoped;

  const MissionRoomWorkSet._({required this.rooms, required this.unscoped});

  MissionRoomWorkProjection? forRoom(String roomId) {
    for (final room in rooms) {
      if (room.roomId == roomId) return room;
    }
    return null;
  }
}

/// Pure projection over the already-loaded Mission snapshot.
///
/// It performs no I/O, persistence, subscription, polling, or inference from
/// Room members/task assignees. Room ownership comes only from an explicit
/// [MissionRoomTaskLink]. Local manager fields are presentation preferences,
/// never shared GroupChat authority.
abstract final class MissionRoomWorkProjector {
  static const _activeStatuses = <String>{
    'blocked',
    'running',
    'review',
    'ready',
  };

  static MissionRoomWorkSet build({
    required Iterable<MissionRoom> rooms,
    required MissionBackendSnapshot snapshot,
    required MissionProjection mission,
    Iterable<MissionRoom>? ownershipRooms,
  }) {
    final roomList = rooms.toList(growable: false);
    final ownershipRoomList = (ownershipRooms ?? roomList).toList(
      growable: false,
    );
    final currentBoardId = snapshot.currentBoardId;
    final currentTasksById = <String, KanbanTask>{};
    for (final task in mission.tasks) {
      currentTasksById.putIfAbsent(task.id, () => task);
    }

    final linkedOnCurrentBoard = <String>{
      for (final room in ownershipRoomList)
        for (final link in room.linkedTasks)
          if (link.boardId == currentBoardId) link.taskId,
    };

    final projections = <MissionRoomWorkProjection>[];
    for (final room in roomList) {
      final linked = <MissionRoomLinkedTask>[
        for (final link in room.linkedTasks)
          MissionRoomLinkedTask(
            link: link,
            task: link.boardId == currentBoardId
                ? currentTasksById[link.taskId]
                : null,
          ),
      ];
      final originalOrder = <MissionRoomTaskLink, int>{
        for (var index = 0; index < linked.length; index++)
          linked[index].link: index,
      };
      final active =
          linked
              .where(
                (entry) =>
                    entry.task != null &&
                    _activeStatuses.contains(entry.task!.status),
              )
              .toList(growable: true)
            ..sort((left, right) {
              final byState = _taskPriority(
                left.task!.status,
              ).compareTo(_taskPriority(right.task!.status));
              if (byState != 0) return byState;
              return originalOrder[left.link]!.compareTo(
                originalOrder[right.link]!,
              );
            });
      final currentTaskIds = <String>{
        for (final entry in linked)
          if (entry.link.boardId == currentBoardId) entry.link.taskId,
      };
      final activity = mission.activity
          .where((event) {
            if (event.kind == MissionActivityKind.sessionUpdated) return false;
            return currentTaskIds.contains(event.sourceId);
          })
          .toList(growable: false);
      const approvals = <MissionApproval>[];
      final blockedCount = active
          .where((entry) => entry.task!.status == 'blocked')
          .length;

      projections.add(
        MissionRoomWorkProjection._(
          roomId: room.id,
          linkedTasks: List.unmodifiable(linked),
          activeTasks: List.unmodifiable(active),
          primaryTask: active.isEmpty ? null : active.first,
          activity: List.unmodifiable(activity),
          approvals: List.unmodifiable(approvals),
          attentionCount: blockedCount + approvals.length,
          spineState: _spineState(linked),
          workerSession: null,
        ),
      );
    }

    final unscopedTasks = <MissionRoomLinkedTask>[
      for (final task in mission.tasks)
        if (!linkedOnCurrentBoard.contains(task.id))
          MissionRoomLinkedTask(
            link: MissionRoomTaskLink(boardId: currentBoardId, taskId: task.id),
            task: task,
          ),
    ];
    final unscopedApprovals = mission.approvals.toList(growable: false);

    return MissionRoomWorkSet._(
      rooms: List.unmodifiable(projections),
      unscoped: UnscopedMissionWorkProjection._(
        tasks: List.unmodifiable(unscopedTasks),
        approvals: List.unmodifiable(unscopedApprovals),
      ),
    );
  }

  static MissionRoomSpineState _spineState(
    Iterable<MissionRoomLinkedTask> linked,
  ) {
    final statuses = linked
        .map((entry) => entry.task?.status)
        .whereType<String>()
        .toSet();
    if (statuses.contains('blocked')) return MissionRoomSpineState.blocked;
    if (statuses.contains('running')) return MissionRoomSpineState.active;
    if (statuses.contains('review')) return MissionRoomSpineState.warning;
    return MissionRoomSpineState.neutral;
  }

  static int _taskPriority(String status) => switch (status) {
    'blocked' => 0,
    'running' => 1,
    'review' => 2,
    'ready' => 3,
    _ => 4,
  };
}
