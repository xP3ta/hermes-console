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
import 'support/pump_until_loaded.dart';

/// Live board refreshes are debounced, but two silent reloads can still be in
/// flight at once (a burst, then another burst while the first read is slow).
/// The board on screen must be the one from the most recent read: an older
/// response that arrives last must not replace a newer board.
void main() {
  final connection = SavedConnection(
    id: 'kanban-stale-reload',
    label: 'QA',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'test-key',
    useHttps: true,
  );

  const statuses = ['running', 'todo', 'blocked', 'review', 'done'];

  http.Response board(int revision) => http.Response(
    jsonEncode({
      'columns': [
        for (final status in statuses)
          {
            'name': status,
            'tasks': [
              {
                'id': '$status-1',
                'title': 'Rev $revision $status',
                'body': '',
                'status': status,
                'assignee': 'worker',
              },
            ],
          },
      ],
    }),
    200,
  );

  testWidgets('an older silent reload that resolves last keeps the newer board', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var boardReads = 0;
    final pending = <Completer<http.Response>>[];
    final mock = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/plugins/kanban/board') {
        boardReads++;
        if (boardReads == 1) return board(1);
        final c = Completer<http.Response>();
        pending.add(c);
        return c.future;
      }
      if (path == '/api/plugins/kanban/boards') return http.Response('{}', 404);
      if (path == '/api/plugins/kanban/profiles') {
        return http.Response(jsonEncode({'profiles': []}), 200);
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
    expect(find.textContaining('Rev 1'), findsWidgets);

    Future<void> burst(int id) async {
      for (var i = 0; i < 3; i++) {
        events.add(KanbanEvent(id: id + i, taskId: 'running-1', kind: 'updated'));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 600)); // > 450 ms debounce
    }

    await burst(10); // reload A in flight
    await burst(20); // reload B in flight
    expect(pending, hasLength(2), reason: 'each burst coalesces into one read');

    pending[1].complete(board(3)); // newer read answers first
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Rev 3'), findsWidgets);

    pending[0].complete(board(2)); // older read answers last
    await tester.pump();
    await tester.pump();

    // ignore: avoid_print
    print(
      'KANBAN_STALE rev3=${find.textContaining('Rev 3').evaluate().length} '
      'rev2=${find.textContaining('Rev 2').evaluate().length}',
    );
    expect(find.textContaining('Rev 2'), findsNothing);
    expect(find.textContaining('Rev 3'), findsWidgets);
  });
}
