import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/content.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/pump_until_loaded.dart';

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
    await pumpUntilLoaded(tester);
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
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('kanban-task-detail-loading')),
          matching: find.byType(ConsoleLoader),
        ),
        findsOneWidget,
      );

      firstDetail.complete(http.Response('{}', 500));
      await pumpUntilLoaded(tester);
      expect(
        find.byKey(const ValueKey('kanban-task-detail-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('kanban-task-detail-error')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('kanban-task-detail-retry')));
      await pumpUntilLoaded(tester);

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
    await pumpUntilLoaded(tester);
    await tester.enterText(
      find.byKey(const ValueKey('kanban-search-field')),
      'needle',
    );
    await tester.tap(find.byKey(const ValueKey('kanban-filter-all')));
    await pumpUntilLoaded(tester);

    expect(find.byKey(const ValueKey('kanban-task-needle')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-task-other')), findsNothing);
    expect(boardReads, 1, reason: 'search must remain local');

    await tester.tap(find.byKey(const ValueKey('kanban-clear-filters')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('kanban-filter-button')));
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-filter-archived')));
    await pumpUntilLoaded(tester);

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
    // "@infra" ahora aparece dos veces a propósito: en el chip del filtro
    // activo y junto al avatar de la propia tarjeta (rediseño de lista que
    // muestra el asignado como "@usuario", como en el resto del mockup).
    expect(find.text('@infra'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('kanban-clear-filters')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('kanban-task-other-task')),
      findsOneWidget,
    );
  });

  testWidgets('help probes orchestration once and hides its row on 404', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    var orchestrationReads = 0;
    var profileReads = 0;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/api/plugins/kanban/board':
          return http.Response('{"columns":[]}', 200);
        case '/api/plugins/kanban/boards':
          return http.Response('{}', 404);
        case '/api/plugins/kanban/profiles':
          profileReads++;
          return http.Response('{"profiles":[]}', 200);
        case '/api/plugins/kanban/orchestration':
          orchestrationReads++;
          return http.Response('{}', 404);
        default:
          return http.Response('{}', 404);
      }
    });

    await pumpScreen(tester, httpClient: client, events: events.stream);
    final profilesBeforeHelp = profileReads;
    await tester.tap(find.byTooltip('How it works'));
    await pumpUntilLoaded(tester);

    expect(orchestrationReads, 1);
    expect(profileReads, profilesBeforeHelp + 1);
    expect(
      find.byKey(const ValueKey('kanban-orchestration-row')),
      findsNothing,
    );
  });

  testWidgets('new-task model options load only when its row is tapped', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    var optionReads = 0;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/api/plugins/kanban/board':
          return http.Response(
            '{"columns":[{"name":"todo","tasks":[{"id":"t1","title":"One","status":"todo"}]}]}',
            200,
          );
        case '/api/plugins/kanban/boards':
          return http.Response('{}', 404);
        case '/api/plugins/kanban/profiles':
          return http.Response(
            '{"profiles":[{"name":"builder","is_default":true}]}',
            200,
          );
        case '/api/plugins/kanban/model-options':
          optionReads++;
          return http.Response(
            '{"providers":[{"slug":"openai","label":"OpenAI","models":["gpt-5.6"]}]}',
            200,
          );
        default:
          return http.Response('{}', 404);
      }
    });

    await pumpScreen(tester, httpClient: client, events: events.stream);
    await tester.tap(find.byTooltip('New task'));
    await pumpUntilLoaded(tester);
    expect(find.byKey(const ValueKey('kanban-create-model')), findsOneWidget);
    expect(optionReads, 0);

    await tester.tap(find.byKey(const ValueKey('kanban-create-model')));
    await pumpUntilLoaded(tester);
    expect(optionReads, 1);
    expect(
      find.byKey(const ValueKey('kanban-create-model-openai-gpt-5.6')),
      findsOneWidget,
    );
  });

  testWidgets('orchestration controls send one field per request', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final writes = <Map<String, dynamic>>[];
    var orchestrator = '';
    var autoDecompose = false;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/api/plugins/kanban/board':
          return http.Response('{"columns":[]}', 200);
        case '/api/plugins/kanban/boards':
          return http.Response('{}', 404);
        case '/api/plugins/kanban/profiles':
          return http.Response(
            '{"profiles":[{"name":"builder","is_default":true},{"name":"lead"}]}',
            200,
          );
        case '/api/plugins/kanban/orchestration':
          if (request.method == 'PUT') {
            final body = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            writes.add(body);
            if (body['orchestrator_profile'] case final String value) {
              orchestrator = value;
            }
            if (body['auto_decompose'] case final bool value) {
              autoDecompose = value;
            }
          }
          return http.Response(
            jsonEncode({
              'orchestrator_profile': orchestrator,
              'default_assignee': null,
              'auto_decompose': autoDecompose,
              'resolved_orchestrator_profile': orchestrator.isEmpty
                  ? 'builder'
                  : orchestrator,
              'resolved_default_assignee': 'builder',
              'active_profile': 'default',
            }),
            200,
          );
        default:
          return http.Response('{}', 404);
      }
    });

    await pumpScreen(tester, httpClient: client, events: events.stream);
    await tester.tap(find.byTooltip('How it works'));
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-orchestration-row')));
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-orchestrator-profile')));
    await pumpUntilLoaded(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('kanban-option-surface')),
        matching: find.text('lead'),
      ),
    );
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-auto-decompose')));
    await pumpUntilLoaded(tester);

    expect(writes, [
      {'orchestrator_profile': 'lead'},
      {'auto_decompose': true},
    ]);
  });

  testWidgets('overlapping orchestration writes keep every field', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final writes = <Map<String, dynamic>>[];
    final orchestratorGate = Completer<void>();
    var orchestrator = '';
    var autoDecompose = false;
    String snapshot() => jsonEncode({
      'orchestrator_profile': orchestrator,
      'default_assignee': null,
      'auto_decompose': autoDecompose,
      'resolved_orchestrator_profile': orchestrator.isEmpty
          ? 'builder'
          : orchestrator,
      'resolved_default_assignee': 'builder',
      'active_profile': 'default',
    });
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/api/plugins/kanban/board':
          return http.Response('{"columns":[]}', 200);
        case '/api/plugins/kanban/boards':
          return http.Response('{}', 404);
        case '/api/plugins/kanban/profiles':
          return http.Response(
            '{"profiles":[{"name":"builder","is_default":true},{"name":"lead"}]}',
            200,
          );
        case '/api/plugins/kanban/orchestration':
          if (request.method != 'PUT') return http.Response(snapshot(), 200);
          final body = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          writes.add(body);
          if (body['orchestrator_profile'] case final String value) {
            orchestrator = value;
          }
          if (body['auto_decompose'] case final bool value) {
            autoDecompose = value;
          }
          // The server applies the write on arrival; only the reply
          // (a full snapshot taken now) is delayed.
          final reply = snapshot();
          if (body.containsKey('orchestrator_profile')) {
            await orchestratorGate.future;
          }
          return http.Response(reply, 200);
        default:
          return http.Response('{}', 404);
      }
    });

    bool toggleValue() => tester
        .widget<HermesToggleRow>(
          find.byKey(const ValueKey('kanban-auto-decompose')),
        )
        .value;

    await pumpScreen(tester, httpClient: client, events: events.stream);
    await tester.tap(find.byTooltip('How it works'));
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-orchestration-row')));
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-orchestrator-profile')));
    await pumpUntilLoaded(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('kanban-option-surface')),
        matching: find.text('lead'),
      ),
    );
    await pumpUntilLoaded(tester);
    // The orchestrator reply is still held; the user flips the toggle.
    expect(writes, [
      {'orchestrator_profile': 'lead'},
    ]);
    await tester.tap(find.byKey(const ValueKey('kanban-auto-decompose')));
    await pumpUntilLoaded(tester);

    orchestratorGate.complete();
    await pumpUntilLoaded(tester);

    expect(writes, [
      {'orchestrator_profile': 'lead'},
      {'auto_decompose': true},
    ]);
    expect(toggleValue(), isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kanban-orchestrator-profile')),
        matching: find.text('lead'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failed orchestration write does not stall the next one', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final writes = <Map<String, dynamic>>[];
    final orchestratorGate = Completer<void>();
    var refreshFails = false;
    var autoDecompose = false;
    String snapshot() => jsonEncode({
      'orchestrator_profile': '',
      'default_assignee': null,
      'auto_decompose': autoDecompose,
      'resolved_orchestrator_profile': 'builder',
      'resolved_default_assignee': 'builder',
      'active_profile': 'default',
    });
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/api/plugins/kanban/board':
          return http.Response('{"columns":[]}', 200);
        case '/api/plugins/kanban/boards':
          return http.Response('{}', 404);
        case '/api/plugins/kanban/profiles':
          return http.Response(
            '{"profiles":[{"name":"builder","is_default":true},{"name":"lead"}]}',
            200,
          );
        case '/api/plugins/kanban/orchestration':
          if (request.method != 'PUT') {
            // The refresh after the rejected write fails too.
            if (refreshFails) return http.Response('{"detail":"down"}', 500);
            return http.Response(snapshot(), 200);
          }
          final body = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          writes.add(body);
          if (body.containsKey('orchestrator_profile')) {
            await orchestratorGate.future;
            refreshFails = true;
            return http.Response('{"detail":"unknown profile"}', 400);
          }
          if (body['auto_decompose'] case final bool value) {
            autoDecompose = value;
          }
          return http.Response(snapshot(), 200);
        default:
          return http.Response('{}', 404);
      }
    });

    bool toggleValue() => tester
        .widget<HermesToggleRow>(
          find.byKey(const ValueKey('kanban-auto-decompose')),
        )
        .value;

    await pumpScreen(tester, httpClient: client, events: events.stream);
    await tester.tap(find.byTooltip('How it works'));
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-orchestration-row')));
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-orchestrator-profile')));
    await pumpUntilLoaded(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('kanban-option-surface')),
        matching: find.text('lead'),
      ),
    );
    await pumpUntilLoaded(tester);
    // The toggle queues behind the orchestrator write that is about to fail.
    await tester.tap(find.byKey(const ValueKey('kanban-auto-decompose')));
    await pumpUntilLoaded(tester);
    expect(writes, [
      {'orchestrator_profile': 'lead'},
    ]);

    orchestratorGate.complete();
    await pumpUntilLoaded(tester);

    expect(writes, [
      {'orchestrator_profile': 'lead'},
      {'auto_decompose': true},
    ]);
    expect(autoDecompose, isTrue);
    expect(toggleValue(), isTrue);
    expect(
      tester
          .widget<HermesListRow>(
            find.byKey(const ValueKey('kanban-orchestrator-profile')),
          )
          .onTap,
      isNotNull,
    );
    expect(
      tester
          .widget<HermesToggleRow>(
            find.byKey(const ValueKey('kanban-auto-decompose')),
          )
          .onChanged,
      isNotNull,
    );
  });
}
