import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final connection = SavedConnection(
    id: 'kanban-widget-spec058',
    label: 'QA',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'gateway-key',
    useHttps: true,
  );

  Future<void> pumpScreen(
    WidgetTester tester, {
    required MockClient httpClient,
    required Stream<KanbanEvent> events,
    String? initialAssignee,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: httpClient,
    );
    final client = KanbanClient(connection, dashboardClient: dashboard);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: TasksScreen(
          connection: connection,
          clientOverride: client,
          eventStreamOverride: events,
          initialAssignee: initialAssignee,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'detalle hidrata, mantiene error abierto y reintenta en la hoja',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<KanbanEvent>.broadcast();
      addTearDown(events.close);
      final firstDetail = Completer<http.Response>();
      var detailCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/api/plugins/kanban/board') {
          return http.Response(
            jsonEncode({
              'columns': [
                {
                  'name': 'todo',
                  'tasks': [
                    {
                      'id': 'task-1',
                      'title': 'Hydrate me',
                      'body': 'Card preview',
                      'status': 'todo',
                    },
                  ],
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/plugins/kanban/boards') {
          return http.Response('{}', 404);
        }
        if (request.url.path == '/api/plugins/kanban/profiles') {
          return http.Response(jsonEncode({'profiles': []}), 200);
        }
        if (request.url.path == '/api/plugins/kanban/tasks/task-1') {
          detailCalls++;
          if (detailCalls == 1) return firstDetail.future;
          return http.Response(
            jsonEncode({
              'task': {
                'id': 'task-1',
                'title': 'Hydrate me',
                'body': 'Full body from task detail',
                'status': 'todo',
                'latest_summary': 'Complete worker summary',
              },
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      await pumpScreen(tester, httpClient: client, events: events.stream);
      await tester.tap(find.text('Hydrate me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(detailCalls, 1);
      expect(
        find.byKey(const ValueKey('kanban-task-detail-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('kanban-task-detail-loading')),
        findsOneWidget,
      );

      firstDetail.complete(http.Response('{}', 500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('kanban-task-detail-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('kanban-task-detail-error')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('kanban-task-detail-retry')));
      await tester.pumpAndSettle();

      expect(find.text('Full body from task detail'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('kanban-task-detail-surface')),
          matching: find.text('Card preview'),
        ),
        findsNothing,
      );
      expect(find.text('Complete worker summary'), findsOneWidget);
      expect(find.byKey(const ValueKey('kanban-task-archive')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('kanban-task-delete-permanent')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('búsqueda es local y archivo se solicita solo al elegirlo', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    var boardReads = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/plugins/kanban/board') {
        boardReads++;
        final includeArchived =
            request.url.queryParameters['include_archived'] == 'true';
        return http.Response(
          jsonEncode({
            'columns': [
              {
                'name': 'todo',
                'tasks': [
                  {'id': 'needle', 'title': 'Needle task', 'status': 'todo'},
                  {'id': 'other', 'title': 'Other task', 'status': 'todo'},
                ],
              },
              if (includeArchived)
                {
                  'name': 'archived',
                  'tasks': [
                    {
                      'id': 'old',
                      'title': 'Archived task',
                      'status': 'archived',
                    },
                  ],
                },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/plugins/kanban/boards') {
        return http.Response('{}', 404);
      }
      if (request.url.path == '/api/plugins/kanban/profiles') {
        return http.Response(jsonEncode({'profiles': []}), 200);
      }
      return http.Response('{}', 404);
    });

    await pumpScreen(tester, httpClient: client, events: events.stream);
    expect(boardReads, 1);

    await tester.tap(find.byKey(const ValueKey('kanban-filter-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('kanban-search-field')),
      'needle',
    );
    await tester.tap(find.byKey(const ValueKey('kanban-filter-all')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('kanban-task-needle')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-task-other')), findsNothing);
    expect(boardReads, 1, reason: 'search must remain local');

    await tester.tap(find.byKey(const ValueKey('kanban-clear-filters')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('kanban-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kanban-filter-archived')));
    await tester.pumpAndSettle();

    expect(boardReads, 2);
    expect(find.byKey(const ValueKey('kanban-task-old')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-task-needle')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('kanban-clear-filters')));
    await tester.pump();
    expect(find.byKey(const ValueKey('kanban-task-old')), findsNothing);
    expect(find.byKey(const ValueKey('kanban-task-needle')), findsOneWidget);
    expect(boardReads, 2, reason: 'clearing archived remains a local filter');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('perfil contextual filtra por assignee y puede quitarse', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final client = MockClient((request) async {
      if (request.url.path == '/api/plugins/kanban/board') {
        return http.Response(
          jsonEncode({
            'columns': [
              {
                'name': 'running',
                'tasks': [
                  {
                    'id': 'infra-task',
                    'title': 'Infra visible',
                    'status': 'running',
                    'assignee': 'infra',
                  },
                  {
                    'id': 'other-task',
                    'title': 'Other hidden',
                    'status': 'running',
                    'assignee': 'other',
                  },
                ],
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/plugins/kanban/boards') {
        return http.Response('{}', 404);
      }
      if (request.url.path == '/api/plugins/kanban/profiles') {
        return http.Response(jsonEncode({'profiles': []}), 200);
      }
      return http.Response('{}', 404);
    });

    await pumpScreen(
      tester,
      httpClient: client,
      events: events.stream,
      initialAssignee: 'infra',
    );

    expect(
      find.byKey(const ValueKey('kanban-task-infra-task')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('kanban-task-other-task')), findsNothing);
    expect(find.text('@infra'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kanban-clear-filters')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('kanban-task-other-task')),
      findsOneWidget,
    );
  });
}
