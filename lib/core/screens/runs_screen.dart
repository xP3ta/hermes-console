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
import '../services/notifications/background_listener.dart';
import '../services/notifications/notification_service.dart';
import '../services/approval_activity.dart';
import '../services/approval_policy.dart';
import '../services/capability_payload_sanitizer.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../services/run_registry.dart';
import '../design/hermes_design.dart' as d show HermesListRow;
import '../design/hermes_design.dart'
    show
        HermesListGroup,
        HermesSpace,
        HermesStatusText,
        HermesStatusTone,
        HermesTextBlock,
        HermesType;
import '../theme/app_theme.dart';
import '../utils/enum_labels.dart';
import '../widgets/hermes_notice.dart';
import '../utils/relative_time.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';

@visibleForTesting
bool runTerminalCancelsApproval(String eventType) =>
    const {'run.completed', 'run.failed', 'run.cancelled'}.contains(eventType);

@visibleForTesting
Future<bool> resolveRunApprovalWithLockFence({
  required String requestId,
  required String? Function() currentRequestId,
  required Future<bool> Function() verify,
  required Future<bool> Function() resolve,
}) async {
  final verified = await verify();
  if (!verified || currentRequestId() != requestId) return false;
  return resolve();
}

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
      'cancelled' || 'expired' => colors.textTertiary,
      _ => colors.textSecondary,
    };

/// Inline status tone of a run (spec 080: no boxed pills).
HermesStatusTone runStatusTone(String status) => switch (status) {
  'queued' || 'running' || 'stopping' => HermesStatusTone.active,
  'waiting_for_approval' => HermesStatusTone.warn,
  'completed' => HermesStatusTone.ok,
  'failed' => HermesStatusTone.error,
  _ => HermesStatusTone.neutral,
};

// ─────────────────────────────────────────────────────────────────────────────
// Detalle de ejecución — SSE en vivo + aprobaciones
// ─────────────────────────────────────────────────────────────────────────────

class RunDetailScreen extends StatefulWidget {
  final SavedConnection connection;
  final RunRecord record;
  final ApiClient? client;
  final String? initialApprovalId;
  final VoidCallback? onInitialApprovalReady;

  const RunDetailScreen({
    required this.connection,
    required this.record,
    this.client,
    this.initialApprovalId,
    this.onInitialApprovalReady,
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
  bool _initialApprovalReadyReported = false;

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
        profile: widget.record.profile,
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
      final status = await _client.getRun(
        widget.record.runId,
        profile: widget.record.profile,
      );
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
      profile: widget.record.profile,
      lastStatus: _status,
      output: _output.isEmpty ? null : _output,
      error: _error,
    );
  }

  void _listen() {
    _client.streamRunEvents(
      widget.record.runId,
      profile: widget.record.profile,
      onEvent: (event) {
        if (!mounted) return;
        final type = (event['event'] ?? '').toString();
        final evS = Strings.of(context);
        var accepted = false;
        setState(() => accepted = _applyEvent(event, evS));
        if (accepted &&
            type == 'approval.request' &&
            !_initialApprovalReadyReported &&
            widget.initialApprovalId != null) {
          _initialApprovalReadyReported = true;
          widget.onInitialApprovalReady?.call();
        }
        _persist();
        // Tras registrar una solicitud de aprobación, la política decide:
        // YOLO/regla guardada → auto-aprobar; read-only → bloquear; si no, pedir.
        if (type == 'approval.request' && accepted) {
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
                approvalId: (event['request_id'] ?? event['approval_id'])
                    ?.toString(),
                base: widget.connection.baseUrl,
                profile: widget.record.profile,
              );
            }
          });
        } else if (type == 'run.completed' ||
            type == 'run.failed' ||
            type == 'run.cancelled') {
          // Ya la gestionamos en primer plano: que el servicio deje de vigilarla
          // (evita doble aviso; además los ids de notificación se reemplazan).
          BackgroundWatch.remove(
            widget.record.runId,
            connId: widget.connection.id,
            profile: widget.record.profile,
          );
          if (runTerminalCancelsApproval(type)) {
            _notifications?.cancelApproval(
              connId: widget.connection.id,
              profile: widget.record.profile,
              runId: widget.record.runId,
              terminal: true,
            );
          }
          if (type != 'run.cancelled') {
            _notifications?.runFinished(
              title: widget.record.prompt.trim().isEmpty
                  ? Strings.of(context).runsAgentTask
                  : widget.record.prompt.trim(),
              ok: type == 'run.completed',
              connId: widget.connection.id,
              sessionId: widget.record.sessionId,
              runId: widget.record.runId,
              profile: widget.record.profile,
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

  bool _applyEvent(Map<String, dynamic> event, Strings s) {
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
          return false;
        }
        final requestId = (event['request_id'] ?? event['approval_id'])
            ?.toString()
            .trim();
        if (requestId == null || requestId.isEmpty) return false;
        final initialApprovalId = widget.initialApprovalId?.trim();
        if (!_initialApprovalReadyReported &&
            initialApprovalId != null &&
            initialApprovalId.isNotEmpty &&
            requestId != initialApprovalId) {
          return false;
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
        final respondedId = (event['request_id'] ?? event['approval_id'])
            ?.toString()
            .trim();
        final pendingId =
            (_pendingApproval?['request_id'] ??
                    _pendingApproval?['approval_id'])
                ?.toString()
                .trim();
        if (pendingId == null ||
            pendingId.isEmpty ||
            respondedId == null ||
            respondedId.isEmpty ||
            respondedId != pendingId) {
          return false;
        }
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
    return true;
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
    final requestId =
        (_pendingApproval?['request_id'] ?? _pendingApproval?['approval_id'])
            ?.toString()
            .trim();
    if (requestId == null || requestId.isEmpty) return;
    setState(() => _resolvingApproval = true);
    try {
      await _client.resolveRunApproval(
        widget.record.runId,
        scope.wire,
        requestId: requestId,
        profile: widget.record.profile,
      );
      await _notifications?.cancelApproval(
        connId: widget.connection.id,
        profile: widget.record.profile,
        runId: widget.record.runId,
        approvalId: requestId,
      );
      if (!mounted) return;
      final currentRequestId =
          (_pendingApproval?['request_id'] ?? _pendingApproval?['approval_id'])
              ?.toString()
              .trim();
      if (currentRequestId != requestId) return;
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
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.runsAutoApproved(reason))),
        kind: HermesNoticeKind.success,
      );
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.runsAutoApproveError(e.toString()))),
        kind: HermesNoticeKind.error,
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
    final requestId = (approval?['request_id'] ?? approval?['approval_id'])
        ?.toString()
        .trim();
    if (requestId == null || requestId.isEmpty) return;
    final command = (approval?['command'] ?? '').toString();
    final risk = assessCommandRisk(command);

    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    try {
      final resolved = await resolveRunApprovalWithLockFence(
        requestId: requestId,
        currentRequestId: () =>
            (_pendingApproval?['request_id'] ??
                    _pendingApproval?['approval_id'])
                ?.toString()
                .trim(),
        verify: () async {
          // App Lock antes de aprobar acciones sensibles (si la política lo exige).
          // "deny" nunca pide verificación.
          if (choice == 'deny' || !(policy?.requireLock ?? true)) return true;
          if (lock == null || !lock.enabled) return true;
          final reason = choice == 'always'
              ? s.runsAllowAlwaysThis
              : risk == CommandRisk.high
              ? s.runsApproveHighRisk
              : s.runsApproveAction;
          return LockScreen.verify(context, lock, reason: reason);
        },
        resolve: () async {
          if (!mounted) return false;
          setState(() => _resolvingApproval = true);
          await _client.resolveRunApproval(
            widget.record.runId,
            choice,
            requestId: requestId,
            profile: widget.record.profile,
          );
          return true;
        },
      );
      if (!resolved) return;
      await _notifications?.cancelApproval(
        connId: widget.connection.id,
        profile: widget.record.profile,
        runId: widget.record.runId,
        approvalId: requestId,
      );
      if (!mounted) return;
      final currentRequestId =
          (_pendingApproval?['request_id'] ?? _pendingApproval?['approval_id'])
              ?.toString()
              .trim();
      if (currentRequestId != requestId) return;
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
      HermesNotice.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.runsResolveError(e.toString()))),
        kind: HermesNoticeKind.error,
      );
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
      await _client.stopRun(
        widget.record.runId,
        profile: widget.record.profile,
      );
      if (!mounted) return;
      setState(() => _status = 'stopping');
      _persist();
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.runsStopError(e.toString()))),
        kind: HermesNoticeKind.error,
      );
    }
  }

  void _copyOutput() {
    final s = Strings.of(context);
    Clipboard.setData(ClipboardData(text: _output));
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(s.runsReplyCopied)),
      kind: HermesNoticeKind.success,
    );
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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
        key: const ValueKey('run-detail'),
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.pageH,
          HermesSpace.pageTop,
          HermesSpace.pageH,
          HermesSpace.pageBottom,
        ),
        children: [
          // Cabecera action-first (spec 080): título, estado inline, contexto.
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 4),
            child: Text(
              widget.record.prompt,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: HermesType.display.copyWith(
                fontSize: 19,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: HermesSpace.x1),
          HermesStatusText(
            key: const ValueKey('run-detail-status'),
            label: runStatusLabel(_status, s),
            tone: runStatusTone(_status),
            meta: relativeTime(widget.record.createdAt),
          ),
          const SizedBox(height: HermesSpace.x3),
          HermesListGroup(
            dividerIndent: HermesSpace.rowH,
            children: [
              d.HermesListRow(
                title: widget.connection.label,
                subtitle: widget.record.sessionId,
                showChevron: false,
              ),
              d.HermesListRow(
                key: const ValueKey('run-detail-id'),
                title: widget.record.runId,
                muted: true,
                trailing: Icon(
                  Icons.copy_rounded,
                  size: 18,
                  color: colors.textSecondary,
                ),
                semanticLabel: s.commonCopy,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: widget.record.runId));
                  HermesNotice.of(context).showSnackBar(
                    SnackBar(content: Text(s.runsRunIdCopied)),
                    kind: HermesNoticeKind.success,
                  );
                },
              ),
            ],
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
            HermesTextBlock(
              key: const ValueKey('run-detail-reply'),
              text: _output.trim(),
              collapsedLines: 12,
              openTitle: s.runsReplySection,
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
              style: TextStyle(fontSize: 10.5, color: colors.textTertiary),
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
                      color: colors.textTertiary,
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
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).runsCommandCopied)),
      kind: HermesNoticeKind.success,
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
          Tooltip(
            message: s.apx1215ScopeSessionHint,
            child: TextButton.icon(
              onPressed: widget.busy ? null : () => widget.onChoice('session'),
              icon: const Icon(Icons.repeat_rounded, size: 17),
              label: Text(s.runsApproveSession),
            ),
          ),
          if (showAlways)
            Tooltip(
              message: s.apx1215ScopeAlwaysHint,
              child: TextButton.icon(
                onPressed: widget.busy ? null : widget.onAlways,
                icon: const Icon(Icons.all_inclusive_rounded, size: 17),
                label: Text(s.runsAllowAlways),
              ),
            ),
          Tooltip(
            message: s.apx1215ScopeOnceHint,
            child: FilledButton.icon(
              onPressed: widget.busy ? null : () => widget.onChoice('once'),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(s.runsApproveOnce),
            ),
          ),
        ],
      ],
    );
  }
}
