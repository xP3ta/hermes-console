import 'dart:async';

import '../utils/session_timestamp.dart';
import 'connection_manager.dart';

enum SessionArchiveMode {
  exclude('exclude'),
  only('only'),
  include('include');

  final String wire;
  const SessionArchiveMode(this.wire);
}

enum SessionLibraryOrder {
  recent('recent'),
  created('created');

  final String wire;
  const SessionLibraryOrder(this.wire);
}

enum SessionLibrarySource { dashboard, gateway, local }

final class SessionLibraryQuery {
  final int pageSize;
  final int minMessages;
  final SessionArchiveMode archived;
  final SessionLibraryOrder order;
  final String? source;
  final List<String> sources;
  final List<String> excludeSources;
  final String? cwdPrefix;
  final String? profile;
  final bool full;
  final bool includeChildren;

  const SessionLibraryQuery({
    this.pageSize = 20,
    this.minMessages = 1,
    this.archived = SessionArchiveMode.exclude,
    this.order = SessionLibraryOrder.recent,
    this.source,
    this.sources = const [],
    this.excludeSources = const [],
    this.cwdPrefix,
    this.profile,
    this.full = false,
    this.includeChildren = false,
  });

  int get boundedPageSize => pageSize.clamp(10, 100);
  int get boundedMinMessages => minMessages.clamp(0, 1000000);

  String? get normalizedSource {
    final value = source?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  /// Los filtros de inclusión son excluyentes entre sí. Un `source` explícito
  /// tiene prioridad sobre `sources`; cualquier inclusión tiene prioridad
  /// sobre exclusiones para no enviar una query contradictoria.
  List<String> get normalizedSources => normalizedSource == null
      ? _normalizedSourceList(sources)
      : const <String>[];

  List<String> get normalizedExcludeSources =>
      normalizedSource == null && normalizedSources.isEmpty
      ? _normalizedSourceList(excludeSources)
      : const <String>[];

  String get fingerprint => <String>[
    '$boundedPageSize',
    '$boundedMinMessages',
    archived.wire,
    order.wire,
    normalizedSource ?? '',
    _canonicalSourceFingerprint(normalizedSources),
    _canonicalSourceFingerprint(normalizedExcludeSources),
    cwdPrefix?.trim() ?? '',
    profile?.trim() ?? '',
    full ? '1' : '0',
    includeChildren ? '1' : '0',
  ].join('\u001f');

  String dashboardEndpoint(int offset) {
    final params = <String, String>{
      'archived': archived.wire,
      'order': order.wire,
      'source': ?normalizedSource,
      if (normalizedSources.isNotEmpty) 'sources': normalizedSources.join(','),
      if (normalizedExcludeSources.isNotEmpty)
        'exclude_sources': normalizedExcludeSources.join(','),
      if (cwdPrefix?.trim().isNotEmpty == true) 'cwd_prefix': cwdPrefix!.trim(),
      if (profile?.trim().isNotEmpty == true) 'profile': profile!.trim(),
      'limit': '$boundedPageSize',
      'offset': '${offset < 0 ? 0 : offset}',
      'min_messages': '$boundedMinMessages',
      'full': full ? '1' : '0',
    };
    return 'sessions?${Uri(queryParameters: params).query}';
  }

  String dashboardSearchEndpoint(String text, {int limit = 20}) {
    final params = <String, String>{
      'source': ?normalizedSource,
      if (normalizedSources.isNotEmpty) 'sources': normalizedSources.join(','),
      if (normalizedExcludeSources.isNotEmpty)
        'exclude_sources': normalizedExcludeSources.join(','),
      if (profile?.trim().isNotEmpty == true) 'profile': profile!.trim(),
      'q': text.trim(),
      'limit': '${limit.clamp(1, 100)}',
    };
    return 'sessions/search?${Uri(queryParameters: params).query}';
  }
}

final class SessionLibrarySnapshot {
  final List<Session> sessions;
  final SessionLibrarySource source;
  final bool exhaustive;
  final bool stale;
  final int epoch;
  final int? total;

  const SessionLibrarySnapshot({
    this.sessions = const [],
    this.source = SessionLibrarySource.local,
    this.exhaustive = false,
    this.stale = false,
    this.epoch = 0,
    this.total,
  });
}

final class SessionSearchSnapshot {
  final List<Session> sessions;
  final SessionLibrarySource source;
  final bool exhaustive;
  final int epoch;

  const SessionSearchSnapshot({
    this.sessions = const [],
    this.source = SessionLibrarySource.local,
    this.exhaustive = false,
    this.epoch = 0,
  });
}

/// Authenticated, connection-scoped session library.
///
/// Dashboard is the only route used for rich pagination/search/archive. The
/// Gateway fallback is explicitly non-exhaustive and never receives an
/// `archived` PATCH.
final class SessionRepository {
  final DashboardClient _dashboard;
  final ApiClient _gateway;
  final bool _ownsDashboard;

  int _queryEpoch = 0;
  int _searchEpoch = 0;
  SessionLibraryQuery? _query;
  List<Session> _sessions = const [];
  SessionLibrarySource _source = SessionLibrarySource.local;
  int _nextOffset = 0;
  int? _total;
  bool _exhausted = false;
  Future<SessionLibrarySnapshot>? _nextPageFlight;

  SessionRepository(this._dashboard, this._gateway) : _ownsDashboard = false;

  SessionRepository._owned(this._dashboard, this._gateway)
    : _ownsDashboard = true;

  factory SessionRepository.forConnection(
    SavedConnection connection, {
    required ApiClient gateway,
  }) => SessionRepository._owned(DashboardClient.lazy(connection), gateway);

  SessionLibrarySnapshot get snapshot => _snapshot();

  Future<SessionLibrarySnapshot> refresh(
    SessionLibraryQuery query, {
    Iterable<String> keepIds = const <String>[],
  }) async {
    final previousFingerprint = _query?.fingerprint;
    final previousSource = _source;
    final epoch = ++_queryEpoch;
    final fingerprint = query.fingerprint;
    final retainedIds = Set<String>.unmodifiable(keepIds);
    _query = query;
    try {
      final page = await _loadDashboardPage(query, 0);
      if (!_isCurrent(epoch, fingerprint)) return _snapshot();
      if (previousFingerprint != fingerprint) _sessions = const [];
      _applyPage(page, replace: true, epoch: epoch, keepIds: retainedIds);
      return _snapshot();
    } catch (error) {
      if (!_isCurrent(epoch, fingerprint)) return _snapshot();
      if (_isDashboardAuthFailure(error)) rethrow;
      final sameScope = previousFingerprint == fingerprint;
      if (_sessions.isNotEmpty &&
          sameScope &&
          previousSource != SessionLibrarySource.gateway) {
        rethrow;
      }
      final fallback = await _gateway.getSessions(
        includeChildren: query.includeChildren,
      );
      if (!_isCurrent(epoch, fingerprint)) return _snapshot();
      if (previousFingerprint != fingerprint) _sessions = const [];
      _sessions = List<Session>.unmodifiable(
        _mergeSessionPage(
          _sessions,
          _filterFallback(fallback, query),
          retainedIds,
        ),
      );
      _source = SessionLibrarySource.gateway;
      _nextOffset = _sessions.length;
      _total = null;
      _exhausted = false;
      return _snapshot();
    }
  }

  Future<SessionLibrarySnapshot> loadNext() {
    if (_source != SessionLibrarySource.dashboard || _exhausted) {
      return Future.value(_snapshot());
    }
    final inFlight = _nextPageFlight;
    if (inFlight != null) return inFlight;
    final query = _query;
    if (query == null) return Future.value(_snapshot());
    final epoch = _queryEpoch;
    final fingerprint = query.fingerprint;
    final offset = _nextOffset;
    final future = _loadDashboardPage(query, offset).then((page) {
      if (_isCurrent(epoch, fingerprint)) {
        _applyPage(page, replace: false, epoch: epoch);
      }
      return _snapshot();
    });
    _nextPageFlight = future;
    return future.whenComplete(() {
      if (identical(_nextPageFlight, future)) _nextPageFlight = null;
    });
  }

  Future<SessionSearchSnapshot> search(
    String text, {
    int limit = 20,
    String? profile,
    SessionLibraryQuery? libraryQuery,
  }) async {
    final epoch = ++_searchEpoch;
    final query = text.trim();
    final scope = libraryQuery ?? SessionLibraryQuery(profile: profile?.trim());
    if (query.isEmpty) {
      return SessionSearchSnapshot(epoch: epoch);
    }
    try {
      final data = await _dashboard.apiGet(
        scope.dashboardSearchEndpoint(query, limit: limit),
      );
      if (epoch != _searchEpoch) {
        return SessionSearchSnapshot(epoch: epoch);
      }
      final rawResults = data['results'];
      if (rawResults is! List) {
        throw const FormatException('Invalid Dashboard session search');
      }
      final byLogicalId = <String, Session>{};
      for (final row in rawResults) {
        final parsed = _searchResult(row);
        final scoped = parsed == null
            ? null
            : _captureDashboardOwner(parsed, scope);
        if (scoped != null && _matchesSearchScope(scoped, scope)) {
          byLogicalId.putIfAbsent(scoped.logicalId, () => scoped);
        }
      }
      return SessionSearchSnapshot(
        sessions: List<Session>.unmodifiable(byLogicalId.values),
        source: SessionLibrarySource.dashboard,
        exhaustive: true,
        epoch: epoch,
      );
    } catch (error) {
      if (epoch != _searchEpoch) {
        return SessionSearchSnapshot(epoch: epoch);
      }
      if (_isDashboardAuthFailure(error)) rethrow;
      final needle = query.toLowerCase();
      final local = _filterFallback(_sessions, scope)
          .where((session) {
            return session.displayTitle.toLowerCase().contains(needle) ||
                session.preview.toLowerCase().contains(needle) ||
                session.model.toLowerCase().contains(needle) ||
                session.source.toLowerCase().contains(needle);
          })
          .toList(growable: false);
      return SessionSearchSnapshot(
        sessions: List<Session>.unmodifiable(local),
        source: SessionLibrarySource.local,
        exhaustive: false,
        epoch: epoch,
      );
    }
  }

  Future<void> setArchived(
    Session session,
    bool archived, {
    String? profile,
  }) async {
    final id = Uri.encodeComponent(session.id);
    final response = await _dashboard.apiPatch(
      'sessions/$id',
      body: {
        'archived': archived,
        if (profile?.trim().isNotEmpty == true) 'profile': profile!.trim(),
      },
    );
    if (response['ok'] != true || response['archived'] != archived) {
      throw const FormatException('Invalid Dashboard archive response');
    }
    _sessions = List<Session>.unmodifiable([
      for (final row in _sessions)
        if (row.id == session.id) row.copyWith(archived: archived) else row,
    ]);
  }

  Future<void> setPinned(
    String sessionId,
    bool pinned, {
    String? profile,
  }) async {
    final id = Uri.encodeComponent(sessionId);
    final response = await _dashboard.apiPatch(
      'sessions/$id',
      body: {
        'pinned': pinned,
        if (profile?.trim().isNotEmpty == true) 'profile': profile!.trim(),
      },
    );
    if (response['ok'] != true || response['pinned'] != pinned) {
      throw const FormatException('Invalid Dashboard pin response');
    }
    _sessions = List<Session>.unmodifiable([
      for (final row in _sessions)
        if (row.id == sessionId || row.logicalId == sessionId)
          row.copyWith(pinned: pinned)
        else
          row,
    ]);
  }

  bool _isCurrent(int epoch, String fingerprint) =>
      epoch == _queryEpoch && _query?.fingerprint == fingerprint;

  SessionLibrarySnapshot _snapshot() => SessionLibrarySnapshot(
    sessions: List<Session>.unmodifiable(_sessions),
    source: _source,
    exhaustive: _source == SessionLibrarySource.dashboard && _exhausted,
    stale: false,
    epoch: _queryEpoch,
    total: _total,
  );

  Future<_SessionPage> _loadDashboardPage(
    SessionLibraryQuery query,
    int offset,
  ) async {
    final data = await _dashboard.apiGet(query.dashboardEndpoint(offset));
    final rawRows = data['sessions'] ?? data['data'];
    if (rawRows is! List) {
      throw const FormatException('Invalid Dashboard session page');
    }
    final sessions = <Session>[];
    for (final row in rawRows) {
      final parsed = Session.tryParse(row);
      final scoped = parsed == null
          ? null
          : _captureDashboardOwner(parsed, query);
      if (scoped != null && !scoped.id.startsWith('mob-aux-')) {
        sessions.add(scoped);
      }
    }
    final serverLimit = _nonNegativeInt(data['limit']) ?? query.boundedPageSize;
    final serverOffset = _nonNegativeInt(data['offset']) ?? offset;
    return _SessionPage(
      sessions: sessions,
      rawCount: rawRows.length,
      total: _nonNegativeInt(data['total']),
      limit: serverLimit.clamp(1, 1000),
      offset: serverOffset,
    );
  }

  void _applyPage(
    _SessionPage page, {
    required bool replace,
    required int epoch,
    Set<String> keepIds = const <String>{},
  }) {
    final retained = replace
        ? keepIds
        : <String>{
            for (final row in _sessions) row.id,
            for (final row in _sessions) row.logicalId,
          };
    _sessions = List<Session>.unmodifiable(
      _mergeSessionPage(_sessions, page.sessions, retained),
    );
    _source = SessionLibrarySource.dashboard;
    _total = page.total;
    // Agent back-fills pinned rows after the LIMIT/OFFSET window. Advancing by
    // rawCount would therefore skip ordinary rows whenever a pin is appended.
    _nextOffset = page.offset + page.limit;
    _exhausted =
        (page.total != null && _nextOffset >= page.total!) ||
        (page.rawCount > 0 && page.rawCount < page.limit);
  }

  static Session _canonicalSessionWinner(Session current, Session candidate) {
    if (current.id == candidate.id &&
        current.lastActivityAt == candidate.lastActivityAt) {
      return candidate;
    }
    return compareSessionsByRecentActivity(current, candidate) <= 0
        ? current
        : candidate;
  }

  static List<Session> _mergeSessionPage(
    Iterable<Session> previous,
    Iterable<Session> incoming,
    Set<String> keepIds,
  ) {
    final previousByLineage = <String, Session>{};
    final previousAliasesByLineage = <String, Set<String>>{};
    for (final row in previous) {
      previousByLineage.update(
        row.logicalId,
        (prior) => _canonicalSessionWinner(prior, row),
        ifAbsent: () => row,
      );
      previousAliasesByLineage
          .putIfAbsent(row.logicalId, () => <String>{row.logicalId})
          .add(row.id);
    }

    final incomingByLineage = <String, Session>{};
    for (final serverRow in incoming) {
      final prior =
          incomingByLineage[serverRow.logicalId] ??
          previousByLineage[serverRow.logicalId];
      incomingByLineage[serverRow.logicalId] = prior == null
          ? serverRow
          : _canonicalSessionWinner(prior, serverRow);
    }

    final incomingIds = {for (final row in incomingByLineage.values) row.id};
    final incomingLineages = incomingByLineage.keys.toSet();
    final survivorsByLineage = <String, Session>{};
    for (final entry in previousByLineage.entries) {
      final aliases = previousAliasesByLineage[entry.key]!;
      if (incomingLineages.contains(entry.key) ||
          aliases.any(incomingIds.contains)) {
        continue;
      }
      if (aliases.any(keepIds.contains)) {
        survivorsByLineage[entry.key] = entry.value;
      }
    }
    return [...survivorsByLineage.values, ...incomingByLineage.values];
  }

  Iterable<Session> _filterFallback(
    Iterable<Session> rows,
    SessionLibraryQuery query,
  ) sync* {
    final included = query.normalizedSources.toSet();
    final excluded = query.normalizedExcludeSources.toSet();
    final requestedOwner = Session.profileOwner(query.profile);
    for (final row in rows) {
      if (row.messageCount < query.boundedMinMessages) continue;
      if (!query.includeChildren && row.parentSessionId?.isNotEmpty == true) {
        continue;
      }
      if (query.archived == SessionArchiveMode.exclude && row.archived) {
        continue;
      }
      if (query.archived == SessionArchiveMode.only && !row.archived) continue;
      if (query.normalizedSource != null &&
          row.source != query.normalizedSource) {
        continue;
      }
      if (included.isNotEmpty && !included.contains(row.source)) continue;
      if (excluded.contains(row.source)) continue;
      if (Session.profileOwner(row.profile) != requestedOwner) {
        continue;
      }
      if (query.cwdPrefix?.trim().isNotEmpty == true &&
          !(row.cwd ?? '').startsWith(query.cwdPrefix!.trim())) {
        continue;
      }
      yield row;
    }
  }

  static bool _isDashboardAuthFailure(Object error) =>
      error is DashboardHttpException &&
      (error.statusCode == 401 || error.statusCode == 403);

  static Session? _searchResult(Object? value) {
    if (value is! Map) return null;
    final id = _boundedString(value['session_id'], 1024)?.trim();
    if (id == null || id.isEmpty) return null;
    return Session(
      id: id,
      lineageRootId: _boundedString(value['lineage_root'], 1024)?.trim(),
      title: _boundedString(value['title'], 512) ?? '',
      model: _boundedString(value['model'], 256) ?? 'Default',
      source: _boundedString(value['source'], 128) ?? '',
      messageCount: _nonNegativeInt(value['message_count']) ?? 1,
      isActive: value['is_active'] == true,
      preview:
          _boundedString(value['snippet'], 1024) ??
          _boundedString(value['preview'], 1024) ??
          '',
      startedAt:
          normalizeEpochTimestamp(value['started_at']) ??
          normalizeEpochTimestamp(value['session_started']) ??
          0,
      endedAt: normalizeEpochTimestamp(value['ended_at']),
      updatedAt: normalizeEpochTimestamp(value['last_active']),
      parentSessionId: _boundedString(value['parent_session_id'], 1024),
      archived: value['archived'] == true,
      pinned: value['pinned'] is bool ? value['pinned'] as bool : null,
      profile: _boundedString(value['profile'], 128),
      toolCallCount: _nonNegativeInt(value['tool_call_count']) ?? 0,
      inputTokens: _nonNegativeInt(value['input_tokens']) ?? 0,
      outputTokens: _nonNegativeInt(value['output_tokens']) ?? 0,
    );
  }

  /// Dashboard `sessions` y `sessions/search` están scoped por la query, pero
  /// Hermes Agent todavía no repite siempre el owner en cada fila. Capturamos
  /// ese owner una vez en la frontera de red; un owner explícito contradictorio
  /// se descarta en vez de caer al perfil global mutable al abrir el chat.
  static Session? _captureDashboardOwner(
    Session session,
    SessionLibraryQuery query,
  ) {
    final requestedOwner = Session.profileOwner(query.profile);
    final published = session.profile?.trim();
    if (published != null && published.isNotEmpty) {
      return published == requestedOwner ? session : null;
    }
    return session.copyWith(profile: requestedOwner);
  }

  static bool _matchesSearchScope(Session session, SessionLibraryQuery query) {
    if (query.archived == SessionArchiveMode.exclude && session.archived) {
      return false;
    }
    if (query.archived == SessionArchiveMode.only && !session.archived) {
      return false;
    }
    final source = query.normalizedSource;
    if (source != null && session.source != source) return false;
    final sources = query.normalizedSources;
    if (sources.isNotEmpty && !sources.contains(session.source)) return false;
    if (query.normalizedExcludeSources.contains(session.source)) return false;
    if (Session.profileOwner(session.profile) !=
        Session.profileOwner(query.profile)) {
      return false;
    }
    return true;
  }

  void close() {
    _queryEpoch += 1;
    _searchEpoch += 1;
    if (_ownsDashboard) _dashboard.close();
  }
}

final class _SessionPage {
  final List<Session> sessions;
  final int rawCount;
  final int? total;
  final int limit;
  final int offset;

  const _SessionPage({
    required this.sessions,
    required this.rawCount,
    required this.total,
    required this.limit,
    required this.offset,
  });
}

int? _nonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  final integer = value.toInt();
  return value == integer ? integer : null;
}

String? _boundedString(Object? value, int maxRunes) {
  if (value is! String) return null;
  final bounded = String.fromCharCodes(value.runes.take(maxRunes));
  final sanitized = bounded
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
      .trim();
  return sanitized.isEmpty ? null : sanitized;
}

List<String> _normalizedSourceList(Iterable<String> values) {
  final seen = <String>{};
  final normalized = <String>[];
  for (final item in values) {
    final value = item.trim();
    if (value.isNotEmpty && seen.add(value)) normalized.add(value);
  }
  return List<String>.unmodifiable(normalized);
}

String _canonicalSourceFingerprint(Iterable<String> values) {
  final canonical = values.toList(growable: false)..sort();
  return canonical.join(',');
}
