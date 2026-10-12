import 'connection_manager.dart';

/// A prompt of the Dashboard index: metadata only (never tool or assistant
/// bodies), with the durable identity of its row.
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

  /// Entries of the page, as the server returns them.
  final List<SessionTimelineEntry> entries;

  /// True only if the server says so and provides a usable cursor.
  final bool hasMore;
  final int? nextCursor;
}

/// Parses `GET /api/sessions/{id}/timeline`:
/// `{entries: [{row_id, preview, timestamp}], pagination: {has_more,
/// next_cursor, …}}`. Rows without a numeric id or without a text preview are
/// dropped; `null` is the same as absent. Returns null if the body is not an
/// index (no `entries` list).
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

/// Optional read of the Dashboard prompt index (a sibling of
/// [DashboardClient], not part of `connection_manager.dart`).
extension DashboardSessionTimeline on DashboardClient {
  /// One page of the index. Returns null if the Dashboard does not offer the
  /// route (404/405): the caller then shows only what is already loaded. Any other
  /// failure propagates.
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
