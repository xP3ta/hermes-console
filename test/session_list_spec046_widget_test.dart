import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _connectionId = 'conn-spec-046';

Map<String, dynamic> _sessionRow(
  int index, {
  String? id,
  String? title,
  String source = 'mobile',
  int messageCount = 2,
  int? lastActiveOverride,
}) {
  final lastActive = lastActiveOverride ?? 1784500000 - index * 60;
  return {
    'id': id ?? 'session-$index',
    '_lineage_root_id': 'root-$index',
    'title': title ?? 'Conversation $index',
    'preview': 'Preview $index',
    'model': 'model-a',
    'source': source,
    'message_count': messageCount,
    'is_active': false,
    'started_at': lastActive - 30,
    'ended_at': lastActive - 1,
    'last_active': lastActive,
    'archived': false,
  };
}

http.Response _pageResponse(
  Iterable<Map<String, dynamic>> rows, {
  required int total,
  required int limit,
  required int offset,
}) => http.Response(
  jsonEncode({
    'sessions': rows.toList(growable: false),
    'total': total,
    'limit': limit,
    'offset': offset,
  }),
  200,
);

http.Response _searchResponse({
  required String id,
  required String snippet,
  String source = 'mobile',
  bool archived = false,
}) => http.Response(
  jsonEncode({
    'results': [
      {
        'session_id': id,
        'lineage_root': 'root-$id',
        'snippet': snippet,
        'source': source,
        'model': 'model-a',
        'session_started': 1784500000,
        'archived': archived,
      },
    ],
  }),
  200,
);

ApiClient _gateway(http.Client client) => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'gateway-key',
  connectionId: _connectionId,
  httpClient: client,
);

DashboardClient _dashboard(http.Client client) => DashboardClient(
  host: '127.0.0.1',
  port: 9119,
  manualToken: 'dashboard-token',
  httpClientOverride: client,
);

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Spec 046',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'gateway-key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ConnectionManager.create(prefs);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int attempts = 40,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

MockClient _healthyGatewayHttp() => MockClient((request) async {
  if (request.url.path == '/health' || request.url.path == '/api/sessions') {
    return http.Response('{}', 200);
  }
  return http.Response('{}', 404);
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sessions.changed es el único evento que refresca la biblioteca', () {
    expect(sessionLibraryRefreshGap, const Duration(seconds: 10));
    expect(
      isSessionLibraryRefreshEvent(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      ),
      isTrue,
    );
    expect(
      isSessionLibraryRefreshEvent(
        const TuiGatewayEvent(
          type: 'message.delta',
          sessionId: 'runtime',
          payload: {},
        ),
      ),
      isFalse,
    );
  });

  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  testWidgets('gateway fallback never shows the limited-list warning', (
    tester,
  ) async {
    final dashboard = _dashboard(
      MockClient((request) async => http.Response('{}', 503)),
    );
    final gateway = _gateway(
      MockClient((request) async {
        if (request.url.path == '/health') {
          return http.Response('{}', 200);
        }
        if (request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'data': [_sessionRow(0, title: 'Gateway fallback conversation')],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Gateway fallback conversation'));

    expect(
      find.text(
        'The server provides a limited list; some conversations may be missing',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Clean old'), findsNothing);
    expect(find.byKey(const ValueKey('session-cleanup-surface')), findsNothing);
  });

  testWidgets('a late search cannot replace the newest query', (tester) async {
    final alpha = Completer<http.Response>();
    final beta = Completer<http.Response>();
    final searchQueries = <String>[];
    final dashboardHttp = MockClient((request) async {
      if (request.url.path == '/api/sessions') {
        return _pageResponse(
          [_sessionRow(0, title: 'Initial conversation')],
          total: 1,
          limit: 50,
          offset: 0,
        );
      }
      if (request.url.path == '/api/sessions/search') {
        final query = request.url.queryParameters['q']!;
        searchQueries.add(query);
        return switch (query) {
          'alpha' => alpha.future,
          'beta' => beta.future,
          _ => http.Response('{}', 404),
        };
      }
      return http.Response('{}', 404);
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(_healthyGatewayHttp());
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Initial conversation'));

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump(const Duration(milliseconds: 221));
    expect(searchQueries, ['alpha']);

    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pump(const Duration(milliseconds: 221));
    expect(searchQueries, ['alpha', 'beta']);

    beta.complete(
      _searchResponse(id: 'beta-result', snippet: 'Beta visible phrase'),
    );
    await _pumpUntil(tester, find.text('Beta visible phrase'));
    expect(find.text('Alpha stale phrase'), findsNothing);

    alpha.complete(
      _searchResponse(id: 'alpha-result', snippet: 'Alpha stale phrase'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));

    expect(find.text('Beta visible phrase'), findsWidgets);
    expect(find.text('Alpha stale phrase'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'la invalidación local refresca Conversaciones sin navegar de vuelta',
    (tester) async {
      var rows = <Map<String, dynamic>>[
        _sessionRow(0, title: 'Conversation removed by cleanup'),
      ];
      var sessionReads = 0;
      final dashboardHttp = MockClient((request) async {
        if (request.url.path == '/api/sessions') {
          sessionReads++;
          return _pageResponse(rows, total: rows.length, limit: 50, offset: 0);
        }
        return http.Response('{}', 404);
      });
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(_healthyGatewayHttp());
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });

      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: _connection(),
            connManager: await _manager(),
            clientOverride: gateway,
            repositoryOverride: repository,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Conversation removed by cleanup'));
      final readsBefore = sessionReads;

      historyCleanupInvalidations.publish(
        connectionId: 'another-connection',
        scope: HistoryCleanupScope.normalConversations,
      );
      await tester.pump();
      expect(
        sessionReads,
        readsBefore,
        reason: 'Conversaciones ignora invalidaciones de otra conexión',
      );

      rows = [];
      historyCleanupInvalidations.publish(
        connectionId: _connectionId,
        scope: HistoryCleanupScope.normalConversations,
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (find.text('Conversation removed by cleanup').evaluate().isEmpty) {
          break;
        }
      }

      expect(sessionReads, greaterThan(readsBefore));
      expect(find.text('Conversation removed by cleanup'), findsNothing);
      expect(find.byKey(const ValueKey('session-filter-all')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session-filter-automation')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-filter-everything')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('session-filter-automation')));
      await _pumpUntil(tester, find.text('No automation sessions'));
      expect(find.text('No automation sessions'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-filter-all')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session-filter-automation')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-filter-everything')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final readsAfterDispose = sessionReads;
      historyCleanupInvalidations.publish(
        connectionId: _connectionId,
        scope: HistoryCleanupScope.normalConversations,
      );
      await tester.pump();
      expect(sessionReads, readsAfterDispose);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Dashboard keeps child sessions folded without exposing a fake toggle',
    (tester) async {
      final queries = <Map<String, String>>[];
      final child = _sessionRow(
        1,
        id: 'child-session',
        title: 'Hidden child session',
      )..['parent_session_id'] = 'session-0';
      final dashboardHttp = MockClient((request) async {
        if (request.url.path == '/api/sessions') {
          queries.add(request.url.queryParameters);
          return _pageResponse(
            [_sessionRow(0, title: 'Visible parent session'), child],
            total: 2,
            limit: 50,
            offset: 0,
          );
        }
        return http.Response('{}', 404);
      });
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(_healthyGatewayHttp());
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });

      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: _connection(),
            connManager: await _manager(),
            clientOverride: gateway,
            repositoryOverride: repository,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Visible parent session'));

      expect(find.text('Hidden child session'), findsNothing);
      expect(queries, hasLength(1));
      expect(queries.single.containsKey('include_children'), isFalse);

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();

      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Show sub-sessions'), findsNothing);
      expect(find.text('Hide sub-sessions'), findsNothing);
      expect(find.byIcon(Icons.account_tree_outlined), findsNothing);
      expect(queries, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('categories and archive filter independently before pagination', (
    tester,
  ) async {
    final queries = <Map<String, String>>[];
    final dashboardHttp = MockClient((request) async {
      if (request.url.path == '/api/sessions') {
        queries.add(request.url.queryParameters);
        final sources = request.url.queryParameters['sources'];
        final excluded = request.url.queryParameters['exclude_sources'];
        final archived = request.url.queryParameters['archived'];
        if (archived == 'only') {
          return _pageResponse(
            [
              _sessionRow(2, title: 'Archived automation', source: 'webhook')
                ..['archived'] = true,
            ],
            total: 1,
            limit: 50,
            offset: 0,
          );
        }
        if (sources != null) {
          return _pageResponse(
            [
              _sessionRow(
                1,
                id: 'webhook_automation_20260802_013000',
                title: 'Webhook automation',
                source: 'webhook',
              ),
            ],
            total: 1,
            limit: 50,
            offset: 0,
          );
        }
        if (excluded == null) {
          return _pageResponse(
            [
              _sessionRow(3, title: 'Everything conversation'),
              _sessionRow(4, title: 'Everything automation', source: 'acp'),
            ],
            total: 2,
            limit: 50,
            offset: 0,
          );
        }
        return _pageResponse(
          [_sessionRow(0, title: 'Normal conversation')],
          total: 1,
          limit: 50,
          offset: 0,
        );
      }
      return http.Response('{}', 404);
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(_healthyGatewayHttp());
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Normal conversation'));

    expect(queries, hasLength(1));
    expect(
      queries.single['exclude_sources'],
      'cron,kanban,subagent,tool,acp,hermes_flow,vulcan_delegate,webhook',
    );
    expect(queries.single['sources'], isNull);
    expect(queries.single['source'], isNull);
    expect(queries.single['archived'], 'exclude');
    expect(find.text('Normal conversation'), findsWidgets);
    expect(find.text('Webhook automation'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('session-filter-automation')));
    await _pumpUntil(tester, find.text('Webhook automation'));

    expect(queries, hasLength(2));
    expect(
      queries.last['sources'],
      'cron,kanban,subagent,tool,acp,hermes_flow,vulcan_delegate,webhook',
    );
    expect(queries.last['exclude_sources'], isNull);
    expect(queries.last['archived'], 'exclude');
    expect(find.text('Normal conversation'), findsNothing);
    expect(find.text('Webhook automation'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _pumpUntil(tester, find.text('Archived automation'));

    expect(queries, hasLength(3));
    expect(
      queries.last['sources'],
      'cron,kanban,subagent,tool,acp,hermes_flow,vulcan_delegate,webhook',
    );
    expect(queries.last['exclude_sources'], isNull);
    expect(queries.last['archived'], 'only');
    expect(find.text('Webhook automation'), findsNothing);
    expect(find.text('Archived automation'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _pumpUntil(tester, find.text('Webhook automation'));
    await tester.tap(find.byKey(const ValueKey('session-filter-everything')));
    await _pumpUntil(tester, find.text('Everything conversation'));

    expect(queries.last['sources'], isNull);
    expect(queries.last['exclude_sources'], isNull);
    expect(queries.last['archived'], 'exclude');
    expect(find.text('Everything conversation'), findsWidgets);
    expect(find.text('Everything automation'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing category restarts search and drops its late response', (
    tester,
  ) async {
    final chatSearch = Completer<http.Response>();
    final automationSearch = Completer<http.Response>();
    final searchQueries = <Map<String, String>>[];
    final dashboardHttp = MockClient((request) async {
      if (request.url.path == '/api/sessions') {
        final automation = request.url.queryParameters['sources'] != null;
        return _pageResponse(
          [
            _sessionRow(
              automation ? 1 : 0,
              title: automation ? 'Automation page' : 'Chat page',
              source: automation ? 'webhook' : 'mobile',
            ),
          ],
          total: 1,
          limit: 50,
          offset: 0,
        );
      }
      if (request.url.path == '/api/sessions/search') {
        searchQueries.add(request.url.queryParameters);
        return request.url.queryParameters['sources'] != null
            ? automationSearch.future
            : chatSearch.future;
      }
      return http.Response('{}', 404);
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(_healthyGatewayHttp());
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Chat page'));

    await tester.enterText(find.byType(TextField), 'same');
    await tester.pump(const Duration(milliseconds: 221));
    expect(searchQueries, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('session-filter-automation')));
    for (var attempt = 0; attempt < 40 && searchQueries.length < 2; attempt++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(searchQueries, hasLength(2));

    automationSearch.complete(
      _searchResponse(
        id: 'automation-search',
        snippet: 'Automation search visible',
        source: 'webhook',
      ),
    );
    await _pumpUntil(tester, find.text('Automation search visible'));

    chatSearch.complete(
      _searchResponse(
        id: 'late-chat-search',
        snippet: 'Late chat must stay hidden',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));

    expect(find.text('Automation search visible'), findsWidgets);
    expect(find.text('Late chat must stay hidden'), findsNothing);
    expect(searchQueries.first['exclude_sources'], isNotNull);
    expect(searchQueries.last['sources'], isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cron results filter fits a 320dp screen at 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dashboard = _dashboard(
      MockClient((request) async {
        if (request.url.path == '/api/sessions') {
          return _pageResponse(
            [_sessionRow(0, title: 'Conversación normal')],
            total: 1,
            limit: 50,
            offset: 0,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final gateway = _gateway(_healthyGatewayHttp());
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Conversación normal'));

    expect(find.text('Automatización'), findsOneWidget);
    expect(find.text('Todo'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-filter-archived')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable remote search falls back with a scope notice', (
    tester,
  ) async {
    final dashboardHttp = MockClient((request) async {
      if (request.url.path == '/api/sessions') {
        return _pageResponse(
          [_sessionRow(0, title: 'Needle local conversation')],
          total: 1,
          limit: 50,
          offset: 0,
        );
      }
      if (request.url.path == '/api/sessions/search') {
        return http.Response('{}', 404);
      }
      return http.Response('{}', 404);
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(_healthyGatewayHttp());
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Needle local conversation'));

    await tester.enterText(find.byType(TextField), 'Needle');
    await tester.pump(const Duration(milliseconds: 221));
    await _pumpUntil(
      tester,
      find.text('Searching only the conversations already loaded'),
    );

    expect(find.text('Needle local conversation'), findsWidgets);
    expect(
      find.text('Searching only the conversations already loaded'),
      findsOneWidget,
    );
    final notice = find.byKey(const ValueKey('session-library-scope-notice'));
    expect(notice, findsOneWidget);
    expect(
      find.descendant(
        of: notice,
        matching: find.byKey(const ValueKey('hermes-info-banner-surface')),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling near the end loads and appends offset 50', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final offsets = <int>[];
    final dashboardHttp = MockClient((request) async {
      if (request.url.path != '/api/sessions') {
        return http.Response('{}', 404);
      }
      final limit = int.parse(request.url.queryParameters['limit']!);
      final offset = int.parse(request.url.queryParameters['offset']!);
      offsets.add(offset);
      if (offset == 0) {
        return _pageResponse(
          [for (var index = 0; index < 50; index++) _sessionRow(index)],
          total: 51,
          limit: limit,
          offset: offset,
        );
      }
      return _pageResponse(
        [_sessionRow(50)],
        total: 51,
        limit: limit,
        offset: offset,
      );
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(_healthyGatewayHttp());
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Conversation 0'));

    await tester.fling(find.byType(ListView), const Offset(0, -8000), 5000);
    for (var attempt = 0; attempt < 40 && !offsets.contains(50); attempt++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    await _pumpUntil(tester, find.text('Conversation 50'));

    expect(offsets, [0, 50]);
    expect(find.text('Conversation 50'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unopened Desktop work uses the one global aggregate badge', (
    tester,
  ) async {
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    final gateway = _gateway(
      MockClient((request) async {
        if (request.url.path == '/health') return http.Response('{}', 200);
        if (request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'data': [_sessionRow(0)],
              'has_more': false,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          globalActivityOverride: aggregate,
          activeSessionListLoader: () async => const DesktopActiveSessionList(
            sessions: [
              DesktopActiveSession(
                runtimeSessionId: 'desktop-runtime-0',
                storedSessionId: 'session-0',
                status: 'working',
              ),
            ],
          ),
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Conversation 0'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('session-running-session-0')),
      findsOneWidget,
    );
  });

  testWidgets('unknown runtime event triggers bounded roster discovery', (
    tester,
  ) async {
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    var rosterReads = 0;
    final gateway = _gateway(
      MockClient((request) async {
        if (request.url.path == '/health') return http.Response('{}', 200);
        if (request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'data': [_sessionRow(0)],
              'has_more': false,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          globalActivityOverride: aggregate,
          eventStreamOverride: events.stream,
          activeSessionListLoader: () async {
            rosterReads += 1;
            return rosterReads <= 2
                ? const DesktopActiveSessionList()
                : const DesktopActiveSessionList(
                    sessions: [
                      DesktopActiveSession(
                        runtimeSessionId: 'desktop-runtime-0',
                        storedSessionId: 'session-0',
                        status: 'working',
                      ),
                    ],
                  );
          },
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Conversation 0'));
    final beforeEvent = rosterReads;
    expect(beforeEvent, greaterThanOrEqualTo(1));
    events.add(
      const TuiGatewayEvent(
        type: 'message.start',
        sessionId: 'desktop-runtime-0',
        payload: {},
      ),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('session-running-session-0')),
    );
    expect(rosterReads, beforeEvent + 1);
  });

  testWidgets(
    'unstable reconnect keeps backing off until an RPC proves health',
    (tester) async {
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      var reconnects = 0;
      var rosterReads = 0;
      var rosterFails = false;
      final aggregate = GlobalActivityAggregate.inMemory();
      addTearDown(aggregate.dispose);
      final gateway = _gateway(
        MockClient((request) async {
          if (request.url.path == '/health') return http.Response('{}', 200);
          if (request.url.path == '/api/sessions') {
            return http.Response(
              jsonEncode({
                'data': [_sessionRow(0)],
                'has_more': false,
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: _connection(),
            connManager: await _manager(),
            clientOverride: gateway,
            eventStreamOverride: events.stream,
            globalActivityOverride: aggregate,
            eventReconnectOverride: () async {
              reconnects += 1;
            },
            eventReconnectRandomOverride: () => 0.75,
            activeSessionListLoader: () async {
              rosterReads += 1;
              if (rosterFails) throw StateError('RPC unavailable');
              return const DesktopActiveSessionList(
                sessions: [
                  DesktopActiveSession(
                    runtimeSessionId: 'desktop-runtime-0',
                    storedSessionId: 'session-0',
                    status: 'working',
                  ),
                ],
              );
            },
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Conversation 0'));
      rosterFails = true;

      events.addError(StateError('offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 749));
      expect(reconnects, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(reconnects, 1);
      await tester.pump();

      events.addError(StateError('flapped'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1499));
      expect(
        reconnects,
        1,
        reason: 'socket-open alone must not reset the reconnect attempt',
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(reconnects, 2);
      expect(rosterReads, greaterThanOrEqualTo(3));

      await tester.pump(GatewayReconnectBackoff.stableInterval);
      rosterFails = false;
      events.addError(StateError('lost after a stable interval'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 749));
      expect(reconnects, 2);
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        reconnects,
        3,
        reason: '30 healthy seconds reset the reconnect backoff',
      );
      await tester.pump();

      events.addError(StateError('lost after a successful RPC'));
      await tester.pump();
      expect(
        aggregate.activityFor(_connectionId, 'default', 'session-0')?.stale,
        isTrue,
        reason: 'transport recovery preserves known work as stale',
      );
      await tester.pump(const Duration(milliseconds: 749));
      expect(reconnects, 3);
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        reconnects,
        4,
        reason: 'a successful RPC resets the reconnect backoff',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 60));
      expect(reconnects, 4, reason: 'dispose cancels reconnect timers');
    },
  );

  testWidgets(
    'stale Spanish activity pill is neutral, bounded and accessible',
    (tester) async {
      tester.view.physicalSize = const Size(640, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final aggregate = GlobalActivityAggregate.inMemory();
      addTearDown(aggregate.dispose);
      const activityScope = GlobalActivityScope(
        connectionId: _connectionId,
        profile: 'default',
        durableSessionId: 'session-0',
        runtimeSessionId: 'desktop-runtime-0',
        replayEpoch: 'current',
      );
      aggregate.applyRecoverySnapshot(
        scope: activityScope,
        running: true,
        waitingForUser: false,
        replayTruncated: true,
        processCount: 2,
      );
      final gateway = _gateway(
        MockClient((request) async {
          if (request.url.path == '/health') return http.Response('{}', 200);
          if (request.url.path == '/api/sessions') {
            return http.Response(
              jsonEncode({
                'data': [_sessionRow(0)],
                'has_more': false,
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SessionListScreen(
            connection: _connection(),
            connManager: await _manager(),
            clientOverride: gateway,
            globalActivityOverride: aggregate,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Conversation 0'));
      expect(tester.takeException(), isNull);
      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('session-running-session-0')),
      );
      expect(semantics.label, 'trabajando · último estado conocido');
      expect(
        find.bySemanticsLabel('trabajando · último estado conocido'),
        findsOneWidget,
      );
    },
  );

  testWidgets('live transport loss retains global activity as stale', (
    tester,
  ) async {
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    final gateway = _gateway(
      MockClient((request) async {
        if (request.url.path == '/health') return http.Response('{}', 200);
        if (request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'data': [_sessionRow(0)],
              'has_more': false,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          globalActivityOverride: aggregate,
          eventStreamOverride: events.stream,
          activeSessionListLoader: () async => const DesktopActiveSessionList(
            sessions: [
              DesktopActiveSession(
                runtimeSessionId: 'desktop-runtime-0',
                storedSessionId: 'session-0',
                status: 'working',
              ),
            ],
          ),
        ),
      ),
    );
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('session-running-session-0')),
    );
    expect(
      aggregate.activityFor(_connectionId, 'default', 'session-0')?.stale,
      isFalse,
    );

    events.addError(StateError('transport lost'));
    await tester.pump();

    expect(
      aggregate.activityFor(_connectionId, 'default', 'session-0')?.stale,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('session-running-session-0')),
      findsOneWidget,
    );
  });

  testWidgets(
    'session library stays idle until its visible safety poll or an event',
    (tester) async {
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      var pageRequests = 0;
      final dashboard = _dashboard(
        MockClient((request) async {
          if (request.url.path != '/api/sessions') {
            return http.Response('{}', 404);
          }
          pageRequests += 1;
          return _pageResponse(
            [_sessionRow(0)],
            total: 1,
            limit: 50,
            offset: 0,
          );
        }),
      );
      final gateway = _gateway(_healthyGatewayHttp());
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });

      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: _connection(),
            connManager: await _manager(),
            clientOverride: gateway,
            repositoryOverride: repository,
            eventStreamOverride: events.stream,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Conversation 0'));
      final initialRequests = pageRequests;

      await tester.pump(const Duration(seconds: 59));
      expect(pageRequests, initialRequests);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        pageRequests,
        initialRequests + 1,
        reason: 'a visible 60-second safety poll must repair missed events',
      );

      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(pageRequests, initialRequests + 2);
    },
  );

  testWidgets(
    'sessions.changed follows REST without cross-process liveness retention',
    (tester) async {
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      var pageRequests = 0;
      final dashboardHttp = MockClient((request) async {
        if (request.url.path != '/api/sessions') {
          return http.Response('{}', 404);
        }
        pageRequests += 1;
        final rows = pageRequests == 1
            ? [_sessionRow(0, title: 'Working conversation')]
            : [_sessionRow(1, title: 'Fresh conversation')];
        return _pageResponse(rows, total: rows.length, limit: 50, offset: 0);
      });
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(_healthyGatewayHttp());
      final repository = SessionRepository(dashboard, gateway);

      addTearDown(() {
        repository.close();
        dashboard.close();
      });

      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: _connection(),
            connManager: await _manager(),
            clientOverride: gateway,
            repositoryOverride: repository,
            eventStreamOverride: events.stream,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Working conversation'));
      expect(
        find.byKey(const ValueKey('session-running-session-0')),
        findsNothing,
      );

      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(pageRequests, 2);

      expect(find.text('Working conversation'), findsNothing);
      expect(find.text('Fresh conversation'), findsWidgets);
      expect(
        find.byKey(const ValueKey('session-running-session-0')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'RED-B1 foreground sessions.changed refreshes the matching durable chat once',
    (tester) async {
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final connection = _connection();
      final activeChats = ActiveChatService();
      addTearDown(activeChats.dispose);
      var transcriptReads = 0;
      var transcript = <Map<String, dynamic>>[
        {
          'message_id': 'open-user-1',
          'role': 'user',
          'content': 'Primer turno abierto',
        },
        {
          'message_id': 'open-assistant-1',
          'role': 'assistant',
          'content': 'Primera respuesta abierta',
        },
      ];
      final chat = activeChats.attach(
        connection: connection,
        sessionId: 'session-0',
        logicalSessionId: 'root-0',
        sessionTitle: 'Working conversation',
        sessionProfile: 'default',
        api: ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: MockClient((_) async => http.Response('{}', 404)),
        ),
        storedMessageLoader: (_, _) async {
          transcriptReads += 1;
          return transcript;
        },
        disableForegroundKeepAlive: true,
      );
      await chat.loadMessages(profile: 'default');
      chat.state = ChatPipelineState.completed;
      transcriptReads = 0;

      var pageRequests = 0;
      final dashboardHttp = MockClient((request) async {
        if (request.url.path != '/api/sessions') {
          return http.Response('{}', 404);
        }
        pageRequests += 1;
        final row = pageRequests == 1
            ? _sessionRow(0, title: 'Working conversation')
            : _sessionRow(
                0,
                title: 'Working conversation',
                messageCount: 6,
                lastActiveOverride: 1784500300,
              );
        return _pageResponse([row], total: 1, limit: 50, offset: 0);
      });
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(_healthyGatewayHttp());
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });

      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: connection,
            connManager: await _manager(),
            clientOverride: gateway,
            repositoryOverride: repository,
            eventStreamOverride: events.stream,
            activeChatsOverride: activeChats,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Working conversation'));
      transcript = <Map<String, dynamic>>[
        ...transcript,
        {
          'message_id': 'open-user-2',
          'role': 'user',
          'content': 'Delega desde Desktop',
        },
        {
          'message_id': 'open-assistant-2',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'delegate-call',
              'function': {
                'name': 'delegate_task',
                'arguments': '{"goal":"private-goal"}',
              },
            },
          ],
        },
        {
          'message_id': 'open-tool-2',
          'role': 'tool',
          'tool_call_id': 'delegate-call',
          'tool_name': 'delegate_task',
          'content': jsonEncode({
            'status': 'dispatched',
            'delegation_id': 'deleg_b1c2d3e4',
            'subagent_ids': ['sa-private-b1'],
          }),
        },
        {
          'message_id': 'open-assistant-3',
          'role': 'assistant',
          'content': 'Delegación aceptada',
        },
      ];

      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      for (var attempt = 0; attempt < 80 && transcriptReads == 0; attempt++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(pageRequests, 2);
      expect(transcriptReads, 1);
      expect(
        chat.messages.where(
          (message) => message['content'] == 'Delega desde Desktop',
        ),
        hasLength(1),
      );
      expect(chat.subagentActivities, isEmpty);
      expect(chat.subagentAggregate.unknownCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background sessions.changed is held and coalesced until resumed',
    (tester) async {
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final connection = _connection();
      final activeChats = ActiveChatService();
      addTearDown(activeChats.dispose);
      var transcriptReads = 0;
      var transcript = <Map<String, dynamic>>[
        {
          'message_id': 'background-user-1',
          'role': 'user',
          'content': 'Antes del fondo',
        },
        {
          'message_id': 'background-assistant-1',
          'role': 'assistant',
          'content': 'Respuesta antes del fondo',
        },
      ];
      final chat = activeChats.attach(
        connection: connection,
        sessionId: 'session-0',
        logicalSessionId: 'root-0',
        sessionTitle: 'Background conversation',
        sessionProfile: 'default',
        api: ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: MockClient((_) async => http.Response('{}', 404)),
        ),
        storedMessageLoader: (_, _) async {
          transcriptReads += 1;
          return transcript;
        },
        disableForegroundKeepAlive: true,
      );
      await chat.loadMessages(profile: 'default');
      chat.state = ChatPipelineState.completed;
      transcriptReads = 0;

      var pageRequests = 0;
      final dashboardHttp = MockClient((request) async {
        if (request.url.path != '/api/sessions') {
          return http.Response('{}', 404);
        }
        pageRequests += 1;
        return _pageResponse(
          [
            _sessionRow(
              0,
              title: 'Background conversation',
              messageCount: pageRequests == 1 ? 2 : 4,
              lastActiveOverride: pageRequests == 1 ? 1784500000 : 1784500400,
            ),
          ],
          total: 1,
          limit: 50,
          offset: 0,
        );
      });
      final dashboard = _dashboard(dashboardHttp);
      final gateway = _gateway(_healthyGatewayHttp());
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });
      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: connection,
            connManager: await _manager(),
            clientOverride: gateway,
            repositoryOverride: repository,
            eventStreamOverride: events.stream,
            activeChatsOverride: activeChats,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Background conversation'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      transcript = <Map<String, dynamic>>[
        ...transcript,
        {
          'message_id': 'background-user-2',
          'role': 'user',
          'content': 'Turno durante el fondo',
        },
        {
          'message_id': 'background-assistant-2',
          'role': 'assistant',
          'content': 'Respuesta durante el fondo',
        },
      ];
      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(pageRequests, 1);
      expect(transcriptReads, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var attempt = 0; attempt < 80 && transcriptReads == 0; attempt++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(pageRequests, 2);
      expect(transcriptReads, 1);
      expect(
        chat.messages.where(
          (message) => message['content'] == 'Respuesta durante el fondo',
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('remote archive 500 rolls back, refreshes, and explains why', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final archiveResponse = Completer<http.Response>();
    var pageRequests = 0;
    var archiveRequests = 0;
    final dashboardHttp = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/sessions') {
        pageRequests += 1;
        return _pageResponse(
          [_sessionRow(0, title: 'Archive rollback conversation')],
          total: 1,
          limit: 50,
          offset: 0,
        );
      }
      if (request.method == 'PATCH' &&
          request.url.path == '/api/sessions/session-0') {
        archiveRequests += 1;
        expect(jsonDecode(request.body), {'archived': true});
        return archiveResponse.future;
      }
      return http.Response('{}', 404);
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(_healthyGatewayHttp());
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    const title = 'Archive rollback conversation';
    await _pumpUntil(tester, find.text(title));

    await tester.longPress(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(archiveRequests, 1);
    expect(find.text(title), findsNothing);

    archiveResponse.complete(http.Response('{}', 500));
    await _pumpUntil(tester, find.text(title));
    await _pumpUntil(
      tester,
      find.text(
        'Archive state could not be confirmed on the server; '
        'the previous state was restored',
      ),
    );

    expect(pageRequests, 2);
    expect(find.text(title), findsWidgets);
    expect(
      find.text(
        'Archive state could not be confirmed on the server; '
        'the previous state was restored',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote archive 404 falls back locally with an honest label', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var archiveRequests = 0;
    final dashboardHttp = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/sessions') {
        return _pageResponse(
          [_sessionRow(0, title: 'Local archive conversation')],
          total: 1,
          limit: 50,
          offset: 0,
        );
      }
      if (request.method == 'PATCH' &&
          request.url.path == '/api/sessions/session-0') {
        archiveRequests += 1;
        return http.Response('{}', 404);
      }
      return http.Response('{}', 404);
    });
    final dashboard = _dashboard(dashboardHttp);
    final gateway = _gateway(_healthyGatewayHttp());
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      _host(
        SessionListScreen(
          connection: _connection(),
          connManager: await _manager(),
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    const title = 'Local archive conversation';
    await _pumpUntil(tester, find.text(title));

    await tester.longPress(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(archiveRequests, 1);
    expect(find.text(title), findsNothing);
    expect(
      find.text(
        'Archived only on this device; the server cannot sync archive state',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await tester.pump();
    expect(find.text(title), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
