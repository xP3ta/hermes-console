import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory Hermes Dashboard for the session reads Console makes, in the
/// shapes of the reference server (`hermes_cli/web_routers/sessions.py`,
/// `web_server_dashboard.py`):
///
/// - `GET /api/status`;
/// - `GET /api/sessions?limit&offset&order=recent[&profile]`: `{sessions,
///   total, limit, offset}`, recent first, `archived: true` rows left out,
///   422 above 100 rows a page;
/// - `GET /api/sessions/<id>[?profile]`: the row, or 404 «Session not found»;
/// - `GET /api/sessions/<id>/messages?limit&offset&order[&profile]`: with
///   `order=latest` (or no `limit`) `offset` counts back from the newest row,
///   otherwise from the oldest; the page arrives oldest first, capped at 500
///   rows; an empty page for a session without messages, 404 only when the
///   session is not in that profile's store;
/// - `GET /api/sessions/<id>/mutation-snapshot`: 404 (no fence), so a
///   `DELETE /api/sessions/<id>[?profile]` goes out as is and answers
///   `{ok: true}` (`already_absent` for a session it does not have); any
///   other method on a session is 405;
/// - `GET /` serves the page token; any other path outside `/api/` is the
///   web app (`index.html`), as the SPA catch-all serves it, and is recorded
///   in [outsideApi].
///
/// Each profile has its own store and stamps its rows with its name; no
/// `profile` (or `default`) is the default one. Requests that look like the
/// retired Gateway (outside `/api/`, or a bearer without a Dashboard session)
/// are recorded in [gatewayShaped]; a native OAuth envelope also sends a
/// bearer without the page token, so a test using one must not read that
/// list.
final class FakeDashboardSessions {
  FakeDashboardSessions({Set<String>? profiles})
    : _profiles = profiles == null ? null : {'default', ...profiles};

  /// Known profiles; null accepts any. An unknown one answers 404 «Profile
  /// does not exist», as the reference server does.
  final Set<String>? _profiles;

  final requests = <http.Request>[];
  final outsideApi = <Uri>[];
  final gatewayShaped = <Uri>[];
  final deleted = <({String profile, String sessionId})>[];

  /// Status for every `/api/` answer when set (e.g. 401 or 503).
  int? status;

  final _rows = <String, Map<String, Map<String, dynamic>>>{};
  final _messages = <String, Map<String, List<Map<String, dynamic>>>>{};

  static String _owner(String? profile) {
    final value = profile?.trim() ?? '';
    return value.isEmpty ? 'default' : value;
  }

  /// Adds or replaces the session row [row] (it needs an `id`).
  void putSession(Map<String, dynamic> row, {String? profile}) {
    final owner = _owner(profile);
    (_rows[owner] ??= {})[row['id'] as String] = {
      ...row,
      'profile': owner,
      'is_default_profile': owner == 'default',
    };
  }

  /// Sets the stored transcript of [sessionId], oldest first. A session
  /// that has messages has a row too, as in the store.
  void putMessages(
    String sessionId,
    List<Map<String, dynamic>> rows, {
    String? profile,
  }) {
    final owner = _owner(profile);
    (_messages[owner] ??= {})[sessionId] = List.of(rows);
    if (_rows[owner]?[sessionId] == null) {
      putSession({'id': sessionId, 'started_at': 0}, profile: owner);
    }
  }

  List<Map<String, dynamic>>? messagesOf(String sessionId, {String? profile}) =>
      _messages[_owner(profile)]?[sessionId];

  http.Client client() => MockClient((request) async {
    requests.add(request);
    final url = request.url;
    final bearerOnly =
        (request.headers['Authorization'] ?? '').startsWith('Bearer') &&
        !request.headers.containsKey('X-Hermes-Session-Token');
    if (url.path == '/') {
      return http.Response(
        '<script>window.__HERMES_SESSION_TOKEN__="fake";</script>',
        200,
      );
    }
    if (!url.path.startsWith('/api/')) {
      outsideApi.add(url);
      gatewayShaped.add(url);
      return http.Response('<!doctype html><html><body></body></html>', 200);
    }
    if (bearerOnly) gatewayShaped.add(url);
    final forced = status;
    if (forced != null && forced != 200) {
      return _json({'detail': 'forced $forced'}, forced);
    }
    if (url.path == '/api/status') return _json({'version': 'fake'});
    final owner = _owner(url.queryParameters['profile']);
    final known = _profiles;
    if (known != null && !known.contains(owner)) {
      return _json({'detail': "Profile '$owner' does not exist."}, 404);
    }
    final parts = url.pathSegments;
    if (parts.length == 2 && parts[1] == 'sessions') {
      return _list(url, owner);
    }
    if (parts.length >= 3 && parts[1] == 'sessions') {
      final id = parts[2];
      if (parts.length == 4 && parts[3] == 'mutation-snapshot') {
        return _json({'detail': 'Not Found'}, 404);
      }
      if (parts.length == 4 && parts[3] == 'messages') {
        return _page(url, owner, id);
      }
      if (parts.length == 3) {
        final row = _rows[owner]?[id];
        if (request.method == 'DELETE') {
          if (row == null) return _json({'ok': true, 'already_absent': true});
          _rows[owner]?.remove(id);
          _messages[owner]?.remove(id);
          deleted.add((profile: owner, sessionId: id));
          return _json({'ok': true});
        }
        if (request.method != 'GET') {
          return _json({'detail': 'Method Not Allowed'}, 405);
        }
        return row == null
            ? _json({'detail': 'Session not found'}, 404)
            : _json(row);
      }
    }
    return _json({'detail': 'No such API endpoint: ${url.path}'}, 404);
  });

  http.Response _list(Uri url, String owner) {
    final query = url.queryParameters;
    final limit = int.parse(query['limit'] ?? '20');
    if (limit > 100) return _json({'detail': 'limit above 100'}, 422);
    final offset = int.parse(query['offset'] ?? '0');
    final rows =
        (_rows[owner]?.values
                  .where((row) => row['archived'] != true)
                  .toList() ??
              <Map<String, dynamic>>[])
          ..sort(
        (a, b) => ((b['last_active'] ?? b['started_at'] ?? 0) as num)
            .compareTo((a['last_active'] ?? a['started_at'] ?? 0) as num),
      );
    final end = math.min(rows.length, offset + limit);
    return _json({
      'sessions': rows.sublist(math.min(offset, rows.length), end),
      'total': rows.length,
      'limit': limit,
      'offset': offset,
    });
  }

  http.Response _page(Uri url, String owner, String id) {
    if (_rows[owner]?[id] == null) {
      return _json({'detail': 'Session not found'}, 404);
    }
    final rows = _messages[owner]?[id] ?? const <Map<String, dynamic>>[];
    final query = url.queryParameters;
    final order = query['order'];
    final latest =
        order == 'latest' || (order == null && query['limit'] == null);
    final limit = math.min(int.parse(query['limit'] ?? '500'), 500);
    final offset = int.parse(query['offset'] ?? '0');
    final List<Map<String, dynamic>> page;
    if (latest) {
      final end = math.max(0, rows.length - offset);
      page = rows.sublist(math.max(0, end - limit), end);
    } else {
      final start = math.min(offset, rows.length);
      page = rows.sublist(start, math.min(rows.length, start + limit));
    }
    return _json({
      'session_id': id,
      'profile': owner,
      'messages': page,
      'pagination': {
        'limit': limit,
        'offset': offset,
        'order': order ?? (query['limit'] == null ? 'latest' : 'oldest'),
        'returned': page.length,
      },
    });
  }

  static http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
