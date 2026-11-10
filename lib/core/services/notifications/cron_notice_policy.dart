import 'package:shared_preferences/shared_preferences.dart';

import 'notification_mute_store.dart';

/// Device-only policy. Per-job `all` inherits this global mode.
enum CronNoticeMode { automatic, all, failuresOnly, off }

abstract final class CronNoticePolicy {
  static const preferenceKey = 'notif_cron_mode_v1';
  static const successWindowMs = 60 * 60 * 1000;

  /// Read-only migration: an explicit old opt-out stays off; an untouched
  /// installation starts in Automatic. Never rewrite mute preferences.
  static CronNoticeMode read(SharedPreferences prefs) {
    final saved = prefs.getString(preferenceKey);
    for (final mode in CronNoticeMode.values) {
      if (mode.name == saved) return mode;
    }
    final old =
        prefs.getBool('notif_cron_results') ??
        prefs.getBool('notif_background_listen');
    return old == false ? CronNoticeMode.off : CronNoticeMode.automatic;
  }

  static bool allows(
    CronNoticeMode mode,
    CronNotifyPolicy jobPolicy, {
    required bool ok,
  }) =>
      NotificationMuteStore.cronPolicyAllows(jobPolicy, ok: ok) &&
      switch (mode) {
        CronNoticeMode.automatic || CronNoticeMode.all => true,
        CronNoticeMode.failuresOnly => !ok,
        CronNoticeMode.off => false,
      };
}
