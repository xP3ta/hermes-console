import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/run_registry.dart';

/// Capa semántica entre los eventos SSE de ejecución y NotificationService.
/// Traduce RunRecord a notificaciones Android sin duplicar la lógica de
/// notificación ni interferir con BackgroundListener (que solo actúa en segundo
/// plano; este controlador actúa desde TaskCenterScreen mientras la app está
/// en primer plano).
///
/// Reglas de ruido:
///   • message.delta / tool lifecycle → solo UI y audit, nunca push nuevo
///   • approval.request              → una alerta reclamada por objeto
///   • terminales                    → una alerta reclamada por objeto
class NotificationController {
  final RunNotificationFacade _notif;

  /// ID de la conexión activa. Se propaga al payload de todas las
  /// notificaciones para que el tap pueda navegar al run correcto.
  final String? _connId;

  // runId del run que emitió la última notificación de aprobación.
  // Solo se cancela la aprobación si el run que termina es el mismo.
  String? _pendingApprovalRunId;

  NotificationController(this._notif, {this._connId});

  // ── API pública ─────────────────────────────────────────────────────────────

  /// Llamado cuando el servidor acepta el run (SSE aún no iniciado).
  /// No notifica: en foreground el usuario ya ve la tarjeta en la lista.
  void notifyRunStarted(RunRecord run) {}

  /// El progreso rutinario permanece en la tarjeta visible y en el registro de
  /// ejecución. No crea una notificación push nueva.
  void notifyRunProgress(RunRecord run) {}

  /// Llamado cuando llega approval.request por SSE.
  /// Siempre bypassa la supresión en foreground (accionable + sensible al tiempo).
  void notifyRunWaitingApproval(RunRecord run) {
    _clearTimers(run.runId);
    _pendingApprovalRunId = run.runId;
    _notif.approvalPending(
      tool: run.progressLabel ?? 'herramienta',
      connId: _connId,
      sessionId: run.sessionId,
      sessionTitle: _truncate(run.prompt),
      runId: run.runId,
    );
  }

  /// Llamado cuando run.completed llega por SSE.
  void notifyRunFinished(RunRecord run) => _notifyTerminal(run, ok: true);

  /// Llamado cuando run.failed llega por SSE.
  void notifyRunFailed(RunRecord run) => _notifyTerminal(run, ok: false);

  /// Llamado cuando run.cancelled llega por SSE. Cancela la notificación de
  /// progreso sin emitir nueva notificación (fue acción del usuario).
  void notifyRunCancelled(RunRecord run) {
    _clearTimers(run.runId);
    _notif.cancelRun(run.runId);
    _cancelApprovalIfOwner(run.runId);
  }

  /// Cancela cualquier notificación activa para el run (progreso o live).
  void clearRunNotification(String runId) {
    _clearTimers(runId);
    _notif.cancelRun(runId);
  }

  /// Libera el estado efímero de la pantalla.
  void dispose() {
    _pendingApprovalRunId = null;
  }

  // ── Internos ─────────────────────────────────────────────────────────────────

  void _notifyTerminal(RunRecord run, {required bool ok}) {
    _clearTimers(run.runId);
    _notif.cancelRun(run.runId);
    _cancelApprovalIfOwner(run.runId);
    _notif.runFinished(
      title: _truncate(run.prompt),
      ok: ok,
      connId: _connId,
      sessionId: run.sessionId,
      runId: run.runId,
    );
  }

  /// Cancela la notificación de aprobación solo si este run la emitió.
  void _cancelApprovalIfOwner(String runId) {
    if (_pendingApprovalRunId == runId) {
      _pendingApprovalRunId = null;
      _notif.cancelApproval();
    }
  }

  void _clearTimers(String runId) {}

  static String _truncate(String s, [int max = 60]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
