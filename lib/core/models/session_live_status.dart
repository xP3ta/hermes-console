import '../../l10n/app_localizations.dart';
import '../services/global_activity_aggregate.dart';
import 'agent_task_list.dart';
import 'session_activity.dart';

/// ss1215 · What a conversation is doing right now, in one closed vocabulary
/// shared by the chat pill, the Conversaciones row and the Inicio card.
///
/// Before this, each surface derived its own wording from a different source
/// (the chat from its pipeline state, the list from `SessionActivity.kind`,
/// Home from a third mapping of the same kinds), so the same moment read as
/// «Ejecutando herramientas…» in the chat, «usando herramientas» in the list
/// and «Pensando…» on Home, or a list row stayed «trabajando» while the chat
/// was already waiting for the user.
///
/// Precedence (highest first): waiting for you > running tool > responding >
/// thinking > compacting > working (another surface owns the turn) >
/// delegated > background > unknown > idle. A queued prompt never changes the phase:
/// during a turn it waits behind that turn, and a parked queue is idle.
enum SessionLivePhase {
  waitingForUser,
  runningTool,
  responding,
  thinking,
  compacting,
  working,
  delegated,
  background,

  /// The roster lost the detail (truncated replay) and nothing proves what
  /// the session is doing: shown only as «último estado conocido», never as
  /// «trabajando».
  unknown,
  idle,
}

final class SessionLiveStatus {
  const SessionLiveStatus({
    required this.phase,
    this.toolLabel,
    this.toolDetail,
    this.tasks,
    this.backgroundCount = 0,
    this.subagentCount = 0,
    this.stale = false,
    this.provisional = false,
  });

  static const SessionLiveStatus idle = SessionLiveStatus(
    phase: SessionLivePhase.idle,
  );

  final SessionLivePhase phase;

  /// Tool (or skill) that is running now, as the pill names it. Only from
  /// this device's own event stream; never inferred for another surface.
  final String? toolLabel;
  final String? toolDetail;

  /// Task list of the live turn, when there is one.
  final AgentTaskList? tasks;
  final int backgroundCount;
  final int subagentCount;

  /// Last known state of a runtime this device lost contact with.
  final bool stale;

  /// Remembered from an earlier visit or from the roster, shown while the
  /// chat re-attaches; the resume snapshot replaces it.
  final bool provisional;

  bool get isLive => phase != SessionLivePhase.idle;

  /// A turn is in flight (as opposed to background-only work).
  bool get turnLive => switch (phase) {
    SessionLivePhase.waitingForUser ||
    SessionLivePhase.runningTool ||
    SessionLivePhase.responding ||
    SessionLivePhase.thinking ||
    SessionLivePhase.working => true,
    _ => false,
  };

  bool get hasOpenTasks => tasks != null && tasks!.hasOpen;

  SessionLiveStatus asProvisional() => SessionLiveStatus(
    phase: phase,
    toolLabel: toolLabel,
    toolDetail: toolDetail,
    tasks: tasks,
    backgroundCount: backgroundCount,
    subagentCount: subagentCount,
    stale: stale,
    provisional: true,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLiveStatus &&
          phase == other.phase &&
          toolLabel == other.toolLabel &&
          toolDetail == other.toolDetail &&
          (tasks?.done) == (other.tasks?.done) &&
          (tasks?.total) == (other.tasks?.total) &&
          (tasks?.current?.id) == (other.tasks?.current?.id) &&
          backgroundCount == other.backgroundCount &&
          subagentCount == other.subagentCount &&
          stale == other.stale &&
          provisional == other.provisional;

  @override
  int get hashCode => Object.hash(
    phase,
    toolLabel,
    toolDetail,
    tasks?.done,
    tasks?.total,
    tasks?.current?.id,
    backgroundCount,
    subagentCount,
    stale,
    provisional,
  );

  @override
  String toString() =>
      'SessionLiveStatus($phase, tool: $toolLabel, '
      'tasks: ${tasks?.done}/${tasks?.total}, bg: $backgroundCount, '
      'sub: $subagentCount, stale: $stale, provisional: $provisional)';
}

/// The open chat's own projection of [SessionActivity] plus what only the
/// chat knows (the running tool, its task list).
SessionLiveStatus sessionLiveStatusFromActivity(
  SessionActivity activity, {
  required bool waitingForUser,
  String? toolLabel,
  String? toolDetail,
  AgentTaskList? tasks,
}) {
  final turn = activity.foregroundTurn;
  final SessionLivePhase phase;
  if (waitingForUser && (turn || activity.rosterTurn)) {
    phase = SessionLivePhase.waitingForUser;
  } else if (turn && toolLabel != null) {
    phase = SessionLivePhase.runningTool;
  } else if (turn &&
      activity.foregroundKind == SessionActivityKind.responding) {
    phase = SessionLivePhase.responding;
  } else if (turn &&
      activity.foregroundKind == SessionActivityKind.waitingForUser) {
    phase = SessionLivePhase.waitingForUser;
  } else if (turn &&
      activity.foregroundKind != SessionActivityKind.compacting) {
    phase = SessionLivePhase.thinking;
  } else if (activity.compacting ||
      activity.foregroundKind == SessionActivityKind.compacting) {
    phase = SessionLivePhase.compacting;
  } else if (activity.rosterTurn) {
    phase = SessionLivePhase.working;
  } else if (activity.subagentCount > 0) {
    phase = SessionLivePhase.delegated;
  } else if (activity.backgroundItemCount > 0) {
    phase = SessionLivePhase.background;
  } else {
    phase = SessionLivePhase.idle;
  }
  final turnLive = switch (phase) {
    SessionLivePhase.waitingForUser ||
    SessionLivePhase.runningTool ||
    SessionLivePhase.responding ||
    SessionLivePhase.thinking ||
    SessionLivePhase.working => true,
    _ => false,
  };
  return SessionLiveStatus(
    phase: phase,
    toolLabel: phase == SessionLivePhase.runningTool ? toolLabel : null,
    toolDetail: phase == SessionLivePhase.runningTool ? toolDetail : null,
    tasks: turnLive && tasks != null && tasks.isNotEmpty ? tasks : null,
    backgroundCount: activity.backgroundItemCount,
    subagentCount: activity.subagentCount,
    stale: activity.stale && !turn,
  );
}

/// A session this device only knows through `session.active_list` and the
/// gateway event fan-out (never opened, or released).
SessionLiveStatus sessionLiveStatusFromGlobal(GlobalActivity? activity) {
  if (activity == null || !activity.active) return SessionLiveStatus.idle;
  if (activity.requiresAction) {
    return SessionLiveStatus(
      phase: SessionLivePhase.waitingForUser,
      stale: activity.stale,
    );
  }
  final phase = switch (activity.phase) {
    GlobalActivityPhase.waitingForUser => SessionLivePhase.waitingForUser,
    GlobalActivityPhase.compacting => SessionLivePhase.compacting,
    GlobalActivityPhase.delegated => SessionLivePhase.delegated,
    GlobalActivityPhase.backgroundWork => SessionLivePhase.background,
    // Another surface's tools are not named here: the roster only proves
    // that the turn is working.
    GlobalActivityPhase.preparing ||
    GlobalActivityPhase.generating ||
    GlobalActivityPhase.usingTools ||
    GlobalActivityPhase.completing => SessionLivePhase.working,
    GlobalActivityPhase.unknown => SessionLivePhase.unknown,
    GlobalActivityPhase.completed ||
    GlobalActivityPhase.interrupted ||
    GlobalActivityPhase.failed => SessionLivePhase.idle,
  };
  return SessionLiveStatus(
    phase: phase,
    backgroundCount: activity.processCount,
    subagentCount: activity.subagentCount,
    stale: activity.stale,
  );
}

/// One status per session: the open (or retained) chat speaks for its own
/// session whenever it has proof of state; otherwise the roster does.
///
/// [chatAuthoritative]: the chat is attached to the runtime (or saw its own
/// turn end). [chatSettledAt]: when the chat last saw its own turn end; a
/// roster row observed before that is older evidence and loses.
SessionLiveStatus resolveSessionLiveStatus({
  SessionLiveStatus? chat,
  bool chatAuthoritative = true,
  DateTime? chatSettledAt,
  GlobalActivity? global,
}) {
  if (chat != null && (chat.isLive || chat.provisional)) return chat;
  final remote = sessionLiveStatusFromGlobal(global);
  if (chat == null || !remote.isLive) return chat ?? remote;
  if (!chatAuthoritative) return remote;
  final observedAt = global?.observedAt;
  final rosterIsNewer =
      observedAt != null &&
      (chatSettledAt == null || observedAt.isAfter(chatSettledAt));
  return rosterIsNewer ? remote : chat;
}

/// The single status line used by the list row and the Home card. It is the
/// pill's own wording (same keys), so the three surfaces read alike.
String sessionLiveStatusLabel(Strings s, SessionLiveStatus status) {
  final base = switch (status.phase) {
    SessionLivePhase.waitingForUser => s.liveWaitingForUser,
    SessionLivePhase.runningTool =>
      status.toolLabel == null
          ? s.ss1215StatusWorking
          : [status.toolLabel!, ?status.toolDetail].join(' · '),
    SessionLivePhase.responding => s.chaPipelineStreaming,
    SessionLivePhase.thinking => s.chaPipelineThinking,
    SessionLivePhase.compacting => s.liveCompacting,
    SessionLivePhase.working => s.ss1215StatusWorking,
    SessionLivePhase.delegated => s.liveSubagentsWorking(
      status.subagentCount < 1 ? 1 : status.subagentCount,
    ),
    SessionLivePhase.background =>
      status.backgroundCount > 0
          ? s.chaBackgroundActivityCount(status.backgroundCount)
          : s.chaBackgroundWorkTitle,
    SessionLivePhase.unknown => '',
    SessionLivePhase.idle => '',
  };
  final parts = <String>[
    base,
    if (status.tasks != null && status.tasks!.isNotEmpty)
      s.liveTasksShort(status.tasks!.done, status.tasks!.total),
    if (status.stale || status.phase == SessionLivePhase.unknown)
      s.slActivityStale,
  ];
  return parts.where((part) => part.isNotEmpty).join(' · ');
}

/// Kind used by the existing tone/colour helpers.
SessionActivityKind sessionLiveStatusKind(SessionLiveStatus status) =>
    switch (status.phase) {
      SessionLivePhase.waitingForUser => SessionActivityKind.waitingForUser,
      SessionLivePhase.runningTool => SessionActivityKind.usingTools,
      SessionLivePhase.responding => SessionActivityKind.responding,
      SessionLivePhase.thinking ||
      SessionLivePhase.working => SessionActivityKind.generating,
      SessionLivePhase.compacting => SessionActivityKind.compacting,
      SessionLivePhase.delegated => SessionActivityKind.delegated,
      SessionLivePhase.background => SessionActivityKind.backgroundProcess,
      SessionLivePhase.unknown ||
      SessionLivePhase.idle => SessionActivityKind.idle,
    };
