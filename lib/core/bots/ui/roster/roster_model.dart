import '../../../models/agent_profile.dart';
import '../../../models/hosted_groups.dart';
import '../../../models/mission_control.dart';
import '../../../models/room_member_status.dart';
import '../../../models/room_mirror.dart';
import '../../../utils/markdown_clipboard.dart';
import '../../data/desktop_projection_rooms.dart';
import '../../state/bot_presence.dart';
import '../../state/attention.dart';
import '../../state/bot_chat_target.dart';
import 'living_bot_face.dart';

/// Roster filter segment (spec 070 S1).
enum RosterFilter { all, bots, rooms }

enum RosterSectionKind { needsYou, user, recent }

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

  @override
  final DateTime? at;

  const BotRosterEntry({
    required this.agent,
    required this.signal,
    this.workingOn,
    this.preview = '',
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
    final signal = signalFor(
      agent: agent,
      live: live,
      hasAttention: hasAttention,
    );
    String? clean(String? value) {
      final text = value?.trim();
      return text == null || text.isEmpty ? null : text;
    }

    // The chat the server says the bot is busy in, whoever moves it: it names
    // the work («Working · chat») and the question («Waiting for you · chat»).
    final remoteTitle = agent.livePresence == BotPresence.idle
        ? null
        : clean(agent.livePresenceTitle);
    final workingOn = signal == BotFaceSignal.idle
        ? null
        : signal == BotFaceSignal.attention
        ? (agent.livePresence == BotPresence.attention ? remoteTitle : null)
        : remoteTitle ??
              clean(chat.workingOn) ??
              clean(live.workingOn) ??
              clean(agent.liveSessionTitle) ??
              clean(agent.currentTask?.title);
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
      workingOn: workingOn,
      preview: rosterPreviewText(chat.preview),
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

  /// Hosted room id; `null` for a Desktop-only projection room.
  final String? hostedRoomId;
  final ProjectionRoom? projection;
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
    this.projection,
    this.working = false,
    this.image,
  });

  bool get desktopOnly => hostedRoomId == null;

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

  /// Hosted rooms from `groups.*` plus read-only Desktop projection rooms.
  static List<RoomRosterEntry> build({
    required HostedGroupsSnapshot hosted,
    required AttentionSummary attention,
    DesktopProjectionRooms projection = DesktopProjectionRooms.empty,
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
    for (final room in projection.rooms) {
      final last = room.lastMessage;
      entries.add(
        RoomRosterEntry(
          roomKey: 'desktop:${room.key}',
          title: room.name,
          projection: room,
          members: [
            for (final name in room.memberNames)
              RoomRosterMember(name, localProfiles[name]),
          ],
          previewFromUser: last?.from.isUser ?? false,
          previewAuthor: last == null || last.from.isUser
              ? null
              : _nonEmpty(localProfiles[last.from.name]?.botTitle) ??
                    last.from.name,
          preview: rosterPreviewText(last?.text ?? ''),
          at: room.lastActivityAt,
          attentionCount: room.needsYou ? 1 : 0,
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
String rosterPreviewText(String markdown) => markdownToCompactText(markdown);

final class RosterSection {
  final RosterSectionKind kind;
  final String? id;

  /// User section name (only for [RosterSectionKind.user]).
  final String? name;
  final List<RosterEntry> entries;

  const RosterSection({
    required this.kind,
    required this.entries,
    this.id,
    this.name,
  });
}

final class RosterLayout {
  final List<BotRosterEntry> pinned;
  final List<RosterSection> sections;
  final int hiddenCount;

  const RosterLayout({
    required this.pinned,
    required this.sections,
    required this.hiddenCount,
  });

  bool get isEmpty => pinned.isEmpty && sections.isEmpty;

  /// Pure roster ordering (spec 070 S1): pinned faces on top, then
  /// **Needs you**, then the user sections from `ui_meta` (sorted by name),
  /// then everything else by recency. Pinned bots appear only in the pinned
  /// strip unless they need the user. Hidden bots are skipped unless
  /// [showHidden]. A search query flattens everything into one list.
  static RosterLayout build({
    required List<BotRosterEntry> bots,
    required List<RoomRosterEntry> rooms,
    RosterFilter filter = RosterFilter.all,
    String query = '',
    bool showHidden = false,
  }) {
    final hiddenCount = bots.where((b) => b.profile.botHidden).length;
    final folded = foldRosterSearch(query);
    bool matches(RosterEntry entry) {
      if (folded.isEmpty) return true;
      final fields = switch (entry) {
        BotRosterEntry(:final profile) => [
          profile.name,
          profile.botTitle,
          profile.description,
          profile.botSectionName,
        ],
        RoomRosterEntry(:final title, :final members) => [
          title,
          for (final m in members) m.handle,
        ],
      };
      return fields.whereType<String>().any(
        (value) => foldRosterSearch(value).contains(folded),
      );
    }

    final visibleBots = filter == RosterFilter.rooms
        ? const <BotRosterEntry>[]
        : bots
              .where((b) => showHidden || !b.profile.botHidden)
              .where(matches)
              .toList();
    final visibleRooms = filter == RosterFilter.bots
        ? const <RoomRosterEntry>[]
        : rooms.where(matches).toList();

    int byRecency(RosterEntry a, RosterEntry b) {
      final at = a.at?.millisecondsSinceEpoch ?? 0;
      final bt = b.at?.millisecondsSinceEpoch ?? 0;
      if (at != bt) return bt.compareTo(at);
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }

    if (folded.isNotEmpty) {
      final all = <RosterEntry>[...visibleBots, ...visibleRooms]
        ..sort(byRecency);
      return RosterLayout(
        pinned: const [],
        sections: [
          if (all.isNotEmpty)
            RosterSection(kind: RosterSectionKind.recent, entries: all),
        ],
        hiddenCount: hiddenCount,
      );
    }

    final pinned = visibleBots.where((b) => b.profile.botPinned).toList()
      ..sort(byRecency);
    final needs = <RosterEntry>[
      ...visibleBots.where((b) => b.needsYou),
      ...visibleRooms.where((r) => r.needsYou),
    ]..sort(byRecency);
    final placed = {for (final entry in needs) entry.key};
    final rest = visibleBots
        .where((b) => !b.profile.botPinned && !placed.contains(b.key))
        .toList();

    // Section names: the lexicographically smallest name per id among all
    // bots, so a partially synced rename renders stably.
    final names = <String, String>{};
    for (final bot in bots) {
      final id = bot.profile.botSectionId;
      final name = bot.profile.botSectionName;
      if (id == null || name == null) continue;
      if (!names.containsKey(id) || name.compareTo(names[id]!) < 0) {
        names[id] = name;
      }
    }
    final grouped = <String, List<RosterEntry>>{};
    final loose = <RosterEntry>[];
    for (final bot in rest) {
      final id = bot.profile.botSectionId;
      if (id != null && names.containsKey(id)) {
        (grouped[id] ??= []).add(bot);
      } else {
        loose.add(bot);
      }
    }
    loose.addAll(visibleRooms.where((r) => !placed.contains(r.key)));
    loose.sort(byRecency);
    final sectionIds = grouped.keys.toList()
      ..sort((a, b) {
        final byName = names[a]!.toLowerCase().compareTo(
          names[b]!.toLowerCase(),
        );
        return byName != 0 ? byName : a.compareTo(b);
      });
    return RosterLayout(
      pinned: pinned,
      sections: [
        if (needs.isNotEmpty)
          RosterSection(kind: RosterSectionKind.needsYou, entries: needs),
        for (final id in sectionIds)
          RosterSection(
            kind: RosterSectionKind.user,
            id: id,
            name: names[id],
            entries: grouped[id]!..sort(byRecency),
          ),
        if (loose.isNotEmpty)
          RosterSection(kind: RosterSectionKind.recent, entries: loose),
      ],
      hiddenCount: hiddenCount,
    );
  }
}

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
