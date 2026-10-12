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
import '../../../widgets/chat/quick_reaction_bar.dart';
import '../../../widgets/hermes_notice.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../../../widgets/room_team_row.dart' show RoomMemberAvatar;
import '../roster/living_bot_face.dart';
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

  /// Live surfaces (round and members sheets): the member's living face
  /// moving with this state on the shared face clocks. Null (transcript
  /// rows, pickers) keeps the still avatar.
  final BotFaceSignal? signal;

  /// The member's living face at rest and not moving: the faces that stand
  /// on a room's island. Takes the place of [signal].
  final bool still;

  const RoomMemberFace({
    super.key,
    required this.member,
    required this.fallbackName,
    required this.profile,
    required this.avatarCache,
    this.size = 30,
    this.working = false,
    this.signal,
    this.still = false,
  });

  @override
  Widget build(BuildContext context) {
    final profile = this.profile;
    final signal = still ? BotFaceSignal.idle : this.signal;
    return SizedBox.square(
      dimension: size,
      child: profile != null && signal != null
          ? LivingBotFace(
              profileName: profile.name,
              profile: profile,
              avatarCache: avatarCache,
              signal: signal,
              size: size,
              entrance: false,
              animate: !still,
              // Rooms draw their own state dots.
              stateMark: false,
            )
          : RoomMemberAvatar(
              profileName: member?.handle ?? fallbackName,
              profile: profile,
              avatarCache: avatarCache,
              size: size,
              working: working,
            ),
    );
  }
}

/// How a room member's face moves for its turn [state].
BotFaceSignal roomTurnFaceSignal(RoomTurnState? state) => switch (state) {
  RoomTurnState.working => BotFaceSignal.working,
  RoomTurnState.needsYou => BotFaceSignal.attention,
  _ => BotFaceSignal.idle,
};

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

  /// Long-press opens the message panel (Copy, Reply, Select text). Rooms
  /// have no reactions: the panel carries no reactions row.
  Widget _withMessageActions(BuildContext context, Widget child) {
    final s = Strings.of(context);
    return MessageQuickReactScope(
      copyText: () => entry.event.publicText ?? '',
      onReply: onReplyInThread,
      replyLabel: entry.isUser
          ? s.roomReplyInThread
          : s.roomReplyTo(
              entry.member?.handle ?? entry.event.actor.publicLabel,
            ),
      child: child,
    );
  }

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
          label: quote.speaker == null
              ? s.rp1215QuoteSemantics(quote.preview)
              : s.rr1215QuoteOfSemantics(quote.speaker!, quote.preview),
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
                            text: '${quote.speaker ?? s.roomYou}: ',
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
      return _withMessageActions(
        context,
        Padding(
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
            key: ValueKey('room-highlight-${event.eventId}'),
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
                ?_quoteChip(context),
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
    return _withMessageActions(
      context,
      Padding(
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
                    // Face, name and time take everything left of the actions;
                    // the name is the only flexible child there, so it uses
                    // all of that width and ellipsizes only when it truly
                    // runs out (a Spacer next to it used to take half).
                    Expanded(
                      child: Row(
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
                        ],
                      ),
                    ),
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
      ),
    );
  }
}

/// Quiet "N passed · Activity ›" line after a discussion (T304).
class RoomPassesLine extends StatelessWidget {
  final RoomPassesEntry entry;
  final List<HostedGroupMember> members;
  final VoidCallback onOpenActivity;
  final RoomProfileResolver? profileFor;

  const RoomPassesLine({
    super.key,
    required this.entry,
    required this.members,
    required this.onOpenActivity,
    this.profileFor,
  });

  String _name(HostedGroupMember? member) => roomSpeakerName(
    member,
    null,
    member == null ? null : profileFor?.call(member),
  );

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final label = entry.memberIds.length == 1
        ? s.roomPassesOne(
            _name(roomMemberById(entry.memberIds.single, members)),
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

/// Short turn duration: "18 s" under a minute, else "1:52".
String roomTook(Duration d) =>
    d.inSeconds < 60 ? '${d.inSeconds} s' : roomElapsed(d);

/// A localized label for a room turn's `reason_code`, or null for a code
/// with no label (never shown raw).
String? roomReasonText(Strings s, String? code) => switch (code) {
  'provider_quota_limit' => s.rat1215ReasonQuota,
  'provider_rate_limit' => s.rat1215ReasonRate,
  'provider_auth_or_access' => s.rat1215ReasonAuth,
  'provider_server_error' => s.rat1215ReasonServer,
  'context_overflow' => s.rat1215ReasonContext,
  'model_unavailable' => s.rat1215ReasonModel,
  'missing_config' => s.rat1215ReasonConfig,
  'runtime_offline' => s.rat1215ReasonOffline,
  'delivery_timeout' || 'queued_expired' => s.rat1215ReasonTimeout,
  'agent_blocked' => s.rat1215ReasonBlocked,
  _ => null,
};

String _roomStepLabel(Strings s, RoomLiveStep step) => switch (step.kind) {
  RoomLiveStepKind.thinking => s.rat1215StepThinking,
  RoomLiveStepKind.writing => s.rat1215StepWriting,
  RoomLiveStepKind.tool => [step.tool!, ?step.context].join(' · '),
};

/// What one member is doing in the round, from what the server reported:
/// the live step of a local member, the reply time, the failure reason or
/// the place in the queue. Nothing is shown that the server did not send.
String roomRowStatusText(Strings s, RoomRoundRow row, DateTime now) {
  final elapsed = roomElapsed(now.difference(row.since ?? now));
  switch (row.state) {
    case RoomTurnState.working:
      final step = row.live?.current;
      return switch (step?.kind) {
        RoomLiveStepKind.tool => '${_roomStepLabel(s, step!)} · $elapsed',
        RoomLiveStepKind.thinking => s.rat1215Thinking(elapsed),
        RoomLiveStepKind.writing => s.rat1215Writing(elapsed),
        null => s.roomRowWorking(elapsed),
      };
    case RoomTurnState.needsYou:
      final prompt = row.prompt;
      if (row.approval != null || prompt is RoomMemberApproval) {
        return s.rat1215WaitingPermission(elapsed);
      }
      return s.rq1215RowWaitingAnswer;
    case RoomTurnState.queued:
      if (row.deferred && row.reasonCode == 'member_unavailable') {
        return s.rat1215Unavailable;
      }
      final position = row.queuePosition;
      if (position == null) return s.rat1215Waiting;
      return position == 1 ? s.rat1215Next : s.rat1215WaitingTurn(position);
    case RoomTurnState.passed:
      return s.rat1215Passed;
    case RoomTurnState.replied:
      final took = row.took;
      return took == null ? s.roomRowReplied : s.rat1215Replied(roomTook(took));
    case RoomTurnState.failed:
      final reason = roomReasonText(s, row.reasonCode);
      return reason == null ? s.roomRowFailed : s.rat1215Error(reason);
    case RoomTurnState.stopped:
      return row.reasonCode == 'superseded_by_newer_user_event'
          ? s.rat1215Superseded
          : s.roomRowStopped;
    case RoomTurnState.noReply:
      return s.roomRowNoReply;
  }
}

/// "2 of 4 replied" when the round's size is known, else "2 replied";
/// failures are counted apart.
String roomRoundProgressText(Strings s, RoomRoundModel round) {
  final total = round.total;
  final parts = [
    total != null
        ? s.rat1215Progress(round.responded, total)
        : s.rat1215ProgressOpen(round.responded),
    if (round.failed > 0) s.roomRoundFailed(round.failed),
  ];
  return parts.join(' · ');
}

/// The room's Activity sheet (opened from the header, floating over the
/// room): round progress, approvals waiting for you on top, then one row per
/// member saying exactly what it is doing. Tapping a member who replied
/// jumps to the reply; tapping the working one unfolds its live steps.
/// Earlier rounds stay folded. Stop all is kept, quiet, at the bottom.
class RoomRoundDetail extends StatefulWidget {
  final RoomRoundModel round;
  final DateTime now;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback? onStopAll;
  final void Function(RoomRoundRow row)? onRetry;

  /// Cards for approvals waiting on the user, shown above the members.
  final List<Widget> approvals;

  /// Jumps to a reply in the transcript (`message_event_id`).
  final void Function(String eventId)? onOpenReply;

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
    this.approvals = const [],
    this.onOpenReply,
    this.onOpenMembers,
  });

  @override
  State<RoomRoundDetail> createState() => _RoomRoundDetailState();
}

class _RoomRoundDetailState extends State<RoomRoundDetail> {
  String? _expanded;
  bool _previousOpen = false;

  VoidCallback? _tapFor(RoomRoundRow row) {
    final reply = row.replyEventId;
    final open = widget.onOpenReply;
    if (reply != null && open != null) return () => open(reply);
    final steps = row.live?.steps ?? const <RoomLiveStep>[];
    if (row.state == RoomTurnState.working && steps.isNotEmpty) {
      final id = row.member.memberId;
      return () => setState(() => _expanded = _expanded == id ? null : id);
    }
    return null;
  }

  Widget _row(
    BuildContext context,
    RoomRoundRow row, {
    String keyPrefix = 'room-round',
    double face = 28,
    bool interactive = true,
  }) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final profile = widget.profileFor(row.member);
    final id = row.member.memberId;
    final retry =
        interactive &&
        row.state == RoomTurnState.failed &&
        row.retryOffered &&
        widget.onRetry != null;
    final onTap = interactive ? _tapFor(row) : null;
    final text = roomRowStatusText(s, row, widget.now);
    final expanded = interactive && _expanded == id;
    return InkWell(
      key: ValueKey('$keyPrefix-row-$id'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            RoomMemberFace(
              member: row.member,
              fallbackName: row.member.handle,
              profile: profile,
              avatarCache: widget.avatarCache,
              size: face,
              working: row.state == RoomTurnState.working,
              signal: roomTurnFaceSignal(row.state),
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
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      SizedBox.square(
                        key: ValueKey('$keyPrefix-chip-$id-${row.state.name}'),
                        dimension: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: roomTurnDotColor(colors, row.state),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          text,
                          key: ValueKey('$keyPrefix-status-$id'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (retry)
              TextButton(
                key: ValueKey('room-round-retry-$id'),
                onPressed: () => widget.onRetry!(row),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  foregroundColor: colors.error,
                ),
                child: Text(s.roomRetryAction),
              )
            else if (onTap != null)
              Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : row.replyEventId != null
                    ? Icons.chevron_right_rounded
                    : Icons.expand_more_rounded,
                size: 18,
                color: colors.textSecondary,
              ),
          ],
        ),
      ),
    );
  }

  Widget _steps(BuildContext context, RoomRoundRow row) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final steps = row.live?.steps ?? const <RoomLiveStep>[];
    return Container(
      key: ValueKey('room-round-steps-${row.member.memberId}'),
      margin: const EdgeInsets.only(left: 14, bottom: 6),
      padding: const EdgeInsets.only(left: 22),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _roomStepLabel(s, step),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: step.done
                            ? colors.textSecondary
                            : colors.textPrimary,
                      ),
                    ),
                  ),
                  if (step.done)
                    Icon(
                      Icons.check_rounded,
                      size: 13,
                      color: colors.textSecondary,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final round = widget.round;
    final title = round.active
        ? s.roomRoundLabel(round.round)
        : '${s.roomRoundLabel(round.round)} · ${s.roomRoundDone}';
    final started = round.startedAt;
    // A finished round shows its length only when the log dates its end.
    final clock = started == null || (!round.active && round.endedAt == null)
        ? null
        : roomElapsed((round.endedAt ?? widget.now).difference(started));
    final total = round.total;
    final progress = total == null || total == 0
        ? null
        : ((round.responded + round.failed) / total).clamp(0.0, 1.0);
    final divider = Divider(
      height: 1,
      thickness: 1,
      color: colors.divider.withValues(alpha: 0.35),
    );
    return Padding(
      key: const ValueKey('room-round-sheet'),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (clock != null)
                Text(
                  clock,
                  key: const ValueKey('room-round-clock'),
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            roomRoundProgressText(s, round),
            key: const ValueKey('room-round-progress'),
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          if (progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  key: const ValueKey('room-round-progress-bar'),
                  value: progress,
                  minHeight: 4,
                  backgroundColor: colors.surfaceVariant,
                  color: colors.success,
                ),
              ),
            ),
          const SizedBox(height: 6),
          for (final card in widget.approvals) card,
          for (var i = 0; i < round.rows.length; i++) ...[
            if (i > 0) divider,
            _row(context, round.rows[i]),
            if (_expanded == round.rows[i].member.memberId &&
                (round.rows[i].live?.steps.isNotEmpty ?? false))
              _steps(context, round.rows[i]),
          ],
          if (round.previous.isNotEmpty) ...[
            divider,
            InkWell(
              key: const ValueKey('room-round-previous'),
              onTap: () => setState(() => _previousOpen = !_previousOpen),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.rat1215Previous(round.previous.length),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    Icon(
                      _previousOpen
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: colors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
            if (_previousOpen)
              for (final past in round.previous.reversed) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Text(
                    s.roomRoundLabel(past.round),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                for (final row in past.rows)
                  _row(
                    context,
                    row,
                    keyPrefix: 'room-round-past-${past.round}',
                    face: 22,
                    interactive: false,
                  ),
              ],
          ],
          if (widget.onOpenMembers != null ||
              (widget.onStopAll != null && round.active))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (widget.onOpenMembers != null)
                    TextButton(
                      key: const ValueKey('room-round-members'),
                      onPressed: widget.onOpenMembers,
                      style: TextButton.styleFrom(
                        foregroundColor: colors.textSecondary,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      child: Text(s.roomMenuMembers),
                    ),
                  const Spacer(),
                  if (widget.onStopAll != null && round.active)
                    OutlinedButton(
                      key: const ValueKey('room-stop-all'),
                      onPressed: widget.onStopAll,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.textSecondary,
                        side: BorderSide(color: colors.divider),
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      child: Text(s.roomStopAll),
                    ),
                ],
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

  /// What arrived answers the owner's newest message: say so.
  final bool repliesToYou;

  const RoomNewPill({
    super.key,
    required this.count,
    required this.onTap,
    this.repliesToYou = false,
  });

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
                repliesToYou
                    ? s.rr1215NewRepliesToYou(count)
                    : s.roomNewPill(count),
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
