// Normaliza eventos SSE de /v1/runs/{id}/events a campos de RunRecord.
//
// Función pura sin dependencias de Flutter — testeable directamente.
// Usada por TaskCenterScreen para actualizar badges y progressLabel
// sin polling agresivo.

/// Resultado de normalizar un evento SSE.
class RunEventUpdate {
  /// Etiqueta de progreso legible (p.ej. "Ejecutando: bash"). Null para
  /// limpiar el label (p.ej. al completar) o para events sin label útil.
  final String? progressLabel;

  /// Tipo de evento crudo que lo generó.
  final String? lastEvent;

  /// Nuevo estado del run, o null si el evento no lo cambia.
  final String? lastStatus;

  /// Si true, el run llegó a estado terminal con este evento.
  final bool isTerminal;

  /// Si false, el evento no debe provocar escritura en SharedPreferences
  /// (p.ej. message.delta, que llega centenares de veces por run).
  final bool shouldPersist;

  const RunEventUpdate({
    this.progressLabel,
    this.lastEvent,
    this.lastStatus,
    this.isTerminal = false,
    this.shouldPersist = true,
  });
}

/// Interpreta un frame SSE de /v1/runs/{id}/events y devuelve qué actualizar
/// en RunRecord. Devuelve null para tipos desconocidos o eventos irrelevantes.
///
/// Regla de escritura en RunRegistry:
///   shouldPersist: true  → persistir (tool.*, approval.*, run.*)
///   shouldPersist: false → solo actualizar UI en memoria (message.delta)
RunEventUpdate? normalizeRunEvent(Map<String, dynamic> event) {
  final type = (event['event'] ?? '').toString();

  switch (type) {
    case 'tool.started':
      final tool = (event['tool'] ?? 'herramienta').toString();
      return RunEventUpdate(
        progressLabel: 'Ejecutando: $tool',
        lastEvent: type,
        lastStatus: 'running',
      );

    case 'tool.completed':
      final tool = (event['tool'] ?? 'herramienta').toString();
      final failed = event['error'] == true;
      return RunEventUpdate(
        progressLabel: failed ? 'Error en: $tool' : 'Completado: $tool',
        lastEvent: type,
        lastStatus: 'running',
      );

    case 'approval.request':
      return RunEventUpdate(
        progressLabel: 'Waiting for approval',
        lastEvent: type,
        lastStatus: 'waiting_for_approval',
      );

    case 'approval.responded':
      final choice = (event['choice'] ?? '').toString();
      return RunEventUpdate(
        progressLabel: choice.isNotEmpty
            ? 'Approval: $choice'
            : 'Approval answered',
        lastEvent: type,
        lastStatus: 'running',
      );

    case 'run.completed':
      return RunEventUpdate(
        progressLabel: null, // limpiamos label al terminar
        lastEvent: type,
        lastStatus: 'completed',
        isTerminal: true,
      );

    case 'run.failed':
      final err = (event['error'] ?? '').toString();
      return RunEventUpdate(
        progressLabel: err.isNotEmpty ? err : 'Run failed',
        lastEvent: type,
        lastStatus: 'failed',
        isTerminal: true,
      );

    case 'run.cancelled':
      return RunEventUpdate(
        progressLabel: null,
        lastEvent: type,
        lastStatus: 'cancelled',
        isTerminal: true,
      );

    case 'message.delta':
      // Muy frecuente: no persistir, solo señalizar que el run sigue activo.
      // shouldPersist: false → la pantalla actualiza _statusOverrides en memoria.
      return RunEventUpdate(
        progressLabel: null,
        lastEvent: type,
        lastStatus: 'running',
        shouldPersist: false,
      );

    default:
      return null; // evento desconocido o keepalive
  }
}
