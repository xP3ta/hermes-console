import 'hosted_groups.dart';
import 'mission_control.dart';

// gateway/hosted_room_discussion.py::_MENTION_RE has no left boundary.
// Python IGNORECASE adds İ, ı, ſ and K to the ASCII letter ranges.
final _mentions = RegExp(r'@([A-Za-z0-9İıſK][A-Za-z0-9İıſK._:-]*)');

List<HostedGroupMember> resolveRoomRecipients(
  String text,
  List<HostedGroupMember> members,
) {
  final handles = _mentions
      .allMatches(text)
      .map((match) => _mentionFold(match[1]!))
      .toSet();
  final selected = members
      .where((m) => handles.contains(_mentionFold(m.handle)))
      .toList();
  return handles.contains('all') ||
          handles.contains('everyone') ||
          selected.isEmpty
      ? List.of(members)
      : selected;
}

enum RoomPresence { working, active, idle, needsYou, unknown }

enum RoomResponse { pending, responded, passed, noResponse }

/// One presentation model for header, autocomplete, preview and receipts.
final class BotLiveStatus {
  final RoomPresence presence;
  final String? workingOn;
  final RoomResponse? response;
  const BotLiveStatus(this.presence, {this.workingOn, this.response});

  /// Join only seats owned by this gateway: a peer with the same profile
  /// name cannot donate liveness or work details to a local bot.
  static BotLiveStatus forAgent({
    required MissionAgent agent,
    required DateTime now,
    HostedGroupsSnapshot rooms = HostedGroupsSnapshot.empty,
  }) {
    var result = derive(agent: agent, now: now);
    int priority(RoomPresence p) => switch (p) {
      RoomPresence.needsYou => 4,
      RoomPresence.working => 3,
      RoomPresence.active => 2,
      RoomPresence.idle => 1,
      RoomPresence.unknown => 0,
    };
    for (final room in rooms.rooms.where((r) => !r.disbanded)) {
      for (final member in room.members.where(
        (m) =>
            m.owner.connectionId == room.authorityGatewayId &&
            m.owner.profile == agent.profile.name,
      )) {
        final events = rooms.logs
            .where(
              (log) =>
                  log.authority.gatewayId == room.authorityGatewayId &&
                  log.authority.epoch == room.authorityEpoch,
            )
            .expand((log) => log.events)
            .where((e) => e.roomId == room.roomId)
            .toList();
        final candidate = derive(
          agent: agent,
          member: member,
          events: events,
          now: now,
        );
        final roomOnly = derive(member: member, events: events, now: now);
        if (priority(roomOnly.presence) >= priority(result.presence)) {
          result = candidate;
        }
      }
    }
    return result;
  }

  static BotLiveStatus derive({
    HostedGroupMember? member,
    List<HostedGroupEvent> events = const [],
    required DateTime now,
    MissionAgent? agent,
    HostedGroupEvent? addressedMessage,
  }) {
    final ordered = [...events]
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    bool belongs(HostedGroupEvent e) =>
        member != null &&
        (e.activity.memberId == member.memberId ||
            (e.activity.memberId == null &&
                (e.actor.id == member.memberId ||
                    (e.actor.connectionId == member.owner.connectionId &&
                        e.actor.profile == member.owner.profile))));
    final seconds = now.millisecondsSinceEpoch / 1000;
    bool recent(num time) => seconds - time >= -60 && seconds - time <= 90;
    HostedGroupEvent? running;
    HostedGroupEvent? last;
    HostedGroupEvent? question;
    for (final e in ordered) {
      if (e.kind == 'room.stop_requested' ||
          (e.kind == 'room.activity' &&
              running != null &&
              e.activity.discussionId == running.activity.discussionId)) {
        running = null;
      }
      if (e.kind == 'message.user') {
        // A new user message answers the room's previous request for input.
        if (question?.threadId == e.threadId) question = null;
        if (running?.activity.threadId == e.threadId) running = null;
      }
      if (!belongs(e)) continue;
      if (e.kind == 'turn.started') running = e;
      if (e.kind == 'message.member') question = null;
      if (e.kind == 'message.member' || e.kind.startsWith('turn.')) last = e;
      if (e.kind == 'message.member' &&
          roomMessageNeedsYou(e.publicText ?? '')) {
        question = e;
      }
      if (const {
            'turn.settled',
            'turn.failed',
            'turn.cancelled',
            'turn.deferred',
            'message.member',
          }.contains(e.kind) &&
          (running?.activity.taskId == null ||
              e.activity.taskId == running?.activity.taskId ||
              (e.activity.taskId == null &&
                  e.threadId == running?.activity.threadId))) {
        running = null;
      }
    }
    // A stranded start is not indefinite proof of liveness.
    final working =
        running != null &&
        seconds - running.createdAt >= -60 &&
        seconds - running.createdAt < 120;
    final profile = agent?.profile;
    final summaries = [
      profile?.preferredSession,
      profile?.lastSession,
      profile?.canonicalSession,
    ];
    final active =
        (last != null && recent(last.createdAt)) ||
        (agent?.lastActivityAt != null &&
            recent(agent!.lastActivityAt!.millisecondsSinceEpoch / 1000)) ||
        summaries.any((s) => s?.lastActive != null && recent(s!.lastActive!));
    final worker = profile?.workerSession;
    final freshWorker =
        worker != null &&
        seconds - worker.lastActive >= -60 &&
        seconds - worker.lastActive <= 150;
    final profileWorking =
        agent?.activeNow == true &&
        (!(agent?.statusEvidence.startsWith('worker.') ?? false) ||
            freshWorker);
    final presence =
        question != null ||
            agent?.approval != null ||
            agent?.status == MissionAgentStatus.approvalRequired ||
            agent?.status == MissionAgentStatus.blocked
        ? RoomPresence.needsYou
        : working || profileWorking
        ? RoomPresence.working
        : active
        ? RoomPresence.active
        : agent != null || last != null
        ? RoomPresence.idle
        : RoomPresence.unknown;
    String? first(Iterable<String?> values) {
      for (final value in values) {
        if (value != null && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    final detail = presence != RoomPresence.working
        ? null
        : first([
            if (working) running.activity.description,
            if (freshWorker) worker.title,
            if (profileWorking) agent?.liveSessionTitle,
            // Pinned "Bot Chat" is navigation, not a description of current work.
            if (profileWorking &&
                agent?.currentSession?.source != 'bot-mode' &&
                agent?.currentSession != null &&
                recent(agent!.currentSession!.lastActivityAt))
              agent.currentSession?.title,
            if (profileWorking)
              ...summaries
                  .where((s) => s?.lastActive != null && recent(s!.lastActive!))
                  .map((s) => first([s?.title, s?.rootTitle, s?.preview])),
            if (agent?.currentTask?.status == 'running')
              agent?.currentTask?.title,
          ]);
    RoomResponse? response;
    if (addressedMessage != null) {
      response = seconds - addressedMessage.createdAt >= 120
          ? RoomResponse.noResponse
          : RoomResponse.pending;
      // Coordinate identity is authoritative. Legacy events without it may
      // only acknowledge the latest user message in the SAME thread.
      final laterUser = ordered
          .where(
            (e) =>
                e.kind == 'message.user' &&
                e.sequence > addressedMessage.sequence &&
                e.threadId == addressedMessage.threadId,
          )
          .firstOrNull;
      for (final e in ordered) {
        if (e.sequence <= addressedMessage.sequence || !belongs(e)) continue;
        final discussion = e.activity.discussionId;
        if (discussion != null
            ? discussion != addressedMessage.eventId
            : ((e.activity.threadId ?? e.threadId) !=
                      addressedMessage.threadId ||
                  (laterUser != null && e.sequence >= laterUser.sequence))) {
          continue;
        }
        if (e.kind == 'message.member') response = RoomResponse.responded;
        if (response == RoomResponse.responded) continue;
        if (e.kind == 'turn.settled' && e.activity.passed) {
          response = RoomResponse.passed;
        }
        if (const {'turn.failed', 'turn.cancelled'}.contains(e.kind)) {
          response = RoomResponse.noResponse;
        }
      }
    }
    return BotLiveStatus(presence, workingOn: detail, response: response);
  }
}

/// Most recent user send defines the current run. Explicit coordinates keep
/// late results from an older run out of the activity panel.
List<HostedGroupEvent> currentRoomActivity(List<HostedGroupEvent> events) {
  final ordered = [...events]..sort((a, b) => a.sequence.compareTo(b.sequence));
  final start = ordered.where((e) => e.kind == 'message.user').lastOrNull;
  if (start == null) return const [];
  final activity = ordered
      .where(
        (e) =>
            e.sequence > start.sequence &&
            (e.activity.discussionId != null
                ? e.activity.discussionId == start.eventId
                : (e.activity.threadId ?? e.threadId) == start.threadId ||
                      e.kind == 'room.stop_requested') &&
            (e.kind.startsWith('turn.') ||
                e.kind == 'message.member' ||
                e.kind == 'room.activity' ||
                e.kind == 'room.stop_requested'),
      )
      .toList();
  return activity.length <= 50
      ? activity
      : activity.sublist(activity.length - 50);
}

// Compatibility for room call sites; Bots use the same pure derivation.
typedef RoomMemberStatus = BotLiveStatus;

bool roomMessageNeedsYou(String text) => _mentions
    .allMatches(text)
    .any((match) => _mentionFold(match[1]!) == 'user');

String _mentionFold(String text) =>
    text.replaceAll('İ', 'i\u0307').replaceAll('ſ', 's').toLowerCase();
