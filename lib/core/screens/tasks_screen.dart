// Kanban de Hermes — board del agente (local o remoto), no almacenamiento local.
//
// Todo tira del agente: las columnas, tarjetas y cambios en vivo provienen del
// plugin Kanban del dashboard (/api/plugins/kanban/) vía [KanbanClient]. El
// tablero antiguo en SharedPreferences se ha retirado; esta pantalla requiere
// una conexión activa (el drawer la deshabilita sin instancia).
//
// Sin dependencias nuevas — drag & drop con LongPressDraggable + DragTarget;
// tiempo real con dart:io WebSocket dentro de KanbanClient.
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/agent_profile.dart';
import '../models/connection.dart';
import '../models/kanban.dart';
import '../services/kanban_client.dart';
import '../services/connection_manager.dart' show DashboardHttpException;
import '../theme/app_theme.dart';
import '../widgets/accent_card.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/kanban_task_detail_surface.dart';
import 'lock_screen.dart';

class TasksScreen extends StatefulWidget {
  final SavedConnection connection;
  final KanbanClient? clientOverride;
  final Stream<KanbanEvent>? eventStreamOverride;
  final String? initialBoard;
  final String? initialTaskId;
  final String? initialAssignee;

  const TasksScreen({
    required this.connection,
    this.clientOverride,
    this.eventStreamOverride,
    this.initialBoard,
    this.initialTaskId,
    this.initialAssignee,
    super.key,
  });

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> with WidgetsBindingObserver {
  late final KanbanClient _client;
  KanbanBoard? _board;
  bool _loading = true;
  String? _error;
  String _searchQuery = '';
  KanbanMobileGroup? _taskFilter;
  String? _assigneeFilter;
  bool _includeArchived = false;

  List<KanbanBoardRef> _boards = const [];
  late String? _selectedBoard;
  bool _boardCapabilityChecked = false;
  bool _initialTaskOpened = false;

  StreamSubscription<KanbanEvent>? _eventsSub;
  Timer? _refreshDebounce;
  Timer? _reconnectTimer;
  bool _disposed = false;

  // Backoff de reconexión del WS (3s→60s). Sin esto, con el dashboard caído
  // la pantalla reintentaba cada 3s para siempre (reload + ticket + connect
  // con la radio despierta), incluso con la app en background (spec 028).
  Duration _reconnectDelay = const Duration(seconds: 3);
  bool _paused = false;

  // Perfiles asignables (quién EJECUTA la tarea). Se cargan una vez al abrir
  // la pantalla; el formulario los ofrece para que la tarea sea ejecutable.
  List<AgentProfile> _profiles = const [];

  @override
  void initState() {
    super.initState();
    _selectedBoard = widget.initialBoard;
    _assigneeFilter = switch (widget.initialAssignee?.trim()) {
      final value? when value.isNotEmpty => value,
      _ => null,
    };
    WidgetsBinding.instance.addObserver(this);
    _client = widget.clientOverride ?? KanbanClient(widget.connection);
    _load().whenComplete(() {
      if (mounted) {
        _subscribeEvents();
        _scheduleInitialTaskOpen();
      }
    });
  }

  void _scheduleInitialTaskOpen() {
    final taskId = widget.initialTaskId?.trim();
    if (_initialTaskOpened || taskId == null || taskId.isEmpty) return;
    _initialTaskOpened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        KanbanTask? task;
        for (final column in _board?.columns ?? const <KanbanColumn>[]) {
          for (final candidate in column.tasks) {
            if (candidate.id == taskId) {
              task = candidate;
              break;
            }
          }
          if (task != null) break;
        }
        task ??= await _client.getTask(taskId, board: _selectedBoard);
        if (mounted) await _openTaskSheet(task);
      } catch (error) {
        if (mounted) _snack(_humanError(error));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Los Timer de Dart SIGUEN disparando con la app pausada (solo los
    // Tickers vsync se congelan): sin esto, el bucle de reconexión seguía
    // gastando red y batería en background.
    switch (state) {
      case AppLifecycleState.resumed:
        if (_paused) {
          _paused = false;
          _reconnectDelay = const Duration(seconds: 3);
          _silentReload().whenComplete(() {
            if (!_disposed && !_paused) _subscribeEvents();
          });
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _paused = true;
        _reconnectTimer?.cancel();
        _eventsSub?.cancel();
        _eventsSub = null;
    }
  }

  /// Carga perezosa de perfiles. NO se hace en paralelo con el board: el
  /// dashboard inicia sesión por cookie y dos peticiones concurrentes con la
  /// cookie aún vacía disparan dos logins que se pisan (uno gana, el otro
  /// cae con 401) → la lista de perfiles quedaba vacía. Se llama tras el
  /// board (cookie ya establecida) y como red de seguridad al abrir el form.
  Future<void> _ensureProfiles() async {
    if (_profiles.isNotEmpty) return;
    final profiles = await _client.getProfiles();
    if (!mounted) return;
    setState(() => _profiles = profiles);
  }

  /// Perfil sugerido por defecto al crear: el del gateway activo, si no el
  /// `default`, si no el primero. Vacío si no hay perfiles (degrada a anotación).
  String _defaultAssignee() {
    final contextual = widget.initialAssignee?.trim() ?? '';
    if (contextual.isNotEmpty) return contextual;
    if (_profiles.isEmpty) return '';
    final running = _profiles.where((p) => p.gatewayRunning);
    if (running.isNotEmpty) return running.first.name;
    final def = _profiles.where((p) => p.isDefault);
    if (def.isNotEmpty) return def.first.name;
    return _profiles.first.name;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _refreshDebounce?.cancel();
    _reconnectTimer?.cancel();
    _eventsSub?.cancel();
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    try {
      final board = await _client.getBoard(
        includeArchived: _includeArchived,
        board: _selectedBoard,
      );
      if (!mounted) return;
      setState(() {
        _board = board;
        _error = null;
        _loading = false;
      });
      // Cookie ya establecida por getBoard: descubrir capacidades y perfiles
      // secuencialmente para no disparar logins paralelos que se pisen.
      await _discoverBoards();
      await _ensureProfiles();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _humanError(e);
        _loading = false;
      });
    }
  }

  Future<void> _discoverBoards() async {
    if (_boardCapabilityChecked) return;
    try {
      final catalog = await _client.getBoardsIfSupported();
      if (!mounted) return;
      if (catalog == null) {
        _boardCapabilityChecked = true;
        return;
      }
      final requested = _selectedBoard;
      final selected =
          requested != null &&
              catalog.boards.any((board) => board.slug == requested)
          ? requested
          : catalog.current ?? catalog.boards.first.slug;
      setState(() {
        _boards = catalog.boards;
        _selectedBoard = selected;
        _boardCapabilityChecked = true;
      });
    } catch (_) {
      // No degrada el tablero base por una capacidad opcional. Un refresh
      // manual vuelve a sondear si el fallo fue transitorio.
    }
  }

  void _subscribeEvents() {
    _eventsSub?.cancel();
    final stream =
        widget.eventStreamOverride ??
        _client.events(
          since: _board?.latestEventId ?? 0,
          board: _selectedBoard,
        );
    _eventsSub = stream.listen(
      (_) {
        // Señal de vida: el próximo corte reintenta rápido otra vez.
        _reconnectDelay = const Duration(seconds: 3);
        _scheduleRefresh();
      },
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );
  }

  /// Reabre el WS si se cae (ticket de un solo uso caducado, red, etc.) para
  /// que el board siga actualizándose solo. Refresca una vez al reconectar por
  /// si nos perdimos algún evento mientras estábamos desconectados.
  void _scheduleReconnect() {
    if (_disposed || _paused) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () {
      if (_disposed || _paused) return;
      _silentReload().whenComplete(() {
        if (!_disposed && !_paused) _subscribeEvents();
      });
    });
    // Duplica hasta 60s; se rearma a 3s cuando el stream vuelve a dar señal
    // de vida (evento recibido) o al volver de background.
    final next = _reconnectDelay * 2;
    _reconnectDelay = next > const Duration(seconds: 60)
        ? const Duration(seconds: 60)
        : next;
  }

  // Agrupa ráfagas de eventos en un solo refresco del board.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!_disposed) _silentReload();
    });
  }

  Future<void> _silentReload() async {
    try {
      final board = await _client.getBoard(
        includeArchived: _includeArchived,
        board: _selectedBoard,
      );
      if (!mounted) return;
      setState(() {
        _board = board;
        _error = null;
      });
    } catch (_) {
      // Mantiene el board actual si un refresco puntual falla.
    }
  }

  Future<void> _move(KanbanTask task, String toStatus) async {
    if (task.status == toStatus) return;
    if (!kKanbanMovableStatuses.contains(toStatus)) {
      _snack(
        Strings.of(context).kanbanManagedByAgent(kanbanColumnLabel(toStatus)),
      );
      return;
    }
    // Optimista: mueve la tarjeta en memoria y confirma contra el agente.
    final previous = _board;
    setState(() => _board = _withMovedTask(_board, task, toStatus));
    try {
      await _client.moveTask(task.id, toStatus, board: _selectedBoard);
      _scheduleRefresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _board = previous);
      _snack(_humanError(e));
    }
  }

  KanbanBoard? _withMovedTask(
    KanbanBoard? board,
    KanbanTask task,
    String toStatus,
  ) {
    if (board == null) return board;
    final cols = <KanbanColumn>[];
    for (final c in board.columns) {
      final filtered = c.tasks.where((t) => t.id != task.id).toList();
      if (c.name == toStatus) {
        filtered.insert(0, task.copyWith(status: toStatus));
      }
      cols.add(KanbanColumn(name: c.name, tasks: filtered));
    }
    return KanbanBoard(columns: cols, latestEventId: board.latestEventId);
  }

  Future<void> _delete(KanbanTask task) async {
    try {
      await _client.deleteTask(task.id, board: _selectedBoard);
      if (!mounted) return;
      _scheduleRefresh();
    } catch (e) {
      if (!mounted) return;
      _snack(_humanError(e));
    }
  }

  /// Limpia la sección "Hechas": archiva (no borra) cada tarea hecha. El
  /// historial sigue en el servidor; solo desaparecen del tablero.
  Future<void> _confirmClearDone(List<KanbanTask> done) async {
    if (done.isEmpty) return;
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(s.kanbanClearDoneTitle),
        content: Text(s.kanbanClearDoneConfirm(done.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(s.kanbanCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(
              s.kanbanClearDone,
              style: TextStyle(color: colors.accent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!await _verifyAppLock(s.kanbanClearDoneTitle) || !mounted) return;
    try {
      try {
        final result = await _client.bulkUpdate(
          done.map((task) => task.id),
          archive: true,
          board: _selectedBoard,
        );
        if (result.failed.isNotEmpty) {
          if (!mounted) return;
          final copy = _Kanban020Copy.forContext(context);
          await _showBulkFailures(result, copy);
          if (!mounted) return;
          _scheduleRefresh();
          return;
        }
      } on DashboardHttpException catch (error) {
        if (error.statusCode != 404 && error.statusCode != 405) rethrow;
        // Legacy seguro: una ruta inexistente no pudo aplicar cambios. Solo en
        // ese caso se conserva el archivo secuencial anterior.
        for (final task in done) {
          await _client.archiveTask(task.id, board: _selectedBoard);
        }
      }
      if (!mounted) return;
      _snack(s.kanbanCleared);
      _scheduleRefresh();
    } catch (e) {
      if (!mounted) return;
      _snack(_humanError(e));
    }
  }

  /// El endpoint bulk es deliberadamente parcial: un 200 no implica que todas
  /// las tarjetas se hayan archivado. Muestra cada fallo en vez de reducirlo a
  /// un contador que obligaría al usuario a adivinar qué tarea sigue pendiente.
  Future<void> _showBulkFailures(
    KanbanBulkResult result,
    _Kanban020Copy copy,
  ) async {
    final colors = Theme.of(context).hermes;
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('kanban-bulk-partial-surface'),
      maxWidth: 540,
      maxHeightFactor: 0.72,
      builder: (_) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
        children: [
          Text(
            copy.bulkPartialTitle,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            copy.bulkPartial(result.succeeded.length, result.failed.length),
            style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
          ),
          const SizedBox(height: 14),
          for (final failure in result.failed)
            Container(
              key: ValueKey('kanban-bulk-failure-${failure.id}'),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: colors.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.error.withValues(alpha: 0.32)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    failure.id,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    failure.error?.trim().isNotEmpty == true
                        ? failure.error!
                        : copy.actionUnavailable,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _create(
    String title,
    String? body,
    String? priority,
    String? assignee,
  ) async {
    try {
      await _client.createTask(
        title: title,
        body: body,
        priority: priority,
        assignee: assignee,
        board: _selectedBoard,
      );
      if (!mounted) return;
      _scheduleRefresh();
    } catch (e) {
      if (!mounted) return;
      _snack(_humanError(e));
    }
  }

  Future<void> _update(
    String id,
    String title,
    String? body,
    String? priority,
    String? assignee,
  ) async {
    try {
      await _client.updateTask(
        id,
        title: title,
        body: body,
        priority: priority,
        assignee: assignee,
        board: _selectedBoard,
      );
      if (!mounted) return;
      _scheduleRefresh();
    } catch (e) {
      if (!mounted) return;
      _snack(_humanError(e));
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _humanError(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  /// Las operaciones de recuperación, borrado y configuración cambian estado
  /// persistente del servidor. Si el usuario activó App Lock, se vuelven a
  /// verificar justo antes de la red para que un diálogo dejado abierto no
  /// pueda confirmar una mutación después de que la app haya quedado bloqueada.
  Future<bool> _verifyAppLock(String reason) async {
    if (!mounted || widget.connection.readOnly) return false;
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock == null || !lock.enabled) return true;
    final verified = await LockScreen.verify(context, lock, reason: reason);
    return verified && mounted;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        title: Text(
          s.kanbanTitle,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            letterSpacing: 1,
          ),
        ),
        actions: [
          if (_boards.length > 1)
            PopupMenuButton<String>(
              key: const ValueKey('kanban-board-selector'),
              tooltip: s.kanbanBoardLabel,
              initialValue: _selectedBoard,
              onSelected: _selectBoard,
              icon: const Icon(Icons.view_kanban_outlined),
              itemBuilder: (context) => [
                for (final board in _boards)
                  PopupMenuItem<String>(
                    value: board.slug,
                    child: Row(
                      children: [
                        Expanded(child: Text(board.name)),
                        if (board.slug == _selectedBoard)
                          Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: colors.accent,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          IconButton(
            key: const ValueKey('kanban-filter-button'),
            tooltip: s.kanbanFilterTitle,
            icon: Icon(
              _hasActiveFilters
                  ? Icons.filter_alt_rounded
                  : Icons.filter_alt_outlined,
              color: _hasActiveFilters ? colors.accent : null,
            ),
            onPressed: _openFilters,
          ),
          IconButton(
            tooltip: s.kanbanHelpTooltip,
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: _showHelp,
          ),
          IconButton(
            tooltip: s.kanbanRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      // FAB circular simple: el botón extendido se recortaba contra el borde.
      // Sólo cuando hay tareas (con el board vacío ya está el CTA grande).
      floatingActionButton:
          (_board != null &&
              _error == null &&
              _board!.taskCount > 0 &&
              !widget.connection.readOnly &&
              _taskFilter != KanbanMobileGroup.archived)
          ? FloatingActionButton(
              backgroundColor: colors.accent,
              tooltip: s.kanbanNewTask,
              onPressed: () => _openTaskForm(),
              child: Icon(Icons.add, color: colors.onAccent),
            )
          : null,
      body: _buildBody(colors),
    );
  }

  bool get _hasActiveFilters =>
      _searchQuery.trim().isNotEmpty ||
      _taskFilter != null ||
      _assigneeFilter != null;

  Future<void> _selectBoard(String slug) async {
    if (slug == _selectedBoard) return;
    _refreshDebounce?.cancel();
    _eventsSub?.cancel();
    _eventsSub = null;
    setState(() {
      _selectedBoard = slug;
      _board = null;
      _loading = true;
      _error = null;
      _searchQuery = '';
      _taskFilter = null;
      _includeArchived = false;
    });
    await _load();
    if (mounted) _subscribeEvents();
  }

  Future<void> _openFilters() async {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final queryCtrl = TextEditingController(text: _searchQuery);
    final selected = await showHermesFloatingSurface<String>(
      context: context,
      surfaceKey: const ValueKey('kanban-filter-surface'),
      maxWidth: 560,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s.kanbanFilterTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('kanban-search-field'),
                controller: queryCtrl,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: s.kanbanSearch,
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: queryCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: s.kanbanClearFilters,
                          onPressed: () {
                            queryCtrl.clear();
                            setState(() => _searchQuery = '');
                            setSheet(() {});
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
                onChanged: (value) {
                  setState(() => _searchQuery = value);
                  setSheet(() {});
                },
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _filterChip(
                    sheetCtx,
                    key: 'all',
                    label: s.kanbanFilterAll,
                    selected: _taskFilter == null,
                  ),
                  for (final group in KanbanMobileGroup.values)
                    _filterChip(
                      sheetCtx,
                      key: group.name,
                      label: _filterLabel(s, group),
                      selected: _taskFilter == group,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    Future.delayed(const Duration(milliseconds: 400), queryCtrl.dispose);
    if (selected == null || !mounted) return;
    await _applyTaskFilter(selected);
  }

  Widget _filterChip(
    BuildContext sheetCtx, {
    required String key,
    required String label,
    required bool selected,
  }) {
    return FilterChip(
      key: ValueKey('kanban-filter-$key'),
      selected: selected,
      label: Text(label),
      onSelected: (_) => Navigator.of(sheetCtx).pop(key),
    );
  }

  Future<void> _applyTaskFilter(String value) async {
    final filter = value == 'all'
        ? null
        : KanbanMobileGroup.values
              .where((candidate) => candidate.name == value)
              .firstOrNull;
    final needsArchiveFetch =
        filter == KanbanMobileGroup.archived && !_includeArchived;
    setState(() {
      _taskFilter = filter;
      _includeArchived = filter == KanbanMobileGroup.archived;
    });
    if (needsArchiveFetch) await _load();
  }

  void _clearFilters() {
    setState(() {
      _searchQuery = '';
      _taskFilter = null;
      _assigneeFilter = null;
      _includeArchived = false;
    });
  }

  String _filterLabel(Strings s, KanbanMobileGroup group) {
    switch (group) {
      case KanbanMobileGroup.attention:
        return s.kanbanGroupAttention;
      case KanbanMobileGroup.working:
        return s.kanbanGroupWorking;
      case KanbanMobileGroup.queued:
        return s.kanbanGroupQueued;
      case KanbanMobileGroup.notes:
        return s.kanbanGroupNotes;
      case KanbanMobileGroup.done:
        return s.kanbanGroupDone;
      case KanbanMobileGroup.archived:
        return s.kanbanFilterArchived;
    }
  }

  /// Hoja de ayuda: explica el modelo del tablero (tarea + perfil → el agente
  /// la ejecuta). Resuelve el "no sé sacarle partido / no entiendo cómo está
  /// distribuido": el problema era de comprensión, no solo de diseño.
  Future<void> _showHelp() async {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('kanban-help-surface'),
      maxWidth: 560,
      builder: (sheetCtx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dashboard_customize_outlined,
                  size: 20,
                  color: colors.accent,
                ),
                const SizedBox(width: 8),
                Text(
                  s.kanbanHelpTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              s.kanbanHelpBody,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(HermesThemeColors colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorState(colors: colors, message: _error!, onRetry: _load);
    }
    final board = _board;
    final s = Strings.of(context);
    if (board == null || (board.taskCount == 0 && !_hasActiveFilters)) {
      return _EmptyState(
        colors: colors,
        readOnly: widget.connection.readOnly,
        onCreate: () => _openTaskForm(),
        onHelp: _showHelp,
      );
    }
    // Bandeja agrupada: una sola lista vertical con secciones humanas. Los 8
    // estados técnicos del motor de Hermes se proyectan a 5 grupos que un
    // humano entiende; las secciones vacías no se muestran. Mover/reasignar
    // se hace tocando la tarjeta (hoja de detalle), no con drag.
    final groups = _buildGroups(board, s);
    return RefreshIndicator(
      onRefresh: _silentReload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 100),
        children: [
          if (_hasActiveFilters) ...[
            _FilterSummary(
              colors: colors,
              label: _assigneeFilter != null
                  ? '@$_assigneeFilter'
                  : _taskFilter == null
                  ? s.kanbanFilterAll
                  : _filterLabel(s, _taskFilter!),
              query: _searchQuery.trim(),
              clearLabel: s.kanbanClearFilters,
              onClear: _clearFilters,
            ),
            const SizedBox(height: 12),
          ],
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 20),
              child: Text(
                s.kanbanNoMatches,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          for (final g in groups) ...[
            _GroupHeader(
              colors: colors,
              group: g,
              // Solo "Hechas" ofrece limpiar en bloque (archivar, no borra).
              onClear: g.key == 'done' && !widget.connection.readOnly
                  ? () => _confirmClearDone(g.tasks)
                  : null,
              clearLabel: s.kanbanClearDone,
            ),
            const SizedBox(height: 8),
            for (final t in g.tasks)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _TaskCard(
                  colors: colors,
                  task: t,
                  statusColor: g.color,
                  onTap: () => _openTaskSheet(t),
                ),
              ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  /// Proyecta los estados del board a grupos humanos, en orden de prioridad de
  /// atención. Sólo devuelve grupos no vacíos.
  List<_TaskGroup> _buildGroups(KanbanBoard board, Strings s) {
    final attention = <KanbanTask>[];
    final working = <KanbanTask>[];
    final queued = <KanbanTask>[];
    final notes = <KanbanTask>[];
    final done = <KanbanTask>[];
    final archived = <KanbanTask>[];

    for (final col in board.columns) {
      for (final t in col.tasks) {
        if (_assigneeFilter != null && t.assignee?.trim() != _assigneeFilter) {
          continue;
        }
        if (!kanbanTaskMatchesFilter(
          t,
          query: _searchQuery,
          group: _taskFilter,
        )) {
          continue;
        }
        switch (kanbanMobileGroupFor(t)) {
          case KanbanMobileGroup.attention:
            attention.add(t);
          case KanbanMobileGroup.working:
            working.add(t);
          case KanbanMobileGroup.queued:
            queued.add(t);
          case KanbanMobileGroup.notes:
            notes.add(t);
          case KanbanMobileGroup.done:
            done.add(t);
          case KanbanMobileGroup.archived:
            archived.add(t);
        }
      }
    }

    final colors = Theme.of(context).hermes;
    final groups = <_TaskGroup>[
      _TaskGroup(
        'attention',
        s.kanbanGroupAttention,
        s.kanbanColBlocked,
        Icons.warning_amber_rounded,
        colors.error,
        attention,
      ),
      _TaskGroup(
        'working',
        s.kanbanGroupWorking,
        s.kanbanColRunning,
        Icons.settings_suggest_outlined,
        colors.accent,
        working,
      ),
      _TaskGroup(
        'queued',
        s.kanbanGroupQueued,
        s.kanbanGroupQueued,
        Icons.schedule_rounded,
        colors.accent,
        queued,
      ),
      _TaskGroup(
        'notes',
        s.kanbanGroupNotes,
        s.kanbanUnassigned,
        Icons.sticky_note_2_outlined,
        colors.textSecondary,
        notes,
      ),
      _TaskGroup(
        'done',
        s.kanbanGroupDone,
        s.kanbanColDone,
        Icons.check_circle_outline_rounded,
        colors.success,
        done,
      ),
    ];
    if (_taskFilter == KanbanMobileGroup.archived) {
      return [
        _TaskGroup(
          'archived',
          s.kanbanFilterArchived,
          s.kanbanFilterArchived,
          Icons.archive_outlined,
          colors.textSecondary,
          archived,
        ),
      ].where((g) => g.tasks.isNotEmpty).toList();
    }
    return groups.where((g) => g.tasks.isNotEmpty).toList();
  }

  /// Selector de destino para mover una tarjeta (sustituye al drag&drop, poco
  /// práctico en móvil con columnas fuera de pantalla). Solo ofrece estados a
  /// los que el cliente puede mover (el agente gestiona 'running').
  Future<void> _pickMove(KanbanTask task) async {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final target = await showHermesFloatingSurface<String>(
      context: context,
      surfaceKey: const ValueKey('kanban-move-surface'),
      maxWidth: 520,
      builder: (sheetCtx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 10),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                s.kanbanMove,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
          for (final st in kKanbanColumnOrder)
            if (kKanbanMovableStatuses.contains(st) && st != task.status)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: colors.accent,
                ),
                title: Text(
                  _colLabel(s, st),
                  style: TextStyle(color: colors.textPrimary),
                ),
                onTap: () => Navigator.of(sheetCtx).pop(st),
              ),
        ],
      ),
    );
    if (target != null) _move(task, target);
  }

  /// Etiqueta localizada (es/en) de una columna/estado del board de Hermes.
  String _colLabel(Strings s, String name) {
    switch (name) {
      case 'triage':
        return s.kanbanColTriage;
      case 'todo':
        return s.kanbanColTodo;
      case 'scheduled':
        return s.kanbanColScheduled;
      case 'ready':
        return s.kanbanColReady;
      case 'running':
        return s.kanbanColRunning;
      case 'blocked':
        return s.kanbanColBlocked;
      case 'review':
        return s.kanbanColReview;
      case 'done':
        return s.kanbanColDone;
      case 'archived':
        return s.kanbanFilterArchived;
    }
    return kanbanColumnLabel(name);
  }

  // ── Sheets ────────────────────────────────────────────────────────────

  /// Formulario de tarea: crea ([existing]==null) o edita una tarjeta. Al crear
  /// ofrece plantillas rápidas (bug/feature/investigar) que rellenan título y
  /// descripción.
  Future<void> _openTaskForm({KanbanTask? existing}) async {
    // Red de seguridad: asegura los perfiles antes de calcular el sugerido.
    await _ensureProfiles();
    if (!mounted) return;
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final editing = existing != null;
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final bodyCtrl = TextEditingController(text: existing?.body ?? '');
    String priority = existing?.priority ?? 'normal';
    // assignee = perfil que EJECUTA la tarea. Al crear se sugiere el activo
    // para que la tarea se trabaje sola; '' = sin asignar (sólo anotación).
    String assignee = existing?.assignee ?? _defaultAssignee();

    void applyTemplate(String title, String body) {
      titleCtrl.text = title;
      titleCtrl.selection = TextSelection.collapsed(offset: title.length);
      bodyCtrl.text = body;
    }

    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('kanban-task-form-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.9,
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: StatefulBuilder(
          builder: (sheetCtx, setSheet) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  editing ? s.kanbanEditTask : s.kanbanNewTask,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                if (!editing) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _taskTemplateChip(
                        colors,
                        Icons.bug_report_outlined,
                        s.kanbanTplBugName,
                        () {
                          applyTemplate(s.kanbanTplBugName, s.kanbanTplBugBody);
                          setSheet(() {});
                        },
                      ),
                      _taskTemplateChip(
                        colors,
                        Icons.auto_awesome_outlined,
                        s.kanbanTplFeatureName,
                        () {
                          applyTemplate(
                            s.kanbanTplFeatureName,
                            s.kanbanTplFeatureBody,
                          );
                          setSheet(() {});
                        },
                      ),
                      _taskTemplateChip(
                        colors,
                        Icons.search,
                        s.kanbanTplResearchName,
                        () {
                          applyTemplate(s.kanbanTplResearchName, '');
                          setSheet(() {});
                        },
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                TextField(
                  controller: titleCtrl,
                  autofocus: !editing,
                  decoration: InputDecoration(labelText: s.kanbanFieldTitle),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: bodyCtrl,
                  maxLines: 4,
                  minLines: 3,
                  decoration: InputDecoration(labelText: s.kanbanFieldDesc),
                ),
                const SizedBox(height: 12),
                _formSelector(
                  colors: colors,
                  label: s.kanbanFieldPriority,
                  valueText: _priorityLabel(s, priority),
                  onTap: () async {
                    final v = await _pickOption(
                      title: s.kanbanFieldPriority,
                      current: priority,
                      options: [
                        (value: 'low', label: s.kanbanPriorityLow),
                        (value: 'normal', label: s.kanbanPriorityNormal),
                        (value: 'high', label: s.kanbanPriorityHigh),
                      ],
                    );
                    if (v != null) setSheet(() => priority = v);
                  },
                ),
                const SizedBox(height: 12),
                _formSelector(
                  colors: colors,
                  label: s.kanbanFieldAssignee,
                  valueText: assignee.isEmpty ? s.kanbanAssigneeNone : assignee,
                  valueColor: assignee.isEmpty
                      ? colors.textSecondary
                      : colors.accent,
                  onTap: () async {
                    final v = await _pickOption(
                      title: s.kanbanFieldAssignee,
                      current: assignee,
                      options: [
                        (value: '', label: s.kanbanAssigneeNone),
                        for (final p in _profiles)
                          (value: p.name, label: p.name),
                      ],
                    );
                    if (v != null) setSheet(() => assignee = v);
                  },
                ),
                const SizedBox(height: 8),
                _assigneeHint(colors, s, assignee.isNotEmpty),
                const SizedBox(height: 18),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: colors.accent),
                  onPressed: () {
                    final title = titleCtrl.text.trim();
                    if (title.isEmpty) return;
                    Navigator.of(sheetCtx).pop();
                    final body = bodyCtrl.text.trim().isEmpty
                        ? null
                        : bodyCtrl.text.trim();
                    if (editing) {
                      _update(existing.id, title, body, priority, assignee);
                    } else {
                      _create(title, body, priority, assignee);
                    }
                  },
                  child: Text(
                    editing ? s.kanbanSave : s.kanbanCreate,
                    style: TextStyle(color: colors.onAccent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Libera los controllers DESPUÉS de la animación de cierre del sheet.
    // Liberarlos de inmediato (con la hoja aún cerrándose) hacía que el TextField
    // re-escuchara un TextEditingController ya destruido en el siguiente frame
    // → crash en cascada `_dependents.isEmpty`. Son variables locales: la closure
    // sigue siendo válida aunque la pantalla se cierre antes.
    Future.delayed(const Duration(milliseconds: 400), () {
      titleCtrl.dispose();
      bodyCtrl.dispose();
    });
  }

  String _priorityLabel(Strings s, String value) {
    switch (value) {
      case 'low':
        return s.kanbanPriorityLow;
      case 'high':
        return s.kanbanPriorityHigh;
      default:
        return s.kanbanPriorityNormal;
    }
  }

  /// Nota bajo el selector de perfil: explica si la tarea se ejecutará o es
  /// solo una anotación. Sin perfil el dispatcher nunca la coge.
  Widget _assigneeHint(HermesThemeColors colors, Strings s, bool assigned) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          assigned ? Icons.play_circle_outline : Icons.sticky_note_2_outlined,
          size: 14,
          color: assigned ? colors.accent : colors.textSecondary,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            assigned ? s.kanbanAssigneeHintRun : s.kanbanAssigneeHintNote,
            style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
          ),
        ),
      ],
    );
  }

  /// Campo de formulario con aspecto de input pero que abre un selector en
  /// hoja inferior al tocarlo. Evita el `DropdownButton` (texto en negrita del
  /// tema + el menú se solapaba sobre el título de la hoja). Texto en peso
  /// normal, legible.
  Widget _formSelector({
    required HermesThemeColors colors,
    required String label,
    required String valueText,
    required VoidCallback onTap,
    Color? valueColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: Icon(Icons.expand_more_rounded, color: colors.accent),
        ),
        child: Text(
          valueText,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
            color: valueColor ?? colors.textPrimary,
          ),
        ),
      ),
    );
  }

  /// Selector genérico en hoja inferior (radio). Devuelve el valor elegido o
  /// null si se cancela. Tipografía controlada, sin solapamientos.
  Future<String?> _pickOption({
    required String title,
    required String current,
    required List<({String value, String label})> options,
  }) {
    final colors = Theme.of(context).hermes;
    return showHermesFloatingSurface<String>(
      context: context,
      surfaceKey: const ValueKey('kanban-option-surface'),
      maxWidth: 520,
      builder: (sheetCtx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 10),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
          for (final o in options)
            ListTile(
              dense: true,
              title: Text(
                o.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: colors.textPrimary,
                ),
              ),
              trailing: o.value == current
                  ? Icon(Icons.check_rounded, size: 18, color: colors.accent)
                  : null,
              onTap: () => Navigator.of(sheetCtx).pop(o.value),
            ),
        ],
      ),
    );
  }

  Widget _taskTemplateChip(
    HermesThemeColors colors,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: colors.surfaceVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colors.accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openTaskSheet(KanbanTask task) async {
    final colors = Theme.of(context).hermes;
    final copy = _Kanban020Copy.forContext(context);
    Future<KanbanTaskDetail> detailFuture = _client.getTaskDetail(
      task.id,
      board: _selectedBoard,
    );
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('kanban-task-detail-surface'),
      maxWidth: 580,
      maxHeightFactor: 0.88,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => FutureBuilder<KanbanTaskDetail>(
          future: detailFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                key: ValueKey('kanban-task-detail-loading'),
                height: 220,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError || snapshot.data == null) {
              return _TaskDetailError(
                colors: colors,
                message: _humanError(snapshot.error ?? 'invalid task'),
                onRetry: () {
                  setSheet(() {
                    detailFuture = _client.getTaskDetail(
                      task.id,
                      board: _selectedBoard,
                    );
                  });
                },
              );
            }
            final detail = snapshot.data!;

            void refreshDetail() {
              if (!sheetCtx.mounted) return;
              setSheet(() {
                detailFuture = _client.getTaskDetail(
                  detail.task.id,
                  board: _selectedBoard,
                );
              });
            }

            Future<void> mutate(Future<void> Function() action) async {
              try {
                await action();
                _scheduleRefresh();
                refreshDetail();
              } catch (error) {
                if (!mounted) return;
                _snack(_humanError(error));
                if (error is DashboardHttpException &&
                    error.statusCode == 409) {
                  refreshDetail();
                }
              }
            }

            Future<void> guarded(Future<void> Function() action) async {
              try {
                await action();
              } catch (error) {
                if (mounted) _snack(_humanError(error));
              }
            }

            final hydratedTask = detail.task;
            return KanbanTaskDetailSurface(
              detail: detail,
              readOnly: widget.connection.readOnly,
              onAddComment: widget.connection.readOnly
                  ? null
                  : (body) => mutate(
                      () => _client.addComment(
                        hydratedTask.id,
                        body,
                        board: _selectedBoard,
                      ),
                    ),
              onUploadAttachment: widget.connection.readOnly
                  ? null
                  : () => mutate(() => _uploadTaskAttachment(hydratedTask.id)),
              onDownloadAttachment: (attachment) =>
                  guarded(() => _downloadTaskAttachment(attachment)),
              onDeleteAttachment: widget.connection.readOnly
                  ? null
                  : (attachment) =>
                        mutate(() => _deleteTaskAttachment(attachment)),
              onInspectRun: (run) => guarded(() => _showRunInspection(run)),
              onTerminateRun: widget.connection.readOnly
                  ? null
                  : (run) => mutate(() => _terminateRun(run)),
              onShowLog: () => guarded(() => _showTaskLog(hydratedTask.id)),
              onReclaim: widget.connection.readOnly
                  ? null
                  : () => mutate(() => _reclaimTask(hydratedTask)),
              onReassign: widget.connection.readOnly
                  ? null
                  : () => mutate(() => _reassignTask(hydratedTask)),
              onSpecify: widget.connection.readOnly
                  ? null
                  : () => mutate(() async {
                      if (!await _confirm020(
                        title: copy.specifyTitle,
                        body: copy.specifyBody,
                        confirmLabel: copy.specify,
                      )) {
                        return;
                      }
                      if (!await _verifyAppLock(copy.specifyTitle)) return;
                      final result = await _client.specifyTask(
                        hydratedTask.id,
                        author: 'mobile',
                        board: _selectedBoard,
                      );
                      if (!mounted) return;
                      _snack(
                        result.ok
                            ? copy.specifyStarted
                            : (result.reason ?? copy.actionUnavailable),
                      );
                    }),
              onDecompose: widget.connection.readOnly
                  ? null
                  : () => mutate(() async {
                      if (!await _confirm020(
                        title: copy.decomposeTitle,
                        body: copy.decomposeBody,
                        confirmLabel: copy.decompose,
                      )) {
                        return;
                      }
                      if (!await _verifyAppLock(copy.decomposeTitle)) return;
                      final result = await _client.decomposeTask(
                        hydratedTask.id,
                        author: 'mobile',
                        board: _selectedBoard,
                      );
                      if (!mounted) return;
                      _snack(
                        result.ok
                            ? copy.decomposeResult(result.childIds.length)
                            : (result.reason ?? copy.actionUnavailable),
                      );
                    }),
              onConfigureModel: detail.capabilities.isEmpty
                  ? null
                  : () => mutate(() => _configureTaskModel(hydratedTask)),
              onOpenLinkedTask: (id) async {
                Navigator.of(sheetCtx).pop();
                await Future<void>.delayed(const Duration(milliseconds: 350));
                if (!mounted) return;
                await _openTaskSheet(
                  KanbanTask(id: id, title: id, body: '', status: 'todo'),
                );
              },
              onArchive: widget.connection.readOnly
                  ? null
                  : () {
                      Navigator.of(sheetCtx).pop();
                      _confirmArchive(hydratedTask);
                    },
              onDelete: widget.connection.readOnly
                  ? null
                  : () {
                      Navigator.of(sheetCtx).pop();
                      _confirmDelete(hydratedTask);
                    },
              onMove: widget.connection.readOnly
                  ? null
                  : () {
                      Navigator.of(sheetCtx).pop();
                      _pickMove(hydratedTask);
                    },
              onEdit: widget.connection.readOnly
                  ? null
                  : () {
                      Navigator.of(sheetCtx).pop();
                      _openTaskForm(existing: hydratedTask);
                    },
            );
          },
        ),
      ),
    );
  }

  Future<bool> _confirm020({
    required String title,
    required String body,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(s.kanbanCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(
              confirmLabel,
              style: TextStyle(
                color: destructive ? colors.error : colors.accent,
              ),
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _uploadTaskAttachment(String taskId) async {
    final copy = _Kanban020Copy.forContext(context);
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    if (picked.size > kKanbanAttachmentMaxBytes) {
      _snack(copy.attachmentTooLarge);
      return;
    }
    final path = picked.path;
    if (path == null || path.isEmpty) {
      _snack(copy.attachmentUnavailable);
      return;
    }
    await _client.uploadAttachment(
      taskId,
      filePath: path,
      filename: picked.name,
      uploadedBy: 'mobile',
      board: _selectedBoard,
    );
    if (mounted) _snack(copy.attachmentUploaded);
  }

  Future<void> _downloadTaskAttachment(KanbanAttachment attachment) async {
    final copy = _Kanban020Copy.forContext(context);
    final download = await _client.downloadAttachment(
      attachment.id,
      board: _selectedBoard,
    );
    final path = await FilePicker.platform.saveFile(
      dialogTitle: copy.saveAttachment,
      fileName: attachment.safeFilename,
      bytes: download.bytes,
    );
    if (path != null && mounted) _snack(copy.attachmentSaved);
  }

  Future<void> _deleteTaskAttachment(KanbanAttachment attachment) async {
    final copy = _Kanban020Copy.forContext(context);
    final confirmed = await _confirm020(
      title: copy.deleteAttachment,
      body: copy.deleteAttachmentBody(attachment.safeFilename),
      confirmLabel: copy.delete,
      destructive: true,
    );
    if (!confirmed) return;
    if (!await _verifyAppLock(copy.deleteAttachment)) return;
    await _client.deleteAttachment(attachment.id, board: _selectedBoard);
    if (mounted) _snack(copy.attachmentDeleted);
  }

  Future<void> _showTaskLog(String taskId) async {
    final colors = Theme.of(context).hermes;
    final copy = _Kanban020Copy.forContext(context);
    final future = _client.getTaskLog(
      taskId,
      tailBytes: 65536,
      board: _selectedBoard,
    );
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('kanban-log-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.82,
      builder: (_) => FutureBuilder<KanbanTaskLog>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 220,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError || snapshot.data == null) {
            return Padding(
              padding: const EdgeInsets.all(22),
              child: Text(
                _humanError(snapshot.error ?? copy.actionUnavailable),
              ),
            );
          }
          final log = snapshot.data!;
          return Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  copy.workerLog,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      log.exists && log.content.isNotEmpty
                          ? log.content
                          : copy.noLog,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        height: 1.35,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
                if (log.truncated) ...[
                  const SizedBox(height: 10),
                  Text(
                    copy.logTruncated,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showRunInspection(KanbanRun run) async {
    final colors = Theme.of(context).hermes;
    final copy = _Kanban020Copy.forContext(context);
    final future = _client.inspectRun(run.id, board: _selectedBoard);
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('kanban-run-inspection-surface'),
      maxWidth: 520,
      builder: (_) => FutureBuilder<KanbanRunInspection>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError || snapshot.data == null) {
            return Padding(
              padding: const EdgeInsets.all(22),
              child: Text(
                _humanError(snapshot.error ?? copy.actionUnavailable),
              ),
            );
          }
          final inspection = snapshot.data!;
          return Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${copy.runInspection} #${run.id}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                _inspectionRow(
                  copy.alive,
                  inspection.alive ? copy.yes : copy.no,
                ),
                if (inspection.pid != null)
                  _inspectionRow('PID', '${inspection.pid}'),
                if (inspection.status?.isNotEmpty == true)
                  _inspectionRow(copy.status, inspection.status!),
                if (inspection.cpuPercent != null)
                  _inspectionRow('CPU', '${inspection.cpuPercent}%'),
                if (inspection.memoryRssBytes != null)
                  _inspectionRow(
                    copy.memory,
                    _formatBytes020(inspection.memoryRssBytes!),
                  ),
                if (inspection.numThreads != null)
                  _inspectionRow(copy.threads, '${inspection.numThreads}'),
                if (inspection.reason?.isNotEmpty == true)
                  _inspectionRow(copy.reason, inspection.reason!),
                if (inspection.error?.isNotEmpty == true)
                  _inspectionRow(copy.error, inspection.error!),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _inspectionRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(label, style: const TextStyle(fontSize: 11.5)),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );

  Future<void> _terminateRun(KanbanRun run) async {
    final copy = _Kanban020Copy.forContext(context);
    if (!await _confirm020(
      title: copy.terminateTitle,
      body: copy.terminateBody(run.id),
      confirmLabel: copy.terminate,
      destructive: true,
    )) {
      return;
    }
    if (!await _verifyAppLock(copy.terminateTitle)) return;
    await _client.terminateRun(
      run.id,
      reason: 'Terminated from Hermes Console',
      board: _selectedBoard,
    );
    if (mounted) _snack(copy.runTerminated);
  }

  Future<void> _reclaimTask(KanbanTask task) async {
    final copy = _Kanban020Copy.forContext(context);
    if (!await _confirm020(
      title: copy.reclaimTitle,
      body: copy.reclaimBody,
      confirmLabel: copy.reclaim,
      destructive: true,
    )) {
      return;
    }
    if (!await _verifyAppLock(copy.reclaimTitle)) return;
    await _client.reclaimTask(
      task.id,
      reason: 'Reclaimed from Hermes Console',
      board: _selectedBoard,
    );
    if (mounted) _snack(copy.taskReclaimed);
  }

  Future<void> _reassignTask(KanbanTask task) async {
    final copy = _Kanban020Copy.forContext(context);
    await _ensureProfiles();
    if (!mounted) return;
    if (_profiles.isEmpty) {
      _snack(copy.actionUnavailable);
      return;
    }
    final profile = await _pickOption(
      title: copy.chooseProfile,
      current: task.assignee ?? '',
      options: [
        for (final profile in _profiles)
          (value: profile.name, label: profile.name),
      ],
    );
    if (profile == null || !mounted) return;
    if (!await _confirm020(
      title: copy.reassignTitle,
      body: copy.reassignBody(profile, task.status == 'running'),
      confirmLabel: copy.reassign,
    )) {
      return;
    }
    if (!await _verifyAppLock(copy.reassignTitle)) return;
    await _client.reassignTask(
      task.id,
      profile: profile,
      reclaimFirst: task.status == 'running',
      reason: 'Reassigned from Hermes Console',
      board: _selectedBoard,
    );
    if (mounted) _snack(copy.taskReassigned);
  }

  Future<void> _configureTaskModel(KanbanTask task) async {
    final copy = _Kanban020Copy.forContext(context);
    KanbanModelOptions options;
    try {
      options = await _client.getModelOptions();
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) {
        _snack(copy.modelOptionsUnavailable);
        return;
      }
      rethrow;
    }
    if (!mounted) return;
    if (options.providers.isEmpty && task.modelOverride == null) {
      _snack(copy.modelOptionsUnavailable);
      return;
    }
    final selection = await showHermesFloatingSurface<_KanbanModelChoice>(
      context: context,
      surfaceKey: const ValueKey('kanban-model-options-surface'),
      maxWidth: 560,
      maxHeightFactor: 0.82,
      builder: (surfaceCtx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 18),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
              copy.chooseModel,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          ListTile(
            key: const ValueKey('kanban-model-inherit'),
            leading: const Icon(Icons.call_merge_rounded),
            title: Text(copy.inheritModel),
            onTap: () => Navigator.of(
              surfaceCtx,
            ).pop(const _KanbanModelChoice(provider: '', model: '')),
          ),
          for (final provider in options.providers) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
              child: Text(
                provider.label,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final model in provider.models)
              ListTile(
                dense: true,
                title: Text(
                  model,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing:
                    provider.slug == task.providerOverride &&
                        model == task.modelOverride
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(surfaceCtx).pop(
                  _KanbanModelChoice(provider: provider.slug, model: model),
                ),
              ),
          ],
        ],
      ),
    );
    if (selection == null || !mounted) return;
    final effort = await _pickOption(
      title: copy.reasoningEffort,
      current: task.reasoningEffort ?? '',
      options: [
        (value: '', label: copy.inheritEffort),
        for (final value in kKanbanReasoningEfforts)
          (value: value, label: copy.effortLabel(value)),
      ],
    );
    if (effort == null || !mounted) return;
    final modelLabel = selection.model.isEmpty
        ? copy.inheritModel
        : '${selection.provider}: ${selection.model}';
    if (!await _confirm020(
      title: copy.applyModelTitle,
      body: copy.applyModelBody(modelLabel, effort),
      confirmLabel: copy.apply,
    )) {
      return;
    }
    if (!await _verifyAppLock(copy.applyModelTitle)) return;
    await _client.updateTaskOverrides(
      task.id,
      model: selection.model,
      provider: selection.provider,
      reasoningEffort: effort,
      clearModel: selection.model.isEmpty,
      clearReasoningEffort: effort.isEmpty,
      board: _selectedBoard,
    );
    if (mounted) _snack(copy.modelApplied);
  }

  String _formatBytes020(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  Future<void> _confirmArchive(KanbanTask task) async {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(s.kanbanArchiveTitle),
        content: Text(s.kanbanArchiveConfirm(task.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(s.kanbanCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(s.kanbanArchive),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!await _verifyAppLock(s.kanbanArchiveTitle) || !mounted) return;
    try {
      await _client.archiveTask(task.id, board: _selectedBoard);
      if (!mounted) return;
      _snack(s.kanbanArchived);
      _scheduleRefresh();
    } catch (e) {
      if (!mounted) return;
      _snack(_humanError(e));
    }
  }

  Future<void> _confirmDelete(KanbanTask task) async {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(s.kanbanDeleteTitle),
        content: Text(s.kanbanDeletePermanentConfirm(task.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(s.kanbanCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(
              s.kanbanDeletePermanent,
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!await _verifyAppLock(s.kanbanDeleteTitle) || !mounted) return;
    await _delete(task);
  }
}

/// Un grupo humano de la bandeja (proyección de varios estados del motor).
class _TaskGroup {
  final String key;
  final String label;
  final String shortLabel; // etiqueta corta para el badge de cada tarjeta
  final IconData icon;
  final Color color;
  final List<KanbanTask> tasks;

  const _TaskGroup(
    this.key,
    this.label,
    this.shortLabel,
    this.icon,
    this.color,
    this.tasks,
  );
}

class _FilterSummary extends StatelessWidget {
  final HermesThemeColors colors;
  final String label;
  final String query;
  final String clearLabel;
  final VoidCallback onClear;

  const _FilterSummary({
    required this.colors,
    required this.label,
    required this.query,
    required this.clearLabel,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.divider.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(Icons.filter_alt_rounded, size: 16, color: colors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              query.isEmpty ? label : '$label · $query',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
          ),
          IconButton(
            key: const ValueKey('kanban-clear-filters'),
            tooltip: clearLabel,
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _TaskDetailError extends StatelessWidget {
  final HermesThemeColors colors;
  final String message;
  final VoidCallback onRetry;

  const _TaskDetailError({
    required this.colors,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Padding(
      key: const ValueKey('kanban-task-detail-error'),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 34, color: colors.textSecondary),
          const SizedBox(height: 12),
          Text(
            s.kanbanDetailLoadError,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('kanban-task-detail-retry'),
            style: FilledButton.styleFrom(backgroundColor: colors.accent),
            onPressed: onRetry,
            icon: Icon(Icons.refresh_rounded, color: colors.onAccent),
            label: Text(
              s.kanbanRetry,
              style: TextStyle(color: colors.onAccent),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cabecera de sección de la bandeja: icono + nombre + recuento. Opcionalmente
/// una acción "Limpiar" a la derecha (solo en Hechas).
class _GroupHeader extends StatelessWidget {
  final HermesThemeColors colors;
  final _TaskGroup group;
  final VoidCallback? onClear;
  final String? clearLabel;

  const _GroupHeader({
    required this.colors,
    required this.group,
    this.onClear,
    this.clearLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Row(
        children: [
          Icon(group.icon, size: 16, color: group.color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              group.label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: group.color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${group.tasks.length}',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: group.color,
              ),
            ),
          ),
          if (onClear != null) ...[
            const SizedBox(width: 6),
            TextButton.icon(
              key: ValueKey('kanban-clear-${group.key}'),
              onPressed: onClear,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(
                Icons.cleaning_services_outlined,
                size: 14,
                color: colors.textSecondary,
              ),
              label: Text(
                clearLabel ?? '',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final HermesThemeColors colors;
  final KanbanTask task;
  final Color statusColor;
  final VoidCallback onTap;

  const _TaskCard({
    required this.colors,
    required this.task,
    required this.statusColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final assignee = task.assignee ?? '';
    final hasAssignee = assignee.isNotEmpty;
    final highPrio = (task.priority == 'high');
    return AccentCard(
      key: ValueKey('kanban-task-${task.id}'),
      background: colors.surface,
      borderColor: statusColor.withValues(alpha: 0.30),
      accent: statusColor,
      accentWidth: 3,
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              if (task.body.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  task.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: colors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Perfil ejecutor: lo más importante para entender si la
                  // tarea se trabajará o es solo una nota.
                  _Chip(
                    colors: colors,
                    icon: hasAssignee
                        ? Icons.person_outline
                        : Icons.sticky_note_2_outlined,
                    label: hasAssignee ? assignee : s.kanbanUnassigned,
                    color: hasAssignee ? colors.accent : colors.textSecondary,
                  ),
                  if (highPrio)
                    _Chip(
                      colors: colors,
                      icon: Icons.priority_high_rounded,
                      label: s.kanbanPriorityHigh,
                      color: colors.error,
                    ),
                  if (task.hasProgress)
                    _Chip(
                      colors: colors,
                      icon: Icons.donut_large_rounded,
                      label: '${task.progressDone}/${task.progressTotal}',
                      color: statusColor,
                    ),
                  if (task.commentCount > 0)
                    _Chip(
                      colors: colors,
                      icon: Icons.mode_comment_outlined,
                      label: '${task.commentCount}',
                      color: colors.textSecondary,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chip compacto (icono + texto) para metadatos de una tarjeta: perfil
/// ejecutor, prioridad alta, progreso, comentarios.
class _Chip extends StatelessWidget {
  final HermesThemeColors colors;
  final IconData icon;
  final String label;
  final Color color;

  const _Chip({
    required this.colors,
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final HermesThemeColors colors;
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.colors,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 40,
              color: colors.textSecondary,
            ),
            const SizedBox(height: 14),
            Text(
              Strings.of(context).kanbanLoadError,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: colors.accent),
              onPressed: onRetry,
              icon: Icon(Icons.refresh, color: colors.onAccent),
              label: Text(
                Strings.of(context).kanbanRetry,
                style: TextStyle(color: colors.onAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final HermesThemeColors colors;
  final bool readOnly;
  final VoidCallback onCreate;
  final VoidCallback onHelp;

  const _EmptyState({
    required this.colors,
    required this.readOnly,
    required this.onCreate,
    required this.onHelp,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dashboard_customize_outlined,
              size: 46,
              color: colors.accent,
            ),
            const SizedBox(height: 16),
            Text(
              s.kanbanEmptyTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.kanbanEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            if (!readOnly)
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: colors.accent),
                onPressed: onCreate,
                icon: Icon(Icons.add, color: colors.onAccent),
                label: Text(
                  s.kanbanEmptyCta,
                  style: TextStyle(color: colors.onAccent),
                ),
              ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: onHelp,
              icon: Icon(
                Icons.help_outline_rounded,
                size: 16,
                color: colors.accent,
              ),
              label: Text(
                s.kanbanHelpTooltip,
                style: TextStyle(color: colors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KanbanModelChoice {
  final String provider;
  final String model;

  const _KanbanModelChoice({required this.provider, required this.model});
}

/// Copy transitorio del lote 0.20. Las mismas claves viven en los ARB; se
/// mantiene aquí hasta el próximo `gen-l10n` global para no regenerar archivos
/// compartidos mientras otros lotes editan el catálogo en paralelo.
class _Kanban020Copy {
  final bool spanish;

  const _Kanban020Copy._(this.spanish);

  factory _Kanban020Copy.forContext(BuildContext context) => _Kanban020Copy._(
    Strings.of(context).localeName.toLowerCase().startsWith('es'),
  );

  String get bulkPartialTitle =>
      spanish ? 'Algunas tareas no cambiaron' : 'Some tasks were not changed';
  String bulkPartial(int ok, int failed) => spanish
      ? '$ok archivadas; $failed no se pudieron cambiar.'
      : '$ok archived; $failed could not be changed.';
  String get actionUnavailable => spanish
      ? 'Esta operación no está disponible en el servidor.'
      : 'This operation is not available on the server.';
  String get specify => spanish ? 'Especificar' : 'Specify';
  String get specifyTitle => spanish ? 'Especificar tarea' : 'Specify task';
  String get specifyBody => spanish
      ? 'Hermes usará el modelo auxiliar para completar esta tarea de triage. Puede tardar varios minutos.'
      : 'Hermes will use the auxiliary model to flesh out this triage task. This can take several minutes.';
  String get specifyStarted =>
      spanish ? 'La tarea se ha especificado.' : 'The task was specified.';
  String get decompose => spanish ? 'Descomponer' : 'Decompose';
  String get decomposeTitle =>
      spanish ? 'Descomponer en subtareas' : 'Decompose into child tasks';
  String get decomposeBody => spanish
      ? 'Hermes creará un grafo de subtareas y las asignará a perfiles compatibles. Puede tardar varios minutos.'
      : 'Hermes will create a child-task graph and route it to compatible profiles. This can take several minutes.';
  String decomposeResult(int count) => spanish
      ? 'Descomposición completada: $count subtareas.'
      : 'Decomposition complete: $count child tasks.';
  String get attachmentTooLarge => spanish
      ? 'El adjunto supera el límite oficial de 25 MiB.'
      : 'The attachment exceeds the official 25 MiB limit.';
  String get attachmentUnavailable => spanish
      ? 'Android no pudo proporcionar este archivo.'
      : 'Android could not provide this file.';
  String get attachmentUploaded =>
      spanish ? 'Adjunto subido.' : 'Attachment uploaded.';
  String get saveAttachment => spanish ? 'Guardar adjunto' : 'Save attachment';
  String get attachmentSaved =>
      spanish ? 'Adjunto guardado.' : 'Attachment saved.';
  String get deleteAttachment =>
      spanish ? 'Eliminar adjunto' : 'Delete attachment';
  String deleteAttachmentBody(String name) => spanish
      ? '¿Eliminar «$name» del servidor? Esta acción no se puede deshacer.'
      : 'Delete “$name” from the server? This cannot be undone.';
  String get delete => spanish ? 'Eliminar' : 'Delete';
  String get attachmentDeleted =>
      spanish ? 'Adjunto eliminado.' : 'Attachment deleted.';
  String get workerLog => spanish ? 'Log del worker' : 'Worker log';
  String get noLog => spanish
      ? 'Esta tarea todavía no tiene log.'
      : 'This task does not have a log yet.';
  String get logTruncated => spanish
      ? 'Se muestra únicamente la cola más reciente del log.'
      : 'Only the most recent log tail is shown.';
  String get runInspection =>
      spanish ? 'Estado de la ejecución' : 'Run inspection';
  String get alive => spanish ? 'Activo' : 'Alive';
  String get yes => spanish ? 'Sí' : 'Yes';
  String get no => 'No';
  String get status => spanish ? 'Estado' : 'Status';
  String get memory => 'RAM';
  String get threads => spanish ? 'Hilos' : 'Threads';
  String get reason => spanish ? 'Motivo' : 'Reason';
  String get error => 'Error';
  String get terminate => spanish ? 'Terminar' : 'Terminate';
  String get terminateTitle => spanish ? 'Terminar ejecución' : 'Terminate run';
  String terminateBody(int id) => spanish
      ? 'Se detendrá el worker de la ejecución #$id y la tarea volverá a la cola. ¿Continuar?'
      : 'The worker for run #$id will stop and the task will return to the queue. Continue?';
  String get runTerminated => spanish
      ? 'Ejecución terminada y reencolada.'
      : 'Run terminated and requeued.';
  String get reclaim => spanish ? 'Recuperar' : 'Reclaim';
  String get reclaimTitle =>
      spanish ? 'Recuperar tarea atascada' : 'Reclaim stuck task';
  String get reclaimBody => spanish
      ? 'Se detendrá el worker actual y la tarea volverá a «En cola». Úsalo solo si la ejecución está atascada.'
      : 'The current worker will stop and the task will return to the queue. Use this only for a stuck run.';
  String get taskReclaimed => spanish
      ? 'Tarea recuperada y reencolada.'
      : 'Task reclaimed and requeued.';
  String get chooseProfile => spanish ? 'Elegir perfil' : 'Choose profile';
  String get reassign => spanish ? 'Reasignar' : 'Reassign';
  String get reassignTitle => spanish ? 'Reasignar tarea' : 'Reassign task';
  String reassignBody(String profile, bool reclaims) => spanish
      ? 'La tarea se asignará a «$profile».${reclaims ? ' El worker actual se detendrá primero.' : ''}'
      : 'The task will be assigned to “$profile”.${reclaims ? ' The current worker will be stopped first.' : ''}';
  String get taskReassigned =>
      spanish ? 'Tarea reasignada.' : 'Task reassigned.';
  String get modelOptionsUnavailable => spanish
      ? 'Este servidor no publica opciones de modelo para Kanban.'
      : 'This server does not publish Kanban model options.';
  String get chooseModel =>
      spanish ? 'Modelo para esta tarea' : 'Model for this task';
  String get inheritModel =>
      spanish ? 'Heredar modelo del perfil' : 'Inherit model from profile';
  String get reasoningEffort =>
      spanish ? 'Esfuerzo de razonamiento' : 'Reasoning effort';
  String get inheritEffort =>
      spanish ? 'Heredar esfuerzo del perfil' : 'Inherit effort from profile';
  String effortLabel(String value) {
    if (value == 'none') return spanish ? 'Desactivado' : 'Off';
    if (value == 'minimal') return spanish ? 'Mínimo' : 'Minimal';
    if (value == 'low') return spanish ? 'Bajo' : 'Low';
    if (value == 'medium') return spanish ? 'Medio' : 'Medium';
    if (value == 'high') return spanish ? 'Alto' : 'High';
    if (value == 'xhigh') return spanish ? 'Muy alto' : 'XHigh';
    if (value == 'max') return spanish ? 'Máximo' : 'Max';
    return 'Ultra';
  }

  String get applyModelTitle =>
      spanish ? 'Aplicar configuración de modelo' : 'Apply model configuration';
  String applyModelBody(String model, String effort) {
    final effortLabelValue = effort.isEmpty
        ? inheritEffort
        : effortLabel(effort);
    return spanish
        ? 'Modelo: $model\nRazonamiento: $effortLabelValue'
        : 'Model: $model\nReasoning: $effortLabelValue';
  }

  String get apply => spanish ? 'Aplicar' : 'Apply';
  String get modelApplied => spanish
      ? 'Configuración de modelo aplicada.'
      : 'Model configuration applied.';
}
