import 'dart:ui';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'compact_pill_text.dart';
import '../models/agent_profile.dart';
import '../models/room_summary.dart';
import '../theme/app_theme.dart';
import 'mission_profile_avatar.dart';
import 'room_member_status.dart';

/// Occupies layout space above the transcript; it never covers input surfaces.
class RoomSummaryPill extends StatefulWidget {
  final RoomSummary summary;
  final Map<String, AgentProfile> profiles;
  final MissionProfileAvatarCache? avatarCache;
  final String localGatewayId;
  final double maxHeight;
  final bool compact;
  const RoomSummaryPill({
    super.key,
    required this.summary,
    required this.localGatewayId,
    this.profiles = const {},
    this.avatarCache,
    this.maxHeight = 300,
    this.compact = false,
  });

  @override
  State<RoomSummaryPill> createState() => _RoomSummaryPillState();
}

class _RoomSummaryPillState extends State<RoomSummaryPill> {
  bool _expanded = false;
  final Map<String, int> _limits = {};

  @override
  void didUpdateWidget(RoomSummaryPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.compact && !oldWidget.compact) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final summary = widget.summary;
    final parts = <String>[
      if (summary.needsYouCount > 0)
        s.roomSummaryNeedsCount(summary.needsYouCount),
      if (summary.now.rows.isNotEmpty)
        s.roomSummaryWorkingCount(summary.now.rows.length),
      if (summary.done.rows.isNotEmpty)
        s.roomSummaryDoneCount(summary.done.rows.length),
      if (summary.pending.rows.length > summary.needsYouCount)
        s.roomSummaryPendingCount(
          summary.pending.rows.length - summary.needsYouCount,
        ),
    ];
    final label = parts.isEmpty ? s.roomSummaryUpToDate : parts.join(' · ');
    final avatarRows = <RoomSummaryRow>[];
    final avatarMembers = <String>{};
    for (final row in [
      ...summary.now.rows,
      ...summary.pending.rows,
      ...summary.done.rows,
    ]) {
      if (row.member != null && avatarMembers.add(row.member!.memberId)) {
        avatarRows.add(row);
      }
      if (avatarRows.length == 3) break;
    }
    final expanded = _expanded && !widget.compact;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Material(
            key: const ValueKey('room-summary-pill'),
            color: colors.surfaceVariant.withValues(alpha: .65),
            child: _transition(
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: widget.maxHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      expanded: expanded,
                      child: InkWell(
                        key: const ValueKey('room-summary-toggle'),
                        onTap: widget.compact
                            ? null
                            : () => setState(() => _expanded = !_expanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              for (final row in avatarRows.take(3)) ...[
                                RoomStatusAvatar(
                                  member: row.member!,
                                  status:
                                      summary.statuses[row.member!.memberId]!,
                                  profile:
                                      row.member!.owner.connectionId ==
                                          widget.localGatewayId
                                      ? widget.profiles[row
                                            .member!
                                            .owner
                                            .profile]
                                      : null,
                                  avatarCache: widget.avatarCache,
                                  size: 20,
                                ),
                                const SizedBox(width: 5),
                              ],
                              Expanded(
                                child: CompactPillText(
                                  label: label,
                                  compactLabel: s.roomSummaryCompact,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ),
                              if (!widget.compact)
                                Icon(
                                  expanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 16,
                                  color: colors.textSecondary,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (expanded)
                      Flexible(
                        child: SingleChildScrollView(
                          key: const ValueKey('room-summary-expanded'),
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (summary.topic != null)
                                Tooltip(
                                  message: summary.topic!,
                                  child: Text(
                                    s.roomSummaryTopic(summary.topic!),
                                    key: const ValueKey('room-summary-topic'),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                ),
                              _section('now', s.roomSummaryNow, summary.now),
                              _section(
                                'done',
                                s.roomSummaryDone,
                                summary.done,
                                checks: true,
                              ),
                              _section(
                                'pending',
                                s.roomSummaryPending,
                                summary.pending,
                              ),
                              _section(
                                'recent',
                                s.roomSummaryRecent,
                                summary.recent,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _transition(Widget child) {
    // Zero-duration AnimatedSize can re-dirty its render object during layout.
    // Removing the animation also makes IME compaction immediate and bounded.
    if (widget.compact || MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  Widget _section(
    String id,
    String title,
    RoomSummarySection section, {
    bool checks = false,
  }) {
    if (section.rows.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final limit = _limits[id] ?? RoomSummarySection.pageSize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 14, thickness: .5, color: colors.divider),
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: colors.textSecondary,
          ),
        ),
        for (final row in section.rows.take(limit))
          Padding(
            key: ValueKey('room-summary-$id-${row.id}'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                if (checks) ...[
                  Icon(
                    Icons.check_rounded,
                    size: 13,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Tooltip(
                    message: _label(s, row),
                    child: Text(
                      _label(s, row),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (section.rows.length > limit)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: ValueKey('room-summary-more-$id'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => setState(
                () => _limits[id] = limit + RoomSummarySection.pageSize,
              ),
              child: Text(
                s.roomSummaryMore(section.rows.length - limit),
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
      ],
    );
  }

  String _label(Strings s, RoomSummaryRow row) {
    if (row.kind == RoomSummaryKind.needsYou) {
      return s.roomSummaryWaitingForYou(row.member?.handle ?? '');
    }
    final action = switch (row.kind) {
      RoomSummaryKind.working => s.roomPresenceWorking,
      RoomSummaryKind.answered => s.roomActivityReplied,
      RoomSummaryKind.passed => s.roomActivityPassed,
      RoomSummaryKind.done => s.roomSummaryTaskDone,
      RoomSummaryKind.waiting => s.roomResponsePending,
      RoomSummaryKind.silent => s.roomResponseNone,
      RoomSummaryKind.deferred => s.roomActivityDeferred,
      RoomSummaryKind.failed => s.roomActivityFailed,
      RoomSummaryKind.cancelled => s.roomActivityCancelled,
      RoomSummaryKind.unavailable => s.roomSummaryUnavailable,
      RoomSummaryKind.stopped => s.roomActivityStopped,
      RoomSummaryKind.bounded => s.roomActivityBounded,
      RoomSummaryKind.settled => s.roomActivitySettled,
      RoomSummaryKind.needsYou => s.roomPresenceNeedsYou,
    };
    final reason = switch (row.reasonCode) {
      'superseded_by_newer_user_event' => s.roomSummarySuperseded,
      'member_unavailable' => s.roomSummaryUnavailable,
      'room_stopped' => s.roomActivityStopped,
      'bounded' => s.roomActivityBounded,
      _ => null,
    };
    return [if (row.member != null) row.member!.handle, action].join(' ') +
        [?reason, ?row.detail].map((part) => ' · $part').join();
  }
}
