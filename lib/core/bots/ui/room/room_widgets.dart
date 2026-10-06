import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/agent_profile.dart';
import '../../../models/attachment_draft.dart';
import '../../../models/hosted_groups.dart';
import '../../../services/artifact_export_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/attachment_card.dart' show showImageViewer;
import '../../../widgets/attachment_preview.dart';
import '../../../widgets/chat/chat_markdown_body.dart';
import '../../../widgets/chat/chat_message_frame.dart';
import '../../../widgets/chat/chat_message_selection_area.dart';
import '../../../widgets/hermes_notice.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../../../widgets/room_team_row.dart' show RoomMemberAvatar;
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

/// Time until [roomAgo] of an age of [elapsed] shows another label: the
/// next whole minute under an hour, the next hour under a day, else the
/// next day.
Duration roomAgoNextChange(Duration elapsed) {
  if (elapsed.isNegative) return const Duration(minutes: 1) - elapsed;
  final unit = elapsed < const Duration(hours: 1)
      ? const Duration(minutes: 1)
      : elapsed < const Duration(days: 1)
      ? const Duration(hours: 1)
      : const Duration(days: 1);
  return unit -
      Duration(microseconds: elapsed.inMicroseconds % unit.inMicroseconds);
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
/// A message sent from this device that the server has not acknowledged
/// yet: the user bubble, dimmed while sending, or marked "Not sent" with
/// Retry when delivery failed.
class RoomPendingMessageTile extends StatelessWidget {
  final String id;
  final String text;
  final List<AttachmentDraft> attachments;
  final bool failed;
  final VoidCallback onRetry;

  const RoomPendingMessageTile({
    super.key,
    required this.id,
    required this.text,
    required this.attachments,
    required this.failed,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(left: 56, right: 12, top: 10, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Opacity(
            opacity: failed ? 1 : 0.7,
            child: Container(
              key: ValueKey('room-pending-bubble-$id'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: colors.surfaceVariant.withValues(alpha: 0.75),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(5),
                ),
                border: failed
                    ? Border.all(color: colors.error.withValues(alpha: 0.6))
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (text.isNotEmpty)
                    ChatMarkdownBody(data: text, selectable: false),
                  // Same card as the sent bubble, from the local file:
                  // nothing is on the server yet, so no file actions.
                  for (final draft in attachments)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: RoomAttachmentCard(
                        key: ValueKey(
                          'room-pending-attachment-$id-${draft.localPath}',
                        ),
                        attachment: RoomAttachmentRef(
                          name: draft.name,
                          path: draft.localPath,
                        ),
                        actions: null,
                        localFile: File(draft.localPath),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (failed)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 14,
                  color: colors.error,
                ),
                const SizedBox(width: 4),
                Text(
                  s.rs1215NotSent,
                  key: ValueKey('room-pending-failed-$id'),
                  style: TextStyle(fontSize: 11.5, color: colors.error),
                ),
                TextButton(
                  key: ValueKey('room-pending-retry-$id'),
                  onPressed: onRetry,
                  child: Text(s.rs1215Retry),
                ),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                s.rs1215Sending,
                key: ValueKey('room-pending-sending-$id'),
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class RoomMessageTile extends StatelessWidget {
  final RoomMessageEntry entry;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final List<String> mentionHandles;
  final RoomAttachmentActions? attachmentActions;
  final VoidCallback? onReplyInThread;
  final VoidCallback? onOpenThread;
  final ValueChanged<String>? onMention;

  /// rp1215: tap on the quote chip (shows the quoted message).
  final VoidCallback? onOpenQuote;

  /// rp1215: this owner message was just shown from a quote chip.
  final bool highlighted;

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
    this.onOpenQuote,
    this.highlighted = false,
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

  /// rp1215: «↪ You: Mira por ejemplo las fotos…» above a reply, one line;
  /// tapping it shows the quoted message.
  Widget? _quoteChip(BuildContext context) {
    final quote = entry.quote;
    if (quote == null) return null;
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    // Not part of the reply's selectable text: copying a reply never
    // carries «You: …» along.
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: SelectionContainer.disabled(
        child: Semantics(
          button: onOpenQuote != null,
          label: s.rp1215QuoteSemantics(quote.preview),
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey('room-quote-${entry.event.eventId}'),
            borderRadius: BorderRadius.circular(8),
            onTap: onOpenQuote,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                children: [
                  Container(
                    width: 2,
                    height: 16,
                    margin: const EdgeInsets.only(left: 2, right: 6),
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Icon(
                    Icons.subdirectory_arrow_right_rounded,
                    size: 14,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${s.roomYou}: ',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: colors.textSecondary,
                            ),
                          ),
                          TextSpan(text: quote.preview),
                        ],
                      ),
                      key: ValueKey('room-quote-text-${entry.event.eventId}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
      final reduceMotion =
          MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      return Padding(
        key: ValueKey('room-message-${event.eventId}'),
        padding: EdgeInsets.only(
          left: 56,
          right: 12,
          top: entry.firstOfRun ? 10 : 3,
          bottom: 2,
        ),
        // rp1215: brief accent wash when a quote chip brought the reader
        // here. Always mounted, so marking it never remounts the bubble.
        child: AnimatedContainer(
          key: ValueKey('room-message-highlight-${event.eventId}'),
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 220),
          decoration: BoxDecoration(
            color: highlighted
                ? colors.accent.withValues(alpha: 0.14)
                : colors.accent.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(20),
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
          ?_quoteChip(context),
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
      fg: colors.textTertiary,
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
/// you, who is replying (and for how long), something failed, else the idle
/// status.
String roomStripSummary(
  Strings s, {
  required RoomRoundModel? round,
  required String idleStatus,
  required String Function(HostedGroupMember member) nameOf,
  DateTime? now,
}) {
  if (round != null) {
    final needs = [
      for (final r in round.rows)
        if (r.state == RoomTurnState.needsYou) r,
    ];
    if (needs.length == 1) {
      return s.roomStripNeedsYou(nameOf(needs.single.member));
    }
    if (needs.length > 1) return s.rhdrNeedsYouMany(needs.length);
    final working = [
      for (final r in round.rows)
        if (r.state == RoomTurnState.working) r,
    ];
    final parts = <String>[];
    if (working.length == 1) {
      final one = working.single;
      parts.add(s.roomStripReplying(nameOf(one.member)));
      final since = one.since;
      if (now != null && since != null) {
        parts.add(roomElapsed(now.difference(since)));
      }
    } else if (working.length == 2) {
      parts.add(
        s.roomStripReplyingTwo(
          nameOf(working[0].member),
          nameOf(working[1].member),
        ),
      );
    } else if (working.length > 2) {
      parts.add(s.roomStripReplyingMany(working.length.toString()));
    }
    if (round.failed > 0) {
      if (parts.isEmpty) parts.add(s.roomRoundLabel(round.round));
      parts.add(s.roomRoundFailed(round.failed));
    }
    if (parts.isNotEmpty) return parts.join(' · ');
  }
  return idleStatus;
}

/// The replying bot at the bottom of the conversation, where its answer
/// will land: its face beside a quiet bubble. Driven only by the server's
/// turn state (started, not yet settled); it never guesses from text. Still
/// on purpose: an endless animation here would repaint the room every frame
/// for the whole turn.
class RoomTypingRow extends StatelessWidget {
  final HostedGroupMember member;
  final String name;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;

  const RoomTypingRow({
    super.key,
    required this.member,
    required this.name,
    required this.profile,
    required this.avatarCache,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    Widget dot() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox.square(
        dimension: 6,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.textSecondary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          RoomMemberFace(
            member: member,
            fallbackName: member.handle,
            profile: profile,
            avatarCache: avatarCache,
            size: 28,
          ),
          const SizedBox(width: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [dot(), dot(), dot()],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              s.roomTypingLabel(name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-member detail of the current round (opened from the header, floating
/// over the room): face, what it is doing, state chip, Stop all.
class RoomRoundDetail extends StatelessWidget {
  final RoomRoundModel round;
  final DateTime now;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback? onStopAll;
  final void Function(RoomRoundRow row)? onRetry;
  final VoidCallback? onOpenActivity;

  /// Opens the members sheet (who is in the room, availability).
  final VoidCallback? onOpenMembers;

  const RoomRoundDetail({
    super.key,
    required this.round,
    required this.now,
    required this.profileFor,
    required this.avatarCache,
    this.onStopAll,
    this.onRetry,
    this.onOpenActivity,
    this.onOpenMembers,
  });

  String _rowDetail(Strings s, RoomRoundRow row) => switch (row.state) {
    RoomTurnState.working => s.roomRowWorking(
      roomElapsed(now.difference(row.since ?? now)),
    ),
    RoomTurnState.needsYou => _needsYouDetail(s, row),
    RoomTurnState.queued => s.roomRowQueued,
    RoomTurnState.passed => s.roomRowPassed,
    RoomTurnState.replied => s.roomRowReplied,
    RoomTurnState.failed => s.roomRowFailed,
    RoomTurnState.stopped => s.roomRowStopped,
    RoomTurnState.noReply => s.roomRowNoReply,
  };

  static String _needsYouDetail(Strings s, RoomRoundRow row) {
    final prompt = row.prompt;
    final approval = row.approval;
    if (approval == null && prompt is! RoomMemberApproval) {
      // A clarify question or an unreadable wait on a human.
      return s.rq1215RowWaitingAnswer;
    }
    final command =
        approval?.command ??
        (prompt is RoomMemberApproval ? prompt.command : null);
    return command != null ? s.roomRowNeedsYou(command) : s.roomRowApproval;
  }

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
          if (onOpenActivity != null || onOpenMembers != null)
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                if (onOpenMembers != null)
                  TextButton(
                    key: const ValueKey('room-round-members'),
                    onPressed: onOpenMembers,
                    child: Text(s.roomMenuMembers),
                  ),
                if (onOpenActivity != null)
                  TextButton(
                    key: const ValueKey('room-round-activity'),
                    onPressed: onOpenActivity,
                    child: Text(s.roomActivityTitle),
                  ),
              ],
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
        // App font (Inter) like every other button; a bare TextStyle here
        // dropped to the platform default family.
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// A member's open `clarify` question, answerable from the room with one of
/// the offered choices or free text.
class RoomMemberClarifyCard extends StatefulWidget {
  final RoomMemberClarify prompt;
  final HostedGroupMember? member;
  final AgentProfile? profile;
  final bool busy;

  /// Null when this room cannot answer (read-only): the question still
  /// shows, without live controls.
  final void Function(String answer)? onAnswer;

  const RoomMemberClarifyCard({
    super.key,
    required this.prompt,
    required this.member,
    required this.profile,
    required this.busy,
    required this.onAnswer,
  });

  @override
  State<RoomMemberClarifyCard> createState() => _RoomMemberClarifyCardState();
}

class _RoomMemberClarifyCardState extends State<RoomMemberClarifyCard> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    widget.onAnswer?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final prompt = widget.prompt;
    final name = roomSpeakerName(widget.member, null, widget.profile);
    final id = 'room-member-clarify-${prompt.requestId}';
    final enabled = !widget.busy && widget.onAnswer != null;
    return Container(
      key: ValueKey(id),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 16, color: colors.warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.rq1215ClarifyAsks(name),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: roomMemberColor(
                      widget.member?.handle ?? name,
                      profile: widget.profile,
                    ),
                  ),
                ),
              ),
              if (prompt.total > 1)
                Text(
                  s.rq1215ClarifyStep(prompt.index, prompt.total),
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            prompt.question,
            style: TextStyle(fontSize: 14, color: colors.textPrimary),
          ),
          for (var i = 0; i < prompt.choices.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _ChoiceButton(
                key: ValueKey('$id-choice-$i'),
                label: prompt.choices[i],
                primary: i == 0,
                destructive: false,
                onPressed: enabled
                    ? () => widget.onAnswer!(prompt.choices[i])
                    : null,
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('$id-text'),
                  controller: _text,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: TextStyle(fontSize: 13.5, color: colors.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: s.rq1215ClarifyHint,
                    filled: true,
                    fillColor: colors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                key: ValueKey('$id-send'),
                onPressed: enabled ? _send : null,
                style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
                child: Text(s.rq1215ClarifySend),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Honest fallback when a member's session waits on a human but the room
/// cannot show the request: open that bot's chat, or (confirmed) cancel the
/// wait of that runtime only.
class RoomMemberWaitingBanner extends StatelessWidget {
  final HostedGroupMember member;
  final AgentProfile? profile;
  final bool busy;
  final VoidCallback? onOpenChat;
  final VoidCallback? onCancelWait;

  const RoomMemberWaitingBanner({
    super.key,
    required this.member,
    required this.profile,
    required this.busy,
    required this.onOpenChat,
    required this.onCancelWait,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final id = 'room-member-waiting-${member.memberId}';
    return Container(
      key: ValueKey(id),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.warning.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.hourglass_top_rounded,
                size: 18,
                color: colors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.rq1215WaitingUnreachable(
                        roomSpeakerName(member, null, profile),
                      ),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.textPrimary,
                      ),
                    ),
                    if (onOpenChat != null)
                      Text(
                        s.rq1215WaitingUnreachableHint,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              if (onCancelWait != null)
                TextButton(
                  key: ValueKey('$id-cancel'),
                  onPressed: busy ? null : onCancelWait,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    foregroundColor: colors.error,
                  ),
                  child: Text(s.rq1215CancelWait),
                ),
              if (onOpenChat != null)
                TextButton(
                  key: ValueKey('$id-open'),
                  onPressed: onOpenChat,
                  style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
                  child: Text(s.rq1215OpenChat),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A member whose room turn cannot start because its room session has no
/// live runtime on the server (the driver only keeps retrying). [onResume]
/// is null on a read-only connection: the banner then only explains.
class RoomMemberStallBanner extends StatelessWidget {
  final HostedGroupMember member;
  final AgentProfile? profile;
  final bool busy;
  final VoidCallback? onResume;

  const RoomMemberStallBanner({
    super.key,
    required this.member,
    required this.profile,
    required this.busy,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final id = 'room-member-stall-${member.memberId}';
    return Container(
      key: ValueKey(id),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.warning.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.sync_problem_rounded, size: 18, color: colors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.rr1215StallTitle(
                        roomSpeakerName(member, null, profile),
                      ),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      onResume == null
                          ? s.rr1215StallReadOnlyHint
                          : s.rr1215StallHint,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (onResume != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: ValueKey('$id-resume'),
                onPressed: busy ? null : onResume,
                style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(s.rr1215Resume),
              ),
            )
          else
            const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class RoomRetryCard extends StatelessWidget {
  final String taskId;
  final HostedGroupMember? member;

  /// Local profile of [member], so the card names it like the strip does.
  final AgentProfile? profile;
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
    this.profile,
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
                    member == null
                        ? s.roomRetryUnknownMember
                        : roomSpeakerName(member, null, profile),
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

  /// Local copy of a not-yet-sent attachment: shown as the thumbnail, and
  /// the card offers no file actions because the server has nothing yet.
  final File? localFile;

  const RoomAttachmentCard({
    super.key,
    required this.attachment,
    required this.actions,
    this.localFile,
  });

  @override
  State<RoomAttachmentCard> createState() => _RoomAttachmentCardState();
}

enum _AttachmentOp { preview, download, open, share }

class _RoomAttachmentCardState extends State<RoomAttachmentCard> {
  bool _busy = false;

  /// A cached copy (reopened room, app restart, finished prefetch) paints on
  /// the first frame without any network.
  late File? _file = widget.localFile ?? _cachedCopy();
  bool _previewFailed = false;

  File? _cachedCopy() {
    final actions = widget.actions;
    if (!_hasMediaPreview || actions is! RoomAttachmentCache) return null;
    return (actions as RoomAttachmentCache).cachedFile(widget.attachment);
  }

  /// Bounded preview fetches across every room card on screen: a long room
  /// full of photos must not open dozens of downloads at once.
  static const int _maxConcurrentPreviews = 2;
  static int _activePreviews = 0;
  static final List<Completer<void>> _previewWaiters = <Completer<void>>[];

  AttachmentPreviewKind get _kind =>
      attachmentPreviewKindFor(widget.attachment.name, '');

  /// Images, videos and audio preview in place, so they are fetched without
  /// a tap; documents still wait for one.
  bool get _hasMediaPreview => switch (_kind) {
    AttachmentPreviewKind.image ||
    AttachmentPreviewKind.video ||
    AttachmentPreviewKind.audio => true,
    _ => false,
  };

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
  }

  Future<void> _loadPreview() async {
    final actions = widget.actions;
    if (_file != null ||
        !_hasMediaPreview ||
        actions == null ||
        !actions.canFetch(widget.attachment)) {
      return;
    }
    if (_activePreviews >= _maxConcurrentPreviews) {
      final waiter = Completer<void>();
      _previewWaiters.add(waiter);
      await waiter.future;
    } else {
      _activePreviews++;
    }
    try {
      if (!mounted || _file != null) return;
      final file = await actions.fetch(widget.attachment);
      if (!mounted) return;
      setState(() => _file ??= file);
    } catch (_) {
      if (mounted) setState(() => _previewFailed = true);
    } finally {
      if (_previewWaiters.isNotEmpty) {
        _previewWaiters.removeAt(0).complete();
      } else {
        _activePreviews--;
      }
    }
  }

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
    final file = _file;
    // Media the server will not serve (outside the managed files, sensitive,
    // or no connection) is labelled instead of spinning or showing a path.
    final unavailable =
        _previewFailed ||
        (_hasMediaPreview && file == null && !enabled && !_busy);
    final Widget? preview = file != null && _hasMediaPreview && !_previewFailed
        ? AttachmentPreview(
            key: ValueKey('room-attachment-media-${ref.path}'),
            name: ref.name,
            mimeType: '',
            sizeLabel: '',
            file: file,
          )
        : _kind == AttachmentPreviewKind.image &&
              file == null &&
              !_previewFailed &&
              (widget.actions?.canFetch(ref) ?? false)
        // The image's box is reserved while its bytes arrive, so the card
        // does not grow under the reader when they land.
        ? Container(
            key: ValueKey('room-attachment-skeleton-${ref.path}'),
            width: AttachmentPreview.imageExtent,
            height: AttachmentPreview.imageExtent,
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
            ),
          )
        : null;
    Widget action(String key, IconData icon, String label, _AttachmentOp op) =>
        ChatMessageActionButton(
          key: ValueKey('room-attachment-$key-${ref.path}'),
          icon: icon,
          label: label,
          iconSize: 18,
          onPressed: enabled ? () => unawaited(_run(op)) : null,
        );
    final openOp = ref.isImage ? _AttachmentOp.preview : _AttachmentOp.open;
    // Media with a preview shows it above a slim name row; everything else
    // is the shared type card (badge, short name) instead of a bare name.
    final Widget leading = preview != null
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Icon(
              _kind == AttachmentPreviewKind.video
                  ? Icons.movie_outlined
                  : _kind == AttachmentPreviewKind.audio
                  ? Icons.graphic_eq_rounded
                  : Icons.image_outlined,
              size: 18,
              color: colors.textSecondary,
            ),
          )
        : InkWell(
            key: ValueKey('room-attachment-preview-${ref.path}'),
            borderRadius: BorderRadius.circular(12),
            onTap: enabled ? () => unawaited(_run(openOp)) : null,
            child: SizedBox(
              width: 48,
              height: 48,
              child:
                  _busy ||
                      (_hasMediaPreview &&
                          file == null &&
                          enabled &&
                          !_previewFailed)
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _kind == AttachmentPreviewKind.video
                          ? Icons.movie_outlined
                          : ref.isImage
                          ? Icons.image_outlined
                          : Icons.insert_drive_file_outlined,
                      color: colors.textSecondary,
                    ),
            ),
          );
    final Widget label = preview != null || _hasMediaPreview
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                middleEllipsis(ref.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
              ),
              // A fetch the server refused (403/404/not allowed) says so,
              // by name only: the server path is never shown.
              if (unavailable)
                Text(
                  s.cm1215AttachmentUnavailable,
                  key: ValueKey('room-attachment-unavailable-${ref.path}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
            ],
          )
        : Align(
            alignment: AlignmentDirectional.centerStart,
            child: AttachmentPreview(
              name: ref.name,
              mimeType: '',
              sizeLabel: '',
              onOpen: enabled ? () => unawaited(_run(openOp)) : null,
            ),
          );
    final row = Row(
      children: [
        if (preview != null || _hasMediaPreview) leading,
        Expanded(
          child: preview == null && !_hasMediaPreview
              ? Padding(padding: const EdgeInsets.all(6), child: label)
              : label,
        ),
        if (widget.localFile != null) const SizedBox(width: 12),
        if (widget.localFile == null) ...[
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
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.45)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (preview != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
              child: preview,
            ),
          row,
        ],
      ),
    );
  }
}

/// Plain-text copy of a message for the clipboard.
Future<void> copyRoomText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
}
