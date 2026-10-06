import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/hermes_premium_ui.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../../../widgets/room_mirror_avatar.dart';
import 'dots_home_model.dart';
import 'living_bot_face.dart';
import 'roster_model.dart';
import 'roster_rows.dart' show rosterTime;

/// Bots home in the Dots style (owner decision 1.2.15, variant C).
///
/// The main bot is the big face on top (always first, never moves), with
/// its name, ONE status line (current step of its canonical Bot Chat, or
/// its last preview when free) and an "Activity · N delegated" chip while
/// that chat has subagents running. Then "N working · M waiting for you",
/// the **Your team** grid (waiting, working, then by recency; see
/// [DotsHomeLayout]) and the **Rooms** cards. Tap a bot: its canonical Bot
/// Chat; long press: the existing actions sheet; tap a room: the room.
///
/// The view owns no roster state: it paints the entries Mission Control
/// derives from its one shared snapshot. Lists use `cacheExtent: 0` and the
/// faces use the shared rare blink, so an idle home produces no frames.
class DotsHomeView extends StatefulWidget {
  final List<BotRosterEntry> bots;
  final List<RoomRosterEntry> rooms;
  final MissionProfileAvatarCache? avatarCache;
  final ValueNotifier<bool> searchOpen;
  final ValueChanged<BotRosterEntry> onOpenBot;
  final ValueChanged<BotRosterEntry> onBotActions;
  final ValueChanged<RoomRosterEntry> onOpenRoom;
  final ValueChanged<RoomRosterEntry>? onRoomActions;

  /// Chat approvals / blocked Kanban tasks summary, shown under the summary
  /// line; tapping opens the approval or the chooser.
  final String? attentionSummary;
  final VoidCallback? onAttention;
  final Future<void> Function()? onRefresh;
  final Widget? emptyState;
  final List<Widget> header;
  final List<Widget> footer;
  final DateTime? now;

  const DotsHomeView({
    super.key,
    required this.bots,
    required this.rooms,
    required this.avatarCache,
    required this.searchOpen,
    required this.onOpenBot,
    required this.onBotActions,
    required this.onOpenRoom,
    this.onRoomActions,
    this.attentionSummary,
    this.onAttention,
    this.onRefresh,
    this.emptyState,
    this.header = const [],
    this.footer = const [],
    this.now,
  });

  /// Team grid columns for the window: 4 on a phone, 5 on a medium and 6 on
  /// an expanded window; one fewer with very large text so names fit.
  static int teamColumns(BuildContext context) {
    final base = switch (Responsive.sizeClassOf(context)) {
      WindowSizeClass.compact => 4,
      WindowSizeClass.medium => 5,
      WindowSizeClass.expanded => 6,
    };
    final large = MediaQuery.textScalerOf(context).scale(10) > 15;
    return large ? base - 1 : base;
  }

  /// Room card columns: 2 on a phone, 3 on tablets.
  static int roomColumns(BuildContext context) =>
      Responsive.sizeClassOf(context) == WindowSizeClass.compact ? 2 : 3;

  @override
  State<DotsHomeView> createState() => _DotsHomeViewState();
}

class _DotsHomeViewState extends State<DotsHomeView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    widget.searchOpen.addListener(_onSearchToggle);
  }

  @override
  void didUpdateWidget(covariant DotsHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.searchOpen, widget.searchOpen)) {
      oldWidget.searchOpen.removeListener(_onSearchToggle);
      widget.searchOpen.addListener(_onSearchToggle);
    }
  }

  void _onSearchToggle() {
    if (!widget.searchOpen.value) _search.clear();
    setState(() {});
    if (widget.searchOpen.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    widget.searchOpen.removeListener(_onSearchToggle);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<Widget> _rows<T>(List<T> items, int columns, Widget Function(T) cell) {
    return [
      for (var start = 0; start < items.length; start += columns)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = start; i < start + columns; i++)
                Expanded(
                  child: i < items.length
                      ? cell(items[i])
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final query = widget.searchOpen.value ? _search.text : '';
    final layout = DotsHomeLayout.build(
      bots: widget.bots,
      rooms: widget.rooms,
      query: query,
      showHidden: _showHidden,
    );
    final summary = [
      if (layout.working > 0) s.dotsSummaryWorking(layout.working),
      if (layout.waiting > 0) s.dotsSummaryWaiting(layout.waiting),
    ].join(' · ');
    final items = <Widget>[
      ...widget.header,
      if (widget.searchOpen.value)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: HermesSearchField(
            key: const ValueKey('mission-bot-search'),
            controller: _search,
            focusNode: _searchFocus,
            hintText: s.rosterSearchHint,
            clearTooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
            onChanged: (_) => setState(() {}),
          ),
        ),
    ];
    if (widget.bots.isEmpty &&
        widget.rooms.isEmpty &&
        widget.emptyState != null) {
      items.add(widget.emptyState!);
    } else if (layout.isEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Text(
              query.trim().isEmpty ? s.rosterEmpty : s.rosterNoMatches,
              key: const ValueKey('roster-empty'),
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
        ),
      );
    }
    if (layout.main case final main?) {
      items.add(
        _DotsHero(
          entry: main,
          avatarCache: widget.avatarCache,
          onTap: () => widget.onOpenBot(main),
          onLongPress: () => widget.onBotActions(main),
        ),
      );
      if (main.delegated > 0) {
        items.add(
          Center(
            child: _ActivityChip(
              label: s.dotsActivity(main.delegated),
              onTap: () => widget.onOpenBot(main),
            ),
          ),
        );
      }
    }
    if (summary.isNotEmpty && query.trim().isEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: Text(
            summary,
            key: const ValueKey('dots-summary'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
        ),
      );
    }
    if (widget.attentionSummary case final text?) {
      if (widget.onAttention case final onTap?) {
        items.add(_AttentionRow(text: text, onTap: onTap));
      }
    }
    if (layout.team.isNotEmpty) {
      items.add(
        _SectionLabel(
          key: const ValueKey('dots-team-header'),
          title: s.dotsTeam,
          count: layout.team.length,
        ),
      );
      items.addAll(
        _rows(
          layout.team,
          DotsHomeView.teamColumns(context),
          (entry) => _TeamTile(
            key: ValueKey('dots-tile-${entry.profile.name}'),
            entry: entry,
            avatarCache: widget.avatarCache,
            now: widget.now,
            onTap: () => widget.onOpenBot(entry),
            onLongPress: () => widget.onBotActions(entry),
          ),
        ),
      );
    }
    if (layout.hiddenCount > 0) {
      items.add(
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('mission-show-hidden'),
            onPressed: () => setState(() => _showHidden = !_showHidden),
            icon: Icon(
              _showHidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 17,
            ),
            label: Text(
              _showHidden
                  ? s.rosterHideHidden
                  : s.rosterShowHidden(layout.hiddenCount),
            ),
            style: TextButton.styleFrom(
              foregroundColor: colors.textSecondary,
              minimumSize: const Size(48, 48),
            ),
          ),
        ),
      );
    }
    if (layout.rooms.isNotEmpty) {
      items.add(
        _SectionLabel(
          key: const ValueKey('dots-rooms-header'),
          title: s.dotsRooms,
          count: layout.rooms.length,
        ),
      );
      items.addAll(
        _rows(
          layout.rooms,
          DotsHomeView.roomColumns(context),
          (room) => _RoomCard(
            entry: room,
            avatarCache: widget.avatarCache,
            onTap: () => widget.onOpenRoom(room),
            onLongPress: widget.onRoomActions == null
                ? null
                : () => widget.onRoomActions!(room),
          ),
        ),
      );
    }
    items.addAll(widget.footer);
    final list = ListView(
      key: const ValueKey('mission-bots'),
      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
      children: items,
    );
    final refresh = widget.onRefresh;
    return refresh == null
        ? list
        : RefreshIndicator(onRefresh: refresh, child: list);
  }
}

/// Display name: the Desktop title, and "Hermes" (or the profile's display
/// name) for the main bot instead of the raw `default`.
String dotsTitle(BotRosterEntry entry) {
  final profile = entry.profile;
  if (profile.botTitle != null || !isMainBot(profile)) return entry.title;
  final display = profile.displayName.trim();
  return display.isEmpty ? 'Hermes' : display;
}

bool _busy(BotFaceSignal signal) =>
    signal == BotFaceSignal.working ||
    signal == BotFaceSignal.thinking ||
    signal == BotFaceSignal.speaking;

/// The hero's one status line: the canonical chat's current step, else its
/// last preview when the bot is free.
String dotsHeroStatus(Strings s, BotRosterEntry entry) {
  final title = entry.workingOn;
  return switch (entry.signal) {
    BotFaceSignal.attention =>
      title == null ? s.dotsWaiting : s.dotsWaitingOn(title),
    BotFaceSignal.working => title ?? s.rosterWorking,
    BotFaceSignal.thinking => title ?? s.rosterThinking,
    BotFaceSignal.speaking => title ?? s.rosterSpeaking,
    BotFaceSignal.idle =>
      entry.preview.isEmpty ? s.dotsIdle : s.dotsIdleWith(entry.preview),
  };
}

/// Status phrase for TalkBack ("working: Reviewing PR #134").
String _a11yStatus(Strings s, BotRosterEntry entry) {
  final title = entry.workingOn;
  if (entry.signal == BotFaceSignal.attention) {
    return title == null ? s.dotsA11yWaiting : s.dotsA11yWaitingOn(title);
  }
  if (_busy(entry.signal)) {
    return title == null ? s.dotsA11yWorking : s.dotsA11yWorkingOn(title);
  }
  return s.dotsA11yIdle;
}

Color _statusColor(HermesThemeColors colors, BotFaceSignal signal) =>
    signal == BotFaceSignal.attention
    ? colors.warning
    : _busy(signal)
    ? colors.accentText
    : colors.textSecondary;

class _DotsHero extends StatelessWidget {
  final BotRosterEntry entry;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _DotsHero({
    required this.entry,
    required this.avatarCache,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final name = dotsTitle(entry);
    final status = dotsHeroStatus(s, entry);
    final faceSize = Responsive.sizeClassOf(context) == WindowSizeClass.compact
        ? 112.0
        : 128.0;
    return Semantics(
      key: const ValueKey('dots-main'),
      container: true,
      button: true,
      label: s.dotsA11yMain(name, _a11yStatus(s, entry)),
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            key: ValueKey('mission-bot-row-${entry.profile.name}'),
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('mission-bot-${entry.profile.name}'),
              onTap: onTap,
              onLongPress: onLongPress,
              borderRadius: BorderRadius.circular(28),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: faceSize + 24,
                      child: Center(
                        child: LivingBotFace(
                          profileName: entry.profile.name,
                          profile: entry.profile,
                          avatarCache: avatarCache,
                          signal: entry.signal,
                          size: faceSize,
                          blink: LivingBotFaceBlink.shared,
                          style: LivingBotFaceStyle.dots,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: colors.divider),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 8,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              status,
                              key: ValueKey(
                                'roster-line-${entry.profile.name}',
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _statusColor(colors, entry.signal),
                                fontSize: 13.5,
                                fontWeight: _busy(entry.signal)
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
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
}

class _ActivityChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ActivityChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Material(
        key: const ValueKey('dots-activity'),
        color: colors.surface,
        shape: StadiumBorder(side: BorderSide(color: colors.divider)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: colors.textDisabled,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _AttentionRow({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('mission-attention'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(
                  Icons.front_hand_outlined,
                  color: colors.warning,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: colors.textDisabled),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String title;
  final int count;

  const _SectionLabel({super.key, required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final style = TextStyle(
      color: colors.success,
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.6,
    );
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(8, 18, 8, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            Text(
              '$count',
              style: style.copyWith(
                color: colors.textDisabled,
                letterSpacing: 0,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamTile extends StatelessWidget {
  final BotRosterEntry entry;
  final MissionProfileAvatarCache? avatarCache;
  final DateTime? now;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static const faceSize = 52.0;

  const _TeamTile({
    super.key,
    required this.entry,
    required this.avatarCache,
    required this.onTap,
    required this.onLongPress,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final name = dotsTitle(entry);
    final at = entry.at;
    final status = entry.needsYou
        ? s.dotsWaiting
        : _busy(entry.signal)
        ? s.dotsWorking
        : at == null
        ? ''
        : rosterTime(context, at, now: now);
    return Semantics(
      container: true,
      button: true,
      label: s.dotsA11yBot(name, _a11yStatus(s, entry)),
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: Material(
        key: ValueKey('mission-bot-row-${entry.profile.name}'),
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('mission-bot-${entry.profile.name}'),
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: faceSize + 12,
                    child: Center(
                      child: LivingBotFace(
                        profileName: entry.profile.name,
                        profile: entry.profile,
                        avatarCache: avatarCache,
                        signal: entry.signal,
                        size: faceSize,
                        blink: LivingBotFaceBlink.shared,
                        style: LivingBotFaceStyle.dots,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    status.isEmpty ? ' ' : status,
                    key: ValueKey('roster-line-${entry.profile.name}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _statusColor(colors, entry.signal),
                      fontSize: 11.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
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
}

/// Room as a team card: clustered member faces, name, one status line.
class _RoomCard extends StatelessWidget {
  final RoomRosterEntry entry;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static const faceSize = 34.0;

  const _RoomCard({
    required this.entry,
    required this.avatarCache,
    required this.onTap,
    this.onLongPress,
  });

  Widget _cluster(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final shown = entry.members.take(3).toList();
    final extra = entry.members.length - shown.length;
    const step = faceSize * .68;
    final width = shown.isEmpty
        ? faceSize
        : faceSize + step * (shown.length - 1) + (extra > 0 ? step : 0);
    return SizedBox(
      width: width,
      height: faceSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: step * i,
              top: 0,
              child: LivingBotFace(
                profileName: shown[i].profile?.name ?? shown[i].handle,
                profile: shown[i].profile,
                avatarCache: avatarCache,
                signal: BotFaceSignal.idle,
                size: faceSize,
                entrance: false,
                blink: LivingBotFaceBlink.shared,
                style: LivingBotFaceStyle.dots,
              ),
            ),
          if (extra > 0)
            Positioned(
              left: step * shown.length,
              top: faceSize * .2,
              child: Container(
                height: faceSize * .6,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(faceSize),
                ),
                child: Text(
                  '+$extra',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final id = entry.publicKey;
    final preview = entry.preview;
    final previewLine = preview.isEmpty
        ? s.rosterRoomMembers(entry.members.length)
        : entry.previewFromUser
        ? s.rosterYouSaid(preview)
        : entry.previewAuthor != null
        ? s.rosterMemberSaid(entry.previewAuthor!, preview)
        : preview;
    final line = entry.needsYou
        ? s.dotsWaiting
        : entry.working
        ? s.dotsRoomWorking
        : previewLine;
    final lineColor = entry.needsYou
        ? colors.warning
        : entry.working
        ? colors.accentText
        : colors.textSecondary;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Semantics(
        container: true,
        button: true,
        label: s.dotsA11yRoom(entry.title, line),
        onTap: onTap,
        onLongPress: onLongPress,
        excludeSemantics: true,
        child: Material(
          key: ValueKey('roster-room-row-$id'),
          color: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: colors.divider),
          ),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (entry.image case final image?)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox.square(
                            dimension: faceSize,
                            child: RoomMirrorAvatar(
                              image: image,
                              fallback: _cluster(context),
                            ),
                          ),
                        )
                      else
                        Flexible(child: _cluster(context)),
                      if (entry.needsYou) ...[
                        const SizedBox(width: 6),
                        Container(
                          key: ValueKey('roster-room-needs-you-$id'),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: colors.warning,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    entry.title,
                    key: ValueKey('roster-room-title-$id'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    line,
                    key: ValueKey('roster-room-line-$id'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: lineColor, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
