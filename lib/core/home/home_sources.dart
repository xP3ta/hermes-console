import '../bots/state/attention.dart';
import '../bots/ui/roster/dots_home_model.dart';
import '../design/schedule_model.dart';
import '../models/agent_profile.dart';
import '../models/cron_job.dart';
import '../models/desktop_active_session.dart';
import '../models/hosted_groups.dart';
import '../models/interactive_prompt.dart';
import '../models/kanban.dart';
import '../models/mission_control.dart';
import '../models/session.dart' show Session;
import '../models/session_live_status.dart';
import '../models/tool_label.dart';
import '../services/active_chat_service.dart';
import '../services/approval_policy.dart';
import '../services/interactive_prompt_reducer.dart';
import '../bots/state/bot_presence.dart';
import '../bots/ui/room/room_models.dart';
import '../utils/home_recent_sessions.dart' show humanReadableSessionPreview;
import '../utils/session_title.dart';
import '../../l10n/app_localizations.dart';
import 'board/home_board_data.dart';
import 'home_now.dart';

/// What a chat is doing right now, in the words Home shows beside it: the
/// tool it runs, its subagents, its background work. Null while it only
/// thinks or writes (the widgets then say it is working).
///
/// The one place Home turns a live status into words; the tool phrases of
/// every widget change here.
String? homeStepLabel(Strings s, SessionLiveStatus status) =>
    switch (status.phase) {
      SessionLivePhase.runningTool =>
        status.toolIsSkill
            ? status.toolLabel
            : homeToolLabel(s, status.toolLabel, detail: status.toolDetail),
      SessionLivePhase.delegated => s.hwStepSubagents(
        status.subagentCount < 1 ? 1 : status.subagentCount,
      ),
      SessionLivePhase.background => s.hwStepBackground,
      SessionLivePhase.compacting => s.liveCompacting,
      _ => null,
    };

/// How Home names a running tool.
String? homeToolLabel(Strings s, String? tool, {String? detail}) {
  final name = tool?.trim() ?? '';
  return name.isEmpty
      ? null
      : toolOrSkillStepTitle(s, name, running: true, detail: detail);
}

/// Adapters from what Console already holds to the [HomeNow] inputs. Each
/// one only reads; the opaque refs carry what the screen needs to act.

/// Ref of a chat approval: the attached chat that owns the request. The
/// screen answers it with that chat's own [ActiveChat.resolveApproval].
final class HomeChatApprovalRef {
  final ActiveChat chat;
  final Map<String, dynamic> request;
  const HomeChatApprovalRef(this.chat, this.request);

  /// Answers [request] only while it is still the chat's pending one: the
  /// card the user read must be the request that gets answered.
  Future<void> resolve(String choice) {
    if (!identical(chat.pendingApproval, request)) {
      return Future<void>.error(StateError('The approval changed'));
    }
    return chat.resolveApproval(choice);
  }
}

/// Ref of a question: the attached chat that asked it. The screen answers
/// it with that chat's own [ActiveChat.respondToClarify].
final class HomeChatQuestionRef {
  final ActiveChat chat;
  final InteractivePromptKey prompt;
  const HomeChatQuestionRef(this.chat, this.prompt);

  /// Answers only while the question is still the one the chat waits on.
  Future<void> answer(String choice) {
    if (chat.pendingInteractivePrompt?.key != prompt) {
      return Future<void>.error(StateError('The question changed'));
    }
    return chat.respondToClarify(prompt, choice);
  }
}

/// Ref of a hosted-room approval: answered with the existing pooled
/// `groups.approve` ([pooledRoomApprove]) for the exact request.
final class HomeRoomApprovalRef {
  final HostedGroupRoom room;
  final RoomApprovalAction action;
  const HomeRoomApprovalRef(this.room, this.action);
}

String _commandOf(Map<String, dynamic> request) {
  for (final key in const ['command', 'description', 'tool']) {
    final value = request[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return '';
}

String? _requestId(Map<String, dynamic> request) {
  final value = (request['request_id'] ?? request['approval_id'])
      ?.toString()
      .trim();
  return value == null || value.isEmpty ? null : value;
}

/// Pending approvals of the attached [chats] (one per chat). [chatKey] maps
/// a chat to the Home recent it belongs to (null when it is not a recent),
/// [actorOf] names the bot of a non-main chat.
List<HomeApprovalItem> homeChatApprovals(
  Iterable<ActiveChat> chats, {
  required String? Function(ActiveChat chat) chatKey,
  required String Function(ActiveChat chat) whereOf,
  String? Function(ActiveChat chat)? actorOf,
  bool readOnly = false,
}) {
  final items = <HomeApprovalItem>[];
  for (final chat in chats) {
    final request = chat.pendingApproval;
    if (request == null) continue;
    final id = _requestId(request);
    if (id == null) continue;
    final permitted = permittedApprovalChoices(request);
    items.add(
      HomeApprovalItem(
        key: 'chat:${chat.sessionId}:$id',
        sessionKey: chatKey(chat),
        where: whereOf(chat),
        actor: actorOf?.call(chat),
        profileName: Session.profileOwner(chat.sessionProfile),
        command: _commandOf(request),
        canAllow: !readOnly && permitted.contains(ApprovalScope.once.wire),
        canDeny: !readOnly && permitted.contains(ApprovalScope.deny.wire),
        ref: HomeChatApprovalRef(chat, request),
      ),
    );
  }
  return items;
}

/// Questions the attached [chats] wait on (one per chat): a clarify prompt
/// with one question. Its choices are offered only when Home can send one
/// as it is (a single-choice question, not [readOnly]); a batch of
/// questions, a password or a secret is answered in the chat.
List<HomeQuestionItem> homeChatQuestions(
  Iterable<ActiveChat> chats, {
  required String? Function(ActiveChat chat) chatKey,
  required String Function(ActiveChat chat) whereOf,
  String? Function(ActiveChat chat)? actorOf,
  bool readOnly = false,

  /// The prompt a chat waits on (its own pending one).
  InteractivePromptEntry? Function(ActiveChat chat)? promptOf,
}) {
  final items = <HomeQuestionItem>[];
  for (final chat in chats) {
    final entry = promptOf == null
        ? chat.pendingInteractivePrompt
        : promptOf(chat);
    final request = entry?.request;
    if (entry == null || request is! ClarifyPromptRequest) continue;
    if (request.isBatch) continue;
    final question = request.question.trim();
    if (question.isEmpty) continue;
    items.add(
      HomeQuestionItem(
        key: 'chat:${chat.sessionId}:${entry.key.requestId}',
        sessionKey: chatKey(chat),
        where: whereOf(chat),
        actor: actorOf?.call(chat),
        profileName: Session.profileOwner(chat.sessionProfile),
        question: question,
        choices: readOnly || request.multiSelect
            ? const []
            : [
                for (final choice in request.choices)
                  if (choice.trim().isNotEmpty) choice,
              ],
        ref: HomeChatQuestionRef(chat, entry.key),
      ),
    );
  }
  return items;
}

/// Hosted-room approvals of the Bots [attention] (the same source as the
/// Bots home).
List<HomeApprovalItem> homeRoomApprovals(
  HostedGroupsSnapshot groups,
  AttentionSummary attention, {
  String Function(HostedGroupRoom room)? titleOf,
  bool readOnly = false,
}) {
  final items = <HomeApprovalItem>[];
  for (final room in groups.rooms) {
    if (room.disbanded) continue;
    for (final item in attention.room(room.roomId)?.items ?? const []) {
      final action = item.approval;
      if (item.kind != AttentionKind.approval || action == null) continue;
      final member = room.members
          .where((m) => m.memberId == action.memberId)
          .firstOrNull;
      final actor = member?.displayName?.trim();
      items.add(
        HomeApprovalItem(
          key: 'room:${room.roomId}:${action.requestId}',
          roomKey: room.roomId,
          where: titleOf?.call(room) ?? room.name,
          actor: actor == null || actor.isEmpty ? member?.handle : actor,
          profileName: member?.owner.profile,
          command: (action.command ?? action.description ?? '').trim(),
          canAllow: !readOnly && action.offers(ApprovalScope.once.wire),
          canDeny: !readOnly && action.offers(ApprovalScope.deny.wire),
          ref: HomeRoomApprovalRef(room, action),
        ),
      );
    }
  }
  return items;
}

/// Rooms with member messages after the sequence this device last saw.
/// A room never opened here has no mark, so it never counts as news.
List<HomeRoomNews> homeRoomNews(
  HostedGroupsSnapshot groups, {
  required RoomAttentionAcks Function(HostedGroupRoom room) acksFor,
  String Function(HostedGroupRoom room)? titleOf,
}) {
  final news = <HomeRoomNews>[];
  for (final room in groups.rooms) {
    if (room.disbanded) continue;
    final seen = acksFor(room).seenSeq;
    if (seen == null) continue;
    var count = 0;
    HostedGroupEvent? last;
    for (final log in groups.logs) {
      for (final event in log.events) {
        if (event.roomId != room.roomId ||
            event.kind != 'message.member' ||
            event.sequence <= seen) {
          continue;
        }
        count++;
        if (last == null || event.sequence > last.sequence) last = event;
      }
    }
    if (count == 0) continue;
    news.add(
      HomeRoomNews(
        key: room.roomId,
        title: titleOf?.call(room) ?? room.name,
        count: count,
        at: last == null ? null : _eventTime(last.createdAt),
        ref: room,
      ),
    );
  }
  return news;
}

DateTime _eventTime(num raw) {
  // Gateway timestamps are epoch seconds; tolerate milliseconds.
  final ms = raw > 1e12 ? raw.toDouble() : raw * 1000;
  return DateTime.fromMillisecondsSinceEpoch(ms.round());
}

/// Every bot other than the main one (and not hidden), with the state of
/// its canonical Bot Chat derived exactly as the Bots home does
/// ([MissionProjector] → `botChatPresence`): the bot's attached chats,
/// else its `session.active_list` row. Idle bots are listed too (the
/// Equipo widget shows them dimmed).
///
/// [sessions] (the Bots read's own list, when Home has one) tells the last
/// chat each bot worked on and when.
///
/// [strings] localizes the title of that last chat: a session the server
/// leaves untitled (a cron run, a Kanban worker) falls back to a generic
/// name, and [Session.displayTitle] spells it in Spanish — an English or
/// Portuguese screen would show «Tarea programada».
List<HomeBoardBot> homeBoardBots({
  required List<AgentProfile> profiles,
  required List<DesktopActiveSession> activeSessions,
  required List<MissionLiveChat> liveChats,
  required DateTime now,
  DateTime? observedAt,
  List<Session> sessions = const [],
  DateTime? Function(String sessionId, String profile)? turnStartedAtOf,
  Strings? strings,
}) {
  if (profiles.isEmpty) return const [];
  final projection = MissionProjector.build(
    snapshot: MissionBackendSnapshot(
      profiles: profiles,
      sessions: sessions,
      activeSessions: activeSessions,
      activeSessionsObservedAt: observedAt,
      loadedAt: now,
    ),
    liveChats: liveChats,
    now: now,
  );
  final bots = <HomeBoardBot>[];
  for (final agent in projection.agents) {
    final profile = agent.profile;
    if (isMainBot(profile) || profile.botHidden) continue;
    final state = switch (agent.botChatPresence) {
      BotPresence.attention => HomeBotState.waiting,
      BotPresence.working || BotPresence.thinking => HomeBotState.working,
      BotPresence.idle => HomeBotState.idle,
    };
    final title = profile.botTitle?.trim();
    final current = agent.currentSession;
    final reply = current?.lastAssistantPreview;
    DateTime? since;
    if (state == HomeBotState.working) {
      final ids = BotPresence.botChatIds(profile);
      for (final id in ids) {
        since = turnStartedAtOf?.call(id, profile.name);
        if (since != null) break;
      }
    }
    final last = _lastWork(profile, sessions, strings);
    bots.add(
      HomeBoardBot(
        profileName: profile.name,
        displayName: title == null || title.isEmpty ? profile.name : title,
        profile: profile,
        state: state,
        step: state == HomeBotState.idle ? null : agent.botChatTitle,
        since: since,
        lastReply: humanReadableSessionPreview(reply),
        lastTitle: last?.$1,
        lastAt: last?.$2,
      ),
    );
  }
  return bots;
}

/// The last thing [profile] worked on and when, from the Bots read's own
/// list: its newest chat. A task chat goes by its title; its one Bot Chat,
/// whose title never changes, by the last thing it said.
(String, DateTime)? _lastWork(
  AgentProfile profile,
  List<Session> sessions, [
  Strings? strings,
]) {
  Session? newest;
  for (final session in sessions) {
    if (session.profile?.trim() != profile.name) continue;
    if (newest == null || session.lastActivityAt > newest.lastActivityAt) {
      newest = session;
    }
  }
  if (newest == null || newest.lastActivityAt <= 0) return null;
  final ids = BotPresence.botChatIds(profile);
  final botChat = ids.contains(newest.id) || ids.contains(newest.logicalId);
  final said = humanReadableSessionPreview(newest.lastAssistantPreview);
  final title =
      (strings == null
              ? newest.displayTitle
              : localizedSessionTitle(strings, newest))
          .trim();
  final text = botChat ? (said ?? title) : (title.isEmpty ? said : title);
  if (text == null || text.isEmpty) return null;
  return (
    text.split('\n').first.trim(),
    DateTime.fromMillisecondsSinceEpoch((newest.lastActivityAt * 1000).round()),
  );
}

/// Rooms of the Bots read as Sala widgets see them: the newest public
/// lines, who replies in the current round and how many member messages
/// arrived after the sequence this device last saw.
List<HomeBoardRoom> homeBoardRooms(
  HostedGroupsSnapshot groups, {
  required RoomAttentionAcks Function(HostedGroupRoom room) acksFor,
  String Function(HostedGroupRoom room)? titleOf,
  DateTime? now,
  AttentionSummary? attention,
}) {
  final rooms = <HomeBoardRoom>[];
  for (final room in groups.rooms) {
    if (room.disbanded) continue;
    final events = <HostedGroupEvent>[
      for (final log in groups.logs)
        for (final event in log.events)
          if (event.roomId == room.roomId) event,
    ]..sort((a, b) => a.sequence.compareTo(b.sequence));
    final seen = acksFor(room).seenSeq;
    var unread = 0;
    if (seen != null) {
      for (final event in events) {
        if (event.kind == 'message.member' && event.sequence > seen) unread++;
      }
    }
    String nameOf(HostedGroupMember m) {
      final d = m.displayName?.trim();
      return d == null || d.isEmpty ? m.handle : d;
    }

    final lines = <HomeBoardRoomLine>[];
    DateTime? lastAt;
    for (final event in events.reversed) {
      if (lines.length >= 3) break;
      final text = event.publicText?.trim();
      if (text == null || text.isEmpty) continue;
      if (event.kind == 'message.member' || event.kind == 'message.user') {
        lastAt ??= _eventTime(event.createdAt);
      }
      if (event.kind == 'message.member') {
        final member = room.members
            .where((m) => m.memberId == event.actor.id)
            .firstOrNull;
        lines.add(
          HomeBoardRoomLine(
            author: member == null
                ? (event.actor.displayName ?? event.actor.id)
                : nameOf(member),
            profileName: member?.owner.profile ?? event.actor.profile,
            text: humanReadableSessionPreview(text) ?? text,
          ),
        );
      } else if (event.kind == 'message.user') {
        lines.add(
          HomeBoardRoomLine(
            author: '',
            text: humanReadableSessionPreview(text) ?? text,
          ),
        );
      }
    }
    // Replies addressed to the user and failed turns: the same attention
    // the Bots needs-you dot counts (acks already applied).
    var mentions = 0;
    final failed = <String>[];
    for (final item in attention?.room(room.roomId)?.items ?? const []) {
      switch (item.kind) {
        case AttentionKind.mention:
          mentions++;
        case AttentionKind.failedTurn || AttentionKind.retry:
          final member = room.members
              .where((m) => m.memberId == item.memberId)
              .firstOrNull;
          final name = member == null ? null : nameOf(member);
          if (name != null && !failed.contains(name)) failed.add(name);
        case AttentionKind.approval:
          break;
      }
    }
    final round = deriveRoomRound(
      events: events,
      members: room.members,
      driverStatus: groups.driverStatusFor(room.roomId),
      now: now,
    );
    final working = [
      for (final row in round?.rows ?? const <RoomRoundRow>[])
        if (row.state == RoomTurnState.working) row,
    ];
    final next = (round?.rows ?? const <RoomRoundRow>[])
        .where((r) => r.state == RoomTurnState.queued && r.queuePosition == 1)
        .firstOrNull;
    rooms.add(
      HomeBoardRoom(
        key: room.roomId,
        title: titleOf?.call(room) ?? room.name,
        unread: unread,
        mentions: mentions,
        failed: List.unmodifiable(failed),
        lines: List.unmodifiable(lines.reversed),
        responding: [for (final row in working) nameOf(row.member)],
        respondingProfiles: [
          for (final row in working) row.member.owner.profile,
        ],
        respondingSince: working.firstOrNull?.since,
        next: next == null ? null : nameOf(next.member),
        lastAt: lastAt,
        memberProfiles: [for (final m in room.members) m.owner.profile],
      ),
    );
  }
  return rooms;
}

/// Cron jobs as automations. A job whose last run failed (state `error`
/// or `last_status` error/failed) is red; paused jobs have no next run.
List<HomeAutomation> homeAutomations(
  List<CronJob> jobs, {
  required DateTime? Function(Object? raw) parseTime,
}) => [
  for (final job in jobs)
    HomeAutomation(
      key: job.id,
      name: job.title,
      enabled: job.enabled && !job.isPaused,
      failed: _failed(job),
      nextRun: job.isPaused ? null : parseTime(job.nextRunAt),
      lastRunAt: parseTime(job.lastRunAt),
      lastRunOk: _failed(job) ? false : (job.lastStatus.isEmpty ? null : true),
      everyMinutes: _everyMinutes(job),
      ref: job,
    ),
];

int? _everyMinutes(CronJob job) {
  final expression = job.scheduleExpression.trim();
  if (expression.isEmpty) return null;
  final schedule = HermesSchedule.parse(expression);
  return schedule.mode == HermesScheduleMode.interval &&
          schedule.intervalMinutes > 0
      ? schedule.intervalMinutes
      : null;
}

/// The Kanban board as «Tareas» shows it, with the same groups as the
/// Tasks list: what runs; then what needs the user (blocked, in review),
/// what is queued for someone and the notes without assignee. Done and
/// archived cards are not Home's.
HomeTasks homeTasks(KanbanBoard board) {
  final running = <HomeTaskItem>[];
  final attention = <HomeTaskItem>[];
  final queued = <HomeTaskItem>[];
  final notes = <HomeTaskItem>[];
  for (final column in board.columns) {
    for (final task in column.tasks) {
      final group = kanbanMobileGroupFor(task);
      final assignee = task.assignee?.trim();
      final item = HomeTaskItem(
        key: task.id,
        title: task.title.trim().isEmpty ? task.id : task.title.trim(),
        assignee: assignee == null || assignee.isEmpty ? null : assignee,
        attention: group == KanbanMobileGroup.attention,
        ref: task,
      );
      switch (group) {
        case KanbanMobileGroup.working:
          running.add(item);
        case KanbanMobileGroup.attention:
          attention.add(item);
        case KanbanMobileGroup.queued:
          queued.add(item);
        case KanbanMobileGroup.notes:
          notes.add(item);
        case KanbanMobileGroup.done || KanbanMobileGroup.archived:
          break;
      }
    }
  }
  return HomeTasks(
    running: List.unmodifiable(running),
    pending: List.unmodifiable([...attention, ...queued, ...notes]),
  );
}

bool _failed(CronJob job) =>
    job.state == CronJobState.error ||
    const {'error', 'failed'}.contains(job.lastStatus.toLowerCase());
