import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/agent_profile.dart';
import '../../../models/hosted_groups.dart';
import '../../../services/artifact_export_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/attachment_card.dart' show showImageViewer;
import '../../../widgets/chat/chat_markdown_body.dart';
import '../../../widgets/chat/chat_message_frame.dart';
import '../../../widgets/chat/chat_message_selection_area.dart';
import '../../../widgets/hermes_notice.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../../../widgets/room_team_row.dart' show RoomMemberAvatar;
import '../room_avatar_tile.dart';
import 'room_gateway.dart';
import 'room_models.dart';

/// Resolves the local profile (face, colour) of a member, if any.
typedef RoomProfileResolver = AgentProfile? Function(HostedGroupMember member);

String roomMemberName(HostedGroupMember? member, HostedGroupActor? actor) =>
    member?.displayName ?? member?.handle ?? actor?.publicLabel ?? '?';

/// Speaker name in the room: the local Bot's display name ("Astra"), the
/// same one the roster and its Bot Chat show, else [roomMemberName].
String roomSpeakerName(
  HostedGroupMember? member,
  HostedGroupActor? actor,
  AgentProfile? profile,
) {
  final title = profile?.botTitle?.trim();
  return title != null && title.isNotEmpty
      ? title
      : roomMemberName(member, actor);
}

String roomClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String roomElapsed(Duration value) {
  final d = value.isNegative ? Duration.zero : value;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

String roomAgo(Strings s, Duration value) {
  if (value.inMinutes < 1) return s.roomAgoNow;
  if (value.inHours < 1) return s.roomAgoMinutes(value.inMinutes);
  if (value.inDays < 1) return s.roomAgoHours(value.inHours);
  return s.roomAgoDays(value.inDays);
}

/// Face of a room member (real Bot face when local, neutral otherwise).
class RoomMemberFace extends StatelessWidget {
  final HostedGroupMember? member;
  final String fallbackName;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final double size;
  final bool working;

  const RoomMemberFace({
    super.key,
    required this.member,
    required this.fallbackName,
    required this.profile,
    required this.avatarCache,
    this.size = 30,
    this.working = false,
  });

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: RoomMemberAvatar(
      profileName: member?.handle ?? fallbackName,
      profile: profile,
      avatarCache: avatarCache,
      size: size,
      working: working,
    ),
  );
}

/// Room header avatar: the same [RoomAvatarTile] as the room's roster row
/// (2×2 grid of member faces, "+n" in the fourth cell), at header size.
class RoomHeaderFaces extends StatelessWidget {
  final List<HostedGroupMember> members;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;

  const RoomHeaderFaces({
    super.key,
    required this.members,
    required this.profileFor,
    required this.avatarCache,
  });

  static const double size = 36;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    return KeyedSubtree(
      key: const ValueKey('room-header-faces'),
      child: RoomAvatarTile(
        members: [
          for (final m in members)
            RoomAvatarTileMember(m.handle, profileFor(m)),
        ],
        avatarCache: avatarCache,
        size: size,
      ),
    );
  }
}

// ─── Separators ──────────────────────────────────────────────────────────────

class RoomSeparator extends StatelessWidget {
  final String label;
  final bool highlight;

  const RoomSeparator({super.key, required this.label, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = highlight ? colors.accent : colors.textSecondary;
    final line = highlight
        ? colors.accent.withValues(alpha: 0.35)
        : colors.divider.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: highlight ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ),
          Expanded(child: Container(height: 1, color: line)),
        ],
      ),
    );
  }
}

String roomDayLabel(Strings s, DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(DateTime(day.year, day.month, day.day)).inDays;
  if (diff == 0) return s.roomToday;
  if (diff == 1) return s.roomYesterday;
  return '${day.day.toString().padLeft(2, '0')}/'
      '${day.month.toString().padLeft(2, '0')}/${day.year}';
}

// ─── Messages ────────────────────────────────────────────────────────────────

/// One message of a group run. User messages are right bubbles; member
/// messages are full-width subtle cards. Face + coloured name + time only
/// on the first message of a run; no coloured side rail.
class RoomMessageTile extends StatelessWidget {
  final RoomMessageEntry entry;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final List<String> mentionHandles;
  final RoomAttachmentActions? attachmentActions;
  final VoidCallback? onReplyInThread;
  final VoidCallback? onOpenThread;
  final ValueChanged<String>? onMention;

  const RoomMessageTile({
    super.key,
    required this.entry,
    required this.profile,
    required this.avatarCache,
    required this.mentionHandles,
    this.attachmentActions,
    this.onReplyInThread,
    this.onOpenThread,
    this.onMention,
  });

  static const double faceSize = 28;

  void _onLink(BuildContext context, String? href) {
    if (href != null && href.startsWith('$roomMentionScheme:')) {
      onMention?.call(href.substring(roomMentionScheme.length + 1));
      return;
    }
    unawaited(openChatMarkdownLink(context, href));
  }

  Widget _markdown(BuildContext context) {
    final text = entry.body.text;
    if (text.trim().isEmpty) return const SizedBox.shrink();
    // Mentions become accent links; selection is owned by the frame, so the
    // body is not selectable on its own (never SelectableText, no inner
    // scroll-into-view on tap).
    return ChatMarkdownBody(
      data: linkifyRoomMentions(text, mentionHandles),
      selectable: false,
      onLinkTap: (href) => _onLink(context, href),
    );
  }

  List<Widget> _attachments() => [
    for (final ref in entry.body.attachments)
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: RoomAttachmentCard(
          key: ValueKey('room-attachment-${entry.event.eventId}-${ref.path}'),
          attachment: ref,
          actions: attachmentActions,
        ),
      ),
  ];

  Widget _actions(BuildContext context) {
    final s = Strings.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ChatCopyMessageButton(text: () => entry.event.publicText ?? ''),
        if (onReplyInThread != null)
          ChatMessageActionButton(
            key: ValueKey('room-reply-${entry.event.eventId}'),
            icon: Icons.reply_rounded,
            label: entry.isUser
                ? s.roomReplyInThread
                : s.roomReplyTo(
                    entry.member?.handle ?? entry.event.actor.publicLabel,
                  ),
            onPressed: onReplyInThread,
          ),
      ],
    );
  }

  Widget? _threadSummary(BuildContext context) {
    final thread = entry.thread;
    if (thread == null) return null;
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final last = thread.lastActor;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        key: ValueKey('room-thread-summary-${thread.threadId}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onOpenThread,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '↳ ',
                    style: TextStyle(color: colors.textSecondary),
                  ),
                  TextSpan(
                    text: s.roomThreadReplies(thread.replies),
                    style: TextStyle(
                      color: colors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (last != null)
                    TextSpan(
                      text:
                          ' ${s.roomThreadLastBy(last.kind == 'user' ? s.roomYou : last.publicLabel)}',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                ],
              ),
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final event = entry.event;
    final time = roomClock(roomEventTime(event));
    final summary = _threadSummary(context);
    if (entry.isUser) {
      return Padding(
        key: ValueKey('room-message-${event.eventId}'),
        padding: EdgeInsets.only(
          left: 56,
          right: 12,
          top: entry.firstOfRun ? 10 : 3,
          bottom: 2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ChatMessageSelectionArea(
              selectionIdentity: event.eventId,
              child: Container(
                key: ValueKey('room-user-bubble-${event.eventId}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant.withValues(alpha: 0.75),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(18),
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [_markdown(context), ..._attachments()],
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onReplyInThread != null)
                  ChatMessageActionButton(
                    key: ValueKey('room-reply-${event.eventId}'),
                    icon: Icons.reply_rounded,
                    iconSize: 15,
                    label: Strings.of(context).roomReplyInThread,
                    onPressed: onReplyInThread,
                  ),
                ChatMessageTimestamp(time),
              ],
            ),
            ?summary,
          ],
        ),
      );
    }
    final member = entry.member;
    final name = roomSpeakerName(member, event.actor, profile);
    final identity = roomMemberColor(
      member?.handle ?? name,
      profile: profile,
      avatarCache: avatarCache,
    );
    final card = Container(
      key: ValueKey('room-member-card-${event.eventId}'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [_markdown(context), ..._attachments()],
      ),
    );
    // Face + name + time sit on a header line; the card starts at the left
    // margin under it and uses the full width (no gutter under the face).
    return Padding(
      key: ValueKey('room-message-${event.eventId}'),
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        top: entry.firstOfRun ? 12 : 4,
      ),
      child: ChatMessageFrame(
        selectionIdentity: event.eventId,
        padding: EdgeInsets.zero,
        headerSpacing: 4,
        header: entry.firstOfRun
            ? Row(
                key: ValueKey('room-run-header-${event.eventId}'),
                children: [
                  RoomMemberFace(
                    key: ValueKey('room-face-${event.eventId}'),
                    member: member,
                    fallbackName: name,
                    profile: profile,
                    avatarCache: avatarCache,
                    size: faceSize,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: identity,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: colors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  _actions(context),
                ],
              )
            : null,
        children: [
          if (!entry.firstOfRun)
            Align(alignment: Alignment.centerRight, child: _actions(context)),
          card,
          ?summary,
        ],
      ),
    );
  }
}

/// Quiet "N passed · Activity ›" line after a discussion (T304).
class RoomPassesLine extends StatelessWidget {
  final RoomPassesEntry entry;
  final List<HostedGroupMember> members;
  final VoidCallback onOpenActivity;

  const RoomPassesLine({
    super.key,
    required this.entry,
    required this.members,
    required this.onOpenActivity,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final label = entry.memberIds.length == 1
        ? s.roomPassesOne(
            roomMemberName(
              roomMemberById(entry.memberIds.single, members),
              null,
            ),
          )
        : s.roomPassesMany(entry.memberIds.length);
    return Center(
      child: TextButton(
        key: ValueKey('room-passes-${entry.discussionId}'),
        onPressed: onOpenActivity,
        style: TextButton.styleFrom(
          foregroundColor: colors.textSecondary,
          textStyle: const TextStyle(fontSize: 11.5),
          minimumSize: const Size(0, 36),
        ),
        child: Text(label),
      ),
    );
  }
}

// ─── Round panel (T30A) ─────────────────────────────────────────────────────

({String label, Color fg, Color bg}) roomStateChip(
  BuildContext context,
  RoomTurnState state,
) {
  final s = Strings.of(context);
  final colors = Theme.of(context).hermes;
  return switch (state) {
    RoomTurnState.working => (
      label: s.roomStateWorking,
      fg: colors.success,
      bg: colors.success.withValues(alpha: 0.16),
    ),
    RoomTurnState.needsYou => (
      label: s.roomStateNeedsYou,
      fg: colors.warning,
      bg: colors.warning.withValues(alpha: 0.16),
    ),
    RoomTurnState.queued => (
      label: s.roomStateQueued,
      fg: colors.textSecondary,
      bg: colors.surfaceVariant,
    ),
    RoomTurnState.passed => (
      label: s.roomStatePassed,
      fg: colors.textSecondary,
      bg: colors.surfaceVariant,
    ),
    RoomTurnState.replied => (
      label: s.roomStateReplied,
      fg: colors.textPrimary,
      bg: colors.surfaceVariant,
    ),
    RoomTurnState.failed => (
      label: s.roomStateFailed,
      fg: colors.error,
      bg: colors.error.withValues(alpha: 0.14),
    ),
    RoomTurnState.stopped => (
      label: s.roomStateStopped,
      fg: colors.textSecondary,
      bg: colors.surfaceVariant,
    ),
    RoomTurnState.noReply => (
      label: s.roomStateNoReply,
      fg: colors.textDisabled,
      bg: colors.surfaceVariant,
    ),
  };
}

class RoomStateChip extends StatelessWidget {
  final RoomTurnState state;
  const RoomStateChip({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final chip = roomStateChip(context, state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: chip.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        chip.label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: chip.fg,
        ),
      ),
    );
  }
}

/// Colour of a member's state dot. One visual language for the whole room:
/// green = working, amber = needs you, red = failed (red is reserved for
/// failures), grey = waiting, done or no activity.
Color roomTurnDotColor(HermesThemeColors colors, RoomTurnState? state) =>
    switch (state) {
      RoomTurnState.working => colors.success,
      RoomTurnState.needsYou => colors.warning,
      RoomTurnState.failed => colors.error,
      RoomTurnState.passed || RoomTurnState.replied => colors.textSecondary,
      RoomTurnState.queued ||
      RoomTurnState.stopped ||
      RoomTurnState.noReply ||
      null => colors.textDisabled,
    };

/// One line that says who is doing what, in priority order: someone needs
/// you, something failed, who is working, else the idle status.
String roomStripSummary(
  Strings s, {
  required RoomRoundModel? round,
  required String idleStatus,
  required String Function(HostedGroupMember member) nameOf,
}) {
  if (round != null) {
    final needs = [
      for (final r in round.rows)
        if (r.state == RoomTurnState.needsYou) r,
    ];
    if (needs.length == 1) {
      return s.roomStripNeedsYou(nameOf(needs.single.member));
    }
    if (needs.length > 1) {
      return '${s.roomRoundLabel(round.round)} · ${s.roomRoundNeedsYou(needs.length)}';
    }
    final working = [
      for (final r in round.rows)
        if (r.state == RoomTurnState.working) r,
    ];
    final parts = <String>[];
    if (working.length == 1) {
      parts.add(s.roomStatusMemberWorking(nameOf(working.single.member)));
    } else if (working.length > 1) {
      parts
        ..add(s.roomRoundLabel(round.round))
        ..add(s.roomRoundWorking(working.length));
    }
    if (parts.isNotEmpty && round.queued > 0) {
      parts.add(s.roomRoundQueued(round.queued));
    }
    if (round.failed > 0) {
      if (parts.isEmpty) parts.add(s.roomRoundLabel(round.round));
      parts.add(s.roomRoundFailed(round.failed));
    }
    if (parts.isNotEmpty) return parts.join(' · ');
  }
  return idleStatus;
}

/// Fixed-height status strip (Bot Mode direction A): a face per member with
/// a state dot and one summary line. It never changes height, so a round
/// starting or ending never moves what the user is reading; tapping it opens
/// the per-member detail floating over the room.
class RoomStatusStrip extends StatelessWidget {
  /// Constant in every state (spec: status never resizes the transcript).
  static const double height = 48;
  static const int maxFaces = 5;
  static const double _faceSize = 26;

  final List<HostedGroupMember> members;
  final Map<String, RoomTurnState> states;
  final String summary;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback? onTap;

  const RoomStatusStrip({
    super.key,
    required this.members,
    required this.states,
    required this.summary,
    required this.profileFor,
    required this.avatarCache,
    this.onTap,
  });

  Widget _memberFace(BuildContext context, HostedGroupMember member) {
    final colors = Theme.of(context).hermes;
    final state = states[member.memberId];
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: SizedBox.square(
        dimension: _faceSize + 2,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            RoomMemberFace(
              member: member,
              fallbackName: member.handle,
              profile: profileFor(member),
              avatarCache: avatarCache,
              size: _faceSize,
              // The dot carries the state; an always-on animation here
              // would repaint the room every frame for as long as a bot
              // works. The floating detail animates the working faces.
              working: false,
            ),
            Positioned(
              right: -1,
              bottom: -1,
              child: SizedBox.square(
                key: ValueKey(
                  'room-strip-dot-${member.memberId}-${state?.name ?? 'idle'}',
                ),
                dimension: 11,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: roomTurnDotColor(colors, state),
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.background, width: 2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final shown = members.take(maxFaces).toList();
    final more = members.length - shown.length;
    return Semantics(
      button: onTap != null,
      label: s.roomStripDetail,
      child: InkWell(
        key: const ValueKey('room-status-strip'),
        onTap: onTap,
        child: Container(
          height: height,
          padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.divider.withValues(alpha: 0.5)),
            ),
          ),
          child: Row(
            children: [
              for (final m in shown) _memberFace(context, m),
              if (more > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    '+$more',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  summary,
                  key: const ValueKey('room-strip-summary'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: colors.textSecondary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Per-member detail of the current round (opened from the strip, floating
/// over the room): face, what it is doing, state chip, Stop all.
class RoomRoundDetail extends StatelessWidget {
  final RoomRoundModel round;
  final DateTime now;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback? onStopAll;
  final void Function(RoomRoundRow row)? onRetry;
  final VoidCallback? onOpenActivity;

  const RoomRoundDetail({
    super.key,
    required this.round,
    required this.now,
    required this.profileFor,
    required this.avatarCache,
    this.onStopAll,
    this.onRetry,
    this.onOpenActivity,
  });

  String _rowDetail(Strings s, RoomRoundRow row) => switch (row.state) {
    RoomTurnState.working => s.roomRowWorking(
      roomElapsed(now.difference(row.since ?? now)),
    ),
    RoomTurnState.needsYou =>
      row.approval?.command != null
          ? s.roomRowNeedsYou(row.approval!.command!)
          : s.roomRowApproval,
    RoomTurnState.queued => s.roomRowQueued,
    RoomTurnState.passed => s.roomRowPassed,
    RoomTurnState.replied => s.roomRowReplied,
    RoomTurnState.failed => s.roomRowFailed,
    RoomTurnState.stopped => s.roomRowStopped,
    RoomTurnState.noReply => s.roomRowNoReply,
  };

  Widget _row(BuildContext context, RoomRoundRow row) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final profile = profileFor(row.member);
    final retry =
        row.state == RoomTurnState.failed &&
        row.retryOffered &&
        onRetry != null;
    return Container(
      key: ValueKey('room-round-row-${row.member.memberId}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.divider.withValues(alpha: 0.35)),
        ),
      ),
      child: Row(
        children: [
          RoomMemberFace(
            member: row.member,
            fallbackName: row.member.handle,
            profile: profile,
            avatarCache: avatarCache,
            size: 28,
            working: row.state == RoomTurnState.working,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  roomSpeakerName(row.member, null, profile),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: roomMemberColor(
                      row.member.handle,
                      profile: profile,
                      avatarCache: avatarCache,
                    ),
                  ),
                ),
                Text(
                  _rowDetail(s, row),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (retry)
            TextButton(
              key: ValueKey('room-round-retry-${row.member.memberId}'),
              onPressed: () => onRetry!(row),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                foregroundColor: colors.error,
              ),
              child: Text(s.roomRetryAction),
            )
          else
            RoomStateChip(
              key: ValueKey(
                'room-round-chip-${row.member.memberId}-${row.state.name}',
              ),
              state: row.state,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      key: const ValueKey('room-round-sheet'),
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.roomRoundLabel(round.round),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (onStopAll != null && round.active)
                TextButton.icon(
                  key: const ValueKey('room-stop-all'),
                  onPressed: onStopAll,
                  icon: const Icon(Icons.stop_rounded, size: 16),
                  label: Text(s.roomStopAll),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.textPrimary,
                    backgroundColor: colors.surfaceVariant,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (final row in round.rows) _row(context, row),
          if (onOpenActivity != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('room-round-activity'),
                onPressed: onOpenActivity,
                child: Text(s.roomActivityTitle),
              ),
            ),
        ],
      ),
    );
  }
}

/// Floating "↓ N new" pill shown while the user reads above the newest
/// content; tapping it returns to the bottom.
class RoomNewPill extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const RoomNewPill({super.key, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Material(
      key: const ValueKey('room-new-pill'),
      color: colors.accent,
      elevation: 4,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_downward_rounded,
                size: 15,
                color: colors.onAccent,
              ),
              const SizedBox(width: 6),
              Text(
                s.roomNewPill(count),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colors.onAccent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Inline cards (T305/T306) ────────────────────────────────────────────────

class RoomApprovalCard extends StatelessWidget {
  final RoomApprovalAction action;
  final HostedGroupMember? member;
  final AgentProfile? profile;
  final bool busy;
  final void Function(String choice)? onChoice;

  const RoomApprovalCard({
    super.key,
    required this.action,
    required this.member,
    required this.profile,
    required this.busy,
    required this.onChoice,
  });

  static String choiceLabel(Strings s, String choice) => switch (choice) {
    'once' => s.roomApprovalOnce,
    'session' => s.roomApprovalSession,
    'always' => s.roomApprovalAlways,
    'deny' => s.roomApprovalDeny,
    _ => choice,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final name = roomSpeakerName(member, null, profile);
    final command = action.command ?? action.description ?? '';
    // Only choices the server offered, in a stable order.
    final choices = [
      for (final c in const ['once', 'session', 'always', 'deny'])
        if (action.offers(c)) c,
    ];
    return Container(
      key: ValueKey('room-approval-${action.requestId}'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: name,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: roomMemberColor(
                      member?.handle ?? name,
                      profile: profile,
                    ),
                  ),
                ),
                TextSpan(text: ' ${s.roomApprovalWants}'),
              ],
            ),
            style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
          ),
          if (command.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                command,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  color: colors.textPrimary,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < choices.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: _ChoiceButton(
                    key: ValueKey(
                      'room-approval-${action.requestId}-${choices[i]}',
                    ),
                    label: choiceLabel(s, choices[i]),
                    primary: choices[i] == 'once',
                    destructive: choices[i] == 'deny',
                    onPressed: busy || onChoice == null
                        ? null
                        : () => onChoice!(choices[i]),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  final String label;
  final bool primary;
  final bool destructive;
  final VoidCallback? onPressed;

  const _ChoiceButton({
    super.key,
    required this.label,
    required this.primary,
    required this.destructive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 40),
        backgroundColor: primary ? colors.accent : colors.background,
        foregroundColor: primary
            ? colors.onAccent
            : destructive
            ? colors.error
            : colors.textPrimary,
        disabledForegroundColor: colors.textDisabled,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class RoomRetryCard extends StatelessWidget {
  final String taskId;
  final HostedGroupMember? member;
  final bool busy;

  /// Null when the server does not offer a retry from here: the card then
  /// says so instead of showing a dead button.
  final VoidCallback? onRetry;

  /// Always available: a card never blocks the room without a way out.
  final VoidCallback onDismiss;

  const RoomRetryCard({
    super.key,
    required this.taskId,
    required this.member,
    required this.busy,
    required this.onRetry,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Container(
      key: ValueKey('room-retry-$taskId'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.roomRetryTitle(
                    member == null ? '?' : roomMemberName(member, null),
                  ),
                  style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
                ),
                if (onRetry == null)
                  Text(
                    s.roomRetryUnavailable,
                    key: ValueKey('room-retry-$taskId-unavailable'),
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
              ],
            ),
          ),
          if (onRetry != null)
            TextButton(
              key: ValueKey('room-retry-$taskId-action'),
              onPressed: busy ? null : onRetry,
              style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
              child: Text(s.roomRetryAction),
            ),
          TextButton(
            key: ValueKey('room-retry-$taskId-dismiss'),
            onPressed: busy ? null : onDismiss,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 40),
              foregroundColor: colors.textSecondary,
            ),
            child: Text(s.roomRetryDismiss),
          ),
        ],
      ),
    );
  }
}

// ─── Attachment card (T309) ─────────────────────────────────────────────────

class RoomAttachmentCard extends StatefulWidget {
  final RoomAttachmentRef attachment;
  final RoomAttachmentActions? actions;

  const RoomAttachmentCard({
    super.key,
    required this.attachment,
    required this.actions,
  });

  @override
  State<RoomAttachmentCard> createState() => _RoomAttachmentCardState();
}

enum _AttachmentOp { preview, download, open, share }

class _RoomAttachmentCardState extends State<RoomAttachmentCard> {
  bool _busy = false;
  File? _file;

  Future<void> _run(_AttachmentOp op) async {
    final actions = widget.actions;
    if (actions == null || _busy) return;
    final s = Strings.of(context);
    final notice = HermesNotice.of(context);
    setState(() => _busy = true);
    try {
      final file = _file ?? await actions.fetch(widget.attachment);
      if (!mounted) return;
      _file = file;
      switch (op) {
        case _AttachmentOp.preview:
          await showImageViewer(context, file);
        case _AttachmentOp.download:
          final result = await actions.save(widget.attachment, file);
          if (result == ArtifactSaveResult.saved) {
            notice.showSnackBar(
              SnackBar(content: Text(s.roomFileSaved)),
              kind: HermesNoticeKind.success,
            );
          }
        case _AttachmentOp.open:
          await actions.open(widget.attachment, file);
        case _AttachmentOp.share:
          await actions.share(widget.attachment, file);
      }
    } catch (_) {
      notice.showSnackBar(
        SnackBar(content: Text(s.roomFileFailed)),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final ref = widget.attachment;
    final enabled = !_busy && (widget.actions?.canFetch(ref) ?? false);
    Widget action(String key, IconData icon, String label, _AttachmentOp op) =>
        ChatMessageActionButton(
          key: ValueKey('room-attachment-$key-${ref.path}'),
          icon: icon,
          label: label,
          iconSize: 18,
          onPressed: enabled ? () => unawaited(_run(op)) : null,
        );
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          InkWell(
            key: ValueKey('room-attachment-preview-${ref.path}'),
            borderRadius: BorderRadius.circular(12),
            onTap: enabled
                ? () => unawaited(
                    _run(
                      ref.isImage ? _AttachmentOp.preview : _AttachmentOp.open,
                    ),
                  )
                : null,
            child: SizedBox(
              width: 48,
              height: 48,
              child: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : ref.isImage && _file != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(_file!, fit: BoxFit.cover),
                    )
                  : Icon(
                      ref.isImage
                          ? Icons.image_outlined
                          : Icons.insert_drive_file_outlined,
                      color: colors.textSecondary,
                    ),
            ),
          ),
          Expanded(
            child: Text(
              ref.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
            ),
          ),
          action(
            'download',
            Icons.download_rounded,
            s.roomFileDownload,
            _AttachmentOp.download,
          ),
          action(
            'open',
            Icons.open_in_new_rounded,
            s.roomFileOpen,
            _AttachmentOp.open,
          ),
          action(
            'share',
            Icons.ios_share_rounded,
            s.roomFileShare,
            _AttachmentOp.share,
          ),
        ],
      ),
    );
  }
}

/// Plain-text copy of a message for the clipboard.
Future<void> copyRoomText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
}
