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

/// Issue #62: "Can't scroll in bot rooms or in kanban — it feels pinned in
/// place". The attached recording shows the Kanban task detail: dragging
/// over the objective or a comment moved only that text block while the
/// page itself stayed put. These tests drag every Kanban surface with a
/// real touch pointer, many cards and long text, and require the scroll
/// offset to move — also across a live board refresh.
void main() {
  final connection = SavedConnection(
    id: 'kanban-scroll-62',
    label: 'QA',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'test-key',
    useHttps: true,
  );

  const statuses = ['running', 'todo', 'blocked', 'review', 'done'];

  Map<String, dynamic> taskJson(String status, int i) => {
    'id': '$status-$i',
    'title': 'Task $status $i',
    'body': 'Card preview $i',
    'status': status,
    'assignee': 'worker',
  };

  final longBody = List.generate(
    60,
    (i) => 'Objective line $i: review the change and report back.',
  ).join('\n');

  final comments = [
    for (var i = 0; i < 16; i++)
      {
        'id': 'c$i',
        'author': 'reviewer',
        'body': List.generate(
          4,
          (l) => 'Comment $i paragraph $l with enough words to wrap.',
        ).join('\n'),
      },
  ];

  MockClient buildClient({required void Function() onBoardRead}) {
    return MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/plugins/kanban/board') {
        onBoardRead();
        return http.Response(
          jsonEncode({
            'columns': [
              for (final status in statuses)
                {
                  'name': status,
                  'tasks': [for (var i = 0; i < 12; i++) taskJson(status, i)],
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
      if (path == '/api/plugins/kanban/tasks/blocked-0') {
        return http.Response(
          jsonEncode({
            'task': {
              ...taskJson('blocked', 0),
              'body': longBody,
              'diagnostics': [
                {
                  'kind': 'stale_worker',
                  'severity': 'warning',
                  'title': 'Stale worker',
                  'detail': 'Diagnostic detail: the worker stopped reporting.',
                },
              ],
            },
            'comments': comments,
            'events': [
              for (var i = 0; i < 3; i++)
                {
                  'id': i + 1,
                  'kind': 'status_changed',
                  'payload': {'note': 'event $i'},
                },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
  }

  Future<StreamController<KanbanEvent>> pumpScreen(
    WidgetTester tester, {
    required void Function() onBoardRead,
    ScrollBehavior scrollBehavior = const MomentumScrollBehavior(),
  }) async {
    tester.view.physicalSize = const Size(412, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: buildClient(onBoardRead: onBoardRead),
    );
    final client = KanbanClient(connection, dashboardClient: dashboard);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        // Same scroll behaviour as the real app (`lib/main.dart`).
        scrollBehavior: scrollBehavior,
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
    await tester.pumpAndSettle();
    return events;
  }

  /// A finger drag in ten steps, like a real swipe: the first step crosses
  /// the touch slop and the rest must move the content.
  Future<void> drag(WidgetTester tester, Offset from, Offset step) async {
    final finger = await tester.startGesture(
      from,
      kind: PointerDeviceKind.touch,
    );
    for (var i = 0; i < 10; i++) {
      await finger.moveBy(step);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await finger.up();
    await tester.pumpAndSettle();
  }

  /// A live Kanban event: the screen debounces and silently reloads.
  Future<void> liveEvent(
    WidgetTester tester,
    StreamController<KanbanEvent> events,
  ) async {
    events.add(const KanbanEvent(id: 9, taskId: 'running-3', kind: 'updated'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  ScrollPosition positionOf(WidgetTester tester, Finder scrollView) => tester
      .state<ScrollableState>(
        find
            .descendant(of: scrollView, matching: find.byType(Scrollable))
            .first,
      )
      .position;

  /// The list view has no key of its own; it is the only vertical page
  /// Scrollable under the RefreshIndicator.
  Finder listView() => find.descendant(
    of: find.byType(RefreshIndicator),
    matching: find.byType(ListView),
  );

  testWidgets('la lista de tareas se desplaza al arrastrar y conserva el '
      'desplazamiento tras un evento en vivo', (tester) async {
    var boardReads = 0;
    final events = await pumpScreen(tester, onBoardRead: () => boardReads++);
    expect(boardReads, 1);

    final position = positionOf(tester, listView());
    expect(position.pixels, 0);
    expect(position.maxScrollExtent, greaterThan(1000));

    // Start the drag on a card, as a user does.
    await drag(
      tester,
      tester.getCenter(find.text('Task blocked 2')),
      const Offset(0, -30),
    );
    final afterDrag = position.pixels;
    expect(afterDrag, greaterThan(150), reason: 'the list must scroll');

    await liveEvent(tester, events);
    expect(boardReads, 2, reason: 'the live event must reload the board');
    expect(
      positionOf(tester, listView()).pixels,
      afterDrag,
      reason: 'a silent reload must keep the reading position',
    );

    // Still scrollable after the reload.
    await drag(tester, const Offset(206, 600), const Offset(0, -30));
    expect(positionOf(tester, listView()).pixels, greaterThan(afterDrag + 150));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tirar hacia abajo en la lista refresca y no bloquea el '
      'desplazamiento', (tester) async {
    var boardReads = 0;
    await pumpScreen(tester, onBoardRead: () => boardReads++);

    await drag(tester, const Offset(206, 300), const Offset(0, 30));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(boardReads, 2, reason: 'pull-to-refresh must reload the board');
    expect(positionOf(tester, listView()).pixels, 0);

    await drag(tester, const Offset(206, 600), const Offset(0, -30));
    expect(positionOf(tester, listView()).pixels, greaterThan(150));
    expect(tester.takeException(), isNull);
  });

  testWidgets('el tablero desplaza columnas en vertical y el tablero en '
      'horizontal sin robarse el gesto', (tester) async {
    var boardReads = 0;
    final events = await pumpScreen(tester, onBoardRead: () => boardReads++);
    await tester.tap(find.byKey(const ValueKey('kanban-view-board')));
    await tester.pumpAndSettle();

    final columns = find.byKey(const ValueKey('kanban-board-columns'));
    Finder firstColumn() =>
        find.byKey(const ValueKey('kanban-board-column-attention'));
    final horizontal = positionOf(tester, columns);
    expect(horizontal.maxScrollExtent, greaterThan(300));

    // Vertical drag that starts on a card inside the first column.
    await drag(
      tester,
      tester.getCenter(find.text('Task blocked 1')),
      const Offset(0, -30),
    );
    final columnOffset = positionOf(tester, firstColumn()).pixels;
    expect(columnOffset, greaterThan(150), reason: 'the column must scroll');
    expect(horizontal.pixels, 0, reason: 'a vertical drag stays vertical');

    // Horizontal drag across the board.
    await drag(tester, const Offset(200, 500), const Offset(-25, 0));
    final boardOffset = horizontal.pixels;
    expect(boardOffset, greaterThan(100), reason: 'the board must scroll');
    expect(
      positionOf(tester, firstColumn()).pixels,
      columnOffset,
      reason: 'a horizontal drag must not move the column',
    );

    await liveEvent(tester, events);
    expect(boardReads, 2);
    expect(positionOf(tester, columns).pixels, boardOffset);
    expect(positionOf(tester, firstColumn()).pixels, columnOffset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el detalle de la tarea se desplaza al arrastrar sobre el '
      'objetivo y sobre un comentario', (tester) async {
    var boardReads = 0;
    final events = await pumpScreen(tester, onBoardRead: () => boardReads++);
    await tester.tap(find.text('Task blocked 0'));
    await tester.pumpAndSettle();

    final page = find.byKey(const ValueKey('kanban-task-detail-rich'));
    expect(page, findsOneWidget);

    // Read the whole objective, as in the recording.
    final toggle = find.byKey(const ValueKey('hermes-text-block-toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final position = positionOf(tester, page);
    final start = position.pixels;
    final body = find.byKey(const ValueKey('hermes-text-block-text'));
    final bodyRect = tester.getRect(body);
    final onBody = Offset(
      bodyRect.center.dx,
      (bodyRect.top.clamp(0.0, 860.0) + 700.0) / 2,
    );
    expect(tester.hitTestOnBinding(onBody).path.isNotEmpty, isTrue);
    await drag(tester, onBody, const Offset(0, -30));
    expect(
      position.pixels,
      greaterThan(start + 150),
      reason: 'dragging the objective text must scroll the page',
    );

    // Open the comments and drag starting on a selectable comment body.
    final commentsRow = find.byKey(const ValueKey('kanban-detail-comments'));
    await tester.ensureVisible(commentsRow);
    await tester.pumpAndSettle();
    await tester.tap(commentsRow);
    await tester.pumpAndSettle();
    final comment = find.byType(SelectableText).first;
    await tester.ensureVisible(comment);
    await tester.pumpAndSettle();
    final beforeComment = position.pixels;
    expect(position.maxScrollExtent - beforeComment, greaterThan(400));
    await drag(tester, tester.getCenter(comment), const Offset(0, -30));
    final afterComment = position.pixels;
    expect(
      afterComment,
      greaterThan(beforeComment + 150),
      reason: 'dragging a comment must scroll the page, not the comment',
    );

    // A live board event while the detail is open keeps the position.
    await liveEvent(tester, events);
    expect(boardReads, 2);
    expect(positionOf(tester, page).pixels, afterComment);
    expect(tester.takeException(), isNull);
  });

  testWidgets('los textos seleccionables del detalle nunca se quedan el '
      'arrastre, aunque el comportamiento de scroll acepte todo', (
    tester,
  ) async {
    // Up to 1.2.13 the app behaviour let every scrollable accept a drag,
    // including the one inside each SelectableText: the drag moved the
    // text and the page stayed pinned (the recording in #62). The detail
    // must not depend on the app-wide behaviour to stay scrollable.
    await pumpScreen(
      tester,
      onBoardRead: () {},
      scrollBehavior: const _EveryScrollableDraggable(),
    );
    await tester.tap(find.text('Task blocked 0'));
    await tester.pumpAndSettle();
    final page = find.byKey(const ValueKey('kanban-task-detail-rich'));
    final toggle = find.byKey(const ValueKey('hermes-text-block-toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    for (final section in const [
      'kanban-detail-events',
      'kanban-detail-diagnostics',
      'kanban-detail-comments',
    ]) {
      final row = find.byKey(ValueKey(section));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    Finder selectable(String contains) => find.byWidgetPredicate(
      (w) => w is SelectableText && (w.data ?? '').contains(contains),
    );
    final position = positionOf(tester, page);
    for (final target in [
      selectable('note=event 1'),
      selectable('Diagnostic detail'),
      selectable('Comment 0 paragraph'),
    ]) {
      expect(target, findsOneWidget);
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      final before = position.pixels;
      expect(before, greaterThan(300), reason: 'room to scroll back');
      // Scroll back up (finger moves down), as the user tried to.
      await drag(tester, tester.getCenter(target), const Offset(0, 30));
      expect(
        position.pixels,
        lessThan(before - 150),
        reason: 'dragging $target must scroll the page',
      );
    }
    expect(tester.takeException(), isNull);
  });
}

/// The scroll behaviour shipped up to 1.2.13: every Scrollable, nested or
/// not, always accepts a drag.
class _EveryScrollableDraggable extends MaterialScrollBehavior {
  const _EveryScrollableDraggable();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}
