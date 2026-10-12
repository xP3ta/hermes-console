import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../screens/lock_screen.dart';
import '../services/app_lock.dart';
import '../services/approval_policy.dart';
import '../services/command_risk.dart';
import '../theme/app_theme.dart';
import 'read_only.dart';
import '../design/modal.dart' show showHermesDialogRoute;

/// Decisión de la política SIN mostrar diálogo, para pantallas que ya tienen su
/// propia confirmación rica (p.ej. el diff de memoria/SOUL o el diálogo de
/// skills): la pantalla muestra su confirmación solo cuando es [ActionGate.ask],
/// la salta en [ActionGate.proceed] (YOLO) y aborta en [ActionGate.blocked]
/// (solo lectura). Así el MODO de aprobación gobierna también esas acciones.
enum ActionGate { proceed, ask, blocked }

ActionGate approvalGate(
  BuildContext context, {
  required String instanceId,
  String? sessionId,
  required bool readOnlyInstance,
  required CommandRisk risk,
  String? patternKey,
}) {
  final policy = context
      .findAncestorStateOfType<HermesAppState>()
      ?.approvalPolicy;
  if (policy == null) {
    return readOnlyInstance ? ActionGate.blocked : ActionGate.ask;
  }
  final decision = policy.evaluate(
    mode: policy.effectiveMode(sessionId),
    risk: risk,
    readOnlyInstance: readOnlyInstance,
    hasSavedAlways:
        patternKey != null &&
        policy.hasSavedAlways(instanceId, patternKey: patternKey),
  );
  return switch (decision.kind) {
    ApprovalDecisionKind.blocked => ActionGate.blocked,
    ApprovalDecisionKind.autoApprove => ActionGate.proceed,
    ApprovalDecisionKind.ask => ActionGate.ask,
  };
}

/// The one rule set for answering an agent's approval request, shared by
/// the chat card and Home's «Lo siguiente» / «Te necesita»:
///   - read-only (instance or approval mode) blocks approving, with the
///     read-only notice; denying is always allowed;
///   - approving asks App Lock first when the policy requires it (the
///     default without a policy) and the lock is on; denying never does.
/// Returns whether the answer may be sent. [lock] overrides the app's lock
/// (screens that receive it injected).
Future<bool> approvalAnswerAllowed(
  BuildContext context, {
  required String choice,
  required bool readOnlyInstance,
  required String reason,
  String? sessionId,
  AppLockService? lock,
}) async {
  final app = context.findAncestorStateOfType<HermesAppState>();
  final policy = app?.approvalPolicy;
  final mode = policy?.effectiveMode(sessionId);
  final deny = choice == ApprovalScope.deny.wire;
  if (!deny && (readOnlyInstance || mode == ApprovalMode.readOnly)) {
    showReadOnlyNotice(context);
    return false;
  }
  if (!deny && (policy?.requireLock ?? true)) {
    final appLock = lock ?? app?.appLock;
    if (appLock != null && appLock.enabled) {
      final verified = await LockScreen.verify(
        context,
        appLock,
        reason: reason,
      );
      if (!verified) return false;
    }
  }
  return context.mounted;
}

/// Punto ÚNICO de aprobación para acciones que la app inicia y que MUTAN una
/// instancia (escribir memoria/SOUL, instalar/quitar/activar skills, fijar o
/// borrar modelo, crear/editar cron…). Aplica la MISMA [ApprovalPolicyService]
/// que el chat remoto (`approval.request`), para que los modos
/// YOLO/Preguntar/Conservador/Solo-lectura gobiernen TODAS las funciones —no
/// solo el chat remoto—. Antes, en local, estas acciones se ejecutaban directas
/// (solo respetaban el flag readOnly de la instancia).
///
/// Devuelve true si la acción debe ejecutarse:
///   - Solo lectura (instancia o modo) → bloquea con aviso → false.
///   - YOLO o regla "always" → ejecuta directo → true (sin diálogo).
///   - Preguntar/Conservador → diálogo de confirmación (+ App Lock si el riesgo
///     es alto y [ApprovalPolicyService.requireLock]) → según la respuesta.
Future<bool> confirmMutatingAction(
  BuildContext context, {
  required String instanceId,
  String? sessionId,
  required bool readOnlyInstance,
  required CommandRisk risk,
  required String title,
  String detail = '',
}) async {
  final app = context.findAncestorStateOfType<HermesAppState>();
  final policy = app?.approvalPolicy;
  // Sin política disponible: respeta al menos el readOnly de la instancia.
  if (policy == null) {
    if (readOnlyInstance) {
      showReadOnlyNotice(context);
      return false;
    }
    return true;
  }
  final mode = policy.effectiveMode(sessionId);
  final decision = policy.evaluate(
    mode: mode,
    risk: risk,
    readOnlyInstance: readOnlyInstance,
    hasSavedAlways: policy.hasSavedAlways(instanceId, patternKey: title),
  );
  switch (decision.kind) {
    case ApprovalDecisionKind.blocked:
      showReadOnlyNotice(context);
      return false;
    case ApprovalDecisionKind.autoApprove:
      return true;
    case ApprovalDecisionKind.ask:
      // App Lock para acciones sensibles (riesgo alto) si está configurado.
      if (policy.requireLock && risk == CommandRisk.high) {
        final lock = app?.appLock;
        if (lock != null && lock.enabled) {
          final ok = await LockScreen.verify(context, lock, reason: title);
          if (!ok) return false;
        }
      }
      if (!context.mounted) return false;
      return _confirmDialog(
        context,
        title,
        detail,
        risk,
        decision.requiresExtraConfirm,
      );
  }
}

Future<bool> _confirmDialog(
  BuildContext context,
  String title,
  String detail,
  CommandRisk risk,
  bool extraConfirm,
) async {
  final colors = Theme.of(context).hermes;
  final riskColor = switch (risk) {
    CommandRisk.high => colors.error,
    CommandRisk.medium => colors.warning,
    CommandRisk.low => colors.textSecondary,
  };
  final ok = await showHermesDialogRoute<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (detail.isNotEmpty)
            Text(
              detail,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 14, color: riskColor),
              const SizedBox(width: 6),
              Text(
                risk.label,
                style: TextStyle(fontSize: 12, color: riskColor),
              ),
            ],
          ),
          if (extraConfirm) ...[
            const SizedBox(height: 8),
            Text(
              Strings.of(context).approvalHighRisk,
              style: TextStyle(fontSize: 12, color: colors.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(Strings.of(context).commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            Strings.of(context).approvalAllow,
            style: TextStyle(
              color: extraConfirm ? colors.error : colors.accent,
            ),
          ),
        ),
      ],
    ),
  );
  return ok == true;
}
