import 'connection_manager.dart';

/// Un prompt del índice de Dashboard: solo metadatos (nunca cuerpos de
/// herramientas ni de asistente), con la identidad durable de su fila.
class SessionTimelineEntry {
  const SessionTimelineEntry({required this.rowId, required this.preview});

  final int rowId;
  final String preview;
}

class SessionTimelinePage {
  const SessionTimelinePage({
    required this.entries,
    required this.hasMore,
    required this.nextCursor,
  });

  /// Entradas de la página, tal como las devuelve el servidor.
  final List<SessionTimelineEntry> entries;

  /// Solo es true si el servidor lo afirma y entrega un cursor utilizable.
  final bool hasMore;
  final int? nextCursor;
}

/// Interpreta `GET /api/sessions/{id}/timeline`:
/// `{entries: [{row_id, preview, timestamp}], pagination: {has_more,
/// next_cursor, …}}`. Las filas sin id numérico o sin vista previa de texto se
/// descartan; `null` equivale a ausente. Devuelve null si el cuerpo no es un
/// índice (sin lista `entries`).
SessionTimelinePage? parseSessionTimelinePage(Object? raw) {
  if (raw is! Map) return null;
  final rawEntries = raw['entries'];
  if (rawEntries is! List) return null;
  final entries = <SessionTimelineEntry>[];
  for (final item in rawEntries) {
    if (item is! Map) continue;
    final rowId = item['row_id'];
    final preview = item['preview'];
    if (rowId is! int || preview is! String) continue;
    entries.add(SessionTimelineEntry(rowId: rowId, preview: preview));
  }
  final pagination = raw['pagination'];
  final cursor = pagination is Map ? pagination['next_cursor'] : null;
  final nextCursor = cursor is int ? cursor : null;
  final hasMore =
      pagination is Map && pagination['has_more'] == true && nextCursor != null;
  return SessionTimelinePage(
    entries: List.unmodifiable(entries),
    hasMore: hasMore,
    nextCursor: hasMore ? nextCursor : null,
  );
}

/// Lectura opcional del índice de prompts de Dashboard (hermano de
/// [DashboardClient], no parte de `connection_manager.dart`).
extension DashboardSessionTimeline on DashboardClient {
  /// Una página del índice. Devuelve null si el Dashboard no ofrece la ruta
  /// (404/405): quien llama muestra solo lo ya cargado. Cualquier otro fallo
  /// se propaga.
  Future<SessionTimelinePage?> getSessionTimelinePage(
    String sessionId, {
    String profile = '',
    int limit = 500,
    int? afterRowId,
  }) async {
    final normalizedProfile = profile.trim();
    final query = Uri(
      queryParameters: {
        'limit': '${limit.clamp(1, 500)}',
        'after_row_id': ?(afterRowId == null ? null : '$afterRowId'),
        if (normalizedProfile.isNotEmpty) 'profile': normalizedProfile,
      },
    ).query;
    try {
      final data = await apiGet(
        'sessions/${Uri.encodeComponent(sessionId)}/timeline?$query',
      );
      return parseSessionTimelinePage(data);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) return null;
      rethrow;
    }
  }
}
