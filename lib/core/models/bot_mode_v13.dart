import 'mission_control.dart';

/// V13 identities are source-qualified; display names never establish equality.
final class AvatarOwner {
  final String connectionId;
  final String profile;

  const AvatarOwner({required this.connectionId, required this.profile});

  bool get isValid =>
      connectionId.trim().isNotEmpty && profile.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is AvatarOwner &&
      other.connectionId == connectionId &&
      other.profile == profile;

  @override
  int get hashCode => Object.hash(connectionId, profile);
}

enum HandoffKind { approval, clarify }

enum WorkRouteMode { read, write }

enum WorkKind { approval, task, board }

enum WorkAttention { needsDecision, blocked, review, running, ready, empty }

enum CapabilityAvailability { available, unsupported, offline, stale, readOnly }

enum OfficialCapability {
  profilesRead,
  profilesCreate,
  profilesDelete,
  profilesConfigure,
  profileAvatarRead,
  profileAvatarWrite,
  sessionsRead,
  sessionCreate,
  promptSubmit,
  kanbanRead,
  kanbanBoardCrud,
  kanbanTaskCrud,
  kanbanAdvanced,
  approvalRespond,
  clarifyRespond,
  groupRead,
  groupCreate,
  groupRename,
  groupDisband,
  groupMembershipWrite,
  groupThreadReply,
  groupStop,
  groupHoldResume,
  groupImageWrite,
  groupPinWrite,
  attachments,
  cronRead,
  cronWrite,
  deepLinkOpen,
}

final class RouteCapabilities {
  final String connectionId;
  final int generation;
  final Map<OfficialCapability, CapabilityAvailability>
  availabilityByCapability;

  RouteCapabilities({
    required this.connectionId,
    required this.generation,
    required Map<OfficialCapability, CapabilityAvailability>
    availabilityByCapability,
  }) : availabilityByCapability = Map.unmodifiable({
         for (final capability in OfficialCapability.values)
           capability:
               availabilityByCapability[capability] ??
               CapabilityAvailability.unsupported,
       });

  factory RouteCapabilities.complete({
    required String connectionId,
    required int generation,
    required CapabilityAvailability availability,
  }) => RouteCapabilities(
    connectionId: connectionId,
    generation: generation,
    availabilityByCapability: {
      for (final capability in OfficialCapability.values)
        capability: availability,
    },
  );

  CapabilityAvailability operator [](OfficialCapability capability) =>
      availabilityByCapability[capability]!;
}

/// Private locator. Never interpolate this object into public text or semantics.
final class CanonicalHandoffRoute {
  final String connectionId;
  final String profile;
  final String runtimeSessionId;
  final String requestId;
  final HandoffKind kind;
  final int sourceGeneration;

  const CanonicalHandoffRoute({
    required this.connectionId,
    required this.profile,
    required this.runtimeSessionId,
    required this.requestId,
    required this.kind,
    required this.sourceGeneration,
  });

  bool get isValid =>
      connectionId.trim().isNotEmpty &&
      profile.trim().isNotEmpty &&
      runtimeSessionId.trim().isNotEmpty &&
      requestId.trim().isNotEmpty &&
      sourceGeneration >= 0;

  bool sameLocator(CanonicalHandoffRoute other) =>
      connectionId == other.connectionId &&
      profile == other.profile &&
      runtimeSessionId == other.runtimeSessionId &&
      requestId == other.requestId &&
      kind == other.kind &&
      sourceGeneration == other.sourceGeneration;
}

final class ApprovalSourcePrivate {
  final MissionApproval approval;
  final CanonicalHandoffRoute? candidateRoute;
  final int sourceGeneration;

  const ApprovalSourcePrivate({
    required this.approval,
    required this.candidateRoute,
    required this.sourceGeneration,
  });
}

final class BoardTaskSourcePrivate {
  final String connectionId;
  final String boardId;
  final String taskId;
  final int sourceGeneration;

  const BoardTaskSourcePrivate({
    required this.connectionId,
    required this.boardId,
    required this.taskId,
    required this.sourceGeneration,
  });
}

final class BoardSourcePrivate {
  final String connectionId;
  final String boardId;
  final int sourceGeneration;

  const BoardSourcePrivate({
    required this.connectionId,
    required this.boardId,
    required this.sourceGeneration,
  });
}

final class ApprovalPublicViewData {
  final String title;
  final String decisionCopy;
  final WorkAttention attention;
  final DateTime? freshness;

  const ApprovalPublicViewData.pending({this.freshness})
    : title = 'Aprobación pendiente',
      decisionCopy = 'Decide si quieres continuar',
      attention = WorkAttention.needsDecision;
}

ApprovalPublicViewData projectApprovalPublic(ApprovalSourcePrivate source) =>
    const ApprovalPublicViewData.pending();

final class BoardTaskRef {
  final String boardId;
  final String taskId;

  const BoardTaskRef({required this.boardId, required this.taskId});
}

final class BoardRef {
  final String boardId;

  const BoardRef({required this.boardId});
}

sealed class WorkDestination {
  final WorkRouteMode mode;
  const WorkDestination(this.mode);
}

final class ApprovalDestination extends WorkDestination {
  final CanonicalHandoffRoute route;
  const ApprovalDestination({required this.route, required WorkRouteMode mode})
    : super(mode);
}

final class TaskDestination extends WorkDestination {
  final String connectionId;
  final String boardId;
  final String taskId;
  const TaskDestination({
    required this.connectionId,
    required this.boardId,
    required this.taskId,
    required WorkRouteMode mode,
  }) : super(mode);
}

final class BoardDestination extends WorkDestination {
  final String connectionId;
  final String boardId;
  const BoardDestination({
    required this.connectionId,
    required this.boardId,
    required WorkRouteMode mode,
  }) : super(mode);
}

/// Render-safe work projection. It deliberately retains no raw backend DTO.
final class WorkItem {
  final String stableKey;
  final WorkKind kind;
  final String title;
  final String decisionCopy;
  final WorkAttention attention;
  final DateTime? freshness;
  final ApprovalPublicViewData? approvalView;
  final BoardTaskRef? taskRef;
  final BoardRef? boardRef;
  final WorkDestination? destination;

  WorkItem.approval({
    required this.stableKey,
    required ApprovalPublicViewData view,
    this.destination,
  }) : kind = WorkKind.approval,
       title = view.title,
       decisionCopy = view.decisionCopy,
       attention = view.attention,
       freshness = view.freshness,
       approvalView = view,
       taskRef = null,
       boardRef = null;

  const WorkItem.task({
    required this.stableKey,
    required this.title,
    required this.decisionCopy,
    required this.attention,
    required BoardTaskRef this.taskRef,
    this.freshness,
    this.destination,
  }) : kind = WorkKind.task,
       approvalView = null,
       boardRef = null;

  const WorkItem.board({
    required this.stableKey,
    required this.title,
    required this.decisionCopy,
    required this.attention,
    required BoardRef this.boardRef,
    this.freshness,
    this.destination,
  }) : kind = WorkKind.board,
       approvalView = null,
       taskRef = null;
}

WorkDestination? resolveWorkDestination({
  required WorkItem item,
  required Object? privateSource,
  required MissionBackendSnapshot snapshot,
  required MissionProjection mission,
  required RouteCapabilities capabilities,
  required Iterable<CanonicalHandoffRoute> liveHandoffs,
  WorkDestination? previouslyValidatedDestination,
}) {
  if (capabilities.connectionId.trim().isEmpty) return null;
  switch (item.kind) {
    case WorkKind.approval:
      if (privateSource is! ApprovalSourcePrivate ||
          item.approvalView == null ||
          item.taskRef != null ||
          item.boardRef != null) {
        return null;
      }
      final route = privateSource.candidateRoute;
      if (route == null ||
          !route.isValid ||
          route.kind != HandoffKind.approval ||
          route.connectionId != capabilities.connectionId ||
          route.sourceGeneration != capabilities.generation ||
          privateSource.sourceGeneration != capabilities.generation ||
          privateSource.approval.profileName != route.profile ||
          privateSource.approval.sessionId != route.runtimeSessionId ||
          privateSource.approval.requestId != route.requestId ||
          !liveHandoffs.any(route.sameLocator)) {
        return null;
      }
      final availability = capabilities[OfficialCapability.approvalRespond];
      final mode = switch (availability) {
        CapabilityAvailability.available => WorkRouteMode.write,
        CapabilityAvailability.readOnly || CapabilityAvailability.stale
            when previouslyValidatedDestination is ApprovalDestination &&
                previouslyValidatedDestination.route.sameLocator(route) =>
          WorkRouteMode.read,
        _ => null,
      };
      return mode == null
          ? null
          : ApprovalDestination(route: route, mode: mode);
    case WorkKind.task:
      if (privateSource is! BoardTaskSourcePrivate ||
          item.taskRef == null ||
          item.approvalView != null ||
          item.boardRef != null ||
          privateSource.connectionId != capabilities.connectionId ||
          privateSource.sourceGeneration != capabilities.generation ||
          privateSource.boardId != item.taskRef!.boardId ||
          privateSource.taskId != item.taskRef!.taskId ||
          snapshot.currentBoardId != privateSource.boardId ||
          !snapshot.tasks.any((task) => task.id == privateSource.taskId)) {
        return null;
      }
      final readAvailability = capabilities[OfficialCapability.kanbanRead];
      if (_cannotRead(readAvailability)) return null;
      if ((readAvailability == CapabilityAvailability.stale ||
              readAvailability == CapabilityAvailability.readOnly) &&
          !_sameTaskDestination(
            previouslyValidatedDestination,
            privateSource,
          )) {
        return null;
      }
      final mode =
          readAvailability == CapabilityAvailability.available &&
              capabilities[OfficialCapability.kanbanTaskCrud] ==
                  CapabilityAvailability.available
          ? WorkRouteMode.write
          : WorkRouteMode.read;
      return TaskDestination(
        connectionId: privateSource.connectionId,
        boardId: privateSource.boardId,
        taskId: privateSource.taskId,
        mode: mode,
      );
    case WorkKind.board:
      if (privateSource is! BoardSourcePrivate ||
          item.boardRef == null ||
          item.approvalView != null ||
          item.taskRef != null ||
          privateSource.connectionId != capabilities.connectionId ||
          privateSource.sourceGeneration != capabilities.generation ||
          privateSource.boardId != item.boardRef!.boardId ||
          snapshot.currentBoardId != privateSource.boardId ||
          _cannotRead(capabilities[OfficialCapability.kanbanRead])) {
        return null;
      }
      final readAvailability = capabilities[OfficialCapability.kanbanRead];
      if ((readAvailability == CapabilityAvailability.stale ||
              readAvailability == CapabilityAvailability.readOnly) &&
          !_sameBoardDestination(
            previouslyValidatedDestination,
            privateSource,
          )) {
        return null;
      }
      final mode =
          readAvailability == CapabilityAvailability.available &&
              capabilities[OfficialCapability.kanbanBoardCrud] ==
                  CapabilityAvailability.available
          ? WorkRouteMode.write
          : WorkRouteMode.read;
      return BoardDestination(
        connectionId: privateSource.connectionId,
        boardId: privateSource.boardId,
        mode: mode,
      );
  }
}

bool _cannotRead(CapabilityAvailability availability) =>
    availability == CapabilityAvailability.unsupported ||
    availability == CapabilityAvailability.offline;

bool _sameTaskDestination(
  WorkDestination? destination,
  BoardTaskSourcePrivate source,
) =>
    destination is TaskDestination &&
    destination.connectionId == source.connectionId &&
    destination.boardId == source.boardId &&
    destination.taskId == source.taskId;

bool _sameBoardDestination(
  WorkDestination? destination,
  BoardSourcePrivate source,
) =>
    destination is BoardDestination &&
    destination.connectionId == source.connectionId &&
    destination.boardId == source.boardId;
