// Cron section of the launcher widgets: the scheduled jobs of one connection
// with their next run and how the last one went. Written as ONE atomic JSON
// string under [LauncherWidgetCronSnapshot.storageKey] by whoever just read
// the jobs from the server (the Cron screen, or the background listener's own
// cron pass); the Android widget only reads it. Secret-free: opaque ids,
// public job names and times.
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How a job's last run ended, as far as the server said.
enum LauncherWidgetCronResult { none, ok, failed, running }

@immutable
class LauncherWidgetCronJob {
  const LauncherWidgetCronJob({
    required this.id,
    required this.name,
    required this.profile,
    this.nextRunAtMs,
    this.lastRunAtMs,
    this.last = LauncherWidgetCronResult.none,
    this.paused = false,
    this.openPayload,
  });

  final String id;
  final String name;

  /// Profile that owns the job (`default` for the server's own store).
  final String profile;

  /// Null when the job has no next run (paused, a one-shot already run).
  final int? nextRunAtMs;
  final int? lastRunAtMs;
  final LauncherWidgetCronResult last;
  final bool paused;

  /// Deep link to the job in the app (a `NotificationOpen` payload); null
  /// when the job cannot be addressed, and a tap then opens the app.
  final String? openPayload;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'profile': profile,
    'next_ms': ?nextRunAtMs,
    'last_ms': ?lastRunAtMs,
    'last': last.name,
    if (paused) 'paused': true,
    'open': ?openPayload,
  };

  static LauncherWidgetCronJob? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = _text(value['id'], 256);
    final name = _text(value['name'], 120);
    if (id == null || name == null) return null;
    final last = value['last'];
    return LauncherWidgetCronJob(
      id: id,
      name: name,
      profile: _text(value['profile'], 64) ?? 'default',
      nextRunAtMs: _positiveInt(value['next_ms']),
      lastRunAtMs: _positiveInt(value['last_ms']),
      last: LauncherWidgetCronResult.values.firstWhere(
        (result) => result.name == last,
        orElse: () => LauncherWidgetCronResult.none,
      ),
      paused: value['paused'] == true,
      openPayload: _text(value['open'], 4000),
    );
  }
}

@immutable
class LauncherWidgetCronSnapshot {
  const LauncherWidgetCronSnapshot({
    required this.connectionId,
    required this.updatedAtMs,
    required this.jobs,
  });

  static const storageKey = 'hermes_widget_cron_v1';
  static const schemaVersion = 1;

  /// More than the largest widget ever draws; bounds the stored string.
  static const maxJobs = 24;

  final String connectionId;

  /// When these jobs were read from the server.
  final int updatedAtMs;
  final List<LauncherWidgetCronJob> jobs;

  /// Jobs as the widget lists them: by next run, jobs without one last.
  static List<LauncherWidgetCronJob> ordered(
    Iterable<LauncherWidgetCronJob> jobs,
  ) {
    final sorted = jobs.toList()
      ..sort((a, b) {
        final an = a.nextRunAtMs, bn = b.nextRunAtMs;
        if (an != null && bn != null && an != bn) return an.compareTo(bn);
        if (an == null && bn != null) return 1;
        if (an != null && bn == null) return -1;
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    if (sorted.length <= maxJobs) return sorted;
    // A failed job is never the one that falls off the end.
    final kept = sorted.take(maxJobs).toList();
    final dropped = sorted.skip(maxJobs);
    for (final failed in dropped.where(
      (job) => job.last == LauncherWidgetCronResult.failed,
    )) {
      final replace = kept.lastIndexWhere(
        (job) => job.last != LauncherWidgetCronResult.failed,
      );
      if (replace < 0) break;
      kept[replace] = failed;
    }
    return kept;
  }

  /// This listing applied on top of [previous].
  ///
  /// A listing of every profile ([profile] null) replaces everything. A
  /// listing of one profile only replaces that profile's jobs, so opening
  /// one profile's Cron screen does not make the others disappear from the
  /// widget; jobs of another connection are never kept.
  factory LauncherWidgetCronSnapshot.merged({
    required LauncherWidgetCronSnapshot? previous,
    required String connectionId,
    required int nowMs,
    required List<LauncherWidgetCronJob> listed,
    required String? profile,
  }) {
    final others = profile == null || previous?.connectionId != connectionId
        ? const <LauncherWidgetCronJob>[]
        : previous!.jobs.where((job) => job.profile != profile);
    return LauncherWidgetCronSnapshot(
      connectionId: connectionId,
      updatedAtMs: nowMs,
      jobs: ordered([...others, ...listed]),
    );
  }

  int get failedCount =>
      jobs.where((job) => job.last == LauncherWidgetCronResult.failed).length;

  /// Everything but the time of the read: equal content is not rewritten.
  String get content => jsonEncode({
    'conn_id': connectionId,
    'jobs': [for (final job in jobs) job.toJson()],
  });

  String encode() => jsonEncode({
    'schema_version': schemaVersion,
    'conn_id': connectionId,
    'updated_at_ms': updatedAtMs,
    'jobs': [for (final job in jobs.take(maxJobs)) job.toJson()],
  });

  /// Null for anything that is not a snapshot of this schema.
  static LauncherWidgetCronSnapshot? tryDecode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['schema_version'] != schemaVersion) {
        return null;
      }
      final connectionId = _text(decoded['conn_id'], 256);
      if (connectionId == null) return null;
      final jobs = decoded['jobs'];
      return LauncherWidgetCronSnapshot(
        connectionId: connectionId,
        updatedAtMs: _positiveInt(decoded['updated_at_ms']) ?? 0,
        jobs: [
          if (jobs is List)
            for (final job in jobs.take(maxJobs))
              ?LauncherWidgetCronJob.fromJson(job),
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

int? _positiveInt(Object? value) {
  if (value is int) return value > 0 ? value : null;
  if (value is num && value.isFinite && value > 0) return value.round();
  return null;
}
