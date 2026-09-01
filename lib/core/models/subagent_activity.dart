enum SubagentActivityPhase {
  requested,
  running,
  thinking,
  tool,
  completed,
  failed,
  cancelled,
  unknown,
}

extension SubagentActivityPhaseLifecycle on SubagentActivityPhase {
  bool get isTerminal =>
      this == SubagentActivityPhase.completed ||
      this == SubagentActivityPhase.failed ||
      this == SubagentActivityPhase.cancelled;
}

enum SubagentActivitySource { native, legacyDelegateTask }

enum SubagentIdentityKind { subagent, delegation, childSession, legacyToolCall }

enum SubagentActivityEventKind {
  spawnRequested,
  start,
  thinking,
  tool,
  progress,
  complete,
  legacyToolStart,
  legacyToolComplete,
}

abstract final class SubagentPayloadLimits {
  static const int opaqueIdCharacters = 256;
  static const int goalCharacters = 512;
  static const int detailCharacters = 512;
  static const int toolNameCharacters = 128;
  static const int toolPreviewCharacters = 512;
  static const int resultCharacters = 1024;
  static const int modelCharacters = 160;
  static const int toolsetCharacters = 128;
  static const int toolsetCount = 24;
  static const int rememberedEventIds = 32;
}

final class SubagentActivityScope {
  final String connectionId;
  final String profile;
  final String parentSessionId;
  final String runtimeSessionId;
  final int turnEpoch;

  factory SubagentActivityScope({
    required String connectionId,
    String profile = '',
    required String parentSessionId,
    required String runtimeSessionId,
    required int turnEpoch,
  }) {
    if (!_isUsableScopeId(connectionId) ||
        !_isUsableScopeId(parentSessionId) ||
        !_isUsableScopeId(runtimeSessionId)) {
      throw const FormatException('Invalid subagent activity scope');
    }
    if (turnEpoch < 0) {
      throw const FormatException('Invalid subagent activity epoch');
    }
    return SubagentActivityScope._(
      connectionId: connectionId,
      profile: profile,
      parentSessionId: parentSessionId,
      runtimeSessionId: runtimeSessionId,
      turnEpoch: turnEpoch,
    );
  }

  const SubagentActivityScope._({
    required this.connectionId,
    required this.profile,
    required this.parentSessionId,
    required this.runtimeSessionId,
    required this.turnEpoch,
  });

  SubagentActivityLineageKey get durableLineageKey =>
      SubagentActivityLineageKey(
        connectionId: connectionId,
        profile: profile,
        parentSessionId: parentSessionId,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubagentActivityScope &&
          connectionId == other.connectionId &&
          profile == other.profile &&
          parentSessionId == other.parentSessionId &&
          runtimeSessionId == other.runtimeSessionId &&
          turnEpoch == other.turnEpoch;

  @override
  int get hashCode => Object.hash(
    connectionId,
    profile,
    parentSessionId,
    runtimeSessionId,
    turnEpoch,
  );

  @override
  String toString() => 'SubagentActivityScope(epoch: $turnEpoch)';
}

final class SubagentActivityLineageKey {
  final String connectionId;
  final String profile;
  final String parentSessionId;

  const SubagentActivityLineageKey({
    required this.connectionId,
    required this.profile,
    required this.parentSessionId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubagentActivityLineageKey &&
          connectionId == other.connectionId &&
          profile == other.profile &&
          parentSessionId == other.parentSessionId;

  @override
  int get hashCode => Object.hash(connectionId, profile, parentSessionId);
}

final class SubagentActivityKey {
  final SubagentActivityScope scope;
  final SubagentIdentityKind identityKind;
  final String stableId;

  const SubagentActivityKey({
    required this.scope,
    required this.identityKind,
    required this.stableId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubagentActivityKey &&
          scope == other.scope &&
          identityKind == other.identityKind &&
          stableId == other.stableId;

  @override
  int get hashCode => Object.hash(scope, identityKind, stableId);

  @override
  String toString() =>
      'SubagentActivityKey(kind: ${identityKind.name}, scope: $scope)';
}

final class SubagentTaskProgress {
  final int taskIndex;
  final int taskCount;

  const SubagentTaskProgress({
    required this.taskIndex,
    required this.taskCount,
  });

  int get displayTaskIndex => taskIndex.clamp(0, taskCount);
  double get displayFraction => displayTaskIndex / taskCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubagentTaskProgress &&
          taskIndex == other.taskIndex &&
          taskCount == other.taskCount;

  @override
  int get hashCode => Object.hash(taskIndex, taskCount);
}

final class SubagentUsage {
  final int? inputTokens;
  final int? outputTokens;
  final int? reasoningTokens;
  final int? apiCalls;
  final double? costUsd;

  const SubagentUsage({
    this.inputTokens,
    this.outputTokens,
    this.reasoningTokens,
    this.apiCalls,
    this.costUsd,
  });

  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      reasoningTokens == null &&
      apiCalls == null &&
      costUsd == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubagentUsage &&
          inputTokens == other.inputTokens &&
          outputTokens == other.outputTokens &&
          reasoningTokens == other.reasoningTokens &&
          apiCalls == other.apiCalls &&
          costUsd == other.costUsd;

  @override
  int get hashCode => Object.hash(
    inputTokens,
    outputTokens,
    reasoningTokens,
    apiCalls,
    costUsd,
  );
}

final class SubagentActivityDetails {
  final String? goalPreview;
  final String? detailPreview;
  final String? summaryPreview;
  final String? outputTailPreview;
  final String? parentId;
  final int? depth;
  final String? model;
  final SubagentTaskProgress? progress;
  final int? toolCount;
  final List<String> toolsets;
  final int? filesReadCount;
  final int? filesWrittenCount;
  final String? activeToolName;
  final String? activeToolPreview;
  final SubagentUsage? usage;
  final double? durationSeconds;
  final DateTime? startedAt;
  final DateTime? completedAt;

  const SubagentActivityDetails({
    this.goalPreview,
    this.detailPreview,
    this.summaryPreview,
    this.outputTailPreview,
    this.parentId,
    this.depth,
    this.model,
    this.progress,
    this.toolCount,
    this.toolsets = const [],
    this.filesReadCount,
    this.filesWrittenCount,
    this.activeToolName,
    this.activeToolPreview,
    this.usage,
    this.durationSeconds,
    this.startedAt,
    this.completedAt,
  });

  String? get resultPreview => summaryPreview ?? outputTailPreview;

  bool get isEmpty =>
      goalPreview == null &&
      detailPreview == null &&
      summaryPreview == null &&
      outputTailPreview == null &&
      parentId == null &&
      depth == null &&
      model == null &&
      progress == null &&
      toolCount == null &&
      toolsets.isEmpty &&
      filesReadCount == null &&
      filesWrittenCount == null &&
      activeToolName == null &&
      activeToolPreview == null &&
      usage == null &&
      durationSeconds == null &&
      startedAt == null &&
      completedAt == null;
}

final class SubagentActivityEvent {
  final SubagentActivityScope scope;
  final SubagentActivityEventKind kind;
  final SubagentActivitySource source;
  final SubagentActivityPhase phase;
  final String? subagentId;
  final String? delegationId;
  final String? childSessionId;
  final String? legacyToolCallId;
  final String? eventId;
  final int? eventRevision;
  final SubagentActivityDetails details;

  const SubagentActivityEvent._({
    required this.scope,
    required this.kind,
    required this.source,
    required this.phase,
    required this.details,
    this.subagentId,
    this.delegationId,
    this.childSessionId,
    this.legacyToolCallId,
    this.eventId,
    this.eventRevision,
  });

  bool get hasStableIdentity => preferredKey != null;

  SubagentActivityKey? get preferredKey {
    final identity = _preferredIdentity(
      subagentId: subagentId,
      delegationId: delegationId,
      childSessionId: childSessionId,
      legacyToolCallId: legacyToolCallId,
    );
    if (identity == null) return null;
    return SubagentActivityKey(
      scope: scope,
      identityKind: identity.$1,
      stableId: identity.$2,
    );
  }

  static SubagentActivityEvent? tryParseNative({
    required String type,
    required SubagentActivityScope scope,
    required Object? payload,
    String? eventId,
    int? eventRevision,
    String? fallbackToolCallId,
  }) {
    final json = _stringKeyedMap(payload);
    if (json == null) return null;
    final kind = switch (type) {
      'subagent.spawn_requested' => SubagentActivityEventKind.spawnRequested,
      'subagent.start' => SubagentActivityEventKind.start,
      'subagent.thinking' => SubagentActivityEventKind.thinking,
      'subagent.tool' => SubagentActivityEventKind.tool,
      'subagent.progress' => SubagentActivityEventKind.progress,
      'subagent.complete' => SubagentActivityEventKind.complete,
      _ => null,
    };
    if (kind == null) return null;

    final phase = _nativePhase(kind, json['status']);
    final parsedUsage = SubagentUsage(
      inputTokens: _nonNegativeInt(json['input_tokens']),
      outputTokens: _nonNegativeInt(json['output_tokens']),
      reasoningTokens: _nonNegativeInt(json['reasoning_tokens']),
      apiCalls: _nonNegativeInt(json['api_calls']),
      costUsd: _nonNegativeDouble(json['cost_usd']),
    );
    final taskIndex = _nonNegativeInt(json['task_index']);
    final taskCount = _positiveInt(json['task_count']);
    final progress = taskIndex == null || taskCount == null
        ? null
        : SubagentTaskProgress(taskIndex: taskIndex, taskCount: taskCount);
    final toolsets = _boundedStringList(
      json['toolsets'],
      maxItems: SubagentPayloadLimits.toolsetCount,
      maxCharacters: SubagentPayloadLimits.toolsetCharacters,
    );

    return SubagentActivityEvent._(
      scope: scope,
      kind: kind,
      source: SubagentActivitySource.native,
      phase: phase,
      subagentId: _opaqueId(json['subagent_id']),
      delegationId: _opaqueId(json['delegation_id']),
      childSessionId: _opaqueId(json['child_session_id']),
      legacyToolCallId:
          _opaqueId(json['tool_id']) ??
          _opaqueId(json['tool_call_id']) ??
          _opaqueId(json['call_id']) ??
          _opaqueId(fallbackToolCallId),
      eventId: _opaqueId(eventId) ?? _opaqueId(json['event_id']),
      eventRevision:
          _nonNegativeInt(eventRevision) ??
          _nonNegativeInt(json['event_revision']) ??
          _nonNegativeInt(json['revision']),
      details: SubagentActivityDetails(
        goalPreview: _boundedText(
          json['goal'],
          SubagentPayloadLimits.goalCharacters,
        ),
        detailPreview: _boundedText(
          json['text'],
          SubagentPayloadLimits.detailCharacters,
        ),
        summaryPreview: _boundedText(
          json['summary'],
          SubagentPayloadLimits.resultCharacters,
        ),
        outputTailPreview: _boundedText(
          json['output_tail'],
          SubagentPayloadLimits.resultCharacters,
        ),
        parentId: _opaqueId(json['parent_id']),
        depth: _nonNegativeInt(json['depth']),
        model: _boundedText(
          json['model'],
          SubagentPayloadLimits.modelCharacters,
        ),
        progress: progress,
        toolCount: _nonNegativeInt(json['tool_count']),
        toolsets: toolsets,
        filesReadCount: _redactedCollectionCount(json['files_read']),
        filesWrittenCount: _redactedCollectionCount(json['files_written']),
        activeToolName: _boundedText(
          json['tool_name'],
          SubagentPayloadLimits.toolNameCharacters,
        ),
        activeToolPreview: _boundedText(
          json['tool_preview'],
          SubagentPayloadLimits.toolPreviewCharacters,
        ),
        usage: parsedUsage.isEmpty ? null : parsedUsage,
        durationSeconds: _nonNegativeDouble(json['duration_seconds']),
        startedAt: _timestamp(json['started_at']),
        completedAt: _timestamp(json['completed_at']),
      ),
    );
  }

  static SubagentActivityEvent? tryParseLegacyDelegateTool({
    required String type,
    required SubagentActivityScope scope,
    required Object? payload,
    String? toolName,
    String? toolCallId,
    String? eventId,
    int? eventRevision,
  }) {
    final json = _stringKeyedMap(payload);
    if (json == null) return null;
    final parsedToolName =
        _boundedText(toolName, SubagentPayloadLimits.toolNameCharacters) ??
        _boundedText(
          json['tool_name'] ?? json['name'],
          SubagentPayloadLimits.toolNameCharacters,
        );
    if (parsedToolName != 'delegate_task') return null;

    final kind = switch (type) {
      'tool.start' => SubagentActivityEventKind.legacyToolStart,
      'tool.complete' => SubagentActivityEventKind.legacyToolComplete,
      _ => null,
    };
    if (kind == null) return null;

    final result = _stringKeyedMap(json['result']);
    final dispatchedSubagentIds = _boundedStringList(
      result?['subagent_ids'],
      maxItems: 64,
      maxCharacters: SubagentPayloadLimits.opaqueIdCharacters,
    );

    return SubagentActivityEvent._(
      scope: scope,
      kind: kind,
      source: SubagentActivitySource.legacyDelegateTask,
      phase: kind == SubagentActivityEventKind.legacyToolStart
          ? SubagentActivityPhase.running
          : _legacyCompletionPhase(json),
      subagentId: dispatchedSubagentIds.length == 1
          ? _opaqueId(dispatchedSubagentIds.single)
          : null,
      delegationId:
          _opaqueId(result?['delegation_id']) ??
          _opaqueId(json['delegation_id']),
      legacyToolCallId:
          _opaqueId(toolCallId) ??
          _opaqueId(json['tool_id']) ??
          _opaqueId(json['tool_call_id']) ??
          _opaqueId(json['call_id']),
      eventId: _opaqueId(eventId) ?? _opaqueId(json['event_id']),
      eventRevision:
          _nonNegativeInt(eventRevision) ??
          _nonNegativeInt(json['event_revision']) ??
          _nonNegativeInt(json['revision']),
      details: SubagentActivityDetails(
        summaryPreview: _boundedText(
          json['summary'],
          SubagentPayloadLimits.resultCharacters,
        ),
      ),
    );
  }

  @override
  String toString() =>
      'SubagentActivityEvent(kind: ${kind.name}, phase: ${phase.name}, '
      'source: ${source.name}, identified: $hasStableIdentity)';
}

final class SubagentActivity {
  final SubagentActivityKey key;
  final SubagentActivitySource source;
  final SubagentActivityPhase phase;
  final String? subagentId;
  final String? delegationId;
  final String? childSessionId;
  final String? legacyToolCallId;
  final int? eventRevision;
  final List<String> seenEventIds;
  final SubagentActivityDetails details;

  SubagentActivity({
    required this.key,
    required this.source,
    required this.phase,
    required this.details,
    this.subagentId,
    this.delegationId,
    this.childSessionId,
    this.legacyToolCallId,
    this.eventRevision,
    List<String> seenEventIds = const [],
  }) : seenEventIds = List.unmodifiable(seenEventIds);

  bool get isTerminal => phase.isTerminal;
  bool get hasNativeIdentity => subagentId != null;
  bool get canResumeChildTranscript =>
      source == SubagentActivitySource.native && childSessionId != null;

  String? get goalPreview => details.goalPreview;
  String? get resultPreview => details.resultPreview;
  SubagentTaskProgress? get progress => details.progress;
  SubagentUsage? get usage => details.usage;

  bool explicitlyMatches(SubagentActivityEvent event) {
    if (key.scope != event.scope) return false;
    if (_differentKnownId(subagentId, event.subagentId) ||
        _differentKnownId(delegationId, event.delegationId) ||
        _differentKnownId(childSessionId, event.childSessionId) ||
        _differentKnownId(legacyToolCallId, event.legacyToolCallId)) {
      return false;
    }
    return _sameKnownId(subagentId, event.subagentId) ||
        _sameKnownId(delegationId, event.delegationId) ||
        _sameKnownId(childSessionId, event.childSessionId) ||
        _sameKnownId(legacyToolCallId, event.legacyToolCallId);
  }

  @override
  String toString() =>
      'SubagentActivity(phase: ${phase.name}, source: ${source.name}, '
      'identity: ${key.identityKind.name})';
}

final class SubagentActivityState {
  final SubagentActivityScope scope;
  final Map<SubagentActivityKey, SubagentActivity> _entries;

  SubagentActivityState.empty(this.scope) : _entries = const {};

  SubagentActivityState.withEntries(
    this.scope,
    Map<SubagentActivityKey, SubagentActivity> entries,
  ) : _entries = Map.unmodifiable(entries);

  Map<SubagentActivityKey, SubagentActivity> get entries => _entries;
  Iterable<SubagentActivity> get activities => _entries.values;

  SubagentActivity? operator [](SubagentActivityKey key) => _entries[key];

  SubagentActivityState rebaseScope(SubagentActivityScope rebasedScope) {
    if (scope == rebasedScope) return this;
    if (scope.durableLineageKey != rebasedScope.durableLineageKey) {
      throw StateError('Cannot rebase subagent activity across lineages');
    }
    final rebased = <SubagentActivityKey, SubagentActivity>{};
    for (final activity in activities) {
      final key = SubagentActivityKey(
        scope: rebasedScope,
        identityKind: activity.key.identityKind,
        stableId: activity.key.stableId,
      );
      rebased[key] = SubagentActivity(
        key: key,
        source: activity.source,
        phase: activity.phase,
        subagentId: activity.subagentId,
        delegationId: activity.delegationId,
        childSessionId: activity.childSessionId,
        legacyToolCallId: activity.legacyToolCallId,
        eventRevision: activity.eventRevision,
        seenEventIds: activity.seenEventIds,
        details: activity.details,
      );
    }
    return SubagentActivityState.withEntries(rebasedScope, rebased);
  }

  @override
  String toString() => 'SubagentActivityState(count: ${_entries.length})';
}

(SubagentIdentityKind, String)? preferredSubagentIdentity({
  String? subagentId,
  String? delegationId,
  String? childSessionId,
  String? legacyToolCallId,
}) => _preferredIdentity(
  subagentId: subagentId,
  delegationId: delegationId,
  childSessionId: childSessionId,
  legacyToolCallId: legacyToolCallId,
);

(SubagentIdentityKind, String)? _preferredIdentity({
  String? subagentId,
  String? delegationId,
  String? childSessionId,
  String? legacyToolCallId,
}) {
  if (subagentId != null) {
    return (SubagentIdentityKind.subagent, subagentId);
  }
  if (delegationId != null) {
    return (SubagentIdentityKind.delegation, delegationId);
  }
  if (childSessionId != null) {
    return (SubagentIdentityKind.childSession, childSessionId);
  }
  if (legacyToolCallId != null) {
    return (SubagentIdentityKind.legacyToolCall, legacyToolCallId);
  }
  return null;
}

SubagentActivityPhase _nativePhase(
  SubagentActivityEventKind kind,
  Object? status,
) {
  final explicit = _phaseFromStatus(status);
  if (explicit?.isTerminal == true) return explicit!;
  return switch (kind) {
    SubagentActivityEventKind.spawnRequested => SubagentActivityPhase.requested,
    SubagentActivityEventKind.start => SubagentActivityPhase.running,
    SubagentActivityEventKind.thinking => SubagentActivityPhase.thinking,
    SubagentActivityEventKind.tool => SubagentActivityPhase.tool,
    SubagentActivityEventKind.progress =>
      explicit ?? SubagentActivityPhase.running,
    SubagentActivityEventKind.complete =>
      explicit ?? SubagentActivityPhase.completed,
    SubagentActivityEventKind.legacyToolStart ||
    SubagentActivityEventKind.legacyToolComplete =>
      SubagentActivityPhase.unknown,
  };
}

SubagentActivityPhase _legacyCompletionPhase(Map<String, dynamic> json) {
  if (json['success'] == false || json['error'] != null) {
    return SubagentActivityPhase.failed;
  }
  final result = _stringKeyedMap(json['result']);
  if (result != null) {
    if (result['success'] == false || result['error'] != null) {
      return SubagentActivityPhase.failed;
    }
    final resultPhase = _phaseFromStatus(result['status']);
    if (resultPhase != null) return resultPhase;
  }
  if (json['success'] == true) return SubagentActivityPhase.completed;
  final explicit = _phaseFromStatus(json['status']);
  if (explicit == SubagentActivityPhase.failed) return explicit!;
  if (explicit == SubagentActivityPhase.completed) return explicit!;
  if (json.containsKey('status')) return SubagentActivityPhase.unknown;
  return SubagentActivityPhase.completed;
}

SubagentActivityPhase? _phaseFromStatus(Object? value) {
  if (value is! String) return null;
  return switch (value.trim().toLowerCase()) {
    'requested' ||
    'pending' ||
    'queued' ||
    'dispatched' => SubagentActivityPhase.requested,
    'running' || 'active' || 'started' => SubagentActivityPhase.running,
    'thinking' || 'reasoning' => SubagentActivityPhase.thinking,
    'tool' || 'using_tool' => SubagentActivityPhase.tool,
    'completed' ||
    'complete' ||
    'success' ||
    'succeeded' ||
    'done' ||
    'ok' => SubagentActivityPhase.completed,
    'failed' || 'failure' || 'error' => SubagentActivityPhase.failed,
    'cancelled' ||
    'canceled' ||
    'interrupted' => SubagentActivityPhase.cancelled,
    'unknown' => SubagentActivityPhase.unknown,
    _ => null,
  };
}

bool _isUsableScopeId(String value) =>
    value.trim().isNotEmpty &&
    value.runes.length <= SubagentPayloadLimits.opaqueIdCharacters;

String? _opaqueId(Object? value) {
  if (value is! String || !_isUsableScopeId(value)) return null;
  return value;
}

String? _boundedText(Object? value, int maxCharacters) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final runes = trimmed.runes;
  if (runes.length <= maxCharacters) return trimmed;
  return String.fromCharCodes(runes.take(maxCharacters));
}

List<String> _boundedStringList(
  Object? value, {
  required int maxItems,
  required int maxCharacters,
}) {
  if (value is! List) return const [];
  final result = <String>[];
  for (final item in value) {
    final parsed = _boundedText(item, maxCharacters);
    if (parsed == null || result.contains(parsed)) continue;
    result.add(parsed);
    if (result.length == maxItems) break;
  }
  return List.unmodifiable(result);
}

int? _nonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  final integer = value.toInt();
  return value == integer ? integer : null;
}

int? _positiveInt(Object? value) {
  final parsed = _nonNegativeInt(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

double? _nonNegativeDouble(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  return value.toDouble();
}

int? _redactedCollectionCount(Object? value) {
  final count = _nonNegativeInt(value);
  if (count != null) return count;
  if (value is List) return value.length;
  if (value is Map) {
    final declaredCount = _nonNegativeInt(value['count']);
    return declaredCount ?? value.length;
  }
  return null;
}

DateTime? _timestamp(Object? value) {
  if (value is String) return DateTime.tryParse(value)?.toUtc();
  if (value is! num || !value.isFinite || value < 0) return null;
  try {
    return DateTime.fromMicrosecondsSinceEpoch(
      (value.toDouble() * Duration.microsecondsPerSecond).round(),
      isUtc: true,
    );
  } on RangeError {
    return null;
  }
}

Map<String, dynamic>? _stringKeyedMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}

bool _sameKnownId(String? left, String? right) =>
    left != null && right != null && left == right;

bool _differentKnownId(String? left, String? right) =>
    left != null && right != null && left != right;
