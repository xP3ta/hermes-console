// Pantalla "Ejecuciones" — historial de runs lanzados desde esta app.
//
// Fuente de datos: RunRegistry local (SharedPreferences). El gateway no
// expone GET /v1/runs global; la app solo ve los runs que ella misma inició.
//
// Fase 2: SSE en vivo para runs no terminales mientras la pantalla está
// montada. Máximo 5 streams simultáneos (prioridad: waiting > running > queued).
// Todos los streams se cancelan en dispose() cerrando el ApiClient.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/active_chat_service.dart';
import '../services/bridge_client.dart';
import '../services/connection_manager.dart';
import '../services/run_registry.dart';
import '../services/run_template_store.dart';
import '../theme/app_theme.dart';
import '../services/notifications/notification_controller.dart';
import '../utils/relative_time.dart';
import '../utils/run_event_normalizer.dart';
import '../widgets/accent_card.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import '../widgets/run_template_composer.dart';
import 'runs_screen.dart' show RunDetailScreen, runStatusColor, runStatusLabel;

// Máximo de streams SSE simultáneos para no saturar el gateway.
const _kMaxLiveStreams = 5;

// Prioridad de status para decidir qué runs reciben SSE primero.
const _kStatusPriority = {
  'waiting_for_approval': 0,
  'running': 1,
  'stopping': 2,
  'queued': 3,
};

typedef TaskCenterRunStatusFetcher =
    Future<Map<String, dynamic>> Function(String runId);

@visibleForTesting
Future<void> refreshTaskCenterRunStatuses(
  RunRegistry registry,
  TaskCenterRunStatusFetcher fetchStatus,
) async {
  for (final record in registry.records.where((record) => !record.isTerminal)) {
    try {
      final status = await fetchStatus(record.runId);
      await registry.update(
        record.runId,
        profile: record.profile,
        lastStatus: status['status'] as String?,
        output: status['output'] as String?,
        error: status['error'] as String?,
      );
    } catch (error) {
      if (error.toString().contains('404')) {
        await registry.update(
          record.runId,
          profile: record.profile,
          lastStatus: 'expired',
        );
      }
    }
  }
}

@visibleForTesting
Future<RunRecord> persistTaskCenterRunUpdate(
  RunRegistry registry,
  RunRecord record,
  RunEventUpdate update, {
  double? updatedAt,
}) async {
  if (!update.shouldPersist) return record;
  final effectiveUpdatedAt =
      updatedAt ?? DateTime.now().millisecondsSinceEpoch / 1000;
  await registry.update(
    record.runId,
    profile: record.profile,
    lastStatus: update.lastStatus,
    progressLabel: update.progressLabel,
    lastEvent: update.lastEvent,
    updatedAt: effectiveUpdatedAt,
  );
  return record.copyWith(
    lastStatus: update.lastStatus,
    progressLabel: update.progressLabel,
    lastEvent: update.lastEvent,
    updatedAt: effectiveUpdatedAt,
  );
}

class TaskCenterScreen extends StatefulWidget {
  final SavedConnection connection;
  const TaskCenterScreen({required this.connection, super.key});

  @override
  State<TaskCenterScreen> createState() => _TaskCenterScreenState();
}

@visibleForTesting
String taskCenterRunOwnerKey(String profile, String runId) =>
    '${profile.trim().toLowerCase()}\u0000$runId';

class _TaskCenterScreenState extends State<TaskCenterScreen> {
  late final ApiClient _client;
  RunRegistry? _registry;
  RunTemplateStore? _templateStore;
  bool _refreshing = false;
  NotificationController? _notifCtrl;

  // RunIds con SSE abierto (para no abrir duplicados).
  final Set<String> _streamedRunIds = {};

  // Overrides de status/label en memoria para events frecuentes (message.delta).
  // No se persisten en SharedPreferences: solo viven mientras la pantalla esté
  // montada. Evita escritura masiva por cada token de respuesta.
  final Map<String, String> _statusOverrides = {};

  String _runOwnerKey(String profile, String runId) =>
      taskCenterRunOwnerKey(profile, runId);

  ActiveChatService? get _activeChats =>
      context.findAncestorStateOfType<HermesAppState>()?.activeChats;

  @override
  void initState() {
    super.initState();
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
    );
    _init();
  }

  @override
  void dispose() {
    _notifCtrl?.dispose();
    // Cierra el ApiClient → aborta todos los SSE abiertos con onError.
    // Los callbacks verifican `mounted` antes de setState, así que es seguro.
    _client.close();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final registry = await RunRegistry.load(prefs, widget.connection.id);
    final templateStore = await RunTemplateStore.load(prefs);
    if (!mounted) return;
    final notif = context
        .findAncestorStateOfType<HermesAppState>()
        ?.notifications;
    if (notif != null) {
      _notifCtrl = NotificationController(notif, connId: widget.connection.id);
    }
    setState(() {
      _registry = registry;
      _templateStore = templateStore;
    });
    await _refreshStatuses();
    // _openStreams() ya se llama al final de _refreshStatuses().
  }

  /// Refresca el estado de todos los runs no terminales vía GET /v1/runs/{id}.
  /// Al terminar, abre SSE para los que siguen activos.
  Future<void> _refreshStatuses() async {
    final registry = _registry;
    if (registry == null || _refreshing) return;
    setState(() => _refreshing = true);
    await refreshTaskCenterRunStatuses(registry, _client.getRun);
    if (!mounted) return;
    setState(() => _refreshing = false);
    // Abrir SSE para runs que siguen no terminales tras el refresh.
    _openStreams();
  }

  // ─── SSE ────────────────────────────────────────────────────────────────────

  /// Selecciona runs no terminales sin SSE abierto, prioriza por estado y
  /// abre hasta (_kMaxLiveStreams - activos actuales) streams nuevos.
  void _openStreams() {
    final registry = _registry;
    if (registry == null) return;

    final available = _kMaxLiveStreams - _streamedRunIds.length;
    if (available <= 0) return;

    final candidates =
        registry.records
            .where(
              (r) =>
                  !r.isTerminal &&
                  !_streamedRunIds.contains(_runOwnerKey(r.profile, r.runId)),
            )
            .toList()
          ..sort((a, b) {
            final pa = _kStatusPriority[a.lastStatus] ?? 99;
            final pb = _kStatusPriority[b.lastStatus] ?? 99;
            if (pa != pb) return pa.compareTo(pb);
            return b.createdAt.compareTo(a.createdAt); // más reciente primero
          });

    for (final r in candidates.take(available)) {
      _openStreamFor(r);
    }
  }

  /// Inicia el SSE para un run. No se awaita: corre en background hasta que
  /// el stream cierra o _client.close() lo aborta.
  void _openStreamFor(RunRecord record) {
    final runId = record.runId;
    final ownerKey = _runOwnerKey(record.profile, runId);
    if (_streamedRunIds.contains(ownerKey)) return;
    _streamedRunIds.add(ownerKey);

    _client.streamRunEvents(
      runId,
      onEvent: (event) => _onEvent(record, event),
      onDone: () => _onStreamClosed(record, pollAfter: true),
      onError: (_) => _onStreamClosed(record, pollAfter: false),
    );
    // streamRunEvents es Future<void>; no se awaita intencionalmente.
    // El ApiClient lo cancela en dispose() cerrando la conexión HTTP.
  }

  /// Procesa un evento SSE para un run. Persiste solo eventos importantes;
  /// para message.delta actualiza solo el override en memoria.
  Future<void> _onEvent(RunRecord record, Map<String, dynamic> event) async {
    final runId = record.runId;
    final ownerKey = _runOwnerKey(record.profile, runId);
    final update = normalizeRunEvent(event);
    if (update == null) return;

    final registry = _registry;
    var notificationRecord = record;

    if (update.shouldPersist && registry != null) {
      try {
        notificationRecord = await persistTaskCenterRunUpdate(
          registry,
          record,
          update,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('TaskCenter registry.update falló: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      if (!update.shouldPersist && update.lastStatus != null) {
        // message.delta: solo override en memoria (sin escritura a prefs).
        _statusOverrides[ownerKey] = update.lastStatus!;
      }
      if (update.isTerminal) {
        // El run terminó: limpiamos tracking y override de memoria.
        _streamedRunIds.remove(ownerKey);
        _statusOverrides.remove(ownerKey);
      }
    });
    _fireNotification(notificationRecord, update, event);
  }

  void _fireNotification(
    RunRecord record,
    RunEventUpdate update,
    Map<String, dynamic> rawEvent,
  ) {
    final ctrl = _notifCtrl;
    if (ctrl == null) return;

    final eventType = update.lastEvent;
    if (update.isTerminal) {
      switch (eventType) {
        case 'run.completed':
          ctrl.notifyRunFinished(record);
        case 'run.failed':
          ctrl.notifyRunFailed(record);
        case 'run.cancelled':
          ctrl.notifyRunCancelled(record);
      }
    } else if (eventType == 'approval.request') {
      final approvalId = (rawEvent['request_id'] ?? rawEvent['approval_id'])
          ?.toString()
          .trim();
      if (approvalId != null && approvalId.isNotEmpty) {
        ctrl.notifyRunWaitingApproval(record, approvalId: approvalId);
      }
    } else if (eventType == 'tool.started' && update.progressLabel != null) {
      ctrl.notifyRunProgress(record);
    }
  }

  /// El stream cerró (onDone = cierre limpio del servidor;
  /// onError = cliente cerrado o error de red).
  void _onStreamClosed(RunRecord record, {required bool pollAfter}) {
    final runId = record.runId;
    final ownerKey = _runOwnerKey(record.profile, runId);
    _streamedRunIds.remove(ownerKey);
    _statusOverrides.remove(ownerKey);
    if (!mounted) return;
    setState(() {});
    // Si el stream cerró limpiamente (el servidor lo terminó), hacemos un
    // GET final para sincronizar el estado exacto (output, uso de tokens…).
    if (pollAfter) _pollRunStatus(record);
  }

  /// GET /v1/runs/{runId} puntual para sincronizar el estado final de un run
  /// cuyo SSE se cerró limpiamente desde el servidor.
  Future<void> _pollRunStatus(RunRecord record) async {
    final registry = _registry;
    if (registry == null) return;
    try {
      final status = await _client.getRun(record.runId);
      await registry.update(
        record.runId,
        profile: record.profile,
        lastStatus: status['status'] as String?,
        output: status['output'] as String?,
        error: status['error'] as String?,
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (e.toString().contains('404')) {
        await registry.update(
          record.runId,
          profile: record.profile,
          lastStatus: 'expired',
        );
        if (mounted) setState(() {});
      }
    }
  }

  // ─── Lanzar run nuevo ────────────────────────────────────────────────────────

  Future<void> _newRun() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final store = _templateStore;
    if (store == null) return;
    // Composer con plantillas (predefinidas + propias) en lugar del campo en
    // blanco. Devuelve el prompt a lanzar, o null si se cancela.
    final prompt = await showRunComposer(context, store);
    if (prompt == null || prompt.isEmpty || !mounted) return;

    final s = Strings.of(context);
    try {
      // Instancia LOCAL: el agente no expone /v1/runs (daba HTTP 405). Ejecuta
      // por el Mobile Bridge (igual que el chat local) y muestra el resultado.
      // REMOTO: flujo /v1/runs + SSE en vivo, intacto.
      if (widget.connection.kind == InstanceKind.localhost) {
        await _launchLocalRun(prompt);
        return;
      }
      final runId = await _client.startRun(input: prompt);
      final record = RunRecord(
        runId: runId,
        prompt: prompt,
        createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
        lastStatus: 'queued',
      );
      await _registry?.add(record);
      if (!mounted) return;
      setState(() {});
      _openStreamFor(record); // abrir SSE de inmediato
      _openDetail(record);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.runsLaunchError(e.toString()))));
    }
  }

  /// Ejecución en instancia LOCAL vía Mobile Bridge (oneshot). No hay SSE en
  /// vivo: el bridge devuelve la respuesta final, que registramos y mostramos.
  Future<void> _launchLocalRun(String prompt) async {
    final conn = widget.connection;
    final s = Strings.of(context);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.runsLocalRunning)));
    }
    final base = conn.derivedBridgeUrl;
    final token = await BridgeClient.provision(base, conn.apiKey.trim());
    if (token == null || token.isEmpty) {
      throw Exception(s.runsLocalBridgeUnavailable);
    }
    final client = BridgeClient(baseUrl: base, token: token);
    final response = (await client.chat(prompt)).trim();
    final record = RunRecord(
      runId: 'local-${DateTime.now().millisecondsSinceEpoch}',
      prompt: prompt,
      createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
      lastStatus: 'completed',
      output: response,
    );
    await _registry?.add(record);
    if (!mounted) return;
    setState(() {});
    await _showLocalResult(response);
  }

  /// Muestra el resultado de una ejecución local (sin detalle en vivo). Texto
  /// plano (no SelectableText) para no reactivar el crash `_dependents.isEmpty`.
  Future<void> _showLocalResult(String response) async {
    if (!mounted) return;
    final colors = Theme.of(context).hermes;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Strings.of(context).commonResult),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              response.isEmpty ? Strings.of(context).commonNoOutput : response,
              style: TextStyle(color: colors.textPrimary, height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: response));
              Navigator.pop(ctx);
            },
            child: Text(Strings.of(context).commonCopy),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(Strings.of(context).commonClose),
          ),
        ],
      ),
    );
  }

  void _openDetail(RunRecord record) {
    // Pausar el SSE de este run mientras el detalle lo gestiona directamente.
    // No cerramos la conexión global: el ApiClient sigue vivo. Si RunDetail
    // se cierra y el run sigue activo, _openStreams lo recuperará al volver.
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            RunDetailScreen(connection: widget.connection, record: record),
      ),
    ).then((_) {
      if (mounted) {
        setState(() {});
        _refreshStatuses(); // sincronizar + reabrir SSE si procede
      }
    });
  }

  /// Elimina una ejecución del historial local (swipe). El run ya no vive en
  /// el servidor; esto solo limpia la lista del móvil.
  Future<void> _deleteRun(RunRecord record) async {
    final ownerKey = _runOwnerKey(record.profile, record.runId);
    _statusOverrides.remove(ownerKey);
    _streamedRunIds.remove(ownerKey);
    await _registry?.remove(record.runId, profile: record.profile);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(Strings.of(context).runsDeleted)));
  }

  /// Vacía toda la lista local de ejecuciones (con confirmación).
  Future<void> _clearAll() async {
    final registry = _registry;
    if (registry == null || registry.records.isEmpty) return;
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final count = registry.records.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(s.runsClearTitle),
        content: Text(s.runsClearConfirm(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.runsClear, style: TextStyle(color: colors.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _statusOverrides.clear();
    _streamedRunIds.clear();
    await registry.clear();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(s.runsCleared)));
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final registry = _registry;

    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          'EJECUCIONES',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            letterSpacing: 1.5,
            color: colors.accentHover,
          ),
        ),
        actions: [
          if (registry != null && registry.records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              tooltip: s.runsClear,
              onPressed: _clearAll,
            ),
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: s.runsRefreshStates,
              onPressed: _refreshStatuses,
            ),
        ],
      ),
      floatingActionButton: widget.connection.readOnly
          ? null
          : FloatingActionButton(
              onPressed: _newRun,
              tooltip: s.runsNewRun,
              child: const Icon(Icons.add),
            ),
      body: registry == null
          ? const Center(child: TuiLoader())
          : _buildWithActiveIds(registry, colors, s),
    );
  }

  /// Envuelve el cuerpo en un ValueListenableBuilder para que el dot de "chat
  /// activo" se actualice en tiempo real sin pull-to-refresh.
  Widget _buildWithActiveIds(
    RunRegistry registry,
    HermesThemeColors colors,
    Strings s,
  ) {
    final activeChats = _activeChats;
    if (activeChats == null) {
      return _buildBody(registry, colors, s, null);
    }
    return ValueListenableBuilder<Set<String>>(
      valueListenable: activeChats.activeIds,
      builder: (context0, activeSessionIds, child0) =>
          _buildBody(registry, colors, s, activeChats),
    );
  }

  Widget _buildBody(
    RunRegistry registry,
    HermesThemeColors colors,
    Strings s,
    ActiveChatService? activeChats,
  ) {
    final records = registry.records;

    if (records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.rocket_launch_outlined,
              size: 40,
              color: colors.textDisabled,
            ),
            const SizedBox(height: 14),
            Text(
              s.runsEmpty,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              s.runsEmptySub,
              style: TextStyle(fontSize: 11, color: colors.textDisabled),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: colors.accent,
      onRefresh: _refreshStatuses,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 80),
        itemCount: records.length,
        itemBuilder: (_, i) {
          final r = records[i];
          final ownerKey = _runOwnerKey(r.profile, r.runId);
          // El status efectivo puede estar sobreescrito en memoria (message.delta).
          final effectiveStatus = _statusOverrides[ownerKey] ?? r.lastStatus;
          final chatLive =
              r.sessionId != null &&
              (activeChats?.isActive(widget.connection.id, r.sessionId!) ??
                  false);
          return Dismissible(
            key: ValueKey(ownerKey),
            direction: DismissDirection.endToStart,
            onDismissed: (_) => _deleteRun(r),
            background: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.centerRight,
              decoration: BoxDecoration(
                color: colors.error.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.runsDelete,
                    style: TextStyle(
                      color: colors.error,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.delete_outline, color: colors.error, size: 18),
                ],
              ),
            ),
            child: _RunCard(
              record: r,
              effectiveStatus: effectiveStatus,
              chatLive: chatLive,
              liveStream: _streamedRunIds.contains(ownerKey),
              onTap: () => _openDetail(r),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _RunCard extends StatelessWidget {
  final RunRecord record;

  /// Status efectivo: puede diferir de record.lastStatus si hay un override
  /// en memoria por message.delta (ej. queued → running sin persistir).
  final String effectiveStatus;

  /// Hay un stream SSE activo para este run en TaskCenterScreen.
  final bool liveStream;

  /// Hay un stream de chat activo para la sesión de este run.
  final bool chatLive;

  final VoidCallback onTap;

  const _RunCard({
    required this.record,
    required this.effectiveStatus,
    required this.liveStream,
    required this.chatLive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final isTerminal = const {
      'completed',
      'failed',
      'cancelled',
      'expired',
    }.contains(effectiveStatus);
    final live = !isTerminal;
    final waiting = effectiveStatus == 'waiting_for_approval';

    return AccentCard(
      margin: const EdgeInsets.only(bottom: 7),
      accent: waiting
          ? colors.warning
          : live
          ? colors.accent.withValues(alpha: 0.6)
          : null,
      background: colors.surface,
      borderColor: colors.divider,
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  HermesIconTile(
                    waiting
                        ? Icons.pan_tool_outlined
                        : effectiveStatus == 'failed'
                        ? Icons.error_outline
                        : Icons.rocket_launch_outlined,
                    size: 34,
                    active: live,
                  ),
                  // Dot ámbar: SSE activo para este run en esta pantalla.
                  if (liveStream)
                    Positioned(
                      right: -3,
                      bottom: -3,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors.accent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.background,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  // Dot blanco/primario: chat con streaming activo para esta sesión.
                  if (chatLive && !liveStream)
                    Positioned(
                      right: -3,
                      top: -3,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors.success,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.background,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.prompt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          relativeTime(record.createdAt),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: colors.textSecondary,
                          ),
                        ),
                        if (record.progressLabel != null && live) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              record.progressLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: colors.accentHover.withValues(
                                  alpha: 0.8,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              HermesPill(
                color: runStatusColor(effectiveStatus, colors),
                label: runStatusLabel(effectiveStatus, s),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
