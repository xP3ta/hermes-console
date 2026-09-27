import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/chat/chat_markdown_body.dart';
import '../../../widgets/chat/chat_message_frame.dart';
import '../../../widgets/chat/chat_message_selection_area.dart';
import '../../../widgets/hermes_app_bar.dart';
import '../../data/desktop_projection_rooms.dart';
import 'room_models.dart';
import 'room_widgets.dart';

/// A Desktop-only room (`ui_meta['hermes-bots-groups']` projection, gap G3):
/// same group layout, read-only, labelled, no composer.
class DesktopProjectionRoomScreen extends StatelessWidget {
  final ProjectionRoom room;
  final DateTime Function()? clock;

  const DesktopProjectionRoomScreen({
    super.key,
    required this.room,
    this.clock,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final now = (clock ?? DateTime.now)();
    final handles = room.memberNames;
    final items = <Widget>[];
    if (room.omitted > 0) {
      items.add(RoomSeparator(label: s.roomDesktopOmitted(room.omitted)));
    }
    ProjectionMessage? previous;
    for (final message in room.messages) {
      final newDay =
          previous == null ||
          previous.at.year != message.at.year ||
          previous.at.month != message.at.month ||
          previous.at.day != message.at.day;
      if (newDay) {
        items.add(RoomSeparator(label: roomDayLabel(s, message.at, now)));
      }
      final firstOfRun =
          newDay ||
          previous.from.isUser != message.from.isUser ||
          previous.from.name != message.from.name;
      items.add(
        _ProjectionMessageTile(
          key: ValueKey('projection-message-${items.length}'),
          message: message,
          firstOfRun: firstOfRun,
          handles: handles,
        ),
      );
      previous = message;
    }
    return Scaffold(
      key: const ValueKey('projection-room-screen'),
      appBar: HermesAppBar(
        scrolledUnderElevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(room.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              '${room.memberNames.length} · ${room.memberNames.map((n) => '@$n').join(' ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              key: const ValueKey('projection-readonly-banner'),
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.desktop_windows_outlined,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.roomDesktopReadOnly,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          s.roomDesktopReadOnlyBody,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                key: const ValueKey('projection-transcript'),
                padding: const EdgeInsets.only(bottom: 16),
                children: items,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectionMessageTile extends StatelessWidget {
  final ProjectionMessage message;
  final bool firstOfRun;
  final List<String> handles;

  const _ProjectionMessageTile({
    super.key,
    required this.message,
    required this.firstOfRun,
    required this.handles,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final body = ChatMarkdownBody(
      data: linkifyRoomMentions(message.text, handles),
      selectable: false,
    );
    final time = roomClock(message.at);
    if (message.from.isUser) {
      return Padding(
        padding: EdgeInsets.fromLTRB(56, firstOfRun ? 10 : 3, 12, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ChatMessageSelectionArea(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: body,
              ),
            ),
            ChatMessageTimestamp(time),
          ],
        ),
      );
    }
    final color = roomMemberColor(message.from.name);
    return Padding(
      padding: EdgeInsets.fromLTRB(10, firstOfRun ? 12 : 4, 10, 0),
      child: ChatMessageFrame(
        padding: EdgeInsets.zero,
        headerSpacing: 4,
        header: firstOfRun
            ? Row(
                children: [
                  RoomMemberFace(
                    member: null,
                    fallbackName: message.from.name,
                    profile: null,
                    avatarCache: null,
                    size: RoomMessageTile.faceSize,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      message.from.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: color,
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
              )
            : null,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.divider.withValues(alpha: 0.35)),
            ),
            child: body,
          ),
        ],
      ),
    );
  }
}
