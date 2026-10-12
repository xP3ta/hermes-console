import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/header_actions.dart';

class _Read {
  _Read(this.url);
  final Uri url;
  final response = Completer<http.Response>();
}

class _Fixture {
  final events = StreamController<KanbanEvent>.broadcast();
  final reads = <_Read>[];
  int eventId = 0;
  bool holdFirstCatalog = false;
  int catalogReads = 0;
  final firstCatalog = Completer<http.Response>();

  http.Response catalog(String current, {bool includeOps = true}) =>
      http.Response(
        jsonEncode({
          'boards': [
            {'slug': 'default', 'name': 'Main'},
            if (includeOps) {'slug': 'ops', 'name': 'Ops'},
          ],
          'current': current,
        }),
        200,
      );

  http.Response board(String title, {bool archived = false}) => http.Response(
    jsonEncode({
      'columns': [
        for (final status in ['todo', if (archived) 'archived'])
          {
            'name': status,
            'tasks': [
              {'id': status, 'title': '$title $status', 'status': status},
            ],
          },
      ],
    }),
    200,
  );

  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(events.close);
    final connection = SavedConnection(
      id: 'read-authority',
      label: 'Test',
      host: 'example.test',
      port: 443,
      apiKey: 'fixture-key',
      useHttps: true,
    );
    final client = KanbanClient(
      connection,
      dashboardClient: DashboardClient(
        host: 'example.test',
        manualToken: 'fixture-token',
        httpClientOverride: MockClient((request) async {
          if (request.url.path.endsWith('/kanban/board')) {
            final read = _Read(request.url);
            reads.add(read);
            if (reads.length == 1) return board('Initial');
            return read.response.future;
          }
          if (request.url.path.endsWith('/kanban/boards')) {
            catalogReads++;
            if (holdFirstCatalog && catalogReads == 1) {
              return firstCatalog.future;
            }
            return catalog(holdFirstCatalog ? 'ops' : 'default');
          }
          if (request.url.path.endsWith('/kanban/profiles')) {
            return http.Response('{"profiles":[]}', 200);
          }
          return http.Response('{}', 404);
        }),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('github'),
        home: TasksScreen(
          connection: connection,
          clientOverride: client,
          eventStreamOverride: events.stream,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Initial todo'), findsOneWidget);
    expect(reads, hasLength(1));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  Future<void> refresh(WidgetTester tester) async {
    await tapHeaderAction(
      tester,
      inBar: find.byTooltip('Refresh'),
      inMenu: find.byIcon(Icons.refresh_rounded),
    );
    await settle(tester);
  }

  Future<void> burst(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      events.add(KanbanEvent(id: ++eventId, taskId: 'todo', kind: 'updated'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
  }

  Future<void> selectBoard(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('kanban-board-selector')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(name).last);
    await settle(tester);
  }

  Future<void> filter(WidgetTester tester, String name) async {
    await tapHeaderAction(
      tester,
      inBar: find.byKey(const ValueKey('kanban-filter-button')),
      inMenu: find.byIcon(Icons.filter_alt_outlined),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(ValueKey('kanban-filter-$name')));
    await settle(tester);
  }

  Future<void> complete(
    WidgetTester tester,
    int index,
    String title, {
    bool archived = false,
  }) async {
    reads[index].response.complete(board(title, archived: archived));
    await settle(tester);
  }

  Future<void> fail(WidgetTester tester, int index) async {
    reads[index].response.completeError(Exception('Read failed'));
    await settle(tester);
  }
}

void main() {
  testWidgets('late catalog cannot overwrite selection from a newer load', (
    tester,
  ) async {
    final f = _Fixture()..holdFirstCatalog = true;
    await f.mount(tester);
    expect(f.catalogReads, 1);
    await f.refresh(tester);
    await f.complete(tester, 1, 'New');
    expect(f.catalogReads, 2);
    f.firstCatalog.complete(f.catalog('default', includeOps: false));
    await f.settle(tester);
    await f.refresh(tester);
    expect(f.reads.last.url.queryParameters['board'], 'ops');
    await f.complete(tester, 2, 'Ops');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'newest silent failure retains board and ends superseded loading',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.refresh(tester);
      await f.burst(tester);
      await f.fail(tester, 2);
      expect(find.text('Initial todo'), findsOneWidget);
      expect(find.byType(ConsoleLoader), findsNothing);
      expect(find.textContaining('Read failed'), findsNothing);
      await f.complete(tester, 1, 'Old');
      expect(find.text('Initial todo'), findsOneWidget);
      expect(find.text('Old todo'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'older load error cannot replace newer silent success or loading',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.refresh(tester);
      expect(find.byType(ConsoleLoader), findsWidgets);
      await f.burst(tester);
      expect(f.reads, hasLength(3));
      await f.complete(tester, 2, 'New');
      expect(find.text('New todo'), findsOneWidget);
      expect(find.byType(ConsoleLoader), findsNothing);
      await f.fail(tester, 1);
      expect(find.text('New todo'), findsOneWidget);
      expect(find.textContaining('Read failed'), findsNothing);
      expect(find.byType(ConsoleLoader), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('older silent success cannot clear newer load error', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await f.burst(tester);
    await f.refresh(tester);
    expect(f.reads, hasLength(3));
    await f.fail(tester, 2);
    expect(find.textContaining('Read failed'), findsWidgets);
    await f.complete(tester, 1, 'Old');
    expect(find.text('Old todo'), findsNothing);
    expect(find.textContaining('Read failed'), findsWidgets);
    expect(find.byType(ConsoleLoader), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('older load success cannot clear newer load error', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await f.selectBoard(tester, 'Ops');
    await f.selectBoard(tester, 'Main');
    expect(f.reads, hasLength(3));
    expect(f.reads[1].url.queryParameters['board'], 'ops');
    expect(f.reads[2].url.queryParameters['board'], 'default');
    await f.fail(tester, 2);
    await f.complete(tester, 1, 'Old');
    expect(find.textContaining('Read failed'), findsWidgets);
    expect(find.text('Old todo'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old board response cannot stop selected board loading', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await f.burst(tester);
    await f.selectBoard(tester, 'Ops');
    expect(f.reads, hasLength(3));
    await f.complete(tester, 1, 'Old');
    expect(find.byType(ConsoleLoader), findsWidgets);
    expect(find.text('Old todo'), findsNothing);
    await f.complete(tester, 2, 'Ops');
    expect(find.text('Ops todo'), findsOneWidget);
    expect(find.byType(ConsoleLoader), findsNothing);
    await f.burst(tester);
    expect(f.reads.last.url.queryParameters['board'], 'ops');
    await f.complete(tester, 3, 'Ops refreshed');
    expect(find.text('Ops refreshed todo'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('archived selection rejects a previous unfiltered response', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await f.burst(tester);
    await f.filter(tester, 'archived');
    expect(f.reads, hasLength(3));
    expect(f.reads[2].url.queryParameters['include_archived'], 'true');
    await f.complete(tester, 2, 'Archive', archived: true);
    expect(find.text('Archive archived'), findsOneWidget);
    await f.complete(tester, 1, 'Old');
    expect(find.text('Archive archived'), findsOneWidget);
    expect(find.text('Old todo'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'leaving archived while loading retains local board without stale publish',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.filter(tester, 'archived');
      expect(f.reads, hasLength(2));
      expect(find.byType(ConsoleLoader), findsWidgets);
      await f.filter(tester, 'all');
      expect(f.reads, hasLength(2), reason: 'clearing a filter is local');
      expect(find.text('Initial todo'), findsOneWidget);
      expect(find.byType(ConsoleLoader), findsNothing);
      await f.complete(tester, 1, 'Stale archive', archived: true);
      expect(find.text('Initial todo'), findsOneWidget);
      expect(find.textContaining('Stale archive'), findsNothing);
      await f.burst(tester);
      expect(
        f.reads.last.url.queryParameters['include_archived'],
        isNot('true'),
      );
      await f.complete(tester, 2, 'Current');
      expect(find.text('Current todo'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'disposal drops pending load and silent completions and debounce',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.refresh(tester);
      await f.burst(tester);
      expect(f.reads, hasLength(3));
      f.events.add(KanbanEvent(id: 99, taskId: 'todo', kind: 'updated'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await f.fail(tester, 1);
      await f.complete(tester, 2, 'Late');
      await tester.pump(const Duration(seconds: 2));
      expect(f.reads, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('burst waits exactly 450ms after the last event', (tester) async {
    final f = _Fixture();
    await f.mount(tester);
    for (var i = 0; i < 3; i++) {
      f.events.add(KanbanEvent(id: i + 1, taskId: 'todo', kind: 'updated'));
      await tester.pump();
      if (i < 2) await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 449));
    expect(f.reads, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(f.reads, hasLength(2));
    await f.complete(tester, 1, 'Updated');
    expect(find.text('Updated todo'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
