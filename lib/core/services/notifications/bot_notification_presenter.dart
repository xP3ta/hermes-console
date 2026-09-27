// Presents room watcher decisions and Bot Chat events as rich conversation
// notifications, and publishes the Bot Mode widget snapshot (Phase 7).
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/hosted_groups.dart';
import 'bot_face_bitmap.dart';
import 'notification_service.dart';
import 'notification_strings.dart';
import 'rich_notifications.dart';
import 'room_watcher.dart';

typedef BotShapeLookup =
    FutureOr<String?> Function(String connId, String profile);

/// Display name for a room member: display name, then handle.
String memberName(HostedGroupRoom room, String memberId) {
  for (final m in room.members) {
    if (m.memberId == memberId) {
      final display = m.displayName?.trim();
      return display != null && display.isNotEmpty ? display : m.handle;
    }
  }
  return memberId;
}

String? memberProfile(HostedGroupRoom room, String memberId) {
  for (final m in room.members) {
    if (m.memberId == memberId) return m.owner.profile;
  }
  return null;
}

class RichRoomNoticePresenter implements RoomNoticePresenter {
  RichRoomNoticePresenter({
    required this.sink,
    required this.prefs,
    required this.faces,
    this.shapeFor,
    DateTime Function()? now,
    this.readOnly = false,
  }) : _now = now ?? DateTime.now;

  final RichNotificationSink sink;
  final SharedPreferences prefs;
  final BotFaceBitmapCache faces;
  final BotShapeLookup? shapeFor;
  final DateTime Function() _now;

  /// Read-only connections get no Approve / Reply / Stop buttons.
  final bool readOnly;

  /// Tags of Live Updates this presenter currently shows.
  final Set<String> _liveTags = {};
  Set<String> get liveTags => Set.unmodifiable(_liveTags);

  /// Withdraws every Live Update not in [keep] (rooms that disappeared).
  Future<void> cancelLiveExcept(Set<String> keep) async {
    for (final tag in _liveTags.difference(keep).toList()) {
      await _cancelLive(tag);
    }
  }

  /// Withdraws every Live Update (connection change, listener stop,
  /// gateway unreachable).
  Future<void> cancelAllLive() => cancelLiveExcept(const {});

  Future<void> _cancelLive(String tag) async {
    _liveTags.remove(tag);
    await sink.cancel(id: RichNotificationIds.live, tag: tag);
  }

  NotifL10n get _t => NotifL10n.of(prefs);
  bool get _hideSensitive => prefs.getBool('notif_hide_sensitive_content') ?? false;

  String _conn = '';

  Future<String?> _face(String? profile, BotFaceBitmapState state) async {
    if (profile == null) return null;
    final shape = await shapeFor?.call(_conn, profile);
    return faces.pathFor(profile: profile, shape: shape, state: state);
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
    HostedGroupEvent? replyTarget;
    for (final notice in notices) {
      switch (notice) {
        case RoomApprovalNotice(:final action):
          final profile = memberProfile(room, action.memberId);
          final name = memberName(room, action.memberId);
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
              senderName: memberName(room, member),
              text: plainNotificationText(event.publicText),
              iconPath: await _face(
                memberProfile(room, member),
                BotFaceBitmapState.needsYou,
              ),
              timeMs: (event.createdAt * 1000).round(),
            ),
          );
          alert = true;
          replyTarget = event;
        case RoomMemberFailedNotice(:final event):
          final member = event.activity.memberId ?? event.actor.id;
          final name = memberName(room, member);
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
        case RoomBlockedNotice():
          messages.add(
            RichMessage(
              senderKey: 'room',
              senderName: room.name,
              text: t.roomBlocked,
              timeMs: nowMs,
            ),
          );
          alert = true;
        case RoomRoundFinishedNotice(:final repliedMemberIds, :final lastMemberId):
          final names = [for (final id in repliedMemberIds) memberName(room, id)];
          await _cancelLive(tag);
          messages.add(
            RichMessage(
              senderKey: lastMemberId ?? 'room',
              senderName: lastMemberId == null
                  ? room.name
                  : memberName(room, lastMemberId),
              text: t.roundDone(names),
              iconPath: await _face(
                lastMemberId == null ? null : memberProfile(room, lastMemberId),
                BotFaceBitmapState.idle,
              ),
              timeMs: nowMs,
            ),
          );
        case RoomLiveNotice():
          await _live(connId, room, notice, builder, tag, conv, open);
      }
    }
    if (messages.isEmpty) return;
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
    final working = notice.workingMemberId;
    _liveTags.add(tag);
    await sink.postLiveUpdate(
      builder.liveUpdate(
        tag: tag,
        conversationId: conv,
        title: room.name,
        members: [
          for (final m in notice.members)
            (name: memberName(room, m.memberId), state: m.state),
        ],
        workingName: working == null ? null : memberName(room, working),
        trackerIconPath: await _face(
          working == null ? null : memberProfile(room, working),
          BotFaceBitmapState.working,
        ),
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
    this.shapeFor,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final RichNotificationSink sink;
  final BotFaceBitmapCache faces;
  final BotShapeLookup? shapeFor;
  final DateTime Function() _now;

  Future<String?> _face(
    String connId,
    String profile,
    BotFaceBitmapState state,
  ) async => faces.pathFor(
    profile: profile,
    shape: await shapeFor?.call(connId, profile),
    state: state,
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
    final icon = await _face(connId, profile, BotFaceBitmapState.idle);
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
        shortcutIconPath: icon,
        hideSensitive: hideSensitive,
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
