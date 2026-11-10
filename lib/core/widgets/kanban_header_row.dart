// Cabecera compacta de una fila de la piel nueva del Kanban: contador,
// selector de tableros, vista, búsqueda, filtros, selección, ajustes de
// orquestación y "nueva tarea". En un ancho estrecho, búsqueda, selección y
// ajustes pasan a un menú para que la fila no se desborde.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart' show HermesAction, HermesMenuButton;
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';

class KanbanHeaderRow extends StatefulWidget {
  /// Tareas visibles (tras filtros).
  final int count;

  /// Selector de tableros ya construido; null con un solo tablero.
  final Widget? boardSelector;

  /// Vista de tablero activa. [onToggleView] null oculta el cambio de vista.
  final bool boardView;
  final VoidCallback? onToggleView;

  /// Texto de búsqueda en vigor y su escritura.
  final String query;
  final ValueChanged<String> onQueryChanged;

  final bool filtersActive;
  final VoidCallback onFilter;

  /// Null oculta la acción (solo lectura, filtro de archivadas…).
  final VoidCallback? onSettings;
  final VoidCallback? onCreate;

  /// Selección múltiple: null la oculta.
  final bool selecting;
  final VoidCallback? onToggleSelect;

  const KanbanHeaderRow({
    required this.count,
    required this.query,
    required this.onQueryChanged,
    required this.filtersActive,
    required this.onFilter,
    this.boardSelector,
    this.boardView = false,
    this.onToggleView,
    this.onSettings,
    this.onCreate,
    this.selecting = false,
    this.onToggleSelect,
    super.key,
  });

  /// Por debajo de este ancho, las acciones secundarias van a un menú.
  static const double narrowWidth = 400;

  @override
  State<KanbanHeaderRow> createState() => _KanbanHeaderRowState();
}

class _KanbanHeaderRowState extends State<KanbanHeaderRow> {
  late final TextEditingController _search = TextEditingController(
    text: widget.query,
  );
  late bool _searching = widget.query.trim().isNotEmpty;

  @override
  void didUpdateWidget(KanbanHeaderRow old) {
    super.didUpdateWidget(old);
    if (widget.query != _search.text) {
      _search.text = widget.query;
      if (widget.query.trim().isEmpty && old.query.trim().isNotEmpty) {
        _searching = false;
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() {
    _search.clear();
    widget.onQueryChanged('');
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(HermesRadius.floating),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x2),
        child: _searching ? _searchRow(s) : _actionsRow(colors, s),
      ),
    );
  }

  Widget _searchRow(Strings s) => Row(
    children: [
      Expanded(
        child: TextField(
          key: const ValueKey('kanban-skin-search-field'),
          controller: _search,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: s.kanbanSearch,
            border: InputBorder.none,
            isDense: true,
          ),
          onChanged: widget.onQueryChanged,
        ),
      ),
      IconButton(
        key: const ValueKey('kanban-skin-search-close'),
        tooltip: s.kanbanClearFilters,
        onPressed: _closeSearch,
        icon: const Icon(Icons.close_rounded),
      ),
    ],
  );

  Widget _actionsRow(HermesThemeColors colors, Strings s) {
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < KanbanHeaderRow.narrowWidth;
        final onSelect = widget.onToggleSelect;
        final onSettings = widget.onSettings;
        final selectLabel = widget.selecting
            ? s.kanbanSkinSelectExit
            : s.kanbanSkinSelect;
        return Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: HermesSpace.x2),
                child: Text(
                  s.kanbanSkinCount(widget.count),
                  key: const ValueKey('kanban-skin-count'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: HermesType.supportSize,
                    fontWeight: FontWeight.w700,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
            if (widget.boardSelector != null) widget.boardSelector!,
            if (widget.onToggleView != null)
              IconButton(
                // The key names where the button goes: tapping it from the
                // list opens the board, and the other way round.
                key: ValueKey(
                  widget.boardView ? 'kanban-view-list' : 'kanban-view-board',
                ),
                tooltip: widget.boardView
                    ? s.kanbanViewList
                    : s.kanbanViewBoard,
                onPressed: widget.onToggleView,
                icon: Icon(
                  widget.boardView
                      ? Icons.view_agenda_outlined
                      : Icons.view_column_outlined,
                ),
              ),
            if (!narrow)
              IconButton(
                key: const ValueKey('kanban-skin-search'),
                tooltip: s.kanbanSearch,
                onPressed: _openSearch,
                icon: Icon(
                  Icons.search_rounded,
                  color: widget.query.trim().isNotEmpty ? colors.accent : null,
                ),
              ),
            IconButton(
              key: const ValueKey('kanban-filter-button'),
              tooltip: s.kanbanFilterTitle,
              onPressed: widget.onFilter,
              icon: Icon(
                widget.filtersActive
                    ? Icons.filter_alt_rounded
                    : Icons.filter_alt_outlined,
                color: widget.filtersActive ? colors.accent : null,
              ),
            ),
            if (!narrow && onSelect != null)
              IconButton(
                key: const ValueKey('kanban-select-toggle'),
                tooltip: selectLabel,
                onPressed: onSelect,
                icon: Icon(
                  Icons.checklist_rounded,
                  color: widget.selecting ? colors.accent : null,
                ),
              ),
            if (!narrow && onSettings != null)
              IconButton(
                key: const ValueKey('kanban-skin-settings'),
                tooltip: s.kanbanOrchestrationTitle,
                onPressed: onSettings,
                icon: const Icon(Icons.tune_rounded),
              ),
            if (narrow)
              HermesMenuButton<String>(
                key: const ValueKey('kanban-skin-more'),
                actions: (_) => [
                  HermesAction(value: 'search', label: s.kanbanSearch),
                  if (onSelect != null)
                    HermesAction(
                      value: 'select',
                      label: selectLabel,
                      selected: widget.selecting ? true : null,
                    ),
                  if (onSettings != null)
                    HermesAction(
                      value: 'settings',
                      label: s.kanbanOrchestrationTitle,
                    ),
                ],
                onSelected: (value) {
                  switch (value) {
                    case 'search':
                      _openSearch();
                    case 'select':
                      onSelect?.call();
                    case 'settings':
                      onSettings?.call();
                  }
                },
              ),
            if (widget.onCreate != null)
              IconButton(
                key: const ValueKey('kanban-create'),
                tooltip: s.kanbanNewTask,
                onPressed: widget.onCreate,
                icon: const Icon(Icons.add_rounded),
              ),
          ],
        );
      },
    );
  }
}
