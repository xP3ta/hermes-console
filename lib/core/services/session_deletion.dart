import 'dart:async';

import '../models/session.dart';
import '../models/session_category.dart';

typedef DeleteRemoteSession = Future<bool> Function(String sessionId);
typedef DeleteLinkedCronJob = Future<void> Function(String jobId);
typedef LoadSessionsForDeletion =
    Future<List<Session>> Function({bool includeChildren});
typedef ClearLocalSessionRecovery = Future<void> Function(String sessionId);
typedef ClearConnectionConversationState = Future<int> Function();

enum HistoryCleanupScope { normalConversations, cronResults }

class HistoryCleanupInvalidation {
  final String connectionId;
  final HistoryCleanupScope scope;

  const HistoryCleanupInvalidation({
    required this.connectionId,
    required this.scope,
  });
}

/// Señal local y estrecha para refrescar las proyecciones de historial cuando
/// el backend no publica `sessions.changed` después de una limpieza.
///
/// No transporta contenido ni IDs de sesiones: los consumidores vuelven a
/// consultar su autoridad para la conexión afectada.
class HistoryCleanupInvalidationBus {
  final StreamController<HistoryCleanupInvalidation> _controller =
      StreamController<HistoryCleanupInvalidation>.broadcast(sync: true);

  Stream<HistoryCleanupInvalidation> get events => _controller.stream;

  void publish({
    required String connectionId,
    required HistoryCleanupScope scope,
  }) {
    final normalized = connectionId.trim();
    if (normalized.isEmpty || _controller.isClosed) return;
    _controller.add(
      HistoryCleanupInvalidation(connectionId: normalized, scope: scope),
    );
  }

  Future<void> close() => _controller.close();
}

final HistoryCleanupInvalidationBus historyCleanupInvalidations =
    HistoryCleanupInvalidationBus();

/// Gate compartido por Settings y Cron. Solo lectura falla antes de invocar App
/// Lock; un error del verificador también falla cerrado.
Future<bool> authorizeHistoryCleanup({
  required bool readOnly,
  required Future<bool> Function() verifyAppLock,
}) async {
  if (readOnly) return false;
  try {
    return await verifyAppLock();
  } catch (_) {
    return false;
  }
}

/// Decide si al borrar un informe programado se conserva o se elimina también
/// su tarea. El valor seguro es [keepSchedule]: borrar una conversación nunca
/// debe detener futuras ejecuciones sin una elección explícita del usuario.
enum LinkedCronDeletionMode { keepSchedule, deleteSchedule }

/// Identidades y linaje resueltos una sola vez antes de borrar. El ID que usa
/// el servidor puede diferir de la clave local con la que Chat guardó su
/// draft/outbox; mantenerlos separados evita limpiar el chat equivocado.
class SessionDeletionContext {
  final Session selected;
  final Session target;
  final List<Session> lineage;
  final String remoteSessionId;
  final String localRecoverySessionId;

  const SessionDeletionContext({
    required this.selected,
    required this.target,
    required this.lineage,
    required this.remoteSessionId,
    required this.localRecoverySessionId,
  });
}

/// Resuelve la raíz de una cadena padre/hija. Las compactaciones de Hermes
/// conservan `source: cron`, pero solo la raíz mantiene el ID `cron_<job>_...`.
Session sessionLineageRoot(Session selected, Iterable<Session> sessions) {
  final byId = {for (final session in sessions) session.id: session};
  var current = byId[selected.id] ?? selected;
  final visited = <String>{};
  while (visited.add(current.id)) {
    final parentId = current.parentSessionId;
    if (parentId == null || parentId.isEmpty) break;
    final parent = byId[parentId];
    if (parent == null) break;
    current = parent;
  }
  return current;
}

/// Obtiene el contexto autoritativo para cualquier superficie de borrado.
/// Solo las sesiones cron necesitan refetch, pero cuando lo hacen el helper
/// fuerza `includeChildren` para no dejar continuaciones huérfanas.
Future<SessionDeletionContext> resolveSessionDeletionContext(
  Session selected, {
  required LoadSessionsForDeletion loadSessions,
  String? remoteSessionId,
  String? localRecoverySessionId,
}) async {
  var target = selected;
  List<Session> lineage = const <Session>[];
  if (selected.isJob) {
    lineage = List<Session>.unmodifiable(
      await loadSessions(includeChildren: true),
    );
    target = sessionLineageRoot(selected, lineage);
  }
  final remote = selected.isJob
      ? target.id
      : _nonEmptyOr(remoteSessionId, selected.id);
  return SessionDeletionContext(
    selected: selected,
    target: target,
    lineage: lineage,
    remoteSessionId: remote,
    localRecoverySessionId: _nonEmptyOr(localRecoverySessionId, selected.id),
  );
}

String _nonEmptyOr(String? value, String fallback) {
  final clean = value?.trim() ?? '';
  return clean.isEmpty ? fallback : clean;
}

/// IDs de una cadena completa en orden seguro de borrado: hojas primero y raíz
/// al final. Así cada DELETE no convierte a la siguiente continuación en una
/// nueva sesión principal que "reaparece" en la lista.
List<String> sessionLineageDeleteOrder(
  String rootId,
  Iterable<Session> sessions,
) {
  final children = <String, List<String>>{};
  for (final session in sessions) {
    final parentId = session.parentSessionId;
    if (parentId == null || parentId.isEmpty) continue;
    children.putIfAbsent(parentId, () => <String>[]).add(session.id);
  }

  final order = <String>[];
  final visited = <String>{};
  void visit(String id) {
    if (!visited.add(id)) return;
    for (final childId in children[id] ?? const <String>[]) {
      visit(childId);
    }
    order.add(id);
  }

  visit(rootId);
  return order;
}

/// Las limpiezas masivas son solo para conversaciones normales. Un informe
/// cron requiere confirmación y borrado coordinado individual de su schedule.
List<Session> sessionsSafeForBulkDelete(Iterable<Session> sessions) => sessions
    .where(
      (session) =>
          !session.isJob && !AutomationSessionSources.contains(session.source),
    )
    .toList();

enum RemoteSessionDeleteStatus { deleted, rejected, failed }

class RemoteSessionDeleteResult {
  final RemoteSessionDeleteStatus status;
  final Object? error;

  const RemoteSessionDeleteResult._(this.status, [this.error]);

  const RemoteSessionDeleteResult.deleted()
    : this._(RemoteSessionDeleteStatus.deleted);

  const RemoteSessionDeleteResult.rejected()
    : this._(RemoteSessionDeleteStatus.rejected);

  const RemoteSessionDeleteResult.failed(Object error)
    : this._(RemoteSessionDeleteStatus.failed, error);
}

Future<RemoteSessionDeleteResult> deleteRemoteSession(
  String sessionId, {
  required DeleteRemoteSession delete,
}) async {
  try {
    final deleted = await delete(sessionId);
    return deleted
        ? const RemoteSessionDeleteResult.deleted()
        : const RemoteSessionDeleteResult.rejected();
  } catch (error) {
    return RemoteSessionDeleteResult.failed(error);
  }
}

class RemoteSessionDeleteSummary {
  final int deleted;
  final int rejected;
  final int failed;

  const RemoteSessionDeleteSummary({
    required this.deleted,
    required this.rejected,
    required this.failed,
  });

  bool get allDeleted => rejected == 0 && failed == 0;
}

/// Resultado de limpiar una fuente local cifrada. El error se conserva para
/// diagnóstico interno, pero la UI solo presenta el número de fuentes que no
/// se pudieron limpiar y nunca serializa la excepción del Keystore.
class LocalConversationClearResult {
  final int removed;
  final Object? error;

  const LocalConversationClearResult({required this.removed, this.error});

  bool get succeeded => error == null;
}

/// Resumen honesto de «vaciar conversaciones»: el listado/borrado remoto y
/// cada fuente local son independientes. Así un servidor caído no impide
/// retirar borradores sensibles del dispositivo ni se comunica éxito total si
/// una de las capas falló.
class ClearConversationsSummary {
  final RemoteSessionDeleteSummary? remote;
  final Object? remoteListError;
  final LocalConversationClearResult drafts;
  final LocalConversationClearResult transcripts;
  final LocalConversationClearResult outbox;

  const ClearConversationsSummary({
    required this.remote,
    required this.remoteListError,
    required this.drafts,
    required this.transcripts,
    required this.outbox,
  });

  int get localFailureCount =>
      [drafts, transcripts, outbox].where((result) => !result.succeeded).length;

  bool get hasChanges =>
      (remote?.deleted ?? 0) > 0 ||
      drafts.removed > 0 ||
      transcripts.removed > 0 ||
      outbox.removed > 0;

  bool get allSucceeded =>
      remoteListError == null &&
      (remote?.allDeleted ?? false) &&
      localFailureCount == 0;
}

Future<RemoteSessionDeleteSummary> deleteRemoteSessions(
  Iterable<String> sessionIds, {
  required DeleteRemoteSession delete,
  Future<void> Function(String sessionId)? onDeleted,
}) async {
  var deleted = 0;
  var rejected = 0;
  var failed = 0;

  for (final sessionId in sessionIds) {
    final result = await deleteRemoteSession(sessionId, delete: delete);
    switch (result.status) {
      case RemoteSessionDeleteStatus.deleted:
        deleted++;
        try {
          await onDeleted?.call(sessionId);
        } catch (_) {
          // El borrado remoto ya es autoridad. El callback encola su cleanup.
        }
        break;
      case RemoteSessionDeleteStatus.rejected:
        rejected++;
        break;
      case RemoteSessionDeleteStatus.failed:
        failed++;
        break;
    }
  }

  return RemoteSessionDeleteSummary(
    deleted: deleted,
    rejected: rejected,
    failed: failed,
  );
}

Future<LocalConversationClearResult> _clearLocalConversationState(
  ClearConnectionConversationState clear,
) async {
  try {
    return LocalConversationClearResult(removed: await clear());
  } catch (error) {
    return LocalConversationClearResult(removed: 0, error: error);
  }
}

/// Elimina conversaciones normales del servidor y toda recuperación local de
/// la conexión. Los informes cron quedan fuera del borrado remoto, igual que
/// en el flujo anterior, pero borradores/transcripts/outbox se intentan siempre
/// aunque [loadSessions] falle.
Future<ClearConversationsSummary> clearConversationsAndLocalState({
  required LoadSessionsForDeletion loadSessions,
  required DeleteRemoteSession deleteSession,
  required ClearConnectionConversationState clearDrafts,
  required ClearConnectionConversationState clearTranscripts,
  required ClearConnectionConversationState clearOutbox,
  Future<void> Function(String sessionId)? onRemoteSessionDeleted,
}) async {
  RemoteSessionDeleteSummary? remote;
  Object? remoteListError;
  try {
    final sessions = await loadSessions(includeChildren: true);
    remote = await deleteRemoteSessions(
      sessionsSafeForBulkDelete(sessions).map((session) => session.id),
      delete: deleteSession,
      onDeleted: onRemoteSessionDeleted,
    );
  } catch (error) {
    remoteListError = error;
  }

  final drafts = await _clearLocalConversationState(clearDrafts);
  final transcripts = await _clearLocalConversationState(clearTranscripts);
  final outbox = await _clearLocalConversationState(clearOutbox);
  return ClearConversationsSummary(
    remote: remote,
    remoteListError: remoteListError,
    drafts: drafts,
    transcripts: transcripts,
    outbox: outbox,
  );
}

enum LinkedSessionDeleteStatus {
  deleted,
  cancelled,
  sessionRejected,
  cronDeleteFailed,
  sessionDeleteFailed,
}

/// Razón estable de un fallo de borrado. La capa de servicio conserva la causa
/// técnica únicamente para diagnóstico; las pantallas presentan el código con
/// ARB y nunca exponen `StateError.toString()` ni copy dependiente del idioma.
enum SessionDeletionFailureCode {
  lineageUnavailable('session_lineage_unavailable'),
  missingCronJobId('missing_cron_job_id'),
  cronManagerUnavailable('cron_manager_unavailable'),
  cronDeleteFailed('cron_delete_failed'),
  sessionDeleteFailed('session_delete_failed');

  const SessionDeletionFailureCode(this.stableCode);

  final String stableCode;
}

class SessionDeletionFailure {
  final SessionDeletionFailureCode code;
  final Object? cause;

  const SessionDeletionFailure(this.code, {this.cause});
}

class LinkedSessionDeleteResult {
  final LinkedSessionDeleteStatus status;
  final bool cronDeleted;
  final SessionDeletionFailure? failure;

  const LinkedSessionDeleteResult._(
    this.status, {
    required this.cronDeleted,
    this.failure,
  });

  const LinkedSessionDeleteResult.deleted({required bool cronDeleted})
    : this._(LinkedSessionDeleteStatus.deleted, cronDeleted: cronDeleted);

  const LinkedSessionDeleteResult.cancelled()
    : this._(LinkedSessionDeleteStatus.cancelled, cronDeleted: false);

  const LinkedSessionDeleteResult.sessionRejected({required bool cronDeleted})
    : this._(
        LinkedSessionDeleteStatus.sessionRejected,
        cronDeleted: cronDeleted,
      );

  LinkedSessionDeleteResult.cronDeleteFailed(
    SessionDeletionFailureCode code, {
    Object? cause,
  }) : this._(
         LinkedSessionDeleteStatus.cronDeleteFailed,
         cronDeleted: false,
         failure: SessionDeletionFailure(code, cause: cause),
       );

  LinkedSessionDeleteResult.sessionDeleteFailed(
    SessionDeletionFailureCode code, {
    required bool cronDeleted,
    Object? cause,
  }) : this._(
         LinkedSessionDeleteStatus.sessionDeleteFailed,
         cronDeleted: cronDeleted,
         failure: SessionDeletionFailure(code, cause: cause),
       );
}

/// Flujo compartido por Home, Lista, Detalle y Chat. Resuelve el linaje, trata
/// un fallo de red como resultado (nunca como Future rechazado de un widget),
/// ofrece una salida honesta para cron legacy y limpia la recuperación local
/// únicamente después de que todos los DELETE remotos hayan sido confirmados.
Future<LinkedSessionDeleteResult> deleteSessionWithResolvedLineage(
  Session selected, {
  required LoadSessionsForDeletion loadSessions,
  required DeleteRemoteSession deleteSession,
  LinkedCronDeletionMode cronDeletion = LinkedCronDeletionMode.keepSchedule,
  DeleteLinkedCronJob? deleteCronJob,
  String? remoteSessionId,
  String? localRecoverySessionId,
  ClearLocalSessionRecovery? clearLocalRecovery,
}) async {
  late final SessionDeletionContext context;
  try {
    context = await resolveSessionDeletionContext(
      selected,
      loadSessions: loadSessions,
      remoteSessionId: remoteSessionId,
      localRecoverySessionId: localRecoverySessionId,
    );
  } catch (error) {
    return LinkedSessionDeleteResult.sessionDeleteFailed(
      SessionDeletionFailureCode.lineageUnavailable,
      cronDeleted: false,
      cause: error,
    );
  }

  final result = await deleteSessionWithLinkedCron(
    context.target,
    deleteSession: deleteSession,
    deleteCronJob: deleteCronJob,
    lineage: context.lineage,
    remoteSessionId: context.remoteSessionId,
    cronDeletion: cronDeletion,
  );
  if (result.status == LinkedSessionDeleteStatus.deleted &&
      clearLocalRecovery != null) {
    try {
      await clearLocalRecovery(context.localRecoverySessionId);
    } catch (_) {
      // El servidor ya confirmó el borrado. La limpieza local es best-effort y
      // no debe convertir un éxito remoto irreversible en un falso error.
    }
  }
  return result;
}

/// Borra una conversación y conserva por defecto cualquier cron vinculado. Si
/// el usuario eligió eliminar también la programación, elimina primero el job.
/// Ese orden evita afirmar que el cron se detuvo cuando el servidor lo rechazó.
Future<LinkedSessionDeleteResult> deleteSessionWithLinkedCron(
  Session session, {
  required DeleteRemoteSession deleteSession,
  LinkedCronDeletionMode cronDeletion = LinkedCronDeletionMode.keepSchedule,
  DeleteLinkedCronJob? deleteCronJob,
  Iterable<Session> lineage = const <Session>[],
  String? remoteSessionId,
}) async {
  var cronDeleted = false;
  if (session.isJob) {
    if (cronDeletion == LinkedCronDeletionMode.deleteSchedule) {
      final jobId = session.cronJobId;
      if (jobId == null) {
        return LinkedSessionDeleteResult.cronDeleteFailed(
          SessionDeletionFailureCode.missingCronJobId,
        );
      } else if (deleteCronJob == null) {
        return LinkedSessionDeleteResult.cronDeleteFailed(
          SessionDeletionFailureCode.cronManagerUnavailable,
        );
      } else {
        try {
          await deleteCronJob(jobId);
          cronDeleted = true;
        } catch (error) {
          return LinkedSessionDeleteResult.cronDeleteFailed(
            SessionDeletionFailureCode.cronDeleteFailed,
            cause: error,
          );
        }
      }
    }

    // Quitar el schedule evita nuevas ejecuciones, pero Hermes no cancela el
    // agente cron que ya esté escribiendo. Borrar su fila mientras sigue vivo
    // provoca un FK al persistir el siguiente mensaje y la sesión reaparece.
    // La conversación se podrá borrar con un segundo intento al terminar.
    if (session.state == SessionState.active) {
      return LinkedSessionDeleteResult.sessionRejected(
        cronDeleted: cronDeleted,
      );
    }
  }

  final deleteOrder = session.isJob
      ? sessionLineageDeleteOrder(session.id, lineage)
      : <String>[_nonEmptyOr(remoteSessionId, session.id)];
  for (final sessionId in deleteOrder) {
    final sessionResult = await deleteRemoteSession(
      sessionId,
      delete: deleteSession,
    );
    switch (sessionResult.status) {
      case RemoteSessionDeleteStatus.deleted:
        continue;
      case RemoteSessionDeleteStatus.rejected:
        return LinkedSessionDeleteResult.sessionRejected(
          cronDeleted: cronDeleted,
        );
      case RemoteSessionDeleteStatus.failed:
        return LinkedSessionDeleteResult.sessionDeleteFailed(
          SessionDeletionFailureCode.sessionDeleteFailed,
          cronDeleted: cronDeleted,
          cause: sessionResult.error,
        );
    }
  }
  return LinkedSessionDeleteResult.deleted(cronDeleted: cronDeleted);
}
