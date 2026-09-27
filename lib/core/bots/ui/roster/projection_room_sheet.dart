import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../data/desktop_projection_rooms.dart';
import 'roster_rows.dart';

/// Read-only view of a Desktop-only room (`ui_meta['hermes-bots-groups']`
/// projection). Desktop orchestrates these rooms client-side (gap G3), so
/// Console only shows the projected tail and never writes to it.
class ProjectionRoomSheet extends StatelessWidget {
  final ProjectionRoom room;

  const ProjectionRoomSheet({super.key, required this.room});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return ListView(
      key: const ValueKey('roster-projection-room'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      children: [
        Text(
          room.name,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          s.rosterDesktopReadOnly,
          style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
        ),
        const SizedBox(height: 14),
        for (final message in room.messages)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${message.from.isUser ? s.rosterYouSaid('').replaceAll(RegExp(r':\s*$'), '') : '@${message.from.name}'}'
                  ' · ${rosterTime(context, message.at)}',
                  style: TextStyle(
                    color: message.from.isUser
                        ? colors.accentText
                        : colors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  message.text,
                  style: TextStyle(color: colors.textPrimary, fontSize: 14),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
