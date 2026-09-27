/// Hosted room driver status as returned by `groups.state.driver_status`
/// (`tui_gateway/hosted_room_service.py::HostedRoomService.status`).
///
/// The server is the only authority on whether a room is working, blocked or
/// waiting for the user. Console never infers these from local timers.
library;

/// Approval choices the gateway may offer (`ApprovalChoice` in the contract).
const Set<String> roomApprovalChoices = {'once', 'session', 'always', 'deny'};

sealed class RoomPendingAction {
  const RoomPendingAction();

  String get taskId;

  /// Tolerant row parser: unknown kinds and malformed rows yield `null` so a
  /// newer server cannot make Console answer something it does not model.
  static RoomPendingAction? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    final taskId = _id(raw['task_id']);
    if (taskId == null) return null;
    if (kind == 'retry') return RoomRetryAction(taskId: taskId);
    if (kind != 'approval') return null;
    final memberId = _id(raw['member_id']);
    final generation = raw['execution_generation'];
    final approval = raw['approval'];
    final requestId =
        _id(raw['request_id']) ??
        (approval is Map ? _id(approval['request_id']) : null);
    if (memberId == null ||
        generation is! int ||
        generation < 0 ||
        requestId == null) {
      return null;
    }
    final offered = approval is Map ? approval['choices'] : null;
    final choices = <String>[
      if (offered is List)
        for (final choice in offered)
          if (choice is String && roomApprovalChoices.contains(choice)) choice,
    ];
    return RoomApprovalAction(
      taskId: taskId,
      memberId: memberId,
      executionGeneration: generation,
      requestId: requestId,
      runId: _id(raw['run_id']),
      sessionId: _id(raw['session_id']),
      // The driver always offers at least once/deny (hosted_room_driver.py).
      choices: List.unmodifiable(
        choices.isEmpty ? const ['once', 'deny'] : choices.toSet().toList(),
      ),
      command: approval is Map ? _text(approval['command'], 4000) : null,
      description: approval is Map
          ? _text(approval['description'], 1000)
          : null,
    );
  }
}

final class RoomRetryAction extends RoomPendingAction {
  @override
  final String taskId;
  const RoomRetryAction({required this.taskId});

  @override
  bool operator ==(Object other) =>
      other is RoomRetryAction && other.taskId == taskId;

  @override
  int get hashCode => Object.hash('retry', taskId);
}

final class RoomApprovalAction extends RoomPendingAction {
  @override
  final String taskId;
  final String memberId;
  final int executionGeneration;
  final String requestId;
  final String? runId;
  final String? sessionId;

  /// Only the choices the server offers; Console must not answer others.
  final List<String> choices;
  final String? command;
  final String? description;

  const RoomApprovalAction({
    required this.taskId,
    required this.memberId,
    required this.executionGeneration,
    required this.requestId,
    required this.choices,
    this.runId,
    this.sessionId,
    this.command,
    this.description,
  });

  bool offers(String choice) => choices.contains(choice);

  @override
  bool operator ==(Object other) =>
      other is RoomApprovalAction &&
      other.taskId == taskId &&
      other.memberId == memberId &&
      other.executionGeneration == executionGeneration &&
      other.requestId == requestId;

  @override
  int get hashCode =>
      Object.hash(taskId, memberId, executionGeneration, requestId);
}

final class RoomDriverStatus {
  final bool running;
  final bool working;
  final bool blocked;
  final Map<String, int> counts;
  final List<RoomPendingAction> pendingActions;

  const RoomDriverStatus({
    required this.running,
    required this.working,
    required this.blocked,
    this.counts = const {},
    this.pendingActions = const [],
  });

  /// No driver evidence (older gateway or a disbanded room).
  static const unknown = RoomDriverStatus(
    running: false,
    working: false,
    blocked: false,
  );

  static RoomDriverStatus? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final running = raw['running'];
    final working = raw['working'];
    final blocked = raw['blocked'];
    if (running is! bool || working is! bool || blocked is! bool) return null;
    final counts = <String, int>{};
    final rawCounts = raw['counts'];
    if (rawCounts is Map) {
      for (final entry in rawCounts.entries) {
        if (entry.key is String && entry.value is int && entry.value >= 0) {
          counts[entry.key as String] = entry.value as int;
        }
      }
    }
    final actions = <RoomPendingAction>[];
    final rawActions = raw['pending_actions'];
    if (rawActions is List) {
      for (final row in rawActions.take(64)) {
        final parsed = RoomPendingAction.tryParse(row);
        if (parsed != null && !actions.contains(parsed)) actions.add(parsed);
      }
    }
    return RoomDriverStatus(
      running: running,
      working: working,
      blocked: blocked,
      counts: Map.unmodifiable(counts),
      pendingActions: List.unmodifiable(actions),
    );
  }

  Iterable<RoomApprovalAction> get approvals =>
      pendingActions.whereType<RoomApprovalAction>();

  Iterable<RoomRetryAction> get retries =>
      pendingActions.whereType<RoomRetryAction>();

  bool get needsUser => pendingActions.isNotEmpty;

  /// True when `groups.retry` may be sent for [taskId]: the server itself
  /// lists it as retryable (`indeterminate`/`deferred`).
  bool offersRetry(String taskId) =>
      retries.any((action) => action.taskId == taskId);

  RoomApprovalAction? approvalFor({
    required String taskId,
    required String requestId,
  }) {
    for (final action in approvals) {
      if (action.taskId == taskId && action.requestId == requestId) {
        return action;
      }
    }
    return null;
  }
}

String? _id(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  if (value.isEmpty ||
      value != raw ||
      value.runes.length > 256 ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return null;
  }
  return value;
}

String? _text(Object? raw, int max) {
  if (raw is! String) return null;
  final value = raw.trim();
  if (value.isEmpty) return null;
  return value.length > max ? value.substring(0, max) : value;
}
