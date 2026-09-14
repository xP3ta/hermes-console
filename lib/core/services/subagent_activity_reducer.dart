import '../models/subagent_activity.dart';

abstract final class SubagentActivityReducer {
  static SubagentActivityState reduce(
    SubagentActivityState state,
    SubagentActivityEvent event,
  ) {
    if (state.scope != event.scope || !event.hasStableIdentity) return state;

    final eventKey = event.preferredKey;
    final matches = state.activities
        .where(
          (activity) =>
              activity.key == eventKey || activity.explicitlyMatches(event),
        )
        .toList(growable: false);

    if (matches.isEmpty) {
      final created = _fromEvent(event);
      if (created == null) return state;
      if (!created.isTerminal &&
          state.activities.where((activity) => !activity.isTerminal).length >=
              SubagentPayloadLimits.activeActivities) {
        return state;
      }
      final changed = Map<SubagentActivityKey, SubagentActivity>.of(
        state.entries,
      );
      changed[created.key] = created;
      return SubagentActivityState.withEntries(state.scope, changed);
    }

    var combined = matches.first;
    for (final activity in matches.skip(1)) {
      combined = _mergeExplicitAliases(combined, activity);
    }
    var updated = _applyEvent(combined, event);
    updated = _withCanonicalKey(updated);

    final collision = state.entries[updated.key];
    if (collision != null && !matches.contains(collision)) {
      updated = _withCanonicalKey(_mergeExplicitAliases(updated, collision));
    }

    if (matches.length == 1 &&
        matches.single.key == updated.key &&
        _sameActivity(matches.single, updated)) {
      return state;
    }

    final changed = Map<SubagentActivityKey, SubagentActivity>.of(
      state.entries,
    );
    for (final activity in matches) {
      changed.remove(activity.key);
    }
    if (collision != null) changed.remove(collision.key);
    changed[updated.key] = updated;
    return SubagentActivityState.withEntries(state.scope, changed);
  }
}

SubagentActivity? _fromEvent(SubagentActivityEvent event) {
  final key = event.preferredKey;
  if (key == null) return null;
  return SubagentActivity(
    key: key,
    source: event.source,
    phase: event.phase,
    subagentId: event.subagentId,
    delegationId: event.delegationId,
    childSessionId: event.childSessionId,
    legacyToolCallId: event.legacyToolCallId,
    eventRevision: event.eventRevision,
    seenEventIds: event.eventId == null ? const [] : [event.eventId!],
    details: event.details,
  );
}

SubagentActivity _applyEvent(
  SubagentActivity current,
  SubagentActivityEvent event,
) {
  final identities = _mergeIdentities(current, event);
  final withIdentities = _copyActivity(
    current,
    subagentId: identities.$1,
    delegationId: identities.$2,
    childSessionId: identities.$3,
    legacyToolCallId: identities.$4,
    source:
        current.source == SubagentActivitySource.native ||
            event.source == SubagentActivitySource.native
        ? SubagentActivitySource.native
        : SubagentActivitySource.legacyDelegateTask,
  );

  final replayedEvent =
      event.eventId != null &&
      withIdentities.seenEventIds.contains(event.eventId);
  final staleRevision =
      event.eventRevision != null &&
      withIdentities.eventRevision != null &&
      event.eventRevision! <= withIdentities.eventRevision!;
  if (replayedEvent || staleRevision) return withIdentities;

  final nativeHasPriority =
      current.source == SubagentActivitySource.native &&
      event.source == SubagentActivitySource.legacyDelegateTask;
  if (nativeHasPriority) return withIdentities;

  final isCompletion =
      event.kind == SubagentActivityEventKind.complete ||
      event.kind == SubagentActivityEventKind.legacyToolComplete;
  final newerRevision =
      event.eventRevision != null &&
      (current.eventRevision == null ||
          event.eventRevision! > current.eventRevision!);

  if (current.isTerminal && !isCompletion) return withIdentities;

  final phase = current.isTerminal
      ? _terminalPhase(current, event, newerRevision: newerRevision)
      : _nextLivePhase(current.phase, event.phase);
  final details = current.isTerminal
      ? _mergeDetails(
          current.details,
          event.details,
          overwrite:
              newerRevision ||
              (current.source == SubagentActivitySource.legacyDelegateTask &&
                  event.source == SubagentActivitySource.native),
        )
      : _mergeDetails(current.details, event.details, overwrite: true);

  return _copyActivity(
    withIdentities,
    phase: phase,
    eventRevision: event.eventRevision ?? current.eventRevision,
    seenEventIds: _rememberEventId(withIdentities.seenEventIds, event.eventId),
    details: details,
  );
}

SubagentActivityPhase _terminalPhase(
  SubagentActivity current,
  SubagentActivityEvent event, {
  required bool newerRevision,
}) {
  if (!event.phase.isTerminal) return current.phase;
  if (current.source == SubagentActivitySource.legacyDelegateTask &&
      event.source == SubagentActivitySource.native) {
    return event.phase;
  }
  return newerRevision ? event.phase : current.phase;
}

SubagentActivityPhase _nextLivePhase(
  SubagentActivityPhase current,
  SubagentActivityPhase incoming,
) {
  if (incoming.isTerminal) return incoming;
  return switch (incoming) {
    SubagentActivityPhase.requested =>
      current == SubagentActivityPhase.unknown
          ? SubagentActivityPhase.requested
          : current,
    SubagentActivityPhase.running =>
      current == SubagentActivityPhase.requested ||
              current == SubagentActivityPhase.unknown
          ? SubagentActivityPhase.running
          : current,
    SubagentActivityPhase.thinking => SubagentActivityPhase.thinking,
    SubagentActivityPhase.tool => SubagentActivityPhase.tool,
    SubagentActivityPhase.unknown => current,
    SubagentActivityPhase.completed ||
    SubagentActivityPhase.failed ||
    SubagentActivityPhase.cancelled => incoming,
  };
}

SubagentActivity _mergeExplicitAliases(
  SubagentActivity left,
  SubagentActivity right,
) {
  final primary = _preferredActivity(left, right);
  final secondary = identical(primary, left) ? right : left;
  final phase = _preferredPhase(primary, secondary);
  return _copyActivity(
    primary,
    source:
        primary.source == SubagentActivitySource.native ||
            secondary.source == SubagentActivitySource.native
        ? SubagentActivitySource.native
        : SubagentActivitySource.legacyDelegateTask,
    phase: phase,
    subagentId: primary.subagentId ?? secondary.subagentId,
    delegationId: primary.delegationId ?? secondary.delegationId,
    childSessionId: primary.childSessionId ?? secondary.childSessionId,
    legacyToolCallId: primary.legacyToolCallId ?? secondary.legacyToolCallId,
    eventRevision: _maxRevision(primary.eventRevision, secondary.eventRevision),
    seenEventIds: _mergeEventIds(primary.seenEventIds, secondary.seenEventIds),
    details: _mergeDetails(
      primary.details,
      secondary.details,
      overwrite: false,
    ),
  );
}

SubagentActivity _preferredActivity(
  SubagentActivity left,
  SubagentActivity right,
) {
  if (left.source != right.source) {
    return left.source == SubagentActivitySource.native ? left : right;
  }
  final leftRevision = left.eventRevision;
  final rightRevision = right.eventRevision;
  if (leftRevision != null && rightRevision != null) {
    return rightRevision > leftRevision ? right : left;
  }
  if (leftRevision == null && rightRevision != null) return right;
  if (left.isTerminal != right.isTerminal) {
    return left.isTerminal ? left : right;
  }
  return left;
}

SubagentActivityPhase _preferredPhase(
  SubagentActivity primary,
  SubagentActivity secondary,
) {
  if (primary.source == SubagentActivitySource.native &&
      secondary.source == SubagentActivitySource.legacyDelegateTask) {
    return primary.phase;
  }
  if (primary.isTerminal) return primary.phase;
  if (secondary.isTerminal) return secondary.phase;
  return primary.phase;
}

SubagentActivity _withCanonicalKey(SubagentActivity activity) {
  final identity = preferredSubagentIdentity(
    subagentId: activity.subagentId,
    delegationId: activity.delegationId,
    childSessionId: activity.childSessionId,
    legacyToolCallId: activity.legacyToolCallId,
  );
  if (identity == null) return activity;
  final key = SubagentActivityKey(
    scope: activity.key.scope,
    identityKind: identity.$1,
    stableId: identity.$2,
  );
  if (key == activity.key) return activity;
  return _copyActivity(activity, key: key);
}

(String?, String?, String?, String?) _mergeIdentities(
  SubagentActivity current,
  SubagentActivityEvent event,
) => (
  current.subagentId ?? event.subagentId,
  current.delegationId ?? event.delegationId,
  current.childSessionId ?? event.childSessionId,
  current.legacyToolCallId ?? event.legacyToolCallId,
);

SubagentActivityDetails _mergeDetails(
  SubagentActivityDetails current,
  SubagentActivityDetails incoming, {
  required bool overwrite,
}) {
  T? choose<T>(T? oldValue, T? newValue) =>
      overwrite ? newValue ?? oldValue : oldValue ?? newValue;

  final toolsets = _mergeStrings(
    current.toolsets,
    incoming.toolsets,
    preferIncoming: overwrite,
    limit: SubagentPayloadLimits.toolsetCount,
  );
  final usage = _mergeUsage(
    current.usage,
    incoming.usage,
    overwrite: overwrite,
  );
  return SubagentActivityDetails(
    goalPreview: choose(current.goalPreview, incoming.goalPreview),
    detailPreview: choose(current.detailPreview, incoming.detailPreview),
    summaryPreview: choose(current.summaryPreview, incoming.summaryPreview),
    outputTailPreview: choose(
      current.outputTailPreview,
      incoming.outputTailPreview,
    ),
    parentId: choose(current.parentId, incoming.parentId),
    depth: choose(current.depth, incoming.depth),
    model: choose(current.model, incoming.model),
    progress: choose(current.progress, incoming.progress),
    toolCount: choose(current.toolCount, incoming.toolCount),
    toolsets: toolsets,
    filesReadCount: choose(current.filesReadCount, incoming.filesReadCount),
    filesWrittenCount: choose(
      current.filesWrittenCount,
      incoming.filesWrittenCount,
    ),
    activeToolName: choose(current.activeToolName, incoming.activeToolName),
    activeToolPreview: choose(
      current.activeToolPreview,
      incoming.activeToolPreview,
    ),
    acceptingSteer: choose(current.acceptingSteer, incoming.acceptingSteer),
    usage: usage,
    durationSeconds: choose(current.durationSeconds, incoming.durationSeconds),
    startedAt: choose(current.startedAt, incoming.startedAt),
    completedAt: choose(current.completedAt, incoming.completedAt),
  );
}

SubagentUsage? _mergeUsage(
  SubagentUsage? current,
  SubagentUsage? incoming, {
  required bool overwrite,
}) {
  if (current == null) return incoming;
  if (incoming == null) return current;
  T? choose<T>(T? oldValue, T? newValue) =>
      overwrite ? newValue ?? oldValue : oldValue ?? newValue;
  return SubagentUsage(
    inputTokens: choose(current.inputTokens, incoming.inputTokens),
    outputTokens: choose(current.outputTokens, incoming.outputTokens),
    reasoningTokens: choose(current.reasoningTokens, incoming.reasoningTokens),
    apiCalls: choose(current.apiCalls, incoming.apiCalls),
    costUsd: choose(current.costUsd, incoming.costUsd),
  );
}

List<String> _rememberEventId(List<String> current, String? eventId) {
  if (eventId == null || current.contains(eventId)) return current;
  final result = <String>[...current, eventId];
  if (result.length > SubagentPayloadLimits.rememberedEventIds) {
    result.removeRange(
      0,
      result.length - SubagentPayloadLimits.rememberedEventIds,
    );
  }
  return List.unmodifiable(result);
}

List<String> _mergeEventIds(List<String> left, List<String> right) =>
    _mergeStrings(
      left,
      right,
      preferIncoming: false,
      limit: SubagentPayloadLimits.rememberedEventIds,
      keepNewest: true,
    );

List<String> _mergeStrings(
  List<String> current,
  List<String> incoming, {
  required bool preferIncoming,
  required int limit,
  bool keepNewest = false,
}) {
  final ordered = preferIncoming
      ? <String>[...incoming, ...current]
      : <String>[...current, ...incoming];
  final result = <String>[];
  for (final item in ordered) {
    if (!result.contains(item)) result.add(item);
  }
  if (result.length > limit) {
    return List.unmodifiable(
      keepNewest
          ? result.sublist(result.length - limit)
          : result.sublist(0, limit),
    );
  }
  return List.unmodifiable(result);
}

int? _maxRevision(int? left, int? right) {
  if (left == null) return right;
  if (right == null) return left;
  return left > right ? left : right;
}

SubagentActivity _copyActivity(
  SubagentActivity value, {
  SubagentActivityKey? key,
  SubagentActivitySource? source,
  SubagentActivityPhase? phase,
  String? subagentId,
  String? delegationId,
  String? childSessionId,
  String? legacyToolCallId,
  int? eventRevision,
  List<String>? seenEventIds,
  SubagentActivityDetails? details,
}) => SubagentActivity(
  key: key ?? value.key,
  source: source ?? value.source,
  phase: phase ?? value.phase,
  subagentId: subagentId ?? value.subagentId,
  delegationId: delegationId ?? value.delegationId,
  childSessionId: childSessionId ?? value.childSessionId,
  legacyToolCallId: legacyToolCallId ?? value.legacyToolCallId,
  eventRevision: eventRevision ?? value.eventRevision,
  seenEventIds: seenEventIds ?? value.seenEventIds,
  details: details ?? value.details,
);

bool _sameActivity(SubagentActivity left, SubagentActivity right) =>
    left.key == right.key &&
    left.source == right.source &&
    left.phase == right.phase &&
    left.subagentId == right.subagentId &&
    left.delegationId == right.delegationId &&
    left.childSessionId == right.childSessionId &&
    left.legacyToolCallId == right.legacyToolCallId &&
    left.eventRevision == right.eventRevision &&
    _sameStrings(left.seenEventIds, right.seenEventIds) &&
    _sameDetails(left.details, right.details);

bool _sameDetails(
  SubagentActivityDetails left,
  SubagentActivityDetails right,
) =>
    left.goalPreview == right.goalPreview &&
    left.detailPreview == right.detailPreview &&
    left.summaryPreview == right.summaryPreview &&
    left.outputTailPreview == right.outputTailPreview &&
    left.parentId == right.parentId &&
    left.depth == right.depth &&
    left.model == right.model &&
    left.progress == right.progress &&
    left.toolCount == right.toolCount &&
    _sameStrings(left.toolsets, right.toolsets) &&
    left.filesReadCount == right.filesReadCount &&
    left.filesWrittenCount == right.filesWrittenCount &&
    left.activeToolName == right.activeToolName &&
    left.activeToolPreview == right.activeToolPreview &&
    left.acceptingSteer == right.acceptingSteer &&
    left.usage == right.usage &&
    left.durationSeconds == right.durationSeconds &&
    left.startedAt == right.startedAt &&
    left.completedAt == right.completedAt;

bool _sameStrings(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
