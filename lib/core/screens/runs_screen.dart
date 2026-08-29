// Ejecuciones — /v1/runs del Gateway con aprobaciones en vivo.
//
// Contrato verificado contra api_server.py del upstream y el servidor vivo:
//   POST /v1/runs                    → 202 {run_id, status: started}
//   GET  /v1/runs/{id}               → estado pollable (404 si ya se barrió)
//   GET  /v1/runs/{id}/events        → SSE: message.delta, tool.started/
//                                      completed, approval.request,
//                                      approval.responded, run.completed/
//                                      failed/cancelled
//   POST /v1/runs/{id}/approval      → {choice: once|session|always|deny}
//   POST /v1/runs/{id}/stop          → interrumpe
//
// Limitación honesta: el gateway NO expone listado de runs (405) y los
// estados viven en memoria del servidor — aquí solo se listan las
// ejecuciones lanzadas desde esta app (RunRegistry local).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../companion/models/companion_presence_level.dart';
import '../services/notifications/background_listener.dart';
import '../services/notifications/notification_service.dart';
import '../services/approval_activity.dart';
import '../services/approval_policy.dart';
import '../services/bridge_client.dart';
import '../services/capability_payload_sanitizer.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../services/run_registry.dart';
import '../services/run_template_store.dart';
import '../theme/app_theme.dart';
import '../utils/enum_labels.dart';
import '../widgets/hermes_spark_mascot.dart';
import '../utils/relative_time.dart';
import '../widgets/accent_card.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import '../widgets/run_template_composer.dart';
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';

Color commandRiskColor(CommandRisk risk, HermesThemeColors colors) =>
    switch (risk) {
      CommandRisk.low => colors.textSecondary,
      CommandRisk.medium => colors.warning,
      CommandRisk.high => colors.error,
    };

String runStatusLabel(String status, Strings s) => switch (status) {
  'queued' => s.runsStatusQueued,
  'running' => s.runsStatusRunning,
  'waiting_for_approval' => s.runsStatusWaiting,
  'stopping' => s.runsStatusStopping,
  'completed' => s.runsStatusCompleted,
  'failed' => s.runsStatusFailed,
  'cancelled' => s.runsStatusCancelled,
  'expired' => s.runsStatusExpired,
  _ => status,
};

Color runStatusColor(String status, HermesThemeColors colors) =>
    switch (status) {
      'queued' || 'running' || 'stopping' => colors.accent,
      'waiting_for_approval' => colors.warning,
      'completed' => colors.success,
      'failed' => colors.error,
      'cancelled' || 'expired' => colors.textDisabled,
      _ => colors.textSecondary,
    };

// ─────────────────────────────────────────────────────────────────────────────
// Pestaña de ejecuciones (embebida en Actividad)
// ─────────────────────────────────────────────────────────────────────────────

class RunsTab extends StatefulWidget {
  final SavedConnection connection;
  const RunsTab({required this.connection, super.key});

  @override
  State<RunsTab> createState() => _RunsTabState();
}

class _RunsTabState extends State<RunsTab> with AutomaticKeepAliveClientMixin {
  late final ApiClient _client;
  RunRegistry? _registry;
  RunTemplateStore? _templateStore;
  bool _refreshing = false;

  @override
  bool get wantKeepAlive => true;

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
    _client.close();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final registry = await RunRegistry.load(prefs, widget.connection.id);
    final templateStore = await RunTemplateStore.load(prefs);
    if (!mounted) return;
    setState(() {
      _registry = registry;
      _templateStore = templateStore;
    });
    _refreshStatuses();
  }

  /// Refresca el estado de los runs no terminales contra el servidor.
  Future<void> _refreshStatuses() async {
    final registry = _registry;
    if (registry == null || _refreshing) return;
    setState(() => _refreshing = true);
    for (final r in registry.records.where((r) => !r.isTerminal)) {
      try {
        final status = await _client.getRun(r.runId);
        await registry.update(
          r.runId,
          lastStatus: status['status'] as String?,
          output: status['output'] as String?,
          error: status['error'] as String?,
        );
      } catch (e) {
        if (e.toString().contains('404')) {
          // El gateway ya no conserva este run (se barre tras completar o
          // al reiniciar): estado final desconocido.
          await registry.update(r.runId, lastStatus: 'expired');
        }
      }
    }
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _newRun() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    final store = _templateStore;
    if (store == null) return;
    // Composer con plantillas (predefinidas + propias) en vez del campo en
    // blanco. Devuelve el prompt a lanzar, o null si se cancela.
    final prompt = await showRunComposer(context, store);
    if (prompt == null || prompt.isEmpty || !mounted) return;

    try {
      await _launch(prompt);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.runsLaunchError(e.toString()))));
    }
  }

  /// Relanza una ejecución previa con el mismo prompt (un toque, sin reescribir).
  Future<void> _repeatRun(RunRecord record) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    try {
      await _launch(record.prompt);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.runsLaunchError(e.toString()))));
    }
  }

  /// Lanza una ejecución. REMOTO: `/v1/runs` + detalle en vivo (SSE), como
  /// siempre. LOCAL: el agente NO expone `/v1/runs` (daba 405); ejecutamos por el
  /// Mobile Bridge (`/bridge/chat`), igual que el chat local, y mostramos el
  /// resultado. El camino remoto queda intacto.
  Future<void> _launch(String prompt) async {
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
    _openDetail(record);
  }

  /// Ejecución en instancia LOCAL vía Mobile Bridge (oneshot `hermes -z`). No hay
  /// SSE en vivo: el bridge devuelve la respuesta final, que registramos y
  /// mostramos. Reutiliza el MISMO mecanismo que el chat local (ya probado).
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
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            RunDetailScreen(connection: widget.connection, record: record),
      ),
    ).then((_) {
      if (mounted) {
        setState(() {});
        _refreshStatuses();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final registry = _registry;
    if (registry == null) {
      return const Center(child: TuiLoader());
    }
    final records = registry.records;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        onPressed: _newRun,
        tooltip: s.runsNewRun,
        child: const Icon(Icons.add),
      ),
      body: _buildList(colors, records, s),
    );
  }

  Widget _buildList(
    HermesThemeColors colors,
    List<RunRecord> records,
    Strings s,
  ) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s.runsListNote,
                  style: TextStyle(fontSize: 10, color: colors.textDisabled),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: s.runsRefreshStates,
                onPressed: _refreshing ? null : _refreshStatuses,
              ),
            ],
          ),
        ),
        Expanded(
          child: records.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Builder(
                        builder: (context) {
                          final companion = context
                              .findAncestorStateOfType<HermesAppState>()
                              ?.companion;
                          if (companion == null) {
                            return const SizedBox.shrink();
                          }
                          return AnimatedBuilder(
                            animation: companion,
                            builder: (context, _) {
                              if (!companion.isInitialized ||
                                  !companion.enabled ||
                                  !companion
                                      .presenceLevel
                                      .showsStatusPresence) {
                                return const SizedBox.shrink();
                              }
                              return const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  HermesSparkMascot(
                                    mood: HermesSparkMood.idle,
                                    size: 48,
                                  ),
                                  SizedBox(height: 12),
                                ],
                              );
                            },
                          );
                        },
                      ),
                      Text(
                        s.runsEmpty,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        s.runsEmptySub,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textDisabled,
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  color: colors.accent,
                  onRefresh: _refreshStatuses,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
                    itemCount: records.length,
                    itemBuilder: (_, i) => _RunTile(
                      record: records[i],
                      onTap: _openDetail,
                      onRepeat: () => _repeatRun(records[i]),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _RunTile extends StatelessWidget {
  final RunRecord record;
  final void Function(RunRecord) onTap;
  final VoidCallback? onRepeat;

  const _RunTile({required this.record, required this.onTap, this.onRepeat});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final live = !record.isTerminal;
    final waiting = record.lastStatus == 'waiting_for_approval';
    return AccentCard(
      margin: const EdgeInsets.only(bottom: 6),
      accent: waiting
          ? colors.warning
          : live
          ? colors.accent.withValues(alpha: 0.7)
          : null,
      background: colors.surface,
      borderColor: colors.divider,
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onTap(record),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              HermesIconTile(
                waiting
                    ? Icons.pan_tool_outlined
                    : record.lastStatus == 'failed'
                    ? Icons.error_outline
                    : Icons.rocket_launch_outlined,
                size: 34,
                active: live,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.prompt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      relativeTime(record.createdAt),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              HermesPill(
                color: runStatusColor(record.lastStatus, colors),
                label: runStatusLabel(record.lastStatus, s),
              ),
              if (onRepeat != null)
                IconButton(
                  icon: const Icon(Icons.replay_rounded, size: 18),
                  color: colors.textSecondary,
                  tooltip: s.runsRepeat,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: onRepeat,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detalle de ejecución — SSE en vivo + aprobaciones
// ─────────────────────────────────────────────────────────────────────────────

class RunDetailScreen extends StatefulWidget {
  final SavedConnection connection;
  final RunRecord record;
  final ApiClient? client;

  const RunDetailScreen({
    required this.connection,
    required this.record,
    this.client,
    super.key,
  });

  @override
  State<RunDetailScreen> createState() => _RunDetailScreenState();
}

/// Evento del timeline ya digerido para pintar.
class _RunEvent {
  final String kind; // tool / approval / lifecycle
  final String title;
  final String? detail;
  const _RunEvent(this.kind, this.title, {this.detail});
}

class _RunDetailScreenState extends State<RunDetailScreen> {
  late final ApiClient _client;
  late String _status;
  String _output = '';
  String? _error;
  Map<String, dynamic>? _usage;

  /// Aprobación pendiente (último approval.request sin responder).
  Map<String, dynamic>? _pendingApproval;
  bool _resolvingApproval = false;

  final List<_RunEvent> _events = [];
  bool _streamClosed = false;
  RunRegistry? _registry;
  ApprovalActivityLog? _activityLog;

  ApprovalPolicyService? get _policy =>
      context.findAncestorStateOfType<HermesAppState>()?.approvalPolicy;

  NotificationService? get _notifications =>
      context.findAncestorStateOfType<HermesAppState>()?.notifications;

  @override
  void initState() {
    super.initState();
    _client =
        widget.client ??
        ApiClient(
          baseUrl: widget.connection.baseUrl,
          apiKey: widget.connection.apiKey,
        );
    _status = widget.record.lastStatus;
    _output = widget.record.output ?? '';
    _error = widget.record.error;
    _loadRegistry();
    if (!widget.record.isTerminal) {
      _listen();
      _registerBackgroundWatch();
    }
    _pollStatus();
  }

  /// Si la escucha en 2º plano está activa, registra esta run para que el
  /// servicio la vigile aunque se cierre la app (notifica fin/aprobación).
  Future<void> _registerBackgroundWatch() async {
    if (!await BackgroundListener.isEnabled()) return;
    await BackgroundWatch.add(
      SavedRunWatch(
        connId: widget.connection.id,
        base: widget.connection.baseUrl,
        runId: widget.record.runId,
        prompt: widget.record.prompt,
      ),
    );
  }

  Future<void> _loadRegistry() async {
    final prefs = await SharedPreferences.getInstance();
    _registry = await RunRegistry.load(prefs, widget.connection.id);
    _activityLog = ApprovalActivityLog(prefs);
  }

  @override
  void dispose() {
    // Cierra el socket SSE si sigue abierto.
    _client.close();
    super.dispose();
  }

  Future<void> _pollStatus() async {
    try {
      final status = await _client.getRun(widget.record.runId);
      if (!mounted) return;
      setState(() {
        _status = (status['status'] as String?) ?? _status;
        final out = status['output'] as String?;
        if (out != null && out.isNotEmpty) _output = out;
        _error = status['error'] as String? ?? _error;
        _usage = status['usage'] as Map<String, dynamic>? ?? _usage;
      });
      _persist();
    } catch (e) {
      if (!mounted) return;
      if (e.toString().contains('404') && !widget.record.isTerminal) {
        // Run barrido por el gateway: si ya teníamos un estado terminal lo
        // conservamos; si no, queda como expirada.
        if (!const {'completed', 'failed', 'cancelled'}.contains(_status)) {
          setState(() {
            _status = 'expired';
            _pendingApproval = null;
          });
          _persist();
        }
      }
    }
  }

  void _persist() {
    _registry?.update(
      widget.record.runId,
      lastStatus: _status,
      output: _output.isEmpty ? null : _output,
      error: _error,
    );
  }

  void _listen() {
    _client.streamRunEvents(
      widget.record.runId,
      onEvent: (event) {
        if (!mounted) return;
        final type = (event['event'] ?? '').toString();
        final evS = Strings.of(context);
        setState(() => _applyEvent(event, evS));
        _persist();
        // Tras registrar una solicitud de aprobación, la política decide:
        // YOLO/regla guardada → auto-aprobar; read-only → bloquear; si no, pedir.
        if (type == 'approval.request') {
          _applyApprovalPolicy(event);
          // Notifica solo si la aprobación sigue requiriendo acción del usuario
          // (si la política la auto-resolvió, _pendingApproval ya es null).
          Future.microtask(() {
            if (mounted && _pendingApproval != null) {
              _notifications?.approvalPending(
                tool:
                    (event['command'] ??
                            event['tool'] ??
                            event['description'] ??
                            Strings.of(context).runsApprovalSummary)
                        .toString(),
                instance: widget.connection.label,
                connId: widget.connection.id,
                sessionId: widget.record.sessionId,
                sessionTitle: widget.record.prompt,
                runId: widget.record.runId,
                base: widget.connection.baseUrl,
              );
            }
          });
        } else if (type == 'run.completed' ||
            type == 'run.failed' ||
            type == 'run.cancelled') {
          // Ya la gestionamos en primer plano: que el servicio deje de vigilarla
          // (evita doble aviso; además los ids de notificación se reemplazan).
          BackgroundWatch.remove(widget.record.runId);
          if (type != 'run.cancelled') {
            _notifications?.cancelApproval();
            _notifications?.runFinished(
              title: widget.record.prompt.trim().isEmpty
                  ? Strings.of(context).runsAgentTask
                  : widget.record.prompt.trim(),
              ok: type == 'run.completed',
              connId: widget.connection.id,
              sessionId: widget.record.sessionId,
              runId: widget.record.runId,
            );
          }
        }
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _streamClosed = true);
        _pollStatus();
      },
      onError: (err) {
        if (!mounted) return;
        setState(() => _streamClosed = true);
        // 404 = run ya barrido; el poll decide el estado final.
        _pollStatus();
      },
    );
  }

  void _applyEvent(Map<String, dynamic> event, Strings s) {
    final type = (event['event'] ?? '').toString();
    switch (type) {
      case 'message.delta':
        _output += (event['delta'] ?? '').toString();
        if (_status == 'queued') _status = 'running';
      case 'tool.started':
        final tool = (event['tool'] ?? '').toString();
        final preview = (event['preview'] ?? '').toString();
        _events.add(
          _RunEvent('tool', tool, detail: preview.isEmpty ? null : preview),
        );
        _status = 'running';
      case 'tool.completed':
        final tool = (event['tool'] ?? '').toString();
        final duration = event['duration'];
        final failed = event['error'] == true;
        _events.add(
          _RunEvent(
            'tool',
            '$tool ${failed ? s.runsToolFailed : s.runsToolCompleted}'
                '${duration is num ? ' · ${duration.toStringAsFixed(1)}s' : ''}',
          ),
        );
      case 'approval.request':
        // Un frame tardío no puede resucitar una aprobación de un run que el
        // poll ya confirmó como terminal o barrido.
        if (const {
          'completed',
          'failed',
          'cancelled',
          'expired',
        }.contains(_status)) {
          return;
        }
        _pendingApproval = event;
        _status = 'waiting_for_approval';
        _events.add(
          _RunEvent(
            'approval',
            s.runsApprovalSummary,
            detail: (event['command'] ?? event['description'] ?? '').toString(),
          ),
        );
      case 'approval.responded':
        _pendingApproval = null;
        _status = 'running';
        _events.add(
          _RunEvent(
            'approval',
            s.runsApprovalResolved(event['choice']?.toString() ?? ''),
          ),
        );
      case 'run.completed':
        _status = 'completed';
        final out = (event['output'] ?? '').toString();
        if (out.isNotEmpty) _output = out;
        _usage = event['usage'] as Map<String, dynamic>?;
        _pendingApproval = null;
      case 'run.failed':
        _status = 'failed';
        _error = (event['error'] ?? '').toString();
        _pendingApproval = null;
      case 'run.cancelled':
        _status = 'cancelled';
        _pendingApproval = null;
    }
  }

  /// Evalúa la política al llegar una `approval.request`: YOLO/regla guardada
  /// → auto-aprobar; modo solo lectura → bloquear; en otro caso, pedir (la card
  /// se muestra normal). Registra el evento en la actividad local.
  void _applyApprovalPolicy(Map<String, dynamic> approval) {
    final policy = _policy;
    final command = approval['command']?.toString();
    final patternKey = approval['pattern_key']?.toString();
    final connId = widget.connection.id;
    _activityLog?.add(
      connId,
      kind: 'requested',
      summary:
          approval['description']?.toString() ??
          Strings.of(context).runsApprovalRequested,
      command: command,
      sessionId: widget.record.sessionId,
    );
    if (policy == null) return;
    final decision = policy.evaluate(
      mode: policy.effectiveMode(widget.record.sessionId),
      risk: assessCommandRisk(command),
      readOnlyInstance: widget.connection.readOnly,
      hasSavedAlways: policy.hasSavedAlways(
        connId,
        patternKey: patternKey,
        command: command,
      ),
    );
    switch (decision.kind) {
      case ApprovalDecisionKind.autoApprove:
        _autoResolve(decision.scope!, decision.reason);
      case ApprovalDecisionKind.blocked:
        _activityLog?.add(
          connId,
          kind: 'blocked',
          summary: decision.reason,
          command: command,
          sessionId: widget.record.sessionId,
        );
      case ApprovalDecisionKind.ask:
        break; // mostrar la ApprovalCard para que el usuario decida
    }
  }

  /// Auto-resuelve una aprobación sin pedir (modo YOLO o regla guardada).
  Future<void> _autoResolve(ApprovalScope scope, String reason) async {
    final s = Strings.of(context);
    final command = (_pendingApproval?['command'] ?? '').toString();
    setState(() => _resolvingApproval = true);
    try {
      await _client.resolveRunApproval(widget.record.runId, scope.wire);
      if (!mounted) return;
      setState(() {
        _pendingApproval = null;
        _status = 'running';
      });
      _events.add(
        _RunEvent(
          'approval',
          s.runsAutoApprovedScope(scope.name),
          detail: reason,
        ),
      );
      _activityLog?.add(
        widget.connection.id,
        kind: 'auto_approved',
        summary: reason,
        command: command,
        sessionId: widget.record.sessionId,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.runsAutoApproved(reason))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.runsAutoApproveError(e.toString()))),
      );
      _pollStatus();
    } finally {
      if (mounted) setState(() => _resolvingApproval = false);
    }
  }

  Future<void> _resolveApproval(String choice) async {
    final s = Strings.of(context);
    final policy = _policy;
    final mode = policy?.effectiveMode(widget.record.sessionId);
    // Solo lectura (de instancia O de modo) bloquea cualquier aprobación;
    // denegar siempre se permite.
    if (choice != 'deny' &&
        (widget.connection.readOnly || mode == ApprovalMode.readOnly)) {
      showReadOnlyNotice(context);
      return;
    }

    final approval = _pendingApproval;
    final command = (approval?['command'] ?? '').toString();
    final risk = assessCommandRisk(command);

    // App Lock antes de aprobar acciones sensibles (si la política lo exige).
    // "deny" nunca pide verificación.
    if (choice != 'deny' && (policy?.requireLock ?? true)) {
      final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
      if (lock != null && lock.enabled) {
        final reason = choice == 'always'
            ? s.runsAllowAlwaysThis
            : risk == CommandRisk.high
            ? s.runsApproveHighRisk
            : s.runsApproveAction;
        final verified = await LockScreen.verify(context, lock, reason: reason);
        if (!verified) return;
      }
    }
    if (!mounted) return;

    setState(() => _resolvingApproval = true);
    try {
      await _client.resolveRunApproval(widget.record.runId, choice);
      if (!mounted) return;
      setState(() {
        _pendingApproval = null;
        if (choice != 'deny') _status = 'running';
      });
      // Si es "always", guarda la regla local para futuras auto-aprobaciones.
      if (choice == 'always' && (policy?.allowAlways ?? true)) {
        final patternKey = approval?['pattern_key']?.toString();
        await policy?.saveRule(
          ApprovalRule(
            id: patternKey ?? command,
            description: (approval?['description'] ?? command).toString(),
            instanceId: widget.connection.id,
            scope: ApprovalScope.always,
            risk: risk,
            createdAt: DateTime.now(),
            command: command.isEmpty ? null : command,
            patternKey: patternKey,
          ),
        );
      }
      _activityLog?.add(
        widget.connection.id,
        kind: switch (choice) {
          'once' => 'allowed_once',
          'session' => 'allowed_session',
          'always' => 'allowed_always',
          _ => 'denied',
        },
        summary: switch (choice) {
          'once' => s.runsAllowedOnce,
          'session' => s.runsAllowedSession,
          'always' => s.runsAllowedAlways,
          _ => s.runsDenied,
        },
        command: command,
        sessionId: widget.record.sessionId,
      );
      final msg = switch (choice) {
        'once' => s.runsApprovedOnce,
        'session' => s.runsApprovedSession,
        'always' => s.runsApprovedAlways,
        'deny' => s.runsDeniedAction,
        _ => s.runsApprovalSent,
      };
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.runsResolveError(e.toString()))));
      _pollStatus();
    } finally {
      if (mounted) setState(() => _resolvingApproval = false);
    }
  }

  Future<void> _confirmAlways() async {
    final colors = Theme.of(context).hermes;
    final command = (_pendingApproval?['command'] ?? '').toString();
    final risk = assessCommandRisk(command);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final ls = Strings.of(ctx);
        return AlertDialog(
          title: Text(ls.runsAllowAlwaysQ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ls.runsAllowAlwaysBody),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(command, style: const TextStyle(fontSize: 12)),
              ),
              if (risk == CommandRisk.high) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.warning_amber, size: 16, color: colors.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        ls.runsHighRiskWarn,
                        style: TextStyle(fontSize: 12, color: colors.error),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ls.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                ls.runsAllowAlways,
                style: TextStyle(
                  color: risk == CommandRisk.high
                      ? colors.error
                      : colors.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
    if (ok == true) _resolveApproval('always');
  }

  Future<void> _stop() async {
    final s = Strings.of(context);
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    try {
      await _client.stopRun(widget.record.runId);
      if (!mounted) return;
      setState(() => _status = 'stopping');
      _persist();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.runsStopError(e.toString()))));
    }
  }

  void _copyOutput() {
    final s = Strings.of(context);
    Clipboard.setData(ClipboardData(text: _output));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(s.runsReplyCopied)));
  }

  bool get _isLive => const {
    'queued',
    'running',
    'waiting_for_approval',
    'stopping',
  }.contains(_status);

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          s.runsDetailTitle,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            letterSpacing: 1.5,
            color: colors.accentHover,
          ),
        ),
        actions: [
          if (_isLive)
            IconButton(
              icon: Icon(Icons.stop_circle_outlined, color: colors.error),
              tooltip: s.runsStop,
              onPressed: _stop,
            ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: s.runsRefreshState,
            onPressed: _pollStatus,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          // Cabecera de estado
          AccentCard(
            accent: runStatusColor(_status, colors),
            background: colors.surface,
            borderColor: colors.divider,
            padding: const EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.record.prompt,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    HermesPill(
                      color: runStatusColor(_status, colors),
                      label: runStatusLabel(_status, s),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  widget.record.sessionId != null
                      ? s.runsInstanceSessionInfo(
                          widget.connection.label,
                          widget.record.sessionId!,
                        )
                      : s.runsInstanceInfo(widget.connection.label),
                  style: TextStyle(fontSize: 10, color: colors.textSecondary),
                ),
                const SizedBox(height: 3),
                InkWell(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: widget.record.runId));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(s.runsRunIdCopied)));
                  },
                  child: Text(
                    '${widget.record.runId} · '
                    '${relativeTime(widget.record.createdAt)}',
                    style: TextStyle(fontSize: 10, color: colors.textDisabled),
                  ),
                ),
              ],
            ),
          ),

          if (_status == 'expired') ...[
            const SizedBox(height: 10),
            HermesInfoBanner(s.runsExpired, icon: Icons.history_toggle_off),
          ],

          // Tarjeta de aprobación pendiente — lo más importante de la vista.
          if (_pendingApproval != null) ...[
            const SizedBox(height: 14),
            RunApprovalDecisionBlock(
              approval: _pendingApproval!,
              busy: _resolvingApproval,
              readOnly:
                  widget.connection.readOnly ||
                  _policy?.effectiveMode(widget.record.sessionId) ==
                      ApprovalMode.readOnly,
              allowAlways: _policy?.allowAlways ?? true,
              onChoice: _resolveApproval,
              onAlways: _confirmAlways,
            ),
          ],

          if (_events.isNotEmpty) ...[
            const SizedBox(height: 16),
            HermesSectionHeader(s.runsActivitySection),
            const SizedBox(height: 4),
            for (final e in _events) _EventLine(event: e),
          ],

          if (_output.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            HermesSectionHeader(
              s.runsReplySection,
              trailing: Semantics(
                container: true,
                button: true,
                enabled: true,
                label: s.commonCopy,
                onTap: _copyOutput,
                child: ExcludeSemantics(
                  child: IconButton(
                    key: const ValueKey('runs-copy-reply'),
                    onPressed: _copyOutput,
                    tooltip: s.commonCopy,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    padding: EdgeInsets.zero,
                    focusColor: colors.textSecondary.withValues(alpha: 0.12),
                    icon: Icon(
                      Icons.content_copy_outlined,
                      size: 14,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            HermesCard(
              padding: const EdgeInsets.all(12),
              child: Text(
                _output.trim(),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: colors.textPrimary.withValues(alpha: 0.9),
                ),
              ),
            ),
          ],

          if (_error != null && _error!.isNotEmpty) ...[
            const SizedBox(height: 14),
            HermesInfoBanner(
              s.runsError(_error!),
              icon: Icons.error_outline,
              tone: colors.error,
            ),
          ],

          if (_usage != null) ...[
            const SizedBox(height: 12),
            Text(
              'tokens: ${_usage!['total_tokens'] ?? '—'} '
              '(in ${_usage!['input_tokens'] ?? '—'} / '
              'out ${_usage!['output_tokens'] ?? '—'})',
              style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
            ),
          ],

          if (_isLive && !_streamClosed) ...[
            const SizedBox(height: 18),
            Center(child: TuiLoader(label: s.runsAgentBusy)),
          ],
        ],
      ),
    );
  }
}

class _EventLine extends StatelessWidget {
  final _RunEvent event;
  const _EventLine({required this.event});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final isApproval = event.kind == 'approval';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(
              isApproval ? Icons.pan_tool_outlined : Icons.terminal,
              size: 13,
              color: isApproval ? colors.warning : colors.textDisabled,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
                ),
                if (event.detail != null)
                  Text(
                    event.detail!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colors.textDisabled,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Adaptador de Runs al bloque editorial compartido de decisiones.
///
/// [approval] conserva el payload crudo para riesgo, copia y callbacks. Solo la
/// proyección que se pinta en pantalla se sanea y acota.
class RunApprovalDecisionBlock extends StatefulWidget {
  final Map<String, dynamic> approval;
  final bool busy;
  final bool readOnly;
  final bool allowAlways;
  final void Function(String choice) onChoice;
  final VoidCallback onAlways;

  const RunApprovalDecisionBlock({
    required this.approval,
    required this.busy,
    required this.readOnly,
    required this.allowAlways,
    required this.onChoice,
    required this.onAlways,
    super.key,
  });

  @override
  State<RunApprovalDecisionBlock> createState() =>
      _RunApprovalDecisionBlockState();
}

class _RunApprovalDecisionBlockState extends State<RunApprovalDecisionBlock> {
  static const _sanitizer = CapabilityPayloadSanitizer();
  bool _expanded = false;

  bool get _serverAllowsAlways {
    final explicit = widget.approval['allow_always'];
    if (explicit is bool) return explicit;

    final choices =
        widget.approval['allowed_choices'] ?? widget.approval['choices'];
    if (choices is Iterable) {
      return choices.any(
        (choice) => choice.toString().trim().toLowerCase() == 'always',
      );
    }
    return true;
  }

  void _copyCommand(BuildContext context, String command) {
    Clipboard.setData(ClipboardData(text: command));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).runsCommandCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final rawCommand = (widget.approval['command'] ?? '').toString();
    final description = (widget.approval['description'] ?? '')
        .toString()
        .trim();
    final displayCommand = _sanitizer.commandOutput(rawCommand);
    final risk = assessCommandRisk(rawCommand);
    final riskColor = commandRiskColor(risk, colors);
    final showAlways = widget.allowAlways && _serverAllowsAlways;
    final detail = displayCommand == null
        ? null
        : Semantics(
            button: true,
            enabled: !widget.busy,
            label: s.commonCopy,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('run-approval-command-detail'),
                onTap: widget.busy
                    ? null
                    : () => _copyCommand(context, rawCommand),
                onLongPress: widget.busy
                    ? null
                    : () => _copyCommand(context, rawCommand),
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            displayCommand,
                            key: const ValueKey('run-approval-command-display'),
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.content_copy_outlined,
                          size: 16,
                          color: colors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );

    return HermesDecisionBlock(
      semanticLabel: s.cevPermissionHeadline,
      title: s.cevPermissionHeadline,
      summary: description.isEmpty ? null : description,
      leading: Icon(
        widget.readOnly ? Icons.lock_outline_rounded : Icons.shield_outlined,
        size: 20,
        color: widget.readOnly ? colors.textSecondary : riskColor,
      ),
      status: rawCommand.trim().isNotEmpty || widget.readOnly
          ? Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (rawCommand.trim().isNotEmpty)
                  HermesPill(
                    color: riskColor,
                    label: commandRiskLabel(s, risk),
                  ),
                if (widget.readOnly)
                  HermesPill(
                    color: colors.textSecondary,
                    label: s.statusReadOnly,
                  ),
              ],
            )
          : null,
      detail: detail,
      expanded: _expanded,
      disclosureLabel: detail == null
          ? null
          : _expanded
          ? s.chaErrHideDetails
          : s.chaErrViewDetails,
      onExpansionChanged: detail == null
          ? null
          : (expanded) => setState(() => _expanded = expanded),
      enabled: !widget.busy,
      actions: [
        TextButton.icon(
          onPressed: widget.busy ? null : () => widget.onChoice('deny'),
          icon: const Icon(Icons.close_rounded, size: 18),
          label: Text(s.runsDeny),
        ),
        if (!widget.readOnly) ...[
          TextButton.icon(
            onPressed: widget.busy ? null : () => widget.onChoice('session'),
            icon: const Icon(Icons.repeat_rounded, size: 17),
            label: Text(s.runsApproveSession),
          ),
          if (showAlways)
            TextButton.icon(
              onPressed: widget.busy ? null : widget.onAlways,
              icon: const Icon(Icons.all_inclusive_rounded, size: 17),
              label: Text(s.runsAllowAlways),
            ),
          FilledButton.icon(
            onPressed: widget.busy ? null : () => widget.onChoice('once'),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: Text(s.runsApproveOnce),
          ),
        ],
      ],
    );
  }
}
