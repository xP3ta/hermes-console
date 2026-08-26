import 'agent_profile.dart';
import 'kanban.dart';
import 'session.dart';

enum MissionCapabilityState { available, unsupported, unavailable }

enum MissionAgentStatus {
  idle,
  thinking,
  working,
  responding,
  blocked,
  approvalRequired,
  error,
}

enum MissionLivePhase {
  idle,
  thinking,
  working,
  responding,
  approvalRequired,
  error,
}

enum MissionActivityKind {
  sessionUpdated,
  taskCreated,
  taskStarted,
  taskCompleted,
  taskBlocked,
}

enum MissionCostCoverage { none, partial, complete }

final class MissionOrganization {
  static final RegExp _profileName = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  final String id;
  final String connectionId;
  final String name;
  final Set<String> profileNames;
  final String? managerProfile;
  final int createdAtMs;
  final int updatedAtMs;

  factory MissionOrganization({
    required String id,
    required String connectionId,
    required String name,
    required Iterable<String> profileNames,
    String? managerProfile,
    required int createdAtMs,
    required int updatedAtMs,
  }) {
    final safeProfiles = Set<String>.unmodifiable(
      profileNames
          .map((value) => value.trim())
          .where(_profileName.hasMatch)
          .take(100),
    );
    return MissionOrganization._(
      id: id,
      connectionId: connectionId,
      name: name,
      profileNames: safeProfiles,
      managerProfile: safeProfiles.contains(managerProfile)
          ? managerProfile
          : null,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
    );
  }

  const MissionOrganization._({
    required this.id,
    required this.connectionId,
    required this.name,
    required this.profileNames,
    this.managerProfile,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  MissionOrganization copyWith({
    String? name,
    Iterable<String>? profileNames,
    String? managerProfile,
    bool clearManager = false,
    int? updatedAtMs,
  }) => MissionOrganization(
    id: id,
    connectionId: connectionId,
    name: name ?? this.name,
    profileNames: profileNames ?? this.profileNames,
    managerProfile: clearManager ? null : managerProfile ?? this.managerProfile,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'connection_id': connectionId,
    'name': name,
    'profile_names': profileNames.toList()..sort(),
    if (managerProfile != null) 'manager_profile': managerProfile,
    'created_at_ms': createdAtMs,
    'updated_at_ms': updatedAtMs,
  };

  static MissionOrganization? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _safeText(raw['id'], 128);
    final connectionId = _safeText(raw['connection_id'], 256);
    final name = _safeText(raw['name'], 64);
    final createdAt = _safeInt(raw['created_at_ms']);
    final updatedAt = _safeInt(raw['updated_at_ms']);
    if (id == null || connectionId == null || name == null) return null;
    final profiles = raw['profile_names'];
    final names = profiles is List
        ? profiles.whereType<String>().where(_profileName.hasMatch)
        : const <String>[];
    final manager = _safeText(raw['manager_profile'], 64);
    final safeManager = manager != null && names.contains(manager)
        ? manager
        : null;
    return MissionOrganization(
      id: id,
      connectionId: connectionId,
      name: name,
      profileNames: names,
      managerProfile: safeManager,
      createdAtMs: createdAt ?? 0,
      updatedAtMs: updatedAt ?? createdAt ?? 0,
    );
  }
}

final class MissionBackendSnapshot {
  final List<AgentProfile> profiles;
  final List<Session> sessions;
  final KanbanBoard? board;
  final MissionCapabilityState profilesCapability;
  final MissionCapabilityState sessionsCapability;
  final MissionCapabilityState kanbanCapability;
  final Map<String, Object> failures;
  final DateTime loadedAt;

  const MissionBackendSnapshot({
    this.profiles = const [],
    this.sessions = const [],
    this.board,
    this.profilesCapability = MissionCapabilityState.unavailable,
    this.sessionsCapability = MissionCapabilityState.unavailable,
    this.kanbanCapability = MissionCapabilityState.unavailable,
    this.failures = const {},
    required this.loadedAt,
  });

  List<KanbanTask> get tasks => List<KanbanTask>.unmodifiable(
    board?.columns.expand((column) => column.tasks) ?? const <KanbanTask>[],
  );

  /// Identidad estable del board que respalda este snapshot. Hermes legacy no
  /// publica catálogo multi-board, por lo que conserva el sentinel local que
  /// también usan los enlaces Room persistidos.
  String get currentBoardId => board?.boardId ?? 'legacy-current';
}

final class MissionLiveChat {
  final String profileName;
  final String sessionId;
  final String title;
  final MissionLivePhase phase;
  final Map<String, dynamic>? approval;
  final String? model;
  final String? provider;

  const MissionLiveChat({
    required this.profileName,
    required this.sessionId,
    required this.title,
    required this.phase,
    this.approval,
    this.model,
    this.provider,
  });
}

final class MissionUsage {
  final int? inputTokens;
  final int? outputTokens;
  final int? reasoningTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final double? estimatedCostUsd;
  final double? actualCostUsd;
  final MissionCostCoverage estimatedCostCoverage;
  final MissionCostCoverage actualCostCoverage;

  const MissionUsage({
    this.inputTokens,
    this.outputTokens,
    this.reasoningTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.estimatedCostUsd,
    this.actualCostUsd,
    this.estimatedCostCoverage = MissionCostCoverage.none,
    this.actualCostCoverage = MissionCostCoverage.none,
  });

  int? get totalTokens => inputTokens == null && outputTokens == null
      ? null
      : (inputTokens ?? 0) + (outputTokens ?? 0);

  MissionCostCoverage get costCoverage =>
      actualCostUsd != null ? actualCostCoverage : estimatedCostCoverage;

  factory MissionUsage.fromSessions(Iterable<Session> sessions) =>
      MissionUsage.fromSamples(sessions.map(MissionUsageSample.fromSession));

  factory MissionUsage.fromSamples(Iterable<MissionUsageSample> samples) {
    var input = 0;
    var output = 0;
    var reasoning = 0;
    var cacheRead = 0;
    var cacheWrite = 0;
    var cacheReadPublished = false;
    var cacheWritePublished = false;
    var estimated = 0.0;
    var actual = 0.0;
    var inputPublished = false;
    var outputPublished = false;
    var reasoningPublished = false;
    var estimatedPublished = 0;
    var actualPublished = 0;
    var count = 0;
    for (final sample in samples) {
      count++;
      final inputValue = sample.inputTokens;
      if (inputValue != null) {
        inputPublished = true;
        input += inputValue;
      }
      final outputValue = sample.outputTokens;
      if (outputValue != null) {
        outputPublished = true;
        output += outputValue;
      }
      final reasoningValue = sample.reasoningTokens;
      if (reasoningValue != null) {
        reasoningPublished = true;
        reasoning += reasoningValue;
      }
      final read = sample.cacheReadTokens;
      if (read != null) {
        cacheReadPublished = true;
        cacheRead += read;
      }
      final write = sample.cacheWriteTokens;
      if (write != null) {
        cacheWritePublished = true;
        cacheWrite += write;
      }
      final estimatedValue = sample.estimatedCostUsd;
      if (estimatedValue != null) {
        estimatedPublished++;
        estimated += estimatedValue;
      }
      final actualValue = sample.actualCostUsd;
      if (actualValue != null) {
        actualPublished++;
        actual += actualValue;
      }
    }
    return MissionUsage(
      inputTokens: inputPublished ? input : null,
      outputTokens: outputPublished ? output : null,
      reasoningTokens: reasoningPublished ? reasoning : null,
      cacheReadTokens: cacheReadPublished ? cacheRead : null,
      cacheWriteTokens: cacheWritePublished ? cacheWrite : null,
      estimatedCostUsd: estimatedPublished == 0 ? null : estimated,
      actualCostUsd: actualPublished == 0 ? null : actual,
      estimatedCostCoverage: _coverage(estimatedPublished, count),
      actualCostCoverage: _coverage(actualPublished, count),
    );
  }
}

/// Nullable usage fields before aggregation.
///
/// [Session] predates presence-aware core token fields, so its zero values are
/// ambiguous when every usage field is empty. This compatibility factory is
/// conservative in that case. Callers that still know response-key presence
/// can pass [tokenFieldsPublished], or construct a sample directly, to retain
/// a server-published all-zero record.
final class MissionUsageSample {
  final int? inputTokens;
  final int? outputTokens;
  final int? reasoningTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final double? estimatedCostUsd;
  final double? actualCostUsd;

  const MissionUsageSample({
    this.inputTokens,
    this.outputTokens,
    this.reasoningTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.estimatedCostUsd,
    this.actualCostUsd,
  });

  factory MissionUsageSample.fromSession(
    Session session, {
    bool? tokenFieldsPublished,
  }) {
    final inputPublished =
        tokenFieldsPublished ??
        session.inputTokensPublished || session.inputTokens > 0;
    final outputPublished =
        tokenFieldsPublished ??
        session.outputTokensPublished || session.outputTokens > 0;
    final reasoningPublished =
        tokenFieldsPublished ??
        session.reasoningTokensPublished || session.reasoningTokens > 0;
    return MissionUsageSample(
      inputTokens: inputPublished ? session.inputTokens : null,
      outputTokens: outputPublished ? session.outputTokens : null,
      reasoningTokens: reasoningPublished ? session.reasoningTokens : null,
      cacheReadTokens: session.cacheReadTokens,
      cacheWriteTokens: session.cacheWriteTokens,
      estimatedCostUsd: session.estimatedCostUsd,
      actualCostUsd: session.actualCostUsd,
    );
  }
}

final class MissionApproval {
  final String profileName;
  final String sessionId;
  final String sessionTitle;
  final String? requestId;
  final String description;
  final String? risk;

  const MissionApproval({
    required this.profileName,
    required this.sessionId,
    required this.sessionTitle,
    this.requestId,
    required this.description,
    this.risk,
  });

  factory MissionApproval.fromLiveChat(MissionLiveChat chat) {
    final raw = chat.approval ?? const <String, dynamic>{};
    return MissionApproval(
      profileName: chat.profileName,
      sessionId: chat.sessionId,
      sessionTitle: chat.title,
      requestId: _safeText(
        raw['request_id'] ?? raw['approval_id'] ?? raw['id'],
        256,
      ),
      description:
          _safeText(raw['description'] ?? raw['tool'] ?? raw['command'], 240) ??
          'Approval requested',
      risk: _safeText(raw['risk'], 32),
    );
  }
}

final class MissionActivity {
  final String stableId;
  final String? profileName;
  final MissionActivityKind kind;
  final DateTime timestamp;
  final String title;
  final String sourceId;

  const MissionActivity({
    required this.stableId,
    this.profileName,
    required this.kind,
    required this.timestamp,
    required this.title,
    required this.sourceId,
  });
}

final class MissionAgent {
  final AgentProfile profile;
  final MissionAgentStatus status;
  final String statusEvidence;
  final Session? currentSession;
  final KanbanTask? currentTask;
  final MissionUsage usage;
  final MissionApproval? approval;
  final DateTime? lastActivityAt;
  final String? model;
  final String? provider;

  const MissionAgent({
    required this.profile,
    required this.status,
    required this.statusEvidence,
    this.currentSession,
    this.currentTask,
    required this.usage,
    this.approval,
    this.lastActivityAt,
    this.model,
    this.provider,
  });
}

final class MissionProjection {
  final List<MissionAgent> agents;
  final List<KanbanTask> tasks;
  final List<MissionActivity> activity;
  final List<MissionApproval> approvals;
  final MissionUsage usage;
  final int missingProfileCount;
  final int unattributedSessionCount;

  const MissionProjection({
    this.agents = const [],
    this.tasks = const [],
    this.activity = const [],
    this.approvals = const [],
    this.usage = const MissionUsage(),
    this.missingProfileCount = 0,
    this.unattributedSessionCount = 0,
  });

  int get workingCount => agents
      .where(
        (agent) => const {
          MissionAgentStatus.thinking,
          MissionAgentStatus.working,
          MissionAgentStatus.responding,
        }.contains(agent.status),
      )
      .length;

  int get blockedCount => agents
      .where((agent) => agent.status == MissionAgentStatus.blocked)
      .length;
}

abstract final class MissionProjector {
  static MissionProjection build({
    required MissionBackendSnapshot snapshot,
    Iterable<MissionLiveChat> liveChats = const [],
    MissionOrganization? organization,
    int activityLimit = 80,
    DateTime? now,
  }) {
    final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000.0;
    final liveChatList = liveChats.toList(growable: false);
    final profileScope = organization?.profileNames;
    final profiles = snapshot.profiles
        .where(
          (profile) =>
              profileScope == null || profileScope.contains(profile.name),
        )
        .toList(growable: false);
    final existingNames = snapshot.profiles
        .map((profile) => profile.name)
        .toSet();
    final missing = profileScope == null
        ? 0
        : profileScope.where((name) => !existingNames.contains(name)).length;
    final sessionsByProfile = <String, List<Session>>{};
    final sessionOwners = <Session, String?>{};
    final scopedSessions = <Session>[];
    var unattributedSessionCount = 0;
    for (final session in snapshot.sessions) {
      final owner = _sessionOwner(session, liveChatList, snapshot.profiles);
      sessionOwners[session] = owner;
      if (owner == null) {
        if (profileScope == null) {
          scopedSessions.add(session);
          unattributedSessionCount++;
        }
        continue;
      }
      if (profileScope != null && !profileScope.contains(owner)) continue;
      sessionsByProfile.putIfAbsent(owner, () => []).add(session);
      scopedSessions.add(session);
    }
    for (final sessions in sessionsByProfile.values) {
      sessions.sort(
        (left, right) => right.lastActivityAt.compareTo(left.lastActivityAt),
      );
    }
    final tasks = snapshot.tasks
        .where(
          (task) =>
              profileScope == null ||
              (task.assignee != null && profileScope.contains(task.assignee)),
        )
        .toList(growable: false);
    final tasksByProfile = <String, List<KanbanTask>>{};
    for (final task in tasks) {
      final assignee = task.assignee;
      if (assignee == null || assignee.isEmpty) continue;
      tasksByProfile.putIfAbsent(assignee, () => []).add(task);
    }
    final liveByProfile = <String, List<MissionLiveChat>>{};
    final scopedLiveChats = <MissionLiveChat>[];
    for (final chat in liveChatList) {
      if (profileScope != null && !profileScope.contains(chat.profileName)) {
        continue;
      }
      scopedLiveChats.add(chat);
      liveByProfile.putIfAbsent(chat.profileName, () => []).add(chat);
    }

    final agents = <MissionAgent>[];
    final approvals = <MissionApproval>[];
    final approvalSessions = <String>{};
    for (final liveChat in scopedLiveChats) {
      if (liveChat.approval == null) continue;
      final identity = '${liveChat.profileName}\u0000${liveChat.sessionId}';
      if (approvalSessions.add(identity)) {
        approvals.add(MissionApproval.fromLiveChat(liveChat));
      }
    }
    for (final profile in profiles) {
      final sessions = sessionsByProfile[profile.name] ?? const <Session>[];
      final profileTasks = tasksByProfile[profile.name] ?? const <KanbanTask>[];
      final chats = liveByProfile[profile.name] ?? const <MissionLiveChat>[];
      final chat = _preferredChat(chats);
      final task = _preferredTask(profileTasks);
      final approval = chat?.approval == null
          ? null
          : MissionApproval.fromLiveChat(chat!);
      final worker = _freshWorker(profile.workerSession, nowSeconds);
      final status = _status(chat, task, worker);
      final sessionActivitySeconds = sessions.isEmpty
          ? null
          : sessions.first.lastActivityAt;
      final lastActivitySeconds = worker == null
          ? sessionActivitySeconds
          : sessionActivitySeconds == null ||
                worker.lastActive > sessionActivitySeconds
          ? worker.lastActive
          : sessionActivitySeconds;
      final currentSession =
          _pinnedBotChat(profile) ??
          _sessionForChat(sessions, chat) ??
          (sessions.isEmpty ? null : sessions.first);
      agents.add(
        MissionAgent(
          profile: profile,
          status: status,
          statusEvidence: _statusEvidence(status, chat, task, worker),
          currentSession: currentSession,
          currentTask: task,
          usage: MissionUsage.fromSessions(sessions),
          approval: approval,
          lastActivityAt: lastActivitySeconds == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (lastActivitySeconds * 1000).round(),
                ),
          model: _firstNonEmpty([
            chat?.model,
            task?.modelOverride,
            currentSession?.model,
            profile.model,
          ]),
          provider: _firstNonEmpty([
            chat?.provider,
            task?.providerOverride,
            profile.provider,
          ]),
        ),
      );
    }
    agents.sort((left, right) {
      final priority = _statusPriority(
        left.status,
      ).compareTo(_statusPriority(right.status));
      return priority != 0
          ? priority
          : left.profile.name.compareTo(right.profile.name);
    });
    return MissionProjection(
      agents: List.unmodifiable(agents),
      tasks: List.unmodifiable(tasks),
      activity: _activity(scopedSessions, tasks, activityLimit, sessionOwners),
      approvals: List.unmodifiable(approvals),
      usage: MissionUsage.fromSessions(scopedSessions),
      missingProfileCount: missing,
      unattributedSessionCount: unattributedSessionCount,
    );
  }

  static Session? _pinnedBotChat(AgentProfile profile) {
    final id = profile.botChatSessionId;
    if (id == null || id.isEmpty) return null;
    return Session(
      id: id,
      title: 'Bot Chat',
      model: profile.model.isEmpty ? 'hermes-agent' : profile.model,
      source: 'bot-mode',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: 0,
      profile: profile.name,
      isDefaultProfile: profile.isDefault,
    );
  }

  static String? _sessionOwner(
    Session session,
    List<MissionLiveChat> liveChats,
    List<AgentProfile> profiles,
  ) {
    final explicit = session.profile?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final liveOwners = liveChats
        .where(
          (chat) =>
              chat.sessionId == session.id ||
              chat.sessionId == session.logicalId,
        )
        .map((chat) => chat.profileName)
        .where((name) => name.isNotEmpty)
        .toSet();
    if (liveOwners.length == 1) return liveOwners.single;
    if (session.isDefaultProfile == true) {
      final defaults = profiles
          .where((profile) => profile.isDefault || profile.name == 'default')
          .toList(growable: false);
      if (defaults.length == 1) return defaults.single.name;
    }
    return profiles.length == 1 ? profiles.single.name : null;
  }

  static MissionLiveChat? _preferredChat(List<MissionLiveChat> chats) {
    if (chats.isEmpty) return null;
    final copy = [...chats]
      ..sort(
        (left, right) =>
            _livePriority(left.phase).compareTo(_livePriority(right.phase)),
      );
    return copy.first;
  }

  static KanbanTask? _preferredTask(List<KanbanTask> tasks) {
    if (tasks.isEmpty) return null;
    final copy = [...tasks]
      ..sort((left, right) {
        final priority = _taskPriority(
          left.status,
        ).compareTo(_taskPriority(right.status));
        if (priority != 0) return priority;
        return (right.startedAt ?? right.createdAt ?? 0).compareTo(
          left.startedAt ?? left.createdAt ?? 0,
        );
      });
    return copy.first;
  }

  static AgentProfileWorkerSession? _freshWorker(
    AgentProfileWorkerSession? worker,
    double nowSeconds,
  ) {
    if (worker == null) return null;
    final age = nowSeconds - worker.lastActive;
    return age >= -60 && age <= 150 ? worker : null;
  }

  static MissionAgentStatus _status(
    MissionLiveChat? chat,
    KanbanTask? task,
    AgentProfileWorkerSession? worker,
  ) {
    if (chat?.phase == MissionLivePhase.approvalRequired) {
      return MissionAgentStatus.approvalRequired;
    }
    if (chat?.phase == MissionLivePhase.error) return MissionAgentStatus.error;
    if (worker != null) return MissionAgentStatus.working;
    if (task?.status == 'blocked') return MissionAgentStatus.blocked;
    if (chat != null) {
      switch (chat.phase) {
        case MissionLivePhase.thinking:
          return MissionAgentStatus.thinking;
        case MissionLivePhase.working:
          return MissionAgentStatus.working;
        case MissionLivePhase.responding:
          return MissionAgentStatus.responding;
        case MissionLivePhase.idle:
        case MissionLivePhase.approvalRequired:
        case MissionLivePhase.error:
          break;
      }
    }
    if (task?.status == 'running') return MissionAgentStatus.working;
    return MissionAgentStatus.idle;
  }

  static String _statusEvidence(
    MissionAgentStatus status,
    MissionLiveChat? chat,
    KanbanTask? task,
    AgentProfileWorkerSession? worker,
  ) => switch (status) {
    MissionAgentStatus.approvalRequired =>
      'approval.request:${chat?.sessionId ?? ''}',
    MissionAgentStatus.error => 'chat.failed:${chat?.sessionId ?? ''}',
    MissionAgentStatus.blocked => 'kanban.blocked:${task?.id ?? ''}',
    MissionAgentStatus.thinking => 'chat.thinking:${chat?.sessionId ?? ''}',
    MissionAgentStatus.working when chat?.phase == MissionLivePhase.working =>
      'chat.tool:${chat!.sessionId}',
    MissionAgentStatus.working when task?.status == 'running' =>
      'kanban.running:${task!.id}',
    MissionAgentStatus.working =>
      'worker.${worker?.source ?? 'unknown'}:${worker?.id ?? ''}',
    MissionAgentStatus.responding => 'chat.responding:${chat?.sessionId ?? ''}',
    MissionAgentStatus.idle => 'no-live-evidence',
  };

  static Session? _sessionForChat(
    List<Session> sessions,
    MissionLiveChat? chat,
  ) {
    if (chat == null) return null;
    for (final session in sessions) {
      if (session.id == chat.sessionId || session.logicalId == chat.sessionId) {
        return session;
      }
    }
    return null;
  }

  static List<MissionActivity> _activity(
    Iterable<Session> sessions,
    Iterable<KanbanTask> tasks,
    int limit,
    Map<Session, String?> sessionOwners,
  ) {
    final events = <MissionActivity>[];
    for (final session in sessions) {
      final seconds = session.updatedAt ?? session.startedAt;
      if (seconds <= 0) continue;
      events.add(
        MissionActivity(
          stableId: 'session:${session.id}:$seconds',
          profileName: sessionOwners[session],
          kind: MissionActivityKind.sessionUpdated,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            (seconds * 1000).round(),
          ),
          title: session.displayTitle,
          sourceId: session.id,
        ),
      );
    }
    for (final task in tasks) {
      void add(MissionActivityKind kind, int? seconds, String suffix) {
        if (seconds == null || seconds <= 0) return;
        events.add(
          MissionActivity(
            stableId: 'task:${task.id}:$suffix:$seconds',
            profileName: task.assignee,
            kind: kind,
            timestamp: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
            title: task.title,
            sourceId: task.id,
          ),
        );
      }

      add(MissionActivityKind.taskCreated, task.createdAt, 'created');
      add(MissionActivityKind.taskStarted, task.startedAt, 'started');
      add(MissionActivityKind.taskCompleted, task.completedAt, 'completed');
    }
    events.sort((left, right) => right.timestamp.compareTo(left.timestamp));
    final seen = <String>{};
    return List.unmodifiable(
      events
          .where((event) => seen.add(event.stableId))
          .take(limit.clamp(1, 200)),
    );
  }

  static int _livePriority(MissionLivePhase phase) => switch (phase) {
    MissionLivePhase.approvalRequired => 0,
    MissionLivePhase.error => 1,
    MissionLivePhase.working => 2,
    MissionLivePhase.responding => 3,
    MissionLivePhase.thinking => 4,
    MissionLivePhase.idle => 5,
  };

  static int _taskPriority(String status) => switch (status) {
    'running' => 0,
    'blocked' => 1,
    'review' => 2,
    'ready' => 3,
    'scheduled' => 4,
    'todo' => 5,
    'triage' => 6,
    'done' => 7,
    _ => 8,
  };

  static int _statusPriority(MissionAgentStatus status) => switch (status) {
    MissionAgentStatus.approvalRequired => 0,
    MissionAgentStatus.error => 1,
    MissionAgentStatus.blocked => 2,
    MissionAgentStatus.working => 3,
    MissionAgentStatus.responding => 4,
    MissionAgentStatus.thinking => 5,
    MissionAgentStatus.idle => 6,
  };
}

MissionCostCoverage _coverage(int published, int total) => published == 0
    ? MissionCostCoverage.none
    : published == total
    ? MissionCostCoverage.complete
    : MissionCostCoverage.partial;

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final safe = value?.trim();
    if (safe != null && safe.isNotEmpty) return safe;
  }
  return null;
}

String? _safeText(Object? value, int maxRunes) {
  if (value is! String) return null;
  final safe = String.fromCharCodes(
    value.runes.take(maxRunes),
  ).replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ').trim();
  return safe.isEmpty ? null : safe;
}

int? _safeInt(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  return value.toInt();
}
