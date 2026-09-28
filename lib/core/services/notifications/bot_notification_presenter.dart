// Presents room watcher decisions and Bot Chat events as rich conversation
// notifications, and publishes the Bot Mode widget snapshot (Phase 7).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/hosted_groups.dart';
import '../../widgets/bot_face_identity.dart';
import 'bot_face_bitmap.dart';
import 'notification_service.dart';
import 'notification_strings.dart';
import 'rich_notifications.dart';
import 'room_watcher.dart';

/// Configured face of a Bot ([BotFaceIdentity.resolve]); null = unknown
/// Bot (the unconfigured sphere is used).
typedef BotIdentityLookup =
    FutureOr<BotFaceIdentity?> Function(String connId, String profile);

/// Raster avatar bytes of an avatar identity; null when unavailable.
typedef BotImageLookup =
    FutureOr<Uint8List?> Function(String connId, String profile);

/// Face PNG of [profile] in [state] through the shared identity resolver:
/// configured avatar → configured procedural face → sphere.
Future<String?> botFacePath({
  required BotFaceBitmapCache faces,
  required String connId,
  required String profile,
  required BotFaceBitmapState state,
  BotIdentityLookup? identityFor,
  BotImageLookup? imageFor,
  int size = 128,
  int frame = 0,
  bool plate = true,
}) async {
  BotFaceIdentity? identity;
  try {
    identity = await identityFor?.call(connId, profile);
  } catch (_) {}
  identity ??= BotFaceIdentity.resolve(profile: profile);
  Uint8List? image;
  if (identity.source == BotFaceSource.avatar && imageFor != null) {
    try {
      image = await imageFor(connId, profile);
    } catch (_) {}
  }
  return faces.pathFor(
    profile: profile,
    identity: identity,
    state: state,
    size: size,
    frame: frame,
    plate: plate,
    image: image,
  );
}

/// The Bot's own colour for its notification tint: the base of its face
/// palette, so the shade shows who speaks before a word is read. A Bot
/// without a colour (grey) keeps the brand accent.
int botAccent(BotFaceIdentity identity) {
  if (identity.sphere == 'grey') return RichAccent.brand;
  final base = BotSpherePalette.colors[identity.sphere]?.$2;
  return base == null ? RichAccent.brand : base.toARGB32();
}

/// [botAccent] of [profile] via [identityFor]; brand when unknown.
Future<int> botAccentFor(
  String connId,
  String? profile,
  BotIdentityLookup? identityFor,
) async {
  if (profile == null) return RichAccent.brand;
  BotFaceIdentity? identity;
  try {
    identity = await identityFor?.call(connId, profile);
  } catch (_) {}
  return identity == null ? RichAccent.brand : botAccent(identity);
}

/// Display name of a Bot profile from the loaded roster; null if unknown.
typedef BotNameLookup = String? Function(String profile);

/// Human name for a room member: the Bot's roster display name, then the
/// room's display name unless it is a technical slug ("console-radar"),
/// then a humanized slug/profile ("Radar", "Atlas"). Raw handles never
/// reach the user.
String memberName(
  HostedGroupRoom room,
  String memberId, {
  BotNameLookup? nameFor,
}) {
  for (final m in room.members) {
    if (m.memberId == memberId) {
      final profile = m.owner.profile.trim();
      final roster = profile.isEmpty ? null : nameFor?.call(profile)?.trim();
      if (roster != null && roster.isNotEmpty && !_isSlug(roster)) {
        return roster;
      }
      final display = m.displayName?.trim();
      if (display != null && display.isNotEmpty && !_isSlug(display)) {
        return display;
      }
      return humanizeBotHandle(
        display != null && display.isNotEmpty
            ? display
            : (profile.isNotEmpty && profile != 'default' ? profile : m.handle),
      );
    }
  }
  return humanizeBotHandle(memberId);
}

bool _isSlug(String value) =>
    RegExp(r'^[a-z0-9]+([_-][a-z0-9]+)*$').hasMatch(value);

/// "console-radar" → "Radar", "code_review" → "Code review", "atlas" →
/// "Atlas". Only the last dash segment of a prefixed handle is kept.
String humanizeBotHandle(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return raw;
  final dash = value.lastIndexOf('-');
  if (dash > 0 && dash < value.length - 1) value = value.substring(dash + 1);
  value = value.replaceAll('_', ' ').trim();
  if (value.isEmpty) return raw;
  return value[0].toUpperCase() + value.substring(1);
}

String? memberProfile(HostedGroupRoom room, String memberId) {
  for (final m in room.members) {
    if (m.memberId == memberId) return m.owner.profile;
  }
  return null;
}

/// Member of [room] an @handle addresses (handle, profile or name).
String? memberForHandle(HostedGroupRoom room, String handle) {
  final h = handle.trim().toLowerCase();
  if (h.isEmpty) return null;
  for (final m in room.members) {
    final keys = {
      m.handle.toLowerCase(),
      m.owner.profile.toLowerCase(),
      if (m.displayName != null) m.displayName!.toLowerCase(),
      humanizeBotHandle(m.handle).toLowerCase(),
    };
    if (keys.contains(h)) return m.memberId;
  }
  return null;
}

/// What the room's Live Update shows: one segment per member taking part
/// (server states first, then members @-addressed in the round, else every
/// member), and the Bot shown as working. [inferred] = no `turn.started`
/// yet: the Bot is named from the round's @-address ("pensando…").
({
  List<({String memberId, String state})> members,
  String? workingMemberId,
  bool inferred,
})
liveRoundPlan(HostedGroupRoom room, RoomLiveNotice notice) {
  final states = <String, String>{
    for (final m in notice.members) m.memberId: m.state,
  };
  final addressed = <String>[
    for (final h in notice.addressedHandles) ?memberForHandle(room, h),
  ];
  final order = <String>[
    for (final id in addressed)
      if (!states.containsKey(id)) id,
  ];
  final ids = <String>{...states.keys, ...order};
  if (ids.isEmpty) {
    ids.addAll([for (final m in room.members) m.memberId]);
  }
  var working = notice.workingMemberId;
  var inferred = false;
  working ??= [
    for (final id in [...addressed, ...ids])
      if (states[id] == 'working') id,
  ].firstOrNull;
  if (working == null) {
    final next = [
      for (final id in addressed)
        if (states[id] == null) id,
    ].firstOrNull;
    working =
        next ?? (room.members.length == 1 ? room.members.first.memberId : null);
    inferred = working != null;
  }
  return (
    members: [
      for (final id in ids.take(12))
        (
          memberId: id,
          state: states[id] ?? (id == working ? 'working' : 'pending'),
        ),
    ],
    workingMemberId: working,
    inferred: inferred,
  );
}

class RichRoomNoticePresenter implements RoomNoticePresenter {
  RichRoomNoticePresenter({
    required this.sink,
    required this.prefs,
    required this.faces,
    this.identityFor,
    this.imageFor,
    this.nameFor,
    DateTime Function()? now,
    this.readOnly = false,
  }) : _now = now ?? DateTime.now;

  /// Roster display names (members without a room display name).
  final BotNameLookup? nameFor;

  final RichNotificationSink sink;
  final SharedPreferences prefs;
  final BotFaceBitmapCache faces;
  final BotIdentityLookup? identityFor;
  final BotImageLookup? imageFor;
  final DateTime Function() _now;

  /// Read-only connections get no Approve / Reply / Stop buttons.
  final bool readOnly;

  /// At most this many rooms get their own Live Update at once; further
  /// working rooms share one ongoing summary ("3 salas trabajando").
  static const maxLiveRooms = 2;

  /// Member reply lines kept on a round-finished card.
  static const maxReplyLines = 6;

  /// Tags of Live Updates this presenter currently shows (insertion order).
  final Set<String> _liveTags = {};
  Set<String> get liveTags => Set.unmodifiable(_liveTags);

  /// Working rooms without their own Live Update: tag → room name.
  final Map<String, String> _overflow = {};
  Map<String, String> get overflowRooms => Map.unmodifiable(_overflow);

  /// Names of rooms with their own Live Update: tag → room name.
  final Map<String, String> _liveNames = {};
  bool _summaryPosted = false;

  /// Withdraws every Live Update not in [keep] (rooms that disappeared).
  Future<void> cancelLiveExcept(Set<String> keep) async {
    for (final tag in {..._liveTags, ..._overflow.keys}.difference(keep)) {
      await _cancelLive(tag);
    }
  }

  /// Withdraws every Live Update (connection change, listener stop,
  /// gateway unreachable).
  Future<void> cancelAllLive() => cancelLiveExcept(const {});

  Future<void> _cancelLive(String tag) async {
    final hadOwn = _liveTags.remove(tag);
    _liveNames.remove(tag);
    final hadOverflow = _overflow.remove(tag) != null;
    // Unconditional: a card posted before a process restart is withdrawn
    // too (the presenter's memory starts empty).
    await sink.cancel(id: RichNotificationIds.live, tag: tag);
    if (hadOwn || hadOverflow) await _syncSummary();
  }

  Future<void> _syncSummary() async {
    if (_overflow.isEmpty) {
      if (_summaryPosted) {
        _summaryPosted = false;
        await sink.cancel(
          id: RichNotificationIds.live,
          tag: RichNotificationBuilder.liveSummaryTag,
        );
      }
      return;
    }
    _summaryPosted = true;
    await sink.postLiveUpdate(
      RichNotificationBuilder(_t).liveSummary(
        roomNames: [..._liveNames.values, ..._overflow.values],
        total: _liveTags.length + _overflow.length,
      ),
    );
  }

  NotifL10n get _t => NotifL10n.of(prefs);
  bool get _hideSensitive =>
      prefs.getBool('notif_hide_sensitive_content') ?? false;

  String _conn = '';

  Future<String?> _face(String? profile, BotFaceBitmapState state) async {
    if (profile == null) return null;
    return botFacePath(
      faces: faces,
      connId: _conn,
      profile: profile,
      state: state,
      identityFor: identityFor,
      imageFor: imageFor,
    );
  }

  /// Room avatar (2x2 member tile) for the conversation shortcut.
  Future<String?> _roomTile(HostedGroupRoom room) async {
    final members = <BotFaceIdentity>[
      for (final m in room.members)
        await identityFor?.call(_conn, m.owner.profile) ??
            BotFaceIdentity.resolve(profile: m.owner.profile),
    ];
    return faces.roomTilePath(roomKey: room.roomId, members: members);
  }

  NotificationOpen _open(String connId, HostedGroupRoom room) =>
      NotificationOpen(
        connId: connId,
        sessionId: room.roomId,
        title: room.name,
        surface: NotificationChatSurface.room,
        roomId: room.roomId,
      );

  static String conversationId(String connId, HostedGroupRoom room) =>
      'room-${RichNotificationIds.roomTag(connId, room.roomId).split('.').last}';

  @override
  Future<void> present(
    String connId,
    HostedGroupRoom room,
    List<RoomNotice> notices,
  ) async {
    _conn = connId;
    final t = _t;
    final builder = RichNotificationBuilder(t);
    final tag = RichNotificationIds.roomTag(connId, room.roomId);
    final conv = conversationId(connId, room);
    final open = _open(connId, room);
    final nowMs = _now().millisecondsSinceEpoch;
    final messages = <RichMessage>[];
    var alert = false;
    var accent = RichAccent.brand;
    int rank(int a) => switch (a) {
      RichAccent.failed => 3,
      RichAccent.needsYou => 2,
      RichAccent.done => 1,
      _ => 0,
    };
    void tint(int a) {
      if (rank(a) > rank(accent)) accent = a;
    }

    HostedGroupEvent? replyTarget;
    String? verdict;
    // The Bot that speaks last on a calm card lends it its colour.
    String? speaker;
    String? alertKey;
    for (final notice in notices) {
      switch (notice) {
        case RoomApprovalNotice(:final action):
          final profile = memberProfile(room, action.memberId);
          final name = memberName(room, action.memberId, nameFor: nameFor);
          await sink.postConversation(
            builder.approval(
              tag: tag,
              conversationId: conv,
              conversationTitle: room.name,
              isGroup: true,
              botKey: action.memberId,
              botName: name,
              botIconPath: await _face(profile, BotFaceBitmapState.needsYou),
              command: action.command,
              description: action.description,
              action: NotificationActionPayload(
                route: NotificationActionRoute.room,
                connId: connId,
                roomId: room.roomId,
                requestId: action.requestId,
                taskId: action.taskId,
                memberId: action.memberId,
                executionGeneration: action.executionGeneration,
                choices: action.choices,
              ),
              open: open,
              // Read-only: the card only opens the room.
              offered: readOnly ? const [] : action.choices,
              nowMs: nowMs,
              hideSensitive: _hideSensitive,
              // Hosted rooms accept once|deny only (`approve_room_task`).
              allowAlways: false,
              shortcutIconPath: await _roomTile(room),
            ),
          );
        case RoomApprovalClearedNotice(:final requestId):
          await sink.confirm(
            id: RichNotificationIds.approval(requestId),
            tag: tag,
            text: t.confirmAnsweredElsewhere,
            timeoutMs: 3000,
            // Never resurrect a card already dismissed or confirmed.
            onlyIfActive: true,
          );
        case RoomMentionNotice(:final event):
          final member = event.activity.memberId ?? event.actor.id;
          messages.add(
            RichMessage(
              senderKey: member,
              senderName: memberName(room, member, nameFor: nameFor),
              text: plainNotificationText(event.publicText),
              iconPath: await _face(
                memberProfile(room, member),
                BotFaceBitmapState.needsYou,
              ),
              timeMs: (event.createdAt * 1000).round(),
            ),
          );
          alert = true;
          tint(RichAccent.needsYou);
          replyTarget = event;
        case RoomMemberFailedNotice(:final event):
          final member = event.activity.memberId ?? event.actor.id;
          final name = memberName(room, member, nameFor: nameFor);
          messages.add(
            RichMessage(
              senderKey: member,
              senderName: name,
              text: t.memberFailed(name),
              iconPath: await _face(
                memberProfile(room, member),
                BotFaceBitmapState.failed,
              ),
              timeMs: (event.createdAt * 1000).round(),
            ),
          );
          alert = true;
          tint(RichAccent.failed);
        case RoomBlockedNotice():
          messages.add(
            RichMessage(
              senderKey: 'room',
              senderName: room.name,
              text: t.roomBlocked,
              // The room speaks with its own 2x2 tile, never a letter.
              iconPath: await _roomTile(room),
              timeMs: nowMs,
            ),
          );
          alert = true;
          tint(RichAccent.failed);
        case RoomRoundFinishedNotice(
          :final repliedMemberIds,
          :final lastMemberId,
          :final replies,
        ):
          final names = [
            for (final id in repliedMemberIds)
              memberName(room, id, nameFor: nameFor),
          ];
          await _cancelLive(tag);
          // Each Bot's reply as its own conversation line ("Radar: …"),
          // newest [maxReplyLines] kept; the summary closes the card.
          final shown = replies.length > maxReplyLines
              ? replies.sublist(replies.length - maxReplyLines)
              : replies;
          var lines = 0;
          for (final reply in shown) {
            final text = plainNotificationText(reply.text, max: 240);
            if (text.isEmpty) continue;
            messages.add(
              RichMessage(
                senderKey: reply.memberId,
                senderName: memberName(room, reply.memberId, nameFor: nameFor),
                text: text,
                iconPath: await _face(
                  memberProfile(room, reply.memberId),
                  BotFaceBitmapState.done,
                ),
                timeMs: reply.timeMs,
              ),
            );
            lines++;
          }
          // The round verdict closes the card as its header line (subText),
          // not as a message: a sender named like the room renders as
          // "Room: Room" in the shade. Only a round without reply lines
          // needs a speaker, and then it is the last Bot (the room tile
          // only when no member is known).
          verdict = t.roundDone(names);
          speaker =
              lastMemberId ?? (shown.isEmpty ? null : shown.last.memberId);
          if (lines == 0) {
            final by = lastMemberId;
            messages.add(
              RichMessage(
                senderKey: by ?? 'room',
                senderName: by == null
                    ? room.name
                    : memberName(room, by, nameFor: nameFor),
                text: verdict,
                iconPath: by == null
                    ? await _roomTile(room)
                    : await _face(
                        memberProfile(room, by),
                        BotFaceBitmapState.done,
                      ),
                timeMs: nowMs,
              ),
            );
          }
          // A new round is news: it alerts again even though the card
          // reuses the room's tag + id (seen / dismissed earlier rounds
          // must not swallow it). The same discussion never re-sounds.
          alert = true;
          alertKey = 'round:${notice.dedupeKey}';
          tint(RichAccent.done);
        case RoomLiveNotice():
          await _live(connId, room, notice, builder, tag, conv, open);
      }
    }
    if (messages.isEmpty) return;
    // Amber and red still mean something; a calm card is the Bot's own.
    if (accent == RichAccent.done || accent == RichAccent.brand) {
      final own = await botAccentFor(
        connId,
        speaker == null ? null : memberProfile(room, speaker),
        identityFor,
      );
      if (own != RichAccent.brand) accent = own;
    }
    await sink.postConversation(
      builder.conversation(
        tag: tag,
        conversationId: conv,
        conversationTitle: room.name,
        isGroup: true,
        messages: messages,
        open: open,
        alert: alert,
        replyTo: room.name,
        replyAction: readOnly
            ? null
            : NotificationActionPayload(
                route: NotificationActionRoute.room,
                connId: connId,
                roomId: room.roomId,
                authorityId: room.authorityGatewayId,
                threadId:
                    replyTarget?.threadId ?? replyTarget?.activity.threadId,
              ),
        hideSensitive: _hideSensitive,
        accent: accent,
        shortcutIconPath: await _roomTile(room),
        subText: verdict,
        text: verdict,
        alertKey: alertKey,
      ),
    );
  }

  Future<void> _live(
    String connId,
    HostedGroupRoom room,
    RoomLiveNotice notice,
    RichNotificationBuilder builder,
    String tag,
    String conv,
    NotificationOpen open,
  ) async {
    if (!notice.working) {
      await _cancelLive(tag);
      return;
    }
    if (!_liveTags.contains(tag) && _liveTags.length >= maxLiveRooms) {
      // Third+ working room: listed in the shared summary, no own card.
      _overflow[tag] = room.name;
      await _syncSummary();
      return;
    }
    final wasOverflow = _overflow.remove(tag) != null;
    _liveTags.add(tag);
    _liveNames[tag] = room.name;
    if (wasOverflow) await _syncSummary();
    final plan = liveRoundPlan(room, notice);
    final tile = await _roomTile(room);
    final working = plan.workingMemberId;
    final own = await botAccentFor(
      connId,
      working == null ? null : memberProfile(room, working),
      identityFor,
    );
    await sink.postLiveUpdate(
      builder.liveUpdate(
        accent: own == RichAccent.brand ? RichAccent.working : own,
        tag: tag,
        conversationId: conv,
        title: room.name,
        members: [
          for (final m in plan.members)
            (
              name: memberName(room, m.memberId, nameFor: nameFor),
              state: m.state,
            ),
        ],
        workingName: plan.workingMemberId == null
            ? null
            : memberName(room, plan.workingMemberId!, nameFor: nameFor),
        thinking: plan.inferred,
        trackerIconPath:
            await _face(
              plan.workingMemberId == null
                  ? null
                  : memberProfile(room, plan.workingMemberId!),
              BotFaceBitmapState.working,
            ) ??
            tile,
        largeIconPath: tile,
        repliedAfterMs: {
          for (final e in notice.repliedAfterMs.entries)
            memberName(room, e.key, nameFor: nameFor): e.value,
        },
        startedAtMs: notice.startedAtMs,
        round: notice.round,
        open: open,
        stopAction: readOnly
            ? null
            : NotificationActionPayload(
                route: NotificationActionRoute.room,
                connId: connId,
                roomId: room.roomId,
              ),
      ),
    );
  }
}

/// Bot Chat (1:1) rich cards: completion with inline reply, approval with
/// the bot's face. Posted from the UI isolate by [NotificationService].
class BotChatRichNotifications {
  BotChatRichNotifications({
    required this.sink,
    required this.faces,
    this.identityFor,
    this.imageFor,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final RichNotificationSink sink;
  final BotFaceBitmapCache faces;
  final BotIdentityLookup? identityFor;
  final BotImageLookup? imageFor;
  final DateTime Function() _now;

  Future<String?> _face(
    String connId,
    String profile,
    BotFaceBitmapState state,
  ) => botFacePath(
    faces: faces,
    connId: connId,
    profile: profile,
    state: state,
    identityFor: identityFor,
    imageFor: imageFor,
  );

  static String conversationId(String connId, String profile) =>
      'bot-${RichNotificationIds.botTag(connId, profile).split('.').last}';

  Future<bool> replyReady({
    required NotifL10n t,
    required String connId,
    required String profile,
    required String botName,
    required String sessionId,
    required String preview,
    bool hideSensitive = false,
    bool readOnly = false,
  }) async {
    final icon = await _face(connId, profile, BotFaceBitmapState.done);
    // Conversation shortcut keeps the plain face (it outlives this state).
    final plain = await _face(connId, profile, BotFaceBitmapState.idle);
    final open = NotificationOpen(
      connId: connId,
      sessionId: sessionId,
      title: botName,
      profile: profile,
      surface: NotificationChatSurface.bot,
    );
    return sink.postConversation(
      RichNotificationBuilder(t).conversation(
        tag: RichNotificationIds.botTag(connId, profile),
        conversationId: conversationId(connId, profile),
        conversationTitle: botName,
        isGroup: false,
        messages: [
          RichMessage(
            senderKey: 'bot:$profile',
            senderName: botName,
            text: firstLinePlain(preview, max: 160),
            iconPath: icon,
            timeMs: _now().millisecondsSinceEpoch,
          ),
        ],
        open: open,
        replyTo: botName,
        replyAction: readOnly
            ? null
            : NotificationActionPayload(
                route: NotificationActionRoute.botChat,
                connId: connId,
                profile: profile,
                sessionId: sessionId,
              ),
        shortcutIconPath: plain ?? icon,
        hideSensitive: hideSensitive,
        accent: await _accent(connId, profile, RichAccent.done),
      ),
    );
  }

  /// The Bot's own colour, else [fallback].
  Future<int> _accent(String connId, String profile, int fallback) async {
    final own = await botAccentFor(connId, profile, identityFor);
    return own == RichAccent.brand ? fallback : own;
  }

  /// A scheduled routine owned by a Bot (`[bot:x]`) reported as a message
  /// from that Bot in its own conversation: done face + green on success,
  /// failed face + red on failure. [summary] must already be public text.
  Future<bool> routineResult({
    required NotifL10n t,
    required String connId,
    required String profile,
    required String botName,
    required String sessionId,
    required String routineTitle,
    required bool ok,
    String summary = '',
    bool hideSensitive = false,
  }) async {
    final state = ok ? BotFaceBitmapState.done : BotFaceBitmapState.failed;
    final icon = await _face(connId, profile, state);
    final plain = await _face(connId, profile, BotFaceBitmapState.idle);
    final title = plainNotificationText(routineTitle, max: 60);
    final line = firstLinePlain(summary, max: 120);
    final text = ok ? t.routineDone(title, line) : t.routineFailed(title);
    return sink.postConversation(
      RichNotificationBuilder(t).conversation(
        tag: RichNotificationIds.botTag(connId, profile),
        conversationId: conversationId(connId, profile),
        conversationTitle: botName,
        isGroup: false,
        messages: [
          RichMessage(
            senderKey: 'bot:$profile',
            senderName: botName,
            text: text,
            iconPath: icon,
            timeMs: _now().millisecondsSinceEpoch,
          ),
        ],
        open: NotificationOpen(
          connId: connId,
          sessionId: sessionId,
          title: botName,
          profile: profile,
          surface: NotificationChatSurface.bot,
        ),
        alert: !ok,
        shortcutIconPath: plain ?? icon,
        hideSensitive: hideSensitive,
        accent: ok
            ? await _accent(connId, profile, RichAccent.done)
            : RichAccent.failed,
      ),
    );
  }

  Future<bool> approval({
    required NotifL10n t,
    required String connId,
    required String profile,
    required String botName,
    required String sessionId,
    required String requestId,
    required List<String> offered,
    String? command,
    bool hideSensitive = false,
    bool readOnly = false,
  }) async {
    final icon = await _face(connId, profile, BotFaceBitmapState.needsYou);
    final open = NotificationOpen(
      connId: connId,
      sessionId: sessionId,
      title: botName,
      profile: profile,
      surface: NotificationChatSurface.bot,
    );
    return sink.postConversation(
      RichNotificationBuilder(t).approval(
        tag: RichNotificationIds.botTag(connId, profile),
        conversationId: conversationId(connId, profile),
        conversationTitle: botName,
        isGroup: false,
        botKey: 'bot:$profile',
        botName: botName,
        botIconPath: icon,
        command: command,
        action: NotificationActionPayload(
          route: NotificationActionRoute.chat,
          connId: connId,
          profile: profile,
          sessionId: sessionId,
          requestId: requestId,
          choices: offered,
        ),
        open: open,
        offered: readOnly ? const [] : offered,
        nowMs: _now().millisecondsSinceEpoch,
        hideSensitive: hideSensitive,
      ),
    );
  }
}

/// JSON codec helper so tests can assert payload shapes.
String debugEncode(Object? value) => jsonEncode(value);
