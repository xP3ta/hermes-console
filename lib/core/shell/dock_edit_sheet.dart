import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'gesture_dock.dart' show gestureDockTabIcon, gestureDockTabLabel;
import 'gesture_dock_state.dart';
import '../design/modal.dart';

/// Opens the dock's edit mode: which items it shows (2–5, Inicio always)
/// and in which order. One layout for General and Bots, stored on the
/// device. Reached by the "Editar dock" entry of every item's menu, a long
/// press on the bar outside the items and Ajustes › Dock. Every item is on
/// offer here, Ajustes, Proyectos, Cron, Tareas and Actividad included.
Future<void> showDockEditSheet(
  BuildContext context, {
  GestureDockController? controller,
}) async {
  final c = controller ?? GestureDockController.instance;
  // The one floating modal surface (spec 080): never a bottom sheet.
  await showHermesSurface<void>(
    context: context,
    surfaceKey: const ValueKey('dock-edit-surface'),
    maxHeightFactor: 0.8,
    builder: (_) => DockEditSheet(controller: c),
  );
}

class DockEditSheet extends StatefulWidget {
  final GestureDockController controller;

  const DockEditSheet({required this.controller, super.key});

  @override
  State<DockEditSheet> createState() => _DockEditSheetState();
}

class _DockEditSheetState extends State<DockEditSheet> {
  late List<GestureDockTab> _draft = [...widget.controller.value.tabs];

  bool get _full => _draft.length >= GestureDockTab.maxTabs;
  bool get _minimal => _draft.length <= GestureDockTab.minTabs;

  void _move(int from, int to) {
    if (to < 0 || to >= _draft.length || from == to) return;
    setState(() {
      final tab = _draft.removeAt(from);
      _draft.insert(to, tab);
    });
  }

  void _remove(GestureDockTab tab) {
    if (tab == GestureDockTab.home || _minimal) return;
    setState(() => _draft.remove(tab));
  }

  void _add(GestureDockTab tab) {
    if (_full || _draft.contains(tab)) return;
    setState(() => _draft.add(tab));
  }

  void _reset() => setState(() => _draft = [...GestureDockTab.defaultLayout]);

  void _done() {
    unawaited(widget.controller.setTabs(_draft));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final available = [
      for (final tab in GestureDockTab.values)
        if (!_draft.contains(tab)) tab,
    ];
    TextStyle section() => TextStyle(
      color: colors.textSecondary,
      fontSize: 13,
      fontWeight: FontWeight.w700,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: Column(
        key: const ValueKey('dock-edit-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              strings.gdEditTitle,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              strings.gdEditHint,
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          Flexible(
            child: CustomScrollView(
              shrinkWrap: true,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(strings.gdEditOnDock, style: section()),
                  ),
                ),
                SliverReorderableList(
                  itemCount: _draft.length,
                  onReorderItem: _move,
                  itemBuilder: (context, index) =>
                      _selectedRow(context, strings, colors, index),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Text(strings.gdEditAvailable, style: section()),
                  ),
                ),
                SliverList.list(
                  children: [
                    for (final tab in available)
                      ListTile(
                        key: ValueKey('dock-edit-available-${tab.name}'),
                        leading: Icon(gestureDockTabIcon(tab)),
                        title: Text(gestureDockTabLabel(strings, tab)),
                        trailing: IconButton(
                          key: ValueKey('dock-edit-add-${tab.name}'),
                          tooltip: _full
                              ? strings.gdEditFull
                              : strings.gdEditAdd,
                          icon: const Icon(Icons.add_circle_outline_rounded),
                          onPressed: _full ? null : () => _add(tab),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                TextButton(
                  key: const ValueKey('dock-edit-reset'),
                  onPressed: _reset,
                  child: Text(strings.gdEditReset),
                ),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('dock-edit-done'),
                  onPressed: _done,
                  child: Text(strings.gdEditDone),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectedRow(
    BuildContext context,
    Strings strings,
    HermesThemeColors colors,
    int index,
  ) {
    final tab = _draft[index];
    final home = tab == GestureDockTab.home;
    final label = gestureDockTabLabel(strings, tab);
    return Semantics(
      key: ValueKey('dock-edit-selected-${tab.name}'),
      // TalkBack reorders with actions instead of a drag.
      customSemanticsActions: {
        if (index > 0)
          CustomSemanticsAction(label: strings.gdEditMoveUp): () =>
              _move(index, index - 1),
        if (index < _draft.length - 1)
          CustomSemanticsAction(label: strings.gdEditMoveDown): () =>
              _move(index, index + 1),
      },
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          leading: Icon(gestureDockTabIcon(tab), color: colors.accent),
          title: Text(label),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: ValueKey('dock-edit-remove-${tab.name}'),
                tooltip: home ? strings.gdEditHomeFixed : strings.gdEditRemove,
                icon: const Icon(Icons.remove_circle_outline_rounded),
                onPressed: home || _minimal ? null : () => _remove(tab),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  key: ValueKey('dock-edit-drag-${tab.name}'),
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    Icons.drag_handle_rounded,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
