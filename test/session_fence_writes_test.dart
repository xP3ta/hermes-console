import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Dashboard that owns the session store, after the official handlers
/// (`web_routers/sessions.py`, `_mutate_session_request`): PATCH carries the
/// identity in the body, DELETE in the query; a missing, partial or stale one
/// is a 409; a vanished row is already_absent.
final class _OwnerDashboard {
  final sessions = <String, Map<String, Object?>>{
    's1': {'revision': 3, 'generation': 1, 'pinned': true, 'archived': false},
  };
  final writes = <http.Request>[];
  int snapshots = 0;
  String? busyDetail;
  void Function()? beforeCommit;

  http.Client client() => MockClient((request) async {
    final url = request.url;
    if (url.path == '/') {
      return http.Response(
        '<script>window.__HERMES_SESSION_TOKEN__="t";</script>',
        200,
      );
    }
    if (url.path == '/api/status') return http.Response('{}', 200);
    final id = url.pathSegments.length > 2 ? url.pathSegments[2] : '';
    if (request.method == 'GET' && url.path.endsWith('/mutation-snapshot')) {
      snapshots++;
      final row = sessions[id];
      return http.Response(
        jsonEncode({
          'session_id': id,
          'exists': row != null,
          'runtime_revision': row?['revision'] ?? 0,
          'runtime_generation': row?['generation'],
        }),
        200,
      );
    }
    if (request.method != 'PATCH' && request.method != 'DELETE') {
      return http.Response('{}', 404);
    }
    writes.add(request);
    final fields = request.method == 'PATCH'
        ? jsonDecode(request.body) as Map<String, dynamic>
        : url.queryParameters;
    final requestId = fields['request_id'];
    final revision = int.tryParse('${fields['expected_revision']}');
    final generation = int.tryParse('${fields['expected_generation']}');
    if (requestId == null && revision == null && generation == null) {
      return _refuse('client_upgrade_required: update the app');
    }
    if (requestId == null || revision == null) {
      return _refuse('mutation_identity_required');
    }
    beforeCommit?.call();
    beforeCommit = null;
    final row = sessions[id];
    if (busyDetail != null) return _refuse(busyDetail!);
    if (revision != (row?['revision'] ?? 0)) {
      return _refuse('revision_conflict');
    }
    if (row != null && generation != row['generation']) {
      return _refuse('stale_generation');
    }
    if (request.method == 'DELETE') {
      if (row == null) {
        return http.Response('{"ok":true,"already_absent":true}', 200);
      }
      sessions.remove(id);
      return http.Response('{"ok":true,"deleted_ids":["$id"]}', 200);
    }
    row!['revision'] = (row['revision']! as int) + 1;
    for (final key in ['archived', 'pinned']) {
      if (fields[key] != null) row[key] = fields[key];
    }
    return http.Response(
      jsonEncode({'ok': true, 'archived': row['archived']}),
      200,
    );
  });

  static http.Response _refuse(String detail) =>
      http.Response(jsonEncode({'detail': detail}), 409);
}

ApiClient _api(_OwnerDashboard hermes) => ApiClient.forConnection(
  SavedConnection(
    id: 'c1',
    label: 'QA',
    host: '127.0.0.2',
    port: 8642,
    apiKey: 'test-key-1',
    kind: InstanceKind.vps,
  ),
  httpClient: hermes.client(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    DashboardClient.resetSharedPasswordSessionsForTesting();
  });

  group('DELETE carries the fence, as Desktop mutateSessionHttp', () {
    test('identity rides in the query and the row is deleted', () async {
      final hermes = _OwnerDashboard();
      expect(await _api(hermes).deleteSession('s1', profile: 'work'), isTrue);
      final query = hermes.writes.single.url.queryParameters;
      expect(query['profile'], 'work');
      expect(query['request_id'], isNotEmpty);
      expect(query['expected_revision'], '3');
      expect(query['expected_generation'], '1');
    });

    test('a stale revision is re-read once, then commits', () async {
      final hermes = _OwnerDashboard();
      hermes.beforeCommit = () => hermes.sessions['s1']!['revision'] = 7;
      expect(await _api(hermes).deleteSession('s1'), isTrue);
      expect(hermes.snapshots, 2);
      expect(hermes.writes, hasLength(2));
      expect(hermes.writes.last.url.queryParameters['expected_revision'], '7');
    });

    test('a refusal that is not stale is not retried: the row stays', () async {
      final hermes = _OwnerDashboard()..busyDetail = 'session_busy';
      expect(await _api(hermes).deleteSession('s1'), isFalse);
      expect(hermes.writes, hasLength(1));
      expect(hermes.snapshots, 1);
      expect(hermes.sessions, contains('s1'));
    });

    test(
      'an absent row reads exists:false: already_absent, no DELETE',
      () async {
        final hermes = _OwnerDashboard()..sessions.clear();
        expect(await _api(hermes).deleteSession('gone'), isTrue);
        expect(hermes.snapshots, 1);
        expect(hermes.writes, isEmpty);
      },
    );
  });

  group('archive follows Desktop setSessionArchived', () {
    Future<_OwnerDashboard> archive(bool archived) async {
      final hermes = _OwnerDashboard();
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: 9119,
        manualToken: 'dashboard-token',
        httpClientOverride: hermes.client(),
      );
      final gateway = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key-1',
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      );
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
        gateway.close();
      });
      await repository.setArchived(
        Session.fromJson({'id': 's1', 'source': 'mobile'}),
        archived,
      );
      return hermes;
    }

    test('archiving also unpins on the server', () async {
      final hermes = await archive(true);
      expect(
        jsonDecode(hermes.writes.single.body),
        containsPair('pinned', false),
      );
      expect(hermes.sessions['s1'], containsPair('pinned', false));
    });

    test('unarchiving leaves the pin alone', () async {
      final hermes = await archive(false);
      expect(jsonDecode(hermes.writes.single.body), isNot(contains('pinned')));
      expect(hermes.sessions['s1'], containsPair('pinned', true));
    });
  });
}
