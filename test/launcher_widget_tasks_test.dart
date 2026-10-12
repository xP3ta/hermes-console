import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/launcher_widget_tasks.dart';
import 'package:hermes_android/core/services/launcher_widget_cron.dart'
    show LauncherWidgetSectionStore;
import 'package:hermes_android/core/services/launcher_widget_tasks.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';

class _Store implements LauncherWidgetSectionStore {
  final values = <String, String>{};
  final redraws = <String>[];
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('launcher unavailable');
    values[key] = value;
  }

  @override
  Future<void> redraw(String qualifiedAndroidName) async {
    redraws.add(qualifiedAndroidName);
  }
}

KanbanTask _task(
  String id,
  String status, {
  String? title,
  String? assignee,
  String? blockReason,
}) => KanbanTask(
  id: id,
  title: title ?? 'Task $id',
  body: '',
  status: status,
  assignee: assignee,
  blockReason: blockReason,
);

const _t0 = 1760000000000;

void main() {
  group('a card as the widget tells it', () {
    test(
      'in progress, waiting for you, pending; done cards are not listed',
      () {
        expect(
          launcherWidgetTaskState(_task('a', 'running', assignee: 'forja')),
          LauncherWidgetTaskState.running,
        );
        for (final status in ['blocked', 'review']) {
          expect(
            launcherWidgetTaskState(_task('a', status)),
            LauncherWidgetTaskState.attention,
            reason: status,
          );
        }
        for (final status in ['triage', 'todo', 'scheduled', 'ready']) {
          expect(
            launcherWidgetTaskState(_task('a', status)),
            LauncherWidgetTaskState.pending,
            reason: status,
          );
          expect(
            launcherWidgetTaskState(_task('a', status, assignee: 'forja')),
            LauncherWidgetTaskState.pending,
            reason: '$status, assigned',
          );
        }
        for (final status in ['done', 'archived']) {
          expect(launcherWidgetTaskState(_task('a', status)), isNull);
        }
      },
    );

    test('it carries its title, who has it and a link the app accepts', () {
      final card = launcherWidgetTask(
        'conn-1',
        _task('t-7', 'running', title: ' Publicar 1.2.15 ', assignee: 'forja'),
      )!;
      expect(card.title, 'Publicar 1.2.15');
      expect(card.assignee, 'forja');
      expect(card.state, LauncherWidgetTaskState.running);
      final open = NotificationOpen.tryParse(card.openPayload)!;
      expect(open.connId, 'conn-1');
      expect(open.taskId, 't-7');
      expect(open.sessionId, isEmpty);
      // Nothing to list: no title, no id, or already done.
      expect(launcherWidgetTask('c', _task('x', 'todo', title: '  ')), isNull);
      expect(launcherWidgetTask('c', _task('', 'todo')), isNull);
      expect(launcherWidgetTask('c', _task('x', 'done')), isNull);
    });
  });

  group('the stored section', () {
    LauncherWidgetTask card(String id, LauncherWidgetTaskState state) =>
        LauncherWidgetTask(id: id, title: 'Task $id', state: state);

    test('in progress first, then waiting for you, then pending', () {
      final snapshot = LauncherWidgetTasksSnapshot.of(
        connectionId: 'conn-1',
        nowMs: _t0,
        open: [
          card('p1', LauncherWidgetTaskState.pending),
          card('r1', LauncherWidgetTaskState.running),
          card('a1', LauncherWidgetTaskState.attention),
          card('p2', LauncherWidgetTaskState.pending),
          card('r2', LauncherWidgetTaskState.running),
        ],
      );
      // The board's own order is kept inside each group.
      expect(snapshot.tasks.map((t) => t.id), ['r1', 'r2', 'a1', 'p1', 'p2']);
      expect(snapshot.runningCount, 2);
      expect(snapshot.attentionCount, 1);
      expect(snapshot.pendingCount, 2);
    });

    test('the counts are the board\'s, whatever fits in the list', () {
      final snapshot = LauncherWidgetTasksSnapshot.of(
        connectionId: 'conn-1',
        nowMs: _t0,
        open: [
          for (var i = 0; i < 30; i++)
            card('p$i', LauncherWidgetTaskState.pending),
          card('r', LauncherWidgetTaskState.running),
        ],
      );
      expect(snapshot.tasks, hasLength(LauncherWidgetTasksSnapshot.maxTasks));
      expect(snapshot.tasks.first.id, 'r');
      expect(snapshot.pendingCount, 30);
      expect(snapshot.runningCount, 1);
    });

    test('it survives a round trip and is versioned', () {
      final snapshot = LauncherWidgetTasksSnapshot.of(
        connectionId: 'conn-1',
        nowMs: _t0,
        open: const [
          LauncherWidgetTask(
            id: 'r',
            title: 'Publicar 1.2.15',
            state: LauncherWidgetTaskState.running,
            assignee: 'forja',
            openPayload: '{"conn":"conn-1","tid":"r","surface":"normal"}',
          ),
          LauncherWidgetTask(
            id: 'p',
            title: 'Notas de la versión',
            state: LauncherWidgetTaskState.pending,
          ),
        ],
      );
      final decoded = LauncherWidgetTasksSnapshot.tryDecode(snapshot.encode())!;
      expect(decoded.content, snapshot.content);
      expect(decoded.updatedAtMs, _t0);
      expect(decoded.tasks.first.assignee, 'forja');
      expect(decoded.tasks.last.assignee, isNull);
      expect(jsonDecode(snapshot.encode())['schema_version'], 1);
      expect(LauncherWidgetTasksSnapshot.storageKey, 'hermes_widget_tasks_v1');
    });

    test('anything that is not this schema reads as nothing, never throws', () {
      for (final raw in <Object?>[
        null,
        '',
        'not json',
        '[]',
        '{"schema_version":2,"conn_id":"c","tasks":[]}',
        '{"schema_version":1,"tasks":[]}',
        7,
      ]) {
        expect(
          LauncherWidgetTasksSnapshot.tryDecode(raw),
          isNull,
          reason: '$raw',
        );
      }
      final tolerant = LauncherWidgetTasksSnapshot.tryDecode(
        jsonEncode({
          'schema_version': 1,
          'conn_id': 'c',
          'running': -3,
          'pending': 'many',
          'later_field': true,
          'tasks': [
            {'id': 'ok', 'title': 'Bien', 'state': 'a-new-word'},
            {'id': 'no-title'},
            'nonsense',
          ],
        }),
      )!;
      expect(tolerant.tasks.map((t) => t.id), ['ok']);
      // An unknown state is the plainest one, and bad counts are zero.
      expect(tolerant.tasks.single.state, LauncherWidgetTaskState.pending);
      expect(tolerant.runningCount, 0);
      expect(tolerant.pendingCount, 0);
    });
  });

  group('publishing', () {
    late _Store store;
    late int now;
    String? preferred;

    LauncherWidgetTasksPublisher publisher() => LauncherWidgetTasksPublisher(
      store: store,
      nowMs: () => now,
      preferredConnection: () async => preferred,
    );

    LauncherWidgetTasksSnapshot? stored() =>
        LauncherWidgetTasksSnapshot.tryDecode(
          store.values[LauncherWidgetTasksSnapshot.storageKey],
        );

    setUp(() {
      store = _Store();
      now = _t0;
      preferred = null;
    });

    test('a board is written once and its widget asked to redraw', () async {
      final p = publisher();
      await p.offer(
        connectionId: 'conn-1',
        tasks: [
          _task('done', 'done'),
          _task('p', 'todo'),
          _task('r', 'running', assignee: 'forja'),
        ],
      );
      expect(stored()!.tasks.map((t) => t.id), ['r', 'p']);
      expect(store.redraws, [launcherWidgetTasksProvider]);
      expect(
        launcherWidgetTasksProvider,
        'com.hermesagent.hermes_android.HermesTasksWidgetProvider',
      );
    });

    test(
      'the same board is not rewritten, only re-stamped every 5 min',
      () async {
        final p = publisher();
        final board = [_task('r', 'running', assignee: 'forja')];
        await p.offer(connectionId: 'conn-1', tasks: board);
        for (var minute = 1; minute < 5; minute++) {
          now = _t0 + minute * 60000;
          await p.offer(connectionId: 'conn-1', tasks: board);
        }
        expect(store.redraws, hasLength(1));
        now = _t0 + 5 * 60000;
        await p.offer(connectionId: 'conn-1', tasks: board);
        expect(store.redraws, hasLength(2));
        expect(stored()!.updatedAtMs, now);
        // A card that finished is a change: it goes out at once.
        now += 1000;
        await p.offer(connectionId: 'conn-1', tasks: [_task('r', 'done')]);
        expect(store.redraws, hasLength(3));
        expect(stored()!.tasks, isEmpty);
      },
    );

    test('the widget stays on the connection in use', () async {
      final p = publisher();
      preferred = 'conn-1';
      await p.offer(connectionId: 'conn-1', tasks: [_task('mine', 'todo')]);
      await p.offer(connectionId: 'conn-2', tasks: [_task('other', 'todo')]);
      expect(stored()!.connectionId, 'conn-1');
      expect(stored()!.tasks.single.id, 'mine');
    });

    test('a launcher that cannot be written never breaks the caller', () async {
      final p = publisher();
      store.failWrites = true;
      await p.offer(connectionId: 'conn-1', tasks: [_task('a', 'todo')]);
      expect(stored(), isNull);
      store.failWrites = false;
      await p.offer(connectionId: 'conn-1', tasks: [_task('a', 'todo')]);
      expect(stored()!.tasks.single.id, 'a');
    });
  });

  test('it rides the two board reads that exist and adds none', () {
    final service = File(
      'lib/core/services/launcher_widget_tasks.dart',
    ).readAsStringSync();
    for (final forbidden in [
      'Timer(',
      'Timer.periodic',
      'package:http',
      'apiGet',
      'getBoard',
      'FlutterForegroundTask',
    ]) {
      expect(service, isNot(contains(forbidden)), reason: forbidden);
    }
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    // The listener's change: the board it has just read is offered.
    expect(
      listener,
      contains(
        '      unawaited(\n'
        '        LauncherWidgetTasksPublisher.instance.offer(\n'
        '          connectionId: connection.id,\n'
        '          tasks: tasks,\n'
        '        ),\n'
        '      );',
      ),
    );
    expect('LauncherWidgetTasksPublisher'.allMatches(listener), hasLength(1));
    final screen = File(
      'lib/core/screens/tasks_screen.dart',
    ).readAsStringSync();
    expect('_offerToLauncherWidget(board);'.allMatches(screen), hasLength(2));
  });
}
