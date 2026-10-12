import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/services/kanban_watch_board.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final connection = SavedConnection(
    id: 'kanban-watch-board',
    label: 'QA',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'test-key',
    useHttps: true,
  );

  late List<Uri> boardReads;

  Future<void> pumpTasks(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    boardReads = [];
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/plugins/kanban/boards')) {
          return http.Response(
            jsonEncode({
              'boards': [
                {'slug': 'default', 'name': 'Main', 'is_current': true},
                {'slug': 'ops', 'name': 'Ops'},
              ],
              'current': 'default',
            }),
            200,
          );
        }
        if (path.endsWith('/plugins/kanban/board')) {
          boardReads.add(request.url);
          return http.Response(
            jsonEncode({'columns': <Object>[], 'latest_event_id': 0}),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: TasksScreen(
          connection: connection,
          clientOverride: KanbanClient(connection, dashboardClient: dashboard),
          eventStreamOverride: const Stream<KanbanEvent>.empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('picking a board remembers it for background notices', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpTasks(tester);
    expect(boardReads.first.queryParameters['board'], isNull);

    await tester.tap(find.byKey(const ValueKey('kanban-board-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ops').last);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(KanbanWatchBoard.read(prefs, connection.id), 'ops');
    expect(boardReads.last.queryParameters['board'], 'ops');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Tasks reopens on the board the notifications watch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      KanbanWatchBoard.key(connection.id): 'ops',
    });
    await pumpTasks(tester);
    expect(boardReads.first.queryParameters['board'], 'ops');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('only plain board slugs are stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await KanbanWatchBoard.write(prefs, 'c', 'ops-2');
    expect(KanbanWatchBoard.read(prefs, 'c'), 'ops-2');
    await KanbanWatchBoard.write(prefs, 'c', '../etc?x=1');
    expect(KanbanWatchBoard.read(prefs, 'c'), isNull);
    await prefs.setString(KanbanWatchBoard.key('c'), 'a&b');
    expect(KanbanWatchBoard.read(prefs, 'c'), isNull);
  });
}
