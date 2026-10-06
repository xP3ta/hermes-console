import '../../../models/agent_profile.dart';
import '../../../models/hosted_groups.dart';
import '../../../models/mission_control.dart';
import '../../../models/room_member_status.dart';
import '../../../models/room_mirror.dart';
import '../../../utils/plain_preview.dart';
import '../../state/bot_presence.dart';
import '../../state/attention.dart';
import '../../state/bot_chat_target.dart';
import 'living_bot_face.dart';

sealed class RosterEntry {
  const RosterEntry();

  String get key;
  String get title;
  DateTime? get at;
  bool get needsYou;
}

final class BotRosterEntry extends RosterEntry {
  final MissionAgent agent;
  final BotFaceSignal signal;

  /// Title shown as "Working · <title>" (worker session, live chat, room or
  /// running task), or `null` when the bot is not working on something named.
  final String? workingOn;

  /// Canonical Bot Chat preview (`canonical_session.preview`).
  final String preview;

  /// Subagents the canonical Bot Chat's turn has delegated and that are
  /// still running ("Activity · N delegated"); other chats never count.
  final int delegated;

  @override
  final DateTime? at;

  const BotRosterEntry({
    required this.agent,
    required this.signal,
    this.workingOn,
    this.preview = '',
    this.delegated = 0,
    this.at,
  });

  AgentProfile get profile => agent.profile;

  @override
  String get key => 'bot:${profile.name}';

  @override
  String get title => profile.botTitle ?? profile.name;

  @override
  bool get needsYou => signal == BotFaceSignal.attention;

  bool get working =>
      signal == BotFaceSignal.working ||
      signal == BotFaceSignal.thinking ||
      signal == BotFaceSignal.speaking;

  /// Server-sourced signal for one bot. Priority: attention > speaking >
  /// thinking > working > idle. Only server evidence feeds [live]
  /// (worker_session, live session status, room driver) — no local timers.
  static BotFaceSignal signalFor({
    required MissionAgent agent,
    required BotLiveStatus live,
    bool hasAttention = false,
  }) {
    if (live.presence == RoomPresence.needsYou ||
        hasAttention ||
        agent.status == MissionAgentStatus.approvalRequired ||
        agent.status == MissionAgentStatus.error ||
        agent.livePresence == BotPresence.attention) {
      return BotFaceSignal.attention;
    }
    if (agent.status == MissionAgentStatus.responding) {
      return BotFaceSignal.speaking;
    }
    if (agent.status == MissionAgentStatus.thinking) {
      return BotFaceSignal.thinking;
    }
    if (agent.status == MissionAgentStatus.working ||
        live.presence == RoomPresence.working) {
      return BotFaceSignal.working;
    }
    if (agent.livePresence == BotPresence.thinking) {
      return BotFaceSignal.thinking;
    }
    return BotFaceSignal.idle;
  }

  factory BotRosterEntry.from({
    required MissionAgent agent,
    required BotLiveStatus live,
    bool hasAttention = false,
    DateTime? now,
  }) {
    final chat = BotChatTarget.resolve(agent.profile, now: now);
    // Desktop parity: the avatar opens the canonical Bot Chat, so its aura
    // reflects that chat alone. A turn in another chat of the same profile
    // (the main profile chatting in Chats, a worker, a room seat) does not
    // light it; that work shows where it happens.
    final signal = switch (agent.botChatPresence) {
      BotPresence.attention => BotFaceSignal.attention,
      BotPresence.working => BotFaceSignal.working,
      BotPresence.thinking => BotFaceSignal.thinking,
      BotPresence.idle => BotFaceSignal.idle,
    };
    final title = agent.botChatTitle?.trim();
    final created = agent.profile.botModeUiMeta['created'];
    final createdAt = created is num && created > 0
        ? DateTime.fromMillisecondsSinceEpoch(created.toInt())
        : null;
    final candidates = [
      ?chat.lastActivityAt,
      ?agent.lastActivityAt,
      ?createdAt,
    ];
    return BotRosterEntry(
      agent: agent,
      signal: signal,
      workingOn: signal == BotFaceSignal.idle || title == null || title.isEmpty
          ? null
          : title,
      preview: rosterPreviewText(chat.preview),
      delegated: agent.botChatDelegated,
      at: candidates.isEmpty
          ? null
          : candidates.reduce((a, b) => a.isAfter(b) ? a : b),
    );
  }
}

/// One stacked face of a room row.
final class RoomRosterMember {
  final String handle;
  final AgentProfile? profile;

  const RoomRosterMember(this.handle, this.profile);
}

final class RoomRosterEntry extends RosterEntry {
  final String roomKey;
  @override
  final String title;
  final List<RoomRosterMember> members;

  /// `null` for the user ("You:"), otherwise the member's display name
  /// (falls back to its handle).
  final String? previewAuthor;
  final bool previewFromUser;
  final String preview;
  @override
  final DateTime? at;
  final int attentionCount;

  /// Hosted room id (`groups.*`).
  final String? hostedRoomId;
  final bool working;

  /// Desktop's mirrored room picture (`ui_meta` room mirror), when set.
  final AgentProfileAvatar? image;

  const RoomRosterEntry({
    required this.roomKey,
    required this.title,
    required this.members,
    this.previewAuthor,
    this.previewFromUser = false,
    this.preview = '',
    this.at,
    this.attentionCount = 0,
    this.hostedRoomId,
    this.working = false,
    this.image,
  });

  /// Opaque, stable widget identity: room ids never enter the widget tree
  /// (privacy convention of the hosted-room surfaces).
  String get publicKey {
    var hash = 0x811c9dc5;
    for (final unit in roomKey.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  @override
  String get key => 'room:$roomKey';

  @override
  bool get needsYou => attentionCount > 0;

  /// Hosted rooms from `groups.*`, the only rooms Console lists (owner
  /// decision 1.2.15: Desktop's local projection rooms are not shown).
  static List<RoomRosterEntry> build({
    required HostedGroupsSnapshot hosted,
    required AttentionSummary attention,
    Map<String, AgentProfile> localProfiles = const {},
    RoomMirrorIdentity? Function(HostedGroupRoom room)? identityFor,
  }) {
    final entries = <RoomRosterEntry>[];
    for (final room in hosted.rooms) {
      if (room.disbanded) continue;
      final identity = identityFor?.call(room);
      HostedGroupEvent? last;
      for (final log in hosted.logs) {
        for (final event in log.events) {
          if (event.roomId != room.roomId) continue;
          if (event.kind != 'message.user' && event.kind != 'message.member') {
            continue;
          }
          if (last == null || event.sequence > last.sequence) last = event;
        }
      }
      String? author;
      if (last != null && last.kind == 'message.member') {
        final memberId = last.activity.memberId ?? last.actor.id;
        final member = room.members
            .where((m) => m.memberId == memberId)
            .firstOrNull;
        final local =
            member != null &&
                member.owner.connectionId == room.authorityGatewayId
            ? localProfiles[member.owner.profile]
            : null;
        // Display name first ("Argos"), never the raw handle when a nicer
        // name is known.
        author =
            _nonEmpty(member?.displayName) ??
            _nonEmpty(local?.botTitle) ??
            member?.handle ??
            _nonEmpty(last.actor.displayName) ??
            last.actor.profile;
      }
      final driver = hosted.driverStatusFor(room.roomId);
      entries.add(
        RoomRosterEntry(
          roomKey: 'hosted:${room.roomId}',
          hostedRoomId: room.roomId,
          title: identity?.name ?? room.name,
          image: identity?.image,
          members: [
            for (final member in room.members)
              RoomRosterMember(
                member.handle,
                member.owner.connectionId == room.authorityGatewayId
                    ? localProfiles[member.owner.profile]
                    : null,
              ),
          ],
          previewFromUser: last?.kind == 'message.user',
          previewAuthor: author,
          preview: rosterPreviewText(last?.publicText ?? ''),
          at: last == null ? null : _eventTime(last.createdAt),
          attentionCount: attention.room(room.roomId)?.count ?? 0,
          working: driver?.working ?? false,
        ),
      );
    }
    return entries;
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static DateTime _eventTime(num raw) {
    // Gateway timestamps are epoch seconds; tolerate milliseconds.
    final ms = raw > 1e12 ? raw.toDouble() : raw * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms.round());
  }
}

/// One-line plain-text preview for roster rows (Bots and rooms): Markdown
/// marks are stripped with the same helper notifications and session
/// previews use, so a row never shows `**`, `##` or backticks.
String rosterPreviewText(String markdown) => plainPreview(markdown);

final RegExp _foldA = RegExp(r'[áàäâãå]');
final RegExp _foldE = RegExp(r'[éèëê]');
final RegExp _foldI = RegExp(r'[íìïî]');
final RegExp _foldO = RegExp(r'[óòöôõ]');
final RegExp _foldU = RegExp(r'[úùüû]');
final RegExp _foldSpaces = RegExp(r'\s+');

String foldRosterSearch(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(_foldA, 'a')
    .replaceAll(_foldE, 'e')
    .replaceAll(_foldI, 'i')
    .replaceAll(_foldO, 'o')
    .replaceAll(_foldU, 'u')
    .replaceAll('ñ', 'n')
    .replaceAll(_foldSpaces, ' ');
