import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One host, two listeners. The Gateway (:8642) is down (503) and counts every
/// attempt; the Dashboard (:9119) serves synthetic data in the shapes of
/// `hermes_cli/web_routers/sessions.py` (DELETE answers `{ok:true}`,
/// `{ok:true, already_absent:true}` or 409 while a turn is running).
final class _Hermes {
  int gatewayHits = 0;
  int deleteStatus = 200;
  String deleteBody = '{"ok":true}';
  final calls = <String>[];
  final deletes = <Uri>[];
  final listQueries = <Map<String, String>>[];
  int Function()? onDelete;

  static const sessionTotal = 250;

  http.Client client() => MockClient((request) async {
    final url = request.url;
    if (url.port != 9119) {
      gatewayHits++;
      return http.Response('{}', 503);
    }
    if (url.path == '/') {
      return http.Response(
        '<script>window.__HERMES_SESSION_TOKEN__="t";</script>',
        200,
      );
    }
    if (url.path == '/api/status') {
      return http.Response('{"version":"0.22"}', 200);
    }
    if (request.method == 'GET' && url.path == '/api/sessions') {
      listQueries.add(url.queryParameters);
      final limit = int.parse(url.queryParameters['limit'] ?? '20');
      if (limit > 100) return http.Response('{}', 422);
      final offset = int.parse(url.queryParameters['offset'] ?? '0');
      final end = (offset + limit).clamp(0, sessionTotal);
      return http.Response(
        jsonEncode({
          'sessions': [for (var i = offset; i < end; i++) _row(i)],
          'total': sessionTotal,
          'limit': limit,
          'offset': offset,
        }),
        200,
      );
    }
    if (request.method == 'DELETE' && url.path.startsWith('/api/sessions/')) {
      deletes.add(url);
      calls.add('session:${url.pathSegments.last}');
      onDelete?.call();
      return http.Response(deleteBody, deleteStatus);
    }
    if (request.method == 'DELETE' && url.path.startsWith('/api/cron/jobs/')) {
      calls.add('cron:${url.pathSegments.last}');
      return http.Response('{"ok":true}', 200);
    }
    return http.Response('{}', 404);
  });

  static Map<String, dynamic> _row(int i) => {
    'id': 's$i',
    'title': 'Chat $i',
    'source': 'cli',
    'started_at': 1790000000 + (sessionTotal - i),
    'last_active': 1790000000 + (sessionTotal - i),
    'message_count': 4,
    'profile': 'default',
  };
}

SavedConnection _connection() => SavedConnection(
  id: 'c1',
  label: 'QA',
  host: '127.0.0.2',
  port: 8642,
  apiKey: 'synthetic-key',
  kind: InstanceKind.vps,
);

Session _cron(String id, {String? parent}) => Session.fromJson({
  'id': id,
  'title': 'Scheduled report',
  'source': 'cron',
  'parent_session_id': ?parent,
});

Future<LinkedSessionDeleteResult> _deleteChat(ApiClient client) =>
    deleteSessionWithResolvedLineage(
      Session.fromJson({'id': 's1', 'source': 'cli'}),
      loadSessions: ({bool includeChildren = false}) async => const [],
      deleteSession: client.deleteSession,
      serverDeletesChain: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    DashboardClient.resetSharedPasswordSessionsForTesting();
  });

  ApiClient clientFor(_Hermes hermes) =>
      ApiClient.forConnection(_connection(), httpClient: hermes.client());

  group('deleting one session goes to the Dashboard only', () {
    test('default profile: one unscoped DELETE, recovery cleared', () async {
      final hermes = _Hermes();
      final prefs = await SharedPreferences.getInstance();
      final drafts = ChatDraftStore(prefs);
      await drafts.save('c1', 's1', 'unsent', const []);
      expect((await drafts.load('c1', 's1')).text, 'unsent');

      expect(await clientFor(hermes).deleteSession('s1'), isTrue);

      expect(hermes.deletes.map((u) => u.path), ['/api/sessions/s1']);
      expect(hermes.deletes.single.queryParameters, isEmpty);
      expect(hermes.gatewayHits, 0);
      expect((await drafts.load('c1', 's1')).text, isEmpty);
    });

    test('already_absent is deleted too', () async {
      final hermes = _Hermes()
        ..deleteBody = '{"ok":true,"already_absent":true}';
      expect(await clientFor(hermes).deleteSession('s1'), isTrue);
      expect(hermes.gatewayHits, 0);
    });

    test('named profile: DELETE carries ?profile=', () async {
      final hermes = _Hermes();
      expect(
        await clientFor(hermes).deleteSession('s1', profile: 'work'),
        isTrue,
      );
      expect(hermes.deletes.single.path, '/api/sessions/s1');
      expect(hermes.deletes.single.queryParameters, {'profile': 'work'});
      expect(hermes.gatewayHits, 0);
    });

    test('409 means rejected: the row stays', () async {
      final hermes = _Hermes()
        ..deleteStatus = 409
        ..deleteBody = '{"detail":"busy"}';
      final prefs = await SharedPreferences.getInstance();
      final drafts = ChatDraftStore(prefs);
      await drafts.save('c1', 's1', 'unsent', const []);
      final result = await _deleteChat(clientFor(hermes));
      expect(result.status, LinkedSessionDeleteStatus.sessionRejected);
      expect(hermes.gatewayHits, 0);
      expect((await drafts.load('c1', 's1')).text, 'unsent');
    });

    test('5xx fails without any Gateway request', () async {
      final hermes = _Hermes()..deleteStatus = 502;
      final result = await _deleteChat(clientFor(hermes));
      expect(result.status, LinkedSessionDeleteStatus.sessionDeleteFailed);
      expect(hermes.gatewayHits, 0);
    });

    test('a network error fails without any Gateway request', () async {
      final hermes = _Hermes();
      final client = ApiClient.forConnection(
        _connection(),
        httpClient: MockClient((request) async {
          if (request.url.port != 9119) hermes.gatewayHits++;
          if (request.method == 'DELETE') {
            throw http.ClientException('reset', request.url);
          }
          return hermes.client().get(request.url);
        }),
      );
      final result = await _deleteChat(client);
      expect(result.status, LinkedSessionDeleteStatus.sessionDeleteFailed);
      expect(hermes.gatewayHits, 0);
    });

    test('401 is an authentication error, never deleted', () async {
      final hermes = _Hermes()..deleteStatus = 401;
      final result = await _deleteChat(clientFor(hermes));
      expect(result.status, LinkedSessionDeleteStatus.sessionDeleteFailed);
      expect(
        result.failure?.cause,
        anyOf(
          isA<DashboardAuthException>(),
          isA<DashboardHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(hermes.gatewayHits, 0);
    });

    for (final body in const ['{}', '{"ok":false}', '<html>proxy</html>', '']) {
      test(
        '200 without ok:true (${body.isEmpty ? 'empty' : body}) is rejected',
        () async {
          final hermes = _Hermes()..deleteBody = body;
          expect(await clientFor(hermes).deleteSession('s1'), isFalse);
          expect(hermes.gatewayHits, 0);
        },
      );
    }
  });

  group('cron lineage', () {
    test('the server deletes the chain: no child read, one DELETE', () async {
      final hermes = _Hermes();
      final client = clientFor(hermes);
      var childReads = 0;
      final root = _cron('cron_job1_20261016');
      final result = await deleteSessionWithResolvedLineage(
        root,
        loadSessions: ({bool includeChildren = false}) async {
          if (includeChildren) childReads++;
          return [
            root,
            _cron('c1', parent: root.id),
            _cron('c2', parent: 'c1'),
          ];
        },
        deleteSession: (id) => client.deleteSession(id),
        serverDeletesChain: client.hasDashboard,
      );
      expect(result.status, LinkedSessionDeleteStatus.deleted);
      expect(childReads, 0);
      expect(hermes.deletes.map((u) => u.path), [
        '/api/sessions/cron_job1_20261016',
      ]);
      expect(hermes.gatewayHits, 0);
    });

    test(
      'deleting the schedule too removes the job first, by Dashboard',
      () async {
        final hermes = _Hermes();
        final client = clientFor(hermes);
        final dashboard = DashboardClient.lazy(
          _connection(),
          httpClientOverride: hermes.client(),
        );
        final root = _cron('cron_job1_20261016');
        final result = await deleteSessionWithResolvedLineage(
          root,
          loadSessions: ({bool includeChildren = false}) async => [root],
          deleteSession: (id) => client.deleteSession(id),
          cronDeletion: LinkedCronDeletionMode.deleteSchedule,
          deleteCronJob: (jobId) => dashboard.deleteCronJob(jobId),
          serverDeletesChain: client.hasDashboard,
        );
        expect(result.status, LinkedSessionDeleteStatus.deleted);
        expect(hermes.calls, ['cron:job1', 'session:cron_job1_20261016']);
        expect(hermes.gatewayHits, 0);
      },
    );

    test(
      'without a Dashboard the lineage is still read and deleted leaf first',
      () async {
        final deleted = <String>[];
        var childReads = 0;
        final root = _cron('cron_job1_20261016');
        final result = await deleteSessionWithResolvedLineage(
          root,
          loadSessions: ({bool includeChildren = false}) async {
            if (includeChildren) childReads++;
            return [root, _cron('c1', parent: root.id)];
          },
          deleteSession: (id) async {
            deleted.add(id);
            return true;
          },
        );
        expect(result.status, LinkedSessionDeleteStatus.deleted);
        expect(childReads, 1);
        expect(deleted, ['c1', 'cron_job1_20261016']);
      },
    );
  });

  group('history cleanup', () {
    testWidgets('lists 250 rows from the Dashboard, counts and deletes them', (
      tester,
    ) async {
      final hermes = _Hermes();
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final connection = _connection();
      final remote = ApiClient.forConnection(
        connection,
        httpClient: hermes.client(),
      );
      addTearDown(remote.close);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: Scaffold(
            body: HistoryCleanupSection(
              connection: connection,
              connManager: manager,
              verifyHistoryCleanupForTesting: () async => true,
              remoteClientOverride: remote,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('history-cleanup-normal')));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        find.byKey(const ValueKey('history-cleanup-scope-confirm')),
        findsOneWidget,
      );
      // The dialog counts exactly the rows that were read.
      expect(find.text('250 conversaciones'), findsWidgets);
      expect(find.text('249 conversaciones'), findsNothing);
      expect(find.text('251 conversaciones'), findsNothing);
      expect(hermes.listQueries.length, greaterThanOrEqualTo(3));
      expect(
        hermes.listQueries.every((q) => int.parse(q['limit']!) <= 100),
        isTrue,
      );
      expect(
        hermes.listQueries.every((q) => !q.containsKey('include_children')),
        isTrue,
      );

      await tester.tap(
        find.byKey(const ValueKey('history-cleanup-scope-confirm')),
      );
      for (var i = 0; i < 400 && hermes.deletes.length < 250; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(hermes.deletes.length, 250);
      expect(hermes.deletes.map((u) => u.path).toSet(), hasLength(250));
      expect(hermes.gatewayHits, 0);
    });

    test('cancelling stops the DELETEs', () async {
      final hermes = _Hermes();
      final client = clientFor(hermes);
      var cancelled = false;
      hermes.onDelete = () {
        if (hermes.deletes.length == 3) cancelled = true;
        return 0;
      };
      final summary = await clearRemoteConversations(
        deleteOrder: [for (var i = 0; i < 10; i++) 's$i'],
        deleteSession: (id) => client.deleteSession(id),
        onProgress: (done, total) {},
        isCancelled: () => cancelled,
        isAutomation: (id) => false,
      );
      expect(summary.cancelled, isTrue);
      expect(hermes.deletes.length, 3);
      expect(hermes.gatewayHits, 0);
    });
  });

  test('every delete site hands the Dashboard to the client', () {
    for (final path in const [
      'lib/core/screens/chat_screen.dart',
      'lib/core/screens/session_detail_screen.dart',
      'lib/core/screens/session_list_screen.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('serverDeletesChain:'),
        reason: '$path must say whether the server deletes the chain',
      );
    }
    final settings = File(
      'lib/core/screens/settings_screen.dart',
    ).readAsStringSync();
    expect(settings, contains('ApiClient.forConnection(targetConnection)'));
    expect(settings, contains('includeChildren: !client.hasDashboard'));
    final chat = File('lib/core/screens/chat_screen.dart').readAsStringSync();
    expect(chat, contains('ApiClient.forConnection(widget.connection)'));
  });
}
