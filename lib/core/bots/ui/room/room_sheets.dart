import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/hosted_groups.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/hermes_premium_ui.dart';
import '../../../widgets/mission_profile_avatar.dart';
import 'room_gateway.dart';
import 'room_models.dart';
import 'room_prefs.dart';
import 'room_widgets.dart';

/// Overflow destinations (T30B).
enum RoomMenuAction {
  members,
  threads,
  files,
  activity,
  notifications,
  settings,
  stop,
  disband,
}

class _SheetTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _SheetTitle(this.title, {this.subtitle});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).hermes.textSecondary),
    ),
  );
}

/// The overflow menu, rendered with Console's floating surface.
Future<RoomMenuAction?> showRoomOverflowMenu(
  BuildContext context, {
  required int memberCount,
  required int threadCount,
  required int fileCount,
  required RoomNotificationLevel notifications,
  required bool canStop,
  required bool canDisband,
  required bool readOnly,
}) {
  final s = Strings.of(context);
  String level(RoomNotificationLevel l) => switch (l) {
    RoomNotificationLevel.all => s.roomNotifyAll,
    RoomNotificationLevel.mentions => s.roomNotifyMentions,
    RoomNotificationLevel.muted => s.roomNotifyMuted,
  };
  return showHermesFloatingSurface<RoomMenuAction>(
    context: context,
    surfaceKey: const ValueKey('room-overflow-menu'),
    maxWidth: 420,
    builder: (sheet) {
      Widget row(
        RoomMenuAction action,
        IconData icon,
        String title, {
        String? trailing,
        String? subtitle,
        bool destructive = false,
      }) => HermesListRow(
        key: ValueKey('room-menu-${action.name}'),
        icon: icon,
        title: title,
        subtitle: subtitle,
        destructive: destructive,
        trailing: trailing == null
            ? null
            : Text(
                trailing,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(sheet).hermes.textSecondary,
                ),
              ),
        onTap: () => Navigator.of(sheet).pop(action),
      );
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(
              RoomMenuAction.members,
              Icons.group_outlined,
              s.roomMenuMembers,
              subtitle: s.roomMenuMembersSubtitle(memberCount),
            ),
            row(
              RoomMenuAction.threads,
              Icons.forum_outlined,
              s.roomMenuThreads,
              trailing: '$threadCount',
            ),
            row(
              RoomMenuAction.files,
              Icons.attach_file_rounded,
              s.roomMenuFiles,
              trailing: '$fileCount',
            ),
            row(
              RoomMenuAction.activity,
              Icons.receipt_long_outlined,
              s.roomMenuActivity,
              subtitle: s.roomMenuActivitySubtitle,
            ),
            // Device-local and read-only connections still get room
            // notifications: the level is always offered.
            row(
              RoomMenuAction.notifications,
              Icons.notifications_none_rounded,
              s.roomMenuNotifications,
              trailing: level(notifications),
            ),
            if (!readOnly) ...[
              row(
                RoomMenuAction.settings,
                Icons.tune_rounded,
                s.roomMenuSettings,
                subtitle: s.roomMenuSettingsSubtitle,
              ),
              if (canStop)
                row(
                  RoomMenuAction.stop,
                  Icons.stop_circle_outlined,
                  s.roomMenuStop,
                ),
              if (canDisband)
                row(
                  RoomMenuAction.disband,
                  Icons.block_rounded,
                  s.roomMenuDisband,
                  destructive: true,
                ),
            ],
          ],
        ),
      );
    },
  );
}

/// Activity sheet (T304): passes, failures, retries and stops.
Future<void> showRoomActivitySheet(
  BuildContext context, {
  required List<HostedGroupEvent> events,
  required List<HostedGroupMember> members,
}) {
  final s = Strings.of(context);
  final items = roomActivity(events);
  return showHermesFloatingSurface<void>(
    context: context,
    surfaceKey: const ValueKey('room-activity-sheet'),
    maxWidth: 520,
    builder: (sheet) {
      final colors = Theme.of(sheet).hermes;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetTitle(s.roomActivityTitle),
          if (items.isEmpty)
            _Empty(s.roomActivityEmpty)
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: items.length,
                itemBuilder: (_, index) {
                  final item = items[index];
                  final name = roomMemberName(
                    roomMemberById(item.memberId, members),
                    null,
                  );
                  final (icon, color, text) = switch (item.kind) {
                    RoomActivityKind.passed => (
                      Icons.redo_rounded,
                      colors.textSecondary,
                      s.roomActivityPassedLine(name),
                    ),
                    RoomActivityKind.failed => (
                      Icons.error_outline_rounded,
                      colors.error,
                      s.roomActivityFailedLine(name),
                    ),
                    RoomActivityKind.cancelled => (
                      Icons.cancel_outlined,
                      colors.textSecondary,
                      s.roomActivityCancelledLine(name),
                    ),
                    RoomActivityKind.deferred => (
                      Icons.schedule_rounded,
                      colors.warning,
                      s.roomActivityDeferredLine(name),
                    ),
                    RoomActivityKind.stopRequested => (
                      Icons.stop_circle_outlined,
                      colors.textSecondary,
                      s.roomActivityStopLine,
                    ),
                  };
                  return HermesListRow(
                    key: ValueKey('room-activity-${item.event.eventId}'),
                    icon: icon,
                    iconColor: color,
                    title: text,
                    subtitle: item.event.activity.reasonCode,
                    trailing: Text(
                      roomClock(roomEventTime(item.event)),
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: colors.textSecondary,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      );
    },
  );
}

/// Members sheet: list with state. `groups.*` has no add/remove RPC, so the
/// list is read-only and says so.
Future<void> showRoomMembersSheet(
  BuildContext context, {
  required HostedGroupRoom room,
  required Set<String> unavailable,
  required RoomRoundModel? round,
  required RoomProfileResolver profileFor,
  required MissionProfileAvatarCache? avatarCache,
  void Function(HostedGroupMember member)? onOpenMember,
}) {
  final s = Strings.of(context);
  return showHermesFloatingSurface<void>(
    context: context,
    surfaceKey: const ValueKey('room-members-sheet'),
    maxWidth: 520,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle(s.roomMenuMembers, subtitle: s.roomMembersReadOnlyNote),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              for (final member in room.members)
                Builder(
                  builder: (context) {
                    final profile = profileFor(member);
                    RoomRoundRow? row;
                    for (final r in round?.rows ?? const <RoomRoundRow>[]) {
                      if (r.member.memberId == member.memberId) row = r;
                    }
                    final local =
                        member.owner.connectionId == room.authorityGatewayId;
                    final status = unavailable.contains(member.memberId)
                        ? s.roomMemberUnavailable
                        : local
                        ? s.roomMemberAvailable
                        : s.roomMemberFederated;
                    return HermesListRow(
                      key: ValueKey('room-member-${member.memberId}'),
                      leading: RoomMemberFace(
                        member: member,
                        fallbackName: member.handle,
                        profile: profile,
                        avatarCache: avatarCache,
                        size: 32,
                        working: row?.state == RoomTurnState.working,
                      ),
                      title: roomMemberName(member, null),
                      subtitle: '@${member.handle} · $status',
                      trailing: row == null
                          ? null
                          : RoomStateChip(state: row.state),
                      onTap: profile == null || onOpenMember == null
                          ? null
                          : () {
                              Navigator.of(sheet).pop();
                              onOpenMember(member);
                            },
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Threads list; returns the chosen thread id.
Future<String?> showRoomThreadsSheet(
  BuildContext context, {
  required List<HostedGroupEvent> events,
  required List<HostedGroupMember> members,
}) {
  final s = Strings.of(context);
  final threads = roomThreads(events);
  return showHermesFloatingSurface<String>(
    context: context,
    surfaceKey: const ValueKey('room-threads-sheet'),
    maxWidth: 520,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle(s.roomMenuThreads),
        if (threads.isEmpty)
          _Empty(s.roomThreadsEmpty)
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                for (final thread in threads)
                  HermesListRow(
                    key: ValueKey('room-thread-${thread.threadId}'),
                    icon: Icons.forum_outlined,
                    title: parseRoomMessageText(
                      thread.root.publicText ?? '',
                    ).text.replaceAll('\n', ' '),
                    subtitle: s.roomThreadReplies(thread.messages - 1),
                    onTap: () => Navigator.of(sheet).pop(thread.threadId),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Room files (download/open/share through the attachment cards).
Future<void> showRoomFilesSheet(
  BuildContext context, {
  required List<HostedGroupEvent> events,
  required RoomAttachmentActions? actions,
}) {
  final s = Strings.of(context);
  final files = roomFiles(events);
  return showHermesFloatingSurface<void>(
    context: context,
    surfaceKey: const ValueKey('room-files-sheet'),
    maxWidth: 560,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle(s.roomMenuFiles),
        if (files.isEmpty)
          _Empty(s.roomFilesEmpty)
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
              children: [
                for (final file in files)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: RoomAttachmentCard(
                      key: ValueKey(
                        'room-file-${file.event.eventId}-${file.ref.path}',
                      ),
                      attachment: file.ref,
                      actions: actions,
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

Future<RoomNotificationLevel?> showRoomNotificationsSheet(
  BuildContext context, {
  required RoomNotificationLevel current,
}) {
  final s = Strings.of(context);
  return showHermesFloatingSurface<RoomNotificationLevel>(
    context: context,
    surfaceKey: const ValueKey('room-notifications-sheet'),
    maxWidth: 420,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle(s.roomMenuNotifications, subtitle: s.roomNotifyNote),
        for (final (level, label) in [
          (RoomNotificationLevel.all, s.roomNotifyAll),
          (RoomNotificationLevel.mentions, s.roomNotifyMentions),
          (RoomNotificationLevel.muted, s.roomNotifyMuted),
        ])
          HermesListRow(
            key: ValueKey('room-notify-${level.name}'),
            title: label,
            selected: level == current,
            trailing: level == current
                ? Icon(
                    Icons.check_rounded,
                    color: Theme.of(sheet).hermes.accent,
                  )
                : null,
            onTap: () => Navigator.of(sheet).pop(level),
          ),
        const SizedBox(height: 12),
      ],
    ),
  );
}

/// Settings: rename (groups.rename); picture read-only (no RPC).
Future<String?> showRoomSettingsSheet(
  BuildContext context, {
  required String name,
  required bool canRename,
}) {
  final s = Strings.of(context);
  final controller = TextEditingController(text: name);
  return showHermesFloatingSurface<String>(
    context: context,
    surfaceKey: const ValueKey('room-settings-sheet'),
    maxWidth: 460,
    builder: (sheet) => DisposeControllersOnUnmount(
      controllers: [controller],
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              s.roomMenuSettings,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Theme.of(sheet).hermes.textPrimary,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('room-settings-name'),
              controller: controller,
              enabled: canRename,
              maxLength: 200,
              decoration: InputDecoration(labelText: s.roomSettingsName),
            ),
            HermesListRow(
              icon: Icons.image_outlined,
              title: s.roomSettingsPicture,
              subtitle: s.roomSettingsPictureReadOnly,
              padding: EdgeInsets.zero,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(sheet).pop(),
                  child: Text(s.roomCancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('room-settings-save'),
                  onPressed: canRename
                      ? () {
                          final value = controller.text.trim();
                          Navigator.of(
                            sheet,
                          ).pop(value.isEmpty || value == name ? null : value);
                        }
                      : null,
                  child: Text(s.roomSave),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
