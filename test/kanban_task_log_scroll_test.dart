import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/scroll_behavior.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Issue #48: "The logs in the Kanban card won't scroll. They just bounce
/// back to the top." Reproduces the user gesture: open the task sheet, open
/// the worker log, drag the log body upward with a finger, release, and then
/// let the board refresh land while the log is open.
void main() {
  final connection = SavedConnection(
    id: 'kanban-log-scroll',
    label: 'QA',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'k',
    useHttps: true,
  );

  final longLog = List.generate(
    400,
    (i) => 'line ${i.toString().padLeft(3, '0')} worker output',
  ).join('\n');

  Map<String, dynamic> taskJson() => {
    'id': 'task-1',
    'title': 'Scroll me',
    'body': 'Card preview',
    'status': 'running',
  };

  MockClient buildClient({required void Function() onLogRead}) {
    return MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/plugins/kanban/board') {
        return http.Response(
          jsonEncode({
            'columns': [
              {
                'name': 'running',
                'tasks': [taskJson()],
              },
            ],
          }),
          200,
        );
      }
      if (path == '/api/plugins/kanban/boards') {
        return http.Response('{}', 404);
      }
      if (path == '/api/plugins/kanban/profiles') {
        return http.Response(jsonEncode({'profiles': []}), 200);
      }
      if (path == '/api/plugins/kanban/tasks/task-1') {
        return http.Response(
          jsonEncode({
            'task': taskJson(),
            'runs': [
              {'id': 41, 'task_id': 'task-1', 'status': 'running'},
            ],
          }),
          200,
        );
      }
      if (path == '/api/plugins/kanban/tasks/task-1/log') {
        onLogRead();
        return http.Response(
          jsonEncode({
            'task_id': 'task-1',
            'exists': true,
            'size_bytes': longLog.length,
            'content': longLog,
            'truncated': false,
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    required MockClient httpClient,
    required Stream<KanbanEvent> events,
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
        // Same physics as the real app (`lib/main.dart`): bouncing momentum.
        scrollBehavior: const MomentumScrollBehavior(),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: TasksScreen(
          connection: connection,
          clientOverride: client,
          eventStreamOverride: events,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder logSurface() => find.byKey(const ValueKey('kanban-log-surface'));

  /// Outer log viewport: the `SingleChildScrollView` that owns the 420px
  /// pane. `SelectableText` (the pre-fix widget) nests its own Scrollable,
  /// so the finder must pick the outer one explicitly to stay valid on both
  /// sides of the fix.
  Finder logViewport() => find
      .descendant(of: logSurface(), matching: find.byType(Scrollable))
      .first;

  ScrollPosition logPosition(WidgetTester tester) =>
      tester.state<ScrollableState>(logViewport()).position;

  Future<void> openLog(WidgetTester tester) async {
    await tester.tap(find.text('Scroll me'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kanban-task-log')));
    await tester.pumpAndSettle();
    expect(logSurface(), findsOneWidget);
    expect(find.textContaining('line 000'), findsOneWidget);
  }

  testWidgets(
    'el log del worker conserva el desplazamiento tras un arrastre táctil',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<KanbanEvent>.broadcast();
      addTearDown(events.close);
      var logReads = 0;
      final client = buildClient(onLogRead: () => logReads++);

      await pumpScreen(tester, httpClient: client, events: events.stream);
      await openLog(tester);
      expect(logReads, 1);

      final position = logPosition(tester);
      expect(position.pixels, 0);
      expect(position.maxScrollExtent, greaterThan(300));

      // Finger drag upward over the log body itself (not the title): the
      // user reads the log by dragging the text.
      // Several move events, like a real finger: the first one crosses the
      // touch slop and the rest must move the content.
      // The log is one big Text: its own centre sits far below the 420px
      // viewport, so aim at the visible viewport instead.
      final body = tester.getCenter(logViewport());
      final finger = await tester.startGesture(
        body,
        kind: PointerDeviceKind.touch,
      );
      for (var i = 0; i < 10; i++) {
        await finger.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await finger.up();
      await tester.pumpAndSettle();

      final afterDrag = position.pixels;
      expect(
        afterDrag,
        greaterThan(150),
        reason: 'a 300px finger drag must actually scroll the log',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'el log del worker no vuelve arriba cuando el tablero se refresca',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<KanbanEvent>.broadcast();
      addTearDown(events.close);
      var logReads = 0;
      final client = buildClient(onLogRead: () => logReads++);

      await pumpScreen(tester, httpClient: client, events: events.stream);
      await openLog(tester);

      final position = logPosition(tester);
      position.jumpTo(240);
      await tester.pump();
      expect(position.pixels, 240);

      // A board event arrives while the log is open: the screen debounces a
      // refresh (450ms) and refetches the board. The log surface must keep
      // its own scroll offset across that rebuild.
      events.add(const KanbanEvent(id: 7, taskId: 'task-1', kind: 'updated'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(logSurface(), findsOneWidget);
      expect(logReads, 1, reason: 'a board refresh must not refetch the log');
      expect(
        logPosition(tester).pixels,
        240,
        reason: 'board refresh must not reset the log scroll offset',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
