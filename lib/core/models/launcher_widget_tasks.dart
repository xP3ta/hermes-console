// Tareas section of the launcher widgets: the open cards of one Kanban board,
// the ones in progress first. Written as ONE atomic JSON string under
// [LauncherWidgetTasksSnapshot.storageKey] by whoever just read the board
// (the Tareas screen, or the background listener's own Kanban pass); the
// Android widget only reads it. Secret-free: opaque ids, public titles.
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Where a card stands, as the widget tells it apart.
enum LauncherWidgetTaskState {
  /// A worker is on it.
  running,

  /// It waits for the owner (blocked, or in review).
  attention,

  /// It is waiting its turn.
  pending,
}

@immutable
class LauncherWidgetTask {
  const LauncherWidgetTask({
    required this.id,
    required this.title,
    required this.state,
    this.assignee,
    this.openPayload,
  });

  final String id;
  final String title;
  final LauncherWidgetTaskState state;

  /// Who has it (a profile's name), when somebody does.
  final String? assignee;

  /// Deep link to the card in the app (a `NotificationOpen` payload); null
  /// when it cannot be addressed, and a tap then opens the app.
  final String? openPayload;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'state': state.name,
    'assignee': ?assignee,
    'open': ?openPayload,
  };

  static LauncherWidgetTask? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = _text(value['id'], 256);
    final title = _text(value['title'], 120);
    if (id == null || title == null) return null;
    final state = value['state'];
    return LauncherWidgetTask(
      id: id,
      title: title,
      state: LauncherWidgetTaskState.values.firstWhere(
        (candidate) => candidate.name == state,
        orElse: () => LauncherWidgetTaskState.pending,
      ),
      assignee: _text(value['assignee'], 64),
      openPayload: _text(value['open'], 4000),
    );
  }
}

@immutable
class LauncherWidgetTasksSnapshot {
  const LauncherWidgetTasksSnapshot({
    required this.connectionId,
    required this.updatedAtMs,
    required this.tasks,
    this.runningCount = 0,
    this.attentionCount = 0,
    this.pendingCount = 0,
  });

  static const storageKey = 'hermes_widget_tasks_v1';
  static const schemaVersion = 1;

  /// More than the largest widget ever draws; bounds the stored string.
  static const maxTasks = 12;

  final String connectionId;

  /// When the board was read from the server.
  final int updatedAtMs;

  /// Open cards, in progress first, then the ones that wait for the owner,
  /// then the pending ones; at most [maxTasks].
  final List<LauncherWidgetTask> tasks;

  /// Counts over the WHOLE board, not only the cards kept in [tasks].
  final int runningCount;
  final int attentionCount;
  final int pendingCount;

  /// The open cards of a board in the widget's order, with the board's
  /// counts. The order inside each group is the board's own.
  factory LauncherWidgetTasksSnapshot.of({
    required String connectionId,
    required int nowMs,
    required Iterable<LauncherWidgetTask> open,
  }) {
    final all = open.toList();
    List<LauncherWidgetTask> of(LauncherWidgetTaskState state) => [
      for (final task in all)
        if (task.state == state) task,
    ];
    final running = of(LauncherWidgetTaskState.running);
    final attention = of(LauncherWidgetTaskState.attention);
    final pending = of(LauncherWidgetTaskState.pending);
    return LauncherWidgetTasksSnapshot(
      connectionId: connectionId,
      updatedAtMs: nowMs,
      tasks: [...running, ...attention, ...pending].take(maxTasks).toList(),
      runningCount: running.length,
      attentionCount: attention.length,
      pendingCount: pending.length,
    );
  }

  /// Everything but the time of the read: equal content is not rewritten.
  String get content => jsonEncode({
    'conn_id': connectionId,
    'running': runningCount,
    'attention': attentionCount,
    'pending': pendingCount,
    'tasks': [for (final task in tasks) task.toJson()],
  });

  String encode() => jsonEncode({
    'schema_version': schemaVersion,
    'conn_id': connectionId,
    'updated_at_ms': updatedAtMs,
    'running': runningCount,
    'attention': attentionCount,
    'pending': pendingCount,
    'tasks': [for (final task in tasks.take(maxTasks)) task.toJson()],
  });

  /// Null for anything that is not a snapshot of this schema.
  static LauncherWidgetTasksSnapshot? tryDecode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['schema_version'] != schemaVersion) {
        return null;
      }
      final connectionId = _text(decoded['conn_id'], 256);
      if (connectionId == null) return null;
      final tasks = decoded['tasks'];
      return LauncherWidgetTasksSnapshot(
        connectionId: connectionId,
        updatedAtMs: _count(decoded['updated_at_ms']),
        runningCount: _count(decoded['running']),
        attentionCount: _count(decoded['attention']),
        pendingCount: _count(decoded['pending']),
        tasks: [
          if (tasks is List)
            for (final task in tasks.take(maxTasks))
              ?LauncherWidgetTask.fromJson(task),
        ],
      );
    } on FormatException {
      return null;
    }
  }
}

String? _text(Object? value, int max) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
}

int _count(Object? value) {
  if (value is int) return value > 0 ? value : 0;
  if (value is num && value.isFinite && value > 0) return value.round();
  return 0;
}
