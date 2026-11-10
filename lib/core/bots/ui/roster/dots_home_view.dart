import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../../../l10n/app_localizations.dart';
import '../../../design/tokens.dart' show HermesSpace, HermesType;
import '../../../theme/app_theme.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/hermes_premium_ui.dart';
import '../../../widgets/hermes_ui.dart' show HermesCard;
import '../../../widgets/mission_profile_avatar.dart';
import '../../../widgets/room_mirror_avatar.dart';
import '../bot_screen_access.dart';
import 'dots_home_model.dart';
import 'living_bot_face.dart';
import 'roster_model.dart';
import 'roster_rows.dart' show rosterTime;

/// Bots home in the Dots style (owner decision 1.2.15, variant C).
///
/// An "Activity · N delegated" chip while the main bot's chat has
/// subagents running, then "N working · M waiting for you", then (owner,
/// QA 9493) **Pinned** bots as one calm row, the **Rooms** cards and the
/// **Your team** grid — the main bot its first tile unless pinned (no
/// hero), then waiting, working and by recency (see [DotsHomeLayout]). Tap a bot: its canonical Bot
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

  /// Where the "N working · M waiting for you" line goes when the page's
  /// header shows it under its title. Without one the line stays in the list.
  final ValueNotifier<String>? summary;
  final ValueChanged<BotRosterEntry> onOpenBot;
  final ValueChanged<BotRosterEntry> onBotActions;

  /// Opens a bot's desktop. With [screenAccess], a small button on the face
  /// of each bot that has one; bots without a desktop show nothing.
  final ValueChanged<BotRosterEntry>? onOpenScreen;
  final BotScreenAccess? screenAccess;
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

  /// How the list ends at its edges. A page whose header floats passes
  /// `Clip.none`, and the rows keep scrolling under it.
  final Clip clipBehavior;
  final DateTime? now;

  const DotsHomeView({
    super.key,
    required this.bots,
    required this.rooms,
    required this.avatarCache,
    required this.searchOpen,
    this.summary,
    required this.onOpenBot,
    required this.onBotActions,
    this.onOpenScreen,
    this.screenAccess,
    required this.onOpenRoom,
    this.onRoomActions,
    this.attentionSummary,
    this.onAttention,
    this.onRefresh,
    this.emptyState,
    this.header = const [],
    this.footer = const [],
    this.clipBehavior = Clip.hardEdge,
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
    _askScreens();
  }

  /// Asks, once per bot, which of them have a desktop. Cached and capped in
  /// [BotScreenAccess]; never per rebuild.
  void _askScreens() {
    final access = widget.screenAccess;
    if (access == null || widget.onOpenScreen == null) return;
    final names = [
      for (final entry in widget.bots) botScreenProfile(entry.profile),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) access.ensure(names);
    });
  }

  @override
  void didUpdateWidget(covariant DotsHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // By name, not by count: a refresh can swap one bot for another. Not by
    // identity either: the list is rebuilt on every build of the parent.
    if (!identical(oldWidget.screenAccess, widget.screenAccess) ||
        !_sameProfiles(oldWidget.bots, widget.bots)) {
      _askScreens();
    }
    if (!identical(oldWidget.searchOpen, widget.searchOpen)) {
      oldWidget.searchOpen.removeListener(_onSearchToggle);
      widget.searchOpen.addListener(_onSearchToggle);
    }
  }

  static bool _sameProfiles(List<BotRosterEntry> a, List<BotRosterEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (botScreenProfile(a[i].profile) != botScreenProfile(b[i].profile)) {
        return false;
      }
    }
    return true;
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
    final out = widget.summary;
    if (out != null) {
      final shown = query.trim().isEmpty ? summary : '';
      if (out.value != shown) {
        // After this frame: the header listening to it is built already.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && out.value != shown) out.value = shown;
        });
      }
    }
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
    // QA 9493 (owner): no big hero on top. The main bot is one more member
    // of Your team, always its first tile; only its delegations chip stays
    // up here.
    final mainBot =
        layout.main ??
        layout.pinned.where((b) => isMainBot(b.profile)).firstOrNull;
    if (mainBot case final main?) {
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
    if (out == null && summary.isNotEmpty && query.trim().isEmpty) {
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
    // Owner (QA 9493, then "too big, feels dirty"): pinned bots on top in
    // roster order as one calm row on the grid's rhythm, faces a little
    // larger than the grid's, no cards; no section when none is pinned.
    if (layout.pinned.isNotEmpty) {
      items.add(
        _SectionLabel(
          key: const ValueKey('dots-pinned-header'),
          title: s.dotsPinned,
          count: layout.pinned.length,
        ),
      );
      final columns = DotsHomeView.teamColumns(context);
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final pinned = layout.pinned;
              final scrolls = pinned.length > columns;
              // Same column width as the grid; with more pins than columns
              // the row scrolls and the next face peeks in at the edge.
              final cell =
                  constraints.maxWidth / (columns + (scrolls ? .5 : 0));
              return SingleChildScrollView(
                key: const ValueKey('dots-row-pinned'),
                scrollDirection: Axis.horizontal,
                physics: scrolls ? null : const NeverScrollableScrollPhysics(),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in pinned)
                      SizedBox(
                        width: cell,
                        child: _TeamTile(
                          key: ValueKey('dots-pinned-${entry.profile.name}'),
                          entry: entry,
                          pinned: true,
                          main: isMainBot(entry.profile),
                          avatarCache: widget.avatarCache,
                          now: widget.now,
                          onTap: () => widget.onOpenBot(entry),
                          onLongPress: () => widget.onBotActions(entry),
                          screenAccess: widget.screenAccess,
                          onScreen: widget.onOpenScreen == null
                              ? null
                              : () => widget.onOpenScreen!(entry),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }
    // Owner (QA 9493): Rooms come right after Pinned, above Your team.
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
    final team = [?layout.main, ...layout.team];
    if (team.isNotEmpty) {
      items.add(
        _SectionLabel(
          key: const ValueKey('dots-team-header'),
          title: s.dotsTeam,
          count: team.length,
        ),
      );
      items.addAll(
        _rows(
          team,
          DotsHomeView.teamColumns(context),
          (entry) => _TeamTile(
            key: ValueKey('dots-tile-${entry.profile.name}'),
            entry: entry,
            main: identical(entry, layout.main),
            avatarCache: widget.avatarCache,
            now: widget.now,
            onTap: () => widget.onOpenBot(entry),
            onLongPress: () => widget.onBotActions(entry),
            screenAccess: widget.screenAccess,
            onScreen: widget.onOpenScreen == null
                ? null
                : () => widget.onOpenScreen!(entry),
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
    items.addAll(widget.footer);
    final list = ListView(
      key: const ValueKey('mission-bots'),
      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
      clipBehavior: widget.clipBehavior,
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

/// Display name of a bot: its title (the main bot, the one name the whole
/// app uses for the profile, [AgentProfile.visibleName]: «Hermes» only when
/// it has none) instead of the raw `default`.
String dotsTitle(BotRosterEntry entry) => entry.title;

bool _busy(BotFaceSignal signal) =>
    signal == BotFaceSignal.working ||
    signal == BotFaceSignal.thinking ||
    signal == BotFaceSignal.speaking;

/// The main bot's one status line: the canonical chat's current step, else
/// its last preview when the bot is free.
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

/// The approvals bar: one glass card with a shield, the summary and a
/// chevron. Tapping opens the approvals (or the blocked tasks chooser).
class _AttentionRow extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _AttentionRow({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
      child: HermesCard(
        key: const ValueKey('mission-attention'),
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpace.x4,
          vertical: HermesSpace.x3,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 24),
          child: Row(
            children: [
              Icon(Icons.shield_outlined, color: colors.accentText, size: 22),
              const SizedBox(width: HermesSpace.x3),
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.textSecondary),
            ],
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
      color: colors.textTertiary,
      fontSize: HermesType.sectionSize,
      fontWeight: FontWeight.w600,
      letterSpacing: HermesType.sectionTracking + 0.3,
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
                color: colors.accentText,
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

/// A bot in Your team, or in the Pinned row ([pinned]): the living face
/// (calm style: a small status dot, no ring), the name and one short line.
/// Pinned faces are [pinnedFaceSize], a quarter larger than the grid's,
/// and show a line only when it matters (waiting / working), muted.
class _TeamTile extends StatelessWidget {
  final BotRosterEntry entry;

  /// The main bot (Hermes): TalkBack names its role.
  final bool main;
  final bool pinned;
  final MissionProfileAvatarCache? avatarCache;
  final DateTime? now;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// The desktop shortcut: shown on the face only when [screenAccess] says
  /// this bot has one.
  final BotScreenAccess? screenAccess;
  final VoidCallback? onScreen;

  static const faceSize = 52.0;
  static const pinnedFaceSize = 64.0;

  const _TeamTile({
    super.key,
    required this.entry,
    this.main = false,
    this.pinned = false,
    required this.avatarCache,
    required this.onTap,
    required this.onLongPress,
    this.screenAccess,
    this.onScreen,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final access = screenAccess;
    if (access == null || onScreen == null) return _tile(context, false);
    return ListenableBuilder(
      listenable: access,
      builder: (context, _) => _tile(
        context,
        access.stateOf(botScreenProfile(entry.profile)) ==
            BotScreenState.available,
      ),
    );
  }

  Widget _tile(BuildContext context, bool showScreen) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final name = dotsTitle(entry);
    final at = entry.at;
    final status = entry.needsYou
        ? s.dotsWaiting
        : _busy(entry.signal)
        ? s.dotsWorking
        : at == null || pinned
        ? ''
        : rosterTime(context, at, now: now);
    final face = pinned ? pinnedFaceSize : faceSize;
    return Semantics(
      container: true,
      button: true,
      label: main
          ? s.dotsA11yMain(name, _a11yStatus(s, entry))
          : s.dotsA11yBot(name, _a11yStatus(s, entry)),
      onTap: onTap,
      onLongPress: onLongPress,
      customSemanticsActions: {
        if (showScreen) CustomSemanticsAction(label: s.bsaScreen): onScreen!,
      },
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
                    dimension: face + 12,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        LivingBotFace(
                          profileName: entry.profile.name,
                          profile: entry.profile,
                          avatarCache: avatarCache,
                          signal: entry.signal,
                          size: face,
                          style: LivingBotFaceStyle.calm,
                        ),
                        if (showScreen)
                          PositionedDirectional(
                            top: -6,
                            end: -6,
                            child: _ScreenBadge(
                              key: ValueKey(
                                'roster-screen-${entry.profile.name}',
                              ),
                              label: s.bsaScreen,
                              onTap: onScreen!,
                            ),
                          ),
                      ],
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
                      color: pinned
                          ? colors.textSecondary
                          : _statusColor(colors, entry.signal),
                      fontSize: HermesType.subtitleSize,
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

/// The small "desktop" button on a bot's face: a 22 dp disc inside a 40 dp
/// touch target, so it never covers the name below.
class _ScreenBadge extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ScreenBadge({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: 40,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                shape: BoxShape.circle,
                border: Border.all(color: colors.divider),
              ),
              child: SizedBox.square(
                dimension: 22,
                child: Icon(
                  Icons.desktop_windows_outlined,
                  size: 13,
                  color: colors.textPrimary,
                ),
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
        child: HermesCard(
          key: ValueKey('roster-room-row-$id'),
          onTap: onTap,
          onLongPress: onLongPress,
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
                style: TextStyle(
                  color: lineColor,
                  fontSize: HermesType.subtitleSize,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
