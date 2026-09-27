import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/hermes_premium_ui.dart';
import '../../../widgets/mission_profile_avatar.dart';
import 'roster_model.dart';
import 'roster_rows.dart';

/// Bots roster (spec 070 S1): filter segment, pinned living faces, a
/// **Needs you** section first, then user sections from `ui_meta`, then
/// everything else by recency. Rows are dark and clean with one accent.
///
/// Lists use `cacheExtent: 0` so only on-screen faces exist, and therefore
/// only on-screen faces tick (spec 070 § Motion, T405).
class BotsRosterView extends StatefulWidget {
  final List<BotRosterEntry> bots;
  final List<RoomRosterEntry> rooms;
  final MissionProfileAvatarCache? avatarCache;
  final ValueNotifier<bool> searchOpen;
  final SharedPreferences? prefs;
  final String connectionId;
  final ValueChanged<BotRosterEntry> onOpenBot;
  final ValueChanged<BotRosterEntry> onBotActions;
  final ValueChanged<RoomRosterEntry> onOpenRoom;
  final void Function(String sectionId, String name)? onSectionMenu;

  /// Chat approvals / blocked Kanban tasks summary ("2 approvals · 0
  /// blocked"), shown as the first Needs-you row; tapping opens Work.
  final String? attentionSummary;
  final VoidCallback? onAttention;
  final Future<void> Function()? onRefresh;

  /// Shown instead of the list when there are no bots and no rooms.
  final Widget? emptyState;

  /// Extra widgets after the sections (e.g. remote bots, notices).
  final List<Widget> header;
  final List<Widget> footer;
  final DateTime? now;

  const BotsRosterView({
    super.key,
    required this.bots,
    required this.rooms,
    required this.avatarCache,
    required this.searchOpen,
    required this.connectionId,
    required this.onOpenBot,
    required this.onBotActions,
    required this.onOpenRoom,
    this.prefs,
    this.onSectionMenu,
    this.attentionSummary,
    this.onAttention,
    this.onRefresh,
    this.emptyState,
    this.header = const [],
    this.footer = const [],
    this.now,
  });

  @override
  State<BotsRosterView> createState() => _BotsRosterViewState();
}

class _BotsRosterViewState extends State<BotsRosterView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  RosterFilter _filter = RosterFilter.all;
  bool _showHidden = false;

  String get _foldKey =>
      'mission.bot-section-folds.v1.${Uri.encodeComponent(widget.connectionId)}';

  Set<String> get _folded =>
      (widget.prefs?.getStringList(_foldKey) ?? const <String>[]).toSet();

  @override
  void initState() {
    super.initState();
    widget.searchOpen.addListener(_onSearchToggle);
  }

  @override
  void didUpdateWidget(covariant BotsRosterView oldWidget) {
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

  void _toggleFold(String key) {
    final prefs = widget.prefs;
    if (prefs == null) return;
    final folded = _folded;
    if (!folded.remove(key)) folded.add(key);
    setState(() {
      unawaited(
        prefs
            .setStringList(_foldKey, folded.take(256).toList())
            .catchError((Object _) => false),
      );
    });
  }

  Widget _row(RosterEntry entry) => switch (entry) {
    BotRosterEntry() => RosterBotRow(
      entry: entry,
      avatarCache: widget.avatarCache,
      now: widget.now,
      onTap: () => widget.onOpenBot(entry),
      onLongPress: () => widget.onBotActions(entry),
    ),
    RoomRosterEntry() => RosterRoomRow(
      entry: entry,
      avatarCache: widget.avatarCache,
      now: widget.now,
      onTap: () => widget.onOpenRoom(entry),
    ),
  };

  List<Widget> _attentionRow() {
    final summary = widget.attentionSummary;
    final onTap = widget.onAttention;
    if (summary == null || onTap == null) return const [];
    final colors = Theme.of(context).hermes;
    return [
      Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('mission-attention'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 48,
                  child: Icon(Icons.front_hand_outlined, color: colors.warning),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 14.5,
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final query = widget.searchOpen.value ? _search.text : '';
    final layout = RosterLayout.build(
      bots: widget.bots,
      rooms: widget.rooms,
      filter: _filter,
      query: query,
      showHidden: _showHidden,
    );
    final folded = _folded;
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
      _FilterSegment(
        value: _filter,
        onChanged: (value) => setState(() => _filter = value),
      ),
      const SizedBox(height: 10),
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
    if (layout.pinned.isNotEmpty) {
      // Spec 080 polish: the strip is start-aligned with even spacing. With
      // one or two pinned bots a centred-less row of big faces left a wide
      // empty area, so they become compact face + name + status tiles.
      final compact = layout.pinned.length <= 2;
      Widget tile(BotRosterEntry entry) => RosterPinnedTile(
        key: ValueKey('mission-pinned-tile-${entry.profile.name}'),
        entry: entry,
        avatarCache: widget.avatarCache,
        compact: compact,
        onTap: () => widget.onOpenBot(entry),
        onLongPress: () => widget.onBotActions(entry),
      );
      items.add(
        compact
            ? Padding(
                key: const ValueKey('mission-pinned-strip'),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    for (var i = 0; i < layout.pinned.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: tile(layout.pinned[i])),
                    ],
                    if (layout.pinned.length == 1) const Spacer(),
                  ],
                ),
              )
            : SizedBox(
                // Sized to the tile itself (4 + 60 face + 8 + one name line
                // + 4): no dead space before the first section header.
                height: RosterPinnedTile.heightFor(context),
                child: ListView.separated(
                  key: const ValueKey('mission-pinned-strip'),
                  scrollDirection: Axis.horizontal,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  itemCount: layout.pinned.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => tile(layout.pinned[index]),
                ),
              ),
      );
    }
    final sectionsStart = items.length;
    for (final section in layout.sections) {
      final foldKey = switch (section.kind) {
        RosterSectionKind.needsYou => 'needs-you',
        RosterSectionKind.user => 'section:${section.id}',
        RosterSectionKind.recent => 'recent',
      };
      final collapsed =
          section.kind != RosterSectionKind.needsYou &&
          folded.contains(foldKey);
      items.add(
        _SectionHeader(
          key: ValueKey(switch (section.kind) {
            RosterSectionKind.needsYou => 'roster-section-needs-you',
            RosterSectionKind.user => 'mission-bot-section-$foldKey',
            RosterSectionKind.recent => 'roster-section-recent',
          }),
          title: switch (section.kind) {
            RosterSectionKind.needsYou => s.rosterNeedsYou,
            RosterSectionKind.user => section.name ?? '',
            RosterSectionKind.recent => s.rosterRecent,
          },
          count: section.entries.length,
          accent: section.kind == RosterSectionKind.needsYou
              ? colors.warning
              : null,
          collapsed: collapsed,
          onTap: section.kind == RosterSectionKind.needsYou
              ? null
              : () => _toggleFold(foldKey),
          onMore:
              section.kind == RosterSectionKind.user &&
                  widget.onSectionMenu != null
              ? () => widget.onSectionMenu!(section.id!, section.name ?? '')
              : null,
        ),
      );
      if (section.kind == RosterSectionKind.needsYou) {
        items.addAll(_attentionRow());
      }
      if (!collapsed) {
        for (final entry in section.entries) {
          items.add(_row(entry));
        }
      }
      items.add(const SizedBox(height: 8));
    }
    if (!layout.sections.any((x) => x.kind == RosterSectionKind.needsYou)) {
      final row = _attentionRow();
      if (row.isNotEmpty) {
        items.insertAll(sectionsStart, [
          _SectionHeader(
            key: const ValueKey('roster-section-needs-you'),
            title: s.rosterNeedsYou,
            count: 0,
            accent: colors.warning,
            collapsed: false,
          ),
          ...row,
        ]);
      }
    }
    if (layout.hiddenCount > 0 && _filter != RosterFilter.rooms) {
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
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: items,
    );
    final refresh = widget.onRefresh;
    return refresh == null
        ? list
        : RefreshIndicator(onRefresh: refresh, child: list);
  }
}

class _FilterSegment extends StatelessWidget {
  final RosterFilter value;
  final ValueChanged<RosterFilter> onChanged;

  const _FilterSegment({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    Widget chip(RosterFilter filter, String label) {
      final selected = filter == value;
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: Semantics(
          selected: selected,
          button: true,
          child: Material(
            key: ValueKey('roster-filter-${filter.name}'),
            color: selected
                ? colors.accent.withValues(alpha: .16)
                : colors.surfaceVariant.withValues(alpha: .5),
            shape: StadiumBorder(
              side: BorderSide(
                color: selected
                    ? colors.accent.withValues(alpha: .55)
                    : Colors.transparent,
              ),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => onChanged(filter),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      label,
                      style: TextStyle(
                        color: selected
                            ? colors.accentText
                            : colors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          chip(RosterFilter.all, s.rosterFilterAll),
          chip(RosterFilter.bots, s.rosterFilterBots),
          chip(RosterFilter.rooms, s.rosterFilterRooms),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color? accent;
  final bool collapsed;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  const _SectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.collapsed,
    this.accent,
    this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = accent ?? colors.textSecondary;
    // One quiet label: title and count share size, weight and baseline
    // ("Recent 6"), the fold chevron sits at the trailing edge.
    final style = TextStyle(
      color: color,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      letterSpacing: .2,
    );
    return Semantics(
      header: true,
      expanded: onTap == null ? null : !collapsed,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    title,
                    key: const ValueKey('roster-section-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Text(
                    '$count',
                    key: const ValueKey('roster-section-count'),
                    style: style.copyWith(
                      color: colors.textDisabled,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                const Spacer(),
                if (onMore != null)
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).moreButtonTooltip,
                    icon: const Icon(Icons.more_horiz, size: 18),
                    color: colors.textSecondary,
                    onPressed: onMore,
                  )
                else if (onTap != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 18,
                      color: colors.textDisabled,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
