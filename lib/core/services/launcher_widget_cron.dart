// Feeds the Cron launcher widget from job listings the app ALREADY makes: the
// Cron screen, and the background listener's own cron pass. It never makes a
// request, a timer or a wake-up of its own.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cron_job.dart';
import '../models/launcher_widget_cron.dart';
import 'connection_manager.dart';
import 'notifications/notification_service.dart' show NotificationOpen;

/// Android receiver of the Cron launcher widget.
const launcherWidgetCronProvider =
    'com.hermesagent.hermes_android.HermesCronWidgetProvider';

/// Where the section is kept and how its widget is asked to redraw.
abstract interface class LauncherWidgetSectionStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> redraw(String qualifiedAndroidName);
}

class PluginLauncherWidgetSectionStore implements LauncherWidgetSectionStore {
  const PluginLauncherWidgetSectionStore();

  @override
  Future<String?> read(String key) => HomeWidget.getWidgetData<String>(key);

  @override
  Future<void> write(String key, String value) async {
    await HomeWidget.saveWidgetData<String>(key, value);
  }

  @override
  Future<void> redraw(String qualifiedAndroidName) async {
    await HomeWidget.updateWidget(qualifiedAndroidName: qualifiedAndroidName);
  }
}

/// A server time (`2026-10-12T17:00:00+02:00`, epoch seconds or epoch
/// milliseconds) as epoch milliseconds; null when it is not a time.
int? launcherWidgetEpochMs(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    if (!raw.isFinite || raw <= 0) return null;
    // Seconds until the year 2286 are below 1e10; anything above is ms.
    return raw < 1e11 ? (raw * 1000).round() : raw.round();
  }
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  final number = num.tryParse(text);
  if (number != null) return launcherWidgetEpochMs(number);
  return DateTime.tryParse(text)?.millisecondsSinceEpoch;
}

/// How the job's last run ended. Same rule as the in-app Home board: the
/// `error` state or an error/failed last status is a failure.
LauncherWidgetCronResult launcherWidgetCronResult(CronJob job) {
  final status = job.lastStatus.trim().toLowerCase();
  if (job.state == CronJobState.error ||
      const {
        'error',
        'failed',
        'failure',
        'delivery_failed',
      }.contains(status)) {
    return LauncherWidgetCronResult.failed;
  }
  if (job.state == CronJobState.running ||
      const {'running', 'started', 'queued'}.contains(status)) {
    return LauncherWidgetCronResult.running;
  }
  if (status.isEmpty) return LauncherWidgetCronResult.none;
  return LauncherWidgetCronResult.ok;
}

LauncherWidgetCronJob launcherWidgetCronJob(String connectionId, CronJob job) {
  // Where the job was listed from, else its bot owner; a job nobody can
  // place still shows, under the default store, and opens without a profile.
  final owner = job.targetProfile;
  final open = NotificationOpen(
    connId: connectionId,
    jobId: job.id,
    profile: owner == null || owner == 'default' ? null : owner,
  ).toPayload();
  return LauncherWidgetCronJob(
    id: job.id,
    name: job.title,
    profile: owner ?? 'default',
    nextRunAtMs: job.isPaused ? null : launcherWidgetEpochMs(job.nextRunAt),
    lastRunAtMs: launcherWidgetEpochMs(job.lastRunAt),
    last: launcherWidgetCronResult(job),
    paused: job.isPaused,
    // Only a payload the app would accept back; otherwise a tap opens the app.
    openPayload: NotificationOpen.tryParse(open) == null ? null : open,
  );
}

/// The connection the widgets show: the last one opened, else the default.
/// Null means "no preference": the first listing wins.
Future<String?> launcherWidgetPreferredConnection() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(ConnectionManager.lastConnKey) ??
      prefs.getString(ConnectionManager.defaultConnKey);
}

/// Serial owner of the Cron section. One per isolate; the stored string is
/// replaced whole, so the app and the listener can both publish.
class LauncherWidgetCronPublisher {
  LauncherWidgetCronPublisher({
    this.store = const PluginLauncherWidgetSectionStore(),
    int Function()? nowMs,
    Future<String?> Function()? preferredConnection,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _preferredConnection =
           preferredConnection ?? launcherWidgetPreferredConnection;

  static final LauncherWidgetCronPublisher instance =
      LauncherWidgetCronPublisher();

  /// Unchanged jobs are still re-stamped this often, so the widget keeps
  /// knowing its data is current.
  static const restampAfter = Duration(minutes: 5);

  final LauncherWidgetSectionStore store;
  final int Function() _nowMs;
  final Future<String?> Function() _preferredConnection;
  Future<void> _tail = Future<void>.value();

  /// Offers the jobs just listed for [connectionId].
  ///
  /// [profile] is the single profile the listing covers, or null when it
  /// covers every profile. Never throws: a widget must not break the screen
  /// or the listener pass that fed it.
  Future<void> offer({
    required String connectionId,
    required List<CronJob> jobs,
    required String? profile,
  }) {
    final operation = _tail.then((_) async {
      try {
        await _publish(connectionId, jobs, profile);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[launcher-widget] cron (${error.runtimeType})');
        }
      }
    });
    _tail = operation;
    return operation;
  }

  Future<void> _publish(
    String connectionId,
    List<CronJob> jobs,
    String? profile,
  ) async {
    final preferred = await _preferredConnection();
    final previous = LauncherWidgetCronSnapshot.tryDecode(
      await store.read(LauncherWidgetCronSnapshot.storageKey),
    );
    if (preferred != null &&
        preferred != connectionId &&
        previous?.connectionId == preferred) {
      // Another connection's listing: the widget stays on the one in use.
      return;
    }
    final now = _nowMs();
    final next = LauncherWidgetCronSnapshot.merged(
      previous: previous,
      connectionId: connectionId,
      nowMs: now,
      listed: [
        for (final job in jobs)
          if (job.id.isNotEmpty) launcherWidgetCronJob(connectionId, job),
      ],
      profile: profile,
    );
    final unchanged = previous != null && previous.content == next.content;
    if (unchanged && now - previous.updatedAtMs < restampAfter.inMilliseconds) {
      return;
    }
    await store.write(LauncherWidgetCronSnapshot.storageKey, next.encode());
    await store.redraw(launcherWidgetCronProvider);
  }

  Future<void> flush() => _tail;
}

/// Wraps the Dashboard read the listener already makes for cron
/// notifications, so the same response also feeds the Cron widget.
Future<Map<String, dynamic>> Function(String endpoint) launcherWidgetCronTap(
  String connectionId,
  Future<Map<String, dynamic>> Function(String endpoint) apiGet, {
  LauncherWidgetCronPublisher? publisher,
}) => (endpoint) async {
  final data = await apiGet(endpoint);
  try {
    final raw = data['jobs'] ?? data['data'];
    if (raw is List && endpoint.split('?').first == 'cron/jobs') {
      unawaited(
        (publisher ?? LauncherWidgetCronPublisher.instance).offer(
          connectionId: connectionId,
          jobs: [
            for (final job in raw)
              if (job is Map) CronJob.fromJson(job.cast<String, dynamic>()),
          ],
          // Both forms of this read (`?profile=all`, or the unscoped one of
          // older servers) are everything that server lists.
          profile: null,
        ),
      );
    }
  } catch (_) {
    // The listener's own use of the response is never affected.
  }
  return data;
};
