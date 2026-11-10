// Piel nueva del Kanban (spec 1.4): columnas en el orden del backend con tono
// y ayuda propios, tarjeta con avatar, prioridad, cronómetro y enlaces, barra
// de acciones masivas, estados vacíos con salida y el ajuste que devuelve la
// piel anterior.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/kanban_card.dart';
import 'package:hermes_android/core/widgets/kanban_skin_style.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/header_actions.dart';
import 'support/pump_until_loaded.dart';

final _en = lookupStrings(const Locale('en'));

Map<String, dynamic> _task(
  String id,
  String status, {
  String? assignee,
  int priority = 0,
  String? parent,
  int comments = 0,
  int? startedAt,
}) => {
  'id': id,
  'title': 'Task $id',
  'body': '',
  'status': status,
  'assignee': ?assignee,
  'priority': priority,
  'parent': ?parent,
  'comment_count': comments,
  'started_at': ?startedAt,
};

void main() {
  final connection = SavedConnection(
    id: 'kanban-skin',
    label: 'QA',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'gateway-key',
    useHttps: true,
  );
  late List<Map<String, dynamic>> bulkBodies;

  Future<void> pumpScreen(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    bool board = false,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = const Size(4000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bulkBodies = [];
    final started = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 125;
    final mock = MockClient((request) async {
      switch (request.url.path) {
        case '/api/plugins/kanban/board':
          return _json({
            'columns': [
              {
                'name': 'triage',
                'tasks': [_task('t1', 'triage')],
              },
              {
                'name': 'todo',
                'tasks': [
                  _task(
                    'a',
                    'todo',
                    assignee: 'infra',
                    priority: 3,
                    comments: 2,
                  ),
                  _task('b', 'todo', priority: 1, parent: 'a'),
                ],
              },
              {
                'name': 'running',
                'tasks': [
                  _task('r', 'running', assignee: 'lead', startedAt: started),
                ],
              },
              {
                'name': 'zeta',
                'tasks': [_task('z', 'zeta')],
              },
              {'name': 'blocked', 'tasks': <Object>[]},
            ],
          });
        case '/api/plugins/kanban/tasks/bulk':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bulkBodies.add(body);
          return _json({
            'results': [
              for (final id in body['ids'] as List) {'id': id, 'ok': true},
            ],
          });
        case '/api/plugins/kanban/profiles':
          return _json({'profiles': <Object>[]});
      }
      return http.Response('{}', 404);
    });
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final client = KanbanClient(
      connection,
      dashboardClient: DashboardClient(
        host: 'hermes.local',
        manualToken: 'session-token',
        httpClientOverride: mock,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: TasksScreen(
          connection: connection,
          clientOverride: client,
          eventStreamOverride: events.stream,
        ),
      ),
    );
    await pumpUntilLoaded(tester);
    if (board) {
      await tester.tap(find.byKey(const ValueKey('kanban-view-board')));
      await pumpUntilLoaded(tester);
    }
  }

  testWidgets('the new skin is on by default: compact header, cards', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('kanban-skin-count')), findsOneWidget);
    expect(find.text(_en.kanbanSkinCount(5)), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hermes-segmented-floating')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('kanban-create')), findsOneWidget);
    // Priority glyph, links counter (a has one child, b has its parent).
    expect(find.byKey(const ValueKey('kanban-priority-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-priority-t1')), findsNothing);
    expect(find.byKey(const ValueKey('kanban-links-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-links-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-links-r')), findsNothing);
    // Live clock only on the running task.
    expect(find.byKey(const ValueKey('kanban-clock-r')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-clock-a')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kanban-clock-r')),
        matching: find.textContaining('2:0'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the board keeps the backend order, with tone and help', (
    tester,
  ) async {
    await pumpScreen(tester, board: true);
    double left(String name) =>
        tester.getTopLeft(find.byKey(ValueKey('kanban-board-header-$name'))).dx;
    final order = ['triage', 'todo', 'running', 'zeta', 'blocked'];
    for (var i = 1; i < order.length; i++) {
      expect(left(order[i]), greaterThan(left(order[i - 1])), reason: order[i]);
    }
    expect(find.text(_en.kanbanSkinHelpTriage), findsOneWidget);
    expect(find.text(_en.kanbanSkinHelpTodo), findsOneWidget);
    expect(find.text(_en.kanbanSkinHelpRunning), findsOneWidget);
    expect(find.text(_en.kanbanSkinHelpBlocked), findsOneWidget);
    // An unknown column only has a name and a count: the default look.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kanban-board-header-zeta')),
        matching: find.byType(Text),
      ),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kanban-board-header-zeta')),
        matching: find.text('Zeta'),
      ),
      findsOneWidget,
    );
    // The empty column says so and stays a drop target.
    expect(find.text(_en.kanbanSkinColumnEmpty), findsOneWidget);
  });

  testWidgets('the setting returns to the previous skin and back', (
    tester,
  ) async {
    await pumpScreen(tester, prefs: {kKanbanNewSkinPrefKey: false});
    expect(find.byKey(const ValueKey('kanban-skin-count')), findsNothing);
    expect(
      find.byKey(const ValueKey('hermes-segmented-floating')),
      findsOneWidget,
    );
    await tapHeaderAction(
      tester,
      inBar: find.byTooltip('How it works'),
      inMenu: find.descendant(
        of: find.byKey(const ValueKey('hermes-app-bar-more-menu')),
        matching: find.text('How it works'),
      ),
    );
    await pumpUntilLoaded(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-skin-switch')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kKanbanNewSkinPrefKey), isTrue);
    expect(KanbanSkinSetting.read(prefs), isTrue);
  });

  testWidgets('bulk bar archives the selected tasks in one request', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('kanban-selection-bar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('kanban-select-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kanban-task-a')));
    await tester.tap(find.byKey(const ValueKey('kanban-task-b')));
    await tester.pumpAndSettle();
    expect(find.text(_en.kanbanSkinSelected(2)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kanban-bulk-archive')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kanban-bulk-archive-confirm')));
    await pumpUntilLoaded(tester);
    expect(bulkBodies, hasLength(1));
    expect((bulkBodies.single['ids'] as List).toSet(), {'a', 'b'});
    expect(bulkBodies.single['archive'], isTrue);
    expect(find.byKey(const ValueKey('kanban-selection-bar')), findsNothing);
  });

  testWidgets('a filter leaves no hidden task in the bulk selection', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-select-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kanban-task-a')));
    await tester.tap(find.byKey(const ValueKey('kanban-task-b')));
    await tester.pumpAndSettle();
    expect(find.text(_en.kanbanSkinSelected(2)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kanban-skin-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('kanban-skin-search-field')),
      'Task r',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kanban-task-a')), findsNothing);
    expect(find.text(_en.kanbanSkinSelected(0)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kanban-task-r')));
    await tester.pumpAndSettle();
    expect(find.text(_en.kanbanSkinSelected(1)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kanban-bulk-archive')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kanban-bulk-archive-confirm')));
    await pumpUntilLoaded(tester);
    expect(bulkBodies, hasLength(1));
    expect((bulkBodies.single['ids'] as List).toSet(), {'r'});
  });

  testWidgets('no matches offers the way out', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('kanban-skin-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('kanban-skin-search-field')),
      'zzzz',
    );
    await tester.pumpAndSettle();
    expect(find.text(_en.kanbanNoMatches), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kanban-empty-action')));
    await tester.pumpAndSettle();
    expect(find.text(_en.kanbanNoMatches), findsNothing);
    expect(find.byKey(const ValueKey('kanban-task-a')), findsOneWidget);
  });

  testWidgets('the run clock ticks once a second', (tester) async {
    var now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000 + 59000);
    await tester.pumpWidget(
      MaterialApp(home: KanbanRunClock(startedAt: 1000, now: () => now)),
    );
    expect(find.text('0:59'), findsOneWidget);
    now = now.add(const Duration(seconds: 61));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2:00'), findsOneWidget);
  });

  test('elapsed labels, glyphs and unknown columns', () {
    expect(kanbanElapsedLabel(const Duration(seconds: 9)), '0:09');
    expect(kanbanElapsedLabel(const Duration(seconds: 3725)), '1:02:05');
    expect(kanbanElapsedLabel(const Duration(seconds: -4)), '0:00');
    expect(kanbanPriorityGlyph('high'), isNotNull);
    expect(kanbanPriorityGlyph(null), isNull);
    final colors = AppTheme.fromId('dark').hermes;
    expect(kanbanColumnStyle(colors, _en, 'review').help, isNotNull);
    final unknown = kanbanColumnStyle(colors, _en, 'something-new');
    expect(unknown.help, isNull);
    expect(unknown.tone, colors.textSecondary);
    expect(
      kanbanColumnStyle(colors, _en, 'blocked').tone,
      isNot(kanbanColumnStyle(colors, _en, 'running').tone),
    );
  });
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
