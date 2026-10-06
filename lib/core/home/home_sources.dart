import '../bots/state/attention.dart';
import '../bots/ui/roster/dots_home_model.dart';
import '../models/agent_profile.dart';
import '../models/cron_job.dart';
import '../models/desktop_active_session.dart';
import '../models/hosted_groups.dart';
import '../models/mission_control.dart';
import '../services/active_chat_service.dart';
import '../services/approval_policy.dart';
import '../bots/state/bot_presence.dart';
import 'home_now.dart';

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
        command: _commandOf(request),
        canAllow: !readOnly && permitted.contains(ApprovalScope.once.wire),
        canDeny: !readOnly && permitted.contains(ApprovalScope.deny.wire),
        ref: HomeChatApprovalRef(chat, request),
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

/// Bots other than the main one whose canonical Bot Chat works or waits,
/// derived exactly as the Bots home does ([MissionProjector] →
/// `botChatPresence`): the bot's attached chats, else its
/// `session.active_list` row.
List<HomeTeamBot> homeTeam({
  required List<AgentProfile> profiles,
  required List<DesktopActiveSession> activeSessions,
  required List<MissionLiveChat> liveChats,
  required DateTime now,
  DateTime? observedAt,
}) {
  if (profiles.isEmpty) return const [];
  final projection = MissionProjector.build(
    snapshot: MissionBackendSnapshot(
      profiles: profiles,
      activeSessions: activeSessions,
      activeSessionsObservedAt: observedAt,
      loadedAt: now,
    ),
    liveChats: liveChats,
    now: now,
  );
  final team = <HomeTeamBot>[];
  for (final agent in projection.agents) {
    final profile = agent.profile;
    if (isMainBot(profile) || profile.botHidden) continue;
    final state = switch (agent.botChatPresence) {
      BotPresence.attention => HomeTeamState.waiting,
      BotPresence.working || BotPresence.thinking => HomeTeamState.working,
      BotPresence.idle => null,
    };
    if (state == null) continue;
    final title = profile.botTitle?.trim();
    team.add(
      HomeTeamBot(
        profileName: profile.name,
        displayName: title == null || title.isEmpty ? profile.name : title,
        state: state,
        workingOn: agent.botChatTitle,
        ref: profile,
      ),
    );
  }
  return team;
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
      failed:
          job.state == CronJobState.error ||
          const {'error', 'failed'}.contains(job.lastStatus.toLowerCase()),
      nextRun: job.isPaused ? null : parseTime(job.nextRunAt),
      ref: job,
    ),
];
