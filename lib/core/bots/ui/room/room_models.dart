/// Pure presentation models for the hosted Room screen (spec 070 S3).
///
/// Everything here is derived from server evidence only: the `groups.log`
/// events, the room members and `groups.state.driver_status`. No timers, no
/// Console-only state (except the local "last seen" sequence for the
/// "new since you left" divider, which is per-device UI state).
library;

import 'package:flutter/painting.dart' show Color, HSLColor;

import '../../../models/agent_profile.dart';
import '../../../models/hosted_groups.dart';
import '../../../models/room_member_status.dart' show resolveRoomRecipients;
import '../../../widgets/mission_profile_avatar.dart'
    show MissionProfileAvatarCache;
import '../../state/bot_presence.dart';
import '../bot_identity.dart';

export '../bot_identity.dart' show botIdentityColor;

// ─── Attachments (gap G1 interim) ───────────────────────────────────────────

/// Header Desktop appends to a member turn when it staged files
/// (`apps/desktop/.../hermes-bots/group-turns.ts::groupTurnAttachmentSuffix`).
const String roomAttachmentHeader =
    'Attached files staged in your session workspace:';

const Set<String> _imageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.heic',
  '.bmp',
};

/// One staged file referenced from a room message: `name → @file:/abs/path`.
final class RoomAttachmentRef {
  final String name;

  /// Absolute path on the room's gateway host (Dashboard managed fs).
  final String path;

  const RoomAttachmentRef({required this.name, required this.path});

  bool get isImage {
    final lower = name.toLowerCase();
    return _imageExtensions.any(lower.endsWith);
  }

  @override
  bool operator ==(Object other) =>
      other is RoomAttachmentRef && other.name == name && other.path == path;

  @override
  int get hashCode => Object.hash(name, path);
}

/// A room message split into its Markdown body and trailing attachments.
final class RoomMessageBody {
  final String text;
  final List<RoomAttachmentRef> attachments;

  const RoomMessageBody(this.text, this.attachments);
}

final RegExp _needsQuoting = RegExp(r'''[\s()\[\]{}<>"'`]''');

String _formatRefValue(String value) {
  if (!_needsQuoting.hasMatch(value)) return value;
  for (final quote in const ['`', '"', "'"]) {
    if (!value.contains(quote)) return '$quote$value$quote';
  }
  return value;
}

String _unquote(String value) {
  final v = value.trim();
  if (v.length >= 2) {
    for (final quote in const ['`', '"', "'"]) {
      if (v.startsWith(quote) && v.endsWith(quote)) {
        return v.substring(1, v.length - 1);
      }
    }
  }
  return v;
}

bool _safeAbsolutePath(String path) =>
    path.startsWith('/') &&
    !path.startsWith('//') &&
    path.length <= 2048 &&
    !path.split('/').any((segment) => segment == '..' || segment == '.') &&
    !path.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

/// Appends Desktop's reference suffix to [text] (same wording and
/// `name → @file:<path>` lines), so members and Desktop read the same thing.
String appendRoomAttachmentSuffix(String text, List<RoomAttachmentRef> refs) {
  if (refs.isEmpty) return text;
  final lines = [
    for (final ref in refs) '${ref.name} → @file:${_formatRefValue(ref.path)}',
  ];
  final body = text.trimRight();
  final suffix = '$roomAttachmentHeader\n${lines.join('\n')}';
  return body.isEmpty ? suffix : '$body\n\n$suffix';
}

/// Splits a trailing attachment suffix off [text]. Anything malformed stays
/// part of the Markdown body (never silently dropped).
RoomMessageBody parseRoomMessageText(String text) {
  final index = text.lastIndexOf(roomAttachmentHeader);
  if (index < 0) return RoomMessageBody(text, const []);
  if (index > 0 && text[index - 1] != '\n') {
    return RoomMessageBody(text, const []);
  }
  final tail = text
      .substring(index + roomAttachmentHeader.length)
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (tail.isEmpty) return RoomMessageBody(text, const []);
  final refs = <RoomAttachmentRef>[];
  for (final line in tail) {
    final arrow = line.indexOf(' → ');
    if (arrow <= 0) return RoomMessageBody(text, const []);
    final name = line.substring(0, arrow).trim();
    var ref = line.substring(arrow + 3).trim();
    if (ref.startsWith('@file:')) ref = ref.substring(6);
    final path = _unquote(ref);
    if (name.isEmpty || name.length > 255 || !_safeAbsolutePath(path)) {
      return RoomMessageBody(text, const []);
    }
    refs.add(RoomAttachmentRef(name: name, path: path));
  }
  return RoomMessageBody(
    text.substring(0, index).trimRight(),
    List.unmodifiable(refs),
  );
}

// ─── Mentions ────────────────────────────────────────────────────────────────

/// Link scheme used to render `@handle` mentions as accent links.
const String roomMentionScheme = 'hermes-mention';

final RegExp _mentionToken = RegExp(
  r'(^|[^\w/\[@])@([A-Za-z0-9][A-Za-z0-9._:-]*)',
);

String _linkifyPlain(String text, Set<String> handles) =>
    text.replaceAllMapped(_mentionToken, (match) {
      var handle = match[2]!;
      var trailing = '';
      while (handle.isNotEmpty && '.:-'.contains(handle[handle.length - 1])) {
        trailing = handle[handle.length - 1] + trailing;
        handle = handle.substring(0, handle.length - 1);
      }
      if (!handles.contains(handle.toLowerCase())) return match[0]!;
      return '${match[1]}[@$handle]($roomMentionScheme:$handle)$trailing';
    });

/// Turns known `@handle` mentions into accent links, never inside fenced or
/// inline code.
String linkifyRoomMentions(String markdown, Iterable<String> knownHandles) {
  final handles = {for (final h in knownHandles) h.toLowerCase()};
  if (handles.isEmpty || !markdown.contains('@')) return markdown;
  final out = StringBuffer();
  var fenced = false;
  final lines = markdown.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('```') ||
        line.trimLeft().startsWith('~~~')) {
      fenced = !fenced;
      out.write(line);
    } else if (fenced || line.startsWith('    ')) {
      out.write(line);
    } else {
      final parts = line.split('`');
      for (var p = 0; p < parts.length; p++) {
        if (p > 0) out.write('`');
        out.write(p.isEven ? _linkifyPlain(parts[p], handles) : parts[p]);
      }
    }
    if (i < lines.length - 1) out.write('\n');
  }
  return out.toString();
}

// ─── Identity ───────────────────────────────────────────────────────────────

/// Stable identity colour of a member: the colour of the face the user
/// sees for it (the Blobatar head for procedural faces; the Bot's own
/// `ui_meta` colour for raster avatars), or a hue hashed from its handle
/// when the member has no local profile. Names, mentions and accents use it
/// so a bot looks the same in the roster, the room and its Bot Chat.
Color roomMemberColor(
  String handle, {
  AgentProfile? profile,
  MissionProfileAvatarCache? avatarCache,
}) {
  if (profile != null) {
    return botIdentityColor(profile, avatarCache: avatarCache);
  }
  var hash = 0x811c9dc5;
  for (final unit in handle.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  final hue = (hash & 0x7fffffff) % 360;
  return HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.64).toColor();
}

HostedGroupMember? roomMemberForActor(
  HostedGroupActor actor,
  List<HostedGroupMember> members,
) {
  for (final member in members) {
    if (member.memberId == actor.id) return member;
  }
  for (final member in members) {
    if (member.owner.connectionId == actor.connectionId &&
        member.owner.profile == actor.profile) {
      return member;
    }
  }
  return null;
}

HostedGroupMember? roomMemberById(
  String? memberId,
  List<HostedGroupMember> members,
) {
  if (memberId == null) return null;
  for (final member in members) {
    if (member.memberId == memberId) return member;
  }
  return null;
}

DateTime roomEventTime(HostedGroupEvent event) {
  final value = event.createdAt.toDouble();
  final ms = value < 1e12 ? (value * 1000).round() : value.round();
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

// ─── Transcript ──────────────────────────────────────────────────────────────

sealed class RoomTranscriptEntry {
  const RoomTranscriptEntry();
  String get key;
}

final class RoomDaySeparator extends RoomTranscriptEntry {
  final DateTime day;
  const RoomDaySeparator(this.day);
  @override
  String get key => 'day-${day.year}-${day.month}-${day.day}';
}

final class RoomNewSinceDivider extends RoomTranscriptEntry {
  const RoomNewSinceDivider();
  @override
  String get key => 'new-since';
}

final class RoomRoundDivider extends RoomTranscriptEntry {
  /// 1-based round number as shown to the user.
  final int round;
  final String discussionId;
  const RoomRoundDivider(this.round, this.discussionId);
  @override
  String get key => 'round-$discussionId-$round';
}

final class RoomThreadSummary {
  final String threadId;
  final int replies;
  final HostedGroupActor? lastActor;
  const RoomThreadSummary({
    required this.threadId,
    required this.replies,
    required this.lastActor,
  });
}

final class RoomMessageEntry extends RoomTranscriptEntry {
  final HostedGroupEvent event;
  final RoomMessageBody body;
  final HostedGroupMember? member;
  final bool firstOfRun;
  final RoomThreadSummary? thread;

  const RoomMessageEntry({
    required this.event,
    required this.body,
    required this.member,
    required this.firstOfRun,
    this.thread,
  });

  bool get isUser => event.actor.kind == 'user';

  @override
  String get key => 'msg-${event.eventId}';
}

/// The single quiet "N passed · Activity ›" line after a discussion.
final class RoomPassesEntry extends RoomTranscriptEntry {
  final String discussionId;
  final List<String> memberIds;
  const RoomPassesEntry(this.discussionId, this.memberIds);
  @override
  String get key => 'passes-$discussionId';
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _speaker(HostedGroupEvent e) => '${e.actor.kind}:${e.actor.id}';

String? _discussionOf(HostedGroupEvent e) =>
    e.kind == 'message.user' ? e.eventId : e.activity.discussionId;

/// Thread roots: the first discussion of each thread lives in the main
/// timeline; later discussions in that thread fold into a reply summary.
Map<String, String> _rootDiscussions(List<HostedGroupEvent> messages) {
  final roots = <String, String>{};
  for (final e in messages) {
    final thread = e.threadId;
    final discussion = _discussionOf(e);
    if (thread == null || discussion == null) continue;
    roots.putIfAbsent(thread, () => discussion);
  }
  return roots;
}

bool _inMainTimeline(HostedGroupEvent e, Map<String, String> roots) {
  final thread = e.threadId;
  final discussion = _discussionOf(e);
  if (thread == null || discussion == null) return true;
  return roots[thread] == discussion;
}

/// Messages of one thread (for the thread sheet), in order.
List<HostedGroupEvent> roomThreadMessages(
  List<HostedGroupEvent> events,
  String threadId,
) => [
  for (final e in events)
    if (e.publicText != null && e.threadId == threadId) e,
];

/// Builds the grouped group-chat transcript (oldest first).
List<RoomTranscriptEntry> buildRoomTranscript({
  required List<HostedGroupEvent> events,
  required List<HostedGroupMember> members,
  int? lastSeenSeq,
  Duration runGap = const Duration(minutes: 5),
}) {
  final messages = [
    for (final e in events)
      if (e.publicText != null &&
          (e.kind == 'message.user' || e.kind == 'message.member'))
        e,
  ];
  final roots = _rootDiscussions(messages);
  final main = <HostedGroupEvent>[];
  final hiddenByThread = <String, List<HostedGroupEvent>>{};
  for (final e in messages) {
    if (_inMainTimeline(e, roots)) {
      main.add(e);
    } else {
      hiddenByThread.putIfAbsent(e.threadId!, () => []).add(e);
    }
  }
  // Where each thread summary / passes line hangs: last main message.
  final lastMainOfThread = <String, String>{};
  final lastMainOfDiscussion = <String, String>{};
  for (final e in main) {
    if (e.threadId != null) lastMainOfThread[e.threadId!] = e.eventId;
    final discussion = _discussionOf(e);
    if (discussion != null) lastMainOfDiscussion[discussion] = e.eventId;
  }
  final passes = <String, List<String>>{};
  for (final e in events) {
    if (e.kind == 'turn.settled' &&
        e.activity.passed &&
        e.activity.discussionId != null &&
        e.activity.memberId != null) {
      final list = passes.putIfAbsent(e.activity.discussionId!, () => []);
      if (!list.contains(e.activity.memberId)) list.add(e.activity.memberId!);
    }
  }

  final out = <RoomTranscriptEntry>[];
  HostedGroupEvent? previous;
  var breakRun = true;
  var newSinceShown = false;
  final seen = lastSeenSeq ?? 0;
  final hasOlder = main.any((e) => e.sequence <= seen);
  final roundOf = <String, int>{};
  for (final e in main) {
    final at = roomEventTime(e);
    if (previous == null || !_sameDay(roomEventTime(previous), at)) {
      out.add(RoomDaySeparator(DateTime(at.year, at.month, at.day)));
      breakRun = true;
    }
    if (!newSinceShown && seen > 0 && hasOlder && e.sequence > seen) {
      out.add(const RoomNewSinceDivider());
      newSinceShown = true;
      breakRun = true;
    }
    final discussion = _discussionOf(e);
    final round = e.activity.roundIndex;
    if (e.kind == 'message.member' && discussion != null && round != null) {
      final last = roundOf[discussion];
      if (round > 0 && last != null && round > last) {
        out.add(RoomRoundDivider(round + 1, discussion));
        breakRun = true;
      }
      if (last == null || round > last) roundOf[discussion] = round;
    }
    final firstOfRun =
        breakRun ||
        previous == null ||
        _speaker(previous) != _speaker(e) ||
        at.difference(roomEventTime(previous)) > runGap;
    final hidden = e.threadId == null ? null : hiddenByThread[e.threadId!];
    final summary =
        hidden != null &&
            hidden.isNotEmpty &&
            lastMainOfThread[e.threadId] == e.eventId
        ? RoomThreadSummary(
            threadId: e.threadId!,
            replies: hidden.length,
            lastActor: hidden.last.actor,
          )
        : null;
    out.add(
      RoomMessageEntry(
        event: e,
        body: parseRoomMessageText(e.publicText!),
        member: e.actor.kind == 'user'
            ? null
            : roomMemberForActor(e.actor, members),
        firstOfRun: firstOfRun,
        thread: summary,
      ),
    );
    breakRun = summary != null;
    if (discussion != null &&
        lastMainOfDiscussion[discussion] == e.eventId &&
        (passes[discussion]?.isNotEmpty ?? false)) {
      out.add(
        RoomPassesEntry(discussion, List.unmodifiable(passes[discussion]!)),
      );
      breakRun = true;
    }
    previous = e;
  }
  return out;
}

// ─── Round panel ─────────────────────────────────────────────────────────────

enum RoomTurnState {
  working,
  needsYou,
  queued,
  passed,
  replied,
  failed,
  stopped,
  noReply,
}

final class RoomRoundRow {
  final HostedGroupMember member;
  final RoomTurnState state;

  /// When the current state started (working elapsed).
  final DateTime? since;
  final String? taskId;
  final RoomApprovalAction? approval;

  /// Retry is offered by the server for this task.
  final bool retryOffered;
  final String? reasonCode;

  const RoomRoundRow({
    required this.member,
    required this.state,
    this.since,
    this.taskId,
    this.approval,
    this.retryOffered = false,
    this.reasonCode,
  });
}

final class RoomRoundModel {
  final String discussionId;

  /// 1-based.
  final int round;
  final List<RoomRoundRow> rows;
  final int working;
  final int queued;
  final bool active;

  const RoomRoundModel({
    required this.discussionId,
    required this.round,
    required this.rows,
    required this.working,
    required this.queued,
    required this.active,
  });

  int get needsYou =>
      rows.where((r) => r.state == RoomTurnState.needsYou).length;
  int get failed => rows.where((r) => r.state == RoomTurnState.failed).length;
}

const _turnKinds = {
  'turn.started',
  'turn.settled',
  'turn.failed',
  'turn.cancelled',
  'turn.deferred',
};

/// Current round of the latest discussion, per member, from `turn.*`
/// events plus `driver_status` (approvals, retries, counts). Returns `null`
/// when the room has no user discussion yet.
///
/// Without a driver status, an open `turn.started` counts as working only
/// while the latest activity of that member's turn is fresh at [now]
/// (same window as [BotPresence.workerFreshness]).
RoomRoundModel? deriveRoomRound({
  required List<HostedGroupEvent> events,
  required List<HostedGroupMember> members,
  RoomDriverStatus? driverStatus,
  DateTime? now,
}) {
  HostedGroupEvent? discussion;
  for (final e in events.reversed) {
    if (e.kind == 'message.user') {
      discussion = e;
      break;
    }
  }
  if (discussion == null) return null;
  var discussionId = discussion.eventId;
  final turns = [
    for (final e in events)
      if (_turnKinds.contains(e.kind) && e.sequence > discussion.sequence) e,
  ];
  if (turns.isNotEmpty &&
      !turns.any((e) => e.activity.discussionId == discussionId)) {
    discussionId = turns.last.activity.discussionId ?? discussionId;
  }
  final current = [
    for (final e in turns)
      if (e.activity.discussionId == null ||
          e.activity.discussionId == discussionId)
        e,
  ];
  var round = 0;
  for (final e in current) {
    final r = e.activity.roundIndex;
    if (r != null && r > round) round = r;
  }
  final driver = driverStatus;
  final roomWorking = driver?.working ?? false;
  final recipients = resolveRoomRecipients(
    discussion.publicText ?? '',
    members,
  );
  final touched = {
    for (final e in current)
      if (e.activity.memberId != null) e.activity.memberId!,
  };
  final ordered = [
    ...recipients,
    for (final m in members)
      if (!recipients.contains(m) && touched.contains(m.memberId)) m,
  ];
  final rows = <RoomRoundRow>[];
  for (final member in ordered) {
    HostedGroupEvent? last;
    for (final e in current) {
      if (e.activity.memberId == member.memberId) last = e;
    }
    RoomApprovalAction? approval;
    for (final a in driver?.approvals ?? const <RoomApprovalAction>[]) {
      if (a.memberId == member.memberId) approval = a;
    }
    final taskId = last?.activity.taskId;
    final retry = taskId != null && (driver?.offersRetry(taskId) ?? false);
    final since = last == null ? null : roomEventTime(last);
    bool turnIsFresh() {
      if (now == null) return true;
      var latest = last!.createdAt;
      for (final e in events) {
        if (e.sequence <= last.sequence) continue;
        final memberId =
            e.activity.memberId ??
            (e.kind == 'message.member' ? e.actor.id : null);
        if (memberId == member.memberId && e.createdAt > latest) {
          latest = e.createdAt;
        }
      }
      final seconds = latest < 1e12 ? latest : latest / 1000;
      return BotPresence.isFreshActivity(seconds, now);
    }

    RoomTurnState state;
    if (approval != null) {
      state = RoomTurnState.needsYou;
    } else {
      switch (last?.kind) {
        case 'turn.started':
          state = roomWorking || (driver == null && turnIsFresh())
              ? RoomTurnState.working
              : RoomTurnState.noReply;
        case 'turn.settled':
          state = last!.activity.passed
              ? RoomTurnState.passed
              : RoomTurnState.replied;
        case 'turn.failed':
          state = RoomTurnState.failed;
        case 'turn.cancelled':
          state = RoomTurnState.stopped;
        case 'turn.deferred':
          state = retry ? RoomTurnState.failed : RoomTurnState.queued;
        default:
          state = roomWorking ? RoomTurnState.queued : RoomTurnState.noReply;
      }
    }
    rows.add(
      RoomRoundRow(
        member: member,
        state: state,
        since: since,
        taskId: approval?.taskId ?? taskId,
        approval: approval,
        retryOffered: retry,
        reasonCode: last?.activity.reasonCode,
      ),
    );
  }
  final working = rows.where((r) => r.state == RoomTurnState.working).length;
  final queuedRows = rows.where((r) => r.state == RoomTurnState.queued).length;
  final queuedDriver = driver?.counts['queued'] ?? 0;
  return RoomRoundModel(
    discussionId: discussionId,
    round: round + 1,
    rows: List.unmodifiable(rows),
    working: working,
    queued: queuedDriver > queuedRows ? queuedDriver : queuedRows,
    active:
        roomWorking ||
        (driver?.needsUser ?? false) ||
        rows.any(
          (r) =>
              r.state == RoomTurnState.working ||
              r.state == RoomTurnState.needsYou,
        ),
  );
}

// ─── Activity / threads / files / availability ─────────────────────────────

enum RoomActivityKind { passed, failed, cancelled, deferred, stopRequested }

final class RoomActivityItem {
  final HostedGroupEvent event;
  final RoomActivityKind kind;
  const RoomActivityItem(this.event, this.kind);
  String? get memberId => event.activity.memberId;
}

/// Passes, failures, retries (deferrals) and stops, newest first.
List<RoomActivityItem> roomActivity(List<HostedGroupEvent> events) {
  final out = <RoomActivityItem>[];
  for (final e in events) {
    final kind = switch (e.kind) {
      'turn.settled' when e.activity.passed => RoomActivityKind.passed,
      'turn.failed' => RoomActivityKind.failed,
      'turn.cancelled' => RoomActivityKind.cancelled,
      'turn.deferred' => RoomActivityKind.deferred,
      'room.stop_requested' => RoomActivityKind.stopRequested,
      _ => null,
    };
    if (kind != null) out.add(RoomActivityItem(e, kind));
  }
  return out.reversed.toList(growable: false);
}

final class RoomThreadInfo {
  final String threadId;
  final HostedGroupEvent root;
  final int messages;
  final HostedGroupEvent latest;
  const RoomThreadInfo({
    required this.threadId,
    required this.root,
    required this.messages,
    required this.latest,
  });
}

/// Threads with at least one reply, most recent first.
List<RoomThreadInfo> roomThreads(List<HostedGroupEvent> events) {
  final byThread = <String, List<HostedGroupEvent>>{};
  for (final e in events) {
    if (e.publicText == null || e.threadId == null) continue;
    byThread.putIfAbsent(e.threadId!, () => []).add(e);
  }
  final out = [
    for (final entry in byThread.entries)
      if (entry.value.length > 1)
        RoomThreadInfo(
          threadId: entry.key,
          root: entry.value.first,
          messages: entry.value.length,
          latest: entry.value.last,
        ),
  ];
  out.sort((a, b) => b.latest.sequence.compareTo(a.latest.sequence));
  return out;
}

/// Every attachment referenced in the room, newest first.
List<({RoomAttachmentRef ref, HostedGroupEvent event})> roomFiles(
  List<HostedGroupEvent> events,
) {
  final out = <({RoomAttachmentRef ref, HostedGroupEvent event})>[];
  for (final e in events.reversed) {
    final text = e.publicText;
    if (text == null) continue;
    for (final ref in parseRoomMessageText(text).attachments) {
      out.add((ref: ref, event: e));
    }
  }
  return out;
}

/// Members the server last reported as unavailable (`member.unavailable`
/// newer than any later turn/message of that member).
Set<String> roomUnavailableMembers(List<HostedGroupEvent> events) {
  final latestUnavailable = <String, int>{};
  final latestAlive = <String, int>{};
  for (final e in events) {
    final memberId =
        e.activity.memberId ?? (e.kind == 'message.member' ? e.actor.id : null);
    if (memberId == null) continue;
    if (e.kind == 'member.unavailable') {
      latestUnavailable[memberId] = e.sequence;
    } else if (e.kind == 'message.member' || e.kind == 'turn.started') {
      latestAlive[memberId] = e.sequence;
    }
  }
  return {
    for (final entry in latestUnavailable.entries)
      if ((latestAlive[entry.key] ?? 0) < entry.value) entry.key,
  };
}
