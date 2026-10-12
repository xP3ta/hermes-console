// Feeds the Tareas launcher widget from board reads the app ALREADY makes: the
// Tareas screen, and the background listener's own Kanban pass. It never
// makes a request, a timer or a wake-up of its own.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/kanban.dart';
import '../models/launcher_widget_tasks.dart';
import 'launcher_widget_cron.dart'
    show
        LauncherWidgetSectionStore,
        PluginLauncherWidgetSectionStore,
        launcherWidgetPreferredConnection;
import 'notifications/notification_service.dart' show NotificationOpen;

/// Android receiver of the Tareas launcher widget.
const launcherWidgetTasksProvider =
    'com.hermesagent.hermes_android.HermesTasksWidgetProvider';

/// Where an open card stands; null for one that is done or archived (the
/// widget only lists what is still to do). Same grouping as the Tareas
/// screen's own tray.
LauncherWidgetTaskState? launcherWidgetTaskState(KanbanTask task) =>
    switch (kanbanMobileGroupFor(task)) {
      KanbanMobileGroup.working => LauncherWidgetTaskState.running,
      KanbanMobileGroup.attention => LauncherWidgetTaskState.attention,
      KanbanMobileGroup.queued ||
      KanbanMobileGroup.notes => LauncherWidgetTaskState.pending,
      KanbanMobileGroup.done || KanbanMobileGroup.archived => null,
    };

LauncherWidgetTask? launcherWidgetTask(String connectionId, KanbanTask task) {
  final state = launcherWidgetTaskState(task);
  final title = task.title.trim();
  if (state == null || task.id.isEmpty || title.isEmpty) return null;
  final open = NotificationOpen(
    connId: connectionId,
    taskId: task.id,
  ).toPayload();
  final assignee = task.assignee?.trim() ?? '';
  return LauncherWidgetTask(
    id: task.id,
    title: title,
    state: state,
    assignee: assignee.isEmpty ? null : assignee,
    // Only a payload the app would accept back; otherwise a tap opens the app.
    openPayload: NotificationOpen.tryParse(open) == null ? null : open,
  );
}

/// Serial owner of the Tareas section. One per isolate; the stored string is
/// replaced whole, so the app and the listener can both publish.
class LauncherWidgetTasksPublisher {
  LauncherWidgetTasksPublisher({
    this.store = const PluginLauncherWidgetSectionStore(),
    int Function()? nowMs,
    Future<String?> Function()? preferredConnection,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _preferredConnection =
           preferredConnection ?? launcherWidgetPreferredConnection;

  static final LauncherWidgetTasksPublisher instance =
      LauncherWidgetTasksPublisher();

  /// An unchanged board is still re-stamped this often, so the widget keeps
  /// knowing its data is current.
  static const restampAfter = Duration(minutes: 5);

  final LauncherWidgetSectionStore store;
  final int Function() _nowMs;
  final Future<String?> Function() _preferredConnection;
  Future<void> _tail = Future<void>.value();

  /// Offers the cards of the board just read for [connectionId]. Never
  /// throws: a widget must not break the screen or the listener pass that
  /// fed it.
  Future<void> offer({
    required String connectionId,
    required Iterable<KanbanTask> tasks,
  }) {
    final cards = tasks.toList(growable: false);
    final operation = _tail.then((_) async {
      try {
        await _publish(connectionId, cards);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[launcher-widget] tasks (${error.runtimeType})');
        }
      }
    });
    _tail = operation;
    return operation;
  }

  Future<void> _publish(String connectionId, List<KanbanTask> tasks) async {
    final preferred = await _preferredConnection();
    final previous = LauncherWidgetTasksSnapshot.tryDecode(
      await store.read(LauncherWidgetTasksSnapshot.storageKey),
    );
    if (preferred != null &&
        preferred != connectionId &&
        previous?.connectionId == preferred) {
      // Another connection's board: the widget stays on the one in use.
      return;
    }
    final now = _nowMs();
    final next = LauncherWidgetTasksSnapshot.of(
      connectionId: connectionId,
      nowMs: now,
      open: [for (final task in tasks) ?launcherWidgetTask(connectionId, task)],
    );
    final unchanged = previous != null && previous.content == next.content;
    if (unchanged && now - previous.updatedAtMs < restampAfter.inMilliseconds) {
      return;
    }
    await store.write(LauncherWidgetTasksSnapshot.storageKey, next.encode());
    await store.redraw(launcherWidgetTasksProvider);
  }

  Future<void> flush() => _tail;
}
