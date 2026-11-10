// Pieces of the flat Agents list (1.4.0): rows without a card, a thin line
// between them, the state at the right as a word + colour + icon, the folder
// headings, the small «they need you» tray, the filter chips and the folded
// «finished» section. Presentation only; the data is HerdrFlatList's.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/herdr_agents.dart';
import '../services/herdr_attention.dart';
import '../services/herdr_flat_list.dart';
import '../services/herdr_status.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'herdr_agents_widgets.dart';

/// The word for an agent's state in a row: a blocked one says what it needs
/// (a decision or a permission), the rest say what they do.
String agfStateLabel(Strings strings, HerdrAgentStatus status, HerdrAsk? ask) =>
    switch (status) {
      HerdrAgentStatus.blocked =>
        ask?.kind == HerdrAskKind.approval
            ? strings.agfReasonApproval
            : strings.agfStateAnswer,
      HerdrAgentStatus.working => strings.agfStateWorking,
      HerdrAgentStatus.idle => strings.agfStateFree,
      HerdrAgentStatus.done => strings.agfStateDone,
      HerdrAgentStatus.unknown => strings.hdaStatusUnknown,
    };

/// Why a blocked agent waits: question, approval, or just «it waits».
String agfReasonLabel(Strings strings, HerdrAsk? ask) => switch (ask?.kind) {
  HerdrAskKind.question => strings.agfReasonQuestion,
  HerdrAskKind.approval => strings.agfReasonApproval,
  _ => strings.agfReasonWaiting,
};

String _join(Iterable<String?> parts) =>
    parts.where((p) => p != null && p.isNotEmpty).join(' · ');

/// The state at the right of a row: the word first, then its colour and icon.
class HerdrStateMark extends StatelessWidget {
  const HerdrStateMark({required this.status, required this.label, super.key});

  final HerdrAgentStatus status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final blocked = status == HerdrAgentStatus.blocked;
    return Row(
      key: ValueKey('hda-mark-${status.name}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: HermesType.support.copyWith(
              color: blocked ? colors.textPrimary : colors.textSecondary,
              fontWeight: blocked ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(width: HermesSpace.x2),
        Icon(
          hdaStatusIcon(status),
          size: HermesIcon.sm,
          color: hdaStatusColor(colors, status),
        ),
      ],
    );
  }
}

/// One agent of the flat list: name (semibold), one line of what it does or
/// asks, and its state at the right. No card; the line under it is drawn by
/// the list.
class HerdrFlatRow extends StatelessWidget {
  const HerdrFlatRow({
    required this.row,
    required this.ask,
    required this.subtitle,
    required this.inState,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  final HerdrAgentRow row;

  /// What the screen asks, for a blocked agent.
  final HerdrAsk? ask;

  /// The one line under the name; null leaves the row with its name alone.
  final String? subtitle;

  /// How long it has been in this state, as the app saw it.
  final Duration? inState;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final state = agfStateLabel(strings, row.status, ask);
    final folder = hdaFolderText(strings, row.pane);
    final since = inState == null
        ? ''
        : strings.hdaInState(hdaDurationText(strings, inState!));
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: _join([
        strings.hdaRowSemantics(row.title, state, folder),
        subtitle,
        since,
      ]),
      hint: strings.hdaRowHint,
      onTap: onTap,
      child: ColoredBox(
        color: selected
            ? colors.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        child: InkWell(
          key: ValueKey('hda-row-${row.paneId}'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: HermesSpace.rowMin),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.rowH,
                vertical: HermesSpace.rowV,
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HermesType.body.copyWith(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            key: ValueKey('hda-sub-${row.paneId}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.support.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: HermesSpace.x3),
                  Flexible(
                    flex: 2,
                    child: HerdrStateMark(status: row.status, label: state),
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

/// The hairline between two rows (the theme's divider colour).
class HerdrRowLine extends StatelessWidget {
  const HerdrRowLine({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: HermesSpace.rowH,
    endIndent: HermesSpace.rowH,
    color: HermesSurfaces.divider(Theme.of(context).hermes),
  );
}

/// A folder's heading: its short name, the whole path in the tooltip and the
/// screen reader.
class HerdrFolderHeader extends StatelessWidget {
  const HerdrFolderHeader({required this.folder, super.key});

  final HerdrFolderEntry folder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final full = folder.path ?? folder.label;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: HermesSpace.rowH,
        end: HermesSpace.rowH,
        top: HermesSpace.x4,
        bottom: HermesSpace.x1,
      ),
      child: Semantics(
        header: true,
        container: true,
        label: full,
        excludeSemantics: true,
        child: Tooltip(
          message: full,
          child: Text(
            folder.label,
            key: ValueKey('hda-folder-${folder.path ?? 'unknown'}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HermesType.body.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry of the «they need you» tray.
class HerdrNeedItem {
  const HerdrNeedItem({
    required this.row,
    required this.ask,
    required this.folder,
  });

  final HerdrAgentRow row;
  final HerdrAsk? ask;

  /// Short folder name.
  final String folder;
}

/// The tray on top: small tags for the agents that wait on the user (why,
/// name, folder), side by side; a tap opens the agent.
class HerdrNeedsStrip extends StatelessWidget {
  const HerdrNeedsStrip({required this.items, required this.onOpen, super.key});

  final List<HerdrNeedItem> items;
  final ValueChanged<HerdrAgentRow> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Column(
      key: const ValueKey('hda-needs-strip'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: HermesSpace.rowH,
            end: HermesSpace.rowH,
            bottom: HermesSpace.x2,
          ),
          child: Semantics(
            header: true,
            liveRegion: true,
            container: true,
            label: strings.herdrNeedsYouCount(items.length),
            excludeSemantics: true,
            child: Text(
              strings.agfTrayTitle,
              style: HermesType.support.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        SingleChildScrollView(
          key: const ValueKey('hda-needs'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.rowH),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    end: HermesSpace.x2,
                  ),
                  child: _NeedTag(item: item, onOpen: onOpen),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NeedTag extends StatelessWidget {
  const _NeedTag({required this.item, required this.onOpen});

  final HerdrNeedItem item;
  final ValueChanged<HerdrAgentRow> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final reason = agfReasonLabel(strings, item.ask);
    final radius = BorderRadius.circular(HermesRadius.control);
    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label: strings.hdaRowSemantics(item.row.title, reason, item.folder),
      hint: strings.hdaRowHint,
      onTap: () => onOpen(item.row),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: HermesSpace.tap * 2,
          maxWidth: HermesSpace.tap * 4,
        ),
        child: Material(
          color: colors.warning.withValues(alpha: 0.14),
          borderRadius: radius,
          child: InkWell(
            key: ValueKey('hda-need-${item.row.paneId}'),
            borderRadius: radius,
            onTap: () => onOpen(item.row),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x3,
                  vertical: HermesSpace.x2,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          hdaStatusIcon(HerdrAgentStatus.blocked),
                          size: HermesIcon.sm,
                          color: colors.warning,
                        ),
                        const SizedBox(width: HermesSpace.x1),
                        Flexible(
                          child: Text(
                            reason,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.caption.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      item.row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.value.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      item.folder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.caption.copyWith(
                        color: colors.textSecondary,
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

/// Filter chips in one line that scrolls sideways: all, one per folder, then
/// the states. A folder and a state narrow the list together.
class HerdrChipsRow extends StatelessWidget {
  const HerdrChipsRow({
    required this.folders,
    required this.folder,
    required this.filter,
    required this.onAll,
    required this.onFolder,
    required this.onFilter,
    super.key,
  });

  final List<HerdrFolderEntry> folders;
  final String? folder;
  final HerdrStatusFilter filter;
  final VoidCallback onAll;
  final ValueChanged<String?> onFolder;
  final ValueChanged<HerdrStatusFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    String stateLabel(HerdrStatusFilter f) => switch (f) {
      HerdrStatusFilter.all => strings.hdaFilterAll,
      HerdrStatusFilter.blocked => strings.hdaStatusBlocked,
      HerdrStatusFilter.working => strings.hdaStatusWorking,
      HerdrStatusFilter.idle => strings.hdaStatusIdle,
    };
    Widget gap(Widget child) => Padding(
      padding: const EdgeInsetsDirectional.only(end: HermesSpace.x2),
      child: child,
    );
    return SingleChildScrollView(
      key: const ValueKey('hda-filters'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: HermesSpace.rowH),
      child: Row(
        children: [
          gap(
            HerdrGelButton(
              key: const ValueKey('hda-filter-all'),
              selected: filter == HerdrStatusFilter.all && folder == null,
              onTap: onAll,
              child: Text(strings.hdaFilterAll),
            ),
          ),
          // Agents without a known folder have no chip of their own.
          for (final entry in folders)
            if (entry.path != null)
              gap(
                HerdrGelButton(
                  key: ValueKey('hda-chip-folder-${entry.path}'),
                  semanticLabel: entry.path,
                  selected: entry.path == folder,
                  onTap: () =>
                      onFolder(entry.path == folder ? null : entry.path),
                  child: Text(entry.label),
                ),
              ),
          for (final f in HerdrStatusFilter.values)
            if (f != HerdrStatusFilter.all)
              gap(
                HerdrGelButton(
                  key: ValueKey('hda-filter-${f.name}'),
                  selected: f == filter,
                  onTap: () =>
                      onFilter(f == filter ? HerdrStatusFilter.all : f),
                  child: Text(stateLabel(f)),
                ),
              ),
        ],
      ),
    );
  }
}

/// A section folded by default at the end of the list («Finished (n)»,
/// «Terminals only (n)»): one line with its title and a chevron, and the rows
/// under it when opened.
class HerdrFoldSection extends StatelessWidget {
  const HerdrFoldSection({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.children,
    this.idKey = 'done',
    super.key,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;

  /// Names the section's keys (`hda-<idKey>`, `hda-<idKey>-toggle`).
  final String idKey;

  /// The rows (with their lines), shown when [expanded].
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Column(
      key: ValueKey('hda-$idKey'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: HermesSpace.x3),
        Semantics(
          button: true,
          container: true,
          excludeSemantics: true,
          label: title,
          hint: expanded ? strings.agfDoneCollapse : strings.agfDoneExpand,
          onTap: onToggle,
          child: InkWell(
            key: ValueKey('hda-$idKey-toggle'),
            onTap: onToggle,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.rowH,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: HermesType.body.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: colors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (expanded) ...children,
      ],
    );
  }
}

/// A Herdr workspace with no agent in it, for the folded «Terminals only»
/// section: its name and folder; a tap opens it in the terminal when the app
/// can.
class HerdrShellRow extends StatelessWidget {
  const HerdrShellRow({
    required this.workspace,
    required this.folder,
    required this.onTap,
    super.key,
  });

  final HerdrWorkspace workspace;

  /// Short folder name, empty when the workspace reports none.
  final String folder;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final text = _join([workspace.label, folder]);
    return Semantics(
      container: true,
      button: onTap != null,
      excludeSemantics: true,
      label: text,
      hint: onTap == null ? null : strings.hdpOpenTerminal,
      onTap: onTap,
      child: InkWell(
        key: ValueKey('hda-shell-${workspace.id}'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.rowH,
              vertical: HermesSpace.x2,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                if (onTap != null)
                  Icon(
                    Icons.terminal_rounded,
                    size: HermesIcon.md,
                    color: colors.textSecondary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
