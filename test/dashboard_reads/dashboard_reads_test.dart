import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One host, two listeners. The Gateway (:8642) refuses every connection and
/// counts the attempts; the Dashboard (:9119) serves synthetic data in the
/// shapes of `hermes_cli/web_routers/sessions.py` and `status.py`.
final class _Hermes {
  int gatewayHits = 0;
  int sessionsStatus = 200;
  final sessionQueries = <Map<String, String>>[];
  final paths = <String>[];

  static const sessionTotal = 250;
  static const messageTotal = 250;

  http.Client client() => MockClient((request) async {
    final url = request.url;
    if (url.port != 9119) {
      gatewayHits++;
      throw http.ClientException('connection refused', url);
    }
    paths.add(url.path);
    final q = url.queryParameters;
    switch (url.path) {
      case '/':
        return http.Response(
          '<script>window.__HERMES_SESSION_TOKEN__="t";</script>',
          200,
        );
      case '/api/status':
        return http.Response('{"version":"0.22"}', 200);
      case '/api/sessions':
        sessionQueries.add(q);
        if (sessionsStatus != 200) return http.Response('{}', sessionsStatus);
        final limit = int.parse(q['limit'] ?? '20');
        if (limit > 100) return http.Response('{}', 422);
        final offset = int.parse(q['offset'] ?? '0');
        final end = (offset + limit).clamp(0, sessionTotal);
        return http.Response(
          jsonEncode({
            'sessions': [for (var i = offset; i < end; i++) _session(i)],
            'total': sessionTotal,
            'limit': limit,
            'offset': offset,
          }),
          200,
        );
    }
    if (url.path == '/api/sessions/s7') {
      return http.Response(jsonEncode(_session(7)), 200);
    }
    if (url.path == '/api/sessions/s7/messages') {
      // order=latest: `offset` counts back from the newest row; the page
      // itself arrives oldest first.
      final limit = int.parse(q['limit']!);
      final offset = int.parse(q['offset']!);
      final end = messageTotal - offset;
      final start = (end - limit).clamp(0, end);
      return http.Response(
        jsonEncode({
          'session_id': 's7',
          'messages': [for (var i = start; i < end; i++) _message(i)],
          'pagination': {
            'limit': limit,
            'offset': offset,
            'order': 'latest',
            'returned': end - start,
          },
        }),
        200,
      );
    }
    return http.Response('{}', 404);
  });

  static Map<String, dynamic> _session(int i) => {
    'id': 's$i',
    'title': 'Chat $i',
    'source': 'cli',
    'started_at': 1790000000 + (sessionTotal - i),
    'last_active': 1790000000 + (sessionTotal - i),
    'message_count': 4,
    'profile': 'default',
  };

  // The oldest 100 rows were compacted away but are still part of the history.
  static Map<String, dynamic> _message(int i) => {
    'id': i,
    'role': i.isEven ? 'user' : 'assistant',
    'content': 'm$i',
    if (i < 100) ...{'compacted': true, 'active': false},
  };
}

SavedConnection _connection() => SavedConnection(
  id: 'c1',
  label: 'QA',
  host: '127.0.0.2',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
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

  group('default-profile reads never touch the Gateway', () {
    test(
      'the whole list is paged with limit <= 100, no gaps or repeats',
      () async {
        final hermes = _Hermes();
        final rows = await clientFor(hermes).getSessions();
        expect(rows.map((s) => s.id).toSet(), hasLength(_Hermes.sessionTotal));
        expect(rows.first.id, 's0');
        expect(rows.last.id, 's249');
        final limits = hermes.sessionQueries.map((q) => int.parse(q['limit']!));
        expect(limits, isNotEmpty);
        expect(limits.every((l) => l <= 100), isTrue);
        expect(hermes.sessionQueries.first.containsKey('profile'), isFalse);
        expect(hermes.gatewayHits, 0);
      },
    );

    test(
      'detail and the whole compacted transcript come from the Dashboard',
      () async {
        final hermes = _Hermes();
        final client = clientFor(hermes);
        expect((await client.getSession('s7')).id, 's7');
        final rows = await client.getMessages('s7');
        expect(rows.map((m) => m['content']), [
          for (var i = 0; i < _Hermes.messageTotal; i++) 'm$i',
        ]);
        final page = await client.getMessagesPage(
          's7',
          limit: 120,
          offset: 200,
        );
        expect(page.messages, hasLength(50));
        expect(page.messages.first['content'], 'm0');
        expect(hermes.gatewayHits, 0);
      },
    );

    test('reachability and warm-up use the public status route', () async {
      final hermes = _Hermes();
      final client = clientFor(hermes);
      expect(await client.healthReachable(), isTrue);
      expect(await client.healthCheck(), isTrue);
      await client.warmUp();
      expect(hermes.paths, contains('/api/status'));
      expect(hermes.gatewayHits, 0);
    });

    test('a 401 on the list is an auth failure, not an outage', () async {
      final hermes = _Hermes()..sessionsStatus = 401;
      final client = clientFor(hermes);
      expect(
        client.getSessions(),
        throwsA(
          isA<CoreReadException>().having(
            (e) => e.kind,
            'kind',
            CoreReadErrorKind.auth,
          ),
        ),
      );
      // The public status route proves the server is there.
      expect(await client.healthReachable(), isTrue);
      expect(hermes.gatewayHits, 0);
    });
  });

  group('screens', () {
    Future<void> pumpHome(WidgetTester tester, _Hermes hermes) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await manager.saveConnection(
        'QA',
        '127.0.0.2',
        8642,
        'test-key',
        kind: InstanceKind.vps,
      );
      await manager.setActiveConnection(manager.getConnections().single.id);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (conn) =>
                ApiClient.forConnection(conn, httpClient: hermes.client()),
            // Even a probe that sees nothing wrong must not hide a rejected
            // list read.
            dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('Home is online and lists chats with the Gateway down', (
      tester,
    ) async {
      final hermes = _Hermes();
      await pumpHome(tester, hermes);
      expect(find.text('online · Default'), findsOneWidget);
      expect(find.text('Chat 0'), findsWidgets);
      expect(hermes.gatewayHits, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('Home says login is required when the Dashboard answers 401', (
      tester,
    ) async {
      final hermes = _Hermes()..sessionsStatus = 401;
      await pumpHome(tester, hermes);
      expect(find.text('Dashboard login required · QA'), findsOneWidget);
      expect(find.textContaining('offline'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('the drawer shows four recent rows from the Dashboard', (
      tester,
    ) async {
      final hermes = _Hermes();
      final key = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            key: key,
            drawer: HermesDrawer(
              connection: _connection(),
              connManager: await ConnectionManager.create(
                await SharedPreferences.getInstance(),
              ),
              current: DrawerSection.home,
              recentSessionsClientFactory: (conn) =>
                  ApiClient.forConnection(conn, httpClient: hermes.client()),
            ),
          ),
        ),
      );
      key.currentState!.openDrawer();
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('drawer-scroll')),
        const Offset(0, -520),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(find.text('Chat $i'), findsOneWidget);
      }
      expect(find.text('Chat 4'), findsNothing);
      expect(hermes.gatewayHits, 0);
    });
  });

  // The Dashboard list (`list_sessions_rich`) never returns continuation
  // rows, and the lineage delete order needs them: a root deleted alone leaves
  // its children orphaned. Child-inclusive reads of the default profile stay
  // on the Gateway, as before this change.
  test(
    'a child-inclusive default-profile read still uses the Gateway',
    () async {
      final gatewayQueries = <Map<String, String>>[];
      var dashboardSessionReads = 0;
      final client = ApiClient.forConnection(
        _connection(),
        httpClient: MockClient((request) async {
          final url = request.url;
          if (url.port == 9119) {
            if (url.path == '/') {
              return http.Response(
                '<script>window.__HERMES_SESSION_TOKEN__="t";</script>',
                200,
              );
            }
            if (url.path == '/api/sessions') dashboardSessionReads++;
            return http.Response(
              jsonEncode({
                'sessions': [_Hermes._session(0)],
                'total': 1,
                'limit': 100,
                'offset': 0,
              }),
              200,
            );
          }
          gatewayQueries.add(url.queryParameters);
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'root', 'title': 'Root', 'message_count': 2},
                {
                  'id': 'child',
                  'title': 'Child',
                  'message_count': 2,
                  'parent_session_id': 'root',
                },
              ],
              'has_more': false,
            }),
            200,
          );
        }),
      );
      final rows = await client.getSessions(includeChildren: true);
      expect(rows.map((s) => s.id), ['root', 'child']);
      expect(gatewayQueries, hasLength(1));
      expect(gatewayQueries.single['include_children'], 'true');
      expect(dashboardSessionReads, 0);
    },
  );

  test('every read site builds its client with the Dashboard attached', () {
    for (final path in [
      'lib/core/screens/session_list_screen.dart',
      'lib/core/screens/session_detail_screen.dart',
      'lib/core/screens/chat_screen.dart',
      'lib/core/services/active_chat_service.dart',
      'lib/core/services/mission_control_repository.dart',
      'lib/main.dart',
    ]) {
      expect(File(path).readAsStringSync(), contains('.forConnection('));
    }
  });
}
